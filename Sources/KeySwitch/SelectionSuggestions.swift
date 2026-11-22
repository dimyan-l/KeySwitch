import AppKit
import ApplicationServices

/// A snapshot of one selected word. All AX calls happen after a selection gesture,
/// never inside the keyboard event tap.
final class SelectedWord {
    let focus: FocusToken
    let text: String
    let range: CFRange
    let bounds: CGRect?
    private let caretLocation: Int?

    private init(focus: FocusToken, text: String, range: CFRange, bounds: CGRect?, caretLocation: Int? = nil) {
        self.focus = focus
        self.text = text
        self.range = range
        self.bounds = bounds
        self.caretLocation = caretLocation
    }

    static func capture(includePhrases: Bool = false) -> SelectedWord? {
        guard let focus = FocusToken.capture(), focus.canReadText else { return nil }
        let element = focus.element
        AXUIElementSetMessagingTimeout(element, 0.04)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0,
              (includePhrases ? 1...16_384 : 2...32).contains(range.length) else { return nil }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, text.utf16.count == range.length else { return nil }

        if includePhrases { return SelectedWord(focus: focus, text: text, range: range, bounds: nil) }
        guard text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) ||
                                               CharacterSet.nonBaseCharacters.contains($0) || $0 == "'" || $0 == "-" }),
              text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }

        var rawBounds: CFTypeRef?
        var rect = CGRect.zero
        let hasBounds = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &rawBounds
        ) == .success && rawBounds.map {
            CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue($0 as! AXValue, .cgRect, &rect)
        } == true
        return SelectedWord(focus: focus, text: text, range: range, bounds: hasBounds ? rect : nil)
    }

    enum CaretCapture {
        case word(SelectedWord)
        /// The field is readable, but no word touches the insertion point.
        case noWord
        /// The app does not expose its text through Accessibility (many Electron/Chromium apps).
        case unsupported
    }

    /// Roles that are certainly not text editors: no keyboard fallback for them.
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenu",
        "AXMenuBarItem", "AXTable", "AXOutline", "AXList", "AXRow", "AXCell", "AXImage", "AXSlider",
        "AXTabGroup", "AXToolbar", "AXLink",
    ]

    /// Read a small window around an insertion point. Never fetch an editor's
    /// entire value, and never run this from the keyboard event tap.
    /// `extra`: punctuation that may be part of a word typed in the wrong layout.
    static func captureAtCaret(extra: Set<Character> = []) -> CaretCapture {
        guard let focus = FocusToken.capture() else { return .unsupported }
        guard focus.canReadText else { return .noWord }
        let element = focus.element
        AXUIElementSetMessagingTimeout(element, 0.04)
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String, nonTextRoles.contains(role) { return .noWord }
        var rangeValue: CFTypeRef?
        var countValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success,
              let count = countValue as? NSNumber else { return .unsupported }
        var caret = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &caret) else { return .unsupported }
        guard caret.length == 0, caret.location >= 0, caret.location <= count.intValue else { return .noWord }
        let start = max(0, caret.location - 32)
        let length = caret.location - start + min(32, count.intValue - caret.location)
        guard length > 0 else { return .noWord }
        guard let window = string(in: CFRange(location: start, length: length), from: element),
              window.utf16.count == length else { return .unsupported }
        guard let local = CaretWordRange.find(in: window, caretUTF16: caret.location - start,
                                              leadingTruncated: start > 0,
                                              trailingTruncated: start + length < count.intValue,
                                              extra: extra) else { return .noWord }
        let wordRange = CFRange(location: start + local.location, length: local.length)
        return .word(SelectedWord(focus: focus, text: local.word, range: wordRange,
                                  bounds: bounds(of: wordRange, in: element), caretLocation: caret.location))
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var boundsRange = range
        var rawBounds: CFTypeRef?
        var rect = CGRect.zero
        guard let value = AXValueCreate(.cfRange, &boundsRange),
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         value, &rawBounds) == .success,
              let rawBounds, CFGetTypeID(rawBounds) == AXValueGetTypeID(),
              AXValueGetValue(rawBounds as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The same word without `dropFirst` leading and `dropLast` trailing characters
    /// (punctuation around a word that turned out not to belong to it).
    func narrowed(dropFirst: Int, dropLast: Int) -> SelectedWord {
        guard dropFirst > 0 || dropLast > 0 else { return self }
        let chars = Array(text)
        guard dropFirst + dropLast < chars.count else { return self }
        let head = String(chars[..<dropFirst]).utf16.count
        let body = String(chars[dropFirst..<(chars.count - dropLast)])
        return SelectedWord(focus: focus, text: body,
                            range: CFRange(location: range.location + head, length: body.utf16.count),
                            bounds: bounds, caretLocation: caretLocation)
    }

    private static func string(in range: CFRange, from element: AXUIElement) -> String? {
        var requested = range
        guard let value = AXValueCreate(.cfRange, &requested) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &result) == .success else { return nil }
        return result as? String
    }

    /// Select only if the same editor, insertion point and word are still present.
    func selectIfCaretCurrent() -> Bool {
        guard let caretLocation else { return isCurrent() }
        guard focus.canReadText, focus.isCurrent() else { return false }
        let element = focus.element
        AXUIElementSetMessagingTimeout(element, 0.04)
        var currentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &currentValue) == .success,
              let currentValue, CFGetTypeID(currentValue) == AXValueGetTypeID() else { return false }
        var current = CFRange()
        guard AXValueGetValue(currentValue as! AXValue, .cfRange, &current),
              current.location == caretLocation, current.length == 0,
              Self.string(in: range, from: element) == text else { return false }
        var selectedRange = range
        guard let selectedValue = AXValueCreate(.cfRange, &selectedRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                           selectedValue) == .success else { return false }
        return isCurrent()
    }

    func isCurrent() -> Bool {
        guard focus.canReadText, focus.isCurrent() else { return false }
        let element = focus.element
        AXUIElementSetMessagingTimeout(element, 0.04)
        var selected: CFTypeRef?
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let selected = selected as? String, selected.utf16.elementsEqual(text.utf16),
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return false }
        var current = CFRange()
        return AXValueGetValue(rangeValue as! AXValue, .cfRange, &current)
            && current.location == range.location && current.length == range.length
    }

    /// Direct AX replacement works in native editors. The caller can fall back to
    /// the existing paste path for editors that expose selection read-only.
    func replaceDirectly(with replacement: String) -> Bool {
        guard isCurrent(), !SecureInput.isEnabled else { return false }
        let element = focus.element
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            replacement as CFTypeRef) == .success
    }
}

enum CaretWordRange {
    /// `extra`: punctuation keys that type letters in the other layout ("," is "б", "." is "ю").
    /// They join a word only when all of its letters are ASCII, i.e. it may be a wrong-layout word.
    static func find(in text: String, caretUTF16: Int, leadingTruncated: Bool = false,
                     trailingTruncated: Bool = false,
                     extra: Set<Character> = []) -> (location: Int, length: Int, word: String)? {
        let chars = Array(text)
        var offsets = [0]
        for char in chars { offsets.append(offsets.last! + String(char).utf16.count) }
        guard let caret = offsets.firstIndex(of: caretUTF16) else { return nil }
        func isPart(_ char: Character) -> Bool {
            char.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
            } || char == "'" || char == "-" || extra.contains(char)
        }
        var start = caret
        var end = caret
        if caret > 0, isPart(chars[caret - 1]) {
            start = caret - 1
            end = caret
        } else if caret < chars.count, isPart(chars[caret]) {
            start = caret
            end = caret + 1
        } else { return nil }
        while start > 0 && isPart(chars[start - 1]) { start -= 1 }
        while end < chars.count && isPart(chars[end]) { end += 1 }
        if !extra.isEmpty {
            let run = chars[start..<end]
            let wrongLayoutCandidate = run.contains(where: \.isLetter)
                && run.allSatisfy { !$0.isLetter || $0.isASCII }
            if !wrongLayoutCandidate {
                return find(in: text, caretUTF16: caretUTF16, leadingTruncated: leadingTruncated,
                            trailingTruncated: trailingTruncated)
            }
        }
        if (start == 0 && leadingTruncated) || (end == chars.count && trailingTruncated) { return nil }
        let word = String(chars[start..<end])
        guard (1...32).contains(end - start) else { return nil }
        if extra.isEmpty {
            guard word.first?.isLetter == true, word.last?.isLetter == true else { return nil }
        }
        return (offsets[start], offsets[end] - offsets[start], word)
    }
}

enum SelectionCandidates {
    static func make(for word: String, classifier: Classifier?, preferred: Lang?, flip: String?) -> [String] {
        var result: [String] = []
        func add(_ candidate: String) {
            guard candidate != word, !candidate.isEmpty, !result.contains(candidate) else { return }
            result.append(candidate)
        }

        for candidate in corrections(for: word, classifier: classifier, preferred: preferred, flip: flip) {
            add(candidate)
        }
        add(word.lowercased())
        add(word.prefix(1).uppercased() + word.dropFirst().lowercased())
        add(word.uppercased())
        return Array(result.prefix(3))
    }

    static func corrections(for word: String, classifier: Classifier?, preferred: Lang?, flip: String?) -> [String] {
        var result: [String] = []
        func add(_ candidate: String) {
            guard candidate != word, !candidate.isEmpty, !result.contains(candidate) else { return }
            result.append(candidate)
        }
        let models = classifier?.models ?? [:]
        let languages = Lang.allCases.sorted { $0 == preferred && $1 != preferred }
        let normalized = normalizeWord(word)
        if let flip, flip != word, let classifier {
            let source = languages.first { models[$0]?.isWord(normalized) == true }
            if let source {
                let decision = classifier.decide(current: word, alternative: flip, currentLang: source)
                if decision.convert && decision.reason == "other-dict" { return [flip] }
                if decision.convert { add(flip) }
            }
        }
        for lang in languages {
            guard let model = models[lang], model.isWord(normalized) else { continue }
            for candidate in SpellCorrector.suggestions(for: word, model: model, limit: 2) {
                add(matchCase(candidate, to: word))
            }
        }
        if let flip, flip != word, models.values.contains(where: { $0.score(normalizeWord(flip)) != nil }) {
            add(flip)
        }
        return Array(result.prefix(3))
    }

    static func matchCase(_ candidate: String, to word: String) -> String {
        if word == word.uppercased() { return candidate.uppercased() }
        if word.first.map({ String($0) == String($0).uppercased() }) == true {
            return candidate.prefix(1).uppercased() + candidate.dropFirst()
        }
        return candidate
    }
}

/// A nonactivating panel keeps the editor's selection in place while the user
/// chooses a replacement. Its position follows the selected word when AX bounds
/// are available, with the pointer as a fallback.
final class SelectionSuggestionPanel {
    private var panel: NSPanel?
    private var targets: [ChoiceTarget] = []
    private var buttons: [NSButton] = []
    private var options: [String] = []
    private var selectedIndex = 0
    private var onChoose: ((String) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        targets.removeAll(); buttons.removeAll(); options.removeAll(); onChoose = nil
    }

    /// Called on the main run loop before an editor receives the key.
    func handleKey(_ code: UInt16) -> Bool {
        guard isVisible, !options.isEmpty else { return false }
        switch code {
        case 123, 126: selectedIndex = (selectedIndex + options.count - 1) % options.count; highlight()
        case 124, 125: selectedIndex = (selectedIndex + 1) % options.count; highlight()
        case 36, 76:
            let choice = options[selectedIndex]
            let callback = onChoose
            DispatchQueue.main.async { callback?(choice) }
        case 53: hide()
        default: return false
        }
        return true
    }

    private func highlight() {
        for (index, button) in buttons.enumerated() {
            button.layer?.backgroundColor = (index == selectedIndex ? NSColor.controlAccentColor : NSColor.clear).cgColor
            button.contentTintColor = index == selectedIndex ? .white : .labelColor
            button.setAccessibilityValue(index == selectedIndex ? "Selected" : "")
        }
    }

    func show(options: [String], bounds: CGRect?, onChoose: @escaping (String) -> Void) {
        hide()
        guard !options.isEmpty else { return }
        self.options = Array(options.prefix(3))
        self.onChoose = onChoose
        selectedIndex = 0
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let longest = options.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 100
        let width: CGFloat = min(320, max(216, longest + 32))
        let height: CGFloat = CGFloat(self.options.count) * 32 + 62
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        let background = NSVisualEffectView(frame: frame)
        background.material = .popover; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 12; background.layer?.masksToBounds = true
        panel.contentView = background
        let spanish = Lang(rawValue: "es") != nil
        let title = NSTextField(labelWithString: spanish ? "Corregir palabra" : "Исправить слово")
        title.font = .systemFont(ofSize: 10, weight: .semibold); title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: height - 24, width: width - 24, height: 14)
        background.addSubview(title)
        for (index, choice) in self.options.enumerated() {
            let button = NSButton(title: choice, target: nil, action: nil)
            button.frame = NSRect(x: 6, y: height - 30 - CGFloat(index + 1) * 32, width: width - 12, height: 30)
            button.isBordered = false; button.alignment = .left; button.font = font
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            button.action = #selector(ChoiceTarget.choose(_:))
            let target = ChoiceTarget(choice: choice, callback: onChoose)
            button.target = target; targets.append(target); buttons.append(button)
            background.addSubview(button)
        }
        let hint = NSTextField(labelWithString: spanish ? "↑ ↓ elegir   ↵ aplicar   esc cerrar" : "↑ ↓ выбор   ↵ заменить   esc закрыть")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 12, y: 7, width: width - 24, height: 14)
        background.addSubview(hint)
        let pointer = NSEvent.mouseLocation
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let anchor = bounds.map { NSPoint(x: $0.minX, y: primaryTop - $0.minY) } ?? pointer
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = min(max(anchor.x, visible.minX + 4), visible.maxX - width - 4)
        let above = anchor.y + 8
        let y = above + height <= visible.maxY ? above : max(visible.minY + 4, anchor.y - height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        self.panel = panel
        highlight()
        panel.orderFrontRegardless()
    }
}

private final class ChoiceTarget: NSObject {
    let choice: String
    let callback: (String) -> Void

    init(choice: String, callback: @escaping (String) -> Void) {
        self.choice = choice
        self.callback = callback
    }

    @objc func choose(_ sender: NSButton) { callback(choice) }
}
