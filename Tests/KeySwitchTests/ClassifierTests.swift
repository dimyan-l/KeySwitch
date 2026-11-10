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
        XCTAssertNil(SpellCorrector.correction(for: "Превет", alternative: "", model: ru, other: en))
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
}
