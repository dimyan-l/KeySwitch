import Foundation

/// Mirrors proto/classifier.py test cases. Uses a fixed ЙЦУКЕН↔QWERTY letter map, so it runs anywhere.
enum SelfTest {
    static let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    static let ru = Array("йцукенгшщзхъфывапролджэячсмитьбюё")

    static func flip(_ s: String, to: Lang) -> String {
        let (from, dst) = to == .ru ? (en, ru) : (ru, en)
        return String(s.map { ch in from.firstIndex(of: ch).map { dst[$0] } ?? ch })
    }

    /// Typo fixer: a few hand cases, then single-edit typos made from the 4000 most frequent words.
    /// "wrong" (fixed to a different word) is the number that matters; "left" is just a missed fix.
    static func spelling(_ c: Classifier) {
        let cases: [(String, Lang, String?)] = [
            ("превет", .ru, "привет"), ("севодня", .ru, "сегодня"), ("спосибо", .ru, "спасибо"),
            ("recieve", .en, "receive"), ("definately", .en, "definitely"),
            ("деплой", .ru, nil), ("привет", .ru, nil), ("hubspot", .en, nil), ("sql", .en, nil),
            ("Превет", .ru, nil), ("ПРЕВЕТ", .ru, nil), ("kubernetes", .en, nil), ("терраформ", .ru, nil),
            // Real forms missing from the 80 000-word list: the morphological check keeps them.
            ("выставь", .ru, nil),
        ]
        var ok = 0
        for (typed, lang, expected) in cases {
            guard let m = c.models[lang] else { continue }
            let alt = flip(typed, to: lang.other)
            let got = SpellCorrector.correction(for: typed, altReading: alt, model: m, other: c.models[lang.other])
            let pass = got == expected
            if pass { ok += 1 }
            print("\(pass ? "✓" : "✗") орфография \(typed.padding(toLength: 11, withPad: " ", startingAt: 0)) → \(got ?? "(без изменений)")")
        }
        print("Орфография, ручные случаи: \(ok)/\(cases.count)")

        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for lang in Lang.allCases {
            guard let m = c.models[lang], let other = c.models[lang.other] else { continue }
            let top = m.words.filter { $0.key.count >= 5 && $0.key.allSatisfy { m.letters.contains($0) } }
                .sorted { $0.value > $1.value }.prefix(4000).map(\.key)
            let letters = Array(m.letters)
            var right = 0, wrong = 0, left = 0, total = 0
            for w in top {
                var ch = Array(w)
                let i = 1 + rnd(ch.count - 2)
                switch rnd(3) {
                case 0: ch.swapAt(i, i + 1)
                case 1: ch.remove(at: i)
                default: ch[i] = letters[rnd(letters.count)]
                }
                let typo = String(ch)
                guard typo != w, m.score(typo) == nil else { continue }
                total += 1
                let alt = flip(typo, to: lang.other)
                if let fixed = SpellCorrector.correction(for: typo, altReading: alt, model: m, other: other) {
                    if fixed == w { right += 1 } else { wrong += 1 }
                } else { left += 1 }
            }
            print("Орфография \(lang.label): опечаток \(total), исправлено верно \(right), неверно \(wrong), оставлено \(left)")
        }
    }

    /// Sentence context: the previous word's language tips doubtful words and lone letters, nothing else.
    static func contextChecks(_ c: Classifier) {
        let checks: [(String, Bool)] = [
            ("контекст: одна «d» без контекста остаётся", !c.decide(current: "d", alternative: "в", currentLang: .en).convert),
            ("контекст: «d» после русского слова → «в»", c.decide(current: "d", alternative: "в", currentLang: .en, contextLang: .ru).convert),
            ("контекст: «a» после английского слова остаётся", !c.decide(current: "a", alternative: "ф", currentLang: .en, contextLang: .en).convert),
            ("контекст: «привет» после английского слова остаётся", !c.decide(current: "привет", alternative: "ghbdtn", currentLang: .ru, contextLang: .en).convert),
            ("контекст: «sql» после русского слова остаётся", !c.decide(current: "sql", alternative: "ыйд", currentLang: .en, contextLang: .ru).convert),
        ]
        for (name, ok) in checks where !ok { print("✗ \(name)") }
        print("Контекст: \(checks.filter(\.1).count)/\(checks.count)")
    }

    /// The Caps Lock fix: pure logic, no keyboard needed.
    static func capsChecks() {
        var checks: [(String, Bool)] = []
        let slip = [Stroke(keyCode: 5, shift: true, caps: true), Stroke(keyCode: 4, shift: false, caps: true), Stroke(keyCode: 11, shift: false, caps: true)]
        let allCaps = slip.map { Stroke(keyCode: $0.keyCode, shift: false, caps: true) }
        let normal = [Stroke(keyCode: 5, shift: true, caps: false), Stroke(keyCode: 4, shift: false, caps: false)]
        checks.append(("Caps Lock: пРИВЕТ распознаётся", SwitchEngine.isCapsSlip(slip)))
        checks.append(("Caps Lock: ПРИВЕТ капсом не трогается", !SwitchEngine.isCapsSlip(allCaps)))
        checks.append(("Caps Lock: обычное «Привет» не трогается", !SwitchEngine.isCapsSlip(normal)))
        checks.append(("Caps Lock: исправление — Shift только на первой", SwitchEngine.unslipped(slip).map(\.shift) == [true, false, false] && !SwitchEngine.unslipped(slip).contains(where: \.caps)))
        let dbl = [Stroke(keyCode: 5, shift: true, caps: false), Stroke(keyCode: 4, shift: true, caps: false), Stroke(keyCode: 11, shift: false, caps: false)]
        checks.append(("Две заглавные: ПРи → При", SwitchEngine.doubleCapitalFixed(dbl)?.map(\.shift) == [true, false, false]))
        checks.append(("Две заглавные: ПРИ (аббревиатура) не трогается", SwitchEngine.doubleCapitalFixed(dbl.map { Stroke(keyCode: $0.keyCode, shift: true, caps: false) }) == nil))
        checks.append(("Две заглавные: два символа не трогаются", SwitchEngine.doubleCapitalFixed(Array(dbl.prefix(2))) == nil))
        for (name, ok) in checks where !ok { print("✗ \(name)") }
        print("Регистр: \(checks.filter(\.1).count)/\(checks.count)")
    }

    /// Waits for the store's background writes and their main-thread callbacks.
    private static func settle(_ store: UserStore) {
        store.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// "Не исправлять" rules: one refusal is enough, survives a restart, beats the dictionary,
    /// is exact (no substrings, no other words), and comes off cleanly.
    static func ruleChecks(_ c: Classifier) -> (Int, Int) {
        var checks: [(String, Bool)] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyswitch-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ru = c.models[.ru], let en = c.models[.en] else { return (0, 1) }
        let spell = { (w: String) in SpellCorrector.correction(for: w, altReading: flip(w, to: .en), model: ru, other: en) }

        let before = spell("внось")
        checks.append(("правила: без правила «внось» → «вновь» (воспроизведение ошибки)", before == "вновь"))

        let store = UserStore(directory: dir)
        var saved: Bool?
        store.addRule("внось", lang: .ru, kind: .spell, result: "вновь", source: .undo) { saved = $0 }
        checks.append(("правила: действует сразу, до записи на диск", store.rules.blocks("внось", lang: .ru, kind: .spell)))
        settle(store)
        checks.append(("правила: запись подтверждена", saved == true && store.saveError == nil))
        // The engine checks the rule before the typo fixer: ten more times, the same answer.
        checks.append(("правила: 10 повторов «внось» не исправляются", (0..<10).allSatisfy { _ in store.rules.blocks("Внось", lang: .ru, kind: .spell) }))
        checks.append(("правила: отказ от опечатки не отключает раскладку", !store.rules.blocks("внось", lang: .ru, kind: .layout)))
        checks.append(("правила: только это слово, не подстрока", !store.rules.blocks("вно", lang: .ru, kind: .spell) && !store.rules.blocks("вносьте", lang: .ru, kind: .spell)))
        checks.append(("правила: другой язык не затронут", !store.rules.blocks("внось", lang: .en, kind: .spell)))
        checks.append(("правила: ghbdtn → привет по-прежнему", c.decide(current: "ghbdtn", alternative: "привет", currentLang: .en).convert && !store.rules.blocks("ghbdtn", lang: .en, kind: .layout)))

        let restarted = UserStore(directory: dir)
        checks.append(("правила: переживают перезапуск", restarted.rules.blocks("внось", lang: .ru, kind: .spell)))
        let reloaded = try? Classifier.load(dictionaryDir: Resources.dictionaryDirectory!, userDir: dir, learned: restarted.learned)
        checks.append(("правила: не зависят от пересоздания словарей", reloaded != nil && restarted.rules.blocks("внось", lang: .ru, kind: .spell)))

        // A protected word: every kind of change.
        restarted.addRule("выставь", lang: .ru, kind: nil, result: nil, source: .manual)
        checks.append(("правила: «Не исправлять слово» закрывает все виды", FixKind.allCases.allSatisfy { restarted.rules.blocks("выставь", lang: .ru, kind: $0) }))
        settle(restarted)

        // Remove: back to standard behaviour, and the deletion is not undone by another Mac's older copy.
        // Another Mac learned the same rule before we deleted it here, and still has it.
        let other = dir.appendingPathComponent("other", isDirectory: true)
        let mac2 = UserStore(directory: other)
        mac2.addRule("внось", lang: .ru, kind: .spell, result: "вновь", source: .undo)
        mac2.addRule("ру", lang: .ru, kind: nil, result: nil, source: .manual)
        settle(mac2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        restarted.removeRule(UserRule.key("внось", .ru, .spell))
        settle(restarted)
        checks.append(("правила: удаление возвращает обычное поведение", !restarted.rules.blocks("внось", lang: .ru, kind: .spell) && spell("внось") == before))
        UserStore.merge(from: dir, into: other)
        let merged = UserStore(directory: other)
        checks.append(("iCloud: удалённое правило не воскресает при слиянии", !merged.rules.blocks("внось", lang: .ru, kind: .spell) && merged.rules.blocks("ру", lang: .ru, kind: .layout)))
        UserStore.merge(from: other, into: dir)
        let back = UserStore(directory: dir)
        checks.append(("iCloud: слияние в обе стороны", back.rules.blocks("ру", lang: .ru, kind: .spell) && back.rules.blocks("выставь", lang: .ru, kind: .spell) && !back.rules.blocks("внось", lang: .ru, kind: .spell)))

        // A failed write: protects this session, never claims to be saved, and is kept through a reload.
        back.simulateWriteFailure = true
        var failed: Bool?
        back.addRule("гугл", lang: .ru, kind: nil, result: nil, source: .undo) { failed = $0 }
        settle(back)
        checks.append(("сбой записи: нет ложного «сохранено»", failed == false && back.saveError != nil))
        checks.append(("сбой записи: правило действует в этой сессии", back.rules.blocks("гугл", lang: .ru, kind: .layout)))
        back.reload()
        checks.append(("сбой записи: перезагрузка не теряет правило", back.rules.blocks("гугл", lang: .ru, kind: .layout)))
        back.simulateWriteFailure = false
        var retried: Bool?
        back.retrySave { retried = $0 }
        settle(back)
        checks.append(("сбой записи: повтор записывает", retried == true && UserStore(directory: dir).rules.blocks("гугл", lang: .ru, kind: .layout)))

        // Words learned by 0.1.0 become visible rules without losing the learned list.
        let legacy = dir.appendingPathComponent("legacy", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try? #"{"learned":{"ru":["шь"],"en":["spbdev"]}}"#.write(to: legacy.appendingPathComponent("learned.json"), atomically: true, encoding: .utf8)
        let migrated = UserStore(directory: legacy)
        settle(migrated)
        let again = UserStore(directory: legacy)
        checks.append(("миграция: выученные слова стали правилами", again.rules.blocks("spbdev", lang: .en, kind: .layout) && again.rules.active.contains { $0.source == .migrated }))
        checks.append(("миграция: список выученных сохранён", again.learned[.en] == ["spbdev"] && again.learned[.ru] == ["шь"]))
        again.removeRule(UserRule.key("spbdev", .en, nil))
        settle(again)
        let third = UserStore(directory: legacy)
        checks.append(("миграция: удалённое правило не создаётся снова", !third.rules.blocks("spbdev", lang: .en, kind: .layout) && third.learned[.en]?.isEmpty != false))

        for (name, ok) in checks { print("\(ok ? "✓" : "✗") \(name)") }
        print("Правила: \(checks.filter(\.1).count)/\(checks.count)")
        return (checks.filter(\.1).count, checks.count)
    }

    /// Recognizing your own restore in the field text, punctuation at word edges, undo after Enter.
    static func editChecks(_ c: Classifier) -> (Int, Int) {
        var checks: [(String, Bool)] = []
        // Our fix "вновь" sits at offset 12 in "Пожалуйста, вновь изменения."
        let fixed = "Пожалуйста, вновь изменения."
        let at = FieldProbe.lastWholeWord("вновь", in: fixed)
        checks.append(("поле: найдено место исправления", at == 12))
        let spot = at ?? 0
        checks.append(("поле: выделили и набрали своё слово", FieldProbe.token(in: "Пожалуйста, внось изменения.", at: spot) == "внось"))
        checks.append(("поле: заменили одну букву внутри", FieldProbe.token(in: "Пожалуйста, внось изменения.", at: spot) == "внось"))
        checks.append(("поле: ⌘Z не вернул слово — нет правила", FieldProbe.token(in: "Пожалуйста,  изменения.", at: spot) == nil))
        checks.append(("поле: третье слово — не исходное", FieldProbe.token(in: "Пожалуйста, внеси изменения.", at: spot) == "внеси"))
        checks.append(("поле: «вновь» внутри другого слова не находится", FieldProbe.lastWholeWord("вновь", in: "сновавновь ") == nil))

        let enChars = Array("ghbdtn."), ruChars = Array("приветю")
        let e1 = SwitchEngine.edgePunctuation(cur: enChars.map(String.init), alt: ruChars.map(String.init))
        checks.append(("пунктуация: «ghbdtn.» — точка вне слова", e1.lead == 0 && e1.trail == 1))
        let e2 = SwitchEngine.edgePunctuation(cur: Array("ghbdtn,").map(String.init), alt: Array("приветб").map(String.init))
        checks.append(("пунктуация: «ghbdtn,» — запятая вне слова", e2.trail == 1))
        let e3 = SwitchEngine.edgePunctuation(cur: Array("k.,k.").map(String.init), alt: Array("люблю").map(String.init))
        checks.append(("пунктуация: «k.,k.» — б/ю внутри слова остаются буквами", e3.lead == 0 && e3.trail == 1 && c.models[.ru]?.score("люблю") != nil))
        let e4 = SwitchEngine.edgePunctuation(cur: Array("\"ghbdtn").map(String.init), alt: Array("Эпривет").map(String.init))
        checks.append(("пунктуация: кавычка в начале", e4.lead == 1 && e4.trail == 0))
        checks.append(("пунктуация: «ghbdtn» без точки → «привет»", c.decide(current: "ghbdtn", alternative: "привет", currentLang: .en).convert))

        checks.append(("Enter: отмена недоступна", !SwitchEngine.isUndoable(Stroke(keyCode: 36, shift: false, caps: false))))
        checks.append(("Tab: отмена недоступна", !SwitchEngine.isUndoable(Stroke(keyCode: 48, shift: false, caps: false))))
        checks.append(("Пробел: отмена доступна", SwitchEngine.isUndoable(Stroke(keyCode: 49, shift: false, caps: false))))

        for (name, ok) in checks { print("\(ok ? "✓" : "✗") \(name)") }
        print("Правка в поле, пунктуация, Enter: \(checks.filter(\.1).count)/\(checks.count)")
        return (checks.filter(\.1).count, checks.count)
    }

    static func run() {
        guard let dir = Resources.dictionaryDirectory else {
            print("Словари не найдены. Запускайте из папки проекта или из KeySwitch.app."); return
        }
        let t0 = Date()
        let c: Classifier
        do { c = try Classifier.load(dictionaryDir: dir, userDir: nil, learned: [:]) } catch { print("Ошибка: \(error)"); return }
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
        ]
        var ok = 0
        for (typed, lang, expected) in cases {
            let alt = flip(typed, to: lang.other)
            let d = c.decide(current: typed, alternative: alt, currentLang: lang)
            let got: String? = d.convert ? alt : nil
            let pass = got == expected
            if pass { ok += 1 }
            print("\(pass ? "✓" : "✗") \(typed.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(got ?? "(без изменений)")  [\(d.reason)]")
        }
        spelling(c)
        capsChecks()
        contextChecks(c)
        let rules = ruleChecks(c)
        let edits = editChecks(c)
        let typing = typingChecks(c)
        let t1 = Date()
        for _ in 0..<10_000 { _ = c.decide(current: "ghbdtnbr", alternative: "приветик", currentLang: .en) }
        print(String(format: "Скорость: %.1f мкс на слово", Date().timeIntervalSince(t1) / 10_000 * 1_000_000))
        // build_app.sh refuses to install unless every case here passes.
        print("Итог: \(ok + rules.0 + edits.0 + typing.0)/\(cases.count + rules.1 + edits.1 + typing.1)")
    }
}
