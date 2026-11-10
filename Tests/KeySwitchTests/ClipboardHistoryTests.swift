import AppKit
import XCTest
@testable import KeySwitch

final class ClipboardHistoryTests: XCTestCase {
    func testDisabledRecordingClearsVolatileHistoryButPreservesPins() throws {
        let pasteboard = NSPasteboard(name: .init("KeySwitchTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UserStore(directory: directory, bundledRulesURL: nil)
        var enabled = true
        let history = ClipboardHistory(store: store, pasteboard: pasteboard,
                                       recordingEnabled: { enabled },
                                       foregroundBundleIdentifier: { "com.apple.TextEdit" },
                                       workspaceNotifications: NotificationCenter())
        history.write("ordinary")
        history.togglePin("pinned")
        XCTAssertEqual(history.items, ["ordinary"])
        enabled = false
        history.poll()
        XCTAssertTrue(history.items.isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("not collected", forType: .string)
        history.poll()
        XCTAssertTrue(history.items.isEmpty)
        history.write("explicit paste")
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertEqual(history.pinned, ["pinned"])
        XCTAssertEqual(pasteboard.string(forType: .string), "explicit paste")
        store.flushPendingWrites()
    }

    func testSnapshotRestorePreservesConcealedMarkerOnEveryItem() throws {
        let pasteboard = NSPasteboard(name: .init("KeySwitchTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ClipboardHistory(
            store: UserStore(directory: directory, bundledRulesURL: nil),
            pasteboard: pasteboard, recordingEnabled: { true }, foregroundBundleIdentifier: { "com.apple.TextEdit" },
            workspaceNotifications: NotificationCenter()
        )
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let items = ["first", "second"].map { value -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            item.setData(Data([1]), forType: concealed)
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
        let snapshot = try XCTUnwrap(history.snapshot())
        history.write("temporary")
        history.restore(snapshot)
        let restored = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.map { $0.string(forType: .string) }, ["first", "second"])
        XCTAssertEqual(restored.map { $0.data(forType: concealed) }, [Data([1]), Data([1])])
        history.clear()
        history.poll()
        XCTAssertEqual(history.items, [])
    }

    func testConcealedMarkerOnLaterItemRejectsWholeCopy() throws {
        let pasteboard = NSPasteboard(name: .init("KeySwitchTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ClipboardHistory(
            store: UserStore(directory: directory, bundledRulesURL: nil),
            pasteboard: pasteboard, recordingEnabled: { true }, foregroundBundleIdentifier: { "com.apple.TextEdit" },
            workspaceNotifications: NotificationCenter()
        )
        let text = NSPasteboardItem()
        text.setString("secret on first item", forType: .string)
        let marker = NSPasteboardItem()
        marker.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([text, marker]))
        history.poll()
        XCTAssertEqual(history.items, [])
    }

    func testActivationBeforePollDiscardsPendingUnmarkedSensitiveCopy() throws {
        let pasteboard = NSPasteboard(name: .init("KeySwitchTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notifications = NotificationCenter()
        var foreground = "com.1password.1password"
        let history = ClipboardHistory(
            store: UserStore(directory: directory, bundledRulesURL: nil),
            pasteboard: pasteboard, recordingEnabled: { true },
            foregroundBundleIdentifier: { foreground },
            workspaceNotifications: notifications
        )
        history.start()

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("unmarked secret", forType: .string))
        foreground = "com.apple.TextEdit"
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        history.poll()
        XCTAssertEqual(history.items, [], "Activation must consume the old app's pending copy before polling the new foreground app")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("ordinary copy", forType: .string))
        history.poll()
        XCTAssertEqual(history.items, ["ordinary copy"])
    }
}
