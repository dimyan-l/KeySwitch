import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import ServiceManagement

// Read-only permission check; does not create an event tap or request access.
if CommandLine.arguments.contains("--diagnose-permissions") {
    print("Aplicación: \(Bundle.main.bundleURL.path)")
    print("Accesibilidad: \(AXIsProcessTrusted() ? "concedido" : "sin conceder")")
    print("Monitorización de entrada: \(CGPreflightListenEventAccess() ? "concedido" : "sin conceder")")
    exit(0)
}

if CommandLine.arguments.contains("--diagnose-data") {
    let store = UserStore()
    if let error = store.saveError { print(error); exit(1) }
    print("Palabras aprendidas: \(store.learned.values.reduce(0) { $0 + $1.count })")
    print("Reglas: \(store.rules.active.count) (ES: \(store.rules.active.filter { $0.lang == .es }.count), EN: \(store.rules.active.filter { $0.lang == .en }.count))")
    store.flushPendingWrites()
    exit(0)
}

// Emergency recovery: remove the login item without starting the keyboard tap.
if CommandLine.arguments.contains("--disable-login") {
    do {
        if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        print("Inicio automático de KeySwitch ES desactivado")
        exit(0)
    } catch {
        print("No se pudo desactivar el inicio automático: \(error.localizedDescription)")
        exit(1)
    }
}

// `KeySwitch --selftest` checks the dictionaries and the classifier without any permissions.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

func runKeySwitch() {
    // Hold one advisory lock for the entire menu-bar process, including startup.
    let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("com.levantovsky.keyswitches.instance")
    let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        if fd >= 0 { close(fd) }
        fputs("KeySwitch ES ya está abierto o el bloqueo no está disponible.\n", stderr)
        exit(75)
    }
    defer { close(fd) }

    let app = NSApplication.shared
    if let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
           $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
       }) {
        fputs("Ya hay otra copia de KeySwitch ES abierta.\n", stderr)
        exit(75)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

runKeySwitch()
