import XCTest
@testable import KeySwitchES

final class ClassifierTests: XCTestCase {
    func testCaretWordIncludesDecomposedAccent() {
        let word = "cafe\u{301}"
        XCTAssertEqual(CaretWordRange.find(in: word, caretUTF16: word.utf16.count)?.word, word)
    }

    private func classifier() throws -> Classifier {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Classifier.load(dictionaryDir: root.appendingPathComponent("Resources/Dictionaries"),
                                   userDir: nil, learned: [:])
    }

    func testSpanishWordSwitchesLayoutWithoutChangingLetters() throws {
        let plan = try classifier().plan(current: "gracias", alternative: "gracias", currentLang: .en)
        XCTAssertTrue(plan.decision.convert)
        XCTAssertEqual(plan.alternativeWord + plan.suffix, "gracias")
        XCTAssertTrue(plan.decision.confident, "The default cautious mode must switch for a clear shared-key word")
        let english = try classifier().decide(current: "hello", alternative: "hello", currentLang: .es)
        XCTAssertTrue(english.convert && english.confident)
    }

    func testDifferentCharacterIsCorrected() throws {
        let plan = try classifier().plan(current: "ni;o", alternative: "niño", currentLang: .en)
        XCTAssertTrue(plan.decision.convert)
        XCTAssertEqual(plan.alternativeWord + plan.suffix, "niño")
    }

    func testLayoutCorrectionPreservesPunctuationAtBothEnds() throws {
        let c = try classifier()
        let plan = c.plan(current: "(ni;o?", alternative: ")niño_", currentLang: .en)
        XCTAssertTrue(plan.decision.convert && plan.decision.confident)
        XCTAssertEqual(plan.prefix + plan.alternativeWord + plan.suffix, "(niño?")
        let shared = c.plan(current: "gracias?", alternative: "gracias_", currentLang: .en)
        XCTAssertTrue(shared.decision.convert && shared.decision.confident)
        XCTAssertEqual(shared.prefix + shared.alternativeWord + shared.suffix, "gracias?")
        XCTAssertFalse(c.plan(current: "?!", alternative: "_!", currentLang: .en).decision.convert)
    }

    func testUnknownSharedLetterKeysDoNotTriggerSwitch() throws {
        let plan = try classifier().plan(current: "foobarqux", alternative: "foobarqux", currentLang: .en)
        XCTAssertFalse(plan.decision.convert)
    }

    func testConservativeSpellingCorrection() throws {
        let c = try classifier()
        let es = try XCTUnwrap(c.models[.es])
        let en = try XCTUnwrap(c.models[.en])
        XCTAssertFalse(c.plan(current: "gracais", alternative: "gracais", currentLang: .es).decision.convert)
        XCTAssertEqual(SpellCorrector.correction(for: "gracais", alternative: "gracais", model: es, other: en), "gracias")
        XCTAssertEqual(SpellCorrector.correction(for: "recieve", alternative: "recieve", model: en, other: es), "receive")
        XCTAssertNil(SpellCorrector.correction(for: "gracias", alternative: "gracias", model: es, other: en))
    }

    func testImportedEnglishRulesAndSpanishRulesAreSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"learned":{"en":["hello"]},"rules":[
          {"word":"hello","lang":"en","kind":"layout","result":"руддщ","source":"undo","modified":700000000,"deleted":false}
        ]}
        """
        try json.write(to: directory.appendingPathComponent("learned.json"), atomically: true, encoding: .utf8)
        let store = UserStore(directory: directory)
        XCTAssertEqual(store.learned[.en], ["hello"])
        XCTAssertTrue(store.rules.blocks("hello", lang: .en, kind: .layout))
        XCTAssertFalse(store.rules.blocks("hello", lang: .en, kind: .spell))
        XCTAssertFalse(store.rules.blocks("hello", lang: .es, kind: .layout))
    }

    func testRuleScopesAndDeletedRules() {
        var rules = RuleBook()
        let rule = rules.add("gracais", lang: .es, kind: .spell, result: "gracias", source: .manual)
        XCTAssertTrue(rules.blocks("gracais", lang: .es, kind: .spell))
        XCTAssertFalse(rules.blocks("gracais", lang: .es, kind: .layout))
        XCTAssertFalse(rules.blocks("gracais", lang: .en, kind: .spell))
        rules.remove(rule.id)
        rules.merge(rule)
        XCTAssertFalse(rules.blocks("gracais", lang: .es, kind: .spell))
        _ = rules.add("gracais", lang: .es, kind: nil, result: nil, source: .manual)
        XCTAssertTrue(rules.blocks("gracais", lang: .es, kind: .layout))
        XCTAssertTrue(rules.blocks("gracais", lang: .es, kind: .spell))
    }

    func testBundledEnglishRulesSeedOnceAndStayDeleted() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = root.appendingPathComponent("Resources/DefaultRules.json")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = UserStore(directory: directory, bundledRulesURL: bundled)
        XCTAssertEqual(first.rules.active.count, 2)
        XCTAssertTrue(first.rules.active.allSatisfy { $0.lang == .en })
        first.flushPendingWrites()
        let second = UserStore(directory: directory, bundledRulesURL: bundled)
        XCTAssertEqual(second.rules.active.count, 2)
        let id = try XCTUnwrap(second.rules.active.first?.id)
        second.removeRule(id)
        second.flushPendingWrites()
        let third = UserStore(directory: directory, bundledRulesURL: bundled)
        XCTAssertEqual(third.rules.active.count, 1)
        XCTAssertTrue(third.rules.byKey[id]?.deleted == true)
    }
}
