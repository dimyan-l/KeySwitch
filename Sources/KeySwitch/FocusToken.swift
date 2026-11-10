import AppKit
import ApplicationServices

/// Identifies the field that owned a user-initiated selection operation.
/// Queries run outside the keyboard tap, so an unresponsive app cannot stall physical input.
struct FocusToken {
    let pid: pid_t
    let element: AXUIElement

    static func capture() -> FocusToken? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return FocusToken(pid: pid, element: focused as! AXUIElement)
    }

    func isCurrent() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(element, focused)
    }
}
