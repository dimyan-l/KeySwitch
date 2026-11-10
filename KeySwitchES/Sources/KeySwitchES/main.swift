import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

// Read-only permission check; does not create an event tap or request access.
if CommandLine.arguments.contains("--diagnose-permissions") {
    print("Application: \(Bundle.main.bundleURL.path)")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
    print("Input Monitoring: \(CGPreflightListenEventAccess() ? "granted" : "missing")")
    exit(0)
}

if CommandLine.arguments.contains("--diagnose-data") {
    let store = UserStore()
    if let error = store.saveError { print(error); exit(1) }
    print("Palabras aprendidas: \(store.learned.values.reduce(0) { $0 + $1.count })")
    print("Reglas: \(store.rules.active.count) (EN: \(store.rules.active.filter { $0.lang == .en }.count), ES: \(store.rules.active.filter { $0.lang == .es }.count))")
    store.flushPendingWrites()
    exit(0)
}

// Emergency recovery: remove the login item without starting the keyboard tap.
if CommandLine.arguments.contains("--disable-login") {
    do {
        if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        print("KeySwitch ES login item disabled")
        exit(0)
    } catch {
        print("Could not disable login item: \(error.localizedDescription)")
        exit(1)
    }
}

// `KeySwitch --selftest` checks the dictionaries and the classifier without any permissions.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
