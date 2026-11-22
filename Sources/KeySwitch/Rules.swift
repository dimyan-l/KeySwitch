import Foundation

/// What kind of automatic change a correction was.
enum FixKind: String, Codable, CaseIterable {
    case layout, spell, caseFix
}

/// How a rule came to be. Shown in Dictionaries → "Не исправлять".
enum RuleSource: String, Codable {
    case undo           // right ⌥ right after the fix
    case restore        // you put your own word back yourself (Backspace, selection, edit inside, ⌘Z)
    case manual         // "Не исправлять «…»" in the panel or added in Settings
    case migrated       // a word learned by an earlier version
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
}
