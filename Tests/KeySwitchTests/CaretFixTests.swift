import XCTest
@testable import KeySwitch

final class CaretFixTests: XCTestCase {
    private let extra: Set<Character> = [",", ".", ";", "[", "]", "`"]

    private func classifier() throws -> Classifier {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Classifier.load(dictionaryDir: root.appendingPathComponent("Resources/Dictionaries"),
                                   userDir: nil, learned: [:])
    }

    private func flip(_ text: String) -> String {
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return SelfTest.flip(text, to: cyrillic ? .en : .ru)
    }

    func testWrongLayoutWordIncludesPunctuationKeys() {
        // "hf,jnf" is "работа": the comma is the key of "б".
        let text = "z hf,jnf ult"
        for caret in [2, 4, 5, 8] {
            XCTAssertEqual(CaretWordRange.find(in: text, caretUTF16: caret, extra: extra)?.word, "hf,jnf")
        }
        XCTAssertEqual(CaretWordRange.find(in: "ghbdtn, rfr", caretUTF16: 7, extra: extra)?.word, "ghbdtn,")
        XCTAssertEqual(CaretWordRange.find(in: "z ult", caretUTF16: 1, extra: extra)?.word, "z")
    }

    func testCyrillicWordNeverAbsorbsPunctuation() {
        XCTAssertEqual(CaretWordRange.find(in: "привет, мир", caretUTF16: 6, extra: extra)?.word, "привет")
        XCTAssertNil(CaretWordRange.find(in: "привет, мир", caretUTF16: 7, extra: extra))
    }

    func testMissedWordIsFlippedAtOnce() throws {
        let c = try classifier()
        let plan = try XCTUnwrap(CaretFix.plan(token: "ghbdtn", classifier: c, flip: flip))
        XCTAssertEqual(plan.choices, ["привет"])
        XCTAssertEqual(plan.target, .ru)
        XCTAssertTrue(plan.learnFlip)

        let back = try XCTUnwrap(CaretFix.plan(token: "руддщ", classifier: c, flip: flip))
        XCTAssertEqual(back.choices, ["hello"])
        XCTAssertEqual(back.target, .en)
    }

    func testPunctuationIsLetterOnlyWhenTheWordNeedsIt() throws {
        let c = try classifier()
        let inner = try XCTUnwrap(CaretFix.plan(token: "hf,jnf", classifier: c, flip: flip))
        XCTAssertEqual(inner.choices, ["работа"])
        XCTAssertEqual([inner.dropFirst, inner.dropLast], [0, 0])

        let edge = try XCTUnwrap(CaretFix.plan(token: "k.,k.", classifier: c, flip: flip))
        XCTAssertEqual(edge.choices, ["люблю"])
        XCTAssertEqual(edge.dropLast, 0)

        let comma = try XCTUnwrap(CaretFix.plan(token: "ghbdtn,", classifier: c, flip: flip))
        XCTAssertEqual(comma.word, "ghbdtn")
        XCTAssertEqual(comma.choices, ["привет"])
        XCTAssertEqual(comma.dropLast, 1)
    }

    func testKnownWordFlipsBackButIsNotLearned() throws {
        let plan = try XCTUnwrap(CaretFix.plan(token: "привет", classifier: try classifier(), flip: flip))
        XCTAssertEqual(plan.choices, ["ghbdtn"])
        XCTAssertFalse(plan.learnFlip)
    }

    func testTypoOffersSpellingBeforeFlip() throws {
        let plan = try XCTUnwrap(CaretFix.plan(token: "замеаю", classifier: try classifier(), flip: flip))
        XCTAssertEqual(plan.choices.first, "замечаю")
        XCTAssertEqual(plan.choices.last, flip("замеаю"))
    }

    func testWorksWithoutDictionaries() throws {
        let plan = try XCTUnwrap(CaretFix.plan(token: "ghbdtn,", classifier: nil, flip: flip))
        XCTAssertEqual(plan.word, "ghbdtn")
        XCTAssertEqual(plan.choices, ["привет"])
        XCTAssertNil(CaretFix.plan(token: "...", classifier: nil, flip: flip))
    }

    func testCrookedWrongLayoutWordSuggestsRightSpellingAndKeepsNgramPrefix() throws {
        let c = try classifier()
        // "ghbdnt" -> "привте" -> replaced at once with "привет"
        let crooked = try XCTUnwrap(CaretFix.plan(token: "ghbdnt", classifier: c, flip: flip))
        XCTAssertEqual(crooked.choices, ["привет"])

        // "[jnabrc" -> "хотфикс" (non-dict word starting with '[')
        let bracketed = try XCTUnwrap(CaretFix.plan(token: "[jnabrc", classifier: c, flip: flip))
        XCTAssertEqual(bracketed.word, "[jnabrc")
        XCTAssertEqual(bracketed.choices.first, "хотфикс")
        XCTAssertEqual(bracketed.dropFirst, 0)
    }

    func testKnownWordIsNeverFlippedIntoPunctuation() throws {
        // "беги" in the other layout is ",tub": that is never what the user wants.
        XCTAssertNil(CaretFix.plan(token: "беги", classifier: try classifier(), flip: flip))
        // A known word whose flip is letters still toggles.
        XCTAssertEqual(try XCTUnwrap(CaretFix.plan(token: "привет", classifier: try classifier(), flip: flip)).choices,
                       ["ghbdtn"])
    }

    func testCaretFixLearnsRareDictionaryCollisionAndRemembersNextTime() throws {
        let c = try classifier()
        // Before manual caret fix, "ns" ("ты") is held back by cautiousMode because "ns" is in en.tsv.
        XCTAssertFalse(c.decide(current: "ns", alternative: "ты", currentLang: .en).confident)

        let plan = try XCTUnwrap(CaretFix.plan(token: "ns", classifier: c, flip: flip))
        XCTAssertEqual(plan.choices, ["ты"])
        XCTAssertTrue(plan.learnFlip, "Rare dictionary junk should still allow learning the user's intended flip")

        c.learn("ты", lang: .ru)
        let afterLearn = c.decide(current: "ns", alternative: "ты", currentLang: .en)
        XCTAssertTrue(afterLearn.convert && afterLearn.confident,
                      "Once learned from a caret fix, the word must auto-switch even in cautiousMode")

        // Accidental flip of a rare real word into unpronounceable gibberish must NOT set learnFlip.
        let accidental = try XCTUnwrap(CaretFix.plan(token: "трос", classifier: c, flip: flip))
        XCTAssertFalse(accidental.learnFlip, "Gibberish 'nhjc' must not be learned when flipping a rare real word")
    }
}
