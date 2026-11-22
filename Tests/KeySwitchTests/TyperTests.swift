import XCTest
import CoreGraphics
@testable import KeySwitch

final class TyperTests: XCTestCase {
    private func makeStore() -> UserStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UserStore(directory: directory, bundledRulesURL: nil)
    }

    func testHotkeyPressedDuringRewriteIsHandledOnce() {
        let queue = DispatchQueue(label: "test.bufferedHotkey")
        queue.suspend()
        var posted: [CGEvent] = []
        let typer = Typer(queue: queue, eventSink: { posted.append($0.copy()!) })
        let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { 123 })
        let called = expectation(description: "selection command handled")
        engine.onHotkey = { hotkey in
            XCTAssertEqual(hotkey, .flipSelection)
            XCTAssertFalse(engine.isTyping)
            called.fulfill()
        }
        engine.perform([.backspace(1), .text("x")])
        for repeatFlag: Int64 in [0, 1] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 15, keyDown: true)!
            event.flags = [.maskControl, .maskAlternate]
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatFlag)
            XCTAssertNil(engine.handle(type: .keyDown, event: event))
        }
        queue.resume()
        wait(for: [called], timeout: 2)
        engine.onHotkey = nil
        XCTAssertFalse(posted.contains { $0.getIntegerValueField(.keyboardEventKeycode) == 15 })
    }

    func testBufferedWordCanBeCorrectedInSpellingOnlyMode() throws {
        let layouts = KeyboardLayouts()
        let source = layouts.current()
        let language = try XCTUnwrap(source.lang)
        let word = language == .en ? "recieve" : "почемуто"
        let codes = try word.map { letter in
            try XCTUnwrap((UInt16(0)...50).first {
                layouts.character(Stroke(keyCode: $0, shift: false, caps: false), layout: source.layout) == String(letter)
            })
        }
        let suite = "test.bufferedSpelling.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.autoEnabled = false
        settings.spellEnabled = true
        let queue = DispatchQueue(label: "test.bufferedSpelling")
        let replayed = expectation(description: "next keystroke delivered after spelling rewrite")
        let nextLetter: UInt16 = 6 // Z/Я appears in neither test word.
        var keyDowns: [UInt16] = []
        let typer = Typer(queue: queue, eventSink: { event in
            guard event.type == .keyDown else { return }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            keyDowns.append(code)
            if code == nextLetter { replayed.fulfill() }
        })
        let engine = SwitchEngine(layouts: layouts, store: makeStore(), typer: typer, settings: settings, frontmostPID: { 123 })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        engine.classifier = try Classifier.load(dictionaryDir: root.appendingPathComponent("Resources/Dictionaries"),
                                                userDir: nil, learned: [:])
        queue.suspend()
        engine.perform([])
        for code in codes + [49, nextLetter] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            XCTAssertNil(engine.handle(type: .keyDown, event: event))
        }
        queue.resume()
        wait(for: [replayed], timeout: 3)
        XCTAssertEqual(Array(keyDowns.prefix(codes.count)), codes)
        XCTAssertTrue(keyDowns.dropFirst(codes.count).contains(51))
        XCTAssertEqual(Array(keyDowns.suffix(2)), [49, nextLetter])
        XCTAssertEqual(engine.trackedWordLength, 1)
        XCTAssertFalse(engine.isTyping)
    }

    func testBufferedKeyUpsAndModifierReleasePreserveSemanticUndo() {
        for releaseCode: UInt16? in [nil, 61, 56] {
            let queue = DispatchQueue(label: "test.undoAfterRelease")
            queue.suspend()
            var posted: [CGEvent] = []
            let typer = Typer(queue: queue, eventSink: { posted.append($0.copy()!) })
            let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { 123 })
            XCTAssertTrue(engine.applySpellingCorrection(original: "a", replacement: "b",
                language: .en))
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)!
            XCTAssertNil(engine.handle(type: .keyUp, event: up))
            if let code = releaseCode {
                let release = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
                release.type = .flagsChanged
                release.flags = []
                XCTAssertNil(engine.handle(type: .flagsChanged, event: release))
            }
            let drained = expectation(description: "correction and releases replayed")
            queue.resume()
            queue.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 2)
            XCTAssertFalse(engine.isTyping)
            XCTAssertEqual(posted.suffix(releaseCode == nil ? 1 : 2).map(\.type),
                           releaseCode == nil ? [.keyUp] : [.keyUp, .flagsChanged])

            // Exercise undo, but cancel before its worker runs: no real source selection
            // or undo learning, and the injected sink never posts system events.
            queue.suspend()
            let postedBeforeUndo = posted.count
            engine.manualFix()
            XCTAssertTrue(engine.isTyping, "Releases must preserve the correction's undo branch")
            engine.cancelPendingTyping()
            let cancelled = expectation(description: "undo cancelled before worker")
            queue.resume()
            queue.async { DispatchQueue.main.async { cancelled.fulfill() } }
            wait(for: [cancelled], timeout: 2)
            XCTAssertEqual(posted.count, postedBeforeUndo)
        }
    }

    func testBufferedTextNavigationAndCapsLockInvalidateUndo() {
        for code: UInt16 in [0, 123, 57] {
            let queue = DispatchQueue(label: "test.staleUndo")
            queue.suspend()
            let typer = Typer(queue: queue, eventSink: { _ in })
            let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { 123 })
            XCTAssertTrue(engine.applySpellingCorrection(original: "a", replacement: "b",
                language: .en))
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            if code == 57 { event.type = .flagsChanged; event.flags = .maskAlphaShift }
            XCTAssertNil(engine.handle(type: event.type, event: event))
            let drained = expectation(description: "state-changing input replayed")
            queue.resume()
            queue.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 2)
            queue.suspend()
            // A replayed letter now starts the next tracked word, so Right Option converts that
            // word instead of undoing the earlier correction.
            let expectsWordFix = code == 0 && engine.layouts.currentLang != nil && engine.trackedWordLength == 1
            engine.manualFix()
            XCTAssertEqual(engine.isTyping, expectsWordFix, "Replayed text/navigation/Caps Lock must not leave stale undo")
            engine.cancelPendingTyping()
            let cancelled = expectation(description: "no stale undo worker")
            queue.resume()
            queue.async { DispatchQueue.main.async { cancelled.fulfill() } }
            wait(for: [cancelled], timeout: 2)
        }
    }

    func testLettersTypedDuringRewriteStartTheNextTrackedWord() throws {
        let layouts = KeyboardLayouts()
        try XCTSkipIf(layouts.currentLang == nil || !layouts.hasBothLayouts, "needs RU and EN layouts")
        let queue = DispatchQueue(label: "test.trackReplay")
        queue.suspend()
        var posted: [CGEvent] = []
        let typer = Typer(queue: queue, eventSink: { posted.append($0.copy()!) })
        let engine = SwitchEngine(layouts: layouts, store: makeStore(), typer: typer, frontmostPID: { 123 })
        XCTAssertTrue(engine.applySpellingCorrection(original: "a", replacement: "b",
            language: .en))
        for code: UInt16 in [40, 3, 15] { // k f r -> "как" on ЙЦУКЕН
            XCTAssertNil(engine.handle(type: .keyDown, event: CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!))
        }
        let drained = expectation(description: "held letters replayed")
        queue.resume()
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(engine.isTyping)
        XCTAssertEqual(engine.trackedWordLength, 3, "Held letters must be part of the next word")
        XCTAssertEqual(posted.suffix(3).map { $0.getIntegerValueField(.keyboardEventKeycode) }, [40, 3, 15])
        engine.cancelPendingTyping()
    }

    func testPhysicalKeyDuringRewritePreservesReplacementDelimiterAndInputOrder() {
        let queue = DispatchQueue(label: "test.rewrite")
        let reachedDeletion = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        var posted: [CGEvent] = []
        let typer = Typer(queue: queue, eventSink: { event in
            posted.append(event.copy()!)
            if posted.count == 2 {
                reachedDeletion.signal()
                _ = resume.wait(timeout: .now() + 2)
            }
        })
        let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { 123 })
        let done = expectation(description: "rewrite and replay")
        engine.perform([.backspace(1), .text("x"), .key(49, [])]) {
            DispatchQueue.main.async { done.fulfill() }
        }
        XCTAssertEqual(reachedDeletion.wait(timeout: .now() + 2), .success)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false)!
        let release = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)!
        release.type = .flagsChanged
        release.flags = []
        XCTAssertNil(engine.handle(type: .flagsChanged, event: release))
        down.flags = .maskShift
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(engine.handle(type: .keyDown, event: down))
        XCTAssertNil(engine.handle(type: .keyUp, event: up))
        // The tap owns a copy, not this mutable callback event.
        down.flags = []
        down.setIntegerValueField(.keyboardEventKeycode, value: 13)
        resume.signal()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(posted.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [51, 51, 0, 0, 49, 49, 61, 12, 12])
        XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp, .flagsChanged, .keyDown, .keyUp])
        XCTAssertEqual(posted.last { $0.type == .keyDown }?.flags, .maskShift)
        XCTAssertEqual(posted.last { $0.type == .keyDown }?.getIntegerValueField(.keyboardEventAutorepeat), 1)
        XCTAssertTrue(posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == Typer.marker })
        XCTAssertFalse(engine.isTyping)
    }

    func testAppChangeBeforeCompletionDropsBufferedInputWithoutNotification() {
        let queue = DispatchQueue(label: "test.focus")
        queue.suspend()
        var posted: [CGEvent] = []
        var pid: pid_t? = 123
        let typer = Typer(queue: queue, eventSink: { posted.append($0.copy()!) })
        let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { pid })
        engine.perform([]) { XCTFail("Must not complete in a different app") }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
        XCTAssertNil(engine.handle(type: .keyDown, event: event))
        pid = 456
        let drained = expectation(description: "completion drained")
        queue.resume()
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(posted.isEmpty, "Never replay stale physical input into another app")
        XCTAssertFalse(engine.isTyping)
    }

    func testObservedAppChangeStopsWorkerBeforeNextPairButReleasesStartedKey() {
        for action: Typer.Action in [.backspace(3), .text("abc"), .key(49, []), .command(8)] {
            let queue = DispatchQueue(label: "test.targetPID")
            let reachedDown = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            var posted: [CGEvent] = []
            let typer = Typer(queue: queue, eventSink: { event in
                posted.append(event.copy()!)
                if posted.count == 1 {
                    reachedDown.signal()
                    _ = resume.wait(timeout: .now() + 2)
                }
            })
            let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { 123 })
            // The main-thread observer updates the cache without cancelling the engine.
            // Hold the worker inside key-down so the in-flight key-up must still post.
            engine.perform([action, .key(36, [])]) { XCTFail("App change must not succeed") }
            XCTAssertEqual(reachedDown.wait(timeout: .now() + 2), .success)
            let physical = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
            XCTAssertNil(engine.handle(type: .keyDown, event: physical))
            typer.updateFrontmostPID(456)
            let drained = expectation(description: "worker and failed completion drained")
            resume.signal()
            queue.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 2)
            XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp], "Finish only the started pair; never replay buffered input")
            XCTAssertEqual(posted.first?.getIntegerValueField(.keyboardEventKeycode),
                           posted.last?.getIntegerValueField(.keyboardEventKeycode))
            XCTAssertFalse(engine.isTyping)
        }
    }

    func testUnknownFrontmostProcessPostsNothing() {
        let typer = Typer(queue: DispatchQueue(label: "test.unknownPID"),
                          eventSink: { _ in XCTFail("Unknown target must not receive keys") })
        let direct = expectation(description: "direct run refused")
        typer.run([.backspace(2), .text("x")]) { finished in
            XCTAssertFalse(finished)
            direct.fulfill()
        }
        wait(for: [direct], timeout: 2)

        let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { nil })
        engine.perform([.backspace(2), .text("x")]) { XCTFail("Unknown target must not succeed") }
        let drained = expectation(description: "engine run drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(engine.isTyping)
    }

    func testTargetPIDSnapshotRejectsQueuedRunInDifferentApp() {
        let queue = DispatchQueue(label: "test.queuedTargetPID")
        queue.suspend()
        let typer = Typer(queue: queue, eventSink: { _ in XCTFail("Wrong target posted a key") })
        typer.updateFrontmostPID(123)
        let done = expectation(description: "queued target invalidated")
        typer.run([.text("x")], targetPID: 123) { finished in
            XCTAssertFalse(finished)
            done.fulfill()
        }
        typer.updateFrontmostPID(456)
        queue.resume()
        wait(for: [done], timeout: 2)
    }

    func testDefaultRunSnapshotsObservedPIDBeforeQueueStarts() {
        let queue = DispatchQueue(label: "test.defaultTargetPID")
        queue.suspend()
        let typer = Typer(queue: queue, eventSink: { _ in XCTFail("Default run lost its target snapshot") })
        typer.updateFrontmostPID(123)
        let done = expectation(description: "default target invalidated")
        typer.run([.key(49, [])]) { finished in
            XCTAssertFalse(finished)
            done.fulfill()
        }
        typer.updateFrontmostPID(nil)
        queue.resume()
        wait(for: [done], timeout: 2)
    }

    func testCancellationBeforeWorkerRunsPostsNothing() {
        let queue = DispatchQueue(label: "test.beforeRun")
        queue.suspend()
        let typer = Typer(queue: queue, eventSink: { _ in XCTFail("Cancelled run posted an event") })
        let done = expectation(description: "cancelled before run")
        typer.run([.backspace(3), .text("replacement"), .key(49, [])]) { finished in
            XCTAssertFalse(finished)
            done.fulfill()
        }
        typer.cancel()
        queue.resume()
        wait(for: [done], timeout: 2)
    }

    func testContextCancellationAndStopDiscardBufferAndStaleCompletion() {
        for stop in [false, true] {
            let queue = DispatchQueue(label: "test.invalidate")
            queue.suspend()
            var posted: [CGEvent] = []
            let typer = Typer(queue: queue, eventSink: { posted.append($0.copy()!) })
            let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { 123 })
            engine.perform([.backspace(1), .text("x"), .key(49, [])]) { XCTFail("Stale success") }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
            XCTAssertNil(engine.handle(type: .keyDown, event: event))
            if stop { engine.stop() } else { engine.cancelPendingTyping() }
            XCTAssertFalse(engine.isTyping)
            let drained = expectation(description: "cancelled completion drained")
            queue.resume()
            queue.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 2)
            XCTAssertTrue(posted.isEmpty)
            let next = expectation(description: "new context run")
            engine.perform([.key(0, [])]) { next.fulfill() }
            wait(for: [next], timeout: 2)
            XCTAssertEqual(posted.count, 2, "Old buffer must not leak into a new run")
        }
    }

    func testDisabledTapImmediatelyInvalidatesBufferedRewrite() {
        let queue = DispatchQueue(label: "test.disabled")
        queue.suspend()
        let typer = Typer(queue: queue, eventSink: { _ in XCTFail("Disabled tap must not replay") })
        let engine = SwitchEngine(layouts: KeyboardLayouts(), store: makeStore(), typer: typer, frontmostPID: { 123 })
        engine.perform([.key(49, [])]) { XCTFail("Disabled tap success") }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
        XCTAssertNil(engine.handle(type: .keyDown, event: event))
        _ = engine.handle(type: .tapDisabledByTimeout, event: event)
        XCTAssertFalse(engine.isTyping, "Invalidate synchronously, before the queued completion")
        let drained = expectation(description: "disabled worker drained")
        queue.resume()
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
    }

    func testCancellationStopsPendingRunWithoutPostingKeys() {
        // Pause-only runs post no events; a known target is still required.
        let typer = Typer(eventSink: { _ in XCTFail("Pause must not post events") })
        typer.updateFrontmostPID(123)
        let cancelled = expectation(description: "cancelled")
        typer.run([.pause(0.3)]) { finished in
            XCTAssertFalse(finished)
            cancelled.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { typer.cancel() }
        wait(for: [cancelled], timeout: 2)

        let nextRun = expectation(description: "next run")
        typer.run([.pause(0.01)]) { finished in
            XCTAssertTrue(finished)
            nextRun.fulfill()
        }
        wait(for: [nextRun], timeout: 2)
    }

    func testBackspaceAfterSpaceRestoresPreviousWord() throws {
        let layouts = KeyboardLayouts()
        try XCTSkipIf(layouts.currentLang == nil, "needs an active RU/EN layout")
        let engine = SwitchEngine(layouts: layouts, store: makeStore(), frontmostPID: { 123 })
        for code: UInt16 in [0, 1] { // two letter keys
            _ = engine.handle(type: .keyDown, event: CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!)
        }
        XCTAssertEqual(engine.trackedWordLength, 2)
        // Space moves the word into prev without converting (classifier is nil).
        _ = engine.handle(type: .keyDown, event: CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!)
        XCTAssertEqual(engine.trackedWordLength, 0)
        // Deleting the trailing Space restores the tracked word for continued editing.
        _ = engine.handle(type: .keyDown, event: CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true)!)
        XCTAssertEqual(engine.trackedWordLength, 2)
    }
    func testRoutesBothHalvesToTheSamePIDEvenWhenFocusChangesDuringPosting() {
        var posted: [(CGEventType, pid_t)] = []
        weak var observedTyper: Typer?
        let typer = Typer(targetedSink: { event, pid in
            posted.append((event.type, pid))
            if event.type == .keyDown { observedTyper?.updateFrontmostPID(456) }
        }, protectedInput: { false })
        observedTyper = typer
        typer.updateFrontmostPID(123)
        let ended = expectation(description: "late focus change cancels further emission")
        typer.run([.text("hello")]) { success in
            XCTAssertFalse(success)
            ended.fulfill()
        }
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(posted.map { $0.0 }, [.keyDown, .keyUp])
        XCTAssertEqual(posted.map { $0.1 }, [123, 123])
    }

    func testProtectedInputBlocksNewPostsAndReplay() {
        let typer = Typer(targetedSink: { _, _ in XCTFail("Secure Input must block event delivery") },
                          protectedInput: { true })
        typer.updateFrontmostPID(123)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
        typer.replay(event, to: 123)
        let ended = expectation(description: "protected")
        typer.run([.backspace(1), .text("text")]) { success in
            XCTAssertFalse(success)
            ended.fulfill()
        }
        wait(for: [ended], timeout: 2)
    }

}
