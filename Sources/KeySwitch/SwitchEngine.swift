import AppKit
import CoreGraphics
import Foundation

enum Hotkey: Equatable {
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
    private let settings: Settings
    private let frontmostPID: () -> pid_t?
    private let readFrontmostBundleID: (() -> String?)?
    private let protectedInput: () -> Bool
    private let verifyBackspaceUndo: ((String, pid_t) -> Bool)?
    /// macOS spell checker veto: a word it accepts is never changed automatically.
    private let acceptsSpelling: ((String, Lang) -> Bool)?
    private static let maxPendingEvents = 128
    private static let restoreWindow: TimeInterval = 90

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
    private var word: [Stroke] = []
    private var prev: (strokes: [Stroke], lang: Lang)?
    private var last: Correction?
    private var busy = false
    private var pendingInput: [(event: CGEvent, sourceID: String?)] = []
    private var requestedSourceID: String?
    private var pendingLateSourceID: String?
    private var pendingLateSourceUntil: TimeInterval = 0
    private var userRequestedInputSource = false
    private var idleActions: [() -> Void] = []
    private var typingPID: pid_t?
    private var typingStartedAt: TimeInterval = 0
    private var typingRunID: UInt64 = 0
    private var contextRevision: UInt64 = 0
    private var rightOptionDownAt: TimeInterval?
    private var rightOptionDirty = false
    private var untrackedToken = false
    private var tapDisables: [TimeInterval] = []
    private var restoreWatch: RestoreWatch?
    private(set) var lastAutoCorrection: RecentCorrection?
    /// Mouse clicks and keys since the last one: a click is trusted only if no key came after it.
    private(set) var clickRevision: UInt64 = 0
    private var keysSinceClick = 0
    private var backspacesSinceClick = 0
    /// The field after a click could not tell where its caret is (Electron, some web views):
    /// the first word is tracked, but only a confident whole-word layout fix is applied.
    private var clickUnverified = false
    /// A dead key ("'" on U.S. International) arrives with no text; the next key carries both.
    private var pendingDeadKey: String?
    typealias RecentCorrection = CorrectionRecord
    /// Every replacement KeySwitch made, newest per word, stored in corrections.json.
    var recentCorrections: [RecentCorrection] { store.corrections.values.sorted { $0.date < $1.date } }

    /// After an automatic change: the user erases it and types the same original word again.
    private struct RestoreWatch {
        let correction: RecentCorrection
        var erased = 0
    }

    private struct Correction {
        let typedText: String       // what we typed instead
        let originalText: String    // what the user had typed
        let from: Lang
        let originalWord: String    // the main word (for learning on undo)
        let kind: FixKind
    }

    init(layouts: KeyboardLayouts, store: UserStore, typer: Typer = Typer(), settings: Settings = .shared,
         frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         readFrontmostBundleID: (() -> String?)? = nil,
         protectedInput: @escaping () -> Bool = { SecureInput.isEnabled },
         verifyBackspaceUndo: ((String, pid_t) -> Bool)? = nil,
         acceptsSpelling: ((String, Lang) -> Bool)? = nil) {
        self.layouts = layouts
        self.store = store
        self.typer = typer
        self.settings = settings
        self.frontmostPID = frontmostPID
        self.readFrontmostBundleID = readFrontmostBundleID
        self.protectedInput = protectedInput
        self.verifyBackspaceUndo = verifyBackspaceUndo
        self.acceptsSpelling = acceptsSpelling
    }

    // MARK: - Tap lifecycle

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var isTyping: Bool { busy }
    /// Keystrokes of the word being typed (for tests and diagnostics).
    var trackedWordLength: Int { word.count }

    @discardableResult
    func start() -> Bool {
        if tap != nil {
            if isRunning { return true }
            stop()
        }
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
        ) else {
            KeyboardDiagnostics.record(.tapFailed)
            return false
        }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            KeyboardDiagnostics.record(.tapFailed)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = src
        guard isRunning else { stop(); return false }
        KeyboardDiagnostics.record(.tapStarted)
        return true
    }

    func stop() {
        contextRevision &+= 1
        typingRunID &+= 1
        typer.cancel()
        pendingInput.removeAll()
        requestedSourceID = nil
        pendingLateSourceID = nil
        pendingLateSourceUntil = 0
        idleActions.removeAll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        busy = false
        rightOptionDownAt = nil
        rightOptionDirty = false
        restoreWatch = nil
        lastAutoCorrection = nil
        resetAll()
    }

    func resetAll() {
        word = []
        prev = nil
        last = nil
        untrackedToken = false
        clickUnverified = false
    }

    func cancelPendingTyping() {
        contextRevision &+= 1
        typingRunID &+= 1
        typer.cancel()
        pendingInput.removeAll()
        requestedSourceID = nil
        pendingLateSourceID = nil
        pendingLateSourceUntil = 0
        idleActions.removeAll()
        busy = false
        rightOptionDownAt = nil
        rightOptionDirty = false
        restoreWatch = nil
        resetAll()
    }

    func updateFrontmostApp(bundleID: String?, pid: pid_t?) {
        if bundleID != frontmostBundleID {
            frontmostBundleID = bundleID
            lastAutoCorrection = nil
            cancelPendingTyping()
        }
        typer.updateFrontmostPID(pid)
    }

    /// Selects a layout on behalf of KeySwitch UI actions (caret fix, selection flip, menu)
    /// so the asynchronous TIS notification is recognized as our own rather than an external switch.
    @discardableResult
    func selectInputSource(_ language: Lang) -> Bool {
        guard let target = layouts.preferred[language] else { return false }
        if layouts.current().id == target.id {
            layouts.confirmSelection(target.id)
            return true
        }
        requestedSourceID = target.id
        guard layouts.select(language) else {
            requestedSourceID = nil
            return false
        }
        let expectedID = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.busy, self.requestedSourceID == expectedID else { return }
            self.requestedSourceID = nil
        }
        return true
    }

    /// Check from the tap as well as the asynchronous TIS notifications.
    /// A layout change during a word makes its suffix unsafe to rewrite in isolation.
    @discardableResult
    func inputSourceDidChange(to id: String) -> Bool {
        if id == requestedSourceID {
            if !busy { requestedSourceID = nil }
            pendingLateSourceID = nil
            layouts.confirmSelection(id)
            return false
        }
        if !busy, let late = pendingLateSourceID {
            pendingLateSourceID = nil
            if id == late, ProcessInfo.processInfo.systemUptime <= pendingLateSourceUntil, word.isEmpty {
                layouts.confirmSelection(id)
                return false
            }
        }
        guard layouts.observeInputSource(id) else { return false }
        let hadUnfinishedWord = untrackedToken || !word.isEmpty
        KeyboardDiagnostics.decision(.wordDropped, "external-source-change unfinished=\(hadUnfinishedWord) busy=\(busy)")
        if busy {
            // Keep physical keys already held for this process. Cancel the edit and let
            // its completion release them, without trying to select the old layout.
            requestedSourceID = nil
            typer.cancel()
        }
        contextRevision &+= 1
        rightOptionDownAt = nil
        resetAll()
        untrackedToken = hadUnfinishedWord
        return true
    }

    private func disregardWord() {
        resetAll()
        untrackedToken = true
    }

    // MARK: - Event handling

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByUserInput {
            stop()
            KeyboardDiagnostics.record(.tapDisabled)
            onTapStopped?("Перехват клавиш остановлен. Возобновите его из меню.")
            return pass
        }
        if type == .tapDisabledByTimeout {
            KeyboardDiagnostics.record(.tapTimedOut)
            // Invalidate now: a rewrite completion may already be queued on main.
            cancelPendingTyping()
            // A single slow moment (sleep, a busy main thread) should not turn KeySwitch off
            // for good: re-enable the tap. Only a tap that keeps timing out is left off.
            let now = ProcessInfo.processInfo.systemUptime
            tapDisables = tapDisables.filter { now - $0 < 60 } + [now]
            if let tap, tapDisables.count <= 3 {
                CGEvent.tapEnable(tap: tap, enable: true)
                return pass
            }
            stop()
            onTapStopped?("Перехват клавиш отключён системой. Запустите его снова из меню.")
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Typer.marker { return pass }
        if type == .keyDown, [36, 76, 49].contains(event.getIntegerValueField(.keyboardEventKeycode)) {
            let mods = event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn])
            KeyboardDiagnostics.decision(.wordFinished, "terminator=\(event.getIntegerValueField(.keyboardEventKeycode)) word=\(word.count) untracked=\(untrackedToken) busy=\(busy) secure=\(protectedInput()) excluded=\(settings.isExcluded(frontmostBundleID)) app=\(frontmostBundleID ?? "nil") lang=\(layouts.current().lang?.rawValue ?? "nil") mods=\(String(mods.rawValue, radix: 16))")
        }
        if protectedInput() {
            lastAutoCorrection = nil
            if busy || !word.isEmpty || prev != nil || last != nil || rightOptionDownAt != nil {
                cancelPendingTyping()
            }
            return pass
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            if let readFrontmostBundleID {
                let activeBundle = readFrontmostBundleID()
                if activeBundle != frontmostBundleID {
                    frontmostBundleID = activeBundle
                    lastAutoCorrection = nil
                }
            }
            cancelPendingTyping()
            disregardWord()
            clickRevision &+= 1
            keysSinceClick = 0
            backspacesSinceClick = 0
            return pass
        }
        if frontmostBundleID == nil, let readFrontmostBundleID {
            frontmostBundleID = readFrontmostBundleID()
        }

        if busy, frontmostPID() != typingPID {
            cancelPendingTyping()
            return pass
        }
        if busy, type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == 63 {
            // The Globe key is an OS gesture. A PID-targeted replay cannot replace it.
            userRequestedInputSource = true
            return pass
        }
        if busy, type == .keyDown || type == .keyUp || type == .flagsChanged {
            // Do not abandon a destructive rewrite halfway through. Hold *all* physical
            // keyboard events, including modifier releases and key-ups, in arrival order.
            if pendingInput.count < Self.maxPendingEvents, let copy = event.copy() {
                pendingInput.append((copy, type == .keyDown ? layouts.current().id : nil))
                return nil
            }
            // Abort rather than hold the keyboard indefinitely. Release held input only
            // to the still-active target, without feeding it back to the classifier.
            let pending = pendingInput
            let pid = typingPID
            KeyboardDiagnostics.record(.queueLimit, buffered: pending.count)
            cancelPendingTyping()
            disregardWord()
            if let pid, frontmostPID() == pid {
                for held in pending { typer.replay(held.event, to: pid) }
            }
            return pass
        }

        switch type {
        case .flagsChanged:
            contextRevision &+= 1
            typer.cancel()
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 57 || code == 63 { // Caps Lock may also change the input source.
                if word.isEmpty && !untrackedToken { resetAll() } else { disregardWord() }
            }
            handleFlags(event)
            return pass
        case .keyDown:
            contextRevision &+= 1
            keysSinceClick += 1
            typer.cancel()
            let deadKey = pendingDeadKey
            pendingDeadKey = nil
            return handleKeyDown(event, afterDeadKey: deadKey)
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
            let held = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
            // Quartz sets side-specific Option bits on hardware events. With both Option
            // keys in use, the aggregate mask alone cannot identify the right release.
            let side = event.flags.rawValue & 0x60
            let rightHeld = side == 0 ? held.contains(.maskAlternate) : side & 0x40 != 0
            if rightHeld {
                rightOptionDownAt = ProcessInfo.processInfo.systemUptime
                rightOptionDirty = held != .maskAlternate || side == 0x60
            } else if let started = rightOptionDownAt {
                rightOptionDownAt = nil
                if held.isEmpty, !rightOptionDirty, ProcessInfo.processInfo.systemUptime - started < 0.5 {
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

    /// A click put the caret between words (checked through Accessibility after the click):
    /// the next word is a new word, so track it as if the user had typed a space.
    func caretVerifiedAtBoundary(clickRevision revision: UInt64) {
        guard revision == clickRevision, keysSinceClick == 0, word.isEmpty, untrackedToken, !busy else { return }
        KeyboardDiagnostics.decision(.wordFinished, "click at word boundary")
        resetAll()
    }

    /// Accessibility could not read the caret after a click (no answer, not "mid-word").
    /// Usually an empty chat box in an Electron app: track the first word cautiously.
    func caretUnreadableAfterClick(clickRevision revision: UInt64) {
        guard revision == clickRevision, keysSinceClick == 0, word.isEmpty, untrackedToken, !busy else { return }
        KeyboardDiagnostics.decision(.wordFinished, "click caret unreadable")
        resetAll()
        clickUnverified = true
    }

    /// Accessibility confirmed that a click landed next to the just-replaced word:
    /// if the user erases it and retypes their original word, record an exception.
    func armRestoreWatchAfterClick(clickRevision revision: UInt64) {
        guard revision == clickRevision, !busy, let c = lastAutoCorrection,
              Date().timeIntervalSince(c.date) < Self.restoreWindow else { return }
        let erased = backspacesSinceClick
        restoreWatch = RestoreWatch(correction: c, erased: erased)
        if erased >= c.replacement.count, word.isEmpty {
            untrackedToken = false
        }
    }

    private func handleKeyDown(_ event: CGEvent, afterDeadKey deadKey: String? = nil) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if onSuggestionKey?(code, flags) == true { return nil }
        if rightOptionDownAt != nil { rightOptionDirty = true }

        // Global hotkeys: ⌃⌥ + key
        if flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn])
            == [.maskControl, .maskAlternate], let hk = Hotkey(keyCode: code) {
            if hk == .flipSelection && settings.isExcluded(frontmostBundleID) { return pass }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            let appID = frontmostBundleID
            let pid = frontmostPID()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.protectedInput(), self.frontmostBundleID == appID,
                      self.frontmostPID() == pid else { return }
                self.onHotkey?(hk)
            }
            return nil
        }
        // ⌥⌫ (delete word) and ⌘⌫ (delete line) erase to a boundary, so the next word is safe to track.
        if code == 51, !flags.contains(.maskControl), !flags.contains(.maskSecondaryFn),
           flags.contains(.maskAlternate) || flags.contains(.maskCommand) {
            let savedWatch = restoreWatch
            resetAll()
            if var watch = savedWatch {
                watch.erased += 32
                restoreWatch = watch
            }
            backspacesSinceClick += 16
            return pass
        }
        // Any shortcut or Option-character breaks the word.
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
            // Arrows/Home/End arrive with Fn; ⌘ shortcuts can move the caret or edit text.
            // Either way a retyped word is no longer known to replace the corrected one.
            // (⌃Space and other layout shortcuts keep the watch.)
            if flags.contains(.maskCommand) || (115...126).contains(code) { restoreWatch = nil }
            if word.isEmpty && !untrackedToken { resetAll() } else { disregardWord() }
            return pass
        }
        if settings.isExcluded(frontmostBundleID) {
            resetAll()
            return pass
        }

        let source = layouts.current()
        inputSourceDidChange(to: source.id)
        let keyboardType = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeyboardType))
        let stroke = Stroke(keyCode: code, shift: flags.contains(.maskShift),
                            caps: flags.contains(.maskAlphaShift), keyboardType: keyboardType == 0 ? nil : keyboardType)
        switch code {
        case 51: // Delete (backspace)
            if !flags.contains(.maskShift), event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               beginBackspaceUndo(event) { return nil }
            backspacesSinceClick += 1
            restoreWatch?.erased += 1
            if !word.isEmpty {
                word.removeLast()
            } else if let p = prev, p.lang == source.lang {
                word = p.strokes
                prev = nil
            } else {
                prev = nil
            }
            if word.isEmpty, let watch = restoreWatch, watch.erased >= watch.correction.replacement.count {
                untrackedToken = false
            }
            last = nil
            return pass
        case 48: // Tab can land in an existing word in another field.
            restoreWatch = nil
            disregardWord()
            return pass
        case 36, 76: // Return (and Shift+Return): fix the word's layout first, then send Return itself.
            // Typos are never fixed here: Return can submit a message with an unchecked replacement.
            guard !untrackedToken, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                if untrackedToken { KeyboardDiagnostics.decision(.wordDropped, "return untracked") }
                restoreWatch = nil
                resetAll()
                return pass
            }
            let fixed = finishWord(source: source, terminator: .key(code, flags.intersection(.maskShift)),
                                   allowSpelling: InputPolicy.allowsAutomaticSpelling(terminator: code))
            // After Return the text may be sent: no retype-undo and no context from the previous line.
            restoreWatch = nil
            lastAutoCorrection = nil
            resetAll()
            return fixed ? nil : pass
        case 49: // Space (including lingering Shift during fast typing) triggers automatic rewriting.
            if untrackedToken {
                KeyboardDiagnostics.decision(.wordDropped, "space untracked")
                resetAll(); return pass
            }
            return finishWord(source: source) ? nil : pass
        case 65...92: // A keypad digit/operator may be part of a single token.
            disregardWord()
            return pass
        case 0...50:
            break
        case 53: // Escape dismisses selection/UI state.
            resetAll()
            return pass
        default: // arrows, Home/End, forward delete…
            restoreWatch = nil
            disregardWord()
            return pass
        }

        guard !untrackedToken else { return pass }
        guard let language = source.lang else { disregardWord(); return pass }
        let current = layouts.character(stroke, layout: source.layout)
        let alternative = layouts.character(stroke, in: language.other)
        let delivered = Self.unicodeText(of: event)
        // After a dead key the text holds both characters ("'" + "n" = "'n"); an accented
        // composition ("'" + "e" = "é") is not the key's letter and drops the word as before.
        let composedWithDeadKey = deadKey.map { delivered == $0 + current } ?? false
        if delivered.isEmpty, current.count == 1, current.first?.isLetter == false, !untrackedToken {
            pendingDeadKey = current
        }
        guard current.count == 1, delivered.isEmpty || delivered == current || composedWithDeadKey else {
            KeyboardDiagnostics.decision(.wordDropped, current.count == 1 ? "char-mismatch" : "no-char")
            disregardWord()
            return pass
        }
        // On some layouts the same key represents punctuation or a letter. Keep
        // it as part of the word when the other layout supplies a letter.
        let otherIsLetter = alternative.first?.isLetter == true
        if InputPolicy.beginsStructuredToken(current) &&
            (!otherIsLetter || InputPolicy.structuredEvenIfAlternativeIsLetter(current)) {
            disregardWord()
            return pass
        }
        let letterish = current.first?.isLetter == true || otherIsLetter || current == "'" || current == "-"
        let trailingPunctuation = !word.isEmpty && current.first?.isPunctuation == true
        if letterish || trailingPunctuation {
            if word.isEmpty && current == "-" { return pass }
            guard word.count < 64 else { disregardWord(); return pass }
            word.append(stroke)
            last = nil
        } else {
            disregardWord()
        }
        return pass
    }

    private static func unicodeText(of event: CGEvent) -> String {
        var units = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        return String(decoding: units.prefix(length), as: UTF16.self)
    }

    /// Returns true when the terminator key is swallowed (we retype it ourselves after the fix).
    private func finishWord(source: KeyboardLayouts.Source, terminator: Typer.Action = .key(49, []),
                            allowSpelling: Bool = true) -> Bool {
        let strokes = word
        word = []
        let afterUnverifiedClick = clickUnverified
        clickUnverified = false
        guard !strokes.isEmpty else {
            prev = nil
            last = nil
            return false
        }
        // Keep one correction bounded even if a field contains a very long token.
        guard strokes.count <= InputPolicy.maxAutomaticWordLength, frontmostPID() != nil else {
            KeyboardDiagnostics.decision(.wordFinished, "skip long-or-no-app")
            prev = nil
            last = nil
            return false
        }
        let cur = source
        let mode = settings.applicationMode(for: frontmostBundleID)
        let layoutEnabled = mode.allowsAutomatic && settings.autoEnabled && layouts.hasBothLayouts
        // A word started after an unreadable click may be the tail of an existing word: no typo fixes.
        let canSpell = mode.allowsAutomatic && settings.spellEnabled && allowSpelling && !afterUnverifiedClick
        guard layoutEnabled || canSpell, let classifier, let curLang = cur.lang else {
            KeyboardDiagnostics.decision(.wordFinished, "skip disabled layout=\(layoutEnabled) classifier=\(classifier != nil)")
            if let l = cur.lang { prev = (strokes, l) }
            last = nil
            return false
        }
        let target = curLang.other
        let curStr = layouts.string(strokes, layout: cur.layout)
        let altStr = layouts.string(strokes, in: target)
        guard curStr.count == strokes.count else {
            KeyboardDiagnostics.decision(.wordFinished, "skip length")
            prev = nil
            last = nil
            return false
        }
        // The user typed this word themselves: an older replacement with the same text is now ambiguous.
        store.removeCorrection(producing: curStr)
        if let watch = restoreWatch {
            restoreWatch = nil
            let c = watch.correction
            let typed = classifier.models[curLang]?.core(normalizeWord(curStr)) ?? normalizeWord(curStr)
            // The user erased the replacement and typed their own word again: respect it from now on.
            if curLang == c.lang, typed == c.originalWord, watch.erased >= c.replacement.count,
               Date().timeIntervalSince(c.date) < Self.restoreWindow {
                KeyboardDiagnostics.decision(.wordFinished, "restore")
                remember(c, source: .restore)
                prev = (strokes, curLang)
                last = nil
                return false
            }
        }
        let canSwitch = layoutEnabled && altStr.count == strokes.count
        let cautious = mode.isCautious(defaultValue: settings.cautiousMode)
        var contextLang: Lang?
        if canSwitch, let p = prev, p.lang == curLang, p.strokes.count <= 16 {
            let pc = layouts.string(p.strokes, layout: cur.layout)
            let pa = layouts.string(p.strokes, in: target)
            if pc.count == p.strokes.count, pa.count == p.strokes.count,
               !store.rules.blocks(pc, lang: curLang, kind: .layout),
               classifier.leansTowardOther(current: pc, alternative: pa, currentLang: curLang) {
                contextLang = target
            }
        }
        var plan = classifier.plan(current: curStr, alternative: altStr, currentLang: curLang, contextLang: contextLang)
        if canSwitch, canSpell, let fixed = AutomaticCorrection.layoutWithSpelling(plan, currentLang: curLang,
                                                                                 classifier: classifier, rules: store.rules) {
            plan = fixed
        }
        if InputPolicy.blocksAutomaticCorrection(curStr, plan: plan) {
            KeyboardDiagnostics.decision(.wordFinished, "blocked \(plan.decision.reason)")
            prev = nil
            last = nil
            return false
        }
        let currentCore = classifier.models[curLang]?.core(normalizeWord(plan.currentWord)) ?? normalizeWord(plan.currentWord)
        // Neither dictionary knows the word, but macOS does ("сверю", "задеплою" aside): keep it.
        let systemKeeps = ["ngram", "other-typo", "freq"].contains(plan.decision.reason) && systemAccepts(currentCore, curLang)
        let layoutAllowed = canSwitch && plan.decision.convert && !systemKeeps
            && !store.rules.blocks(currentCore, lang: curLang, kind: .layout)
        let needsConfirmation = (cautious && !plan.decision.confident)
            || (afterUnverifiedClick && (!plan.decision.confident || plan.currentWord.count < 3))
        KeyboardDiagnostics.decision(.wordFinished, "\(layoutAllowed && !needsConfirmation ? "fix" : "keep") reason=\(plan.decision.reason) convert=\(plan.decision.convert) confident=\(plan.decision.confident) cautious=\(cautious) system=\(systemKeeps) canSwitch=\(canSwitch)")
        guard layoutAllowed, !needsConfirmation else {
            if canSpell, curStr.count == strokes.count,
               let model = classifier.models[curLang],
               let fix = AutomaticCorrection.spelling(current: curStr, alternative: altStr, model: model,
                                                       other: classifier.models[target], rules: store.rules),
               fix.kind != .spell || !systemAccepts(fix.word, curLang) {
                return applySpellingCorrection(original: curStr, replacement: fix.text,
                                               language: curLang, kind: fix.kind, word: fix.word)
            }
            prev = (strokes, curLang)
            last = nil
            if layoutAllowed {
                if plan.prefix.isEmpty && plan.suffix.isEmpty {
                    let revision = contextRevision
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.contextRevision == revision else { return }
                        self.onSuggestion?()
                    }
                } else { prev = nil }
            }
            return false
        }

        // Pull a previous word along ("z ghbdtn." -> "я привет.", "dj dctv" -> "во всем").
        var newText = plan.prefix + plan.alternativeWord + plan.suffix
        var originalText = curStr
        var retroPair: (replacement: String, original: String, core: String)?
        if plan.prefix.isEmpty, let p = prev, p.lang == curLang, p.strokes.count <= 16 {
            let pc = layouts.string(p.strokes, layout: cur.layout)
            let pa = layouts.string(p.strokes, in: target)
            // Cautious mode pulls a short word along ("ns uhe,sq" → "ты группа") only when the
            // classifier converts it on its own; the confident fix of this word removes the doubt.
            if pc.count == p.strokes.count, pa.count == p.strokes.count,
               !store.rules.blocks(pc, lang: curLang, kind: .layout),
               cautious ? classifier.decide(current: pc, alternative: pa, currentLang: curLang).convert
                        : classifier.shouldRetroFix(current: pc, alternative: pa, currentLang: curLang) {
                newText = pa + " " + plan.alternativeWord + plan.suffix
                originalText = pc + " " + curStr
                let prevCore = classifier.models[curLang]?.core(normalizeWord(pc)) ?? normalizeWord(pc)
                retroPair = (pa, pc, prevCore.isEmpty ? normalizeWord(pc) : prevCore)
            }
        }

        var actions = replacementActions(original: originalText, replacement: newText)
        actions.append(terminator)
        perform(actions, switchingTo: target) { [weak self] in
            guard let self, self.isRunning else { return }
            self.bumpStats()
            self.onCorrection?(plan.currentWord, plan.alternativeWord)
        }

        last = Correction(typedText: newText, originalText: originalText,
                          from: curLang, originalWord: currentCore, kind: .layout)
        if let retroPair {
            record(replacement: retroPair.replacement, original: retroPair.original, lang: curLang,
                   originalWord: retroPair.core, kind: .layout, watchRestore: false)
        }
        record(replacement: plan.alternativeWord, original: plan.currentWord, lang: curLang,
               originalWord: currentCore, kind: .layout, watchRestore: true)
        prev = plan.alternativeWord == altStr ? (strokes, target) : nil
        return true
    }

    func applySpellingCorrection(original: String, replacement: String, language: Lang,
                                 kind: FixKind = .spell, word: String? = nil) -> Bool {
        let actions = replacementActions(original: original, replacement: replacement)
        perform(actions + [.key(49, [])]) { [weak self] in
            guard let self, self.isRunning else { return }
            self.bumpStats()
            self.onCorrection?(original, replacement)
        }
        last = Correction(typedText: replacement, originalText: original, from: language,
                          originalWord: word ?? normalizeWord(original), kind: kind)
        record(replacement: replacement, original: original, lang: language,
               originalWord: word ?? normalizeWord(original), kind: kind, watchRestore: true)
        prev = nil
        return true
    }

    // MARK: - Recent corrections

    private func systemAccepts(_ word: String, _ lang: Lang) -> Bool {
        // Short tokens are often abbreviations the checker knows ("nj", "ds"): too weak a signal.
        guard word.count >= 4, let acceptsSpelling else { return false }
        return acceptsSpelling(word, lang)
    }

    static func stripSharedEdgePunctuation(original: String, replacement: String) -> (original: String, replacement: String) {
        var orig = Array(original)
        var repl = Array(replacement)
        while let o = orig.first, let r = repl.first, o == r, !o.isLetter {
            orig.removeFirst()
            repl.removeFirst()
        }
        while let o = orig.last, let r = repl.last, o == r, !o.isLetter {
            orig.removeLast()
            repl.removeLast()
        }
        guard !orig.isEmpty, !repl.isEmpty else { return (original, replacement) }
        return (String(orig), String(repl))
    }

    /// Remembers a replacement so a later return to the word can revert it.
    func record(replacement: String, original: String, lang: Lang, originalWord: String? = nil,
                kind: FixKind, automatic: Bool = true, watchRestore: Bool = false) {
        let stripped = Self.stripSharedEdgePunctuation(original: original, replacement: replacement)
        guard stripped.replacement != stripped.original, !stripped.replacement.isEmpty, !stripped.original.isEmpty else { return }
        let rawCore = originalWord ?? (classifier?.models[lang]?.core(normalizeWord(stripped.original)) ?? normalizeWord(stripped.original))
        let entry = RecentCorrection(replacement: stripped.replacement, original: stripped.original, lang: lang,
                                     originalWord: rawCore.isEmpty ? normalizeWord(stripped.original) : rawCore,
                                     kind: kind, automatic: automatic, date: Date())
        store.recordCorrection(entry)
        if watchRestore {
            restoreWatch = RestoreWatch(correction: entry)
            lastAutoCorrection = entry
        } else {
            restoreWatch = nil
        }
    }

    /// The most recent replacement that produced `text` (case and ё-insensitive).
    func recentCorrection(producing text: String) -> RecentCorrection? {
        store.correction(producing: text)
    }

    /// The user reverted `c`: forget it and, for an automatic change, never repeat it.
    func remember(_ c: RecentCorrection, source: RuleSource) {
        if store.correction(producing: c.replacement) == c { store.removeCorrection(producing: c.replacement) }
        if case .some(let watch) = restoreWatch, watch.correction == c { restoreWatch = nil }
        if lastAutoCorrection == c { lastAutoCorrection = nil }
        guard c.automatic else { return }
        store.addRule(c.originalWord, lang: c.lang, kind: c.kind, result: c.replacement, source: source)
    }

    private func replacementActions(original: String, replacement: String) -> [Typer.Action] {
        let matchingPrefix = zip(original, replacement).prefix(while: { $0.0 == $0.1 }).count
        return [.backspace(original.count - matchingPrefix), .text(String(replacement.dropFirst(matchingPrefix)))]
    }

    func perform(_ actions: [Typer.Action], switchingTo language: Lang? = nil, onSuccess: (() -> Void)? = nil) {
        typingRunID &+= 1
        let runID = typingRunID
        let pid = frontmostPID()
        let originalSourceID = layouts.current().id
        userRequestedInputSource = false
        typingPID = pid
        typingStartedAt = ProcessInfo.processInfo.systemUptime
        busy = true
        typer.updateFrontmostPID(pid)
        typer.run(actions, targetPID: pid) { [weak self] finished in
            guard let self, self.typingRunID == runID else { return }
            guard let pid, self.frontmostPID() == pid, self.typer.isTargetActive(pid) else {
                self.cancelPendingTyping()
                return
            }
            guard finished, !self.protectedInput() else {
                KeyboardDiagnostics.record(.rewriteCancelled)
                if !self.untrackedToken { self.resetAll() }
                self.finishTyping(to: pid, runID: runID)
                return
            }
            let originID = self.layouts.current().id
            guard originID == originalSourceID else {
                self.inputSourceDidChange(to: originID)
                self.finishTyping(to: pid, runID: runID)
                return
            }
            guard let language, !self.userRequestedInputSource else {
                if language != nil { self.disregardWord() }
                onSuccess?()
                self.finishTyping(to: pid, runID: runID)
                return
            }
            guard let target = self.layouts.preferred[language] else {
                self.resetAll()
                onSuccess?()
                self.finishTyping(to: pid, runID: runID)
                return
            }
            self.requestedSourceID = target.id
            guard self.layouts.select(language) else {
                KeyboardDiagnostics.record(.sourceUnconfirmed)
                if self.word.isEmpty { self.resetAll() } else { self.disregardWord() }
                onSuccess?()
                self.finishTyping(to: pid, runID: runID)
                return
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.20
            self.waitForInputSource(target.id, from: originID, until: deadline, pid: pid, runID: runID, onSuccess: onSuccess)
        }
    }

    private func waitForInputSource(_ targetID: String, from originID: String, until deadline: TimeInterval,
                                    pid: pid_t, runID: UInt64, onSuccess: (() -> Void)?) {
        guard typingRunID == runID else { return }
        guard !protectedInput(), frontmostPID() == pid, typer.isTargetActive(pid) else { cancelPendingTyping(); return }
        let currentID = layouts.current().id
        let didSwitch = !userRequestedInputSource && requestedSourceID == targetID && currentID == targetID
        if didSwitch {
            pendingLateSourceID = nil
            layouts.confirmSelection(currentID)
        } else if !userRequestedInputSource, requestedSourceID == targetID,
                  currentID == originID, ProcessInfo.processInfo.systemUptime < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                self?.waitForInputSource(targetID, from: originID, until: deadline,
                                         pid: pid, runID: runID, onSuccess: onSuccess)
            }
            return
        } else {
            KeyboardDiagnostics.record(.sourceUnconfirmed)
            if !userRequestedInputSource, currentID == originID {
                pendingLateSourceID = targetID
                pendingLateSourceUntil = ProcessInfo.processInfo.systemUptime + 0.35
            }
            if word.isEmpty { resetAll() } else { disregardWord() }
            _ = layouts.observeInputSource(currentID)
        }
        onSuccess?()
        finishTyping(to: pid, runID: runID, rebaseTo: didSwitch ? targetID : nil)
    }

    private func finishTyping(to pid: pid_t, runID: UInt64, rebaseTo sourceID: String? = nil) {
        guard typingRunID == runID else { return }
        requestedSourceID = nil
        busy = false
        KeyboardDiagnostics.record(.inputReleased,
                                   milliseconds: Int((ProcessInfo.processInfo.systemUptime - typingStartedAt) * 1_000),
                                   buffered: pendingInput.count)
        replayPendingInput(to: pid, runID: runID, rebaseTo: sourceID)
        runIdleActions()
    }

    func afterTyping(_ action: @escaping () -> Void) {
        if busy { idleActions.append(action) } else { action() }
    }

    private func runIdleActions() {
        guard !busy else { return }
        let actions = idleActions
        idleActions.removeAll()
        for action in actions { afterTyping(action) }
    }

    private func replayPendingInput(to pid: pid_t, runID: UInt64, rebaseTo sourceID: String?) {
        let replay = pendingInput
        pendingInput.removeAll()
        for (index, held) in replay.enumerated() {
            let event = held.event
            guard typingRunID == runID, frontmostPID() == pid, typer.isTargetActive(pid) else { cancelPendingTyping(); return }
            if let sourceID, let capturedSource = held.sourceID, capturedSource != sourceID,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
                let source = layouts.current()
                let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if source.id == sourceID, source.layout != nil, code <= 50, ![36, 48, 49].contains(code) {
                    let type = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeyboardType))
                    let stroke = Stroke(keyCode: code, shift: event.flags.contains(.maskShift),
                                        caps: event.flags.contains(.maskAlphaShift), keyboardType: type == 0 ? nil : type)
                    // The keystroke was held before macOS selected the new layout.
                    // Keep its native keycode and update only the stale Unicode payload.
                    let units = Array(layouts.character(stroke, layout: source.layout).utf16)
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                }
            }
            if handle(type: event.type, event: event) != nil { typer.replay(event, to: pid) }
            // A buffered delimiter can start another rewrite. Keep its following keys in order.
            if busy {
                pendingInput.append(contentsOf: replay.dropFirst(index + 1))
                return
            }
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
        guard !busy, !protectedInput() else { return }
        guard !settings.isExcluded(frontmostBundleID) else { resetAll(); return }
        let source = layouts.current()
        inputSourceDidChange(to: source.id)
        if let c = last {
            last = nil
            let actions: [Typer.Action] = [.backspace(c.typedText.count + 1), .text(c.originalText), .key(49, [])]
            restoreWatch = nil
            perform(actions, switchingTo: c.kind == .layout ? c.from : nil) { [weak self] in
                guard let self else { return }
                // The history keys words without edge punctuation ("привет." → "привет").
                let lastWord = c.typedText.split(separator: " ").last.map(String.init) ?? c.typedText
                let core = lastWord.trimmingCharacters(in: CharacterSet.letters.inverted)
                if let r = self.store.correction(producing: core), r.originalWord == c.originalWord {
                    self.store.removeCorrection(producing: r.replacement)
                }
                self.store.addRule(c.originalWord, lang: c.from, kind: c.kind,
                                   result: c.typedText, source: .undo)
            }
            prev = nil
            return
        }
        guard !untrackedToken, let curLang = source.lang, layouts.hasBothLayouts else {
            onManualFixAtCaret?()
            return
        }
        let target = curLang.other
        if !word.isEmpty {
            let alt = layouts.string(word, in: target)
            let original = layouts.string(word, layout: source.layout)
            guard original.count == word.count, alt.count == word.count, original != alt else { return }
            let learn = shouldLearnManualFlip(original: original, from: curLang, alternative: alt, to: target)
            record(replacement: alt, original: original, lang: curLang, kind: .layout, automatic: false)
            perform([.backspace(word.count), .text(alt)], switchingTo: target) { [weak self] in
                if learn { self?.learnPositive(alt, lang: target) }
            }
            return
        }
        if let p = prev, p.lang == curLang {
            let alt = layouts.string(p.strokes, in: target)
            let original = layouts.string(p.strokes, layout: source.layout)
            guard original.count == p.strokes.count, alt.count == p.strokes.count, original != alt else { return }
            let learn = shouldLearnManualFlip(original: original, from: curLang, alternative: alt, to: target)
            record(replacement: alt, original: original, lang: curLang, kind: .layout, automatic: false)
            perform([.backspace(p.strokes.count + 1), .text(alt), .key(49, [])], switchingTo: target) { [weak self] in
                if learn { self?.learnPositive(alt, lang: target) }
            }
            prev = (p.strokes, target)
            return
        }
        onManualFixAtCaret?()
    }

    /// A physical Backspace changes into a reversal only if AX confirms that
    /// the caret still follows exactly the inserted text and its delimiter.
    private func beginBackspaceUndo(_ event: CGEvent) -> Bool {
        guard let verifyBackspaceUndo, let correction = last, let pid = frontmostPID(),
              let held = event.copy() else { return false }
        let suffix = correction.typedText + " "
        userRequestedInputSource = false
        typingRunID &+= 1
        let runID = typingRunID
        typingPID = pid
        typingStartedAt = ProcessInfo.processInfo.systemUptime
        typer.updateFrontmostPID(pid)
        busy = true
        let deadline = DispatchTime.now() + .milliseconds(45)

        func complete(_ verified: Bool) {
            guard busy, typingRunID == runID else { return }
            guard !protectedInput(), frontmostPID() == pid, typer.isTargetActive(pid) else {
                cancelPendingTyping()
                return
            }
            if verified, !userRequestedInputSource, DispatchTime.now() < deadline {
                KeyboardDiagnostics.record(.undoVerified)
                disregardWord()
                perform(replacementActions(original: suffix, replacement: correction.originalText),
                        switchingTo: correction.kind == .layout ? correction.from : nil)
            } else {
                KeyboardDiagnostics.record(.undoDeclined)
                disregardWord()
                typer.replay(held, to: pid)
                finishTyping(to: pid, runID: runID)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: deadline) { complete(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            let verified = verifyBackspaceUndo(suffix, pid)
            DispatchQueue.main.async { complete(verified) }
        }
        return true
    }

    /// Flipping a real word away (an accidental tap) must not teach its gibberish reading,
    /// while flipping rare dictionary junk ("ns" -> "ты") still learns when the other layout wins.
    private func shouldLearnManualFlip(original: String, from curLang: Lang, alternative: String, to target: Lang) -> Bool {
        guard let classifier, let curModel = classifier.models[curLang] else { return true }
        let origCore = curModel.core(normalizeWord(original))
        guard let origScore = curModel.score(origCore) else { return true }
        return origScore < 5.0 && classifier.leansTowardOther(current: original, alternative: alternative, currentLang: curLang)
    }

    func learnPositive(_ text: String, lang: Lang) {
        guard let m = classifier?.models[lang] else { return }
        let w = m.core(normalizeWord(text))
        guard m.isWord(w), w.count >= 2 else { return }
        store.learn(w, lang: lang)
        classifier?.learn(w, lang: lang)
    }
}
