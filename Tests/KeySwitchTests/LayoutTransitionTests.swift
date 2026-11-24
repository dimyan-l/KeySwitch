import Carbon
import CoreGraphics
import XCTest
@testable import KeySwitch

final class LayoutTransitionTests: XCTestCase {
    private func sources() throws -> (en: KeyboardLayouts.Source, ru: KeyboardLayouts.Source) {
        let properties = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String]
        let refs = TISCreateInputSourceList(properties as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        let supportedIDs: Set<String> = ["com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.Russian"]
        let sources = refs.compactMap { ref -> KeyboardLayouts.Source? in
            guard let ptr = TISGetInputSourceProperty(ref, kTISPropertyInputSourceID),
                  let id = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? String,
                  supportedIDs.contains(id) else { return nil }
            return KeyboardLayouts.makeSource(ref)
        }
        return (
            try XCTUnwrap(sources.first { ["com.apple.keylayout.US", "com.apple.keylayout.ABC"].contains($0.id) && $0.layout != nil }),
            try XCTUnwrap(sources.first { $0.id == "com.apple.keylayout.Russian" && $0.layout != nil })
        )
    }

    private func engine(layouts: KeyboardLayouts, typer: Typer = Typer(eventSink: { _ in }),
                        settings configure: (Settings) -> Void = { _ in },
                        verifier: ((String, pid_t) -> Bool)? = nil) -> SwitchEngine {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let store = UserStore(directory: directory, bundledRulesURL: nil)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = "keyswitch.layout-transition.\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        configure(settings)
        return SwitchEngine(layouts: layouts, store: store, typer: typer, settings: settings,
                            frontmostPID: { 123 }, verifyBackspaceUndo: verifier)
    }

    private func key(_ code: UInt16, text: String = "") -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        return event
    }

    private func passes(_ event: CGEvent, through engine: SwitchEngine) -> Bool {
        engine.handle(type: .keyDown, event: event) != nil
    }

    private func text(_ event: CGEvent) -> String {
        var units = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        return String(decoding: units.prefix(length), as: UTF16.self)
    }

    func testInputSourceChangedHalfwayThroughWordBeforeNotification() throws {
        let (en, ru) = try sources()
        var current = en
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { current })
        let engine = engine(layouts: layouts)

        XCTAssertTrue(passes(key(0, text: "a"), through: engine))
        XCTAssertEqual(engine.trackedWordLength, 1)
        current = ru
        XCTAssertTrue(passes(key(0, text: "ф"), through: engine))
        XCTAssertEqual(engine.trackedWordLength, 0)
        XCTAssertTrue(passes(key(49), through: engine))
        XCTAssertTrue(passes(key(0, text: "ф"), through: engine))
        XCTAssertEqual(engine.trackedWordLength, 1)
    }

    func testDisagreementBetweenEventTextAndLayoutDoesNotRewriteSuffix() throws {
        let (en, ru) = try sources()
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { ru })
        let engine = engine(layouts: layouts)
        let oldLanguage = key(0, text: "a")

        XCTAssertTrue(passes(oldLanguage, through: engine))
        XCTAssertEqual(text(oldLanguage), "a", "Physical keystrokes must pass through without coercion")
        XCTAssertTrue(passes(key(0, text: "ф"), through: engine))
        XCTAssertEqual(engine.trackedWordLength, 0)
    }

    func testHeldKeystrokeWaitsForConfirmedLayoutAndKeepsPhysicalKey() throws {
        let (en, ru) = try sources()
        var current = en
        var requests = 0
        let requested = expectation(description: "requested once")
        let released = expectation(description: "buffered key delivered in Russian")
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { current }, requestSource: { _ in
            requests += 1
            requested.fulfill()
            return noErr
        })
        let typer = Typer(eventSink: { event in
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
            XCTAssertEqual(self.text(event), "ф")
            released.fulfill()
        })
        let engine = engine(layouts: layouts, typer: typer)

        engine.perform([], switchingTo: .ru)
        XCTAssertFalse(passes(key(0, text: "a"), through: engine))
        wait(for: [requested], timeout: 2)
        XCTAssertTrue(engine.isTyping, "A successful request does not prove the source is active")
        current = ru
        wait(for: [released], timeout: 2)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(engine.trackedWordLength, 1)
        XCTAssertFalse(engine.isTyping)
    }

    func testUnconfirmedLayoutReleasesHeldKeyInOriginalLayoutWithoutRetry() throws {
        let (en, ru) = try sources()
        var requests = 0
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { en }, requestSource: { _ in
            requests += 1
            return noErr
        })
        let released = expectation(description: "buffered key delivered in English after timeout")
        let typer = Typer(eventSink: { event in
            XCTAssertEqual(self.text(event), "a")
            released.fulfill()
        })
        let engine = engine(layouts: layouts, typer: typer)

        engine.perform([], switchingTo: .ru)
        XCTAssertFalse(passes(key(0, text: "a"), through: engine))
        wait(for: [released], timeout: 2)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(engine.isTyping)
    }

    func testAutomaticLayoutCorrectionWaitsForSpace() throws {
        let (en, ru) = try sources()
        var current = en
        let selected = expectation(description: "Russian selected after the word and space")
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { current }, requestSource: { _ in
            current = ru
            selected.fulfill()
            return noErr
        })
        let engine = engine(layouts: layouts)
        let english = LanguageModel(lang: .en)
        let russian = LanguageModel(lang: .ru)
        russian.add("привет", score: 8)
        engine.classifier = Classifier(models: [.en: english, .ru: russian])
        let wrongKeys: [UInt16] = [5, 4, 11, 2, 17, 45] // ghbdtn

        for delimiter: UInt16 in [48, 49] {
            for code in wrongKeys {
                XCTAssertTrue(passes(key(code), through: engine))
                XCTAssertFalse(engine.isTyping)
            }
            XCTAssertEqual(passes(key(delimiter), through: engine), delimiter != 49)
            if delimiter == 48 {
                // Tab may put the caret in the middle of an existing token in the next field.
                XCTAssertTrue(passes(key(49), through: engine))
            }
        }
        wait(for: [selected], timeout: 2)
        XCTAssertFalse(engine.isTyping)
    }

    func testRightOptionCanRecoverMixedWordsWhenOnlyOneReadingIsInDictionary() throws {
        let (en, ru) = try sources()
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { en })
        let english = LanguageModel(lang: .en)
        let russian = LanguageModel(lang: .ru)
        english.add("hello", score: 8)
        russian.add("привет", score: 8)
        let classifier = Classifier(models: [.en: english, .ru: russian])
        func repair(_ word: String) -> CaretFix.Plan? {
            CaretFix.plan(token: word, classifier: classifier, mixed: { layouts.repairMixedWord($0, classifier: classifier) },
                          flip: layouts.flipText)
        }

        XCTAssertEqual(repair("приdtn")?.choices, ["привет"])
        XCTAssertEqual(repair("heддщ")?.choices, ["hello"])
        XCTAssertNil(repair("прod"))
    }
    func testNavigationAndSymbolsDoNotReclassifyAnExistingTokenSuffix() throws {
        let (en, ru) = try sources()
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { en }, requestSource: { _ in
            XCTFail("A structured token or suffix must not switch layout")
            return noErr
        })
        let engine = engine(layouts: layouts)
        let english = LanguageModel(lang: .en)
        let russian = LanguageModel(lang: .ru)
        russian.add("привет", score: 8)
        engine.classifier = Classifier(models: [.en: english, .ru: russian])

        let plus = key(24, text: "+")
        plus.flags = .maskShift
        for precedingEvent in [key(123), key(48), plus] {
            XCTAssertTrue(passes(key(0), through: engine))
            XCTAssertTrue(passes(precedingEvent, through: engine))
            for code: UInt16 in [5, 4, 11, 2, 17, 45, 49] {
                XCTAssertTrue(passes(key(code), through: engine))
            }
        }
    }

    func testSpellingWorksWithOnlyOneInputSourceEnabled() throws {
        let (en, _) = try sources()
        let layouts = KeyboardLayouts(sources: [.en: en], readSource: { en })
        let engine = engine(layouts: layouts, settings: { $0.spellEnabled = true })
        let english = LanguageModel(lang: .en)
        english.add("address", score: 8)
        engine.classifier = Classifier(models: [.en: english])
        for code: UInt16 in [0, 2, 15, 14, 1, 1] { // adress
            XCTAssertTrue(passes(key(code), through: engine))
        }
        XCTAssertFalse(passes(key(49), through: engine))
    }

    func testBackspaceRestoresOnlyAVerifiedCorrectionAndNeverLearnsFromIt() throws {
        let (en, _) = try sources()
        for verified in [false, true] {
            var posted: [CGEvent] = []
            let queue = DispatchQueue(label: "test.backspace-validation")
            let typer = Typer(queue: queue, eventSink: { posted.append($0.copy()!) })
            let layouts = KeyboardLayouts(sources: [.en: en], readSource: { en })
            let engine = engine(layouts: layouts, typer: typer, verifier: { suffix, pid in
                XCTAssertEqual(suffix, "hello ")
                XCTAssertEqual(pid, 123)
                return verified
            })
            XCTAssertTrue(engine.applySpellingCorrection(original: "hellp", replacement: "hello", language: .en))
            let initial = expectation(description: "initial rewrite released")
            engine.afterTyping { initial.fulfill() }
            wait(for: [initial], timeout: 2)
            posted.removeAll()
            XCTAssertFalse(passes(key(51), through: engine))
            let undo = expectation(description: "verification and fallback/rewrite complete")
            engine.afterTyping { undo.fulfill() }
            wait(for: [undo], timeout: 2)
            let keyDowns = posted.filter { $0.type == .keyDown }
            XCTAssertEqual(keyDowns.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 51 }.count,
                           verified ? 2 : 1)
            let replacement = keyDowns.filter { $0.getIntegerValueField(.keyboardEventKeycode) != 51 }.map(text).joined()
            XCTAssertEqual(replacement, verified ? "p" : "")
            XCTAssertTrue(engine.store.rules.active.isEmpty, "Backspace is an edit, not a persistent exception")
        }
    }

    func testMarkedEventsNeverReenterInputTracking() throws {
        let (en, _) = try sources()
        let engine = engine(layouts: KeyboardLayouts(sources: [.en: en], readSource: { en }))
        let replay = key(0, text: "a")
        replay.setIntegerValueField(.eventSourceUserData, value: Typer.marker)
        XCTAssertTrue(passes(replay, through: engine))
        XCTAssertEqual(engine.trackedWordLength, 0)
    }

    func testGlobeIsPassedToSystemAndSuppressesAutomaticLayoutRequest() throws {
        let (en, ru) = try sources()
        let queue = DispatchQueue(label: "test.globe")
        let typer = Typer(queue: queue, eventSink: { _ in })
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { en }, requestSource: { _ in
            XCTFail("Manual Globe gesture takes priority")
            return noErr
        })
        let engine = engine(layouts: layouts, typer: typer)
        queue.suspend()
        let done = expectation(description: "original rewrite finished")
        engine.perform([], switchingTo: .ru) { done.fulfill() }
        let globe = key(63)
        globe.type = .flagsChanged
        globe.flags = .maskSecondaryFn
        XCTAssertTrue(engine.handle(type: .flagsChanged, event: globe) != nil)
        queue.resume()
        wait(for: [done], timeout: 2)
        XCTAssertFalse(engine.isTyping)
    }


    // MARK: - Remembering reverted corrections

    private func spellingEngine(typer: Typer, accepts: ((String, Lang) -> Bool)? = nil) throws -> SwitchEngine {
        let (en, _) = try sources()
        let layouts = KeyboardLayouts(sources: [.en: en], readSource: { en })
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = "keyswitch.restore.\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.spellEnabled = true
        let engine = SwitchEngine(layouts: layouts, store: UserStore(directory: directory, bundledRulesURL: nil),
                                  typer: typer, settings: settings, frontmostPID: { 123 }, acceptsSpelling: accepts)
        let english = LanguageModel(lang: .en)
        english.add("hello", score: 8)
        english.add("address", score: 8)
        engine.classifier = Classifier(models: [.en: english])
        return engine
    }

    private func settle(_ engine: SwitchEngine) {
        let done = expectation(description: "typing released")
        engine.afterTyping { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testRetypingTheOriginalWordAfterErasingTheFixRemembersIt() throws {
        let typer = Typer(queue: DispatchQueue(label: "test.restore"), eventSink: { _ in })
        let engine = try spellingEngine(typer: typer)
        let hellp: [UInt16] = [4, 14, 37, 37, 35]
        for code in hellp { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertFalse(passes(key(49), through: engine), "hellp is fixed to hello")
        settle(engine)
        XCTAssertEqual(engine.recentCorrection(producing: "Hello")?.original, "hellp")

        for _ in 0..<6 { XCTAssertTrue(passes(key(51), through: engine)) }
        for code in hellp { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertTrue(passes(key(49), through: engine), "the word typed again is left alone")
        XCTAssertTrue(engine.store.rules.blocks("hellp", lang: .en, kind: .spell))
        XCTAssertEqual(engine.store.rules.active.first?.source, .restore)
        XCTAssertNil(engine.recentCorrection(producing: "hello"))

        // From now on the exception holds without any erasing.
        for code in hellp { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertTrue(passes(key(49), through: engine))
    }

    func testRetypingWithoutErasingOrAfterNavigationIsNotAnException() throws {
        let typer = Typer(queue: DispatchQueue(label: "test.restore-nav"), eventSink: { _ in })
        let engine = try spellingEngine(typer: typer)
        let hellp: [UInt16] = [4, 14, 37, 37, 35]
        for code in hellp { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertFalse(passes(key(49), through: engine))
        settle(engine)
        XCTAssertTrue(passes(key(123), through: engine)) // ← moves the caret elsewhere
        for _ in 0..<6 { XCTAssertTrue(passes(key(51), through: engine)) }
        for code in hellp { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertFalse(passes(key(49), through: engine), "the same typo is fixed again")
        settle(engine)
        XCTAssertTrue(engine.store.rules.active.isEmpty, "\(engine.store.rules.active) tracked=\(engine.trackedWordLength)")
    }

    func testRestoringARecentCorrectionAddsAnUndoRuleOnlyForAutomaticChanges() throws {
        let engine = try spellingEngine(typer: Typer(eventSink: { _ in }))
        engine.record(replacement: "беги", original: "баги", lang: .ru, kind: .spell)
        engine.record(replacement: "работа", original: "hf,jnf", lang: .en, originalWord: "hf,jnf",
                      kind: .layout, automatic: false)
        let auto = try XCTUnwrap(engine.recentCorrection(producing: "Беги"))
        engine.remember(auto, source: .undo)
        XCTAssertTrue(engine.store.rules.blocks("баги", lang: .ru, kind: .spell))
        let manual = try XCTUnwrap(engine.recentCorrection(producing: "работа"))
        engine.remember(manual, source: .undo)
        XCTAssertEqual(engine.store.rules.active.count, 1, "a manual flip only toggles")
        XCTAssertTrue(engine.recentCorrections.isEmpty)
    }

    func testMacOSSpellCheckerVetoesAutomaticTypoFix() throws {
        var asked: [String] = []
        let engine = try spellingEngine(typer: Typer(eventSink: { _ in }), accepts: { word, lang in
            asked.append(word)
            XCTAssertEqual(lang, .en)
            return true
        })
        for code: UInt16 in [0, 2, 15, 14, 1, 1] { // adress
            XCTAssertTrue(passes(key(code), through: engine))
        }
        XCTAssertTrue(passes(key(49), through: engine), "a word macOS accepts is not changed")
        XCTAssertEqual(asked, ["adress"])
    }

    func testReplacementHistoryPersistsWithoutExpiry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = UserStore(directory: directory, bundledRulesURL: nil)
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        first.recordCorrection(CorrectionRecord(replacement: "беги", original: "баги", lang: .ru, originalWord: "баги",
                                                kind: .spell, automatic: true, date: old))
        first.recordCorrection(CorrectionRecord(replacement: "привет", original: "ghbdtn", lang: .en, originalWord: "ghbdtn",
                                                kind: .layout, automatic: true, date: Date()))
        first.flushPendingWrites()

        let second = UserStore(directory: directory, bundledRulesURL: nil)
        XCTAssertEqual(second.correction(producing: "Беги")?.original, "баги", "a year-old replacement is still known")
        XCTAssertEqual(second.correction(producing: "ПРИВЕТ")?.original, "ghbdtn")
        second.removeCorrection(producing: "беги")
        second.flushPendingWrites()
        XCTAssertNil(UserStore(directory: directory, bundledRulesURL: nil).correction(producing: "беги"))
        second.clearCorrections()
        second.flushPendingWrites()
        XCTAssertTrue(UserStore(directory: directory, bundledRulesURL: nil).corrections.isEmpty)
    }

    func testCautiousModePullsAShortWrongLayoutWordAlongWithAConfidentFix() throws {
        let (en, ru) = try sources()
        var current = en
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { current }, requestSource: { _ in
            current = ru
            return noErr
        })
        var posted: [CGEvent] = []
        let typer = Typer(queue: DispatchQueue(label: "test.cautious-retro"), eventSink: { posted.append($0.copy()!) })
        let engine = engine(layouts: layouts, typer: typer)
        let english = LanguageModel(lang: .en)
        english.add("vs", score: 3.0)
        english.add("my", score: 7.0)
        let russian = LanguageModel(lang: .ru)
        russian.add("мы", score: 6.9)
        russian.add("привет", score: 8)
        engine.classifier = Classifier(models: [.en: english, .ru: russian])

        for code: UInt16 in [9, 1] { XCTAssertTrue(passes(key(code), through: engine)) } // vs
        XCTAssertTrue(passes(key(49), through: engine), "a two-letter word alone stays a suggestion")
        for code: UInt16 in [5, 4, 11, 2, 17, 45] { XCTAssertTrue(passes(key(code), through: engine)) } // ghbdtn
        XCTAssertFalse(passes(key(49), through: engine))
        let done = expectation(description: "rewrite finished")
        engine.afterTyping { done.fulfill() }
        wait(for: [done], timeout: 2)
        let downs = posted.filter { $0.type == .keyDown }
        XCTAssertEqual(downs.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 51 }.count, 9)
        let typed = downs.filter { $0.getIntegerValueField(.keyboardEventKeycode) != 51 }.map(text).joined()
        XCTAssertTrue(typed.hasPrefix("мы привет"), typed)
    }

    func testReturnFixesLayoutBeforeSendingButNeverTypos() throws {
        let (en, ru) = try sources()
        for shift in [false, true] {
            var current = en
            let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { current }, requestSource: { _ in
                current = ru
                return noErr
            })
            var posted: [CGEvent] = []
            let typer = Typer(queue: DispatchQueue(label: "test.return-\(shift)"), eventSink: { posted.append($0.copy()!) })
            let engine = engine(layouts: layouts, typer: typer, settings: { $0.spellEnabled = true })
            let english = LanguageModel(lang: .en)
            english.add("address", score: 8)
            let russian = LanguageModel(lang: .ru)
            russian.add("тут", score: 6)
            engine.classifier = Classifier(models: [.en: english, .ru: russian])

            for code: UInt16 in [45, 14, 45] { XCTAssertTrue(passes(key(code), through: engine)) } // nen
            let enter = key(36, text: "\r")
            if shift { enter.flags = .maskShift }
            XCTAssertFalse(passes(enter, through: engine), "Return waits for the layout fix")
            let done = expectation(description: "rewrite and Return posted")
            engine.afterTyping { done.fulfill() }
            wait(for: [done], timeout: 2)
            let downs = posted.filter { $0.type == .keyDown }
            XCTAssertEqual(downs.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 51 }.count, 3)
            XCTAssertEqual(downs.filter { ![51, 36].contains($0.getIntegerValueField(.keyboardEventKeycode)) }.map(text).joined(), "тут")
            let sentReturn = try XCTUnwrap(downs.last)
            XCTAssertEqual(sentReturn.getIntegerValueField(.keyboardEventKeycode), 36, "Return comes after the fix")
            XCTAssertEqual(sentReturn.flags.contains(.maskShift), shift)

            // A typo before Return is sent as typed.
            current = en
            _ = engine.inputSourceDidChange(to: en.id)
            for code: UInt16 in [0, 2, 15, 14, 1, 1] { XCTAssertTrue(passes(key(code), through: engine)) } // adress
            XCTAssertTrue(passes(key(36, text: "\r"), through: engine))
        }
    }

    private func wrongLayoutEngine(_ words: [String]) throws -> SwitchEngine {
        let (en, ru) = try sources()
        var current = en
        let layouts = KeyboardLayouts(sources: [.en: en, .ru: ru], readSource: { current }, requestSource: { _ in
            current = ru
            return noErr
        })
        let engine = engine(layouts: layouts)
        let russian = LanguageModel(lang: .ru)
        for word in words { russian.add(word, score: 7) }
        engine.classifier = Classifier(models: [.en: LanguageModel(lang: .en), .ru: russian])
        return engine
    }

    func testClickAtAWordBoundaryTracksTheNextWord() throws {
        let engine = try wrongLayoutEngine(["привет"])
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        XCTAssertNotNil(engine.handle(type: .leftMouseDown, event: click))
        engine.caretVerifiedAtBoundary(clickRevision: engine.clickRevision)
        for code: UInt16 in [5, 4, 11, 2, 17, 45] { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertFalse(passes(key(49), through: engine), "an empty chat field: the first word is fixed")
    }

    func testClickConfirmedTooLateOrMidWordLeavesTheWordAlone() throws {
        let engine = try wrongLayoutEngine(["привет"])
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        XCTAssertNotNil(engine.handle(type: .leftMouseDown, event: click))
        let revision = engine.clickRevision
        XCTAssertTrue(passes(key(5), through: engine))
        engine.caretVerifiedAtBoundary(clickRevision: revision) // arrives after the first key: ignored
        for code: UInt16 in [4, 11, 2, 17, 45] { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertTrue(passes(key(49), through: engine))
        // A stale confirmation from an older click is ignored too.
        XCTAssertNotNil(engine.handle(type: .leftMouseDown, event: click))
        engine.caretVerifiedAtBoundary(clickRevision: revision)
        for code: UInt16 in [5, 4, 11, 2, 17, 45] { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertTrue(passes(key(49), through: engine))
    }

    func testUnreadableCaretAfterClickStillFixesAClearFirstWord() throws {
        // An Electron chat box (the Claude app) gives Accessibility no caret: "gkj[j" stayed as typed.
        let engine = try wrongLayoutEngine(["привет", "плохо", "во"])
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        XCTAssertNotNil(engine.handle(type: .leftMouseDown, event: click))
        engine.caretUnreadableAfterClick(clickRevision: engine.clickRevision)
        for code: UInt16 in [5, 37, 38, 33, 38] { XCTAssertTrue(passes(key(code), through: engine)) } // g k j [ j
        XCTAssertFalse(passes(key(49), through: engine), "the first word after the click is fixed")
    }

    func testUnreadableCaretAfterClickLeavesShortOrLateWordsAlone() throws {
        let engine = try wrongLayoutEngine(["привет", "во"])
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        // A two-letter token may be the tail of a word the click landed in.
        XCTAssertNotNil(engine.handle(type: .leftMouseDown, event: click))
        engine.caretUnreadableAfterClick(clickRevision: engine.clickRevision)
        for code: UInt16 in [2, 38] { XCTAssertTrue(passes(key(code), through: engine)) } // d j
        XCTAssertTrue(passes(key(49), through: engine))
        // An answer that arrives after the first key is ignored.
        XCTAssertNotNil(engine.handle(type: .leftMouseDown, event: click))
        let revision = engine.clickRevision
        XCTAssertTrue(passes(key(5), through: engine))
        engine.caretUnreadableAfterClick(clickRevision: revision)
        for code: UInt16 in [4, 11, 2, 17, 45] { XCTAssertTrue(passes(key(code), through: engine)) }
        XCTAssertTrue(passes(key(49), through: engine))
    }

    func testDeadApostropheOfUSInternationalKeepsTheWord() throws {
        let engine = try wrongLayoutEngine(["это"])
        // U.S. International: "'" is a dead key (no text), the next key delivers "'n".
        XCTAssertTrue(passes(key(39, text: ""), through: engine))
        XCTAssertTrue(passes(key(45, text: "'n"), through: engine))
        XCTAssertTrue(passes(key(38, text: "j"), through: engine))
        XCTAssertEqual(engine.trackedWordLength, 3)
        XCTAssertFalse(passes(key(49, text: " "), through: engine), "'nj is это")
    }
}
