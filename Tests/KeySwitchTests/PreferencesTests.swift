import XCTest
@testable import KeySwitch

final class PreferencesTests: XCTestCase {
    func testApplicationModesKeepLegacyExclusionsAndPersistOverrides() throws {
        let suite = "test.applicationModes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let terminal = "com.apple.Terminal"
        let browser = "com.example.browser"
        XCTAssertEqual(settings.applicationMode(for: terminal), .off)
        settings.setApplicationMode(.manual, for: terminal)
        settings.setApplicationMode(.confirm, for: browser)
        XCTAssertFalse(settings.isExcluded(terminal))
        XCTAssertFalse(settings.applicationMode(for: terminal).allowsAutomatic)
        XCTAssertTrue(Settings(defaults: defaults).applicationMode(for: browser).isCautious(defaultValue: false))
        settings.setApplicationMode(.inherit, for: terminal)
        XCTAssertTrue(settings.isExcluded(terminal))
    }

    func testPrivacyDefaultsAreOffAndExplicitPreferencesSurvive() throws {
        let suite = "KeySwitchTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "unrelatedExistingPreference")
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.spellEnabled)
        XCTAssertFalse(settings.clipboardEnabled)
        settings.spellEnabled = true
        settings.clipboardEnabled = true
        let reloaded = Settings(defaults: defaults)
        XCTAssertTrue(reloaded.spellEnabled)
        XCTAssertTrue(reloaded.clipboardEnabled)
    }

    func testUnmarkedLocalReferenceDatesWithImportedMarkerAreNotConvertedTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = UserRule(word: "example", lang: .en, kind: nil, result: nil,
                            source: .manual, modified: Date(timeIntervalSinceReferenceDate: 750_000_000))
        let rawRule = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule))
        for importedMarker in [false, true] {
            let input: [String: Any] = ["rules": [rawRule], "rulesMigrated": importedMarker,
                                      "languages": ["ru", "en", "es"], "future": ["nested": [true, NSNull(), 42]],
                                      "learned": ["en": ["example"], "zz": ["untouched"]]]
            let url = directory.appendingPathComponent("learned.json")
            try JSONSerialization.data(withJSONObject: input).write(to: url)
            let store = UserStore(directory: directory, bundledRulesURL: nil)
            XCTAssertEqual(store.rules.byKey[rule.id], rule)
            store.learn("another", lang: .en)
            store.flushPendingWrites()
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(saved["rulesMigrated"] as? Bool, importedMarker)
            XCTAssertEqual(saved["languages"] as? [String], ["ru", "en", "es"])
            XCTAssertEqual(saved["future"] as? NSDictionary, input["future"] as? NSDictionary)
            XCTAssertEqual((saved["learned"] as? [String: [String]])?["zz"], ["untouched"])
            XCTAssertEqual(UserStore(directory: directory, bundledRulesURL: nil).rules.byKey[rule.id], rule)
        }
    }

    func testCloudDefaultDirectoryFailsClosedButExplicitDirectoriesIgnorePreferences() throws {
        let suite = "KeySwitchTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "iCloudSync")
        let blocked = UserStore(bundledRulesURL: nil, defaults: defaults)
        XCTAssertTrue(blocked.saveError?.contains("iCloudSync") == true)
        XCTAssertTrue(blocked.saveError?.contains("learned.json") == true)
        blocked.learn("mustnotwrite", lang: .en)
        blocked.flushPendingWrites()
        XCTAssertNotNil(blocked.saveError)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let explicit = UserStore(directory: directory, bundledRulesURL: nil, defaults: defaults)
        XCTAssertNil(explicit.saveError)
        explicit.learn("example", lang: .en)
        explicit.flushPendingWrites()
        XCTAssertEqual(UserStore(directory: directory, bundledRulesURL: nil).learned[.en], ["example"])
    }

    func testUpstreamUnixDatesMigrateWithoutChangingRuleChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        var rule = UserRule(word: "example", lang: .en, kind: .spell, result: "sample",
                            source: .manual, modified: date)
        rule.deleted = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let rawRule = try JSONSerialization.jsonObject(with: encoder.encode(rule))
        let input: [String: Any] = ["rules": [rawRule], "rulesMigrated": true]
        try JSONSerialization.data(withJSONObject: input).write(to: directory.appendingPathComponent("learned.json"))
        let store = UserStore(directory: directory, bundledRulesURL: nil)
        XCTAssertNil(store.saveError)
        XCTAssertEqual(store.rules.byKey[rule.id], rule)
        store.learn("another", lang: .en)
        store.flushPendingWrites()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("learned.json"))) as? [String: Any])
        XCTAssertEqual(saved["localFormat"] as? String, "referenceDate-v1")
        XCTAssertEqual(UserStore(directory: directory, bundledRulesURL: nil).rules.byKey[rule.id], rule)
    }

    func testBundledRulesNeverOverrideExistingDeletionDuringMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = root.appendingPathComponent("Resources/DefaultRules.json")
        let defaults = try JSONDecoder().decode([UserRule].self, from: Data(contentsOf: bundled))
        XCTAssertTrue(defaults.allSatisfy { $0.modified <= Date() }, "Bundled dates use Swift's reference epoch")
        // Older explicit deletion must also beat newer bundled defaults.
        var rule = try XCTUnwrap(defaults.first { $0.word == "itq" && $0.lang == .en })
        rule.deleted = true
        rule.modified = Date(timeIntervalSinceReferenceDate: 1)
        struct ExistingPayload: Encodable { let rules: [UserRule] }
        try JSONEncoder().encode(ExistingPayload(rules: [rule]))
            .write(to: directory.appendingPathComponent("learned.json"))
        let migrated = UserStore(directory: directory, bundledRulesURL: bundled)
        migrated.flushPendingWrites()
        XCTAssertFalse(migrated.rules.blocks("itq", lang: .en, kind: .layout))
        XCTAssertTrue(migrated.rules.byKey[rule.id]?.deleted == true)
    }

    func testDictionaryEditingCanBeUndoneWithoutLosingLearnedWord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UserStore(directory: dir, bundledRulesURL: nil)
        let model = PreferencesModel(store: store)
        store.learn("example", lang: .en)
        XCTAssertTrue(model.add("example", lang: .en, exception: true, kind: .spell))
        let rule = try XCTUnwrap(store.rules.active.first)
        model.remove(rule)
        XCTAssertFalse(store.rules.blocks("example", lang: .en, kind: .spell))
        XCTAssertTrue(store.learned[.en]?.contains("example") == true)
        model.undo()
        XCTAssertTrue(store.rules.blocks("example", lang: .en, kind: .spell))
        model.remove("example", lang: .en)
        XCTAssertFalse(store.learned[.en]?.contains("example") == true)
        model.undo()
        XCTAssertTrue(store.learned[.en]?.contains("example") == true)
        XCTAssertFalse(model.add("two words", lang: .en, exception: false, kind: nil))
        store.flushPendingWrites()
    }
}
