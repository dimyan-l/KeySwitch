import CoreGraphics
import XCTest
@testable import KeySwitchES

final class LayoutTransitionTests: XCTestCase {
    private let en = KeyboardLayouts.Source(ref: nil, id: "en", lang: .en, layout: Data([0]))
    private let es = KeyboardLayouts.Source(ref: nil, id: "es", lang: .es, layout: Data([1]))

    private func layouts(readSource: @escaping () -> KeyboardLayouts.Source,
                         requestSource: ((KeyboardLayouts.Source) -> Bool)? = nil) -> KeyboardLayouts {
        KeyboardLayouts(sources: [.en: en, .es: es], readSource: readSource, requestSource: requestSource) { [es] stroke, data in
            if stroke.keyCode == 41 { return data == es.layout ? "ñ" : ";" }
            let sharedKeys: [UInt16: String] = [0: "a", 4: "h", 31: "o", 34: "i", 37: "l", 45: "n"]
            return sharedKeys[stroke.keyCode] ?? ""
        }
    }

    private func key(_ code: UInt16, text: String = "") -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        return event
    }

    private func engine(layouts: KeyboardLayouts, typer: Typer, protectedInput: @escaping () -> Bool = { false }) -> SwitchEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let english = LanguageModel(lang: .en)
        let spanish = LanguageModel(lang: .es)
        spanish.add("hola", score: 8)
        spanish.add("niño", score: 8)
        let suite = "keyswitches.layout-transition.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let engine = SwitchEngine(layouts: layouts, store: UserStore(directory: dir, bundledRulesURL: nil),
                                  typer: typer, settings: Settings(defaults: defaults), frontmostPID: { 123 }, protectedInput: protectedInput)
        engine.classifier = Classifier(models: [.en: english, .es: spanish])
        return engine
    }

    func testSharedKeysChangeLayoutWithoutDeletingWord() {
        var current = en
        var posted: [Int64] = []
        let selected = expectation(description: "switch once after the word and space")
        let layouts = layouts(readSource: { current }, requestSource: { source in
            current = source
            selected.fulfill()
            return true
        })
        let engine = engine(layouts: layouts, typer: Typer(eventSink: {
            posted.append($0.getIntegerValueField(.keyboardEventKeycode))
        }))

        for code: UInt16 in [4, 31, 37, 0] { // hola
            XCTAssertNotNil(engine.handle(type: .keyDown, event: key(code)))
            XCTAssertFalse(engine.isTyping)
            XCTAssertEqual(current.id, en.id)
        }
        XCTAssertNil(engine.handle(type: .keyDown, event: key(49)))
        wait(for: [selected], timeout: 2)
        XCTAssertEqual(posted, [49, 49])
        XCTAssertEqual(current.id, es.id)
    }

    func testSourceChangeBeforeNotificationDiscardsUnfinishedWord() {
        var current = en
        let layouts = layouts(readSource: { current })
        let engine = engine(layouts: layouts, typer: Typer(eventSink: { _ in XCTFail("Must not rewrite an unfinished word") }))

        XCTAssertNotNil(engine.handle(type: .keyDown, event: key(45, text: "n")))
        XCTAssertEqual(engine.trackedWordLength, 1)
        current = es
        XCTAssertNotNil(engine.handle(type: .keyDown, event: key(41, text: "ñ")))
        XCTAssertEqual(engine.trackedWordLength, 0)
        XCTAssertNotNil(engine.handle(type: .keyDown, event: key(49)))
        XCTAssertNotNil(engine.handle(type: .keyDown, event: key(41, text: "ñ")))
        XCTAssertEqual(engine.trackedWordLength, 1)
    }

    func testSecureInputCancelsTrackedWordsWithoutChangingText() {
        var secure = false
        let layouts = layouts(readSource: { self.en })
        let engine = engine(layouts: layouts, typer: Typer(eventSink: { _ in XCTFail("Must not write in Secure Input") }),
                            protectedInput: { secure })

        for code: UInt16 in [45, 34, 41, 31] { // ni;o
            XCTAssertNotNil(engine.handle(type: .keyDown, event: key(code)))
        }
        XCTAssertEqual(engine.trackedWordLength, 4)
        secure = true
        XCTAssertNotNil(engine.handle(type: .keyDown, event: key(49)))
        XCTAssertEqual(engine.trackedWordLength, 0)
    }
}
