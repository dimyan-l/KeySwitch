import AppKit

/// "Журнал пропусков": words you had to fix yourself (a missed fix) and fixes you took back (a wrong one),
/// with the reason KeySwitch decided as it did. Off by default. Written only on this Mac, to
/// ~/Library/Logs/KeySwitch/missed.log, and only for those words: ordinary typing is never recorded.
enum MissLog {
    enum Kind {
        case missed, wrong
        var title: String { self == .missed ? "ПРОПУСК" : "ЛИШНЯЯ ЗАМЕНА" }
    }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KeySwitch/missed.log")
    }

    /// Self-test only: lines go here (and not to the file), whatever the setting.
    nonisolated(unsafe) static var sink: ((String) -> Void)?

    static var isOn: Bool { sink != nil || Settings.shared.missLogEnabled }

    private static let queue = DispatchQueue(label: "keyswitch.misslog", qos: .utility)
    private static let maxBytes = 1_000_000
    private static let keepLines = 500
    private static let header = """
    # KeySwitch — журнал пропусков.
    # ПРОПУСК: слово не исправилось само, и вы исправили его правым ⌥.
    # ЛИШНЯЯ ЗАМЕНА: KeySwitch исправил слово, а вы вернули своё.
    # Сюда попадают только такие слова; обычный набор не записывается. Файл хранится только на этом Mac.

    """

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// One line: date · app · kind · «typed» → «result» · how · reason.
    static func line(_ kind: Kind, typed: String, result: String, how: String, reason: String, app: String, date: Date = Date()) -> String {
        [dateFormat.string(from: date), app, kind.title, "«\(typed)» → «\(result)»", how, reason].joined(separator: " · ")
    }

    static func write(_ kind: Kind, typed: String, result: String, how: String, reason: String) {
        guard isOn else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
        let text = line(kind, typed: typed, result: result, how: how, reason: reason, app: app)
        if let sink { sink(text); return }
        queue.async { append(text) }
    }

    private static func append(_ text: String) {
        let fm = FileManager.default
        let u = url
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: u.path) { try? header.write(to: u, atomically: true, encoding: .utf8) }
        guard let h = try? FileHandle(forWritingTo: u) else { return }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((text + "\n").utf8))
        try? h.close()
        trimIfNeeded(u)
    }

    /// Past ~1 MB only the newest lines are kept.
    private static func trimIfNeeded(_ u: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        guard size > maxBytes, let all = try? String(contentsOf: u, encoding: .utf8) else { return }
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let kept = header + lines.suffix(keepLines).joined(separator: "\n") + "\n"
        try? kept.write(to: u, atomically: true, encoding: .utf8)
    }

    /// Entries in the file (header lines not counted). Read off the main thread by the caller if it matters.
    static func count() -> Int {
        guard let all = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return all.split(separator: "\n").filter { !$0.hasPrefix("#") }.count
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    static func open() {
        queue.async {
            let u = url
            if !FileManager.default.fileExists(atPath: u.path) {
                try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? header.write(to: u, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
        }
    }
}
