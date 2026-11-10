import Foundation

enum SelfTest {
    @discardableResult
    static func run() -> Bool {
        guard let dir = Resources.dictionaryDirectory else {
            print("Missing dictionaries. Run from the project directory or KeySwitchES.app.")
            return false
        }
        let classifier: Classifier
        do {
            classifier = try Classifier.load(dictionaryDir: dir, userDir: nil, learned: [:])
        } catch {
            print("Dictionary load failed: \(error)")
            return false
        }
        print("Loaded EN \(classifier.models[.en]!.words.count), ES \(classifier.models[.es]!.words.count) words")

        // current, physical-key alternative, active language, expected output;
        // nil means no switch. Equal current/alternative means only layout changes.
        let cases: [(String, String, Lang, String?)] = [
            ("hola", "hola", .en, "hola"),
            ("gracias", "gracias", .en, "gracias"),
            ("casa", "casa", .en, "casa"),
            ("hello", "hello", .es, "hello"),
            ("thanks", "thanks", .es, "thanks"),
            ("the", "the", .es, "the"),
            ("ni;o", "niño", .en, "niño"),
            ("house", "house", .en, nil),
            ("mañana", "mañana", .es, nil),
            ("a", "a", .en, nil),
            ("foobarqux", "foobarqux", .en, nil),
        ]
        var passed = 0
        for (current, alternative, lang, expected) in cases {
            let plan = classifier.plan(current: current, alternative: alternative, currentLang: lang)
            let got = plan.decision.convert ? plan.alternativeWord + plan.suffix : nil
            if got == expected { passed += 1 }
            print("\(got == expected ? "✓" : "✗") \(lang.label) \(current) → \(got ?? "unchanged") [\(plan.decision.reason)]")
        }
        let started = Date()
        for _ in 0..<500 {
            _ = SpellCorrector.correction(for: "abcdefghijklmnop", alternative: "",
                                          model: classifier.models[.en]!, other: classifier.models[.es])
        }
        print(String(format: "16-letter typo check: %.1f µs", Date().timeIntervalSince(started) / 500 * 1_000_000))
        let manual = SelectionCandidates.make(for: "recieve", classifier: classifier, preferred: .en, flip: nil)
        let spanish = SelectionCandidates.make(for: "gracais", classifier: classifier, preferred: .es, flip: nil)
        let caseChoices = SelectionCandidates.make(for: "hello", classifier: classifier, preferred: .en, flip: nil)
        guard manual.contains("receive"), manual.count <= 3,
              spanish.contains("gracias"), spanish.count <= 3,
              caseChoices.contains("Hello"), caseChoices.contains("HELLO") else {
            print("✗ Selection suggestions: \(manual), \(spanish), \(caseChoices)")
            return false
        }
        print("Result: \(passed)/\(cases.count)")
        return passed == cases.count
    }
}
