import XCTest
@testable import KeySwitch

final class SecureInputTests: XCTestCase {
    func testOnlySecureInputTransitionsInvalidateContext() {
        var state = SecureInputState()
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.observe(false), "Idle polling must preserve layout correction undo")
        XCTAssertTrue(state.observe(true), "Entering secure input must invalidate stale context")
        XCTAssertTrue(state.isEnabled)
        XCTAssertFalse(state.observe(true), "Repeated secure polls must not keep resetting context")
        XCTAssertTrue(state.observe(false), "Leaving secure input must discard the unobserved typing gap")
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.observe(false), "Status updates after exit must preserve fresh context")
    }
}
