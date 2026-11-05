import AppKit
import Carbon
import Darwin

/// macOS "secure keyboard entry": while any app holds it (a password field left focused, a password manager,
/// Terminal's "Secure Keyboard Entry"), no other program sees keystrokes, and KeySwitch silently fixes nothing.
/// We can't release it for another app, but we can say that it is on and who holds it.
enum SecureInput {
    struct Holder: Equatable {
        let pid: pid_t
        let name: String
    }

    /// Self-test / snapshots only.
    nonisolated(unsafe) static var simulated: Holder??

    /// nil while secure input is off. When it is on but the holder can't be told, the name is empty.
    static func holder() -> Holder? {
        if let s = simulated { return s }
        guard IsSecureEventInputEnabled() else { return nil }
        guard let pid = holderPID() else { return Holder(pid: 0, name: "") }
        return Holder(pid: pid, name: name(of: pid))
    }

    /// The window server records the holder in the console-user entry of the I/O Registry.
    private static func holderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 { return pid }
        }
        return nil
    }

    private static func name(of pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "процесс \(pid)"
    }
}
