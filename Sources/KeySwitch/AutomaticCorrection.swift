import Foundation

enum AutomaticCorrection {
    struct Spelling {
        let text: String
        let word: String
        let kind: FixKind
    }

    private static let missingHyphens = [
        "почемуто": "почему-то", "чтото": "что-то", "ктото": "кто-то",
        "както": "как-то", "зачемто": "зачем-то", "когдато": "когда-то",
    ]

    static func spelling(current: String, alternative: String, model: LanguageModel,
                         other: LanguageModel?, rules: RuleBook) -> Spelling? {
        let prefix = current.prefix(while: \.isPunctuation)
        let remainder = current.dropFirst(prefix.count)
        let suffixLength = remainder.reversed().prefix(while: \.isPunctuation).count
        let word = String(remainder.dropLast(suffixLength))
        let normalized = normalizeWord(word)
        guard model.isWord(normalized) else { return nil }

        let altWord = alternative.count == current.count
            ? String(alternative.dropFirst(prefix.count).dropLast(suffixLength)) : alternative
        let spelling: (replacement: String, kind: FixKind)
        if hasDoubleCapital(word), (model.score(normalized) ?? 0) >= 4.0,
           !rules.blocks(normalized, lang: model.lang, kind: .caseFix) {
            spelling = (word.prefix(1) + word.dropFirst().lowercased(), .caseFix)
        } else {
            guard !rules.blocks(normalized, lang: model.lang, kind: .spell) else { return nil }
            if model.lang == .ru, let casing = SpellCorrector.Casing(word),
               let fixed = missingHyphens[normalized], model.score(fixed) != nil {
                spelling = (casing.apply(fixed), .spell)
            } else if let fixed = SpellCorrector.correction(for: word, alternative: altWord, model: model, other: other) {
                let reviewed = SpellCorrector.knownMisspellings[model.lang.rawValue]?[normalized] != nil
                // "баги" is a form of "баг", not a typo of "беги": an unknown word whose stem
                // has dictionary forms is a missing inflection, not a slip of the finger.
                guard reviewed || !WordForms.hasKnownSiblings(normalized, model: model) else { return nil }
                spelling = (fixed, .spell)
            } else { return nil }
        }
        return Spelling(text: prefix + spelling.replacement + current.suffix(suffixLength),
                        word: normalized, kind: spelling.kind)
    }

    static func layoutWithSpelling(_ plan: CorrectionPlan, currentLang: Lang,
                                   classifier: Classifier, rules: RuleBook) -> CorrectionPlan? {
        let current = normalizeWord(plan.currentWord)
        let alternative = normalizeWord(plan.alternativeWord)
        guard let source = classifier.models[currentLang], let target = classifier.models[currentLang.other],
              (5...SpellCorrector.maxLength).contains(current.count),
              current.allSatisfy({ source.letters.contains($0) }),
              alternative.allSatisfy({ target.letters.contains($0) }),
              alternative.count == current.count, SpellCorrector.Casing(plan.currentWord) != nil,
              source.score(current) == nil, target.score(alternative) == nil,
              !rules.blocks(current, lang: source.lang, kind: .layout),
              !rules.blocks(current, lang: source.lang, kind: .spell),
              !rules.blocks(alternative, lang: target.lang, kind: .spell) else { return nil }
        let targetLikelihood = target.ngramScore(alternative)
        guard targetLikelihood >= -2.2, targetLikelihood - source.ngramScore(current) >= 0.1,
              let fixed = classifier.spellingInOtherLayout(current: plan.currentWord, alternative: plan.alternativeWord,
                                                           currentLang: currentLang),
              (target.score(normalizeWord(fixed)) ?? 0) >= 4.5 else { return nil }
        return CorrectionPlan(prefix: plan.prefix, currentWord: plan.currentWord, alternativeWord: fixed,
                              suffix: plan.suffix, decision: Decision(convert: true, reason: "other-typo"))
    }

    private static func hasDoubleCapital(_ word: String) -> Bool {
        word.count >= 4 && word.prefix(2).allSatisfy(\.isUppercase) && word.dropFirst(2).allSatisfy(\.isLowercase)
    }
}

/// Russian is inflected: the frequency list holds the common forms of a word, not all of
/// them. A word whose stem appears in the list with two other endings is treated as a
/// real form. Measured on held-out dictionary words: ~58% of valid missing forms are
/// protected, ~8% of random one-letter typos are left alone (mostly ending changes,
/// which are risky to "fix" automatically anyway).
enum WordForms {
    private static let endings: [String] = {
        let list = """
        а я о е ы и у ю ь й ам ям ами ями ах ях ов ев ей ой ом ем ую юю ая яя ое ее ые ие ого его ому ему
        ым им ых их ть ти л ла ло ли ет ют ит ят ешь ишь ете ите ал ял ил ел ала ила ела ться тся ся сь ут ат
        """
        let unique = Set(list.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        return [""] + unique.sorted { $0.count > $1.count }
    }()

    static func hasKnownSiblings(_ word: String, model: LanguageModel) -> Bool {
        guard model.lang == .ru else { return false }
        for ending in endings where ending.isEmpty || word.hasSuffix(ending) {
            let stem = String(word.dropLast(ending.count))
            guard stem.count >= 3 else { continue }
            var found = 0
            for other in endings where other != ending {
                guard let score = model.score(stem + other), score >= 2.5 else { continue }
                found += 1
                if found >= 2 { return true }
            }
        }
        return false
    }
}
