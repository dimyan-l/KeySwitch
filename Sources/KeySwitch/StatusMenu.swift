import AppKit

/// The menu under the RU / EN icon. A plain macOS menu, like Punto Switcher and Caramba Switcher have:
/// ticks for what is on, everyday words, the key hint next to the item. Built afresh every time it opens.
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let model: AppModel
    private var settings: Settings { model.settings }
    private var actions: AppActions? { model.actions }

    /// Called before the menu is built, to bring the model up to date.
    var willOpen: (() -> Void)?
    /// "Исправить слово у курсора": runs right ⌥'s action in the app you were typing in.
    var fixAtCaret: (() -> Void)?
    var showHelp: (() -> Void)?
    var showAbout: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        willOpen?()
        menu.removeAllItems()
        handlers = [:]
        build()
    }

    // MARK: Building

    private func build() {
        header()
        menu.addItem(.separator())

        toggle("Автопереключение раскладки", on: settings.autoEnabled) { [weak self] in self?.flip(\.autoEnabled) }
        toggle("Исправлять опечатки", on: settings.spellEnabled) { [weak self] in self?.flip(\.spellEnabled) }
        toggle("Переключать посреди слова", on: settings.earlySwitch, enabled: settings.autoEnabled) { [weak self] in self?.flip(\.earlySwitch) }
        if let id = model.frontBundleID, let name = model.frontAppName, !settings.isAlwaysExcluded(id) {
            let off = settings.mode(for: id) == .off
            toggle("Не исправлять в «\(name)»", on: off) { [weak self] in
                guard let self else { return }
                self.settings.setMode(off ? .all : .off, for: id)
                self.model.touch()
                self.model.onSettingsChanged?()
            }
        }

        menu.addItem(.separator())
        menu.addItem(sectionTitle("Раскладка"))
        for l in [Lang.ru, .en] {
            let item = action(l == .ru ? "Русская" : "Английская", hint: l.label) { [weak self] in self?.actions?.setLayout(l) }
            item.state = model.lang == l ? .on : .off
            item.indentationLevel = 1
        }
        action("Исправить слово или выделенное", hint: "правый ⌥") { [weak self] in self?.fixAtCaret?() }

        menu.addItem(.separator())
        recentCorrections()
        recentCopies()

        menu.addItem(.separator())
        let more = NSMenu()
        add(toggle("Звук при переключении", on: settings.soundEnabled) { [weak self] in self?.flip(\.soundEnabled) }, to: more)
        add(toggle("Подсказка после исправления", on: settings.showToast) { [weak self] in self?.flip(\.showToast) }, to: more)
        add(toggle("Показывать скопированное", on: settings.clipboardEnabled) { [weak self] in self?.flip(\.clipboardEnabled) }, to: more)
        more.addItem(.separator())
        add(action("Слова-исключения и мои слова…") { [weak self] in self?.actions?.openSettings(.words) }, to: more)
        add(action("Программы-исключения…") { [weak self] in self?.actions?.openSettings(.apps) }, to: more)
        submenu("Ещё", more)

        menu.addItem(.separator())
        action("Как пользоваться…") { [weak self] in self?.showHelp?() }
        action("Настройки…", key: ",") { [weak self] in self?.actions?.openSettings(.general) }
        action("О программе KeySwitch") { [weak self] in self?.showAbout?() }
        menu.addItem(.separator())
        action("Выйти из KeySwitch", key: "q") { [weak self] in self?.actions?.quit() }
    }

    /// What is going on, in one line, plus whatever needs your attention.
    private func header() {
        let (text, color) = status
        let item = NSMenuItem()
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color, .font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor]))
        item.attributedTitle = title
        item.isEnabled = false
        menu.addItem(item)
        if model.correctionsToday > 0 {
            let today = NSMenuItem(title: "    " + MenuPanelText.today(model.correctionsToday), action: nil, keyEquivalent: "")
            today.isEnabled = false
            menu.addItem(today)
        }

        if !model.engineRunning {
            action("⚠️ Выдать разрешения…") { [weak self] in self?.actions?.showOnboarding() }
        }
        if let holder = model.secureInputHolder {
            let what = holder.isEmpty ? "Клавиши закрыты защищённым вводом" : "Клавиши закрыла программа «\(holder)»"
            action("🔒 \(what) — что делать?") { [weak self] in self?.secureInputHelp(holder) }
        }
        for w in warnings { info("⚠️ " + w) }
        if model.saveError != nil {
            action("⚠️ Исключения не сохранены — повторить") { [weak self] in self?.actions?.retrySave() }
        }
    }

    private var status: (String, NSColor) {
        if !model.engineRunning { return ("Нет доступа к клавиатуре", .systemOrange) }
        if model.secureInputHolder != nil { return ("Не видит клавиш", .systemOrange) }
        if !settings.autoEnabled { return ("На паузе: только правый ⌥", .secondaryLabelColor) }
        if let e = model.loadError, !e.isEmpty { return ("Словари не загрузились", .systemOrange) }
        if !model.dictionariesReady { return ("Загружаю словари…", .systemBlue) }
        if !model.hasBothLayouts { return ("Нет русской или английской раскладки", .systemOrange) }
        if let id = model.frontBundleID, settings.mode(for: id) == .off {
            return ("Не исправляет в «\(model.frontAppName ?? "этой программе")»", .secondaryLabelColor)
        }
        return ("KeySwitch работает", .systemGreen)
    }

    private var warnings: [String] {
        var w: [String] = []
        if let e = model.loadError, !e.isEmpty { w.append(e) }
        if model.engineRunning && !model.hasBothLayouts { w.append("Добавьте русскую и английскую раскладки в настройках Mac") }
        if let e = model.lastError { w.append(String(e.prefix(80))) }
        return w
    }

    /// Each correction opens "Это ошибка" choices; a protected one is ticked.
    private func recentCorrections() {
        let sub = NSMenu()
        sub.autoenablesItems = false
        if model.recent.isEmpty {
            let none = NSMenuItem(title: "Пока ничего — пишите как обычно", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for r in model.recent.prefix(10) {
            let row = NSMenuItem(title: "\(r.typed)  →  \(r.result)", action: nil, keyEquivalent: "")
            row.toolTip = "\(r.kind.title) · \(r.app) · \(MenuPanelText.ago(r.date))"
            let word = MenuPanelText.mainWord(r)
            let choices = NSMenu()
            choices.autoenablesItems = false
            let about = NSMenuItem(title: "\(r.kind.title) · \(r.app) · \(MenuPanelText.ago(r.date))", action: nil, keyEquivalent: "")
            about.isEnabled = false
            choices.addItem(about)
            choices.addItem(.separator())
            if r.protected {
                row.state = .on
                let done = NSMenuItem(title: "«\(word)» больше не исправляется", action: nil, keyEquivalent: "")
                done.isEnabled = false
                choices.addItem(done)
            } else {
                add(action("Это ошибка: не исправлять «\(word)»") { [weak self] in self?.actions?.protect(r.id) }, to: choices)
                if r.kind == .spell {
                    add(action("Не исправлять опечатки вообще") { [weak self] in self?.actions?.disableSpelling() }, to: choices)
                } else if let id = r.bundleID {
                    add(action("Не исправлять в «\(r.app)»") { [weak self] in self?.actions?.excludeApp(id) }, to: choices)
                }
            }
            row.submenu = choices
            sub.addItem(row)
        }
        if !model.recent.isEmpty {
            sub.addItem(.separator())
            let hint = NSMenuItem(title: "Текст в программе не изменится — это для следующих раз", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
        }
        submenu("Последние исправления", sub)
    }

    private func recentCopies() {
        let items = Array(model.clipboard.items.prefix(ClipboardHistory.limit))
        guard settings.clipboardEnabled, !items.isEmpty else { return }
        let sub = NSMenu()
        sub.autoenablesItems = false
        for e in items {
            let text = e.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let item = action(text.count > 50 ? String(text.prefix(50)) + "…" : text) { [weak self] in self?.actions?.pasteRecent(e.text) }
            item.toolTip = String(e.text.prefix(300))
            sub.addItem(item)
        }
        sub.addItem(.separator())
        add(action("Очистить") { [weak self] in self?.actions?.clearClipboard() }, to: sub)
        submenu("Недавно скопированное (клик — вставить)", sub)
    }

    private func secureInputHelp(_ holder: String) {
        let alert = NSAlert()
        alert.messageText = "KeySwitch сейчас не видит клавиш"
        alert.informativeText = (holder.isEmpty ? "Какая-то программа" : "Программа «\(holder)»")
            + " включила защищённый ввод. Так macOS прячет нажатия, пока вы вводите пароль, — и ни одна программа, кроме неё, их не видит.\n\n"
            + "Что сделать:\n1. Закройте поле пароля или окно входа.\n2. Если не помогло — закройте саму программу.\n3. Если и это не помогло — заблокируйте экран (⌃⌘Q) и разблокируйте снова.\n\n"
            + "Как только ввод освободится, замок в строке меню исчезнет сам."
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Items

    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    @discardableResult
    private func action(_ title: String, hint: String? = nil, key: String = "", _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        item.target = self
        if let hint { item.attributedTitle = Self.withHint(title, hint) }
        handlers[ObjectIdentifier(item)] = run
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func toggle(_ title: String, on: Bool, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = action(title, run)
        item.state = on ? .on : .off
        item.isEnabled = enabled
        return item
    }

    /// Moves an item built by `action` / `toggle` from the main menu into a submenu.
    private func add(_ item: NSMenuItem, to sub: NSMenu) {
        menu.removeItem(item)
        sub.addItem(item)
    }

    private func submenu(_ title: String, _ sub: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    private func sectionTitle(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func info(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let run = handlers[ObjectIdentifier(sender)] else { return }
        run()
    }

    private func flip(_ key: ReferenceWritableKeyPath<Settings, Bool>) {
        settings[keyPath: key].toggle()
        model.touch()
        model.onSettingsChanged?()
    }

    /// The title with a grey key hint on the right, like a shortcut.
    static func withHint(_ title: String, _ hint: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 330)]
        let s = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: style])
        s.append(NSAttributedString(string: hint, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
        return s
    }
}

/// Texts shared by the menu and the snapshots.
enum MenuPanelText {
    static func mainWord(_ r: CorrectionRecord) -> String {
        let w = r.typed.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? r.typed
        return w.trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "только что" }
        if s < 3600 { return "\(Int(s / 60)) мин назад" }
        return d.formatted(date: .omitted, time: .shortened)
    }

    static func today(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let word = m10 == 1 && m100 != 11 ? "исправление"
            : (2...4).contains(m10) && !(12...14).contains(m100) ? "исправления" : "исправлений"
        return "Сегодня: \(n) \(word)"
    }
}
