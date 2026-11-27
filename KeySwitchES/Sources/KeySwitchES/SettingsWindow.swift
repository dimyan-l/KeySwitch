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
    @Published var page = 0
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
    init(store: UserStore, applicationProfiles: ((PreferencesModel) -> AnyView)? = nil) {
        model = PreferencesModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = ui("Настройки KeySwitch", "Ajustes de KeySwitch ES")
        window.minSize = NSSize(width: 770, height: 540)
        window.contentView = NSHostingView(rootView: PreferencesView(model: model, applicationProfiles: applicationProfiles))
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
    func presentHelp() {
        model.message = ""
        model.page = 4
        present()
    }
}

private struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let applicationProfiles: ((PreferencesModel) -> AnyView)?
    @State private var list = 0
    @State private var query = ""
    @State private var word = ""
    @State private var language = Lang.allCases[0]
    @State private var scope = 0
    private let titles = [ui("Исправления", "Correcciones"), ui("Словари", "Diccionarios"), ui("Приложения", "Aplicaciones"), ui("Клавиши", "Atajos"), ui("Как пользоваться", "Guía rápida")]
    private let symbols = ["switch.2", "character.book.closed", "app.badge", "keyboard", "questionmark.circle"]
    private var page: Int { model.page }

    private var appVersion: String? {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "v\(short) (\($0))" } ?? "v\(short)"
    }

    @Environment(\.colorScheme) private var colorScheme

    private var palette: ClayPalette { ClayPalette(dark: colorScheme == .dark) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high).frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                    Text("KeySwitch").font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .padding(.bottom, 24)
                ForEach(0..<titles.count, id: \.self) { index in
                    Button {
                        model.page = index
                        model.message = ""
                    } label: {
                        Label(titles[index], systemImage: symbols[index])
                            .font(.system(size: 13, weight: page == index ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background {
                                if page == index { ClaySurface(colors: palette.sage, radius: 13, dark: palette.dark) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == index ? .isSelected : [])
                }
                Spacer()
                HStack(spacing: 8) {
                    Text(spanishUI ? "EN / ES" : "EN / RU").font(.caption.weight(.semibold).monospaced())
                    if let appVersion { Text(appVersion).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                }
                .padding(.leading, 10)
            }
            .padding(20)
            .frame(width: 214)
            .background(LinearGradient(colors: palette.sidebar, startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 20) {
                Text(titles[page]).font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                if page == 0 { corrections }
                else if page == 1 { dictionaries }
                else if page == 2 {
                    if let applicationProfiles { applicationProfiles(model) } else { applications }
                } else if page == 3 { shortcuts }
                else { help }
                if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: palette.canvas, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .frame(minWidth: 770, minHeight: 540)
        .onChange(of: page) { _ in query = "" }
    }

    private var corrections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(ui("Автосмена раскладки", "Cambio automático de teclado"))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(ui("Нажмите пробел после слова, чтобы KeySwitch проверил раскладку.",
                                "Pulsa espacio después de una palabra para que KeySwitch compruebe el teclado."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: model.flag(\.autoEnabled))
                        .toggleStyle(ClayToggleStyle(palette: palette))
                        .frame(width: 46)
                        .accessibilityLabel(ui("Автосмена раскладки", "Cambio automático de teclado"))
                }
                .padding(18)
                .background { ClaySurface(colors: palette.sage, radius: 21, dark: palette.dark) }

                clayCard(ui("Правила исправления", "Reglas de corrección"), symbol: "text.badge.checkmark", colors: palette.blue) {
                    Toggle(ui("Исправлять опечатки", "Corregir erratas"), isOn: model.flag(\.spellEnabled))
                    Toggle(ui("Осторожный режим", "Modo prudente"), isOn: model.flag(\.cautiousMode))
                    Text(ui("Сомнительный вариант можно применить правым Option.", "Pulsa Option derecho para aplicar una sugerencia dudosa."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(ui("Звук после исправления", "Sonido al corregir"), isOn: model.flag(\.sound))
                }
                clayCard(ui("Буфер обмена", "Portapapeles"), symbol: "clipboard", colors: palette.peach) {
                    Toggle(ui("Хранить историю до выхода", "Guardar historial hasta salir"), isOn: model.flag(\.clipboardEnabled))
                    Text(ui("Закреплённые фразы доступны в меню и после перезапуска.", "Las frases fijadas siguen disponibles después de reiniciar."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(ui("Очистить историю", "Borrar historial")) {
                        NotificationCenter.default.post(name: .keySwitchClearClipboard, object: nil)
                    }
                }
                clayCard(ui("Доступ macOS", "Permisos de macOS"), symbol: "lock.shield", colors: palette.panel) {
                    permission(ui("Универсальный доступ", "Accesibilidad"), granted: AXIsProcessTrusted(), anchor: "Privacy_Accessibility")
                    permission(ui("Мониторинг ввода", "Monitorización de entrada"), granted: CGPreflightListenEventAccess(), anchor: "Privacy_ListenEvent")
                    Button(ui("Проверить разрешения", "Comprobar permisos")) { model.refresh() }
                }
                Toggle(ui("Запускать при входе в систему", "Abrir al iniciar sesión"), isOn: Binding(get: {
                    _ = model.revision
                    return SMAppService.mainApp.status == .enabled
                }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch { model.message = error.localizedDescription }
                    model.refresh()
                }))
                .padding(.vertical, 8)
            }
            .toggleStyle(ClayToggleStyle(palette: palette))
            .padding(3)
            .padding(.bottom, 10)
        }
    }

    private func clayCard<Content: View>(_ title: String, symbol: String, colors: [Color],
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ClaySurface(colors: colors, radius: 19, dark: palette.dark) }
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
            shortcut("⌥", ui("Правый Option", "Option derecho"), ui("У слова — исправить и запомнить. Сразу после автоматической замены — отменить её.", "Junto a una palabra: corregir. Tras una corrección automática: deshacer."))
            shortcut("⌃ ⌥ R", ui("Выделенный текст", "Texto seleccionado"), ui("Переключить раскладку выделенного фрагмента.", "Cambiar el teclado del texto seleccionado."))
            shortcut("⌃ ⌥ V", ui("Буфер обмена", "Portapapeles"), ui("Открыть историю. С Option — закрепить фразу.", "Abrir el historial. Con Option: fijar una frase."))
            Spacer()
        }
    }
    private var help: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                shortcut("Fn 🌐", ui("Сменить язык", "Cambiar de idioma"), ui("Нажмите Fn с глобусом, если в настройках клавиатуры macOS клавиша назначена на смену источника ввода.", "Pulsa Fn con el globo si macOS tiene asignada esa tecla para cambiar la fuente de entrada."))
                shortcut("⌥", ui("Исправить или отменить", "Corregir o deshacer"), ui("Нажмите правый Option у слова. Сразу после автозамены он возвращает исходный текст.", "Pulsa Option derecho junto a una palabra. Tras una corrección automática, restaura el texto original."))
                shortcut("⌃ ⌥ R", ui("Исправить фрагмент", "Corregir un fragmento"), ui("Выделите текст и нажмите сочетание, чтобы перечитать его в другой раскладке.", "Selecciona el texto y pulsa el atajo para convertirlo al otro teclado."))
                shortcut(ui("Пробел", "Espacio"), ui("Автоисправление при наборе", "Corrección al escribir"), ui("Например, ghbdtn превращается в «привет». Опечатки можно включить отдельно в разделе «Исправления».", "Por ejemplo, ni;o se convierte en «niño». Activa las erratas en la sección Correcciones."))
                if applicationProfiles != nil {
                    shortcut(ui("Профили", "Perfiles"), ui("Выбрать режим для приложения", "Elegir un modo por aplicación"), ui("В разделе «Приложения» можно оставить только ручное исправление или запросить подтверждение сомнительных замен.", "En Aplicaciones puedes elegir el modo manual o confirmar los cambios dudosos."))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func shortcut(_ keys: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(keys).font(.system(.callout, design: .monospaced).weight(.semibold))
                .padding(8).frame(width: 125)
                .background { ClaySurface(colors: palette.panel, radius: 10, dark: palette.dark) }
            VStack(alignment: .leading, spacing: 4) { Text(title).fontWeight(.medium); Text(detail).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

private struct ClayPalette {
    let dark: Bool

    var canvas: [Color] { colors(0xFCF7EB, 0xF2E9D9, 0x272823, 0x1E2322) }
    var sidebar: [Color] { colors(0xE5EDDC, 0xC7D9CA, 0x34453B, 0x24332F) }
    var sage: [Color] { colors(0xE7F0DA, 0xBDD6BF, 0x415743, 0x304538) }
    var blue: [Color] { colors(0xF1F7F8, 0xD4E6EE, 0x344650, 0x2B3B46) }
    var peach: [Color] { colors(0xFCF1E9, 0xF1DECF, 0x493C35, 0x3B302D) }
    var panel: [Color] { colors(0xFFFDF5, 0xF1E7D5, 0x3D3D34, 0x2E302B) }

    private func colors(_ lightTop: UInt32, _ lightBottom: UInt32, _ darkTop: UInt32, _ darkBottom: UInt32) -> [Color] {
        (dark ? [darkTop, darkBottom] : [lightTop, lightBottom]).map { hex in
            Color(red: Double(hex >> 16) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
        }
    }
}

private struct ClaySurface: View {
    let colors: [Color]
    let radius: CGFloat
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(dark ? 0.20 : 0.78), .clear, .black.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5
                )
            }
            .shadow(color: .black.opacity(dark ? 0.25 : 0.11), radius: 5, x: 0, y: 3)
    }
}

private struct ClayToggleStyle: ToggleStyle {
    let palette: ClayPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { configuration.isOn.toggle() }
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 0)
                Capsule()
                    .fill(configuration.isOn ? Color(red: 0.29, green: 0.44, blue: 0.37) : .secondary.opacity(0.22))
                    .overlay { Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 1) }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        ClaySurface(colors: palette.panel, radius: 11, dark: palette.dark)
                            .frame(width: 19, height: 19)
                            .overlay {
                                Image(systemName: configuration.isOn ? "checkmark" : "minus")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .padding(3)
                    }
                    .frame(width: 46, height: 25)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

extension Notification.Name {
    static let keySwitchClearClipboard = Notification.Name("KeySwitch.clearClipboard")
}
