import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// C callback for the event tap. Must not capture context, so we route through `refcon`.
private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<SwitchEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

/// One automatic change, as reported to the app (history, toast, sound).
struct FixEvent {
    let typed: String
    let result: String
    let kind: FixKind
    let from: Lang
    let to: Lang
    /// Right ⌥ can still undo it: false after Enter / Tab, where the text may already be sent or focus moved on.
    let undoable: Bool
}

/// Watches keystrokes, keeps the current word as key codes, decides on word end whether it was
/// typed in the wrong layout, and fixes it: delete → retype in the right layout → switch layout.
/// Your rules ("Не исправлять") are checked before every automatic change.
///
/// Threads: once started, the tap and all of the engine's own state live on `EngineThread`. The main thread
/// talks to it only through the public methods below (they hop over), and hears back through `onFix` /
/// `onRuleLearned`, which are called on the main thread. `UserStore` stays main-thread only: the engine keeps
/// its own copy of your rules and sends every change over. Without a thread (self-test), all of it runs inline.
final class SwitchEngine {
    let layouts: KeyboardLayouts
    let store: UserStore
    let typer = Typer()
    private let settings = Settings.shared

    /// Called on the main thread.
    var onFix: ((FixEvent) -> Void)?
    /// A rule was created by undoing or by putting your word back. `saved`: it reached the disk. Main thread.
    var onRuleLearned: ((_ word: String, _ saved: Bool) -> Void)?

    private var thread: EngineThread?
    /// Guards what both threads touch: the classifier, the front app, the rules copy and the counter.
    private let shared = NSLock()
    private var _classifier: Classifier?
    private var _frontmostBundleID: String?
    private var _rules: RuleBook?
    private var _correctionsToday = 0
    private var _tap: CFMachPort?

    var classifier: Classifier? {
        get { shared.withLock { _classifier } }
        set { shared.withLock { _classifier = newValue } }
    }
    var frontmostBundleID: String? {
        get { shared.withLock { _frontmostBundleID } }
        set { shared.withLock { _frontmostBundleID = newValue } }
    }
    var correctionsToday: Int { shared.withLock { _correctionsToday } }
    private var tap: CFMachPort? { shared.withLock { _tap } }

    /// Main thread: your rules changed in the store (added in Settings, removed, another Mac). The engine reads its copy.
    func rulesChanged() {
        guard thread != nil else { return }
        let book = store.rules
        shared.withLock { _rules = book }
    }

    /// The rules the keyboard handler checks: the store itself when everything runs on one thread (self-test).
    private var rules: RuleBook { thread == nil ? store.rules : shared.withLock { _rules ?? RuleBook() } }

    /// Runs `block` on the keyboard thread. Without one (self-test) the main thread plays its part: inline there.
    private func onEngine(_ block: @escaping () -> Void) {
        if let thread { thread.async(block) } else if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
    private func onEngine(after delay: TimeInterval, _ block: @escaping () -> Void) {
        if let thread { thread.async(after: delay, block) } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) }
    }
    /// Store changes and UI callbacks: main thread (inline when there is no keyboard thread).
    private func onMain(_ block: @escaping () -> Void) {
        if thread == nil || Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private var statsDay = Calendar.current.startOfDay(for: Date())

    private var word: [Stroke] = []
    private var prev: (strokes: [Stroke], terminator: Stroke, lang: Lang)?
    private var last: Correction?
    private var watch: Watch?
    private var recent: RecentFix?
    private var verifyWork: DispatchWorkItem?
    private static let probeQueue = DispatchQueue(label: "keyswitch.probe")
    /// Language of the last word you finished (after our fixes). In a Russian sentence a doubtful word,
    /// or a lone "d" (в), reads as Russian. Forgotten after a minute or whenever the caret jumps.
    private var context: (lang: Lang, at: Date)?
    private var contextLang: Lang? { context.flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.lang : nil } }
    private var busy = false
    /// The word in progress was switched mid-word: the layout its first letters were typed in.
    private var early: Lang?
    private var pending: [CGEvent] = []
    private var rightOptionDownAt: Date?
    private var rightOptionDirty = false
    /// Our own layout switch is about to be reported by macOS: it is not "you switched mid-word".
    private var ownSwitchUntil = Date.distantPast

    /// What right ⌥ can undo right now.
    private struct Correction {
        let typedText: String       // what we typed instead
        let originalText: String    // what the user had typed
        let terminator: Stroke
        let terminatorIsKey: Bool
        let from: Lang
        let to: Lang
        let originalWord: String    // the main word, for the rule
        let resultWord: String
        let kind: FixKind
    }

    /// After an auto-fix: erase the fixed word with Backspace (terminator included) and type the original again:
    /// that is a rule, exactly as if you had undone the fix with right ⌥.
    private struct Watch {
        let original: String    // what you had typed before we changed it
        let length: Int         // characters to erase: the fixed word plus its terminator
        var erased = 0
        let started = Date()
        var erasedAll: Bool { erased == length && Date().timeIntervalSince(started) < 30 }
    }

    /// The last correction, kept apart from the typing buffer: clicks and arrows reset the buffer,
    /// but you may still be fixing this word by hand in the same field.
    private struct RecentFix {
        let id = UUID()
        let kind: FixKind
        let original: String        // normalized core of what you typed
        let typedText: String       // exactly as typed (a case fix differs only in case)
        let result: String          // what we typed instead
        let lang: Lang              // the layout `original` was typed in
        let bundleID: String?
        let at = Date()
        var spot: FieldProbe.Spot?  // where `result` sits in the field, when Accessibility tells us
        var wordsAfter = 0          // words finished since: retyping the original is a restore only right away
        var edited = false          // the caret moved or text was deleted since: plain typing on is never a restore
        var alive: Bool { Date().timeIntervalSince(at) < 90 }

        /// `word` (a whole word, no edge punctuation) is what you had typed, not our result.
        func isRestore(_ word: String) -> Bool {
            if kind == .caseFix { return word == typedText && word != result }
            return normalizeWord(word) == original && normalizeWord(word) != normalizeWord(result)
        }
    }

    init(layouts: KeyboardLayouts, store: UserStore) {
        self.layouts = layouts
        self.store = store
    }

    // MARK: - Tap lifecycle

    var isRunning: Bool { tap != nil }

    /// Main thread.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = 0
        for t in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            mask |= CGEventMask(1) << CGEventMask(t.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        if thread == nil {
            let t = EngineThread()
            t.launch()
            typer.deliver = { block in t.async(block) }
            shared.withLock { _rules = store.rules }
            thread = t
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(thread!.runLoop, src, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        shared.withLock { _tap = tap }
        return true
    }

    /// The caret moved (click, arrows, shortcut): forget the typing buffer. The recent correction is kept,
    /// so putting your word back by hand in the same field can still be recognized.
    func resetAll() { onEngine { self.resetState() } }

    private func resetState() {
        recent?.edited = true
        word = []
        prev = nil
        last = nil
        watch = nil
        context = nil
        early = nil
    }

    /// Another app came to the front: nothing typed before belongs to it.
    func appChanged() {
        onEngine {
            self.resetState()
            self.recent = nil
            self.verifyWork?.cancel()
        }
    }

    /// macOS reports a layout change. Ours (after a fix or right ⌥) changes nothing; yours in the middle
    /// of a word makes the keys typed so far unreadable, so that word is left alone. The undo stays available.
    func layoutChanged() {
        onEngine {
            guard Date() > self.ownSwitchUntil else { return }
            self.word = []
            self.prev = nil
            self.context = nil
            self.early = nil
        }
    }

    private func select(_ lang: Lang) {
        ownSwitchUntil = Date().addingTimeInterval(1)
        layouts.select(lang)
    }

    // MARK: - Event handling

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS paused the tap (the app was busy): keys typed meanwhile were never seen,
            // so the half-word in the buffer would be misread. Start clean.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resetState()
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Typer.marker { return pass }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click while we retype may move focus: stop typing before the next key lands somewhere else.
            if busy { typer.cancel() }
            resetState()
            scheduleVerify()
            return pass
        case .flagsChanged:
            handleFlags(event)
            return pass
        case .keyDown, .keyUp:
            if busy {
                // Hold the user's keys while we are retyping, replay them afterwards in order.
                if let copy = event.copy() { pending.append(copy) }
                return nil
            }
            if type == .keyDown {
                let r = handleKeyDown(event)
                scheduleVerify()
                return r
            }
            return pass
        default:
            return pass
        }
    }

    private func handleFlags(_ event: CGEvent) {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if code == 61 { // right Option
            if event.flags.contains(.maskAlternate) {
                rightOptionDownAt = Date()
                rightOptionDirty = false
            } else if let t = rightOptionDownAt {
                rightOptionDownAt = nil
                if !rightOptionDirty && Date().timeIntervalSince(t) < 0.5 {
                    self.onEngine { self.manualFixNow() }
                }
            }
        } else {
            rightOptionDirty = true
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if rightOptionDownAt != nil { rightOptionDirty = true }

        // Excluded apps (terminals, IDEs, password managers) get every key untouched.
        if settings.isExcluded(frontmostBundleID) {
            resetState()
            return pass
        }
        // Any shortcut or Option-character breaks the word (⌘Z included: whether it restored your word is checked in the field).
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            resetState()
            return pass
        }

        let stroke = Stroke(keyCode: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
        switch code {
        case 51: // Delete (backspace)
            if !word.isEmpty {
                word.removeLast()
                if word.count < Thresholds.earlyLength { early = nil } // erased back into the switched start: it is yours again
            } else {
                prev = nil
                recent?.edited = true
                if var w = watch { w.erased += 1; watch = w.erased <= w.length ? w : nil } // erased past it: editing more
            }
            last = nil
            return pass
        case 49, 36, 76, 48: // Space, Return, Enter, Tab
            return finishWord(terminator: stroke, isKey: true) ? nil : pass
        case 65...92: // keypad: digits/operators end a word
            return finishWord(terminator: stroke, isKey: true) ? nil : pass
        case 0...50:
            break
        default: // arrows, Esc, F-keys, Home/End, forward delete…
            resetState()
            return pass
        }

        let cur = layouts.current()
        guard let curLang = cur.lang else { resetState(); return pass }
        let chCur = layouts.character(stroke, layout: cur.layout)
        let chAlt = layouts.character(stroke, in: curLang.other)
        let letterish = (chCur.first?.isLetter ?? false) || (chAlt.first?.isLetter ?? false) || chCur == "'" || chCur == "-"
        if letterish {
            if word.isEmpty && chCur == "-" { return pass } // a dash is not a word start
            if word.isEmpty, let w = watch, !w.erasedAll { watch = nil } // kept typing after the fix: it was fine
            word.append(stroke)
            last = nil
            if word.count == Thresholds.earlyLength, switchEarly(curLang: curLang, layout: cur.layout) { return nil }
            return pass
        }
        // Digit or symbol: finishes the word; the symbol itself is retyped if we convert.
        return finishWord(terminator: stroke, isKey: false) ? nil : pass
    }

    /// After the first few letters: if they begin no word in this layout but common words in the other one,
    /// retype them there and switch now, so the rest of the word comes out right as you type it.
    /// This key is swallowed and typed with the rest. Returns true when it switched.
    private func switchEarly(curLang: Lang, layout: Data?) -> Bool {
        guard early == nil, settings.autoEnabled, settings.earlySwitch, let classifier, layouts.hasBothLayouts,
              !word.contains(where: \.caps), !word.dropFirst().contains(where: \.shift) else { return false }
        let target = curLang.other
        let cur = layouts.string(word, layout: layout)
        let alt = layouts.string(word, in: target)
        guard classifier.shouldSwitchEarly(current: cur, alternative: alt, currentLang: curLang, contextLang: contextLang),
              !rules.protectsPrefix(cur, lang: curLang) else { return false }
        var deleteCount = word.count - 1 // this key has not reached the field
        var text = alt
        // A short word before it goes along, as at the end of a word ("z ghbd" → "я прив").
        if let p = prev, p.lang == curLang, p.terminator.keyCode == 49, p.strokes.count <= 3 {
            let pc = layouts.string(p.strokes, layout: layout), pa = layouts.string(p.strokes, in: target)
            if classifier.shouldRetroFix(current: pc, alternative: pa, currentLang: curLang),
               !rules.blocks(classifier.models[curLang]?.core(normalizeWord(pc)) ?? pc, lang: curLang, kind: .layout) {
                deleteCount += p.strokes.count + 1
                text = pa + " " + alt
            }
        }
        prev = nil
        early = curLang
        perform(Self.retype(delete: deleteCount, typed: nil, with: text))
        select(target)
        return true
    }

    /// The word ends after a switch mid-word: the same bookkeeping as a fix at the end of the word
    /// (history, toast, right ⌥ undoes it and remembers the word).
    private func finishEarly(strokes: [Stroke], result: String, from: Lang, to: Lang, terminator: Stroke, isKey: Bool) {
        let original = layouts.string(strokes, in: from)
        let core = classifier?.models[from]?.core(normalizeWord(original)) ?? normalizeWord(original)
        let undoable = Self.isUndoable(terminator)
        bumpStats()
        context = (to, Date())
        emit(FixEvent(typed: original, result: result, kind: .layout, from: from, to: to, undoable: undoable))
        guard undoable else { last = nil; watch = nil; prev = nil; return }
        last = Correction(typedText: result, originalText: original, terminator: terminator, terminatorIsKey: isKey,
                          from: from, to: to, originalWord: core, resultWord: result, kind: .layout)
        watch = Watch(original: core, length: result.count + 1)
        prev = (strokes, terminator, to)
        let r = RecentFix(kind: .layout, original: core, typedText: original, result: result, lang: from, bundleID: frontmostBundleID)
        recent = r
        locateFix(r.id, result: result)
    }

    /// Erases and types only what differs: "превет" → "привет" is 4 keys back and "ивет", not the whole word.
    /// `typed`: what is on screen now (nil when unknown: erase `delete` characters and type `text` whole).
    static func retype(delete: Int, typed: String?, with text: String) -> [Typer.Action] {
        guard let typed, typed.count == delete else { return [.backspace(delete), .text(text)] }
        let same = zip(typed, text).prefix { $0 == $1 }.count
        return [.backspace(delete - same), .text(String(text.dropFirst(same)))]
    }

    static func isUndoable(_ terminator: Stroke) -> Bool { ![36, 76, 48].contains(terminator.keyCode) }

    /// Returns true when the terminator key is swallowed (we retype it ourselves after the fix).
    private func finishWord(terminator: Stroke, isKey: Bool) -> Bool {
        let strokes = word
        word = []
        let earlyFrom = early
        early = nil
        let retyped = watch?.erasedAll == true ? watch : nil
        watch = nil
        guard !strokes.isEmpty else {
            prev = nil
            last = nil
            return false
        }
        let cur = layouts.current()
        guard let curLang = cur.lang else { return false }
        let curStr = layouts.string(strokes, layout: cur.layout)

        // You erased our fix and typed your word again: a rule, before this word is looked at.
        if retyped != nil { learnRetyped(curStr, lang: curLang) }
        // Typed your original word right after our fix (selected the result and retyped it): leave it alone
        // this time, and check in the field whether it really replaced our correction.
        let core = classifier?.models[curLang]?.core(normalizeWord(curStr)) ?? normalizeWord(curStr)
        if var r = recent, r.alive, r.bundleID == frontmostBundleID {
            if r.wordsAfter == 0, r.edited, r.lang == curLang, r.isRestore(r.kind == .caseFix ? curStr : core) {
                prev = (strokes, terminator, curLang)
                last = nil
                scheduleVerify(after: 0.35)
                return false
            }
            r.wordsAfter += 1
            recent = r
        }

        guard settings.autoEnabled, let classifier, layouts.hasBothLayouts else {
            prev = (strokes, terminator, curLang)
            return false
        }
        let undoable = Self.isUndoable(terminator)
        let target = curLang.other
        let rules = self.rules
        let altStr = layouts.string(strokes, in: target)
        var d = classifier.decide(current: curStr, alternative: altStr, currentLang: curLang, contextLang: contextLang)
        // Case slips: "пРИВЕТ" (Caps Lock left on; also switch it off) and "ПРивет" (Shift held one key too long).
        let capsSlip = Self.isCapsSlip(strokes)
        let caseFixed = capsSlip ? Self.unslipped(strokes) : Self.doubleCapitalFixed(strokes)
        var fixedStrokes = caseFixed ?? strokes

        // Punctuation at the edges ("ghbdtn." where "." is "ю" in Russian): if the whole reading is not a word,
        // decide on the letters alone and keep the punctuation exactly as typed.
        var lead = "", trail = ""
        let edges = Self.edgePunctuation(cur: strokes.map { layouts.character($0, layout: cur.layout) },
                                         alt: strokes.map { layouts.character($0, in: target) })
        if edges.lead + edges.trail > 0, edges.lead + edges.trail < strokes.count,
           classifier.models[target]?.score(normalizeWord(altStr)) == nil {
            let inner = Array(strokes[edges.lead..<(strokes.count - edges.trail)])
            d = classifier.decide(current: layouts.string(inner, layout: cur.layout), alternative: layouts.string(inner, in: target),
                                  currentLang: curLang, contextLang: contextLang)
            if d.convert {
                lead = layouts.string(Array(strokes.prefix(edges.lead)), layout: cur.layout)
                trail = layouts.string(Array(strokes.suffix(edges.trail)), layout: cur.layout)
                fixedStrokes = caseFixed.map { Array($0[edges.lead..<($0.count - edges.trail)]) } ?? inner
            }
        }

        if d.convert, rules.blocks(core, lang: curLang, kind: .layout) { d = Decision(convert: false, reason: "rule", uncertain: true) }

        guard d.convert else {
            if let from = earlyFrom {
                // "." and "," pressed after the switch came out as "ю" / "б": you meant punctuation ("приветю" → "привет.").
                let fromChars = strokes.map { layouts.character($0, in: from) }
                let curChars = strokes.map { layouts.character($0, layout: cur.layout) }
                let e = Self.edgePunctuation(cur: fromChars, alt: curChars)
                if e.trail > 0, e.trail < strokes.count, let m = classifier.models[curLang], m.score(normalizeWord(curStr)) == nil,
                   m.score(normalizeWord(curChars.dropLast(e.trail).joined())) != nil {
                    let punct = fromChars.suffix(e.trail).joined()
                    perform([.backspace(e.trail), .text(punct), terminatorAction(terminator, isKey: isKey, lang: curLang)])
                    finishEarly(strokes: strokes, result: curChars.dropLast(e.trail).joined() + punct, from: from, to: curLang,
                                terminator: terminator, isKey: isKey)
                    return true
                }
                finishEarly(strokes: strokes, result: curStr, from: from, to: curLang, terminator: terminator, isKey: isKey)
                return false
            }
            if let fixed = caseFixed, !rules.blocks(core, lang: curLang, kind: .caseFix),
               caseFix(strokes: strokes, fixed: fixed, capsLock: capsSlip, typed: curStr, lang: curLang, terminator: terminator, isKey: isKey) {
                return true
            }
            if let m = classifier.models[curLang], m.score(m.core(normalizeWord(curStr))) != nil { context = (curLang, Date()) }
            if !d.uncertain, !rules.blocks(core, lang: curLang, kind: .spell),
               spellFix(strokes: strokes, typed: curStr, alt: altStr, lang: curLang, terminator: terminator, isKey: isKey) {
                return true
            }
            prev = (strokes, terminator, curLang)
            last = nil
            return false
        }

        // Pull a short previous word along ("z ghbdtn" -> "я привет").
        var deleteCount = strokes.count
        let newWord = layouts.string(fixedStrokes, in: target)
        var newText = lead + newWord + trail
        var originalText = curStr
        if let p = prev, p.lang == curLang, p.terminator.keyCode == 49, p.strokes.count <= 3 {
            let pc = layouts.string(p.strokes, layout: cur.layout)
            let pa = layouts.string(p.strokes, in: target)
            if classifier.shouldRetroFix(current: pc, alternative: pa, currentLang: curLang),
               !rules.blocks(classifier.models[curLang]?.core(normalizeWord(pc)) ?? pc, lang: curLang, kind: .layout) {
                deleteCount += p.strokes.count + 1
                newText = pa + " " + newText
                originalText = pc + " " + curStr
            }
        }

        var actions: [Typer.Action] = [.backspace(deleteCount), .text(newText)]
        actions.append(terminatorAction(terminator, isKey: isKey, lang: target))
        if capsSlip { Self.capsLockOff() }
        let fix = FixEvent(typed: curStr, result: lead + newWord + trail, kind: .layout, from: curLang, to: target, undoable: undoable)
        perform(actions, capsJustTurnedOff: capsSlip, fix: fix, original: core, typedText: curStr)
        select(target)
        bumpStats()
        context = (target, Date())
        emit(fix)

        last = undoable ? Correction(
            typedText: newText, originalText: originalText, terminator: terminator, terminatorIsKey: isKey,
            from: curLang, to: target, originalWord: core, resultWord: newWord, kind: .layout) : nil
        watch = undoable ? Watch(original: core, length: fix.result.count + 1) : nil
        prev = undoable ? (strokes, terminator, target) : nil
        return true
    }

    /// Strokes at the start / end that are punctuation in the current layout but letters in the other one
    /// ("ghbdtn." → "." reads as "ю"). Apostrophes count as punctuation only at the edges.
    static func edgePunctuation(cur: [String], alt: [String]) -> (lead: Int, trail: Int) {
        func isPunct(_ i: Int) -> Bool {
            let c = cur[i].first, a = alt[i].first
            return !(c?.isLetter ?? false) && (a?.isLetter ?? false)
        }
        var lead = 0
        while lead < cur.count, isPunct(lead) { lead += 1 }
        guard lead < cur.count else { return (0, 0) }
        var trail = 0
        while trail < cur.count - lead, isPunct(cur.count - 1 - trail) { trail += 1 }
        return (lead, trail)
    }

    /// "пРИВЕТ" / "ПРивет" → "Привет" for a known word in the current layout.
    private func caseFix(strokes: [Stroke], fixed: [Stroke], capsLock: Bool, typed: String, lang: Lang, terminator: Stroke, isKey: Bool) -> Bool {
        guard let model = classifier?.models[lang], model.score(model.core(normalizeWord(typed))) != nil else { return false }
        let text = layouts.string(fixed, in: lang)
        let undoable = Self.isUndoable(terminator)
        if capsLock { Self.capsLockOff() }
        let fix = FixEvent(typed: typed, result: text, kind: .caseFix, from: lang, to: lang, undoable: undoable)
        perform(Self.retype(delete: strokes.count, typed: typed, with: text) + [terminatorAction(terminator, isKey: isKey, lang: lang)],
                capsJustTurnedOff: capsLock, fix: fix, original: model.core(normalizeWord(typed)), typedText: typed)
        context = (lang, Date())
        bumpStats()
        emit(fix)
        last = undoable ? Correction(
            typedText: text, originalText: typed, terminator: terminator, terminatorIsKey: isKey,
            from: lang, to: lang, originalWord: normalizeWord(typed), resultWord: text, kind: .caseFix) : nil
        watch = undoable ? Watch(original: normalizeWord(typed), length: text.count + 1) : nil
        prev = nil
        return true
    }

    /// Caps Lock on for every key, Shift only on the first: the classic "пРИВЕТ". An all-caps word
    /// typed with Caps Lock and no Shift ("ПРИВЕТ") is deliberate and left alone.
    static func isCapsSlip(_ strokes: [Stroke]) -> Bool {
        strokes.count >= 2 && strokes.allSatisfy(\.caps) && strokes[0].shift && !strokes.dropFirst().contains(where: \.shift)
    }

    /// "ПРивет", "HEllo": Shift on the first two keys only, no Caps Lock, at least three letters.
    /// Returns the strokes with Shift kept on the first key only. Acronyms are all caps and never match.
    static func doubleCapitalFixed(_ strokes: [Stroke]) -> [Stroke]? {
        guard strokes.count >= 3, !strokes.contains(where: \.caps),
              strokes[0].shift, strokes[1].shift, !strokes.dropFirst(2).contains(where: \.shift) else { return nil }
        return strokes.enumerated().map { Stroke(keyCode: $0.element.keyCode, shift: $0.offset == 0, caps: false) }
    }

    /// The same keys as if Caps Lock were off: Shift on the first, nothing on the rest.
    static func unslipped(_ strokes: [Stroke]) -> [Stroke] {
        strokes.enumerated().map { Stroke(keyCode: $0.element.keyCode, shift: $0.offset == 0, caps: false) }
    }

    private static func capsLockOff() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
        IOServiceClose(connect)
    }

    /// Typo fix for a word the layout check left alone. Same machinery as a layout fix: delete, retype,
    /// retype the terminator; right Option undoes it and remembers the refusal. Never on Enter / Tab (no undo there).
    private func spellFix(strokes: [Stroke], typed: String, alt: String, lang: Lang, terminator: Stroke, isKey: Bool) -> Bool {
        guard settings.spellAllowed(in: frontmostBundleID), let classifier, let model = classifier.models[lang] else { return false }
        guard Self.isUndoable(terminator) else { return false }
        guard let fixed = SpellCorrector.correction(for: typed, altReading: alt, model: model, other: classifier.models[lang.other]) else { return false }
        let fix = FixEvent(typed: typed, result: fixed, kind: .spell, from: lang, to: lang, undoable: true)
        perform(Self.retype(delete: strokes.count, typed: typed, with: fixed) + [terminatorAction(terminator, isKey: isKey, lang: lang)],
                fix: fix, original: normalizeWord(typed), typedText: typed)
        bumpStats()
        context = (lang, Date())
        emit(fix)
        last = Correction(
            typedText: fixed, originalText: typed, terminator: terminator, terminatorIsKey: isKey,
            from: lang, to: lang, originalWord: normalizeWord(typed), resultWord: fixed, kind: .spell)
        watch = Watch(original: normalizeWord(typed), length: fixed.count + 1)
        prev = nil // the text on screen no longer matches these strokes
        return true
    }

    private func terminatorAction(_ t: Stroke, isKey: Bool, lang: Lang) -> Typer.Action {
        if isKey { return .key(t.keyCode, t.shift ? CGEventFlags.maskShift : []) }
        return .text(layouts.character(t, in: lang))
    }

    /// Retypes while holding the user's own keys; they are replayed afterwards in order.
    /// `capsJustTurnedOff`: the held keys were captured with Caps Lock on and carry uppercase text,
    /// so they are rebuilt from their key codes and the system types them in the new state.
    /// `fix`: an automatic correction; its place in the field is looked up afterwards, to recognize your manual restore.
    /// If focus leaves the app (or you click) mid-way, the rest is not typed and the undo is dropped;
    /// your held keys are still replayed, where you now are.
    private func perform(_ actions: [Typer.Action], capsJustTurnedOff: Bool = false, fix: FixEvent? = nil,
                         original: String? = nil, typedText: String = "") {
        busy = true
        verifyWork?.cancel()
        if let fix, let original, fix.undoable {
            recent = RecentFix(kind: fix.kind, original: original, typedText: typedText, result: fix.result,
                               lang: fix.from, bundleID: frontmostBundleID)
        } else {
            recent = nil
        }
        let fixID = recent?.id
        typer.run(actions) { [weak self] finished in
            guard let self else { return }
            self.busy = false
            if !finished {
                self.last = nil
                self.watch = nil
                self.recent = nil
                self.prev = nil
            } else if let fixID, let fix, fix.undoable {
                self.locateFix(fixID, result: fix.result)
            }
            self.replayPending(capsJustTurnedOff: capsJustTurnedOff)
        }
    }

    /// Your keys held while we were typing, in order.
    private func replayPending(capsJustTurnedOff: Bool = false) {
        let replay = pending
        pending = []
        for e in replay {
            if capsJustTurnedOff, let fresh = CGEvent(keyboardEventSource: nil,
                                                     virtualKey: CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode)),
                                                     keyDown: e.type == .keyDown) {
                fresh.flags = e.flags.subtracting(.maskAlphaShift)
                fresh.post(tap: .cghidEventTap)
            } else {
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Tells the app (history, toast, sound) on the main thread, after the keys are handled.
    private func emit(_ fix: FixEvent) {
        onMain { [weak self] in self?.onFix?(fix) }
    }

    private func bumpStats() {
        let today = Calendar.current.startOfDay(for: Date())
        if today != statsDay { statsDay = today; shared.withLock { _correctionsToday = 0 } }
        shared.withLock { _correctionsToday += 1 }
    }

    // MARK: - Recognizing your own restore

    /// Finds where the corrected word sits in the field (Accessibility, off the main thread).
    private func locateFix(_ id: UUID, result: String) {
        Self.probeQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            let spot = FieldProbe.locate(result)
            self?.onEngine {
                guard let self, var r = self.recent, r.id == id else { return }
                r.spot = spot
                self.recent = r
                if r.edited { self.scheduleVerify() } // you were already editing while we looked
            }
        }
    }

    /// After you stop typing or clicking for a moment: is your original word back where our correction was?
    /// Only that exact word, at that place, in the same field counts.
    private func scheduleVerify(after delay: TimeInterval = 0.6) {
        guard let r = recent, r.alive, r.spot != nil, r.bundleID == frontmostBundleID else { return }
        verifyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.verify() }
        verifyWork = work
        onEngine(after: delay) { if !work.isCancelled { work.perform() } }
    }

    private func verify() {
        guard !busy, let r = recent, r.alive, let spot = r.spot, r.bundleID == frontmostBundleID else { return }
        let length = (r.original as NSString).length + (r.result as NSString).length
        Self.probeQueue.async { [weak self] in
            let now = FieldProbe.word(at: spot, around: length)
            self?.onEngine {
                guard let self, let cur = self.recent, cur.id == r.id, let now else { return }
                if cur.isRestore(now) {
                    self.recent = nil
                    self.addRule(r.original, lang: r.lang, kind: r.kind, result: r.result, source: .restore)
                }
            }
        }
    }

    /// You erased our fix with Backspace and typed again. Only your original word makes a rule;
    /// a third word means the fix was wrong in another way, and the typo is not protected.
    private func learnRetyped(_ text: String, lang: Lang) {
        let w = classifier?.models[lang]?.core(normalizeWord(text)) ?? normalizeWord(text)
        guard let r = recent, r.lang == lang, r.isRestore(r.kind == .caseFix ? text : w) else { return }
        recent = nil
        addRule(r.original, lang: lang, kind: r.kind, result: r.result, source: .restore)
    }

    private func addRule(_ word: String, lang: Lang, kind: FixKind, result: String, source: RuleSource) {
        guard !word.isEmpty else { return }
        if MissLog.isOn, source == .undo || source == .restore {
            var reason = "вид: " + kind.title.lowercased()
            if kind == .layout, let d = classifier?.decide(current: word, alternative: result, currentLang: lang) {
                reason += "; " + Self.describe(d.reason, typed: word, alt: result)
            }
            MissLog.write(.wrong, typed: word, result: result, how: source == .undo ? "отмена ⌥" : "вернули своё слово", reason: reason)
        }
        // Applies to the keyboard at once; the store (main thread) writes it to disk and reports back.
        if thread != nil { shared.withLock { _ = _rules?.add(word, lang: lang, kind: kind, result: result, source: source) } }
        onMain { [weak self] in self?.storeRule(word, lang: lang, kind: kind, result: result, source: source) }
    }

    private func storeRule(_ word: String, lang: Lang, kind: FixKind, result: String, source: RuleSource) {
        store.addRule(word, lang: lang, kind: kind, result: result, source: source) { [weak self] saved in
            self?.onRuleLearned?(word, saved)
        }
    }

    // MARK: - Manual fix (tap Right Option)

    /// 1) right after an auto-fix → undo it and remember the refusal (a rule);
    /// 2) in the middle of a word → convert it;
    /// 3) right after a word + space → convert that word;
    /// 4) the caret is on a word you came back to (click, arrows) or text is selected → convert that,
    ///    reading the field through Accessibility, or through the clipboard where the field does not tell;
    /// 5) otherwise → just switch the layout.
    func manualFix() { onEngine { self.manualFixNow() } }

    private func manualFixNow() {
        guard !busy else { return }
        if let c = last {
            last = nil
            var actions: [Typer.Action] = [.backspace(c.typedText.count + 1), .text(c.originalText)]
            actions.append(terminatorAction(c.terminator, isKey: c.terminatorIsKey, lang: c.from))
            perform(actions)
            select(c.from)
            addRule(c.originalWord, lang: c.from, kind: c.kind, result: c.resultWord, source: .undo)
            prev = nil
            watch = nil
            return
        }
        guard let curLang = layouts.currentLang else { return }
        let target = curLang.other
        if !word.isEmpty {
            let alt = layouts.string(word, in: target)
            logMiss(typed: layouts.string(word, in: curLang), alt: alt, lang: curLang, how: "⌥ посреди слова")
            perform([.backspace(word.count), .text(alt)])
            select(target)
            _ = learnPositive(alt, lang: target)
            return
        }
        if let p = prev, p.lang == curLang {
            let alt = layouts.string(p.strokes, in: target)
            let isKey = [49, 36, 76, 48].contains(p.terminator.keyCode) || (65...92).contains(p.terminator.keyCode)
            if !Self.isUndoable(p.terminator) { select(target); return } // after Enter / Tab: no retyping
            logMiss(typed: layouts.string(p.strokes, in: curLang), alt: alt, lang: curLang, how: "⌥ после слова")
            perform([.backspace(p.strokes.count + 1), .text(alt), terminatorAction(p.terminator, isKey: isKey, lang: target)])
            select(target)
            _ = learnPositive(alt, lang: target)
            prev = (p.strokes, p.terminator, target)
            return
        }
        fixAtCaret(fallback: curLang)
    }

    /// Remembers a word you converted by hand, so next time it is fixed by itself.
    /// Words the dictionaries already know are not added again. Returns the word it learned.
    @discardableResult
    private func learnPositive(_ text: String, lang: Lang) -> String? {
        guard let m = classifier?.models[lang] else { return nil }
        let w = m.core(normalizeWord(text))
        guard m.isWord(w), w.count >= 2, m.score(w) == nil else { return nil }
        onMain { [store] in store.learn(w, lang: lang) }
        classifier?.learn(w, lang: lang)
        return w
    }

    // MARK: - Right ⌥ on a word you came back to

    static let maxSelection = 1000
    /// The last word converted at the caret: pressing right ⌥ on it again puts it back and forgets what was learned.
    private var caretFix: (result: String, learned: String?, lang: Lang, at: Date)?

    /// Text already on screen, read again in the other layout character by character (its length does not change).
    /// The source layout is the script most letters are in. Characters that are not letters in either reading
    /// (digits, spaces, ? !) stay. Punctuation at a word's edge that would turn into a letter ("ghbdtn." → «приветю»)
    /// stays punctuation, unless the whole reading is a known word ("k.,k." → «люблю»).
    func manualConversion(of text: String, fallback: Lang) -> (text: String, from: Lang, to: Lang)? {
        var cyr = 0, lat = 0
        for u in text.unicodeScalars {
            if (0x0400...0x04FF).contains(u.value) { cyr += 1 } else if u.isASCII, u.properties.isAlphabetic { lat += 1 }
        }
        let from: Lang = cyr == lat ? fallback : (cyr > lat ? .ru : .en)
        let to = from.other
        let map = layouts.reverseMap(from)
        var out = ""
        var token: [Character] = []
        func flush() {
            guard !token.isEmpty else { return }
            let cur = token.map(String.init)
            let alt = token.map { ch -> String in
                guard let st = map[ch] else { return String(ch) }
                let a = layouts.character(st, in: to)
                return a.isEmpty ? String(ch) : a
            }
            var conv = zip(cur, alt).map { c, a in (c.first?.isLetter ?? false) || (a.first?.isLetter ?? false) ? a : c }
            let edges = Self.edgePunctuation(cur: cur, alt: alt)
            if edges.lead + edges.trail > 0, edges.lead + edges.trail < cur.count,
               classifier?.models[to]?.score(normalizeWord(conv.joined())) == nil {
                for i in 0..<edges.lead { conv[i] = cur[i] }
                for i in (cur.count - edges.trail)..<cur.count { conv[i] = cur[i] }
            }
            out += conv.joined()
            token = []
        }
        for ch in text {
            if ch.isWhitespace { flush(); out.append(ch) } else { token.append(ch) }
        }
        flush()
        return out == text ? nil : (out, from, to)
    }

    /// Keys you type meanwhile are held and replayed afterwards, as during any fix.
    private func fixAtCaret(fallback: Lang) {
        busy = true
        let pid = Typer.frontPID
        if FieldProbe.simulatedField != nil {
            applyAtCaret(FieldProbe.around(pid: pid), fallback: fallback)
            return
        }
        Self.probeQueue.async { [weak self] in
            let around = FieldProbe.around(pid: pid)
            self?.onEngine { self?.applyAtCaret(around, fallback: fallback) }
        }
    }

    private func applyAtCaret(_ around: FieldProbe.Around?, fallback: Lang) {
        // Some apps answer with an empty field instead of saying nothing: try the clipboard there too.
        guard let a = around, !(a.before.isEmpty && a.selected.isEmpty && a.after.isEmpty) || FieldProbe.simulatedField != nil else {
            fixViaClipboard(fallback: fallback)
            return
        }
        if !a.selected.isEmpty {
            guard a.selected.count <= Self.maxSelection, let c = manualConversion(of: a.selected, fallback: fallback) else {
                return giveUp(fallback)
            }
            replaceAtCaret([.text(c.text)], original: a.selected, c, how: "выделение")
            return
        }
        guard let t = FieldProbe.tokenAtCaret(before: a.before, after: a.after),
              let c = manualConversion(of: t.left + t.right, fallback: fallback) else { return giveUp(fallback) }
        let back = c.text.count == (t.left + t.right).count ? t.right.count : 0
        replaceAtCaret([.forwardDelete(t.right.count), .backspace(t.left.count), .text(c.text), .left(back)],
                       original: t.left + t.right, c, how: "⌥ на старом слове")
    }

    /// Where the field tells nothing (some web editors, Electron): ⌘C shows a selection; otherwise ⌥⇧← selects
    /// the word left of the caret and ⌘C reads it. Your clipboard is put back right after.
    private func fixViaClipboard(fallback: Lang) {
        let pb = NSPasteboard.general
        let saved = Self.snapshot(pb)
        let start = pb.changeCount
        ClipboardHistory.pausedUntil = Date().addingTimeInterval(3)
        typer.run([.command(8), .pause(0.12)]) { [weak self] ok in
            guard let self else { return }
            guard ok else { Self.restore(saved, pb, changedFrom: start); return self.giveUp(fallback) }
            if pb.changeCount != start, let s = pb.string(forType: .string), !s.isEmpty,
               s.count <= Self.maxSelection, !s.contains(where: \.isNewline) {
                Self.restore(saved, pb, changedFrom: start)
                guard let c = self.manualConversion(of: s, fallback: fallback) else { return self.giveUp(fallback) }
                self.replaceAtCaret([.text(c.text)], original: s, c, how: "выделение")
                return
            }
            let mid = pb.changeCount
            self.typer.run([.key(123, [.maskAlternate, .maskShift]), .command(8), .pause(0.12)]) { ok in
                let s = pb.changeCount != mid ? pb.string(forType: .string) : nil
                Self.restore(saved, pb, changedFrom: start)
                // Only a word that touches the caret: after a space right ⌥ just switches the layout.
                guard ok, let s, !s.isEmpty, s.count <= 100, !s.contains(where: \.isWhitespace),
                      let c = self.manualConversion(of: s, fallback: fallback) else {
                    if ok { self.typer.run([.key(124, [])]) } // → drops the selection, the caret is back where it was
                    return self.giveUp(fallback)
                }
                self.replaceAtCaret([.text(c.text)], original: s, c, how: "⌥ на старом слове")
            }
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], _ pb: NSPasteboard, changedFrom start: Int) {
        if pb.changeCount != start {
            pb.clearContents()
            if !items.isEmpty { pb.writeObjects(items) }
        }
        ClipboardHistory.pausedUntil = Date().addingTimeInterval(0.8)
    }

    private func replaceAtCaret(_ actions: [Typer.Action], original: String, _ c: (text: String, from: Lang, to: Lang), how: String) {
        busy = false // perform holds your keys again until it is done
        perform(actions)
        select(c.to)
        word = []
        prev = nil
        last = nil
        watch = nil
        context = (c.to, Date())
        let isToggleBack = caretFix.map { $0.result == original && Date().timeIntervalSince($0.at) < 30 } ?? false
        if isToggleBack {
            if let f = caretFix, let w = f.learned { onMain { [store] in store.forget(w, lang: f.lang) } }
            caretFix = nil
            return
        }
        logMiss(typed: original, alt: c.text, lang: c.from, how: how)
        let single = !c.text.contains(where: \.isWhitespace)
        caretFix = (c.text, single ? learnPositive(c.text, lang: c.to) : nil, c.to, Date())
    }

    // MARK: - Журнал пропусков

    /// You converted `typed` (in `lang`'s layout) by hand: why it was not fixed by itself.
    private func logMiss(typed: String, alt: String, lang: Lang, how: String) {
        guard MissLog.isOn else { return }
        MissLog.write(.missed, typed: typed, result: alt, how: how, reason: explain(typed: typed, alt: alt, lang: lang))
    }

    func explain(typed: String, alt: String, lang: Lang) -> String {
        if settings.isExcluded(frontmostBundleID) { return "приложение в списке «Не исправлять»" }
        if !settings.autoEnabled { return "автоисправление выключено" }
        if typed.contains(where: \.isWhitespace) { return "фраза из нескольких слов" }
        guard let classifier, let model = classifier.models[lang] else { return "словари ещё не загружены" }
        if !layouts.hasBothLayouts { return "не включены обе раскладки, русская и английская" }
        if rules.blocks(model.core(normalizeWord(typed)), lang: lang, kind: .layout) {
            return "ваше правило «Не исправлять» для «\(model.core(normalizeWord(typed)))»"
        }
        let d = classifier.decide(current: typed, alternative: alt, currentLang: lang, contextLang: contextLang)
        let why = Self.describe(d.reason, typed: typed, alt: alt)
        if d.convert {
            return "сейчас исправилось бы само (\(why)) — возможно, слово допечатывали после щелчка или пропали нажатия"
        }
        return why
    }

    /// The classifier's reason, in words.
    static func describe(_ reason: String, typed: String, alt: String) -> String {
        switch reason {
        case "cur-dict": "«\(typed)» есть в словаре как настоящее слово"
        case "both-dict": "оба варианта — настоящие слова, «\(alt)» встречается не намного чаще"
        case "single-letter": "однобуквенное слово без контекста"
        case "short": "короче 3 букв, и в словаре нет"
        case "ngram-no": "незнакомое слово: на другой язык похоже недостаточно"
        case "other-not-alpha": "в другой раскладке получаются не только буквы"
        case "no-letters": "в слове нет букв"
        case "other-dict": "«\(alt)» есть в словаре, «\(typed)» — нет"
        case "freq": "оба варианта в словаре, «\(alt)» намного частотнее"
        case "ngram": "незнакомое слово, больше похоже на язык другой раскладки"
        case "rule": "ваше правило «Не исправлять»"
        default: reason
        }
    }

    /// Nothing to convert at the caret: right ⌥ is a plain layout switch.
    private func giveUp(_ fallback: Lang) {
        busy = false
        replayPending()
        select(fallback.other)
    }
}
