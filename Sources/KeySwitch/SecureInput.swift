import Carbon

/// Read-only visibility into macOS secure keyboard entry. Never release another app's protection.
enum SecureInput {
    static var isEnabled: Bool { IsSecureEventInputEnabled() }
}

/// Pure transition tracking: polling/UI refreshes must not repeatedly discard correction undo.
struct SecureInputState {
    private(set) var isEnabled = false

    /// Both edges invalidate context because keystrokes during secure input were not observable.
    @discardableResult
    mutating func observe(_ enabled: Bool) -> Bool {
        guard enabled != isEnabled else { return false }
        isEnabled = enabled
        return true
    }
}
