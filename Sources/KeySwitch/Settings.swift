import Foundation
import CoreFoundation

enum ApplicationCorrectionMode: String, CaseIterable {
    case inherit, automatic, confirm, manual, off

    var allowsAutomatic: Bool { self != .manual && self != .off }

    func isCautious(defaultValue: Bool) -> Bool {
        switch self {
        case .automatic: return false
        case .confirm: return true
        default: return defaultValue
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d: UserDefaults

    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
    ]

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: [
            "autoEnabled": true,
            "cautiousMode": true,
            "spellEnabled": false,
            "clipboardEnabled": false,
            "selectionSuggestionsEnabled": true,
            "sound": false,
            "clipboardSize": 30,
            "excluded": Settings.defaultExcluded,
        ])
    }

    var autoEnabled: Bool {
        get { d.bool(forKey: "autoEnabled") }
        set { d.set(newValue, forKey: "autoEnabled") }
    }
    var cautiousMode: Bool {
        get { d.bool(forKey: "cautiousMode") }
        set { d.set(newValue, forKey: "cautiousMode") }
    }
    var spellEnabled: Bool {
        get { d.bool(forKey: "spellEnabled") }
        set { d.set(newValue, forKey: "spellEnabled") }
    }
    var clipboardEnabled: Bool {
        get { d.bool(forKey: "clipboardEnabled") }
        set { d.set(newValue, forKey: "clipboardEnabled") }
    }
    var selectionSuggestionsEnabled: Bool {
        get { d.bool(forKey: "selectionSuggestionsEnabled") }
        set { d.set(newValue, forKey: "selectionSuggestionsEnabled") }
    }
    var sound: Bool {
        get { d.bool(forKey: "sound") }
        set { d.set(newValue, forKey: "sound") }
    }
    var clipboardSize: Int { max(5, d.integer(forKey: "clipboardSize")) }

    var excluded: [String] {
        get { d.stringArray(forKey: "excluded") ?? [] }
        set { d.set(newValue, forKey: "excluded") }
    }
    func isExcluded(_ bundleID: String?) -> Bool {
        applicationMode(for: bundleID) == .off
    }

    var applicationModes: [String: ApplicationCorrectionMode] {
        (d.dictionary(forKey: "applicationCorrectionModes") ?? [:]).compactMapValues {
            ($0 as? String).flatMap(ApplicationCorrectionMode.init(rawValue:))
        }
    }

    func applicationMode(for bundleID: String?) -> ApplicationCorrectionMode {
        guard let bundleID else { return .inherit }
        if bundleID == Bundle.main.bundleIdentifier { return .off }
        if let raw = d.dictionary(forKey: "applicationCorrectionModes")?[bundleID] as? String,
           let mode = ApplicationCorrectionMode(rawValue: raw), mode != .inherit { return mode }
        return excluded.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") ? .off : .inherit
    }

    func setApplicationMode(_ mode: ApplicationCorrectionMode, for bundleID: String) {
        var modes = d.dictionary(forKey: "applicationCorrectionModes") ?? [:]
        modes[bundleID] = mode == .inherit ? nil : mode.rawValue
        d.set(modes, forKey: "applicationCorrectionModes")
    }

}

/// Persistent learned words and per-language exceptions for automatic changes.
final class UserStore {
    private struct Payload: Codable {
        var learned: [String: [String]] = [:]
        var pinned: [String] = []
        var rules: [UserRule] = []
        var rulesSeededFrom032 = false

        private enum CodingKeys: String, CodingKey { case learned, pinned, rules, rulesSeededFrom032 }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            learned = try values.decodeIfPresent([String: [String]].self, forKey: .learned) ?? [:]
            pinned = try values.decodeIfPresent([String].self, forKey: .pinned) ?? []
            rules = try values.decodeIfPresent([UserRule].self, forKey: .rules) ?? []
            rulesSeededFrom032 = try values.decodeIfPresent(Bool.self, forKey: .rulesSeededFrom032) ?? false
        }
    }

    static let directory: URL = defaultDirectory()

    private static func defaultDirectory(create: Bool = true) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("KeySwitch", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    private static let ioQueue = DispatchQueue(label: "keyswitch.store")
    private let directory: URL
    private let bundledRulesURL: URL?
    private let url: URL
    // Preserve extensions from upstream/future versions, including unsupported languages.
    private var originalPayload: [String: Any] = [:]
    private var payload = Payload()

    private func readPayload(_ data: Data) throws -> Payload {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        originalPayload = object
        if let format = object["localFormat"] {
            guard format as? String == "referenceDate-v1" else {
                throw CocoaError(.fileReadUnknownStringEncoding)
            }
        } else if object["rulesMigrated"] as? Bool == true,
                  var records = object["rules"] as? [[String: Any]] {
            // Older local imports can retain the upstream marker while already containing
            // reference dates. Classify each number, never blindly shift the entire file.
            let latest = Date().addingTimeInterval(86_400)
            for index in records.indices {
                guard let number = records[index]["modified"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let value = number.doubleValue
                if value == 0, records[index]["source"] as? String == "migrated" {
                    records[index]["modified"] = Date(timeIntervalSince1970: 0).timeIntervalSinceReferenceDate
                } else if value >= 0, value <= latest.timeIntervalSinceReferenceDate {
                    // Legacy local date, including a previously imported upstream file.
                } else if value >= Date.timeIntervalBetween1970AndReferenceDate,
                          value <= latest.timeIntervalSince1970 {
                    records[index]["modified"] = Date(timeIntervalSince1970: value).timeIntervalSinceReferenceDate
                } else {
                    // Ambiguous historical/future timestamps must not be rewritten by guessing.
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            object["rules"] = records
        }
        return try JSONDecoder().decode(Payload.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private(set) var rules = RuleBook()
    private(set) var saveError: String?
    private var canSave = true

    init(directory: URL? = nil,
         bundledRulesURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("DefaultRules.json"),
         defaults: UserDefaults = .standard) {
        let cloudBlocked = directory == nil && defaults.bool(forKey: "iCloudSync")
        self.directory = directory ?? Self.defaultDirectory(create: !cloudBlocked)
        self.bundledRulesURL = bundledRulesURL
        url = self.directory.appendingPathComponent("learned.json")
        if cloudBlocked {
            canSave = false
            saveError = "iCloudSync is enabled, but this build cannot safely sync learned.json. Use the upstream app to disable sync after backing up both local and iCloud KeySwitch folders, then relaunch. No local or cloud files were changed."
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do { payload = try readPayload(Data(contentsOf: url)) }
            catch {
                canSave = false
                saveError = "Не удалось прочитать learned.json: \(error.localizedDescription)"
            }
        }
        rules = RuleBook(payload.rules)
        seedBundledRules()
        seedCustomLists()
    }

    var learned: [Lang: [String]] {
        var r: [Lang: [String]] = [:]
        for l in Lang.allCases { r[l] = payload.learned[l.rawValue] ?? [] }
        return r
    }
    var pinned: [String] {
        get { payload.pinned }
        set { payload.pinned = newValue; save() }
    }

    @discardableResult
    func addRule(_ word: String, lang: Lang, kind: FixKind?, result: String? = nil,
                 source: RuleSource = .manual) -> UserRule? {
        let normalized = normalizeWord(word.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalized.isEmpty, normalized.count <= 64,
              !normalized.contains(where: { $0.isWhitespace }) else { return nil }
        let rule = rules.add(normalized, lang: lang, kind: kind, result: result, source: source)
        save()
        return rule
    }

    func removeRule(_ id: String) {
        guard rules.byKey[id] != nil else { return }
        rules.remove(id)
        save()
    }

    func learn(_ word: String, lang: Lang) {
        let w = normalizeWord(word)
        guard !w.isEmpty else { return }
        var list = payload.learned[lang.rawValue] ?? []
        if !list.contains(w) { list.append(w) }
        payload.learned[lang.rawValue] = list
        save()
    }

    func forget(_ word: String, lang: Lang) {
        payload.learned[lang.rawValue]?.removeAll { $0 == normalizeWord(word) }
        save()
    }

    private func save() {
        guard canSave else { return }
        payload.rules = rules.all
        let data: Data
        do {
            let known = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
            var object = originalPayload
            object.merge(known) { _, current in current }
            object["localFormat"] = "referenceDate-v1"
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            saveError = "Не удалось подготовить learned.json"
            return
        }
        let url = self.url
        // Called from the keyboard tap: never block typing on disk I/O.
        UserStore.ioQueue.async { [weak self] in
            do {
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { self?.saveError = nil }
            } catch {
                let message = "Не удалось сохранить learned.json: \(error.localizedDescription)"
                DispatchQueue.main.async { self?.saveError = message }
            }
        }
    }

    func flushPendingWrites() { UserStore.ioQueue.sync {} }

    /// Apply 0.3.2 defaults once. Tombstones in a user's file win over older bundled rules.
    private func seedBundledRules() {
        guard canSave, !payload.rulesSeededFrom032,
              let url = bundledRulesURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let bundled = try JSONDecoder().decode([UserRule].self, from: Data(contentsOf: url))
            // Defaults fill gaps only; an explicit user choice (including a
            // deletion) must win regardless of imported timestamps.
            for rule in bundled where rules.byKey[rule.id] == nil { rules.merge(rule) }
            payload.rulesSeededFrom032 = true
            save()
        } catch {
            saveError = "Не удалось прочитать DefaultRules.json: \(error.localizedDescription)"
        }
    }

    /// Creates editable my_ru.txt / my_en.txt on first launch.
    private func seedCustomLists() {
        for l in Lang.allCases {
            let f = directory.appendingPathComponent("my_\(l.rawValue).txt")
            if !FileManager.default.fileExists(atPath: f.path) {
                let header = l == .ru
                    ? "# Мои русские слова: по одному или через пробел. После правки: меню → Перезагрузить словари.\n"
                    : "# My English words: names, products, jargon. After editing: menu → Reload dictionaries.\n"
                try? header.write(to: f, atomically: true, encoding: .utf8)
            }
        }
    }
}
