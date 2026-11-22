import AppKit
import SwiftUI

extension ApplicationCorrectionMode {
    var title: String {
        switch self {
        case .inherit: return "По умолчанию"
        case .automatic: return "Автоматически"
        case .confirm: return "Подтверждать сомнительные"
        case .manual: return "Только вручную"
        case .off: return "Выключено"
        }
    }
}

struct ApplicationProfilesView: View {
    @ObservedObject var model: PreferencesModel
    @State private var query = ""
    private let settings = Settings.shared

    private var applications: [String] {
        Set(settings.excluded).union(settings.applicationModes.keys).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Выберите режим для приложения. Общие настройки раскладки и опечаток действуют во всех автоматических режимах.")
                .foregroundStyle(.secondary)
            TextField("Найти приложение", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(applications, id: \.self) { id in
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
                    if query.isEmpty || name.localizedCaseInsensitiveContains(query) || id.localizedCaseInsensitiveContains(query) {
                        profileRow(id: id, name: name, url: url)
                    }
                }
            }.listStyle(.inset).cornerRadius(8)
            Button("Добавить приложение…", action: addApplication)
            Text("Для веб-сайтов действует режим браузера. В режиме «Только вручную» доступны правый Option и ⌃⌥R.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func profileRow(id: String, name: String, url: URL?) -> some View {
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
            }
            Text(name).lineLimit(1).help(id)
            Spacer()
            Picker("Режим для \(name)", selection: Binding(
                get: { settings.applicationModes[id] ?? .inherit },
                set: { setMode($0, for: id) }
            )) {
                ForEach(ApplicationCorrectionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }.labelsHidden().frame(width: 210).help("Текущий режим: \(settings.applicationMode(for: id).title)")
        }.padding(.vertical, 3)
    }

    private func addApplication() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.canChooseDirectories = false
        guard picker.runModal() == .OK, let url = picker.url, let id = Bundle(url: url)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, !applications.contains(id) else { return }
        setMode(.confirm, for: id)
        query = ""
    }

    private func setMode(_ mode: ApplicationCorrectionMode, for id: String) {
        settings.setApplicationMode(mode, for: id)
        model.onChange()
        model.refresh()
    }
}
