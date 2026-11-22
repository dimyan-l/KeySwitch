import AppKit
import SwiftUI

extension ApplicationCorrectionMode {
    var title: String {
        switch self {
        case .inherit: return "Por omisión"
        case .automatic: return "Automático"
        case .confirm: return "Confirmar dudas"
        case .manual: return "Solo manual"
        case .off: return "Desactivado"
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
            Text("Elige un modo por aplicación. Los ajustes generales de teclado y erratas se aplican a los modos automáticos.")
                .foregroundStyle(.secondary)
            TextField("Buscar aplicación", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(applications, id: \.self) { id in
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
                    if query.isEmpty || name.localizedCaseInsensitiveContains(query) || id.localizedCaseInsensitiveContains(query) {
                        profileRow(id: id, name: name, url: url)
                    }
                }
            }.listStyle(.inset).cornerRadius(8)
            Button("Añadir aplicación…", action: addApplication)
            Text("Los sitios web usan el modo del navegador. En el modo «Solo manual» puedes usar Option derecho y ⌃⌥R.")
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
            Picker("Modo de \(name)", selection: Binding(
                get: { settings.applicationModes[id] ?? .inherit },
                set: { setMode($0, for: id) }
            )) {
                ForEach(ApplicationCorrectionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }.labelsHidden().frame(width: 210).help("Modo actual: \(settings.applicationMode(for: id).title)")
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
