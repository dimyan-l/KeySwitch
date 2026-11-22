import Foundation

enum AutomaticCorrection {
    struct Spelling {
        let text: String
        let word: String
        let kind: FixKind
    }

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
            guard let fixed = SpellCorrector.correction(for: word, alternative: altWord, model: model, other: other) else {
                return nil
            }
            spelling = (fixed, .spell)
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
