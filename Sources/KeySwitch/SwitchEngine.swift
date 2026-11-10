import AppKit
import CoreGraphics
import Foundation

enum Hotkey {
    case flipSelection    // ⌃⌥R
    case clipboardMenu    // ⌃⌥V

    init?(keyCode: UInt16) {
        switch keyCode {
        case 15: self = .flipSelection
        case 9: self = .clipboardMenu
        default: return nil
        }
    }
}

/// C callback for the event tap. Must not capture context, so we route through `refcon`.
private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<SwitchEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

/// Watches keystrokes, keeps the current word as key codes, decides on word end whether it was
/// typed in the wrong layout, and fixes it: delete → retype in the right layout → switch layout.
final class SwitchEngine {
    var classifier: Classifier?
    let layouts: KeyboardLayouts
    let store: UserStore
    let typer: Typer
    private let settings = Settings.shared
    private let frontmostPID: () -> pid_t?

    var onSuggestionKey: ((UInt16, CGEventFlags) -> Bool)?
    var onHotkey: ((Hotkey) -> Void)?
    var onCorrection: ((_ from: String, _ to: String) -> Void)?
    var onSuggestion: (() -> Void)?
    var onManualFixAtCaret: (() -> Void)?
    var onTapStopped: ((String) -> Void)?
    var frontmostBundleID: String?

    private(set) var correctionsToday = 0
    private var statsDay = Calendar.current.startOfDay(for: Date())

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var word: [Stroke] = []
    private var prev: (strokes: [Stroke], terminator: Stroke, lang: Lang)?
    private var last: Correction?
    private var busy = false
    private var pendingInput: [CGEvent] = []
    private var typingPID: pid_t?
    private var typingRunID: UInt64 = 0
    private var contextRevision: UInt64 = 0
    private var rightOptionDownAt: Date?
    private var rightOptionDirty = false
    private var structuredToken = false

    private struct Correction {
        let typedText: String       // what we typed instead
        let originalText: String    // what the user had typed
        let terminator: Stroke
        let terminatorIsKey: Bool
        let from: Lang
        let to: Lang
        let originalWord: String    // the main word (for learning on undo)
        let kind: FixKind
    }

    init(layouts: KeyboardLayouts, store: UserStore, typer: Typer = Typer(),
         frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.layouts = layouts
        self.store = store
        self.typer = typer
        self.frontmostPID = frontmostPID
    }

    // MARK: - Tap lifecycle

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var isTyping: Bool { busy }

    @discardableResult
    func start() -> Bool {
        if tap != nil {
            if isRunning { return true }
            stop()
        }
        var mask: CGEventMask = 0
        for t in [CGEventType.keyDown, .keyUp, .flagsChanged] {
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
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = src
        guard isRunning else { stop(); return false }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.cancelPendingTyping()
        }
        return true
    }

    func stop() {
        contextRevision &+= 1
        typingRunID &+= 1
        typer.cancel()
        pendingInput.removeAll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        tap = nil
        tapSource = nil
        mouseMonitor = nil
        busy = false
        rightOptionDownAt = nil
        rightOptionDirty = false
        resetAll()
    }

    func resetAll() {
        word = []
        prev = nil
        last = nil
        structuredToken = false
    }

    func cancelPendingTyping() {
        contextRevision &+= 1
        typingRunID &+= 1
        typer.cancel()
        pendingInput.removeAll()
        busy = false
        rightOptionDownAt = nil
        rightOptionDirty = false
        resetAll()
    }

    // MARK: - Event handling

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Invalidate now: a rewrite completion may already be queued on main.
            cancelPendingTyping()
            // macOS disabled an unresponsive tap. Leave it off so input recovers.
            DispatchQueue.main.async { [weak self] in
                self?.stop()
                self?.onTapStopped?("Перехват клавиш отключён системой. Запустите его снова из меню.")
            }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Typer.marker { return pass }

        if busy, frontmostPID() != typingPID {
            cancelPendingTyping()
            return pass
        }
        if busy, type == .keyDown || type == .keyUp || type == .flagsChanged {
            // Do not abandon a destructive rewrite halfway through. Hold *all* physical
            // keyboard events, including modifier releases and key-ups, in arrival order.
            if let copy = event.copy() {
                pendingInput.append(copy)
                rightOptionDownAt = nil
                rightOptionDirty = false
                return nil
            }
            cancelPendingTyping()
            return pass
        }

        switch type {
        case .flagsChanged:
            contextRevision &+= 1
            typer.cancel()
            handleFlags(event)
            return pass
        case .keyDown:
            contextRevision &+= 1
            typer.cancel()
            return handleKeyDown(event)
        case .keyUp:
            // The terminator's key-up follows its swallowed key-down. It must not cancel a fix.
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
                    let revision = contextRevision
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.contextRevision == revision else { return }
                        self.manualFix()
                    }
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
        if onSuggestionKey?(code, flags) == true { return nil }
        if rightOptionDownAt != nil { rightOptionDirty = true }

        // Global hotkeys: ⌃⌥ + key
        if flags.contains(.maskControl) && flags.contains(.maskAlternate) && !flags.contains(.maskCommand),
           let hk = Hotkey(keyCode: code) {
            let appID = frontmostBundleID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.frontmostBundleID == appID else { return }
                self.onHotkey?(hk)
            }
            return nil
        }
        // Any shortcut or Option-character breaks the word.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            resetAll()
            return pass
        }
        if settings.isExcluded(frontmostBundleID) {
            resetAll()
            return pass
        }

        let stroke = Stroke(keyCode: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
        switch code {
        case 51: // Delete (backspace)
            if !word.isEmpty { word.removeLast() } else { prev = nil }
            last = nil
            return pass
        case 48: // Tab can move focus: never rewrite or offer undo across fields.
            resetAll()
            return pass
        case 49, 36, 76: // Space, Return, Enter
            if structuredToken { resetAll(); return pass }
            return finishWord(terminator: stroke, isKey: true) ? nil : pass
        case 65...92: // keypad: digits/operators end a word
            resetAll()
            return pass
        case 0...50:
            break
        default: // arrows, Esc, F-keys, Home/End, forward delete…
            resetAll()
            return pass
        }

        let cur = layouts.current()
        guard let curLang = cur.lang else { resetAll(); return pass }
        let chCur = layouts.character(stroke, layout: cur.layout)
        let chAlt = layouts.character(stroke, in: curLang.other)
        if InputPolicy.beginsStructuredToken(chCur) {
            structuredToken = true
            word = []
            prev = nil
            last = nil
            return pass
        }
        if structuredToken { return pass }
        let letterish = (chCur.first?.isLetter ?? false) || (chAlt.first?.isLetter ?? false) || chCur == "'" || chCur == "-"
        if letterish {
            if word.isEmpty && chCur == "-" { return pass } // a dash is not a word start
            if word.count >= 64 { structuredToken = true; word = []; prev = nil; last = nil; return pass }
            word.append(stroke)
            last = nil
            return pass
        }
        // Digit or symbol: finishes the word; the symbol itself is retyped if we convert.
        return finishWord(terminator: stroke, isKey: false) ? nil : pass
    }

    /// Returns true when the terminator key is swallowed (we retype it ourselves after the fix).
    private func finishWord(terminator: Stroke, isKey: Bool) -> Bool {
        let strokes = word
        word = []
        guard !strokes.isEmpty else {
            prev = nil
            last = nil
            return false
        }
        // Keep one correction bounded even if a field contains a very long token.
        guard strokes.count <= InputPolicy.maxAutomaticWordLength else { prev = nil; last = nil; return false }
        let isEnter = terminator.keyCode == 36 || terminator.keyCode == 76
        let cur = layouts.current()
        guard settings.autoEnabled, let classifier, let curLang = cur.lang, layouts.hasBothLayouts else {
            if let l = cur.lang { prev = (strokes, terminator, l) }
            return false
        }
        let target = curLang.other
        let curStr = layouts.string(strokes, layout: cur.layout)
        let altStr = layouts.string(strokes, in: target)
        let plan = classifier.plan(current: curStr, alternative: altStr, currentLang: curLang)
        if InputPolicy.blocksAutomaticCorrection(curStr, plan: plan) {
            prev = nil
            last = nil
            return false
        }
        let currentCore = classifier.models[curLang]?.core(normalizeWord(plan.currentWord)) ?? normalizeWord(plan.currentWord)
        guard plan.decision.convert else {
            if settings.spellEnabled, InputPolicy.allowsAutomaticSpelling(terminator: terminator.keyCode), curStr.count == strokes.count,
               !store.rules.blocks(currentCore, lang: curLang, kind: .spell),
               let model = classifier.models[curLang],
               let replacement = SpellCorrector.correction(
                   for: curStr, alternative: altStr, model: model, other: classifier.models[target]
               ) {
                return applySpellingCorrection(original: curStr, replacement: replacement,
                                               strokes: strokes, terminator: terminator,
                                               isKey: isKey, language: curLang, isEnter: isEnter)
            }
            prev = (strokes, terminator, curLang)
            last = nil
            return false
        }
        guard !store.rules.blocks(currentCore, lang: curLang, kind: .layout) else {
            prev = (strokes, terminator, curLang)
            last = nil
            return false
        }
        if settings.cautiousMode && plan.decision.reason == "ngram" {
            prev = !isEnter && plan.suffix.isEmpty ? (strokes, terminator, curLang) : nil
            last = nil
            if prev != nil { DispatchQueue.main.async { [weak self] in self?.onSuggestion?() } }
            return false
        }

        // Pull a short previous word along ("z ghbdtn" -> "я привет").
        var deleteCount = strokes.count
        var newText = plan.alternativeWord + plan.suffix
        var originalText = curStr
        if plan.suffix.isEmpty, let p = prev, p.lang == curLang, p.terminator.keyCode == 49, p.strokes.count <= 3 {
            let pc = layouts.string(p.strokes, layout: cur.layout)
            let pa = layouts.string(p.strokes, in: target)
            if !store.rules.blocks(pc, lang: curLang, kind: .layout),
               classifier.shouldRetroFix(current: pc, alternative: pa, currentLang: curLang) {
                deleteCount += p.strokes.count + 1
                newText = pa + " " + plan.alternativeWord
                originalText = pc + " " + curStr
            }
        }

        var actions: [Typer.Action] = [.backspace(deleteCount), .text(newText)]
        actions.append(terminatorAction(terminator, isKey: isKey, lang: curLang))
        perform(actions) { [weak self] in
            guard let self, self.isRunning else { return }
            self.layouts.select(target)
            self.bumpStats()
            self.onCorrection?(plan.currentWord, plan.alternativeWord)
        }

        last = isEnter ? nil : Correction(
            typedText: newText, originalText: originalText, terminator: terminator, terminatorIsKey: isKey,
            from: curLang, to: target, originalWord: currentCore, kind: .layout)
        prev = isEnter || !plan.suffix.isEmpty ? nil : (strokes, terminator, target)
        return true
    }

    func applySpellingCorrection(original: String, replacement: String, strokes: [Stroke],
                                         terminator: Stroke, isKey: Bool, language: Lang,
                                         isEnter: Bool) -> Bool {
        perform([.backspace(strokes.count), .text(replacement),
                 terminatorAction(terminator, isKey: isKey, lang: language)]) { [weak self] in
            guard let self, self.isRunning else { return }
            self.bumpStats()
            self.onCorrection?(original, replacement)
        }
        last = isEnter ? nil : Correction(
            typedText: replacement, originalText: original, terminator: terminator,
            terminatorIsKey: isKey, from: language, to: language,
            originalWord: normalizeWord(original), kind: .spell)
        prev = nil
        return true
    }

    private func terminatorAction(_ t: Stroke, isKey: Bool, lang: Lang) -> Typer.Action {
        if isKey { return .key(t.keyCode, t.shift ? CGEventFlags.maskShift : []) }
        return .text(layouts.character(t, in: lang))
    }

    func perform(_ actions: [Typer.Action], onSuccess: (() -> Void)? = nil) {
        typingRunID &+= 1
        let runID = typingRunID
        let pid = frontmostPID()
        typingPID = pid
        busy = true
        typer.updateFrontmostPID(pid)
        typer.run(actions, targetPID: pid) { [weak self] finished in
            guard let self, self.typingRunID == runID else { return }
            guard let pid, self.frontmostPID() == pid else {
                self.cancelPendingTyping()
                return
            }
            if finished {
                onSuccess?()
                // Success callbacks may themselves invalidate the context or stop the tap.
                guard self.typingRunID == runID else { return }
                let replay = self.pendingInput
                self.pendingInput.removeAll()
                // Replayed events bypass tracking. New key-downs (text, shortcuts or
                // navigation) and Caps Lock toggles stale the caret/text context;
                // key-ups and momentary modifiers alone do not invalidate undo/prev.
                if replay.contains(where: { $0.type == .keyDown ||
                    ($0.type == .flagsChanged && $0.getIntegerValueField(.keyboardEventKeycode) == 57)
                }) { self.resetAll() }
                for event in replay {
                    guard self.typingRunID == runID, self.frontmostPID() == pid else {
                        self.cancelPendingTyping()
                        return
                    }
                    self.typer.replay(event)
                }
            } else {
                self.pendingInput.removeAll()
                self.resetAll()
            }
            self.busy = false
        }
    }

    private func bumpStats() {
        let today = Calendar.current.startOfDay(for: Date())
        if today != statsDay { statsDay = today; correctionsToday = 0 }
        correctionsToday += 1
        if settings.sound { NSSound(named: "Tink")?.play() }
    }

    // MARK: - Manual fix (tap Right Option)

    /// 1) right after an auto-fix → undo it and remember the word;
    /// 2) in the middle of a word → convert it;
    /// 3) right after a word + space → convert that word;
    /// otherwise, offer a correction for the word at the caret. Selection conversion uses ⌃⌥R.
    func manualFix() {
        guard !busy else { return }
        guard !settings.isExcluded(frontmostBundleID) else { resetAll(); return }
        if let c = last {
            last = nil
            var actions: [Typer.Action] = [.backspace(c.typedText.count + 1), .text(c.originalText)]
            actions.append(terminatorAction(c.terminator, isKey: c.terminatorIsKey, lang: c.from))
            perform(actions) { [weak self] in
                guard let self else { return }
                self.layouts.select(c.from)
                self.store.addRule(c.originalWord, lang: c.from, kind: c.kind,
                                   result: c.typedText, source: .undo)
            }
            prev = nil
            return
        }
        guard let curLang = layouts.currentLang else { return }
        let target = curLang.other
        if !word.isEmpty {
            let alt = layouts.string(word, in: target)
            perform([.backspace(word.count), .text(alt)]) { [weak self] in
                self?.layouts.select(target)
                self?.learnPositive(alt, lang: target)
            }
            return
        }
        if let p = prev, p.lang == curLang {
            let alt = layouts.string(p.strokes, in: target)
            let isKey = [49, 36, 76, 48].contains(p.terminator.keyCode) || (65...92).contains(p.terminator.keyCode)
            if p.terminator.keyCode == 36 || p.terminator.keyCode == 76 { return }
            perform([.backspace(p.strokes.count + 1), .text(alt), terminatorAction(p.terminator, isKey: isKey, lang: curLang)]) { [weak self] in
                self?.layouts.select(target)
                self?.learnPositive(alt, lang: target)
            }
            prev = (p.strokes, p.terminator, target)
            return
        }
        onManualFixAtCaret?()
    }

    private func learnPositive(_ text: String, lang: Lang) {
        guard let m = classifier?.models[lang] else { return }
        let w = m.core(normalizeWord(text))
        guard m.isWord(w), w.count >= 2 else { return }
        store.learn(w, lang: lang)
        classifier?.learn(w, lang: lang)
    }
}
