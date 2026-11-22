import XCTest
@testable import KeySwitchES

final class InputSourceContextTests: XCTestCase {
    func testSuccessfulOwnSelectionPreservesUndoAcrossNotificationAndTimer() {
        var context = InputSourceContext()
        XCTAssertFalse(context.observe("en"))
        context.recordSelection("other")
        XCTAssertFalse(context.observe("other"), "Own selection must preserve correction undo")
        XCTAssertFalse(context.observe("other"), "Delayed duplicate must also preserve undo")
        XCTAssertTrue(context.observe("en"), "Own selection must not suppress a later external return")
    }

    func testExternalSourceChangeInvalidatesIdleContextOnlyOnce() {
        var context = InputSourceContext()
        XCTAssertFalse(context.observe("en"), "Initial observation establishes the baseline")
        XCTAssertTrue(context.observe("other"), "Idle word/previous-word/undo context must be invalidated")
        XCTAssertFalse(context.observe("other"), "Notification and timer duplicates must not reset new context")
        XCTAssertTrue(context.observe("en"), "Returning to an earlier source is still an external change")
    }

    func testExternalReturnIsObservedImmediatelyAfterConfirmation() {
        var context = InputSourceContext()
        XCTAssertFalse(context.observe("en"))
        context.recordSelection("ru")
        XCTAssertTrue(context.observe("en"), "An immediate Fn switch must not be masked by a grace period")
    }
}
