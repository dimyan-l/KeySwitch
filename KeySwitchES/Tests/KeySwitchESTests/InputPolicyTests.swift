import XCTest
@testable import KeySwitchES

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

    func testAddressesAndCodeTokensStayUntouched() {
        for character in ["@", ":", "/", "\\", "_", "#", "=", "3"] {
            XCTAssertTrue(InputPolicy.beginsStructuredToken(character), character)
        }
        XCTAssertTrue(InputPolicy.containsEmbeddedDot("example.com"))
        XCTAssertTrue(InputPolicy.containsEmbeddedDot("object.method"))
        XCTAssertFalse(InputPolicy.containsEmbeddedDot("ghbdtn."))
        XCTAssertFalse(InputPolicy.containsEmbeddedDot("ghbdtn..."))
        XCTAssertFalse(InputPolicy.beginsStructuredToken("."))
    }
}
