import AppKit
import SwiftUI
import ApplicationServices
import Carbon

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let layouts = KeyboardLayouts()
    private let store = UserStore()
    private lazy var engine = SwitchEngine(
        layouts: layouts, store: store,
        readFrontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        verifyBackspaceUndo: CommandLine.arguments.contains("--backspace-undo") ? { text, pid in
            FocusToken.capture(expectedPID: pid)?.matchesTextBeforeCaret(text) == true
        } : nil,
        acceptsSpelling: { SystemSpelling.accepts($0, lang: $1) }
    )
    private lazy var clipboard = ClipboardHistory(store: store)
    private let settings = Settings.shared
    private let motion = MotionBadge()
    private let selectionPanel = SelectionSuggestionPanel()
    private lazy var preferences = PreferencesWindowController(store: store) { model in
        AnyView(ApplicationProfilesView(model: model))
    }
    private var selectionMonitors: [Any] = []
    /// Processes already asked to expose their web accessibility tree (main thread only).
    private var webContentRequested: Set<pid_t> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var selectionGeneration: UInt64 = 0
    private var selectedWord: SelectedWord?
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var inputSourceTimer: Timer?
    private var secureInputState = SecureInputState()
    private var lastInputSourceID: String?
    private var lastExternalApp: NSRunningApplication?
    private var lastError: String?
    private var loadError: String?
    private var dictionaryLoadID: UInt64 = 0

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        preferences.model.onChange = { [weak self] in
            self?.engine.cancelPendingTyping()
            self?.dismissSelectionSuggestions()
            self?.clipboard.poll()
            self?.updateStatusTitle()
        }
        preferences.model.reload = { [weak self] in self?.loadDictionaries() }
        observe(NotificationCenter.default, .keySwitchClearClipboard) { [weak self] _ in self?.clipboard.clear() }
        engine.onSuggestionKey = { [weak self] code, flags in
            guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty else { return false }
            return self?.selectionPanel.handleKey(code) ?? false
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 66)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        secureInputDidChange()
        updateStatusTitle()

        engine.onHotkey = { [weak self] hk in self?.handle(hk) }
        engine.onCorrection = { [weak self] original, replacement in
            self?.preferences.model.record(original, replacement)
            self?.motion.acknowledgeCorrection()
            self?.updateStatusTitle()
        }
        engine.onSuggestion = { [weak self] in self?.motion.suggestCorrection() }
        engine.onManualFixAtCaret = { [weak self] in self?.fixWordAtCaret() }
        engine.onTapStopped = { [weak self] message in
            self?.lastError = message
            self?.updateStatusTitle()
        }
        engine.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        engine.typer.updateFrontmostPID(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        lastExternalApp = NSWorkspace.shared.frontmostApplication

        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.engine.frontmostBundleID = app?.bundleIdentifier
            self.engine.typer.updateFrontmostPID(app?.processIdentifier)
            self.engine.cancelPendingTyping()
            self.dismissSelectionSuggestions()
            if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { self.lastExternalApp = app }
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)) { [weak self] _ in
            self?.inputSourceDidChange()
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)) { [weak self] _ in self?.layouts.refresh() }

        loadDictionaries()
        DispatchQueue.main.async { SystemSpelling.warmUp() }
        clipboard.start()
        startEngineWhenTrusted()
        observeSelection()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.engine.typer.updateFrontmostPID(NSWorkspace.shared.frontmostApplication?.processIdentifier)
            self?.secureInputDidChange()
            self?.inputSourceDidChange()
        }
        RunLoop.main.add(timer, forMode: .common)
        inputSourceTimer = timer
        if CommandLine.arguments.contains("--settings") { preferences.present() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !selectionPanel.isVisible else { return false }
        preferences.present()
        return false
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         handler: @escaping @Sendable (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
        observers.append((center, token))
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        inputSourceTimer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for monitor in selectionMonitors { NSEvent.removeMonitor(monitor) }
        selectionPanel.hide()
        engine.stop()
        store.flushPendingWrites()
    }

    private func loadDictionaries() {
        dictionaryLoadID &+= 1
        let loadID = dictionaryLoadID
        guard let dir = Resources.dictionaryDirectory else {
            loadError = "Словари не найдены (Resources/Dictionaries)"
            return
        }
        let learned = store.learned
        let userDir = UserStore.directory
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let c = try Classifier.load(dictionaryDir: dir, userDir: userDir, learned: learned)
                DispatchQueue.main.async {
                    guard self.dictionaryLoadID == loadID else { return }
                    // Words learned while the background load was running must
                    // not disappear from the live classifier.
                    for (lang, words) in self.store.learned {
                        let loaded = Set(learned[lang] ?? [])
                        for word in words where !loaded.contains(word) { c.learn(word, lang: lang) }
                    }
                    self.engine.classifier = c
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.dictionaryLoadID == loadID else { return }
                    self.loadError = "Ошибка словарей: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startEngineWhenTrusted() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(opts)
        let inputMonitoring = CGPreflightListenEventAccess()
        if !inputMonitoring { _ = CGRequestListenEventAccess() }
        if accessibility && inputMonitoring { startEngine(); return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if AXIsProcessTrusted(), CGPreflightListenEventAccess() {
                t.invalidate()
                self.permissionTimer = nil
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        if engine.start() {
            lastError = nil
        } else {
            lastError = "Разрешения выданы, но macOS не создала перехват клавиш. Перезапустите приложение."
        }
        updateStatusTitle()
    }

    /// Standard menu commands keep text fields and the settings window keyboard accessible.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "KeySwitch")
        appMenu.addItem(item("Настройки…", #selector(showPreferences)))
        appMenu.items.last?.keyEquivalent = ","
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть KeySwitch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main; NSApp.windowsMenu = windowMenu
    }

    /// Observe independently of status rendering: other UI updates must not hide a source change.
    private func inputSourceDidChange() {
        let source = layouts.current()
        let externalChange = engine.inputSourceDidChange(to: source.id)
        if externalChange { dismissSelectionSuggestions() }
        guard externalChange || source.id != lastInputSourceID else { return }
        layouts.refresh()
        updateStatusTitle()
    }

    private var secureInputExplanation: String {
        "Защищённый ввод macOS блокирует перехват клавиш и исправления KeySwitch. Выйдите из поля пароля или проверьте защищённый ввод в другом приложении. KeySwitch не отключает эту защиту."
    }

    private func secureInputDidChange() {
        guard secureInputState.observe(SecureInput.isEnabled) else { return }
        KeyboardDiagnostics.record(.secureInputChanged)
        engine.cancelPendingTyping()
        dismissSelectionSuggestions()
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let source = layouts.current()
        lastInputSourceID = source.id
        if button.image == nil { motion.attach(to: button, language: source.lang) }
        motion.show(source.lang)
        motion.setPaused(secureInputState.isEnabled || !engine.isRunning || (!settings.autoEnabled && !settings.spellEnabled))
        // Keep the local animated layout badge; the lock is a separate title, not a replacement image.
        button.title = secureInputState.isEnabled ? "🔒" : ""
        button.imagePosition = secureInputState.isEnabled ? .imageLeading : .imageOnly
        statusItem.length = secureInputState.isEnabled ? 86 : 66
        button.toolTip = secureInputState.isEnabled ? secureInputExplanation : "Выбрать раскладку или открыть настройки"
        button.setAccessibilityHelp(button.toolTip)
        button.alphaValue = 1
    }

    // MARK: - Hotkeys

    private func handle(_ hk: Hotkey) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        waitForModifierRelease { [weak self] in
            self?.engine.afterTyping { [weak self] in
                guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !SecureInput.isEnabled else { return }
                switch hk {
                case .flipSelection:
                    if !self.settings.isExcluded(self.engine.frontmostBundleID) { self.flipSelection() }
                case .clipboardMenu: self.showClipboardPopup()
                }
            }
        }
    }

    /// Posting ⌘C while ⌃⌥ are still physically held would send ⌃⌥⌘C to the app.
    private func waitForModifierRelease(attempt: Int = 0, _ body: @escaping () -> Void) {
        let f = CGEventSource.flagsState(.combinedSessionState)
        if attempt > 40 { return }
        if !f.contains(.maskControl) && !f.contains(.maskAlternate) && !f.contains(.maskCommand) {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            self.waitForModifierRelease(attempt: attempt + 1, body)
        }
    }

    private func flipSelection() {
        dismissSelectionSuggestions()
        let generation = selectionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let selected = SelectedWord.capture(includePhrases: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation, !SecureInput.isEnabled else { return }
                guard let selected else { NSSound.beep(); return }
                let flipped = self.layouts.flipText(selected.text)
                guard flipped != selected.text else { NSSound.beep(); return }
                self.selectedWord = selected
                let cyrillic = flipped.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
                self.applySelectionSuggestion(flipped, switchTo: cyrillic ? .ru : .en)
            }
        }
    }

    // MARK: - Selection suggestions

    /// Right ⌥ next to a word that was missed earlier: put the caret inside the word or at
    /// its edge, tap, and the word is re-read in the other layout (or a typo fix is offered).
    private func fixWordAtCaret() {
        dismissSelectionSuggestions()
        let generation = selectionGeneration
        guard engine.isRunning, AXIsProcessTrusted(), !SecureInput.isEnabled,
              !settings.isExcluded(engine.frontmostBundleID) else { return }
        let extra = layouts.letterPunctuation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let capture = SelectedWord.captureAtCaret(extra: extra)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation, self.engine.isRunning,
                      !SecureInput.isEnabled, !self.settings.isExcluded(self.engine.frontmostBundleID) else { return }
                switch capture {
                case .noWord, .unsupported:
                    return
                case .word(let token):
                    // A word KeySwitch changed earlier: put the user's own word back and remember it.
                    if self.restoreRecentCorrection(in: token) { return }
                    guard let plan = CaretFix.plan(token: token.text, classifier: self.engine.classifier,
                                                   mixed: { self.layouts.repairMixedWord($0, classifier: self.engine.classifier) },
                                                   flip: { self.layouts.flipText($0) }) else { NSSound.beep(); return }
                    let selected = token.narrowed(dropFirst: plan.dropFirst, dropLast: plan.dropLast)
                    self.selectedWord = selected
                    let apply: (String) -> Void = { [weak self] choice in
                        guard let self, self.applySelectionSuggestion(choice) else { return }
                        self.learn(choice, from: plan)
                        // A manual change toggles: the next tap on this word puts the old text back.
                        let cyrillic = plan.word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
                        self.engine.record(replacement: choice, original: plan.word, lang: cyrillic ? .ru : .en,
                                           kind: choice == plan.flip ? .layout : .spell, automatic: false)
                    }
                    if plan.choices.count == 1 {
                        apply(plan.choices[0])
                    } else {
                        self.selectionPanel.show(options: plan.choices, bounds: selected.bounds, onChoose: apply)
                    }
                }
            }
        }
    }

    /// Right ⌥ on a word that KeySwitch replaced in the last minutes restores what was typed.
    /// For an automatic change the restore is also an exception, so it is not repeated.
    private func restoreRecentCorrection(in token: SelectedWord) -> Bool {
        let chars = Array(token.text)
        let lead = chars.prefix { !$0.isLetter }.count
        let trail = chars.reversed().prefix { !$0.isLetter }.count
        guard lead + trail < chars.count else { return false }
        let core = String(chars[lead..<(chars.count - trail)])
        guard let correction = engine.recentCorrection(producing: core) else { return false }
        selectedWord = token.narrowed(dropFirst: lead, dropLast: trail)
        let switchTo = correction.automatic && correction.kind == .layout ? correction.lang : nil
        if applySelectionSuggestion(correction.original, switchTo: switchTo) {
            engine.remember(correction, source: .undo)
        }
        return true
    }

    private func learn(_ choice: String, from plan: CaretFix.Plan) {
        if choice == plan.flip, plan.learnFlip { engine.learnPositive(choice, lang: plan.target) }
    }

    private func observeSelection() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Typer.marker else { return }
            self?.dismissSelectionSuggestions()
        })
        if let down { selectionMonitors.append(down) }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            self?.scheduleSelectionSuggestions()
            self?.checkCaretAfterClick()
        })
        if let up { selectionMonitors.append(up) }
        let keyUp = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp], handler: { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Typer.marker,
               event.modifierFlags.contains(.shift), (123...126).contains(event.keyCode) {
                self?.scheduleSelectionSuggestions()
            }
        })
        if let keyUp { selectionMonitors.append(keyUp) }
    }

    /// A click usually lands in an empty field or after the last word (a chat box). Ask the
    /// editor whether the caret is between words, so the first word is checked like any other.
    private func checkCaretAfterClick() {
        guard engine.isRunning, !SecureInput.isEnabled, !settings.isExcluded(engine.frontmostBundleID) else { return }
        let revision = engine.clickRevision
        // The global monitor sees mouse-up before the editor has moved its caret: reading at once
        // returns the old position. A short delay is still well before the first keystroke.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let token = FocusToken.capture()
            let atBoundary = token?.caretIsAtWordBoundary()
            let pid = token?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            DispatchQueue.main.async {
                guard let self else { return }
                switch atBoundary {
                case true?:
                    self.engine.caretVerifiedAtBoundary(clickRevision: revision)
                case false?:
                    break // the caret is inside a word: leave the next keys alone
                case nil:
                    // Unreadable is not "mid-word": an Electron chat box hides its field until
                    // asked. Ask once per process so later clicks can be checked precisely.
                    self.engine.caretUnreadableAfterClick(clickRevision: revision)
                    if let pid, self.webContentRequested.insert(pid).inserted {
                        DispatchQueue.global(qos: .utility).async { FocusToken.exposeWebContent(pid: pid) }
                    }
                }
            }
        }
    }

    private func dismissSelectionSuggestions() {
        selectionGeneration &+= 1
        selectedWord = nil
        selectionPanel.hide()
    }

    private func scheduleSelectionSuggestions() {
        dismissSelectionSuggestions()
        let generation = selectionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.selectionGeneration == generation,
                  self.settings.selectionSuggestionsEnabled,
                  self.engine.isRunning, AXIsProcessTrusted(), !SecureInput.isEnabled,
                  !self.settings.isExcluded(self.engine.frontmostBundleID) else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let selected = SelectedWord.capture(), selected.isCurrent() else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectionGeneration == generation else { return }
                    var choices = SelectionCandidates.make(
                        for: selected.text, classifier: self.engine.classifier,
                        preferred: self.layouts.currentLang,
                        flip: self.layouts.flipText(selected.text)
                    )
                    // The word KeySwitch replaced comes first: selecting "беги" offers "баги" back.
                    let recent = self.engine.recentCorrection(producing: selected.text)
                    if let recent, recent.original != selected.text {
                        choices = Array(([recent.original] + choices.filter { $0 != recent.original }).prefix(3))
                    }
                    guard !choices.isEmpty else { return }
                    self.selectedWord = selected
                    self.selectionPanel.show(options: choices, bounds: selected.bounds) { [weak self] choice in
                        guard let self else { return }
                        let restoring = recent.map { $0.original == choice } ?? false
                        let switchTo = restoring && recent?.automatic == true && recent?.kind == .layout ? recent?.lang : nil
                        if self.applySelectionSuggestion(choice, switchTo: switchTo), restoring, let recent {
                            self.engine.remember(recent, source: .undo)
                        }
                    }
                }
            }
        }
    }

    /// Scheduled callers check selectionGeneration on main before reaching this point.
    /// A single AX request replaces the verified range. AX does not offer compare-and-swap.
    @discardableResult
    private func applySelectionSuggestion(_ choice: String, switchTo target: Lang? = nil) -> Bool {
        guard let selected = selectedWord, !SecureInput.isEnabled else { return false }
        selectionPanel.hide()
        selectedWord = nil
        selectionGeneration &+= 1
        guard choice != selected.text else { NSSound.beep(); return false }
        engine.cancelPendingTyping()
        guard selected.selectIfCaretCurrent(), selected.replaceDirectly(with: choice) else {
            NSSound.beep()
            return false
        }
        if let target { layouts.select(target) }
        motion.acknowledgeCorrection()
        preferences.model.record(selected.text, choice)
        return true
    }

    private func showClipboardPopup() {
        let menu = NSMenu()
        for item in clipboard.buildItems(target: self, paste: #selector(pasteClip(_:)), pin: #selector(pinClip(_:))) {
            menu.addItem(item)
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pasteClip(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let app = lastExternalApp,
              !SecureInput.isEnabled else { return }
        clipboard.write(s)
        let change = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard !SecureInput.isEnabled, NSPasteboard.general.changeCount == change,
                  currentPID == app.processIdentifier || currentPID == ProcessInfo.processInfo.processIdentifier else { return }
            if currentPID != app.processIdentifier { app.activate(options: []) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      !SecureInput.isEnabled, NSPasteboard.general.changeCount == change else { return }
                self.engine.typer.updateFrontmostPID(app.processIdentifier)
                self.engine.typer.run([.command(9)], targetPID: app.processIdentifier)
            }
        }
    }

    @objc private func pinClip(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        clipboard.togglePin(s)
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        secureInputDidChange()
        menu.removeAllItems()
        let language = layouts.currentLang?.label ?? "—"
        let state: String
        if secureInputState.isEnabled { state = "🔒 Защищённый ввод" }
        else if !engine.isRunning { state = "Пауза" }
        else { state = settings.autoEnabled || settings.spellEnabled ? "Работает" : "Ручной режим" }
        menu.addItem(ClipboardHistory.header("KeySwitch · \(language) · \(state)"))
        if secureInputState.isEnabled {
            menu.addItem(ClipboardHistory.header("macOS блокирует перехват клавиш и исправления."))
            menu.addItem(ClipboardHistory.header("Выйдите из поля пароля или проверьте другое приложение."))
            menu.addItem(ClipboardHistory.header("KeySwitch не отключает защиту других приложений."))
        }
        for error in [loadError, lastError, store.saveError].compactMap({ $0 }) {
            menu.addItem(ClipboardHistory.header("⚠︎ " + error))
        }
        if !layouts.hasBothLayouts { menu.addItem(ClipboardHistory.header("Включите русскую и английскую раскладки")) }
        menu.addItem(.separator())
        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        for lang in Lang.allCases {
            let option = item(lang == .en ? "English · EN" : "Русский · RU", #selector(selectLanguage(_:)),
                              checked: layouts.currentLang == lang)
            option.representedObject = lang.rawValue
            option.isEnabled = layouts.preferred[lang] != nil
            languageMenu.addItem(option)
        }
        let switchItem = NSMenuItem(title: "Сменить раскладку", action: nil, keyEquivalent: "")
        switchItem.submenu = languageMenu
        menu.addItem(switchItem)
        menu.addItem(item("Автосмена раскладки", #selector(toggleAuto), checked: settings.autoEnabled))
        menu.addItem(item("Исправлять опечатки", #selector(toggleSpell), checked: settings.spellEnabled))
        menu.addItem(item(engine.isRunning ? "Приостановить KeySwitch" : "Возобновить KeySwitch", #selector(toggleInterception)))
        if let app = lastExternalApp, let id = app.bundleIdentifier {
            let entry = NSMenuItem(title: "Режим в \(app.localizedName ?? id)", action: nil, keyEquivalent: "")
            let modes = NSMenu()
            let current = settings.applicationModes[id] ?? .inherit
            for mode in ApplicationCorrectionMode.allCases {
                let option = item(mode.title, #selector(setApplicationMode(_:)), checked: mode == current)
                option.representedObject = [id, mode.rawValue]
                modes.addItem(option)
            }
            entry.submenu = modes
            menu.addItem(entry)
        }
        let clipItem = NSMenuItem(title: "Буфер обмена · ⌃⌥V", action: nil, keyEquivalent: "")
        let clipMenu = NSMenu()
        for entry in clipboard.buildItems(target: self, paste: #selector(pasteClip(_:)), pin: #selector(pinClip(_:))) { clipMenu.addItem(entry) }
        clipItem.submenu = clipMenu
        menu.addItem(clipItem)
        let historyCount = store.corrections.count
        let history = item("Очистить историю замен (\(historyCount))", #selector(clearCorrectionHistory))
        history.isEnabled = historyCount > 0
        menu.addItem(history)
        menu.addItem(.separator())
        let settingsItem = item("Настройки…", #selector(showPreferences))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("Как пользоваться…", #selector(showHelp)))
        menu.addItem(ClipboardHistory.header("Исправлено сегодня: \(engine.correctionsToday)"))
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// The exceptions you made stay; only the list used to put replaced words back is erased.
    @objc private func clearCorrectionHistory() {
        let alert = NSAlert()
        alert.messageText = "Очистить историю замен?"
        alert.informativeText = "KeySwitch перестанет узнавать уже заменённые слова, поэтому правый ⌥ не сможет вернуть их исходный вид. Ваши исключения сохранятся."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearCorrections()
    }

    @objc private func showPreferences() { preferences.present() }
    @objc private func showHelp() { preferences.presentHelp() }

    private func item(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = checked ? .on : .off
        return i
    }

    // MARK: - Menu actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = Lang(rawValue: raw) else { return }
        if layouts.select(language) { inputSourceDidChange() } else { NSSound.beep() }
    }

    @objc private func toggleAuto() { settings.autoEnabled.toggle(); preferences.model.onChange(); preferences.model.refresh() }
    @objc private func toggleSpell() { settings.spellEnabled.toggle(); preferences.model.onChange(); preferences.model.refresh() }
    @objc private func toggleInterception() {
        if engine.isRunning {
            engine.stop()
        } else if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
            lastError = "Проверьте разрешения для этой копии приложения: Универсальный доступ и Мониторинг ввода."
        } else if engine.start() {
            lastError = nil
        } else {
            lastError = "Разрешения выданы, но macOS не создала перехват клавиш. Перезапустите приложение."
        }
        updateStatusTitle()
    }
    @objc private func setApplicationMode(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2,
              let mode = ApplicationCorrectionMode(rawValue: values[1]) else { return }
        settings.setApplicationMode(mode, for: values[0])
        preferences.model.onChange()
        preferences.model.refresh()
    }
}
