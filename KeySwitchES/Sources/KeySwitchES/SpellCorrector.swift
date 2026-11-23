import Foundation

/// A bounded, dictionary-only typo check that is safe to run in the keyboard tap.
/// It never calls the system spell checker or reads files while handling a key.
enum SpellCorrector {
    static let minLength = 4
    static let maxLength = 16
    static let minScore: Float = 3.5
    static let soloScore: Float = 4.3
    static let margin: Float = 1.0
    /// Likely edits (neighbouring key, swapped letters, doubled letter) get this bonus when ranking.
    static let likelyEditBonus: Float = 0.6

    /// Typed text with its letter case, so the replacement keeps "Превет" → "Привет".
    enum Casing {
        case lower, title

        init?(_ s: String) {
            if s == s.lowercased() { self = .lower; return }
            guard let first = s.first, first.isUppercase,
                  String(s.dropFirst()) == String(s.dropFirst()).lowercased() else { return nil }
            self = .title
        }

        func apply(_ s: String) -> String {
            switch self {
            case .lower: return s
            case .title: return s.prefix(1).uppercased() + s.dropFirst()
            }
        }
    }

    static func correction(for typed: String, alternative: String,
                           model: LanguageModel, other: LanguageModel?) -> String? {
        // ALL CAPS and MiXeD case are usually acronyms or names: leave them alone.
        guard let casing = Casing(typed) else { return nil }
        let word = normalizeWord(typed)
        guard (3...maxLength).contains(word.count), word.allSatisfy({ model.letters.contains($0) }) else { return nil }
        if let other {
            let alternate = other.core(normalizeWord(alternative))
            if other.isWord(alternate), other.score(alternate) != nil { return nil }
        }
        // The frequency lists contain a few popular misspellings; those are fixed from a short,
        // reviewed list. Any other dictionary word is left alone: rare words are still words.
        if let fixed = knownMisspellings[model.lang.rawValue]?[word], model.score(fixed) != nil {
            return casing.apply(fixed)
        }
        guard model.score(word) == nil else { return nil }
        // Three-letter words: only swapped letters ("teh" → "the"), and only for very common words.
        let shortWord = word.count < minLength

        var best: (word: String, score: Float, raw: Float)?
        var runnerUp: Float?
        for (candidate, likely) in candidates(word, letters: model.letters, swapsOnly: shortWord, keepFirstLetter: true) {
            guard let raw = model.score(candidate), raw >= minScore else { continue }
            let score = raw + (likely ? likelyEditBonus : 0)
            if let current = best {
                if score > current.score {
                    runnerUp = current.score
                    best = (candidate, score, raw)
                } else if score > (runnerUp ?? -.infinity) {
                    runnerUp = score
                }
            } else {
                best = (candidate, score, raw)
            }
        }
        guard let best else { return nil }
        if shortWord { guard best.raw >= 5.5 else { return nil } }
        if let runnerUp {
            guard best.score - runnerUp >= margin else { return nil }
        } else {
            guard best.raw >= soloScore || (word.count >= 7 && best.raw >= minScore + 0.3) else { return nil }
        }
        return casing.apply(best.word)
    }

    /// Manual suggestions can be broader than automatic corrections: the user
    /// chooses one, and this work runs outside the keyboard event tap.
    static func suggestions(for typed: String, model: LanguageModel, limit: Int = 3) -> [String] {
        let word = normalizeWord(typed)
        guard (minLength...maxLength).contains(word.count), model.isWord(word),
              (model.score(word) ?? 0) < 3.0 else { return [] }
        return candidates(word, letters: model.letters, swapsOnly: false)
            .compactMap { candidate, likely -> (String, Float)? in
                guard let score = model.score(candidate), score >= 3.0 else { return nil }
                return (candidate, score + (likely ? likelyEditBonus : 0))
            }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .prefix(max(0, limit))
            .map(\.0)
    }

    /// Misspellings frequent enough to appear in the frequency lists themselves.
    static let knownMisspellings: [String: [String: String]] = [
        "ru": [
            "здраствуйте": "здравствуйте", "дравствуйте": "здравствуйте", "звините": "извините",
            "прийдется": "придется", "озможно": "возможно",
            "увидемся": "увидимся", "находитс": "находится",
        ],
        "en": [
            "realy": "really", "adress": "address", "wierd": "weird", "untill": "until",
            "occured": "occurred", "seperate": "separate", "acheive": "achieve", "beleive": "believe",
            "truely": "truly", "tommorrow": "tomorrow", "tomorow": "tomorrow", "begining": "beginning",
            "definatly": "definitely", "thier": "their", "freind": "friend",
        ],
    ]

    // MARK: - Candidates

    /// Physical rows of the ЙЦУКЕН and QWERTY layouts (same keys), for neighbour-key typos.
    private static let rows: [[Character]] = [
        Array("qwertyuiop[]"), Array("asdfghjkl;'"), Array("zxcvbnm,./"),
        Array("йцукенгшщзхъ"), Array("фывапролджэ"), Array("ячсмитьбю."),
    ]
    private static let rowStagger: [Double] = [0, 0.25, 0.75]
    private static let keyPosition: [Character: (row: Int, x: Double)] = {
        var map: [Character: (Int, Double)] = [:]
        for (i, row) in rows.enumerated() {
            let r = i % 3
            for (c, ch) in row.enumerated() where map[ch] == nil { map[ch] = (r, Double(c) + rowStagger[r]) }
        }
        map["ё"] = map["е"]
        return map
    }()

    static func areNeighbours(_ a: Character, _ b: Character) -> Bool {
        guard let p = keyPosition[a], let q = keyPosition[b] else { return false }
        let dr = abs(p.row - q.row)
        return dr <= 1 && abs(p.x - q.x) <= (dr == 0 ? 1.0 : 0.75)
    }

    /// All words one edit away, flagged when the edit is a typical slip of the finger.
    /// `keepFirstLetter`: automatic fixes never add or drop the first letter. A leading letter is
    /// usually a prefix or preposition of a real word ("сверить" is not "верить"), not a slip.
    private static func candidates(_ word: String, letters: Set<Character>, swapsOnly: Bool,
                                   keepFirstLetter: Bool = false) -> [String: Bool] {
        let chars = Array(word)
        let alphabet = Array(letters)
        var result: [String: Bool] = [:]
        func add(_ s: [Character], likely: Bool) {
            let key = String(s)
            result[key] = (result[key] ?? false) || likely
        }
        for i in chars.indices where i + 1 < chars.count && chars[i] != chars[i + 1] {
            var swap = chars
            swap.swapAt(i, i + 1)
            add(swap, likely: true)
        }
        if !swapsOnly {
            for i in chars.indices {
                // A doubled first letter ("ппривет") is still removed: deleting either copy gives the same word.
                let dropsFirstLetter = keepFirstLetter && i == 0 && (chars.count < 2 || chars[1] != chars[0])
                var deletion = chars
                deletion.remove(at: i)
                // Extra doubled letter or a neighbouring key pressed together with the right one.
                let likely = (i > 0 && chars[i - 1] == chars[i]) || (i + 1 < chars.count && chars[i + 1] == chars[i])
                    || (i > 0 && areNeighbours(chars[i - 1], chars[i]))
                    || (i + 1 < chars.count && areNeighbours(chars[i + 1], chars[i]))
                if !dropsFirstLetter { add(deletion, likely: likely) }
                for letter in alphabet where letter != chars[i] {
                    var replacement = chars
                    replacement[i] = letter
                    add(replacement, likely: areNeighbours(letter, chars[i]))
                }
            }
            for i in (keepFirstLetter ? 1 : 0)...chars.count {
                for letter in alphabet {
                    var insertion = chars
                    insertion.insert(letter, at: i)
                    // A missed doubled letter ("adress" → "address").
                    let likely = (i > 0 && chars[i - 1] == letter) || (i < chars.count && chars[i] == letter)
                    add(insertion, likely: likely)
                }
            }
        }
        result.removeValue(forKey: word)
        return result
    }
}
