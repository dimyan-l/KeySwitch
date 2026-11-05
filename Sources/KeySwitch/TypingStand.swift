import AppKit

/// Offline typing stand for --selftest: the real engine, classifier, rules and your installed RU/EN layouts,
/// but keys go into a virtual text field instead of the system. Nothing is typed anywhere and your
/// macOS layout is not switched. What it cannot show: real apps' Accessibility, focus races, ⌘Z grouping.
final class TypingStand {
    private(set) var text: [Character] = []
    private var caret = 0
    private var selection: Range<Int>?
    let layouts = KeyboardLayouts()
    let engine: SwitchEngine
    private var keyFor: [Lang: [Character: Stroke]] = [:]

    init?(classifier: Classifier, store: UserStore) {
        guard layouts.hasBothLayouts else { return nil }
        layouts.simulated = .ru
        engine = SwitchEngine(layouts: layouts, store: store)
        engine.classifier = classifier
        engine.frontmostBundleID = "selftest.field"
        for lang in Lang.allCases {
            var m: [Character: Stroke] = [:]
            for shift in [true, false] {
                for code in UInt16(0)...50 where ![36, 48, 49].contains(code) {
                    let s = Stroke(keyCode: code, shift: shift, caps: false)
                    if let ch = layouts.character(s, in: lang).first { m[ch] = s }
                }
            }
            keyFor[lang] = m
        }
        engine.typer.sink = { [weak self] a in self?.apply(a) }
        focus()
    }

    /// This stand's field is the "focused field" the restore check reads.
    func focus() {
        FieldProbe.simulatedText = { [weak self] in String(self?.text ?? []) }
        FieldProbe.simulatedField = { [weak self] in
            guard let self else { return ("", 0, 0) }
            return (String(self.text), self.selection?.lowerBound ?? self.caret, self.selection?.count ?? 0)
        }
    }
    var caretOffset: Int { caret }

    var string: String { String(text) }
    var lang: Lang { layouts.simulated ?? .ru }
    func use(_ l: Lang) { layouts.simulated = l }

    // MARK: Field

    private func insert(_ s: String) {
        if let sel = selection { text.removeSubrange(sel); caret = sel.lowerBound; selection = nil }
        text.insert(contentsOf: Array(s), at: caret)
        caret += s.count
    }
    private func backspace() {
        if let sel = selection { text.removeSubrange(sel); caret = sel.lowerBound; selection = nil; return }
        guard caret > 0 else { return }
        text.remove(at: caret - 1); caret -= 1
    }
    private func apply(_ a: Typer.Action) {
        switch a {
        case .backspace(let n): for _ in 0..<n { backspace() }
        case .text(let s): insert(s)
        case .key(let code, _): insert(code == 36 || code == 76 ? "\n" : code == 48 ? "\t" : " ")
        case .forwardDelete(let n):
            if let sel = selection { text.removeSubrange(sel); caret = sel.lowerBound; selection = nil; return }
            for _ in 0..<n where caret < text.count { text.remove(at: caret) }
        case .left(let n): selection = nil; caret = max(0, caret - n)
        case .command, .pause: break
        }
    }

    // MARK: Input

    private func key(_ code: UInt16, shift: Bool = false, flags extra: CGEventFlags = [], deliver: () -> Void) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return }
        e.flags = (shift ? CGEventFlags.maskShift : CGEventFlags()).union(extra)
        if engine.handle(type: .keyDown, event: e) != nil { deliver() }
    }

    /// Types `s` key by key in the current layout, the way your fingers would.
    func type(_ s: String) {
        for ch in s {
            switch ch {
            case " ": key(49) { insert(" ") }
            case "\n": key(36) { insert("\n") }
            default:
                guard let st = keyFor[lang]?[ch] else { print("  (нет клавиши для «\(ch)»)"); continue }
                key(st.keyCode, shift: st.shift) { insert(layouts.character(st, in: lang)) }
            }
        }
    }
    /// Presses the keys that type `s` in the English layout, whatever layout is active now
    /// (your fingers keep going after we switched the layout).
    func typeKeys(_ s: String) {
        for ch in s {
            switch ch {
            case " ": key(49) { insert(" ") }
            case "\n": key(36) { insert("\n") }
            default:
                guard let st = keyFor[.en]?[ch] else { print("  (нет клавиши для «\(ch)»)"); continue }
                key(st.keyCode, shift: st.shift) { insert(layouts.character(st, in: lang)) }
            }
        }
    }
    func pressBackspace() { key(51) { backspace() } }
    func pressEnd() { key(119) { caret = text.count; selection = nil } }
    /// ⌘Z: `restore` is what the app's undo did to the text.
    func pressUndo(_ restore: String) { key(6, flags: .maskCommand) { text = Array(restore); caret = text.count } }
    /// A click: puts the caret (and selection) somewhere.
    func click(at offset: Int, selecting length: Int = 0) {
        caret = offset + length
        selection = length > 0 ? offset..<(offset + length) : nil
        if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left) {
            _ = engine.handle(type: .leftMouseDown, event: e)
        }
    }
    func rightOption() { engine.manualFix() }
    /// Text that is already in the field (typed earlier, pasted…), caret at the end.
    func set(_ s: String) { text = Array(s); caret = text.count; selection = nil; engine.appChanged(); focus() }
    /// A new, empty field.
    func clear() { text = []; caret = 0; selection = nil; engine.appChanged(); focus() }
    /// Lets the delayed field check run.
    func idle(_ t: TimeInterval = 0.9) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    func offset(of word: String) -> Int? { FieldProbe.lastWholeWord(word, in: string) }
}

extension SelfTest {
    /// The typing scenarios from the task, on the stand. Each check states what was typed and what the field shows.
    static func typingChecks(_ c: Classifier) -> (Int, Int) {
        Settings.shared.testMode = true
        defer { Settings.shared.testMode = false; FieldProbe.simulatedText = nil; FieldProbe.simulatedField = nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyswitch-stand-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UserStore(directory: dir)
        guard let f = TypingStand(classifier: c, store: store) else {
            print("Стенд ввода: пропущен — не включены русская и английская раскладки")
            return (0, 0)
        }
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name + "  «" + f.string.replacingOccurrences(of: "\n", with: "⏎") + "»", ok)) }
        var learned: [String] = []
        f.engine.onRuleLearned = { w, _ in learned.append(w) }
        var logged: [String] = []
        MissLog.sink = { logged.append($0) }
        defer { MissLog.sink = nil }

        // 1. One undo with right ⌥ stops «внось → вновь», ten times and after a restart.
        f.use(.ru); f.type("внось ")
        check("1. «внось » → «вновь » (ошибка воспроизведена)", f.string == "вновь ")
        f.rightOption()
        check("1. правый ⌥ вернул «внось»", f.string == "внось ")
        checks.append(("1. журнал: «ЛИШНЯЯ ЗАМЕНА «внось» → «вновь» · отмена ⌥»", logged.contains { $0.contains("ЛИШНЯЯ ЗАМЕНА") && $0.contains("«внось» → «вновь»") && $0.contains("отмена ⌥") }))
        f.idle(0.1)
        check("1. правило «После отмены» записано", store.rules.blocks("внось", lang: .ru, kind: .spell) && learned == ["внось"])
        for _ in 0..<10 { f.type("внось ") }
        check("1. десять повторов не исправлены", f.string == String(repeating: "внось ", count: 11))
        f.clear()
        let restarted = TypingStand(classifier: c, store: UserStore(directory: dir))!
        restarted.use(.ru); restarted.type("внось ")
        checks.append(("1. после перезапуска «внось» остаётся  «\(restarted.string)»", restarted.string == "внось "))

        // 2. Select our result and type your word over it.
        f.clear(); learned = []
        f.type("превет ")
        check("2. «превет » → «привет »", f.string == "привет ")
        f.idle(0.2) // a person needs longer than this to reach for the mouse
        f.click(at: f.offset(of: "привет")!, selecting: 6)
        f.type("превет ")
        check("2. набранное поверх «превет» не исправлено повторно", f.string == "превет  ")
        f.idle()
        check("2. восстановление проверено в поле → правило", store.rules.byKey[UserRule.key("превет", .ru, .spell)]?.source == .restore)
        f.idle(); f.type("снова превет ")
        check("2. следующий ввод не повторяет замену", f.string.contains("снова превет "))

        // 3. Change one letter inside the corrected word.
        f.clear()
        f.type("севодня ")
        check("3. «севодня » → «сегодня »", f.string == "сегодня ")
        f.idle(0.2) // a person needs longer than this to reach for the mouse
        f.click(at: 3)            // after "сег"
        f.pressBackspace(); f.type("в"); f.pressEnd()
        check("3. буква заменена внутри слова", f.string == "севодня ")
        f.idle()
        check("3. правка внутри слова распознана → правило", store.rules.blocks("севодня", lang: .ru, kind: .spell))
        f.type("и севодня ")
        check("3. повтор не исправлен", f.string == "севодня и севодня ")

        // 4. ⌘Z teaches only when it really brings your word back.
        f.clear()
        f.type("спосибо ")
        check("4. «спосибо » → «спасибо »", f.string == "спасибо ")
        f.type("всем ")
        f.pressUndo("спасибо ")       // the app undid something else: our fix stays
        f.idle()
        check("4. посторонняя отмена ⌘Z не создаёт правило", !store.rules.blocks("спосибо", lang: .ru, kind: .spell))
        f.pressUndo("спосибо ")       // this undo restored the word you typed
        f.idle()
        check("4. ⌘Z вернул исходное слово → правило", store.rules.blocks("спосибо", lang: .ru, kind: .spell))

        // 5. Another word edited, another field: no wrong rule, the old text is not rewritten.
        f.clear(); f.use(.en)
        f.typeKeys("ghbdtn ")
        check("5. «ghbdtn » → «привет »", f.string == "привет ")
        f.idle(0.2) // a person needs longer than this to reach for the mouse
        f.type("мир ")
        f.click(at: f.string.count - 2); f.pressBackspace(); f.type("е"); f.pressEnd()
        f.idle()
        check("5. правка другого слова не создаёт правило", !store.rules.blocks("ghbdtn", lang: .en, kind: .layout))
        f.engine.appChanged()
        let before5 = f.string
        f.rightOption()
        check("5. после смены поля правый ⌥ ничего не стирает", f.string == before5)

        // 9. A rule for «внось» does not stop other fixes; deleting it brings the fix back.
        f.clear(); f.use(.en)
        f.typeKeys("ghbdtn ")
        check("9. правило «внось» не мешает «ghbdtn → привет»", f.string == "привет ")
        f.use(.ru); f.type("вносьте ")
        check("9. похожее слово не защищено правилом", !store.rules.blocks("вносьте", lang: .ru, kind: .spell))
        store.removeRule(UserRule.key("внось", .ru, .spell))
        f.clear(); f.use(.ru); f.type("внось ")
        check("9. после удаления правила снова обычное поведение", f.string == "вновь ")

        // 10. After Enter nothing promises an undo, and nothing is erased in the new line.
        f.clear(); f.use(.en)
        f.typeKeys("ghbdtn\n")
        check("10. «ghbdtn⏎» → «привет⏎»", f.string == "привет\n")
        f.rightOption()
        check("10. после Enter правый ⌥ не стирает текст", f.string == "привет\n")

        // 12. Punctuation and a layout switched by you mid-word.
        f.clear(); f.use(.en)
        f.typeKeys("ghbdtn. ")
        check("12. «ghbdtn. » → «привет. »", f.string == "привет. ")
        f.clear(); f.use(.en)
        f.typeKeys("ghbdtn, rfr ltkf ")
        check("12. «ghbdtn, rfr ltkf » → «привет, как дела »", f.string == "привет, как дела ")
        f.clear(); f.use(.en)
        f.typeKeys("k.,k. ")
        check("12. «k.,k. » → «люблю » (б/ю внутри слова)", f.string == "люблю ")
        f.clear(); f.idle(1.1)          // past our own last switch
        f.use(.en); f.type("ghb")
        f.use(.ru); f.engine.layoutChanged()
        f.type("вет ")
        check("12. раскладку сменили посреди слова — слово не трогаем", f.string == "ghbвет ")

        // 14. Switching mid-word: after four letters the layout is already right.
        f.clear(); f.use(.en)
        f.typeKeys("ghbd")
        check("14. после «ghbd» уже «прив» и русская раскладка", f.string == "прив" && f.lang == .ru)
        f.typeKeys("tn ")
        check("14. слово допечатано правильно", f.string == "привет ")
        f.rightOption()
        check("14. правый ⌥ отменяет и это исправление", f.string == "ghbdtn " && f.lang == .en)
        f.clear(); f.use(.en)
        f.typeKeys("ghbdtn ")
        check("14. после отмены слово больше не переключается", f.string == "ghbdtn ")
        f.clear(); f.use(.en)
        f.type("hello world ")
        check("14. английские слова не переключаются", f.string == "hello world " && f.lang == .en)
        f.clear(); f.use(.ru)
        f.type("привет мир ")
        check("14. русские слова не переключаются", f.string == "привет мир " && f.lang == .ru)
        f.clear(); f.use(.en)
        f.typeKeys("z cltkfkf ")
        check("14. короткое слово перед ним тоже: «я сделала»", f.string == "я сделала ")

        // 15. Audit fixes: undo takes the short word along; right ⌥ mid-word protects the finished word, not its half.
        f.clear(); f.use(.en)
        f.typeKeys("z cltkfkf ")
        f.rightOption()
        check("15. отмена возвращает и короткое слово: «z cltkfkf »", f.string == "z cltkfkf " && f.lang == .en)
        f.clear(); f.use(.en)
        f.typeKeys("ntkt")
        check("15. «ntkt» переключилось посреди слова → «теле»", f.string == "теле")
        f.rightOption()
        check("15. правый ⌥ посреди слова вернул «ntkt»", f.string == "ntkt" && f.lang == .en)
        f.typeKeys("ajy ")
        check("15. слово допечатано как есть, без новой замены", f.string == "ntktajy ")
        check("15. запомнено целое слово, а не «теле»/«ntkt»",
              store.rules.blocks("ntktajy", lang: .en, kind: .layout) && !store.rules.blocks("ntkt", lang: .en, kind: .layout)
              && store.learned[.ru]?.contains("теле") != true)
        f.clear(); f.use(.en)
        f.typeKeys("ntktajy ")
        check("15. в следующий раз это слово не переключается", f.string == "ntktajy ")

        // 13. Right ⌥ on a word you came back to: the buffer is gone, the field is read instead.
        f.set("привет ghbdtn мир"); f.click(at: 10)
        logged = []
        f.rightOption()
        checks.append(("13. журнал: «ПРОПУСК «ghbdtn» → «привет» · ⌥ на старом слове»", logged.count == 1 && logged[0].contains("ПРОПУСК") && logged[0].contains("«ghbdtn» → «привет»") && logged[0].contains("⌥ на старом слове")))
        check("13. курсор внутри «ghbdtn» → «привет»", f.string == "привет привет мир" && f.caretOffset == 10)
        check("13. раскладка переключена на русскую", f.lang == .ru)
        f.rightOption()
        check("13. повторный ⌥ возвращает как было", f.string == "привет ghbdtn мир")
        checks.append(("13. журнал: возврат повторным ⌥ не пишется", logged.count == 1))
        f.engine.appChanged()
        let why = f.engine.explain(typed: "dj", alt: "во", lang: .en)
        checks.append(("13. журнал: причина «dj» — \(why)", why.contains("оба варианта")))
        f.set("ok ghbdtn. ntcn"); f.click(at: 10)
        f.rightOption()
        check("13. курсор в конце слова с точкой → «привет.»", f.string == "ok привет. ntcn")
        f.set("hello руддщ  ok"); f.click(at: 12)
        f.use(.ru); f.rightOption()
        check("13. курсор между пробелами — текст не тронут", f.string == "hello руддщ  ok" && f.lang == .en)
        f.set("руддщ цщкдв, 2 рфтвы!"); f.click(at: 0, selecting: 21)
        f.use(.ru); f.rightOption()
        check("13. выделенная фраза → «hello world, 2 hands!»", f.string == "hello world, 2 hands!" && f.lang == .en)
        f.set("Ghbdtn"); f.click(at: 6)
        f.use(.en); f.rightOption()
        check("13. заглавная сохраняется: «Ghbdtn» → «Привет»", f.string == "Привет")

        for (name, ok) in checks { print("\(ok ? "✓" : "✗") \(name)") }
        print("Стенд ввода: \(checks.filter(\.1).count)/\(checks.count)")
        return (checks.filter(\.1).count, checks.count)
    }
}
