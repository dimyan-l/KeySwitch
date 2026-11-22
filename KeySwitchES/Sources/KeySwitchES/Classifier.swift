import Foundation

/// Two Latin-script languages. The letters on their QWERTY layouts mostly coincide.
enum Lang: String, CaseIterable, Codable {
    case en, es
    var other: Lang { self == .en ? .es : .en }
    var label: String { self == .es ? "ES" : "EN" }
}

/// Conservative thresholds for English/Spanish frequency comparison.
enum Thresholds {
    static let freqMargin: Float = 2.0      // both readings are real words: other must be 100x more frequent
    static let ngramMargin: Float = 0.6     // only used when the physical keys produce different text
    static let ngramFloor: Float = -3.3     // the other reading must look at least this "word-like"
    static let minNgramLength = 3
    static let customScore: Float = 6.0     // words from custom_*.txt
    static let learnedScore: Float = 7.5    // words learned from your corrections
}

func normalizeWord(_ s: String) -> String {
    s.lowercased().precomposedStringWithCanonicalMapping
}

/// Dictionary + character trigram model for one language.
final class LanguageModel {
    let lang: Lang
    let letters: Set<Character>
    let wordChars: Set<Character>
    private(set) var words: [String: Float] = [:]
    private var tri: [String: Float] = [:]
    private var ctx: [String: Float] = [:]
    private let vocabSize: Float

    init(lang: Lang) {
        self.lang = lang
        switch lang {
        case .en:
            letters = Set("abcdefghijklmnopqrstuvwxyz")
            wordChars = letters.union(["-", "'"])
        case .es:
            letters = Set("abcdefghijklmnñopqrstuvwxyzáéíóúü")
            wordChars = letters.union(["-"])
        }
        vocabSize = Float(wordChars.count + 1)
    }

    /// `word<TAB>score` lines, score = log10(per-billion frequency).
    func loadFrequencyList(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var dict = [String: Float](minimumCapacity: 90_000)
        text.enumerateLines { line, _ in
            guard let tab = line.firstIndex(of: "\t") else { return }
            let w = String(line[..<tab])
            let s = Float(line[line.index(after: tab)...]) ?? 0
            dict[w] = s
        }
        for (w, s) in dict { words[w] = max(words[w] ?? 0, s) }
    }

    /// Plain word lists: whitespace separated, lines starting with # are comments.
    func loadWordList(_ url: URL, score: Float) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        text.enumerateLines { line, _ in
            if line.hasPrefix("#") { return }
            for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }) {
                self.add(String(raw), score: score)
            }
        }
    }

    func add(_ raw: String, score: Float) {
        let w = normalizeWord(raw)
        guard isWord(w) else { return }
        words[w] = max(words[w] ?? 0, score)
    }

    func trainNgrams() {
        var tri = [String: Float](minimumCapacity: 300_000)
        var ctx = [String: Float](minimumCapacity: 40_000)
        for (w, s) in words {
            let t = Array("^^" + w + "$")
            for i in 2..<t.count {
                tri[String(t[(i - 2)...i]), default: 0] += s
                ctx[String(t[(i - 2)..<i]), default: 0] += s
            }
        }
        self.tri = tri
        self.ctx = ctx
    }

    func ngramScore(_ w: String) -> Float {
        let t = Array("^^" + w + "$")
        var lp: Float = 0
        var n: Float = 0
        for i in 2..<t.count {
            let g = tri[String(t[(i - 2)...i])] ?? 0
            let c = ctx[String(t[(i - 2)..<i])] ?? 0
            lp += log10f((g + 0.1) / (c + 0.1 * vocabSize))
            n += 1
        }
        return lp / n
    }

    func score(_ w: String) -> Float? { words[w] }

    func isWord(_ w: String) -> Bool {
        !w.isEmpty && w.allSatisfy { wordChars.contains($0) } && w.contains { letters.contains($0) }
    }

    /// Strips leading/trailing characters that are not letters of this language ("hello," -> "hello").
    func core(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, !letters.contains(f) { chars.removeFirst() }
        while let l = chars.last, !letters.contains(l) { chars.removeLast() }
        return String(chars)
    }
}

struct Decision {
    let convert: Bool
    let reason: String
    let confident: Bool

    init(convert: Bool, reason: String, confident: Bool = true) {
        self.convert = convert
        self.reason = reason
        self.confident = confident
    }
}

struct CorrectionPlan {
    let prefix: String
    let currentWord: String
    let alternativeWord: String
    let suffix: String
    let decision: Decision

    init(prefix: String = "", currentWord: String, alternativeWord: String, suffix: String, decision: Decision) {
        self.prefix = prefix
        self.currentWord = currentWord
        self.alternativeWord = alternativeWord
        self.suffix = suffix
        self.decision = decision
    }
}

final class Classifier {
    let models: [Lang: LanguageModel]

    init(models: [Lang: LanguageModel]) { self.models = models }

    /// Loads bundled dictionaries + your editable custom lists + learned words.
    static func load(dictionaryDir: URL, userDir: URL?, learned: [Lang: [String]]) throws -> Classifier {
        var models: [Lang: LanguageModel] = [:]
        for lang in Lang.allCases {
            let m = LanguageModel(lang: lang)
            try m.loadFrequencyList(dictionaryDir.appendingPathComponent("\(lang.rawValue).tsv"))
            m.loadWordList(dictionaryDir.appendingPathComponent("custom_\(lang.rawValue).txt"), score: Thresholds.customScore)
            if let userDir {
                m.loadWordList(userDir.appendingPathComponent("my_\(lang.rawValue).txt"), score: Thresholds.customScore)
            }
            for w in learned[lang] ?? [] { m.add(w, score: Thresholds.learnedScore) }
            m.trainNgrams()
            models[lang] = m
        }
        return Classifier(models: models)
    }

    func learn(_ word: String, lang: Lang) {
        models[lang]?.add(word, score: Thresholds.learnedScore)
    }

    /// `current`: the word as the active layout produced it. `alternative`: same keys in the other layout.
    func decide(current: String, alternative: String, currentLang: Lang, contextLang: Lang? = nil) -> Decision {
        guard let cur = models[currentLang], let oth = models[currentLang.other] else {
            return Decision(convert: false, reason: "no-model")
        }
        let wc = cur.core(normalizeWord(current))
        let wo = oth.core(normalizeWord(alternative))
        // Pure punctuation ("...", ",") or tokens like URLs: never touch.
        guard !wc.isEmpty || current.contains(where: { $0.isLetter }) else {
            return Decision(convert: false, reason: "no-letters")
        }
        guard oth.isWord(wo) else { return Decision(convert: false, reason: "other-not-alpha") }

        var freqMargin = Thresholds.freqMargin
        var ngramMargin = Thresholds.ngramMargin
        if contextLang == oth.lang { freqMargin -= 1.0; ngramMargin -= 0.2 }

        let curOK = cur.isWord(wc)
        let sc = curOK ? cur.score(wc) : nil
        let so = oth.score(wo)

        switch (sc, so) {
        case (.some, .none):
            return Decision(convert: false, reason: "cur-dict")
        case (.none, .some):
            if wo.count == 1 && contextLang != oth.lang {
                return Decision(convert: false, reason: "single-letter")
            }
            return Decision(convert: true, reason: "other-dict")
        case let (.some(c), .some(o)):
            return Decision(convert: o - c >= freqMargin, reason: o - c >= freqMargin ? "freq" : "both-dict")
        case (.none, .none):
            // English and Spanish share most letter keys. Unknown Latin words
            // are too ambiguous for an automatic layout switch.
            if wc == wo { return Decision(convert: false, reason: "unknown-same-keys") }
            guard wo.count >= Thresholds.minNgramLength else {
                return Decision(convert: false, reason: "short")
            }
            let ngo = oth.ngramScore(wo)
            let ngc: Float = curOK ? cur.ngramScore(wc) : -9
            let gap = ngo - ngc
            if ngo > Thresholds.ngramFloor && gap >= ngramMargin {
                return Decision(convert: true, reason: "ngram")
            }
            return Decision(convert: false, reason: "ngram-no")
        }
    }

    /// A punctuation key can be a letter in the other layout ('.' -> 'ю').
    /// At a word boundary, keep a trailing punctuation run when the preceding
    /// reading is a known correction and the full alternative is not a word.
    func plan(current: String, alternative: String, currentLang: Lang) -> CorrectionPlan {
        let full = decide(current: current, alternative: alternative, currentLang: currentLang)
        let currentChars = Array(current)
        let alternativeChars = Array(alternative)
        guard currentChars.count == alternativeChars.count else {
            return CorrectionPlan(currentWord: current, alternativeWord: alternative, suffix: "", decision: full)
        }
        var split = currentChars.count
        while split > 0 {
            let ch = currentChars[split - 1]
            let alt = alternativeChars[split - 1]
            guard !ch.isLetter, !ch.isNumber, !ch.isWhitespace,
                  ch != "-", ch != "'", alt.isLetter else { break }
            split -= 1
        }
        guard split > 0, split < currentChars.count else {
            return CorrectionPlan(currentWord: current, alternativeWord: alternative, suffix: "", decision: full)
        }
        let prefix = String(currentChars[..<split])
        let altPrefix = String(alternativeChars[..<split])
        let prefixDecision = decide(current: prefix, alternative: altPrefix, currentLang: currentLang)
        let fullAlt = models[currentLang.other]?.core(normalizeWord(alternative)) ?? ""
        if prefixDecision.convert && models[currentLang.other]?.score(fullAlt) == nil {
            return CorrectionPlan(currentWord: prefix, alternativeWord: altPrefix,
                                  suffix: String(currentChars[split...]), decision: prefixDecision)
        }
        return CorrectionPlan(currentWord: current, alternativeWord: alternative, suffix: "", decision: full)
    }

    /// A short previous word ("z" before "ghbdtn") is converted together with the next one
    /// if its other reading is a real word and the typed reading is not (or much rarer).
    func shouldRetroFix(current: String, alternative: String, currentLang: Lang) -> Bool {
        guard let cur = models[currentLang], let oth = models[currentLang.other] else { return false }
        let wc = cur.core(normalizeWord(current))
        let wo = oth.core(normalizeWord(alternative))
        guard oth.isWord(wo), let so = oth.score(wo) else { return false }
        if let sc = cur.isWord(wc) ? cur.score(wc) : nil { return so - sc >= 1.0 }
        return true
    }
}
