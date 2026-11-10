import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

// Read-only permission check; does not create an event tap or request access.
if CommandLine.arguments.contains("--diagnose-permissions") {
    print("Приложение: \(Bundle.main.bundleURL.path)")
    print("Универсальный доступ: \(AXIsProcessTrusted() ? "выдан" : "не выдан")")
    print("Мониторинг ввода: \(CGPreflightListenEventAccess() ? "выдан" : "не выдан")")
    exit(0)
}

if CommandLine.arguments.contains("--diagnose-data") {
    let store = UserStore()
    if let error = store.saveError { print(error); exit(1) }
    print("Выученных слов: \(store.learned.values.reduce(0) { $0 + $1.count })")
    print("Правил: \(store.rules.active.count) (RU: \(store.rules.active.filter { $0.lang == .ru }.count), EN: \(store.rules.active.filter { $0.lang == .en }.count))")
    store.flushPendingWrites()
    exit(0)
}

// Emergency recovery: remove the login item without starting the keyboard tap.
if CommandLine.arguments.contains("--disable-login") {
    do {
        if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        print("Автозапуск KeySwitch отключён")
        exit(0)
    } catch {
        print("Не удалось отключить автозапуск: \(error.localizedDescription)")
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
