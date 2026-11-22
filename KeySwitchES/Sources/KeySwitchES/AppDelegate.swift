import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

enum Resources {
    /// Bundled dictionaries or ./Resources/Dictionaries when run from the project folder.
    static var dictionaryDirectory: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Dictionaries")) }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Dictionaries"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("es.tsv").path) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let layouts = KeyboardLayouts()
    private let store = UserStore()
    private lazy var engine = SwitchEngine(layouts: layouts, store: store)
    private lazy var clipboard = ClipboardHistory(store: store)
    private let settings = Settings.shared
    private let motion = MotionBadge()
    private let selectionPanel = SelectionSuggestionPanel()
    private lazy var preferences = PreferencesWindowController(store: store)
    private var selectionMonitors: [Any] = []
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
        NotificationCenter.default.addObserver(forName: .keySwitchClearClipboard, object: nil, queue: .main) { [weak self] _ in self?.clipboard.clear() }
        engine.onSuggestionKey = { [weak self] code, flags in
            guard flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return false }
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
        engine.onTapStopped = { [weak self] message in
            self?.lastError = message
            self?.updateStatusTitle()
        }
        engine.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        engine.typer.updateFrontmostPID(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        lastExternalApp = NSWorkspace.shared.frontmostApplication

        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.engine.frontmostBundleID = app?.bundleIdentifier
            self.engine.typer.updateFrontmostPID(app?.processIdentifier)
            self.engine.cancelPendingTyping()
            self.dismissSelectionSuggestions()
            if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { self.lastExternalApp = app }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            self?.inputSourceDidChange()
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.layouts.refresh() }

        loadDictionaries()
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

    func applicationWillTerminate(_ notification: Notification) {
        for monitor in selectionMonitors { NSEvent.removeMonitor(monitor) }
        selectionPanel.hide()
        engine.stop()
        store.flushPendingWrites()
    }

    private func loadDictionaries() {
        dictionaryLoadID &+= 1
        let loadID = dictionaryLoadID
        guard let dir = Resources.dictionaryDirectory else {
            loadError = "No se encontraron los diccionarios"
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
                    self.loadError = "Error de diccionarios: \(error.localizedDescription)"
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
            lastError = "Los permisos están concedidos, pero macOS no pudo iniciar la captura. Reinicia la aplicación."
        }
        updateStatusTitle()
    }

    /// Standard menu commands keep text fields and the settings window keyboard accessible.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "KeySwitch")
        appMenu.addItem(item("Ajustes…", #selector(showPreferences)))
        appMenu.items.last?.keyEquivalent = ","
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar KeySwitch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rehacer", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Ventana")
        windowMenu.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main; NSApp.windowsMenu = windowMenu
    }

    /// Observe independently of status rendering: other UI updates must not hide a source change.
    private func inputSourceDidChange() {
        let source = layouts.current()
        let externalChange = layouts.observeInputSource(source.id)
        if externalChange {
            engine.cancelPendingTyping()
            dismissSelectionSuggestions()
        }
        guard externalChange || source.id != lastInputSourceID else { return }
        layouts.refresh()
        updateStatusTitle()
    }

    private var secureInputExplanation: String {
        "La entrada segura de macOS bloquea la captura de teclas y las correcciones de KeySwitch. Sal del campo de contraseña o comprueba la entrada segura en otra aplicación. KeySwitch no desactiva esta protección."
    }

    private func secureInputDidChange() {
        guard secureInputState.observe(SecureInput.isEnabled) else { return }
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
        motion.setPaused(secureInputState.isEnabled || !engine.isRunning || !settings.autoEnabled)
        // Keep the local animated layout badge; the lock is a separate title, not a replacement image.
        button.title = secureInputState.isEnabled ? "🔒" : ""
        button.imagePosition = secureInputState.isEnabled ? .imageLeading : .imageOnly
        statusItem.length = secureInputState.isEnabled ? 86 : 66
        button.toolTip = secureInputState.isEnabled ? secureInputExplanation : nil
        button.setAccessibilityHelp(button.toolTip)
        button.alphaValue = 1
    }

    // MARK: - Hotkeys

    private func handle(_ hk: Hotkey) {
        waitForModifierRelease { [weak self] in
            guard let self else { return }
            switch hk {
            case .flipSelection: self.flipSelection()
            case .clipboardMenu: self.showClipboardPopup()
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

    private func withSelection(_ body: @escaping (String, ClipboardHistory.Snapshot, FocusToken) -> Void) {
        guard let focus = FocusToken.capture() else { NSSound.beep(); return }
        engine.cancelPendingTyping()
        guard let snap = clipboard.snapshot() else { NSSound.beep(); return }
        clipboard.suspend(for: 3)
        let pb = NSPasteboard.general
        let before = pb.changeCount
        engine.typer.run([.command(8), .pause(0.15)]) { finished in
            guard finished, focus.isCurrent() else {
                if pb.changeCount != before,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.pid {
                    self.clipboard.restore(snap)
                }
                return
            }
            guard pb.changeCount != before, let s = pb.string(forType: .string), !s.isEmpty else {
                if pb.changeCount != before { self.clipboard.restore(snap) }
                NSSound.beep() // nothing selected
                return
            }
            body(s, snap, focus)
        }
    }

    private func replaceSelection(with text: String, snapshot: ClipboardHistory.Snapshot,
                                  focus: FocusToken, target: Lang) {
        guard focus.isCurrent() else { return }
        let pb = NSPasteboard.general
        clipboard.suspend(for: 3)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let temporaryChange = pb.changeCount
        engine.typer.run([.command(9)]) { [weak self] finished in
            if finished && focus.isCurrent() { self?.layouts.select(target) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if pb.changeCount == temporaryChange { self?.clipboard.restore(snapshot) }
            }
        }
        engine.resetAll()
    }

    private func flipSelection() {
        guard let from = layouts.currentLang else { NSSound.beep(); return }
        withSelection { [weak self] text, snap, focus in
            guard let self else { return }
            let flipped = self.layouts.flipText(text, from: from)
            if flipped == text { self.clipboard.restore(snap) }
            else { self.replaceSelection(with: flipped, snapshot: snap, focus: focus, target: from.other) }
            if flipped == text && focus.isCurrent() { self.layouts.select(from.other) }
        }
    }

    // MARK: - Selection suggestions

    private func observeSelection() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] _ in
            self?.dismissSelectionSuggestions()
        })
        if let down { selectionMonitors.append(down) }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            self?.scheduleSelectionSuggestions()
        })
        if let up { selectionMonitors.append(up) }
        let keyUp = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp], handler: { [weak self] event in
            if event.modifierFlags.contains(.shift), (123...126).contains(event.keyCode) {
                self?.scheduleSelectionSuggestions()
            }
        })
        if let keyUp { selectionMonitors.append(keyUp) }
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
                  self.engine.isRunning, AXIsProcessTrusted(),
                  !self.settings.isExcluded(self.engine.frontmostBundleID) else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let selected = SelectedWord.capture(), selected.isCurrent() else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectionGeneration == generation else { return }
                    let choices = SelectionCandidates.make(
                        for: selected.text, classifier: self.engine.classifier,
                        preferred: self.layouts.currentLang,
                        flip: self.layouts.flipText(selected.text, from: self.layouts.currentLang ?? .en)
                    )
                    guard !choices.isEmpty else { return }
                    self.selectedWord = selected
                    self.selectionPanel.show(options: choices, bounds: selected.bounds) { [weak self] choice in
                        self?.applySelectionSuggestion(choice)
                    }
                }
            }
        }
    }

    private func applySelectionSuggestion(_ choice: String) {
        guard let selected = selectedWord else { return }
        selectionPanel.hide()
        selectedWord = nil
        selectionGeneration &+= 1
        let generation = selectionGeneration
        guard choice != selected.text else { NSSound.beep(); return }
        engine.cancelPendingTyping()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard selected.isCurrent() else { return }
            let replaced = selected.replaceDirectly(with: choice)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation else { return }
                if replaced { self.motion.acknowledgeCorrection(); self.preferences.model.record(selected.text, choice) }
                else { self.pasteSelectedSuggestion(choice, selected: selected) }
            }
        }
    }

    private func pasteSelectedSuggestion(_ choice: String, selected: SelectedWord) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selected.focus.pid else { return }
        guard selected.isCurrent() else { return }
        guard let snapshot = clipboard.snapshot() else { NSSound.beep(); return }
        clipboard.suspend(for: 3)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(choice, forType: .string)
        let temporaryChange = pb.changeCount
        engine.typer.run([.command(9)]) { [weak self] finished in
            guard let self else { return }
            if finished { self.motion.acknowledgeCorrection(); self.preferences.model.record(selected.text, choice) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if pb.changeCount == temporaryChange { self.clipboard.restore(snapshot) }
            }
        }
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
        guard let s = sender.representedObject as? String else { return }
        clipboard.write(s)
        let app = lastExternalApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let app, NSWorkspace.shared.frontmostApplication != app { app.activate(options: []) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                self.engine.typer.run([.command(9)])
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
        let state = secureInputState.isEnabled ? "🔒 Entrada segura" : (engine.isRunning && settings.autoEnabled ? "Activo" : "En pausa")
        menu.addItem(ClipboardHistory.header("KeySwitch · \(language) · \(state)"))
        if secureInputState.isEnabled {
            menu.addItem(ClipboardHistory.header("macOS bloquea la captura de teclas y las correcciones."))
            menu.addItem(ClipboardHistory.header("Sal del campo de contraseña o comprueba otra aplicación."))
            menu.addItem(ClipboardHistory.header("KeySwitch no desactiva la protección de otras aplicaciones."))
        }
        for error in [loadError, lastError, store.saveError].compactMap({ $0 }) {
            menu.addItem(ClipboardHistory.header("⚠︎ " + error))
        }
        if !layouts.hasBothLayouts { menu.addItem(ClipboardHistory.header("Activa los teclados español e inglés")) }
        menu.addItem(.separator())
        menu.addItem(item("Correcciones automáticas", #selector(toggleAuto), checked: settings.autoEnabled))
        menu.addItem(item(engine.isRunning ? "Pausar KeySwitch" : "Reanudar KeySwitch", #selector(toggleInterception)))
        if let app = lastExternalApp, let id = app.bundleIdentifier {
            let entry = item("No corregir en \(app.localizedName ?? id)", #selector(toggleExclude(_:)), checked: settings.isExcluded(id))
            entry.representedObject = id
            menu.addItem(entry)
        }
        let clipItem = NSMenuItem(title: "Portapapeles · ⌃⌥V", action: nil, keyEquivalent: "")
        let clipMenu = NSMenu()
        for entry in clipboard.buildItems(target: self, paste: #selector(pasteClip(_:)), pin: #selector(pinClip(_:))) { clipMenu.addItem(entry) }
        clipItem.submenu = clipMenu
        menu.addItem(clipItem)
        menu.addItem(.separator())
        let settingsItem = item("Ajustes…", #selector(showPreferences))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(ClipboardHistory.header("Cambios hoy: \(engine.correctionsToday)"))
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func showPreferences() { preferences.present() }

    private func item(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = checked ? .on : .off
        return i
    }

    private func rulesMenuItem() -> NSMenuItem {
        let active = store.rules.active
        let top = NSMenuItem(title: "No corregir palabras (\(active.count))", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for language in Lang.allCases {
            let languageItem = NSMenuItem(title: language.rawValue.uppercased(), action: nil, keyEquivalent: "")
            let languageMenu = NSMenu()
            let choices: [(String, FixKind?)] = [
                ("Añadir: no cambiar teclado…", .layout),
                ("Añadir: no corregir erratas…", .spell),
                ("Añadir: no corregir nunca…", nil),
            ]
            for (title, kind) in choices {
                let entry = item(title, #selector(addRuleFromMenu(_:)))
                entry.representedObject = "\(language.rawValue)|\(kind?.rawValue ?? "all")"
                languageMenu.addItem(entry)
            }
            let existing = active.filter { $0.lang == language }
            if !existing.isEmpty {
                languageMenu.addItem(.separator())
                for rule in existing {
                    let scope: String
                    switch rule.kind {
                    case .layout: scope = "teclado"
                    case .spell: scope = "erratas"
                    case .caseFix: scope = "mayúsculas"
                    case nil: scope = "todos los cambios"
                    }
                    let entry = item("Eliminar: \(rule.word) · \(scope)", #selector(removeRuleFromMenu(_:)))
                    entry.representedObject = rule.id
                    languageMenu.addItem(entry)
                }
            }
            languageItem.submenu = languageMenu
            menu.addItem(languageItem)
        }
        top.submenu = menu
        return top
    }

    @objc private func addRuleFromMenu(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let parts = key.split(separator: "|")
        guard parts.count == 2, let lang = Lang(rawValue: String(parts[0])) else { return }
        let kind = parts[1] == "all" ? nil : FixKind(rawValue: String(parts[1]))
        guard parts[1] == "all" || kind != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Palabra que no se debe corregir"
        alert.informativeText = "Idioma: \(lang.rawValue.uppercased()). Una palabra sin espacios."
        alert.addButton(withTitle: "Añadir")
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Escribe una palabra"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.addRule(word, lang: lang, kind: kind) == nil { NSSound.beep() }
    }

    @objc private func removeRuleFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.removeRule(id)
        loadDictionaries()
    }

    // MARK: - Menu actions

    @objc private func toggleAuto() { settings.autoEnabled.toggle(); engine.resetAll(); updateStatusTitle() }
    @objc private func toggleCautious() { settings.cautiousMode.toggle(); engine.resetAll() }
    @objc private func toggleSpell() { settings.spellEnabled.toggle(); engine.resetAll() }
    @objc private func toggleSelectionSuggestions() {
        settings.selectionSuggestionsEnabled.toggle()
        dismissSelectionSuggestions()
    }
    @objc private func toggleInterception() {
        if engine.isRunning {
            engine.stop()
        } else if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
            lastError = "Comprueba los permisos de esta copia: Accesibilidad y Monitorización de entrada."
        } else if engine.start() {
            lastError = nil
        } else {
            lastError = "Los permisos están concedidos, pero macOS no pudo iniciar la captura. Reinicia la aplicación."
        }
        updateStatusTitle()
    }
    @objc private func toggleSound() { settings.sound.toggle() }
    @objc private func toggleExclude(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.toggleExcluded(id)
    }
    @objc private func menuFlip() { refocus { self.flipSelection() } }
    @objc private func clearClipboard() { clipboard.clear() }

    private func refocus(_ body: @escaping () -> Void) {
        guard let app = lastExternalApp else { return }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            body()
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openUserFolder() { NSWorkspace.shared.open(UserStore.directory) }
    @objc private func reloadDictionaries() { layouts.refresh(); loadDictionaries() }

    @objc private func forgetLearned() {
        guard confirm("¿Olvidar todas las palabras aprendidas?", "Las palabras de my_es.txt y my_en.txt se conservarán.") else { return }
        store.forgetAllLearned()
        loadDictionaries()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            lastError = "Inicio automático: \(error.localizedDescription). Mueve KeySwitchES.app a /Applications."
            NSSound.beep()
        }
    }

    @objc private func showHelp() {
        info("KeySwitch ES — cómo se usa", """
        • Escribe normalmente. Después de una palabra reconocible, el teclado cambia a inglés o español. Los símbolos distintos entre teclados también se pueden corregir.
        • Las erratas claras se corrigen al terminar una palabra. Puedes activar o desactivar «Corregir erratas» en el menú.
        • Las letras A–Z coinciden en ambos teclados: palabras sin acentos suelen quedar tal como las escribiste.
        • Modo prudente: si una corrección es dudosa, un destello naranja propone corregirla con ⌥ derecho sin cambiar el texto automáticamente.
        • ⌥ derecho: deshacer una corrección o corregir la palabra actual.
        • ⌃⌥R: cambiar el teclado del texto seleccionado.
        • Selecciona una palabra con el ratón o con Mayús+flecha: aparecerán sugerencias y opciones de mayúsculas encima. Solo se cambia al elegir una opción.
        • ⌃⌥V: historial del portapapeles; clic o números 1–9 para pegar, ⌥ para fijar.
        • Tus palabras: Diccionarios → my_es.txt / my_en.txt.
        • Excepciones de teclado y erratas: Diccionarios → «No corregir palabras».
        """)
    }

    // MARK: - Dialog helpers

    private func info(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Sí")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
