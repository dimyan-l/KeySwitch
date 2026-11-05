import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            // Own rows in the palette: the system's selection highlight competes with the single accent.
            List(SettingsPane.allCases) { p in
                let active = model.pane == p
                Button { model.pane = p } label: {
                    Label(p.title, systemImage: p.symbol)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(active ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 240, max: 280)
        } detail: {
            Group {
                switch model.pane {
                case .general: GeneralPane(model: model)
                case .apps: AppsPane(model: model)
                case .words: WordsPane(model: model)
                case .privacy: PrivacyPane(model: model)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
        }
        .tint(Theme.accent)
        .frame(minWidth: 760, minHeight: 560)
    }
}

/// Short secondary line under a setting.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Long explanations and system-settings paths, folded away from the main path.
private struct Help: View {
    let title: String
    let text: String
    @StateObject private var open = Box(false)
    init(_ title: String, _ text: String) { self.title = title; self.text = text }
    var body: some View {
        DisclosureGroup(isExpanded: $open.value) {
            Text(text).font(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(title).font(.callout).foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Основное

private struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        let _ = model.revision
        Form {
            Section("Исправление текста") {
                Toggle("Автоисправление", isOn: model.binding(\.autoEnabled))
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Переключать посреди слова", isOn: model.binding(\.earlySwitch))
                    Note("Если по первым 4 буквам уже ясно, что раскладка не та, она меняется сразу, и остаток слова печатается правильно.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Исправлять опечатки", isOn: model.binding(\.spellEnabled))
                    Note("Возможны неверные замены. Отмена — правый ⌥, слово запоминается.")
                    Help("Как работает исправление опечаток",
                         "Только строчные слова от 4 букв, которых нет в словарях, и только когда вариант очевиден. Допустимые словоформы, которые знает словарь macOS, не меняются. Ваши решения из «Словари → Не исправлять» проверяются раньше всего.\n\nЕсли в «Системные настройки → Клавиатура → Ввод текста» включено «Исправлять орфографию автоматически», выключите это, иначе слова будут правиться дважды.")
                }
            }
            Section("Поведение") {
                Toggle("Подсказка после исправления", isOn: model.binding(\.showToast))
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Совместимый режим печати", isOn: model.binding(\.compatibleTyping))
                    Note("Включите, если в каком-то приложении исправленное слово появляется не целиком. Печать станет чуть медленнее.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Помнить язык приложения", isOn: model.binding(\.perAppLayout))
                    Note("Возвращаться к последней выбранной раскладке.")
                    Help("Если раскладка переключается сама",
                         "Вернулись в Telegram — там снова русская, в редакторе кода — английская. Если в «Системные настройки → Клавиатура → Источники ввода» включено «Автоматически переключаться на источник ввода документа», выключите его, чтобы они не спорили.")
                }
            }
            Section("Клавиши") {
                LabeledContent("Отменить исправление и запомнить слово") { KeyCap(text: "правый ⌥") }
                Help("Что ещё делает правый ⌥",
                     "Сразу после исправления — отменяет его и больше так не исправляет. Посреди слова или сразу после него — переводит его в другую раскладку. Вернулись к старому слову (щелчком или стрелками) — поставьте курсор в слово или сразу за ним и нажмите правый ⌥: слово перепечатается в другой раскладке, а повторное нажатие вернёт как было. Выделенный текст переводится целиком. Если курсор между пробелами — просто меняет раскладку. После Enter и Tab отмена недоступна: текст мог уже отправиться.")
            }
            Section("Диагностика") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Журнал пропусков", isOn: model.binding(\.missLogEnabled))
                    Note("Записываются только слова, которые вы исправили правым ⌥ сами или вернули после замены, и почему KeySwitch решил иначе. Обычный набор не записывается. Файл хранится только на этом Mac.")
                }
                HStack {
                    Button("Открыть журнал") { MissLog.open() }
                    Button("Очистить") { MissLog.clear(); model.touch() }
                }
            }
            Section("Система") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { _ = model.revision; return model.loginEnabled },
                    set: { model.actions?.setLogin($0) }))
                Picker("Значок в строке меню", selection: model.binding(\.menuBarStyle)) {
                    Text("RU / EN").tag("lang")
                    Text("Точка").tag("dot")
                    Text("Скрыть").tag("hidden")
                }
                .pickerStyle(.segmented)
                if model.settings.menuBarStyle == "hidden" {
                    Note("Чтобы вернуть значок, откройте KeySwitch из папки «Программы».")
                }
                SoundGroup(model: model)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Основное")
    }
}

private struct SoundGroup: View {
    @Bindable var model: AppModel
    @StateObject private var open = Box(false)

    var body: some View {
        DisclosureGroup(isExpanded: $open.value) {
            Toggle("Включить звук", isOn: model.binding(\.soundEnabled))
            Picker("Звук", selection: Binding(
                get: { _ = model.revision; return model.settings.soundChoice },
                set: { model.settings.soundChoice = $0; model.touch(); SoundPlayer.play($0, volume: model.settings.soundVolume) })
            ) {
                ForEach(SwitchSound.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!model.settings.soundEnabled)
            LabeledContent("Громкость") {
                HStack {
                    Slider(value: model.binding(\.soundVolume), in: 0.1...1).frame(maxWidth: 180)
                    Button("Прослушать") { SoundPlayer.play(model.settings.soundChoice, volume: model.settings.soundVolume) }
                }
            }
            .disabled(!model.settings.soundEnabled)
        } label: {
            HStack {
                Text("Звук при смене раскладки")
                Spacer()
                Text(model.settings.soundEnabled ? "Вкл." : "Выкл.").foregroundStyle(Theme.secondary)
            }
        }
    }
}

// MARK: - Приложения

private struct AppsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        let _ = model.revision
        Form {
            Section {
                ForEach(model.settings.configuredApps, id: \.self) { id in
                    HStack(spacing: 10) {
                        Image(nsImage: Self.icon(for: id)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Self.name(for: id))
                            Text(id).font(.caption).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Picker("Режим", selection: Binding(
                            get: { _ = model.revision; return model.settings.mode(for: id) },
                            set: { model.settings.setMode($0, for: id); model.touch(); model.onSettingsChanged?() })
                        ) {
                            ForEach(Settings.AppMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "lock").frame(width: 24).foregroundStyle(Theme.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Приложения JetBrains и окна KeySwitch")
                        Text("Всегда без исправлений").font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(Settings.AppMode.off.title).foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Режим для приложений")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Остальные приложения — как в «Основном». Терминалы, IDE и менеджеры паролей отключены по умолчанию.")
                    if !model.settings.spellEnabled {
                        Text("Опечатки сейчас выключены в «Основном»: «Раскладка и опечатки» исправляет только раскладку.")
                    }
                }
                .foregroundStyle(Theme.secondary)
            }
            Section {
                if let id = model.frontBundleID, let name = model.frontAppName, !model.settings.configuredApps.contains(id),
                   !model.settings.isAlwaysExcluded(id) {
                    Button("Добавить \(name)") { add(id) }
                }
                Button("Выбрать приложение…") { chooseApp() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Приложения")
    }

    private func add(_ id: String) {
        model.settings.setMode(.off, for: id)
        model.touch()
        model.onSettingsChanged?()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        add(id)
    }

    static func url(for id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    static func name(for id: String) -> String {
        guard let u = url(for: id) else { return id }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    static func icon(for id: String) -> NSImage {
        guard let u = url(for: id) else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: u.path)
    }
}

// MARK: - Словари

struct WordsPane: View {
    @Bindable var model: AppModel
    enum Tab: String, CaseIterable { case rules = "Не исправлять", mine = "Мои слова" }
    @StateObject private var tabBox: Box<Tab>
    @StateObject private var wordBox = Box("")
    @StateObject private var langBox = Box<Lang?>(nil)
    @StateObject private var searchBox = Box("")
    @StateObject private var moreOpen = Box(false)

    init(model: AppModel, tab: Tab = .rules) {
        self.model = model
        _tabBox = StateObject(wrappedValue: Box(tab))
    }

    private var tab: Tab { tabBox.value }

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tabBox.value) {
                ForEach(Tab.allCases, id: \.self) { t in Text("\(t.rawValue) · \(count(t))").tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding([.horizontal, .top], 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(tab == .rules ? "Не исправлять автоматически" : "Мои слова").font(.title3.weight(.semibold))
                Text(tab == .rules ? "Ваши решения имеют приоритет перед словарём и моделью."
                                   : "Имена, компании, термины: такие слова считаются правильными.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 16)

            addRow.padding(.horizontal, 20).padding(.top, 12)

            if tab == .rules && model.store.rules.active.count > 8 {
                TextField("Поиск", text: $searchBox.value)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20).padding(.top, 8)
            }

            Group {
                if tab == .rules { rulesTable } else { myWordsList }
            }
            .padding(.top, 10)

            footer.padding(20)
        }
        .foregroundStyle(Theme.text)
        .navigationTitle("Словари")
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField(tab == .rules ? "Слово, которое не нужно исправлять" : "Добавить слово: имя, компанию, термин…",
                      text: $wordBox.value).onSubmit(add)
            Picker("Язык", selection: $langBox.value) {
                Text("Определить само").tag(Lang?.none)
                Text("Русское").tag(Lang?.some(.ru))
                Text("Английское").tag(Lang?.some(.en))
            }
            .labelsHidden().fixedSize()
            Button("Добавить", action: add).disabled(wordBox.value.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var rules: [UserRule] {
        let q = normalizeWord(searchBox.value.trimmingCharacters(in: .whitespaces))
        return model.store.rules.active.filter { q.isEmpty || $0.word.contains(q) }
    }

    private var rulesTable: some View {
        let rows = rules
        return List {
            Section {
                HStack(spacing: 12) {
                    Text("СЛОВО").frame(maxWidth: .infinity, alignment: .leading)
                    Text("ТИП").frame(width: 150, alignment: .leading)
                    Text("ИСТОЧНИК").frame(width: 190, alignment: .leading)
                    Spacer().frame(width: 70)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
                if rows.isEmpty {
                    Text(searchBox.value.isEmpty ? "Пока пусто. Отмените неверное исправление правым ⌥ или нажмите «Это ошибка» в панели."
                                                 : "Ничего не найдено")
                        .font(.callout).foregroundStyle(Theme.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { r in
                            HStack(spacing: 12) {
                                HStack(spacing: 6) {
                                    Text(r.word).font(.system(size: 14, weight: .semibold))
                                    if let res = r.result {
                                        Text("не «\(res)»").font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                    Text(r.lang.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Theme.selected, in: RoundedRectangle(cornerRadius: 4))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(r.scopeTitle).frame(width: 150, alignment: .leading).foregroundStyle(Theme.secondary)
                                Text(r.source.title).frame(width: 190, alignment: .leading).foregroundStyle(Theme.secondary)
                                Button("Удалить") { model.actions?.removeRule(r.id) }
                                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                                    .frame(width: 70, alignment: .trailing)
                                    .accessibilityLabel("Удалить исключение «\(r.word)»")
                            }
                            .font(.system(size: 13))
                            .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private struct WordRow: Identifiable { let id: String; let word: String; let lang: Lang }

    private var myWordsList: some View {
        let rows = Lang.allCases.flatMap { l in model.store.customWords(l).map { WordRow(id: "\(l)-\($0)", word: $0, lang: l) } }
        return List(rows) { r in
            HStack {
                Text(r.word)
                Spacer()
                Text(r.lang.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.selected, in: RoundedRectangle(cornerRadius: 4))
                Button { model.actions?.removeWord(r.word, lang: r.lang) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Удалить из моих слов")
                    .accessibilityLabel("Удалить «\(r.word)»")
            }
        }
        .scrollContentBackground(.hidden)
        .overlay { if rows.isEmpty { Text("Здесь пока пусто").foregroundStyle(Theme.secondary) } }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tab == .rules {
                Note("Удаление исключения снова разрешает автоматическое исправление.")
            }
            HStack {
                Toggle("Синхронизировать через iCloud Drive", isOn: Binding(
                    get: { _ = model.revision; return model.settings.iCloudSync },
                    set: { model.actions?.setICloudSync($0) }))
                    .disabled(UserStore.cloudDirectory == nil)
                if UserStore.cloudDirectory == nil {
                    Text("iCloud Drive выключен на этом Mac").font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            DisclosureGroup(isExpanded: $moreOpen.value) {
                VStack(alignment: .leading, spacing: 8) {
                    Note("Базовые словари: 80 000 русских и 80 000 английских слов плюс IT-жаргон. Исключения и ваши слова лежат в learned.json, my_ru.txt и my_en.txt — " + (model.settings.iCloudSync ? "в iCloud Drive → KeySwitch, общие для ваших Mac." : "в папке поддержки программ на этом Mac."))
                    HStack {
                        Button("Открыть папку") { model.actions?.openUserFolder() }
                        Button("Забыть выученные слова", role: .destructive) { model.actions?.forgetLearned() }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Где хранятся словари").font(.callout).foregroundStyle(Theme.accent)
            }
        }
    }

    private func count(_ t: Tab) -> Int {
        switch t {
        case .rules: model.rulesCount
        case .mine: Lang.allCases.reduce(0) { $0 + model.store.customWords($1).count }
        }
    }

    private func add() {
        let w = wordBox.value.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        if tab == .rules { model.actions?.addRule(w, lang: langBox.value) } else { model.actions?.addWord(w, lang: langBox.value) }
        wordBox.value = ""
    }
}

// MARK: - Конфиденциальность

private struct PrivacyPane: View {
    @Bindable var model: AppModel

    var body: some View {
        let _ = model.revision
        Form {
            Section("Недавно скопированное") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Показывать в панели", isOn: model.binding(\.clipboardEnabled))
                    Note("Последние \(ClipboardHistory.limit) скопированных текстов. Только в памяти: не записываются на диск и пропадают при выходе. Пароли из менеджеров паролей не сохраняются.")
                }
                Button("Очистить") { model.actions?.clearClipboard() }
                    .disabled(model.clipboard.items.isEmpty)
            }
            Section("Что хранит KeySwitch") {
                Note("Набранный текст никуда не отправляется и не записывается. На диске — только ваши исключения и слова; при включённой синхронизации — в вашем iCloud Drive.")
                Note("История исправлений в панели — только в памяти, до выхода.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Конфиденциальность")
    }
}
