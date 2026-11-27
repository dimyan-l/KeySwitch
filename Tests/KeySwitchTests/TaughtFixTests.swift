import XCTest
import CoreGraphics
@testable import KeySwitch

/// Right ⌥ fixes are remembered: the same word is fixed by itself the next time.
final class TaughtFixTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeEngine(store: UserStore, settings: Settings = .shared,
                            eventSink: @escaping (CGEvent) -> Void = { _ in }) throws -> (SwitchEngine, DispatchQueue) {
        let queue = DispatchQueue(label: "test.taught.\(UUID().uuidString)")
        let typer = Typer(queue: queue, eventSink: eventSink)
        let engine = SwitchEngine(layouts: KeyboardLayouts(), store: store, typer: typer, settings: settings,
                                  frontmostPID: { 123 })
        engine.classifier = try Classifier.load(dictionaryDir: root.appendingPathComponent("Resources/Dictionaries"),
                                                userDir: nil, learned: [:])
        return (engine, queue)
    }

    private func fix(_ word: String, _ lang: Lang, _ result: String, _ resultLang: Lang) -> TaughtFix {
        TaughtFix(word: word, lang: lang, result: result, resultLang: resultLang, modified: Date())
    }

    // MARK: - Matching

    func testLayoutFixKeepsPunctuationAndTypedCapitals() {
        let fixes = [fix("ghbdtn", .en, "привет", .ru)].reduce(into: [String: TaughtFix]()) { $0[$1.id] = $1 }
        let readings = ["Ghbdtn,": "Привет,", "ghbdtn": "привет"]
        for (typed, expected) in readings {
            let flipped: [Character] = Array(expected)
            let r = TaughtFixes.replacement(for: typed, lang: .en, lookup: { fixes[$0] },
                                            flip: { range, _ in String(flipped[range]) })
            XCTAssertEqual(r?.text, expected, typed)
            XCTAssertEqual(r?.isLayoutFlip, true)
        }
        XCTAssertNil(TaughtFixes.replacement(for: "ghbdtn", lang: .ru, lookup: { fixes[$0] }, flip: { _, _ in nil }),
                     "A fix belongs to the layout the word was typed in")
        XCTAssertNil(TaughtFixes.replacement(for: "ghbdtns", lang: .en, lookup: { fixes[$0] }, flip: { _, _ in nil }),
                     "Only the exact word, never a longer one")
    }

    func testPunctuationKeysThatAreLettersStayPartOfTheWord() {
        let fixes = [fix("k.,k.", .en, "люблю", .ru)].reduce(into: [String: TaughtFix]()) { $0[$1.id] = $1 }
        let r = TaughtFixes.replacement(for: "k.,k.", lang: .en, lookup: { fixes[$0] },
                                        flip: { range, _ in String(Array("люблю")[range]) })
        XCTAssertEqual(r?.text, "люблю")
    }

    func testSpellingFixFollowsTheTypedCase() {
        let fixes = [fix("превет", .ru, "привет", .ru)].reduce(into: [String: TaughtFix]()) { $0[$1.id] = $1 }
        for (typed, expected) in ["превет": "привет", "Превет.": "Привет.", "ПРЕВЕТ": "ПРИВЕТ"] {
            let r = TaughtFixes.replacement(for: typed, lang: .ru, lookup: { fixes[$0] }, flip: { _, _ in nil })
            XCTAssertEqual(r?.text, expected, typed)
            XCTAssertEqual(r?.isLayoutFlip, false)
        }
        XCTAssertNil(TaughtFixes.replacement(for: "пРеВеТ", lang: .ru, lookup: { fixes[$0] }, flip: { _, _ in nil }))
    }

    // MARK: - Storage

    func testTaughtFixesSurviveRelaunchAndCanBeForgotten() {
        let directory = makeDirectory()
        let store = UserStore(directory: directory, bundledRulesURL: nil)
        store.addTaughtFix(fix("Ghbdtn", .en, "привет", .ru))
        store.flushPendingWrites()
        let reopened = UserStore(directory: directory, bundledRulesURL: nil)
        XCTAssertEqual(reopened.taughtFix("ghbdtn", lang: .en)?.result, "привет")
        reopened.removeTaughtFix("GHBDTN", lang: .en)
        reopened.flushPendingWrites()
        XCTAssertNil(UserStore(directory: directory, bundledRulesURL: nil).taughtFix("ghbdtn", lang: .en))
    }

    func testOlderFilesWithoutTaughtFixesStillLoad() throws {
        let directory = makeDirectory()
        let legacy = #"{"learned":{"ru":["созвон"]},"pinned":[],"rules":[],"localFormat":"referenceDate-v1"}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("learned.json"))
        let store = UserStore(directory: directory, bundledRulesURL: nil)
        XCTAssertNil(store.saveError)
        XCTAssertEqual(store.learned[.ru], ["созвон"])
        XCTAssertTrue(store.taughtFixes.isEmpty)
    }

    // MARK: - Teaching

    func testManualLayoutFixIsRememberedAndAnAccidentalFlipIsNot() throws {
        let store = UserStore(directory: makeDirectory(), bundledRulesURL: nil)
        let (engine, _) = try makeEngine(store: store)
        XCTAssertTrue(engine.teach(typed: "ghbdtn,", lang: .en, result: "привет,", resultLang: .ru))
        XCTAssertEqual(store.taughtFix("ghbdtn", lang: .en)?.result, "привет", "Edge punctuation is not part of the word")

        // Tapping on a real word by accident must not teach its gibberish reading.
        XCTAssertFalse(engine.teach(typed: "привет", lang: .ru, result: "ghbdtn", resultLang: .en))
        // ...but switching it back forgets the earlier fix.
        XCTAssertNil(store.taughtFix("ghbdtn", lang: .en))
    }

    func testTeachingReplacesAnEarlierUndoException() throws {
        let store = UserStore(directory: makeDirectory(), bundledRulesURL: nil)
        let (engine, _) = try makeEngine(store: store)
        store.addRule("ghbdtn", lang: .en, kind: .layout, source: .undo)
        XCTAssertTrue(store.rules.blocks("ghbdtn", lang: .en, kind: .layout))
        XCTAssertTrue(engine.teach(typed: "ghbdtn", lang: .en, result: "привет", resultLang: .ru))
        XCTAssertFalse(store.rules.blocks("ghbdtn", lang: .en, kind: .layout), "Your latest decision wins")
    }

    func testRevertingAFixForgetsIt() throws {
        let store = UserStore(directory: makeDirectory(), bundledRulesURL: nil)
        let (engine, _) = try makeEngine(store: store)
        XCTAssertTrue(engine.teach(typed: "ghbdtn", lang: .en, result: "привет", resultLang: .ru))
        let record = CorrectionRecord(replacement: "привет", original: "ghbdtn", lang: .en, originalWord: "ghbdtn",
                                      kind: .layout, automatic: true, date: Date())
        engine.remember(record, source: .undo)
        XCTAssertNil(store.taughtFix("ghbdtn", lang: .en))
        XCTAssertTrue(store.rules.blocks("ghbdtn", lang: .en, kind: .layout))
    }

    /// The whole loop on the keyboard: the word is fixed by itself after it was taught once.
    func testTaughtWordIsFixedAutomaticallyAfterSpace() throws {
        let layouts = KeyboardLayouts()
        let source = layouts.current()
        let language = try XCTUnwrap(source.lang)
        let typedWord = language == .en ? "kswtyped" : "ксвнабор"
        let taughtWord = language == .en ? "keyswitch" : "переключатель"
        let codes = try typedWord.map { letter in
            try XCTUnwrap((UInt16(0)...50).first {
                layouts.character(Stroke(keyCode: $0, shift: false, caps: false), layout: source.layout) == String(letter)
            })
        }
        let suite = "test.taught.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        // The runner may have one layout only: let the word be checked at all through the
        // spelling switch. The word is unknown to the typo corrector, so the fix is the taught one.
        settings.autoEnabled = false
        settings.spellEnabled = true

        var typed = ""
        var backspaces = 0
        let done = expectation(description: "taught replacement typed")
        let store = UserStore(directory: makeDirectory(), bundledRulesURL: nil)
        let (engine, queue) = try makeEngine(store: store, settings: settings, eventSink: { event in
            guard event.type == .keyDown else { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 51 { backspaces += 1; return }
            if code == 49 { done.fulfill(); return }
            var units = [UniChar](repeating: 0, count: 32)
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            typed += String(decoding: units.prefix(length), as: UTF16.self)
        })
        XCTAssertTrue(engine.teach(typed: typedWord, lang: language, result: taughtWord, resultLang: language))

        queue.suspend()
        for code in codes {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            XCTAssertNotNil(engine.handle(type: .keyDown, event: event), "Letters pass through")
        }
        let space = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
        XCTAssertNil(engine.handle(type: .keyDown, event: space), "Space is held until the word is fixed")
        queue.resume()
        wait(for: [done], timeout: 3)

        let common = zip(typedWord, taughtWord).prefix { $0.0 == $0.1 }.count
        XCTAssertEqual(backspaces, typedWord.count - common)
        XCTAssertEqual(typed, String(taughtWord.dropFirst(common)))
        XCTAssertEqual(engine.recentCorrection(producing: taughtWord)?.original, typedWord)
    }
}
