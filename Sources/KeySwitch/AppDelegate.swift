import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import SwiftUI

enum Resources {
    /// Bundled dictionaries: KeySwitch.app/Contents/Resources/Dictionaries, or ./Resources/Dictionaries when run from the project folder.
    static var dictionaryDirectory: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Dictionaries")) }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Dictionaries"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("ru.tsv").path) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AppActions {
    private let layouts = KeyboardLayouts()
    private let store = UserStore()
    private lazy var engine = SwitchEngine(layouts: layouts, store: store)
    private lazy var clipboard = ClipboardHistory()
    private lazy var model = AppModel(store: store, clipboard: clipboard)
    private let settings = Settings.shared

    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenu!
    private let toast = ToastController()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var syncTimer: Timer?
    private var lastExternalApp: NSRunningApplication?
    private var loadError: String?
    private var ticks = 0
    /// Only the newest dictionary load may replace the model: an older one finishing later is dropped.
    private var loadGeneration = 0

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        model.actions = self
        model.onSettingsChanged = { [weak self] in
            self?.engine.resetAll()
            self?.updateStatusItem()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.setAccessibilityLabel("KeySwitch")

        // A plain menu under the icon, like Punto Switcher and Caramba Switcher.
        statusMenu = StatusMenu(model: model)
        statusMenu.willOpen = { [weak self] in self?.syncModel() }
        statusMenu.fixAtCaret = { [weak self] in
            // The menu has closed and the app you typed in has the keyboard again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.engine.manualFix() }
        }
        statusMenu.showHelp = { [weak self] in self?.showHelp() }
        statusMenu.showAbout = {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(
                string: "Умный переключатель раскладки RU/EN. Работает полностью на этом Mac.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)])])
        }
        statusItem.menu = statusMenu.menu

        engine.onFix = { [weak self] fix in self?.didCorrect(fix) }
        engine.onRuleLearned = { [weak self] word, saved in self?.ruleLearned(word, saved: saved, toast: true) }
        engine.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Typer.frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        lastExternalApp = NSWorkspace.shared.frontmostApplication

        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.engine.frontmostBundleID = app?.bundleIdentifier
            Typer.frontPID = app?.processIdentifier ?? 0
            self.engine.appChanged()
            if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { self.lastExternalApp = app }
            // Back in an app: its own layout (Telegram in Russian, the code editor in English…).
            if self.settings.perAppLayout, let id = app?.bundleIdentifier, !self.settings.isExcluded(id),
               let lang = self.settings.rememberedLayout(for: id), lang != self.layouts.currentLang {
                self.layouts.select(lang)
            }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.layouts.refresh()
            self.engine.layoutChanged()
            // Remember the layout per app, whoever switched it: you, macOS or a correction.
            if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
               let lang = self.layouts.currentLang {
                self.settings.rememberLayout(lang, for: id)
            }
            self.updateStatusItem()
            self.syncModel()
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.layouts.refresh(); self?.syncModel() }

        loadDictionaries()
        // The system dictionary's first lookup takes ~20 ms: pay it now, not on the first typo.
        DispatchQueue.global(qos: .utility).async {
            for (w, l) in [("проверка", Lang.ru), ("check", .en)] { _ = SpellCorrector.isValidForm?(w, l) }
        }
        clipboard.start()
        _ = engine.start()
        syncModel()
        updateStatusItem()

        // Permissions can be granted at any time: start the engine as soon as they are. The views only need
        // polling while one is on screen; corrections and layout changes update them directly.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkSecureInput()
            if !self.engine.isRunning, AXIsProcessTrusted(), self.engine.start() { self.updateStatusItem(); self.syncModel() }
            if self.uiVisible { self.syncModel() }
            // my_*.txt edited by hand, or new words from another Mac via iCloud: pick them up by themselves.
            self.ticks += 1
            if self.ticks % 3 == 0, self.store.changedOnDisk {
                self.store.reload()
                self.loadDictionaries()
            }
        }

        if !settings.onboardingDone || !engine.isRunning { showOnboarding() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(.general)
        return true
    }

    private func loadDictionaries() {
        guard let dir = Resources.dictionaryDirectory else {
            loadError = "Словари не найдены (Resources/Dictionaries)"
            return
        }
        let learned = store.learned
        let userDir = store.folder
        loadGeneration += 1
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let c = try Classifier.load(dictionaryDir: dir, userDir: userDir, learned: learned)
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return } // a newer load is on its way
                    // Words learned while this one was loading.
                    for (l, words) in self.store.learned { for w in words where !(learned[l] ?? []).contains(w) { c.learn(w, lang: l) } }
                    self.engine.classifier = c
                    self.loadError = nil
                    self.syncModel()
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }
                    self.loadError = "Ошибка словарей: \(error.localizedDescription)"
                    self.syncModel()
                }
            }
        }
    }

    /// Accessory apps have no visible main menu, but ⌘C/⌘V/⌘A in text fields need one.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Model sync

    private var uiVisible: Bool {
        settingsWindow?.isVisible == true || onboardingWindow?.isVisible == true
    }

    private func syncModel() {
        engine.rulesChanged() // the keyboard thread reads its own copy of the rules
        model.lang = layouts.currentLang
        model.engineRunning = engine.isRunning
        model.accessibilityGranted = AXIsProcessTrusted()
        model.inputMonitoringGranted = CGPreflightListenEventAccess()
        model.hasBothLayouts = layouts.hasBothLayouts
        model.dictionariesReady = engine.classifier != nil
        model.loadError = loadError
        model.correctionsToday = engine.correctionsToday
        model.learnedCount = store.learned.values.reduce(0) { $0 + $1.count }
        model.rulesCount = store.rules.active.count
        model.saveError = store.saveError
        for i in model.recent.indices {
            let r = model.recent[i]
            model.recent[i].protected = r.typed.split(whereSeparator: \.isWhitespace).contains { w in
                store.rules.blocks(Self.core(String(w)), lang: r.from, kind: r.kind)
            }
        }
        model.frontAppName = lastExternalApp?.localizedName
        model.frontBundleID = lastExternalApp?.bundleIdentifier
        model.loginEnabled = SMAppService.mainApp.status == .enabled
        model.conflictingApps = NSWorkspace.shared.runningApplications.compactMap { app in
            let n = app.localizedName ?? ""
            return n.localizedCaseInsensitiveContains("punto") || n.localizedCaseInsensitiveContains("caramba") ? n : nil
        }
        model.touch()
    }

    // MARK: - Menu bar icon

    /// Secure keyboard entry on or off since the last second: the menu bar and the panel say so.
    private func checkSecureInput() {
        let holder = SecureInput.holder().map(\.name)
        guard holder != model.secureInputHolder else { return }
        model.secureInputHolder = holder
        model.touch()
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        statusItem.isVisible = settings.menuBarStyle != "hidden"
        let lang = layouts.currentLang
        let label = lang?.label ?? "··"
        // Coloured, so the layout is seen at a glance: RU red, EN blue. Filled — fixing is on; outline — paused.
        let color = Self.color(for: lang)
        if model.secureInputHolder != nil {
            button.image = Self.pill("🔒" + label, filled: false, color: color)
        } else if !engine.isRunning {
            button.image = Self.pill("⚠︎" + label, filled: false, color: color)
        } else if settings.menuBarStyle == "dot" {
            button.image = Self.dot(filled: settings.autoEnabled, color: color)
        } else {
            button.image = Self.pill(label, filled: settings.autoEnabled, color: color)
        }
        button.title = ""
        let state = model.secureInputHolder != nil ? "клавиши закрыты защищённым вводом"
            : !engine.isRunning ? "нет доступа" : settings.autoEnabled ? "включён" : "на паузе"
        button.setAccessibilityValue("\(state), \(label)")
    }

    /// RU red, EN blue (the system colours: they stay readable on a light and a dark menu bar).
    private static func color(for lang: Lang?) -> NSColor {
        switch lang {
        case .ru: .systemRed
        case .en: .systemBlue
        case nil: .secondaryLabelColor
        }
    }

    /// Filled with white letters when active; a coloured outline with coloured letters when paused or without access.
    private static func pill(_ label: String, filled: Bool, color: NSColor) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .kern: 0.4]
        let width = max(28, ceil(NSAttributedString(string: label, attributes: attrs).size().width) + 12)
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
            let text = NSAttributedString(string: label, attributes: attrs.merging([.foregroundColor: filled ? NSColor.white : color]) { $1 })
            let size = text.size()
            let at = NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
            if filled {
                color.setFill(); path.fill()
            } else {
                color.setStroke(); path.lineWidth = 1.2; path.stroke()
            }
            text.draw(at: at)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func dot(filled: Bool, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 4.5, dy: 4.5))
            color.set()
            if filled { path.fill() } else { path.lineWidth = 1.5; path.stroke() }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// "Как пользоваться…": everything in a few plain sentences.
    private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Как пользоваться KeySwitch"
        alert.informativeText = """
        Просто печатайте. Если слово набрано не в той раскладке — например «ghbdtn» вместо «привет», — KeySwitch сам исправит его и переключит раскладку.

        Главная кнопка — правый ⌥ (Option, справа от пробела):
        • сразу после исправления — отменить его. Это слово больше не будет исправляться;
        • курсор стоит в слове или текст выделен — перевести его в другую раскладку;
        • в остальных случаях — просто сменить раскладку.

        Значок в строке меню показывает раскладку: красный RU — русская, синий EN — английская. Закрашенный — автопереключение включено, контур — на паузе. Замок 🔒 — какая-то программа закрыла клавиши (обычно поле пароля).

        Исправило зря? Нажмите правый ⌥ сразу или откройте меню → «Последние исправления» и выберите «Это ошибка».
        """
        alert.addButton(withTitle: "Понятно")
        alert.addButton(withTitle: "Открыть настройки")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { openSettings(.general) }
    }

    // MARK: - Corrections and the toast

    /// A typo or case fix is in the same list and toast, but plays no layout-switch sound.
    private func didCorrect(_ fix: FixEvent) {
        model.recent.insert(CorrectionRecord(typed: fix.typed, result: fix.result, kind: fix.kind, to: fix.to, from: fix.from,
                                             app: lastExternalApp?.localizedName ?? "—", bundleID: lastExternalApp?.bundleIdentifier,
                                             date: Date()), at: 0)
        if model.recent.count > 20 { model.recent.removeLast(model.recent.count - 20) }
        model.ruleNotice = nil
        updateStatusItem()
        syncModel()
        if fix.kind == .layout && settings.soundEnabled { SoundPlayer.play(settings.soundChoice, volume: settings.soundVolume) }
        guard settings.showToast else { return }
        // The retyping is still running; give it a moment so the caret sits after the new word.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            CaretLocator.locate { rect in
                self.toast.show(.fix(to: fix.to, typed: fix.typed, result: fix.result, undoable: fix.undoable), near: rect, duration: 1.5)
            }
        }
    }

    /// A rule was made. The confirmation says "remembered" only once it is on disk.
    private func ruleLearned(_ word: String, saved: Bool, toast showToast: Bool) {
        model.ruleNotice = RuleNotice(word: word, saved: saved)
        syncModel()
        guard showToast, settings.showToast else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            CaretLocator.locate { rect in self.toast.show(.learned(word, saved: saved), near: rect, duration: saved ? 1.8 : 3) }
        }
    }

    private static func core(_ w: String) -> String {
        normalizeWord(w).trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    func pasteRecent(_ s: String) {
        clipboard.write(s)
        let app = lastExternalApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let app, NSWorkspace.shared.frontmostApplication != app { app.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.engine.typer.run([.command(9)]) }
        }
    }

    /// Protects the word you had typed from every automatic change from now on.
    /// The text already in the other app stays as it is: nothing is typed there.
    func protect(_ id: UUID) {
        guard let r = model.recent.first(where: { $0.id == id }) else { return }
        let words = r.typed.split(whereSeparator: \.isWhitespace).map { Self.core(String($0)) }.filter { !$0.isEmpty }
        guard let main = words.last else { return }
        for w in words {
            store.addRule(w, lang: r.from, kind: nil, result: nil, source: .manual) { [weak self] saved in
                if w == main { self?.ruleLearned(w, saved: saved, toast: false) }
            }
        }
        syncModel()
    }

    func disableSpelling() {
        settings.spellEnabled = false
        model.touch()
        syncModel()
    }

    func excludeApp(_ bundleID: String) {
        settings.setMode(.off, for: bundleID)
        engine.appChanged()
        syncModel()
    }

    func addRule(_ word: String, lang: Lang?) {
        let w = Self.core(word)
        guard !w.isEmpty else { return }
        let l = lang ?? (w.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? .ru : .en)
        store.addRule(w, lang: l, kind: nil, result: nil, source: .manual) { [weak self] _ in self?.syncModel() }
        syncModel()
    }

    func removeRule(_ id: String) {
        let hadLearned = store.learned.values.reduce(0) { $0 + $1.count }
        store.removeRule(id)
        // The word was also a learned word: rebuild the model without it, so it can be corrected again.
        if store.learned.values.reduce(0, { $0 + $1.count }) != hadLearned { reloadDictionaries() }
        syncModel()
    }

    func retrySave() {
        store.retrySave { [weak self] saved in
            guard let self else { return }
            if let n = self.model.ruleNotice { self.model.ruleNotice = RuleNotice(word: n.word, saved: saved) }
            self.syncModel()
        }
    }

    func clearClipboard() {
        clipboard.clear()
        syncModel()
    }

    func closePanel() { statusMenu.menu.cancelTracking() }

    func setLayout(_ lang: Lang) {
        layouts.select(lang)
        engine.resetAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updateStatusItem(); self.syncModel() }
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.lastError = nil
        } catch {
            model.lastError = "Автозапуск: \(error.localizedDescription). Переместите KeySwitch.app в /Applications."
            NSSound.beep()
        }
        syncModel()
    }

    func openSettings(_ pane: SettingsPane) {
        model.pane = pane
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "KeySwitch"
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        syncModel()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentView = NSHostingView(rootView: OnboardingView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        syncModel()
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func finishOnboarding() {
        settings.onboardingDone = true
        onboardingWindow?.close()
        _ = engine.start()
        updateStatusItem()
    }

    func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoring() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    func addWord(_ word: String, lang: Lang?) {
        let l = lang ?? (word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? .ru : .en)
        store.addCustomWord(word, lang: l)
        reloadDictionaries()
    }

    func forgetWord(_ word: String, lang: Lang) {
        store.forget(word, lang: lang)
        reloadDictionaries() // the classifier only adds words: rebuild it without this one
    }

    func setICloudSync(_ on: Bool) {
        guard on != settings.iCloudSync, let cloud = UserStore.cloudDirectory else { return }
        // Take your words and rules along in both directions, merging with what is already there.
        store.setCloudSync(on, cloud: cloud)
        reloadDictionaries()
    }

    func removeWord(_ word: String, lang: Lang) {
        store.removeCustomWord(word, lang: lang)
        reloadDictionaries()
    }

    func forgetLearned() {
        let alert = NSAlert()
        alert.messageText = "Забыть всё, чему KeySwitch научился?"
        alert.informativeText = "Слова из my_ru.txt / my_en.txt останутся."
        alert.addButton(withTitle: "Забыть")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.forgetAllLearned()
        reloadDictionaries()
    }

    func reloadDictionaries() {
        store.reloadCustomWords()
        layouts.refresh()
        loadDictionaries()
        syncModel()
    }

    func openUserFolder() { NSWorkspace.shared.open(UserStore.directory) }
    func quit() { NSApp.terminate(nil) }
}
