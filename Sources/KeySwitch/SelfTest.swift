import Foundation

/// Mirrors tools/classifier.py test cases with a fixed ЙЦУКЕН↔QWERTY map.
enum SelfTest {
    static let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    static let ru = Array("йцукенгшщзхъфывапролджэячсмитьбюё")

    static func flip(_ s: String, to: Lang) -> String {
        let (from, dst) = to == .ru ? (en, ru) : (ru, en)
        return String(s.map { ch in from.firstIndex(of: ch).map { dst[$0] } ?? ch })
    }

    @discardableResult
    static func run() -> Bool {
        guard let dir = Resources.dictionaryDirectory else {
            print("Словари не найдены. Запускайте из папки проекта или из KeySwitch.app."); return false
        }
        let t0 = Date()
        let c: Classifier
        do { c = try Classifier.load(dictionaryDir: dir, userDir: nil, learned: [:]) } catch { print("Ошибка: \(error)"); return false }
        print(String(format: "Словари загружены за %.2f c: ru %d слов, en %d слов", Date().timeIntervalSince(t0),
                     c.models[.ru]!.words.count, c.models[.en]!.words.count))
        // (typed, layout it was typed in, expected result or nil = leave as is)
        let cases: [(String, Lang, String?)] = [
            ("ghbdtn", .en, "привет"), ("ytn", .en, "нет"), ("rfr", .en, "как"), ("nj", .en, "то"),
            ("ds", .en, "вы"), ("he", .en, nil), ("ok", .en, nil), ("sql", .en, nil), ("hubspot", .en, nil),
            ("cjpdjy", .en, "созвон"), ("ltgkjq", .en, "деплой"), ("fencnfaa", .en, "аутстафф"),
            ("ифслгз", .ru, "backup"), ("ыйд", .ru, "sql"), ("руддщ", .ru, "hello"), ("щл", .ru, "ok"),
            ("ьшпкфешщт", .ru, "migration"), ("rjnjhsq", .en, "который"), ("linkedin", .en, nil),
            ("slack", .en, nil), ("ntvf", .en, "тема"), ("pfghjc", .en, "запрос"), ("привет", .ru, nil),
            ("база", .ru, nil), ("server", .en, nil), ("сервер", .ru, nil), ("dthcbz", .en, "версия"),
            ("ghbdtn.", .en, "привет."), ("ghbdtn,", .en, "привет,"),
            ("ghbdtn...", .en, "привет..."), ("lfnf,fpf", .en, "датабаза"),
        ]
        var ok = 0
        for (typed, lang, expected) in cases {
            let alt = flip(typed, to: lang.other)
            let plan = c.plan(current: typed, alternative: alt, currentLang: lang)
            let got: String? = plan.decision.convert ? plan.alternativeWord + plan.suffix : nil
            let pass = got == expected
            if pass { ok += 1 }
            print("\(pass ? "✓" : "✗") \(typed.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(got ?? "(без изменений)")  [\(plan.decision.reason)]")
        }
        let t1 = Date()
        for _ in 0..<10_000 { _ = c.decide(current: "ghbdtnbr", alternative: "приветик", currentLang: .en) }
        print(String(format: "Скорость: %.1f мкс на слово", Date().timeIntervalSince(t1) / 10_000 * 1_000_000))
        let t2 = Date()
        for _ in 0..<500 {
            _ = SpellCorrector.correction(for: "abcdefghijklmnop", alternative: "",
                                          model: c.models[.en]!, other: c.models[.ru])
        }
        print(String(format: "Проверка опечатки (16 букв): %.1f мкс", Date().timeIntervalSince(t2) / 500 * 1_000_000))
        let manual = SelectionCandidates.make(for: "Превет", classifier: c, preferred: .ru, flip: nil)
        let caseChoices = SelectionCandidates.make(for: "привет", classifier: c, preferred: .ru, flip: nil)
        guard manual.contains("Привет"), manual.count <= 3,
              caseChoices.contains("Привет"), caseChoices.contains("ПРИВЕТ") else {
            print("✗ Варианты для выделенного слова: \(manual), \(caseChoices)")
            return false
        }
        print("Итог: \(ok)/\(cases.count)")
        return ok == cases.count
    }
}
