import AppKit
import ApplicationServices

/// Identifies the field that owned a user-initiated selection operation.
/// Queries run outside the keyboard tap, so an unresponsive app cannot stall physical input.
struct FocusToken {
    let pid: pid_t
    let element: AXUIElement

    static func capture(expectedPID: pid_t? = nil) -> FocusToken? {
        guard !SecureInput.isEnabled,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              expectedPID == nil || expectedPID == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return FocusToken(pid: pid, element: focused as! AXUIElement)
    }

    /// Excludes system Secure Input and Accessibility fields explicitly marked secure.
    var canReadText: Bool {
        guard !SecureInput.isEnabled else { return false }
        AXUIElementSetMessagingTimeout(element, 0.04)
        for key in [kAXSubroleAttribute, kAXRoleAttribute] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if result == .success {
                if (value as? String)?.localizedCaseInsensitiveContains("secure") == true { return false }
            } else if result != .attributeUnsupported && result != .noValue {
                return false
            }
        }
        return true
    }

    func matchesTextBeforeCaret(_ text: String) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.04)
        let length = text.utf16.count
        guard length > 0, canReadText, isCurrent(), let caret = selectionRange(),
              caret.length == 0, caret.location >= length else { return false }
        var range = CFRange(location: caret.location - length, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        var preceding: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &preceding) == .success,
              let found = preceding as? String,
              found.utf16.elementsEqual(text.utf16),
              let current = selectionRange(), current.location == caret.location, current.length == 0 else { return false }
        return !SecureInput.isEnabled && isCurrent()
    }

    private func selectionRange() -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    func isCurrent() -> Bool {
        guard !SecureInput.isEnabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(element, focused)
    }
}
