import Foundation

/// A word you fixed yourself with right ⌥. The next time the same word is typed in the same
/// layout, KeySwitch makes the same change automatically. Undoing that change forgets it.
struct TaughtFix: Codable, Hashable {
    /// The word as typed, normalized (lowercase, ё = е). Punctuation keys that type letters in
    /// the other layout stay part of it ("k.,k." → "люблю").
    var word: String
    /// Language of the layout the word was typed in.
    var lang: Lang
    /// What you chose, lowercased.
    var result: String
    /// Language of `result`: the other one when the layout was wrong.
    var resultLang: Lang
    var modified: Date

    var id: String { Self.key(word, lang) }
    static func key(_ word: String, _ lang: Lang) -> String { "\(lang.rawValue)|\(normalizeWord(word))" }
}

enum TaughtFixes {
    struct Replacement: Equatable {
        let fix: TaughtFix
        /// The matched word without the punctuation around it, as typed.
        let typedWord: String
        /// The new text for that word.
        let word: String
        /// The new text for the whole typed token, punctuation around the word kept.
        let text: String
        /// The new word is the same keys read in the other layout (no spelling change).
        let isLayoutFlip: Bool
    }

    /// The replacement you taught for `typed`, or nil.
    /// `flip` reads characters `range` of `typed` in `resultLang` from the original keystrokes.
    static func replacement(for typed: String, lang: Lang, lookup: (String) -> TaughtFix?,
                            flip: (_ range: Range<Int>, _ lang: Lang) -> String?) -> Replacement? {
        let chars = Array(typed)
        guard chars.contains(where: \.isLetter) else { return nil }
        let lead = chars.prefix { !$0.isLetter }.count
        let trail = chars.reversed().prefix { !$0.isLetter }.count
        var cuts = [(0, 0)]
        if lead + trail > 0, lead + trail < chars.count { cuts.append((lead, trail)) }
        for (first, last) in cuts {
            let range = first..<(chars.count - last)
            let typedWord = String(chars[range])
            guard let fix = lookup(TaughtFix.key(typedWord, lang)) else { continue }
            let flipped = fix.resultLang != lang ? flip(range, fix.resultLang) : nil
            let word: String
            let isLayoutFlip: Bool
            if let flipped, normalizeWord(flipped) == normalizeWord(fix.result) {
                word = flipped // the keystrokes keep your capitals and the exact letters
                isLayoutFlip = true
            } else if let cased = matchCase(fix.result, to: typedWord) {
                word = cased
                isLayoutFlip = false
            } else {
                continue
            }
            guard word != typedWord else { continue }
            let text = String(chars[..<first]) + word + String(chars[(chars.count - last)...])
            return Replacement(fix: fix, typedWord: typedWord, word: word, text: text, isLayoutFlip: isLayoutFlip)
        }
        return nil
    }

    /// "превет" → "привет", "Превет" → "Привет", "ПРЕВЕТ" → "ПРИВЕТ"; other mixed case is left alone.
    static func matchCase(_ result: String, to typed: String) -> String? {
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased(), letters != letters.lowercased() {
            return result.uppercased()
        }
        return SpellCorrector.Casing(typed)?.apply(result.lowercased())
    }
}
