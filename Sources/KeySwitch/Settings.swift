import CoreGraphics
import Foundation

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
    ]

    /// Self-test only: typing scenarios run with fixes on and no app exclusions, whatever you chose.
    var testMode = false

    private init() {
        // Updating from 0.1.0, where typo fixes and the copy history were always on: keep what you had.
        // New installs start with layout fixes only and no copy history.
        let existing = !(d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?.isEmpty ?? true)
        if existing {
            if d.object(forKey: "spellEnabled") == nil { d.set(true, forKey: "spellEnabled") }
            if d.object(forKey: "clipboardEnabled") == nil { d.set(true, forKey: "clipboardEnabled") }
        }
        d.register(defaults: [
            "autoEnabled": true,
            "soundEnabled": false,
            "soundChoice": SwitchSound.drop.rawValue,
            "soundVolume": 0.4,
            "excluded": Settings.defaultExcluded,
            "layoutOnly": [String](),
            "showToast": true,
            "earlySwitch": true,
            "compatibleTyping": false,
            "missLogEnabled": false,
            "perAppLayout": true,
            "iCloudSync": false,
            "spellEnabled": false,
            "clipboardEnabled": false,
            "menuBarStyle": "lang",
            "onboardingDone": false,
        ])
    }

    var spellEnabled: Bool {
        get { testMode || d.bool(forKey: "spellEnabled") }
        set { d.set(newValue, forKey: "spellEnabled") }
    }

    /// The last few copied texts in the panel. Kept in memory only.
    /// Snapshots only: shows or hides the copies without touching your setting.
    var clipboardOverride: Bool?
    var clipboardEnabled: Bool {
        get { clipboardOverride ?? d.bool(forKey: "clipboardEnabled") }
        set { d.set(newValue, forKey: "clipboardEnabled") }
    }

    /// Apps where only the layout is fixed, never typos.
    var layoutOnly: [String] {
        get { d.stringArray(forKey: "layoutOnly") ?? [] }
        set { d.set(newValue, forKey: "layoutOnly") }
    }

    enum AppMode: String, CaseIterable, Identifiable {
        case layoutOnly, all, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .layoutOnly: "Только раскладка"
            case .all: "Раскладка и опечатки"
            case .off: "Не исправлять"
            }
        }
    }

    /// Always off, whatever the lists say: our own windows and JetBrains IDEs.
    func isAlwaysExcluded(_ bundleID: String) -> Bool {
        bundleID == Bundle.main.bundleIdentifier || bundleID.hasPrefix("com.jetbrains.")
    }

    func mode(for bundleID: String) -> AppMode {
        if isAlwaysExcluded(bundleID) || excluded.contains(bundleID) { return .off }
        return layoutOnly.contains(bundleID) ? .layoutOnly : .all
    }

    func setMode(_ m: AppMode, for bundleID: String) {
        var e = excluded.filter { $0 != bundleID }
        var l = layoutOnly.filter { $0 != bundleID }
        switch m {
        case .off: e.append(bundleID)
        case .layoutOnly: l.append(bundleID)
        case .all: break
        }
        excluded = e
        layoutOnly = l
    }

    /// Apps with their own setting, in the order they were added.
    var configuredApps: [String] { excluded + layoutOnly.filter { !excluded.contains($0) } }

    /// Typo fixes on for this app.
    func spellAllowed(in bundleID: String?) -> Bool {
        guard spellEnabled else { return false }
        guard let b = bundleID else { return true }
        return !layoutOnly.contains(b)
    }

    /// Keep the personal dictionary in iCloud Drive, shared by all your Macs.
    var iCloudSync: Bool {
        get { d.bool(forKey: "iCloudSync") }
        set { d.set(newValue, forKey: "iCloudSync") }
    }
    /// Switch to the layout you last used in an app when you come back to it.
    var perAppLayout: Bool {
        get { d.bool(forKey: "perAppLayout") }
        set { d.set(newValue, forKey: "perAppLayout") }
    }
    func rememberedLayout(for bundleID: String) -> Lang? {
        (d.dictionary(forKey: "appLayouts")?[bundleID] as? String).flatMap(Lang.init(rawValue:))
    }
    func rememberLayout(_ lang: Lang, for bundleID: String) {
        var all = d.dictionary(forKey: "appLayouts") ?? [:]
        guard all[bundleID] as? String != lang.rawValue else { return }
        all[bundleID] = lang.rawValue
        d.set(all, forKey: "appLayouts")
    }

    /// Switch the layout after the first letters when the start of the word already tells.
    var earlySwitch: Bool {
        get { testMode || d.bool(forKey: "earlySwitch") }
        set { d.set(newValue, forKey: "earlySwitch") }
    }
    /// Type corrections one character at a time, with pauses: for the rare app that drops fast input.
    var compatibleTyping: Bool {
        get { d.bool(forKey: "compatibleTyping") }
        set { d.set(newValue, forKey: "compatibleTyping") }
    }

    var showToast: Bool {
        get { d.bool(forKey: "showToast") }
        set { d.set(newValue, forKey: "showToast") }
    }
    /// "Журнал пропусков": words you fixed or took back yourself, with the reason (see MissLog).
    var missLogEnabled: Bool {
        get { d.bool(forKey: "missLogEnabled") }
        set { d.set(newValue, forKey: "missLogEnabled") }
    }
    /// "lang" (RU / EN pill), "dot" or "hidden"
    var menuBarStyle: String {
        get { d.string(forKey: "menuBarStyle") ?? "lang" }
        set { d.set(newValue, forKey: "menuBarStyle") }
    }
    var onboardingDone: Bool {
        get { d.bool(forKey: "onboardingDone") }
        set { d.set(newValue, forKey: "onboardingDone") }
    }

    var autoEnabled: Bool {
        get { testMode || d.bool(forKey: "autoEnabled") }
        set { d.set(newValue, forKey: "autoEnabled") }
    }
    var soundEnabled: Bool {
        get { d.bool(forKey: "soundEnabled") }
        set { d.set(newValue, forKey: "soundEnabled") }
    }
    var soundChoice: String {
        get { d.string(forKey: "soundChoice") ?? SwitchSound.drop.rawValue }
        set { d.set(newValue, forKey: "soundChoice") }
    }
    var soundVolume: Double {
        get { d.double(forKey: "soundVolume") }
        set { d.set(newValue, forKey: "soundVolume") }
    }

    var excluded: [String] {
        get { d.stringArray(forKey: "excluded") ?? [] }
        set { d.set(newValue, forKey: "excluded") }
    }
    func isExcluded(_ bundleID: String?) -> Bool {
        guard let b = bundleID, !testMode else { return false }
        return isAlwaysExcluded(b) || excluded.contains(b) // our own dialogs (API key field!), JetBrains
    }
    func toggleExcluded(_ bundleID: String) {
        var e = excluded
        if let i = e.firstIndex(of: bundleID) { e.remove(at: i) } else { e.append(bundleID) }
        excluded = e
    }
}

/// Persistent learning: your "do not correct" rules and the words you taught it.
/// Lives in Application Support, or in iCloud Drive when sync is on, so all your Macs share one dictionary.
/// Every change applies in memory at once; disk writes go through one serial queue, off the keyboard handler.
final class UserStore {
    // Older learned.json files may also hold "uncertain" / "fixes" lists from an earlier version: they are ignored.
    // Versions without rules ignore the "rules" key, so the file stays readable after a rollback.
    fileprivate struct Payload: Codable {
        var learned: [String: [String]] = [:]
        var rules: [UserRule]?
        /// Learned words were copied into rules once: deleting such a rule must not recreate it.
        var rulesMigrated: Bool?
    }

    static let localDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("KeySwitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/Library/Mobile Documents/com~apple~CloudDocs/KeySwitch, or nil when iCloud Drive is off on this Mac.
    static var cloudDirectory: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("KeySwitch", isDirectory: true)
    }

    static var directory: URL {
        if Settings.shared.iCloudSync, let cloud = cloudDirectory {
            try? FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
            return cloud
        }
        return localDirectory
    }

    private static let ioQueue = DispatchQueue(label: "keyswitch.store")
    /// Fixed folder for tests; nil = the local or iCloud folder from Settings.
    private let fixedDirectory: URL?
    var folder: URL { fixedDirectory ?? UserStore.directory }
    private var url: URL { folder.appendingPathComponent("learned.json") }
    private var payload = Payload()
    private(set) var rules = RuleBook()
    /// Forgotten one by one this session: a merge with another Mac's copy must not bring them back.
    private var forgotten: [String: Set<String>] = [:]
    private var seenModification: Date?
    /// Set when the last write failed: the rules still work in memory, but only until you quit.
    private(set) var saveError: String?
    /// Test hook: makes every write fail.
    var simulateWriteFailure = false

    init(directory: URL? = nil) {
        fixedDirectory = directory
        reload()
    }

    /// Reads learned.json (and my_*.txt on next use) again: after switching sync on/off or when another Mac changed them.
    /// Waits for queued writes first; changes that could not be written are kept and merged in.
    func reload() {
        flush()
        var disk = Self.read(url) ?? Payload()
        var book = RuleBook(disk.rules ?? [])
        if saveError != nil {
            book = book.merged(with: rules)
            for (lang, words) in payload.learned {
                var list = disk.learned[lang] ?? []
                for w in words where !list.contains(w) { list.append(w) }
                disk.learned[lang] = list
            }
        }
        payload = disk
        rules = book
        customCache = [:]
        seenModification = modificationDate
        seedCustomLists()
        migrateLearnedToRules()
    }

    /// Blocks until every queued write is on disk (or failed). Never called from the keyboard handler.
    func flush() { UserStore.ioQueue.sync {} }

    /// Words learned by earlier versions meant "do not correct this": they become visible, removable rules.
    private func migrateLearnedToRules() {
        guard payload.rulesMigrated != true else { return }
        let old = Date(timeIntervalSince1970: 0) // older than any deletion, on any Mac
        for (l, words) in learned {
            for w in words where !rules.blocks(w, lang: l, kind: .layout) {
                var r = UserRule(word: w, lang: l, kind: nil, result: nil, source: .migrated, modified: old)
                r.deleted = false
                rules.merge(r)
            }
        }
        payload.rulesMigrated = true
        save()
    }

    // MARK: Rules

    /// Applies at once in memory; `done(true)` on the main thread once it is on disk.
    @discardableResult
    func addRule(_ word: String, lang: Lang, kind: FixKind?, result: String?, source: RuleSource,
                 done: ((Bool) -> Void)? = nil) -> UserRule {
        let r = rules.add(word, lang: lang, kind: kind, result: result, source: source)
        save(done)
        return r
    }

    /// Deleting a rule brings the standard behaviour back: the word is also forgotten as a learned word.
    func removeRule(_ id: String) {
        guard let r = rules.byKey[id] else { return }
        rules.remove(id)
        if learned[r.lang]?.contains(r.word) == true {
            payload.learned[r.lang.rawValue]?.removeAll { $0 == r.word }
            forgotten[r.lang.rawValue, default: []].insert(r.word)
        }
        save()
    }

    /// Writes again after a failure.
    func retrySave(_ done: ((Bool) -> Void)? = nil) { save(done) }

    /// True when the files changed on disk behind our back (edited by hand, or iCloud brought another Mac's words).
    var changedOnDisk: Bool { modificationDate != seenModification }

    private var modificationDate: Date? {
        let files = [url] + Lang.allCases.map(customFile)
        return files.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
    }

    private static func read(_ url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(Payload.self, from: data)
    }

    var learned: [Lang: [String]] {
        var r: [Lang: [String]] = [:]
        for l in Lang.allCases { r[l] = payload.learned[l.rawValue] ?? [] }
        return r
    }

    func learn(_ word: String, lang: Lang) {
        let w = normalizeWord(word)
        guard !w.isEmpty else { return }
        var list = payload.learned[lang.rawValue] ?? []
        if !list.contains(w) { list.append(w) }
        payload.learned[lang.rawValue] = list
        forgotten[lang.rawValue]?.remove(w)
        save()
    }

    func forget(_ word: String, lang: Lang) {
        let w = normalizeWord(word)
        payload.learned[lang.rawValue]?.removeAll { $0 == w }
        forgotten[lang.rawValue, default: []].insert(w)
        save()
    }

    func forgetAllLearned() {
        payload.learned = [:]
        save(merging: false)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// Merges with what is on disk first, so words and rules from another Mac meanwhile are not overwritten.
    /// Runs on the serial queue (never blocks typing); `done` reports on the main thread whether it reached the disk.
    private func save(merging: Bool = true, _ done: ((Bool) -> Void)? = nil) {
        let url = self.url
        var mine = payload
        mine.rules = rules.all
        let forgotten = self.forgotten
        let fail = simulateWriteFailure
        UserStore.ioQueue.async {
            var out = mine
            if merging, let disk = UserStore.read(url) {
                out = UserStore.merged(out, disk, forgotten: forgotten)
            }
            var error: String?
            do {
                if fail { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try UserStore.encoder().encode(out).write(to: url, options: .atomic)
            } catch let e {
                error = e.localizedDescription
            }
            DispatchQueue.main.async {
                self.saveError = error
                if error == nil { self.seenModification = self.modificationDate }
                done?(error == nil)
            }
        }
    }

    /// `a` wins for learned-word deletions (`forgotten`); rules: the newest change of each wins.
    private static func merged(_ a: Payload, _ b: Payload, forgotten: [String: Set<String>] = [:]) -> Payload {
        var out = a
        for (lang, words) in b.learned {
            let gone = forgotten[lang] ?? []
            var list = out.learned[lang] ?? []
            for w in words where !list.contains(w) && !gone.contains(w) { list.append(w) }
            out.learned[lang] = list
        }
        out.rules = RuleBook(a.rules ?? []).merged(with: RuleBook(b.rules ?? [])).all
        out.rulesMigrated = (a.rulesMigrated ?? false) || (b.rulesMigrated ?? false) ? true : nil
        return out
    }

    /// Switches iCloud sync on or off: waits for pending writes, takes your words and rules along
    /// (merging with what is already there), then reads the new folder.
    func setCloudSync(_ on: Bool, cloud: URL) {
        flush()
        UserStore.ioQueue.sync {
            if on { UserStore.merge(from: UserStore.localDirectory, into: cloud) }
            else { UserStore.merge(from: cloud, into: UserStore.localDirectory) }
        }
        Settings.shared.iCloudSync = on
        reload()
    }

    /// Copies (merges) everything from one folder into another: used when sync is switched on or off.
    static func merge(from src: URL, into dst: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var out = read(dst.appendingPathComponent("learned.json")) ?? Payload()
        if let a = read(src.appendingPathComponent("learned.json")) { out = merged(out, a) }
        if let data = try? encoder().encode(out) { try? data.write(to: dst.appendingPathComponent("learned.json"), options: .atomic) }
        for l in Lang.allCases {
            let name = "my_\(l.rawValue).txt"
            let from = (try? String(contentsOf: src.appendingPathComponent(name), encoding: .utf8)) ?? ""
            let to = (try? String(contentsOf: dst.appendingPathComponent(name), encoding: .utf8)) ?? ""
            let have = Set(to.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.flatMap { tokens(of: $0) })
            let missing = from.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
                .flatMap { tokens(of: $0) }.filter { !have.contains($0) }
            if to.isEmpty, !from.isEmpty {
                try? from.write(to: dst.appendingPathComponent(name), atomically: true, encoding: .utf8)
            } else if !missing.isEmpty {
                let text = to + (to.hasSuffix("\n") ? "" : "\n") + missing.joined(separator: "\n") + "\n"
                try? text.write(to: dst.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: my_ru.txt / my_en.txt

    private func customFile(_ lang: Lang) -> URL {
        folder.appendingPathComponent("my_\(lang.rawValue).txt")
    }

    fileprivate static func tokens(of line: Substring) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
    }

    /// Read once and kept until we change the file or you reload the dictionaries (the Words pane asks on every render).
    private var customCache: [Lang: [String]] = [:]

    func customWords(_ lang: Lang) -> [String] {
        if let cached = customCache[lang] { return cached }
        let text = (try? String(contentsOf: customFile(lang), encoding: .utf8)) ?? ""
        let words = text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .flatMap { Self.tokens(of: $0) }
        customCache[lang] = words
        return words
    }

    /// The files may have been edited by hand: read them again next time.
    func reloadCustomWords() { customCache = [:] }

    func addCustomWord(_ word: String, lang: Lang) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !customWords(lang).contains(w) else { return }
        let existing = (try? String(contentsOf: customFile(lang), encoding: .utf8)) ?? ""
        let text = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + w + "\n"
        try? text.write(to: customFile(lang), atomically: true, encoding: .utf8)
        customCache[lang] = nil
        seenModification = modificationDate // our own change: no need to reload
    }

    func removeCustomWord(_ word: String, lang: Lang) {
        guard let text = try? String(contentsOf: customFile(lang), encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("#") { return String(line) }
            return Self.tokens(of: line).filter { $0 != word }.joined(separator: " ")
        }
        try? lines.joined(separator: "\n").write(to: customFile(lang), atomically: true, encoding: .utf8)
        customCache[lang] = nil
        seenModification = modificationDate
    }

    /// Creates editable my_ru.txt / my_en.txt on first launch (and fixes the hint line older versions wrote).
    private func seedCustomLists() {
        for l in Lang.allCases {
            let f = customFile(l)
            if let text = try? String(contentsOf: f, encoding: .utf8), let first = text.split(separator: "\n").first,
               first.contains("Перезагрузить словари") || first.contains("Reload dictionaries") || first.contains("→ Перезагрузить") || first.contains("→ Reload") {
                let hint = l == .ru ? "# Мои русские слова: по одному или через пробел. Правки подхватываются сами."
                                    : "# My English words: names, products, jargon. Changes are picked up automatically."
                try? (hint + text.dropFirst(first.count)).write(to: f, atomically: true, encoding: .utf8)
            }
            if !FileManager.default.fileExists(atPath: f.path) {
                let header = l == .ru
                    ? "# Мои русские слова: по одному или через пробел. Правки подхватываются сами.\n"
                    : "# My English words: names, products, jargon. Changes are picked up automatically.\n"
                try? header.write(to: f, atomically: true, encoding: .utf8)
            }
        }
    }
}
