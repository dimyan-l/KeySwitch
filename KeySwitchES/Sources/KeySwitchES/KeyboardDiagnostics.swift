import Foundation
import OSLog

/// Opt-in counters and timings. Events deliberately cannot contain text, keys, or field values.
enum KeyboardDiagnostics {
    enum Event: String {
        case tapStarted, tapFailed, tapTimedOut, tapDisabled, secureInputChanged
        case inputReleased, rewriteCancelled, queueLimit, sourceUnconfirmed
        case undoVerified, undoDeclined
    }

    private static let enabled = CommandLine.arguments.contains("--diagnostics")
    private static let logger = Logger(subsystem: "com.levantovsky.keyswitches", category: "keyboard")

    static func record(_ event: Event, milliseconds: Int = 0, buffered: Int = 0) {
        guard enabled else { return }
        logger.notice("\(event.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public) buffered=\(buffered, privacy: .public)")
    }
}
