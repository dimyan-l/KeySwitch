import Foundation

/// Two languages we care about.
enum Lang: String, CaseIterable, Codable {
    case ru, en
    var other: Lang { self == .ru ? .en : .ru }
    var label: String { self == .ru ? "RU" : "EN" }
}

/// Thresholds calibrated on frequency lists (see proto/classifier.py):
/// ~0.0–0.2% false conversions, 92–99% of wrong-layout words fixed.
enum Thresholds {
    static let freqMargin: Float = 2.0      // both readings are real words: other must be 100x more frequent
    static let ngramMargin: Float = 0.6     // neither reading is in a dictionary: avg log-prob gap per char
    static let ngramFloor: Float = -3.3     // the other reading must look at least this "word-like"
    static let minNgramLength = 3
    static let customScore: Float = 6.0     // words from custom_*.txt
    static let learnedScore: Float = 7.5    // words learned from your corrections
    static let uncertainBand: Float = 0.4   // gaps this close to the margin: too close to call, no typo fix either
    /// Switching mid-word, after `earlyLength` letters: the typed start begins no word of its language, and the
    /// other reading begins words with this much frequency mass (log10 of summed per-billion frequency).
    /// Calibrated on the dictionaries: 0.01–0.02% false switches on rare unseen words, 0.04–0.15% on typos in
    /// the first letters; 56% (RU) and 79% (EN) of longer wrong-layout words switch before they end.
    static let earlyLength = 4
    static let earlyMass: Float = 5.0
    /// The previous word was in the language you are typing in now: ask for more before switching away from it.
    static let earlyMassSameContext: Float = 5.5
}

func normalizeWord(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: "ё", with: "е")
}

/// Dictionary + character trigram model for one language.
final class LanguageModel {
    let lang: Lang
    let letters: Set<Character>
    let wordChars: Set<Character>
    private(set) var words: [String: Float] = [:]
    private var tri: [String: Float] = [:]
    /// First `Thresholds.earlyLength` letters → summed frequency of the words starting with them (linear units).
    private(set) var prefixMass: [String: Float] = [:]
    private var ctx: [String: Float] = [:]
    private let vocabSize: Float

    init(lang: Lang) {
        self.lang = lang
        switch lang {
        case .ru:
            letters = Set("абвгдежзийклмнопрстуфхцчшщъыьэюя")
            wordChars = letters.union(["-"])
        case .en:
            letters = Set("abcdefghijklmnopqrstuvwxyz")
            wordChars = letters.union(["-", "'"])
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
        let had = words[w]
        words[w] = max(had ?? 0, score)
        if had == nil { addPrefix(w, score: score) } // later additions (learned words) also count as word starts
    }

    private func addPrefix(_ w: String, score: Float) {
        guard w.count >= Thresholds.earlyLength else { return }
        prefixMass[String(w.prefix(Thresholds.earlyLength)), default: 0] += powf(10, score)
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
        prefixMass = [:]
        for (w, s) in words { addPrefix(w, score: s) }
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
    /// Neither reading is known and the call was close: no typo fix is attempted on such a word.
    let uncertain: Bool
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
            return Decision(convert: false, reason: "no-model", uncertain: false)
        }
        let wc = cur.core(normalizeWord(current))
        let wo = oth.core(normalizeWord(alternative))
        // Pure punctuation ("...", ",") or tokens like URLs: never touch.
        guard !wc.isEmpty || current.contains(where: { $0.isLetter }) else {
            return Decision(convert: false, reason: "no-letters", uncertain: false)
        }
        guard oth.isWord(wo) else { return Decision(convert: false, reason: "other-not-alpha", uncertain: false) }

        var freqMargin = Thresholds.freqMargin
        var ngramMargin = Thresholds.ngramMargin
        if contextLang == oth.lang { freqMargin -= 1.0; ngramMargin -= 0.2 }

        let curOK = cur.isWord(wc)
        let sc = curOK ? cur.score(wc) : nil
        let so = oth.score(wo)

        switch (sc, so) {
        case (.some, .none):
            return Decision(convert: false, reason: "cur-dict", uncertain: false)
        case (.none, .some):
            if wo.count == 1 && contextLang != oth.lang {
                return Decision(convert: false, reason: "single-letter", uncertain: false)
            }
            return Decision(convert: true, reason: "other-dict", uncertain: false)
        case let (.some(c), .some(o)):
            return Decision(convert: o - c >= freqMargin, reason: o - c >= freqMargin ? "freq" : "both-dict", uncertain: false)
        case (.none, .none):
            guard wo.count >= Thresholds.minNgramLength else {
                return Decision(convert: false, reason: "short", uncertain: false)
            }
            let ngo = oth.ngramScore(wo)
            let ngc: Float = curOK ? cur.ngramScore(wc) : -9
            let gap = ngo - ngc
            let close = abs(gap - ngramMargin) < Thresholds.uncertainBand
            if ngo > Thresholds.ngramFloor && gap >= ngramMargin {
                return Decision(convert: true, reason: "ngram", uncertain: close)
            }
            return Decision(convert: false, reason: "ngram-no", uncertain: close && curOK)
        }
    }

    /// Mid-word: the first letters typed in the current layout begin no known word, and in the other layout
    /// they begin common words. Then the layout is switched right away and the rest of the word comes out right.
    func shouldSwitchEarly(current: String, alternative: String, currentLang: Lang, contextLang: Lang?) -> Bool {
        guard let cur = models[currentLang], let oth = models[currentLang.other] else { return false }
        let pc = normalizeWord(current), po = normalizeWord(alternative)
        guard pc.count == Thresholds.earlyLength, po.count == Thresholds.earlyLength,
              po.allSatisfy({ oth.letters.contains($0) }) else { return false }
        if cur.prefixMass[pc] != nil { return false }
        guard let mass = oth.prefixMass[po] else { return false }
        let need = contextLang == currentLang ? Thresholds.earlyMassSameContext : Thresholds.earlyMass
        return log10f(mass) >= need
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
