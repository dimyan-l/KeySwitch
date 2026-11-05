import AppKit
import ApplicationServices

/// Reads a few characters of the focused text field through Accessibility, to check whether you put
/// your own word back after a correction (selection + retype, an edit inside the word, ⌘Z).
/// Only a small range around the corrected word is read. Many fields (Electron, some web editors,
/// secure fields) expose nothing: then nothing is learned automatically, and right ⌥ or the panel remain.
enum FieldProbe {
    struct Spot {
        let element: AXUIElement?
        /// UTF-16 offset of the corrected word in the field.
        let location: Int
    }

    /// Self-test only: the focused field's whole text, instead of Accessibility.
    nonisolated(unsafe) static var simulatedText: (() -> String)?

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let el = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.15)
        return el
    }

    static func caret(_ el: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    static func string(_ el: AXUIElement, location: Int, length: Int) -> String? {
        var r = CFRange(location: max(0, location), length: max(0, length))
        guard let v = AXValueCreate(.cfRange, &r) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, v, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Right after we typed `result`: where it sits in the focused field (searched just before the caret,
    /// so a few keys you typed meanwhile do not matter).
    static func locate(_ result: String) -> Spot? {
        if let sim = simulatedText {
            let text = sim()
            return lastWholeWord(result, in: text).map { Spot(element: nil, location: $0) }
        }
        guard let el = focusedElement(), let caret = caret(el) else { return nil }
        let len = (result as NSString).length
        let start = max(0, caret - len - 40)
        guard let text = string(el, location: start, length: caret - start),
              let off = lastWholeWord(result, in: text) else { return nil }
        return Spot(element: el, location: start + off)
    }

    /// The word now at `spot`, if the same field still has focus. nil when that cannot be checked.
    static func word(at spot: Spot, around length: Int) -> String? {
        if let sim = simulatedText { return token(in: sim(), at: spot.location) }
        guard let el = focusedElement(), let mine = spot.element, CFEqual(el, mine) else { return nil }
        let start = max(0, spot.location - 30)
        guard let text = string(el, location: start, length: spot.location - start + length + 30) else { return nil }
        return token(in: text, at: spot.location - start)
    }

    // MARK: Text at the caret (right ⌥ on a word you came back to)

    /// What surrounds the caret in the focused field: a little text before and after it and the selection.
    struct Around {
        let before: String
        let selected: String
        let after: String
        /// More text is selected than right ⌥ converts: it was not read, and nothing is done with it.
        var selectionTooLong = false
    }

    /// Longest selection right ⌥ converts (the engine's limit; larger ones are not even read).
    static let maxSelection = 1000

    /// Self-test only: the stand's field (whole text, caret or selection start, selection length).
    nonisolated(unsafe) static var simulatedField: (() -> (text: String, caret: Int, selection: Int))?
    nonisolated(unsafe) private static var electronAsked = Set<pid_t>()

    /// nil when the field does not tell (no Accessibility text, a password field): then the clipboard is used.
    static func around(pid: pid_t, window: Int = 80) -> Around? {
        if let sim = simulatedField {
            let (t, c, l) = sim()
            let ns = t as NSString
            let start = max(0, c - window), end = min(ns.length, c + l + window)
            return Around(before: ns.substring(with: NSRange(location: start, length: c - start)),
                          selected: ns.substring(with: NSRange(location: c, length: l)),
                          after: ns.substring(with: NSRange(location: c + l, length: end - c - l)))
        }
        // Electron apps (Slack, Notion, Discord…) expose their text only when asked to.
        if pid > 0, !electronAsked.contains(pid) {
            electronAsked.insert(pid)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            usleep(60_000)
        }
        guard let el = focusedElement(), !isSecure(el) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &sel), sel.location >= 0 else { return nil }
        if sel.length > maxSelection * 2 { return Around(before: "", selected: "", after: "", selectionTooLong: true) }
        var total = Int.max
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let n = countRef as? Int { total = n }
        let start = max(0, sel.location - window)
        let afterStart = sel.location + sel.length
        let afterLen = max(0, min(window, total - afterStart))
        // Range reads first; some fields only give their whole value.
        if let before = string(el, location: start, length: sel.location - start),
           let selected = sel.length > 0 ? string(el, location: sel.location, length: sel.length) : "" {
            let after = afterLen > 0 ? (string(el, location: afterStart, length: afterLen) ?? "") : ""
            return Around(before: before, selected: selected, after: after)
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }
        let ns = value as NSString
        guard afterStart <= ns.length else { return nil }
        let end = min(ns.length, afterStart + window)
        return Around(before: ns.substring(with: NSRange(location: start, length: sel.location - start)),
                      selected: ns.substring(with: NSRange(location: sel.location, length: sel.length)),
                      after: ns.substring(with: NSRange(location: afterStart, length: end - afterStart)))
    }

    private static func isSecure(_ el: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &ref) == .success,
           (ref as? String) == (kAXSecureTextFieldSubrole as String) { return true }
        return false
    }

    /// The word the caret touches: the non-space run ending at the caret and the one starting there.
    /// nil when the caret has spaces (or nothing) on both sides: then right ⌥ only switches the layout.
    static func tokenAtCaret(before: String, after: String) -> (left: String, right: String)? {
        let left = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        let right = String(after.prefix { !$0.isWhitespace })
        return left.isEmpty && right.isEmpty ? nil : (left, right)
    }

    // MARK: Pure text helpers (tested in --selftest)

    static func isWordChar(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(s) || c == 0x2D || c == 0x27 || c == 0x2019 // - ' ’
    }

    /// Offset (UTF-16) of the last occurrence of `word` in `text` that is a whole word.
    static func lastWholeWord(_ word: String, in text: String) -> Int? {
        let ns = text as NSString
        var searchEnd = ns.length
        while searchEnd > 0 {
            let r = ns.range(of: word, options: [.backwards, .caseInsensitive], range: NSRange(location: 0, length: searchEnd))
            guard r.location != NSNotFound else { return nil }
            let before = r.location == 0 || !isWordChar(ns.character(at: r.location - 1))
            let after = r.location + r.length >= ns.length || !isWordChar(ns.character(at: r.location + r.length))
            if before && after { return r.location }
            searchEnd = r.location + r.length - 1
        }
        return nil
    }

    /// The whole word covering UTF-16 offset `offset` (or starting right there), without edge apostrophes/dashes.
    static func token(in text: String, at offset: Int) -> String? {
        let ns = text as NSString
        guard offset >= 0, offset < ns.length, isWordChar(ns.character(at: offset)) else { return nil }
        var a = offset, b = offset
        while a > 0, isWordChar(ns.character(at: a - 1)) { a -= 1 }
        while b + 1 < ns.length, isWordChar(ns.character(at: b + 1)) { b += 1 }
        let w = ns.substring(with: NSRange(location: a, length: b - a + 1))
        let trimmed = w.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
