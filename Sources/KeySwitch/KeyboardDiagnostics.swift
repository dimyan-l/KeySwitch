import Foundation
import OSLog

/// Opt-in counters and timings. Events deliberately cannot contain text, keys, or field values.
enum KeyboardDiagnostics {
    enum Event: String {
        case tapStarted, tapFailed, tapTimedOut, tapDisabled, secureInputChanged
        case inputReleased, rewriteCancelled, queueLimit, sourceUnconfirmed
        case undoVerified, undoDeclined
        /// Why a finished word was or was not rewritten: reason codes only, never text.
        case wordFinished, wordDropped
    }

    private static let enabled = CommandLine.arguments.contains("--diagnostics")
    private static let logger = Logger(subsystem: "com.levantovsky.keyswitch", category: "keyboard")

    static func record(_ event: Event, milliseconds: Int = 0, buffered: Int = 0, detail: StaticString = "") {
        guard enabled else { return }
        logger.notice("\(event.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public) buffered=\(buffered, privacy: .public) \(detail.description, privacy: .public)")
    }

    /// Decision codes (classifier reason names) are fixed identifiers, not user text.
    static func decision(_ event: Event, _ detail: String) {
        guard enabled else { return }
        logger.notice("\(event.rawValue, privacy: .public) \(detail, privacy: .public)")
    }
}
