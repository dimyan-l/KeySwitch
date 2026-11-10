import Foundation

/// A bounded, dictionary-only typo check that is safe to run in the keyboard tap.
/// It never calls the system spell checker or reads files while handling a key.
enum SpellCorrector {
    static let minLength = 4
    static let maxLength = 16
    static let minScore: Float = 3.5
    static let soloScore: Float = 4.3
    static let margin: Float = 1.0

    static func correction(for typed: String, alternative: String,
                           model: LanguageModel, other: LanguageModel?) -> String? {
        guard (minLength...maxLength).contains(typed.count), typed == typed.lowercased() else { return nil }
        let word = normalizeWord(typed)
        guard word.allSatisfy({ model.letters.contains($0) }), model.score(word) == nil else { return nil }
        if let other {
            let alternate = other.core(normalizeWord(alternative))
            if other.isWord(alternate), other.score(alternate) != nil { return nil }
        }

        var best: (word: String, score: Float)?
        var runnerUp: Float?
        for candidate in candidates(word, letters: model.letters) {
            guard let score = model.score(candidate), score >= minScore else { continue }
            if let current = best {
                if score > current.score {
                    runnerUp = current.score
                    best = (candidate, score)
                } else if score > (runnerUp ?? -.infinity) {
                    runnerUp = score
                }
            } else {
                best = (candidate, score)
            }
        }
        guard let best else { return nil }
        if let runnerUp {
            guard best.score - runnerUp >= margin else { return nil }
        } else {
            guard best.score >= soloScore else { return nil }
        }
        return best.word
    }

    /// Manual suggestions can be broader than automatic corrections: the user
    /// chooses one, and this work runs outside the keyboard event tap.
    static func suggestions(for typed: String, model: LanguageModel, limit: Int = 3) -> [String] {
        let word = normalizeWord(typed)
        guard (minLength...maxLength).contains(word.count), model.isWord(word),
              model.score(word) == nil else { return [] }
        return candidates(word, letters: model.letters)
            .compactMap { candidate -> (String, Float)? in
                guard let score = model.score(candidate), score >= 3.0 else { return nil }
                return (candidate, score)
            }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .prefix(max(0, limit))
            .map(\.0)
    }

    private static func candidates(_ word: String, letters: Set<Character>) -> Set<String> {
        let chars = Array(word)
        let alphabet = Array(letters)
        var result = Set<String>()
        for i in chars.indices {
            var deletion = chars
            deletion.remove(at: i)
            result.insert(String(deletion))
            if i + 1 < chars.count {
                var swap = chars
                swap.swapAt(i, i + 1)
                result.insert(String(swap))
            }
            for letter in alphabet where letter != chars[i] {
                var replacement = chars
                replacement[i] = letter
                result.insert(String(replacement))
            }
        }
        for i in 0...chars.count {
            for letter in alphabet {
                var insertion = chars
                insertion.insert(letter, at: i)
                result.insert(String(insertion))
            }
        }
        result.remove(word)
        return result
    }
}
