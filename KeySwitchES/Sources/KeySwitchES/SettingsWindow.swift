import AppKit
import SwiftUI
import ApplicationServices
import ServiceManagement

private let spanishUI = Lang(rawValue: "es") != nil
private func ui(_ ru: String, _ es: String) -> String { spanishUI ? es : ru }

struct CorrectionEntry: Identifiable {
    let id = UUID()
    let original: String
    let replacement: String
}

final class PreferencesModel: ObservableObject {
    let store: UserStore
    var onChange: () -> Void = {}
    var reload: () -> Void = {}
    @Published var revision = 0
    @Published var message = ""
    @Published var history: [CorrectionEntry] = []
    @Published var undoAvailable = false
    private var undoAction: (() -> Void)?

    init(store: UserStore) { self.store = store }
    func refresh() { revision += 1 }
    func record(_ original: String, _ replacement: String) {
        guard original != replacement else { return }
        history.insert(CorrectionEntry(original: original, replacement: replacement), at: 0)
        history = Array(history.prefix(50))
    }
    func flag(_ key: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { _ = self.revision; return Settings.shared[keyPath: key] }, set: {
            Settings.shared[keyPath: key] = $0
            self.onChange(); self.refresh()
        })
    }
    func finishEdit(undo: @escaping () -> Void) {
        undoAction = undo; undoAvailable = true
        reload(); refresh()
    }
    func undo() {
        undoAction?(); undoAction = nil; undoAvailable = false
        reload(); refresh()
    }
    func add(_ input: String, lang: Lang, exception: Bool, kind: FixKind?) -> Bool {
        let word = normalizeWord(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (2...32).contains(word.count), LanguageModel(lang: lang).isWord(word) else {
            message = ui("Введите одно слово на выбранном языке.", "Escribe una palabra en el idioma seleccionado."); return false
        }
        if exception {
            let id = UserRule.key(word, lang, kind)
            let old = store.rules.byKey[id]
            store.addRule(word, lang: lang, kind: kind)
            finishEdit { [weak self] in
                guard let self else { return }
                if let old, !old.deleted { self.store.addRule(old.word, lang: old.lang, kind: old.kind, result: old.result, source: old.source) }
                else { self.store.removeRule(id) }
            }
        } else {
            guard !(store.learned[lang] ?? []).contains(word) else { message = ui("Слово уже есть в списке.", "La palabra ya está en la lista."); return false }
            store.learn(word, lang: lang)
            finishEdit { [weak self] in self?.store.forget(word, lang: lang) }
        }
        message = ""; return true
    }
    func remove(_ rule: UserRule) {
        // Removing an exception must preserve independently learned words.
        store.removeRule(rule.id)
        finishEdit { [weak self] in self?.store.addRule(rule.word, lang: rule.lang, kind: rule.kind, result: rule.result, source: rule.source) }
    }
    func remove(_ word: String, lang: Lang) {
        store.forget(word, lang: lang)
        finishEdit { [weak self] in self?.store.learn(word, lang: lang) }
    }
    func addApplication() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        if !Settings.shared.excluded.contains(id) { Settings.shared.excluded.append(id) }
        onChange(); refresh()
    }
}

final class PreferencesWindowController: NSWindowController {
    let model: PreferencesModel
    init(store: UserStore) {
        model = PreferencesModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = ui("Настройки KeySwitch", "Ajustes de KeySwitch ES")
        window.minSize = NSSize(width: 760, height: 540)
        window.contentView = NSHostingView(rootView: PreferencesView(model: model))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KeySwitchPreferences")
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @State private var page = 0
    @State private var list = 0
    @State private var query = ""
    @State private var word = ""
    @State private var language = Lang.allCases[0]
    @State private var scope = 0
    private let titles = [ui("Исправления", "Correcciones"), ui("Словари", "Diccionarios"), ui("Приложения", "Aplicaciones"), ui("Клавиши", "Atajos")]
    private let symbols = ["switch.2", "character.book.closed", "app.badge", "keyboard"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("KeySwitch", systemImage: "keyboard.badge.ellipsis").font(.title3.weight(.semibold)).padding(.bottom, 20)
                ForEach(0..<titles.count, id: \.self) { index in
                    Button { page = index; model.message = "" } label: {
                        Label(titles[index], systemImage: symbols[index]).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(page == index ? Color.accentColor.opacity(0.15) : .clear)
                            .cornerRadius(8)
                    }.buttonStyle(.plain).foregroundColor(page == index ? .accentColor : .primary)
                }
                Spacer()
                Text(spanishUI ? "EN / ES" : "EN / RU").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(ui("Исправления без отвлечений", "Escribe sin interrupciones")).font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 190).background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text(titles[page]).font(.largeTitle.weight(.semibold))
                if page == 0 { corrections }
                else if page == 1 { dictionaries }
                else if page == 2 { applications }
                else { shortcuts }
                if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 760, minHeight: 540)
        .onChange(of: page) { _ in query = "" }
    }
    private var corrections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(ui("Автоматически менять раскладку", "Cambiar teclado automáticamente"), isOn: model.flag(\.autoEnabled))
                        Toggle(ui("Исправлять опечатки", "Corregir erratas"), isOn: model.flag(\.spellEnabled))
                        Toggle(ui("Осторожный режим", "Modo prudente"), isOn: model.flag(\.cautiousMode))
                        Text(ui("При неоднозначном результате исправление ждёт нажатия правого ⌥.", "Las correcciones ambiguas esperan a que pulses ⌥ derecho.")).font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle(ui("Варианты при выделении слова", "Sugerencias al seleccionar una palabra"), isOn: model.flag(\.selectionSuggestionsEnabled))
                        Toggle(ui("Звук после исправления", "Sonido al corregir"), isOn: model.flag(\.sound))
                        Divider()
                        Toggle(ui("Сохранять историю буфера обмена", "Guardar historial del portapapeles"), isOn: model.flag(\.clipboardEnabled))
                        Text(ui("История выключена по умолчанию. Закреплённые фразы доступны независимо от истории.", "El historial está desactivado por defecto. Las frases fijadas siguen disponibles independientemente del historial.")).font(.caption).foregroundStyle(.secondary)
                        if !Settings.shared.clipboardEnabled {
                            Text(ui("Новые копирования не добавляются в историю.", "Las nuevas copias no se añaden al historial.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle(ui("Запускать при входе в систему", "Abrir al iniciar sesión"), isOn: Binding(get: {
                    _ = model.revision; return SMAppService.mainApp.status == .enabled
                }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch { model.message = error.localizedDescription }
                    model.refresh()
                }))
                GroupBox(ui("Доступ macOS", "Permisos de macOS")) {
                    VStack(spacing: 12) {
                        permission(ui("Универсальный доступ", "Accesibilidad"), granted: AXIsProcessTrusted(), anchor: "Privacy_Accessibility")
                        permission(ui("Мониторинг ввода", "Monitorización de entrada"), granted: CGPreflightListenEventAccess(), anchor: "Privacy_ListenEvent")
                        Button(ui("Проверить разрешения", "Comprobar permisos")) { model.refresh() }.frame(maxWidth: .infinity, alignment: .trailing)
                    }.padding(10)
                }
                Button(ui("Очистить историю буфера", "Borrar historial del portapapeles")) {
                    NotificationCenter.default.post(name: .keySwitchClearClipboard, object: nil)
                }
            }
        }
    }
    private func permission(_ title: String, granted: Bool, anchor: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(granted ? .green : .orange)
            Text(title); Spacer()
            if granted { Text(ui("Выдан", "Concedido")).foregroundStyle(.secondary) }
            else { Button(ui("Настроить", "Configurar")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
            } }
        }
    }
    private var dictionaries: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $list) {
                Text(ui("Исключения", "Excepciones")).tag(0)
                Text(ui("Мои слова", "Mis palabras")).tag(1)
                Text(ui("Последние замены", "Cambios recientes")).tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            TextField(ui("Найти слово", "Buscar palabra"), text: $query).textFieldStyle(.roundedBorder)
            if list < 2 {
                HStack {
                    Picker("", selection: $language) { ForEach(Lang.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(width: 80).labelsHidden()
                    TextField(ui("Новое слово", "Nueva palabra"), text: $word).textFieldStyle(.roundedBorder).onSubmit(addWord)
                    Button(ui("Добавить", "Añadir"), action: addWord).disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if list == 0 {
                    Picker(ui("Не исправлять", "No corregir"), selection: $scope) {
                        Text(ui("Всё", "Todo")).tag(0); Text(ui("Раскладку", "Teclado")).tag(1); Text(ui("Опечатки", "Erratas")).tag(2)
                    }
                }
            }
            List {
                if list == 0 {
                    let rules = model.store.rules.active.filter { $0.lang == language && matches($0.word + ($0.result ?? "")) }
                    if rules.isEmpty { emptyList }
                    ForEach(rules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.word).fontWeight(.medium)
                                Text(rule.kind == .layout ? ui("Раскладка", "Teclado") : rule.kind == .spell ? ui("Опечатки", "Erratas") : rule.kind == .caseFix ? ui("Регистр", "Mayúsculas") : ui("Все исправления", "Todas las correcciones")).font(.caption).foregroundStyle(.secondary)
                                if let result = rule.result { Text(ui("Отклонено: ", "Rechazado: ") + rule.word + " → " + result).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(); removeButton { model.remove(rule) }
                        }.padding(.vertical, 4)
                    }
                } else if list == 1 {
                    let words = (model.store.learned[language] ?? []).filter(matches).sorted()
                    if words.isEmpty { emptyList }
                    ForEach(words, id: \.self) { word in HStack { Text(word); Spacer(); removeButton { model.remove(word, lang: language) } } }
                } else {
                    let history = model.history.filter { matches($0.original + $0.replacement) }
                    if history.isEmpty { emptyList }
                    ForEach(history) { entry in
                        HStack { Text(entry.original).foregroundStyle(.secondary); Image(systemName: "arrow.right").foregroundStyle(.tertiary); Text(entry.replacement).fontWeight(.medium) }
                    }
                }
            }.listStyle(.inset).cornerRadius(8)
            HStack {
                Button(ui("Отменить изменение", "Deshacer cambio")) { model.undo() }.disabled(!model.undoAvailable)
                Spacer()
                Button(ui("Мои файлы словарей", "Archivos de diccionarios")) { NSWorkspace.shared.open(UserStore.directory) }
                Button(ui("Перезагрузить", "Recargar")) { model.reload(); model.refresh() }
            }.font(.caption)
            Text(ui("Последние замены хранятся только до выхода из приложения.", "Los cambios recientes se guardan solo durante esta sesión.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var emptyList: some View { Text(ui("Пока пусто", "Sin elementos")).foregroundStyle(.secondary).padding(.vertical, 16) }
    private func matches(_ value: String) -> Bool { query.isEmpty || value.localizedCaseInsensitiveContains(query) }
    private func addWord() { if model.add(word, lang: language, exception: list == 0, kind: scope == 1 ? .layout : scope == 2 ? .spell : nil) { word = "" } }
    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle").foregroundStyle(.secondary) }.buttonStyle(.borderless).help(ui("Удалить из списка", "Eliminar de la lista"))
    }
    private var applications: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ui("В этих приложениях KeySwitch пропускает ввод без исправлений.", "KeySwitch no corrige el texto en estas aplicaciones.")).foregroundStyle(.secondary)
            TextField(ui("Найти приложение", "Buscar aplicación"), text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(Settings.shared.excluded.filter(matches).sorted(), id: \.self) { id in
                    HStack(spacing: 10) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading) { Text(FileManager.default.displayName(atPath: url.path)); Text(id).font(.caption).foregroundStyle(.secondary) }
                        } else { Text(id).font(.callout) }
                        Spacer()
                        removeButton { Settings.shared.excluded.removeAll { $0 == id }; model.onChange(); model.refresh() }
                    }.padding(.vertical, 4)
                }
            }.listStyle(.inset).cornerRadius(8)
            Button(ui("Добавить приложение…", "Añadir aplicación…")) { model.addApplication() }
            Text(ui("Приложения JetBrains также исключены автоматически.", "Las aplicaciones de JetBrains también están excluidas automáticamente.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            shortcut("⌥", ui("Правый Option", "Option derecho"), ui("У слова — исправить. Сразу после автоматической замены — отменить её.", "Junto a una palabra: corregir. Tras una corrección automática: deshacer."))
            shortcut("↑ ↓  ↵  esc", ui("В панели вариантов", "En las sugerencias"), ui("Выбрать вариант, применить или закрыть панель.", "Elegir, aplicar o cerrar las sugerencias."))
            shortcut("⌃ ⌥ R", ui("Выделенный текст", "Texto seleccionado"), ui("Переключить раскладку выделенного фрагмента.", "Cambiar el teclado del texto seleccionado."))
            shortcut("⌃ ⌥ V", ui("Буфер обмена", "Portapapeles"), ui("Открыть историю. С Option — закрепить фразу.", "Abrir el historial. Con Option: fijar una frase."))
            Spacer()
        }
    }
    private func shortcut(_ keys: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(keys).font(.system(.callout, design: .monospaced).weight(.medium)).padding(8).frame(width: 125).background(.quaternary).cornerRadius(7)
            VStack(alignment: .leading, spacing: 4) { Text(title).fontWeight(.medium); Text(detail).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

extension Notification.Name {
    static let keySwitchClearClipboard = Notification.Name("KeySwitch.clearClipboard")
}
