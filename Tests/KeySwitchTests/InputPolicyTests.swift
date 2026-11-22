import XCTest
@testable import KeySwitch

final class InputPolicyTests: XCTestCase {
    func testSubmitAndFocusChangingKeysNeverTriggerAutomaticSpelling() {
        for key: UInt16 in [36, 76, 48] {
            XCTAssertFalse(InputPolicy.allowsAutomaticSpelling(terminator: key))
        }
        for key: UInt16 in [49, 43, 47] {
            XCTAssertTrue(InputPolicy.allowsAutomaticSpelling(terminator: key))
        }
    }

    func testEmbeddedDotExceptionRequiresKnownWholeCyrillicReading() {
        for (alternative, suffix, convert, reason) in [
            ("компьютер", "", true, "ngram"),
            ("компьютер", ".com", true, "other-dict"),
            ("computer", "", true, "other-dict"),
            ("компьютер", "", false, "current-dict"),
            ("", "", true, "other-dict"),
        ] {
            let plan = CorrectionPlan(currentWord: "object.method", alternativeWord: alternative,
                                      suffix: suffix, decision: Decision(convert: convert, reason: reason))
            XCTAssertTrue(InputPolicy.blocksAutomaticCorrection("object.method", plan: plan))
        }
    }

    func testRussianYuKeyIsNotMistakenForDomainWhenWholeReadingIsKnown() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let classifier = try Classifier.load(dictionaryDir: root.appendingPathComponent("Resources/Dictionaries"),
                                             userDir: nil, learned: [:])
        for (typed, alternative) in [("k.lb", "люди"), ("rjvgm.nth", "компьютер")] {
            let plan = classifier.plan(current: typed, alternative: alternative, currentLang: .en)
            XCTAssertTrue(plan.decision.convert)
            XCTAssertFalse(InputPolicy.blocksAutomaticCorrection(typed, plan: plan), typed)
        }
        for typed in ["example.com", "object.method", "main.py", "app.swift"] {
            let plan = classifier.plan(current: typed, alternative: SelfTest.flip(typed, to: .ru), currentLang: .en)
            XCTAssertTrue(InputPolicy.blocksAutomaticCorrection(typed, plan: plan), typed)
        }
        // Known word with trailing sentence punctuation and inflected Cyrillic words with 'ю' ('.')
        for (typed, expected) in [
            ("rjvgm.nth.", "компьютер."),
            ("k.lb,", "люди,"),
            ("gjlrk.xbkb", "подключили"),
            ("gjlrk.xf.cm", "подключаюсь"),
            ("rjvgm.nthf", "компьютера"),
        ] {
            let plan = classifier.plan(current: typed, alternative: SelfTest.flip(typed, to: .ru), currentLang: .en)
            XCTAssertTrue(plan.decision.convert, typed)
            XCTAssertFalse(InputPolicy.blocksAutomaticCorrection(typed, plan: plan), typed)
            XCTAssertEqual(plan.prefix + plan.alternativeWord + plan.suffix, expected, typed)
        }
    }

    func testKnownDomainSuffixOutranksDictionaryEvidenceForTheOtherLayout() {
        let plan = CorrectionPlan(currentWord: "example.com", alternativeWord: "известный", suffix: "",
                                  decision: Decision(convert: true, reason: "other-dict"))
        XCTAssertTrue(InputPolicy.blocksAutomaticCorrection("example.com", plan: plan))
        XCTAssertTrue(InputPolicy.blocksAutomaticCorrection("example.com.", plan: plan))
    }

    func testAddressesAndCodeTokensStayUntouched() {
        for character in ["@", ":", "/", "\\", "_", "#", "=", "3", "+", "&", "%"] {
            XCTAssertTrue(InputPolicy.beginsStructuredToken(character), character)
        }
        XCTAssertTrue(InputPolicy.containsEmbeddedDot("example.com"))
        XCTAssertTrue(InputPolicy.containsEmbeddedDot("object.method"))
        XCTAssertFalse(InputPolicy.containsEmbeddedDot("ghbdtn."))
        XCTAssertFalse(InputPolicy.containsEmbeddedDot("ghbdtn..."))
        XCTAssertFalse(InputPolicy.beginsStructuredToken("."))
    }
}
