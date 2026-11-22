import Foundation

/// Decides how to fix a missed word when the user returns to it and taps right ⌥.
/// Pure logic: no Accessibility, no keyboard events.
enum CaretFix {
    struct Plan {
        /// Characters of the captured token that stay untouched (punctuation around the word).
        let dropFirst: Int
        let dropLast: Int
        let word: String
        /// Replacements, best first. One choice is applied at once; several are offered.
        let choices: [String]
        /// The other-layout reading and its language.
        let flip: String
        let target: Lang
        /// The typed reading is not a known word, so a chosen flip is worth learning.
        let learnFlip: Bool
    }

    /// `token`: the word at the caret, possibly with punctuation that types letters in the
    /// other layout ("ghbdtn," or "k.,k."). `flip` re-reads text in the other layout.
    static func plan(token: String, classifier: Classifier?,
                     mixed: (String) -> (text: String, language: Lang)? = { _ in nil },
                     flip: (String) -> String) -> Plan? {
        let chars = Array(token)
        guard chars.contains(where: \.isLetter) else { return nil }
        let cyrillic = token.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let source: Lang = cyrillic ? .ru : .en
        let target = source.other
        let lead = chars.prefix { !$0.isLetter }.count
        let trail = chars.reversed().prefix { !$0.isLetter }.count
        if cyrillic && chars.contains(where: { $0.isASCII && $0.isLetter }) {
            let word = String(chars[lead..<(chars.count - trail)])
            guard let repaired = mixed(word) else { return nil }
            return Plan(dropFirst: lead, dropLast: trail, word: word, choices: [repaired.text],
                        flip: repaired.text, target: repaired.language, learnFlip: false)
        }

        // Keep edge punctuation inside the word only when that reading is a real word
        // (or a classifier-approved conversion like "[jnabrc" -> "хотфикс"):
        // "k.,k." is "люблю", but the comma of "ghbdtn," stays a comma.
        var cut = (first: lead, last: trail)
        if source == .en, lead + trail > 0 {
            var options: [(first: Int, last: Int)] = []
            for first in 0...lead { for last in 0...trail { options.append((first, last)) } }
            options.sort { ($0.first + $0.last, $0.first) < ($1.first + $1.last, $1.first) }
            if let model = classifier?.models[target],
               let known = options.first(where: {
                   model.score(normalizeWord(flip(String(chars[$0.first..<(chars.count - $0.last)])))) != nil
               }) {
                cut = known
            } else if let classifier,
                      let converted = options.first(where: {
                          let sub = String(chars[$0.first..<(chars.count - $0.last)])
                          let alt = flip(sub)
                          let d = classifier.decide(current: sub, alternative: alt, currentLang: source)
                          return d.convert && d.confident
                      }) {
                cut = converted
            }
        }

        let word = String(chars[cut.first..<(chars.count - cut.last)])
        let flipped = flip(word)
        let sourceModel = classifier?.models[source]
        let known = sourceModel.map { $0.score($0.core(normalizeWord(word))) != nil } ?? false

        var choices: [String] = []
        func add(_ candidate: String) {
            guard candidate != word, !candidate.isEmpty, !choices.contains(candidate) else { return }
            choices.append(candidate)
        }
        if classifier?.decide(current: word, alternative: flipped, currentLang: source).convert == true {
            if let fixed = classifier?.spellingInOtherLayout(current: word, alternative: flipped, currentLang: source) {
                add(fixed)
            } else {
                add(flipped)
            }
        } else {
            if let sourceModel {
                for candidate in SpellCorrector.suggestions(for: word, model: sourceModel, limit: 2) {
                    add(SelectionCandidates.matchCase(candidate, to: word))
                }
            }
            if choices.isEmpty,
               let fixed = classifier?.spellingInOtherLayout(current: word, alternative: flipped, currentLang: source) {
                add(fixed)
            } else {
                // An explicit request always has the layout flip available, so a second tap flips back.
                add(flipped)
            }
        }
        guard !choices.isEmpty else { return nil }
        return Plan(dropFirst: cut.first, dropLast: cut.last, word: word, choices: choices,
                    flip: flipped, target: target, learnFlip: !known)
    }
}
