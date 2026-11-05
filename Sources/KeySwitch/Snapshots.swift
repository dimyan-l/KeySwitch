import AppKit
import SwiftUI

/// Renders the main screens with sample data into PNGs, light and dark, without showing anything on screen.
/// Used to review the design; touches no settings and no files except the PNGs.
enum Snapshots {
    static func run(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let clipboard = ClipboardHistory()
        clipboard.add("https://example.com", app: "Safari")
        clipboard.add("SELECT TOP 10 * FROM sys.dm_exec_query_stats ORDER BY total_worker_time DESC", app: "Slack")
        clipboard.add("Созвон завтра в 11:00 по Мадриду, ссылка в календаре", app: "Telegram")
        // Sample rules in a temporary folder: your own files are never read or written here.
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("keyswitch-snapshots")
        try? FileManager.default.removeItem(at: sample)
        let store = UserStore(directory: sample)
        store.addRule("внось", lang: .ru, kind: .spell, result: "вновь", source: .undo)
        store.addRule("выставь", lang: .ru, kind: .spell, result: "вставь", source: .restore)
        store.addRule("spbdev", lang: .en, kind: nil, result: nil, source: .migrated)
        store.addRule("гугл", lang: .ru, kind: nil, result: nil, source: .manual)
        store.flush()
        Settings.shared.testMode = true
        let model = AppModel(store: store, clipboard: clipboard)
        model.rulesCount = store.rules.active.count
        model.lang = .ru
        model.engineRunning = true
        model.accessibilityGranted = true
        model.inputMonitoringGranted = false
        model.dictionariesReady = true
        model.correctionsToday = 8
        model.learnedCount = 3
        model.frontAppName = "Telegram"
        model.frontBundleID = "ru.keepcoder.Telegram"
        let now = Date()
        model.recent = [
            CorrectionRecord(typed: "внось", result: "вновь", kind: .spell, to: .ru, from: .ru, app: "Telegram", bundleID: "ru.keepcoder.Telegram", date: now.addingTimeInterval(-20)),
            CorrectionRecord(typed: "ghbdtn", result: "привет", kind: .layout, to: .ru, from: .en, app: "Telegram", bundleID: "ru.keepcoder.Telegram", date: now.addingTimeInterval(-600)),
            CorrectionRecord(typed: "ЫЙД Ыукмук", result: "SQL Server", kind: .layout, to: .en, from: .ru, app: "Slack", date: now.addingTimeInterval(-1700)),
            CorrectionRecord(typed: "пРИВЕТ", result: "Привет", kind: .caseFix, to: .ru, from: .ru, app: "Telegram", date: now.addingTimeInterval(-3000), protected: true),
        ]

        let recent = model.recent
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark"),
                                     (.accessibilityHighContrastDarkAqua, "dark-contrast"), (.accessibilityHighContrastAqua, "light-contrast")] {
            // The menu under the icon is a standard macOS menu: it is checked live, not in snapshots.
            model.recent = recent
            model.ruleNotice = nil
            guard suffix == "light" || suffix == "dark" else { continue }
            Settings.shared.clipboardOverride = true
            shot(ToastView(kind: .fix(to: .ru, typed: "cjpdjybvcz", result: "созвонимся", undoable: true)), "toast", appearance, suffix, dir)
            shot(ToastView(kind: .fix(to: .ru, typed: "ghbdtn", result: "привет", undoable: false)), "toast-enter", appearance, suffix, dir)
            shot(ToastView(kind: .learned("внось", saved: true)), "toast-learned", appearance, suffix, dir)
            shot(OnboardingView(model: model), "onboarding", appearance, suffix, dir)
            for pane in SettingsPane.allCases {
                model.pane = pane
                shot(SettingsView(model: model).frame(width: 880, height: 640), "settings-\(pane.rawValue)", appearance, suffix, dir)
            }
            // The words list alone: inside the split view an offscreen render scrolls it out of view.
            shot(WordsPane(model: model).frame(width: 660, height: 600).background(Theme.background), "settings-words-content", appearance, suffix, dir)
            model.pane = .general
            shot(SettingsView(model: model).frame(width: 760, height: 560), "settings-min", appearance, suffix, dir)
        }
        Settings.shared.testMode = false
        print("→ \(dir.path)")
    }

    private static func shot<V: View>(_ view: V, _ name: String, _ appearance: NSAppearance.Name, _ suffix: String, _ dir: URL) {
        // The window background is not part of the view's cached image: draw it inside the view.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
    }
}
