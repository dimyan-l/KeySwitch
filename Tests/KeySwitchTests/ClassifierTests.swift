import XCTest
@testable import KeySwitch

final class ClassifierTests: XCTestCase {
    private func classifier() throws -> Classifier {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Classifier.load(dictionaryDir: root.appendingPathComponent("Resources/Dictionaries"),
                                   userDir: nil, learned: [:])
    }

    func testPunctuationAfterWrongLayoutWordStaysPunctuation() throws {
        let c = try classifier()
        for (typed, alternative, expected) in [
            ("ghbdtn.", "приветю", "привет."),
            ("ghbdtn,", "приветб", "привет,"),
            ("ghbdtn...", "приветююю", "привет..."),
        ] {
            let plan = c.plan(current: typed, alternative: alternative, currentLang: .en)
            XCTAssertTrue(plan.decision.convert)
            XCTAssertEqual(plan.alternativeWord + plan.suffix, expected)
        }
    }

    func testPunctuationKeyInsideWrongLayoutWordRemainsLetter() throws {
        let plan = try classifier().plan(current: "lfnf,fpf", alternative: "датабаза", currentLang: .en)
        XCTAssertTrue(plan.decision.convert)
        XCTAssertEqual(plan.alternativeWord + plan.suffix, "датабаза")
    }

    func testLearnedWordsLoadWithoutPinnedField() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"learned":{"en":["hello"],"ru":["привет"]},"rules":[
          {"word":"hello","lang":"en","kind":"layout","result":"руддщ","source":"undo","modified":700000000,"deleted":false},
          {"word":"привет","lang":"ru","kind":"spell","result":"привёт","source":"restore","modified":700000001,"deleted":false}
        ],"rulesMigrated":true}
        """
        try json.write(to: directory.appendingPathComponent("learned.json"), atomically: true, encoding: .utf8)
        let store = UserStore(directory: directory)
        XCTAssertEqual(store.learned[.en], ["hello"])
        XCTAssertEqual(store.learned[.ru], ["привет"])
        XCTAssertTrue(store.rules.blocks("hello", lang: .en, kind: .layout))
        XCTAssertFalse(store.rules.blocks("hello", lang: .en, kind: .spell))
        XCTAssertTrue(store.rules.blocks("привет", lang: .ru, kind: .spell))
        XCTAssertFalse(store.rules.blocks("привет", lang: .ru, kind: .layout))
    }

    func testRuleScopesAndDeletedRules() {
        var rules = RuleBook()
        let rule = rules.add("Example", lang: .en, kind: .spell, result: "examples", source: .manual)
        XCTAssertTrue(rules.blocks("example", lang: .en, kind: .spell))
        XCTAssertFalse(rules.blocks("example", lang: .en, kind: .layout))
        XCTAssertFalse(rules.blocks("example", lang: .ru, kind: .spell))
        rules.remove(rule.id)
        XCTAssertFalse(rules.blocks("example", lang: .en, kind: .spell))
        rules.merge(rule)
        XCTAssertFalse(rules.blocks("example", lang: .en, kind: .spell))
        _ = rules.add("Example", lang: .en, kind: nil, result: nil, source: .manual)
        XCTAssertTrue(rules.blocks("example", lang: .en, kind: .layout))
        XCTAssertTrue(rules.blocks("example", lang: .en, kind: .spell))
    }

    func testBundledRulesSeedOnceAndStayDeleted() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = root.appendingPathComponent("Resources/DefaultRules.json")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = UserStore(directory: directory, bundledRulesURL: bundled)
        XCTAssertEqual(first.rules.active.count, 15)
        first.flushPendingWrites()
        let second = UserStore(directory: directory, bundledRulesURL: bundled)
        XCTAssertEqual(second.rules.active.count, 15)
        let id = try XCTUnwrap(second.rules.active.first?.id)
        second.removeRule(id)
        second.flushPendingWrites()
        let third = UserStore(directory: directory, bundledRulesURL: bundled)
        XCTAssertEqual(third.rules.active.count, 14)
        XCTAssertTrue(third.rules.byKey[id]?.deleted == true)
    }

    func testConservativeSpellingCorrection() throws {
        let c = try classifier()
        let ru = try XCTUnwrap(c.models[.ru])
        let en = try XCTUnwrap(c.models[.en])
        let wrongLayoutReading = SelfTest.flip("превет", to: .en)
        XCTAssertFalse(c.plan(current: "превет", alternative: wrongLayoutReading, currentLang: .ru).decision.convert)
        XCTAssertEqual(SpellCorrector.correction(for: "превет", alternative: "", model: ru, other: en), "привет")
        XCTAssertEqual(SpellCorrector.correction(for: "recieve", alternative: "", model: en, other: ru), "receive")
        XCTAssertNil(SpellCorrector.correction(for: "привет", alternative: "", model: ru, other: en))
        XCTAssertEqual(SpellCorrector.correction(for: "Превет", alternative: "", model: ru, other: en), "Привет")
        XCTAssertNil(SpellCorrector.correction(for: "ПРЕВЕТ", alternative: "", model: ru, other: en))
    }

    func testCommonTyposAreCorrected() throws {
        let c = try classifier()
        let ru = try XCTUnwrap(c.models[.ru])
        let en = try XCTUnwrap(c.models[.en])
        for (typed, expected) in [("teh", "the"), ("hte", "the"), ("realy", "really"), ("adress", "address"),
                                  ("Thnaks", "Thanks")] {
            XCTAssertEqual(SpellCorrector.correction(for: typed, alternative: "", model: en, other: ru), expected, typed)
        }
        for (typed, expected) in [("здраствуйте", "здравствуйте"), ("спосибо", "спасибо"), ("Сегоня", "Сегодня")] {
            XCTAssertEqual(SpellCorrector.correction(for: typed, alternative: "", model: ru, other: en), expected, typed)
        }
        for word in ["кода", "собака", "щас", "and", "nad", "cat", "код"] {
            let model = word.first!.isASCII ? en : ru
            XCTAssertNil(SpellCorrector.correction(for: word, alternative: "", model: model, other: nil), word)
        }
        XCTAssertTrue(SpellCorrector.areNeighbours("е", "н"))
        XCTAssertFalse(SpellCorrector.areNeighbours("q", "p"))
    }

    func testReportedTyposAndCaretWord() throws {
        let c = try classifier()
        let ru = try XCTUnwrap(c.models[.ru])
        let en = try XCTUnwrap(c.models[.en])
        XCTAssertNil(SpellCorrector.correction(for: "замеаю", alternative: "", model: ru, other: en))
        XCTAssertEqual(Array(SpellCorrector.suggestions(for: "замеаю", model: ru).prefix(2)),
                       ["замечаю", "заменю"])
        XCTAssertEqual(SelectionCandidates.corrections(for: "ghbdtn", classifier: c,
                                                        preferred: .en, flip: "привет"), ["привет"])
        XCTAssertEqual(SpellCorrector.correction(for: "поклодуем", alternative: "", model: ru, other: en),
                       "поколдуем")
        XCTAssertEqual(CaretWordRange.find(in: "вижу замеаю, потом", caretUTF16: 11)?.word, "замеаю")
        XCTAssertEqual(CaretWordRange.find(in: "замеаю потом", caretUTF16: 0)?.word, "замеаю")
        XCTAssertNil(CaretWordRange.find(in: "замеаю  потом", caretUTF16: 7))
        let longWord = String(repeating: "а", count: 40)
        XCTAssertNil(CaretWordRange.find(in: String(longWord.prefix(32)), caretUTF16: 0,
                                          trailingTruncated: true))
        XCTAssertNil(CaretWordRange.find(in: String(longWord.suffix(32)), caretUTF16: 32,
                                          leadingTruncated: true))
    }

    func testConfidentNgramAndWrongLayoutTypos() throws {
        let c = try classifier()
        // Non-dictionary inflected Russian words & slang should be confident n-gram wins.
        for (typed, expected) in [
            ("gjabrcbk", "пофиксил"),
            ("gjlcrf;b", "подскажи"),
            ("j,yjdbkcz", "обновился"),
            ("jngbibntcm", "отпишитесь"),
            ("pfltgkjbkb", "задеплоили"),
            ("pfvth;bk", "замержил"),
            ("[jnabrc", "хотфикс"),
        ] {
            let plan = c.plan(current: typed, alternative: SelfTest.flip(typed, to: .ru), currentLang: .en)
            XCTAssertTrue(plan.decision.convert, typed)
            XCTAssertTrue(plan.decision.confident, "\(typed) should not be held back by cautiousMode")
            XCTAssertEqual(plan.prefix + plan.alternativeWord + plan.suffix, expected, typed)
        }

        // Non-dictionary English words typed in RU should also be confident.
        for (typed, expected) in [
            ("ьшскщыукмшсуы", "microservices"),
            ("куафсещкштп", "refactoring"),
        ] {
            let plan = c.plan(current: typed, alternative: SelfTest.flip(typed, to: .en), currentLang: .ru)
            XCTAssertTrue(plan.decision.convert, typed)
            XCTAssertTrue(plan.decision.confident, typed)
            XCTAssertEqual(plan.alternativeWord, expected, typed)
        }
    }

    func testLeadingAndSurroundingPunctuationAndContext() throws {
        let c = try classifier()
        let quoted = c.plan(current: "\"ghbdtn\"", alternative: "ЭприветЭ", currentLang: .en)
        XCTAssertTrue(quoted.decision.convert)
        XCTAssertEqual(quoted.prefix + quoted.alternativeWord + quoted.suffix, "\"привет\"")

        let openQuoted = c.plan(current: "\"ghbdtn", alternative: "Эпривет", currentLang: .en)
        XCTAssertTrue(openQuoted.decision.convert)
        XCTAssertEqual(openQuoted.prefix + openQuoted.alternativeWord + openQuoted.suffix, "\"привет")

        let goodRussianBracket = c.plan(current: "[jhjij", alternative: "хорошо", currentLang: .en)
        XCTAssertTrue(goodRussianBracket.decision.convert)
        XCTAssertEqual(goodRussianBracket.prefix + goodRussianBracket.alternativeWord + goodRussianBracket.suffix, "хорошо")

        // Previous word leaning RU lowers the threshold for borderline words like "htrhenth" ("рекрутер").
        XCTAssertTrue(c.leansTowardOther(current: "z", alternative: "я", currentLang: .en))
        XCTAssertTrue(c.leansTowardOther(current: "dj", alternative: "во", currentLang: .en))
        let withContext = c.plan(current: "htrhenth", alternative: "рекрутер", currentLang: .en, contextLang: .ru)
        XCTAssertTrue(withContext.decision.convert)
        XCTAssertTrue(c.shouldRetroFix(current: "dj", alternative: "во", currentLang: .en))
    }

    func testAutomaticSpellingCoversMixedLayoutCaseAndPunctuation() throws {
        let c = try classifier()
        let typo = c.plan(current: "ghbdnt", alternative: "привте", currentLang: .en)
        var rules = RuleBook()
        XCTAssertEqual(AutomaticCorrection.layoutWithSpelling(typo, currentLang: .en, classifier: c,
                                                                rules: rules)?.alternativeWord, "привет")
        _ = rules.add("ghbdnt", lang: .en, kind: .layout, result: nil, source: .manual)
        XCTAssertNil(AutomaticCorrection.layoutWithSpelling(typo, currentLang: .en, classifier: c, rules: rules))

        let ru = try XCTUnwrap(c.models[.ru])
        let en = try XCTUnwrap(c.models[.en])
        let capital = AutomaticCorrection.spelling(current: "ПРивет", alternative: "GHbdtn", model: ru, other: en, rules: rules)
        XCTAssertEqual(capital?.text, "Привет")
        XCTAssertEqual(capital?.kind, .caseFix)
        XCTAssertEqual(AutomaticCorrection.spelling(current: "почемуто", alternative: "", model: ru, other: en,
                                                     rules: rules)?.text, "почему-то")
        XCTAssertEqual(AutomaticCorrection.spelling(current: "recieve.", alternative: "кусшумую", model: en, other: ru,
                                                     rules: rules)?.text, "receive.")
        XCTAssertNil(AutomaticCorrection.spelling(current: "GitHub", alternative: "", model: en, other: ru, rules: rules))
        XCTAssertNil(AutomaticCorrection.spelling(current: "some.name", alternative: "", model: en, other: ru, rules: rules))
    }
}

