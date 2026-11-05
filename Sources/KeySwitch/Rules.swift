import Foundation

/// What kind of automatic change a correction was.
enum FixKind: String, Codable, CaseIterable {
    case layout, spell, caseFix

    var title: String {
        switch self {
        case .layout: "Раскладка"
        case .spell: "Опечатка"
        case .caseFix: "Регистр"
        }
    }
    /// Plural, for the "type" column of the rules list.
    var scopeTitle: String {
        switch self {
        case .layout: "Раскладка"
        case .spell: "Опечатки"
        case .caseFix: "Регистр"
        }
    }
}

/// How a rule came to be. Shown in Dictionaries → "Не исправлять".
enum RuleSource: String, Codable {
    case undo           // right ⌥ right after the fix
    case restore        // you put your own word back yourself (Backspace, selection, edit inside, ⌘Z)
    case manual         // "Не исправлять «…»" in the panel or added in Settings
    case migrated       // a word learned by an earlier version

    var title: String {
        switch self {
        case .undo: "После отмены"
        case .restore: "Ручное восстановление"
        case .manual: "Добавлено вручную"
        case .migrated: "Выучено раньше"
        }
    }
}

/// Your explicit decision, checked before the layout classifier, typo and case fixes.
/// `kind == nil` protects the word from every automatic change; otherwise only that kind of fix
/// (for example the typo fix "внось" → "вновь") is refused and layout fixes keep working.
/// Matches one exact token (normalized: lowercase, ё = е) in one language, never substrings or other forms.
struct UserRule: Codable, Hashable, Identifiable {
    var word: String
    var lang: Lang
    var kind: FixKind?
    /// The replacement you refused, for display ("вновь").
    var result: String?
    var source: RuleSource
    var modified: Date
    /// Tombstone: a deleted rule stays in the file so a merge with another Mac's copy does not bring it back.
    var deleted = false

    var id: String { Self.key(word, lang, kind) }
    static func key(_ word: String, _ lang: Lang, _ kind: FixKind?) -> String {
        "\(lang.rawValue)|\(kind?.rawValue ?? "all")|\(word)"
    }

    var scopeTitle: String { kind?.scopeTitle ?? "Все исправления" }
}

/// Rules in memory. Owned by `UserStore`, read on the main thread by the keyboard handler: no disk access here.
struct RuleBook {
    private(set) var byKey: [String: UserRule] = [:]

    init(_ rules: [UserRule] = []) {
        for r in rules { merge(r) }
    }

    var all: [UserRule] { byKey.values.sorted { $0.modified > $1.modified } }
    var active: [UserRule] { all.filter { !$0.deleted } }

    /// True when your rules forbid this kind of automatic fix of this token.
    func blocks(_ token: String, lang: Lang, kind: FixKind) -> Bool {
        let w = normalizeWord(token)
        guard !w.isEmpty else { return false }
        for k in [UserRule.key(w, lang, nil), UserRule.key(w, lang, kind)] {
            if let r = byKey[k], !r.deleted { return true }
        }
        return false
    }

    /// A layout rule protects a word that starts this way: no switching mid-word on it.
    func protectsPrefix(_ prefix: String, lang: Lang) -> Bool {
        let p = normalizeWord(prefix)
        return byKey.values.contains { !$0.deleted && $0.lang == lang && ($0.kind == nil || $0.kind == .layout) && $0.word.hasPrefix(p) }
    }

    mutating func add(_ word: String, lang: Lang, kind: FixKind?, result: String?, source: RuleSource) -> UserRule {
        let r = UserRule(word: normalizeWord(word), lang: lang, kind: kind, result: result.map(normalizeWord),
                         source: source, modified: Date())
        byKey[r.id] = r
        return r
    }

    mutating func remove(_ id: String) {
        guard var r = byKey[id] else { return }
        r.deleted = true
        r.modified = Date()
        byKey[id] = r
    }

    /// Newest change of each rule wins, deletions included; on a tie the deletion wins.
    mutating func merge(_ r: UserRule) {
        if let have = byKey[r.id] {
            if have.modified > r.modified { return }
            if have.modified == r.modified, have.deleted || !r.deleted { return }
        }
        byKey[r.id] = r
    }

    func merged(with other: RuleBook) -> RuleBook {
        var out = self
        for r in other.byKey.values { out.merge(r) }
        return out
    }
}
