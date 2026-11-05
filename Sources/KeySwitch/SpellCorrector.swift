import AppKit

/// Cautious typo fixer. It only runs on words the layout classifier decided to leave alone, and only
/// touches a word when every guard below holds. Candidates come from your own dictionaries (so jargon,
/// `my_*.txt` and learned words are never "fixed"), ranked by frequency.
enum SpellCorrector {
    static let minLength = 4
    /// log10(per-billion frequency): the replacement must be a reasonably common word.
    static let minScore: Float = 3.0
    /// The best candidate must beat the runner-up by this much (1.0 = 10x as frequent; 0.5 gave 2.6-4.7% wrong fixes on synthetic typos, 1.5 lost classics like recieve).
    static let margin: Float = 1.0
    /// A lone candidate has no runner-up to beat, which proves nothing: it must be common on its own.
    static var soloScore: Float = 3.5

    /// Is this a valid word form? The 80 000-word frequency list misses many real forms ("выставь", rare
    /// case endings), so the system's local morphological dictionary vetoes "fixing" them. Candidates still
    /// come only from our own dictionaries. Replaceable in tests; nil = no veto.
    /// Called from the keyboard thread (and once at launch to warm it up): one call at a time.
    /// The newer `check(_:range:types:…)` API was tried and accepts typos like «внось»: this one does not.
    private static let spellLock = NSLock()
    static var isValidForm: ((String, Lang) -> Bool)? = { word, lang in
        spellLock.withLock {
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: lang.rawValue,
                                                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    static func correction(for typed: String, altReading: String, model m: LanguageModel, other: LanguageModel?) -> String? {
        // Plain lowercase words only: names, ALLCAPS, CamelCase, digits, hyphens and apostrophes are left alone.
        guard typed.count >= minLength, typed == typed.lowercased() else { return nil }
        let w = normalizeWord(typed)
        guard w.allSatisfy({ m.letters.contains($0) }) else { return nil }
        // A known word is not a typo.
        guard m.score(w) == nil else { return nil }
        // The same keys read in the other layout are a real word: that is a layout question, not a typo.
        if let o = other {
            let alt = o.core(normalizeWord(altReading))
            if o.isWord(alt), o.score(alt) != nil { return nil }
        }

        var best: (word: String, score: Float)?
        var runnerUp: Float?
        for c in candidates(w, letters: m.letters) {
            guard let s = m.score(c), s >= minScore else { continue }
            if let b = best {
                if s > b.score { runnerUp = b.score; best = (c, s) } else if s > (runnerUp ?? -.infinity) { runnerUp = s }
            } else {
                best = (c, s)
            }
        }
        guard let b = best else { return nil }
        if let r = runnerUp {
            guard b.score - r >= margin else { return nil }
        } else {
            guard b.score >= soloScore else { return nil }
        }
        // Checked last: the system dictionary is the slowest step and only needed when we are about to change the word.
        if let valid = isValidForm, valid(typed, m.lang) { return nil }
        return b.word
    }

    /// Every string one edit away: deletion, transposition, substitution, insertion.
    static func candidates(_ w: String, letters: Set<Character>) -> Set<String> {
        let chars = Array(w)
        let alphabet = Array(letters)
        var out = Set<String>()
        for i in 0..<chars.count {
            var d = chars; d.remove(at: i); out.insert(String(d))
            if i + 1 < chars.count { var t = chars; t.swapAt(i, i + 1); out.insert(String(t)) }
            for a in alphabet where a != chars[i] { var r = chars; r[i] = a; out.insert(String(r)) }
        }
        for i in 0...chars.count {
            for a in alphabet { var n = chars; n.insert(a, at: i); out.insert(String(n)) }
        }
        out.remove(w)
        return out
    }
}
