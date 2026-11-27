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
    return engine.handle(type: type, event: event) { $0.tapPostEvent(proxy) }
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
    private static let maxPendingEvents = 128

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
    private var pendingBackspace: CGEvent?
    private var requestedSourceID: String?
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
         verifyBackspaceUndo: ((String, pid_t) -> Bool)? = nil) {
        self.layouts = layouts
        self.store = store
        self.typer = typer
        self.settings = settings
        self.frontmostPID = frontmostPID
        self.readFrontmostBundleID = readFrontmostBundleID
        self.protectedInput = protectedInput
        self.verifyBackspaceUndo = verifyBackspaceUndo
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
        pendingBackspace = nil
        requestedSourceID = nil
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
        resetAll()
    }

    func resetAll() {
        word = []
        prev = nil
        last = nil
        untrackedToken = false
    }

    func cancelPendingTyping() {
        contextRevision &+= 1
        typingRunID &+= 1
        typer.cancel()
        pendingInput.removeAll()
        pendingBackspace = nil
        requestedSourceID = nil
        idleActions.removeAll()
        busy = false
        rightOptionDownAt = nil
        rightOptionDirty = false
        resetAll()
    }

    /// Check from the tap as well as the asynchronous TIS notifications.
    /// A layout change during a word makes its suffix unsafe to rewrite in isolation.
    @discardableResult
    func inputSourceDidChange(to id: String) -> Bool {
        if id == requestedSourceID {
            layouts.confirmSelection(id)
            return false
        }
        guard layouts.observeInputSource(id) else { return false }
        let hadUnfinishedWord = untrackedToken || !word.isEmpty
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

    private func cancelTypingAndReleaseKeys(postBeforeCurrentEvent: ((CGEvent) -> Void)?) {
        let pid = busy ? typingPID : nil
        let backspace = pendingBackspace
        let queuedKeys = pendingInput
        cancelPendingTyping()
        disregardWord()
        guard let pid, frontmostPID() == pid, typer.isTargetActive(pid), !protectedInput() else { return }

        // When called from the tap, replay before the physical click or key is delivered.
        // Posting directly to the app after a click could type into a newly focused field.
        func release(_ event: CGEvent) {
            if let postBeforeCurrentEvent {
                event.setIntegerValueField(.eventSourceUserData, value: Typer.marker)
                postBeforeCurrentEvent(event)
            } else {
                typer.replay(event, to: pid)
            }
        }
        if let backspace { release(backspace) }
        for held in queuedKeys { release(held.event) }
    }

    // MARK: - Event handling

    func handle(type: CGEventType, event: CGEvent,
                postBeforeCurrentEvent: ((CGEvent) -> Void)? = nil) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByUserInput {
            stop()
            KeyboardDiagnostics.record(.tapDisabled)
            onTapStopped?("La captura de teclas está en pausa. Reanúdala desde el menú.")
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
            onTapStopped?("macOS detuvo la captura de teclas. Reanúdala desde el menú.")
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Typer.marker { return pass }
        if protectedInput() {
            if busy || !word.isEmpty || prev != nil || last != nil || rightOptionDownAt != nil {
                cancelPendingTyping()
            }
            return pass
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            cancelTypingAndReleaseKeys(postBeforeCurrentEvent: postBeforeCurrentEvent)
            return pass
        }
        if let readFrontmostBundleID {
            let activeBundle = readFrontmostBundleID()
            if activeBundle != frontmostBundleID {
                frontmostBundleID = activeBundle
                cancelPendingTyping()
            }
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
            KeyboardDiagnostics.record(.queueLimit, buffered: pendingInput.count)
            cancelTypingAndReleaseKeys(postBeforeCurrentEvent: postBeforeCurrentEvent)
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

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
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
        // Any shortcut or Option-character breaks the word.
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
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
            if !word.isEmpty {
                word.removeLast()
            } else if let p = prev, p.lang == source.lang {
                word = p.strokes
                prev = nil
            } else {
                prev = nil
            }
            last = nil
            return pass
        case 48: // Tab can land in an existing word in another field.
            disregardWord()
            return pass
        case 36, 76: // Return can submit a message.
            resetAll()
            return pass
        case 49: // Only a plain space can trigger automatic rewriting.
            if untrackedToken || flags.contains(.maskShift) { resetAll(); return pass }
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
            disregardWord()
            return pass
        }

        guard !untrackedToken else { return pass }
        guard let language = source.lang else { disregardWord(); return pass }
        let current = layouts.character(stroke, layout: source.layout)
        let alternative = layouts.character(stroke, in: language.other)
        let delivered = Self.unicodeText(of: event)
        guard current.count == 1, delivered.isEmpty || delivered == current else {
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
    private func finishWord(source: KeyboardLayouts.Source) -> Bool {
        let strokes = word
        word = []
        guard !strokes.isEmpty else {
            prev = nil
            last = nil
            return false
        }
        // Keep one correction bounded even if a field contains a very long token.
        guard strokes.count <= InputPolicy.maxAutomaticWordLength, frontmostPID() != nil else {
            prev = nil
            last = nil
            return false
        }
        let cur = source
        let mode = settings.applicationMode(for: frontmostBundleID)
        let layoutEnabled = mode.allowsAutomatic && settings.autoEnabled && layouts.hasBothLayouts
        let canSpell = mode.allowsAutomatic && settings.spellEnabled
        guard layoutEnabled || canSpell, let classifier, let curLang = cur.lang else {
            if let l = cur.lang { prev = (strokes, l) }
            last = nil
            return false
        }
        let target = curLang.other
        let curStr = layouts.string(strokes, layout: cur.layout)
        let altStr = layouts.string(strokes, in: target)
        guard curStr.count == strokes.count else {
            prev = nil
            last = nil
            return false
        }
        let canSwitch = layoutEnabled && altStr.count == strokes.count
        let cautious = mode.isCautious(defaultValue: settings.cautiousMode)
        var contextLang: Lang?
        if canSwitch, !cautious, let p = prev, p.lang == curLang, p.strokes.count <= 16 {
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
            prev = nil
            last = nil
            return false
        }
        let currentCore = classifier.models[curLang]?.core(normalizeWord(plan.currentWord)) ?? normalizeWord(plan.currentWord)
        let layoutAllowed = canSwitch && plan.decision.convert && !store.rules.blocks(currentCore, lang: curLang, kind: .layout)
        let needsConfirmation = cautious && !plan.decision.confident
        guard layoutAllowed, !needsConfirmation else {
            if canSpell, curStr.count == strokes.count,
               let model = classifier.models[curLang],
               let fix = AutomaticCorrection.spelling(current: curStr, alternative: altStr, model: model,
                                                       other: classifier.models[target], rules: store.rules) {
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

        // Correct a previous word only if its physical keys would change its spelling.
        let correctedWord = plan.prefix + plan.alternativeWord + plan.suffix
        var newText = correctedWord
        var originalText = curStr
        if !cautious, curStr != altStr, plan.prefix.isEmpty, let p = prev, p.lang == curLang, p.strokes.count <= 16 {
            let pc = layouts.string(p.strokes, layout: cur.layout)
            let pa = layouts.string(p.strokes, in: target)
            if pc.count == p.strokes.count, pa.count == p.strokes.count, pc != pa {
                let previousPlan = classifier.plan(current: pc, alternative: pa, currentLang: curLang)
                let correctedPrevious = previousPlan.prefix + previousPlan.alternativeWord + previousPlan.suffix
                if correctedPrevious != pc, !store.rules.blocks(pc, lang: curLang, kind: .layout),
                   classifier.shouldRetroFix(current: previousPlan.currentWord,
                                             alternative: previousPlan.alternativeWord, currentLang: curLang) {
                    newText = correctedPrevious + " " + correctedWord
                    originalText = pc + " " + curStr
                }
            }
        }

        var actions = replacementActions(original: originalText, replacement: newText)
        actions.append(.key(49, []))
        perform(actions, switchingTo: target) { [weak self] in
            guard let self, self.isRunning else { return }
            self.bumpStats()
            self.onCorrection?(plan.currentWord, plan.alternativeWord)
        }

        last = Correction(typedText: newText, originalText: originalText,
                          from: curLang, originalWord: currentCore, kind: .layout)
        prev = correctedWord == altStr ? (strokes, target) : nil
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
        prev = nil
        return true
    }

    private func replacementActions(original: String, replacement: String) -> [Typer.Action] {
        guard original != replacement else { return [] }
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
            let deadline = ProcessInfo.processInfo.systemUptime + 0.075
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
            layouts.confirmSelection(currentID)
        } else if !userRequestedInputSource, requestedSourceID == targetID,
                  currentID == originID, ProcessInfo.processInfo.systemUptime < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.waitForInputSource(targetID, from: originID, until: deadline,
                                         pid: pid, runID: runID, onSuccess: onSuccess)
            }
            return
        } else {
            KeyboardDiagnostics.record(.sourceUnconfirmed)
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
            if c.typedText != c.originalText {
                perform([.backspace(c.typedText.count + 1), .text(c.originalText), .key(49, [])],
                        switchingTo: c.kind == .layout ? c.from : nil) { [weak self] in
                    self?.rememberUndo(c)
                }
            } else {
                perform([], switchingTo: c.from) { [weak self] in self?.rememberUndo(c) }
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
            guard original.count == word.count, alt.count == word.count, original != alt else {
                onManualFixAtCaret?()
                return
            }
            let learn = !isKnown(original, lang: curLang)
            perform([.backspace(word.count), .text(alt)], switchingTo: target) { [weak self] in
                if learn { self?.learnPositive(alt, lang: target) }
            }
            return
        }
        if let p = prev, p.lang == curLang {
            let alt = layouts.string(p.strokes, in: target)
            let original = layouts.string(p.strokes, layout: source.layout)
            guard original.count == p.strokes.count, alt.count == p.strokes.count else { return }
            if original == alt {
                // Most EN/ES words share physical keys; keep the text when changing the layout.
                perform([], switchingTo: target)
                prev = (p.strokes, target)
                return
            }
            let learn = !isKnown(original, lang: curLang)
            perform([.backspace(p.strokes.count + 1), .text(alt), .key(49, [])], switchingTo: target) { [weak self] in
                if learn { self?.learnPositive(alt, lang: target) }
            }
            prev = (p.strokes, target)
            return
        }
        onManualFixAtCaret?()
    }

    private func rememberUndo(_ correction: Correction) {
        store.addRule(correction.originalWord, lang: correction.from, kind: correction.kind,
                      result: correction.typedText, source: .undo)
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
        pendingBackspace = held
        let deadline = DispatchTime.now() + .milliseconds(45)

        func complete(_ verified: Bool) {
            guard busy, typingRunID == runID else { return }
            guard !protectedInput(), frontmostPID() == pid, typer.isTargetActive(pid) else {
                cancelPendingTyping()
                return
            }
            pendingBackspace = nil
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

    /// Flipping a real word away (an accidental tap) must not teach its gibberish reading.
    private func isKnown(_ text: String, lang: Lang) -> Bool {
        guard let m = classifier?.models[lang] else { return false }
        return m.score(m.core(normalizeWord(text))) != nil
    }

    func learnPositive(_ text: String, lang: Lang) {
        guard let m = classifier?.models[lang] else { return }
        let w = m.core(normalizeWord(text))
        guard m.isWord(w), w.count >= 2 else { return }
        store.learn(w, lang: lang)
        classifier?.learn(w, lang: lang)
    }
}
