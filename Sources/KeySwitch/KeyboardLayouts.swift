import Carbon
import Foundation

/// Pure source identity tracking, independent of typing or the Text Input Sources API.
struct InputSourceContext {
    private var sourceID: String?
    /// The engine records its own selection only after TIS reports that source as current.
    mutating func recordSelection(_ id: String) {
        sourceID = id
    }

    /// Returns whether engine context belongs to a genuinely different source.
    mutating func observe(_ id: String) -> Bool {
        let changed = sourceID != nil && sourceID != id
        sourceID = id
        return changed
    }

}

/// One physical keystroke. We store keys, not characters, so the same keystrokes can be
/// re-read in any layout (that is the whole trick of layout correction).
struct Stroke: Equatable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
    let keyboardType: UInt32?

    init(keyCode: UInt16, shift: Bool, caps: Bool, keyboardType: UInt32? = nil) {
        self.keyCode = keyCode
        self.shift = shift
        self.caps = caps
        self.keyboardType = keyboardType
    }
}

/// Wraps the Text Input Sources API: finding the RU/EN layouts, switching, and translating
/// key codes into characters with the real installed layouts (Russian, Russian–PC, ABC, US…).
final class KeyboardLayouts {
    struct Source {
        let ref: TISInputSource?
        let id: String
        let lang: Lang?
        let layout: Data?
    }

    private(set) var preferred: [Lang: Source] = [:]
    private var reverseMaps: [String: [Character: Stroke]] = [:]
    private var inputSourceContext = InputSourceContext()
    private let readSource: () -> Source
    private let requestSource: (TISInputSource) -> OSStatus

    init(sources: [Lang: Source]? = nil, readSource: (() -> Source)? = nil,
         requestSource: @escaping (TISInputSource) -> OSStatus = TISSelectInputSource) {
        self.readSource = readSource ?? {
            guard let ref = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
                return Source(ref: nil, id: "?", lang: nil, layout: nil)
            }
            return Self.makeSource(ref)
        }
        self.requestSource = requestSource
        if let sources { preferred = sources } else { refresh() }
        _ = inputSourceContext.observe(current().id)
    }

    func observeInputSource(_ id: String) -> Bool {
        inputSourceContext.observe(id)
    }

    // MARK: - Enumeration

    func refresh() {
        let props: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        let list = (TISCreateInputSourceList(props as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        var found: [Lang: Source] = [:]
        for ref in list {
            let src = Self.makeSource(ref)
            guard let lang = src.lang, src.layout != nil else { continue }
            if found[lang] == nil { found[lang] = src }
        }
        for lang in Lang.allCases {
            // Keep the user's last-used source per language if it is still enabled.
            if let keep = preferred[lang], list.contains(where: { Self.string($0, kTISPropertyInputSourceID) == keep.id }) {
                continue
            }
            preferred[lang] = found[lang]
        }
        reverseMaps.removeAll()
        // Also remember whatever is active right now.
        let cur = current()
        if let lang = cur.lang, cur.layout != nil { preferred[lang] = cur }
    }

    /// Updates the preferred source for the active language without re-enumerating TIS or
    /// discarding cached reverse key maps unless an unknown layout ID appears.
    func noteActiveSource(_ source: Source) {
        guard let lang = source.lang, source.layout != nil else { return }
        if preferred[lang]?.id == source.id { return }
        preferred[lang] = source
    }

    func current() -> Source {
        readSource()
    }

    var currentLang: Lang? { current().lang }

    var hasBothLayouts: Bool { preferred[.ru] != nil && preferred[.en] != nil }

    /// Issue one request. Reissuing it later can override a deliberate Fn/Globe switch.
    @discardableResult
    func select(_ lang: Lang) -> Bool {
        guard let source = preferred[lang], let ref = source.ref else { return false }
        return current().id == source.id || requestSource(ref) == noErr
    }

    func confirmSelection(_ id: String) {
        inputSourceContext.recordSelection(id)
    }

    // MARK: - Translation

    func character(_ s: Stroke, layout: Data?) -> String {
        guard let layout else { return "" }
        var deadKeyState: UInt32 = 0
        var length = 0
        let maxLength = 4
        var chars = [UniChar](repeating: 0, count: maxLength)
        var mods: UInt32 = 0
        if s.shift { mods |= UInt32((shiftKey >> 8) & 0xFF) }
        if s.caps { mods |= UInt32((alphaLock >> 8) & 0xFF) }
        let status: OSStatus = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                s.keyCode,
                UInt16(kUCKeyActionDown),
                mods,
                s.keyboardType ?? UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                maxLength,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    func character(_ s: Stroke, in lang: Lang) -> String {
        character(s, layout: preferred[lang]?.layout)
    }

    func string(_ strokes: [Stroke], layout: Data?) -> String {
        strokes.map { character($0, layout: layout) }.joined()
    }

    func string(_ strokes: [Stroke], in lang: Lang) -> String {
        string(strokes, layout: preferred[lang]?.layout)
    }

    /// Converts arbitrary text typed in the wrong layout ("Ghbdtn, rfr ltkf?" -> "Привет, как дела?").
    /// Direction is chosen by which alphabet dominates the text.
    func flipText(_ text: String) -> String {
        let cyr = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        let lat = text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
        let from: Lang = cyr > lat ? .ru : .en
        let to = from.other
        guard let fromSrc = preferred[from], let toSrc = preferred[to] else { return text }
        let map = reverseMap(for: fromSrc)
        var out = ""
        for ch in text {
            if let stroke = map[ch] {
                let t = character(stroke, layout: toSrc.layout)
                out += t.isEmpty ? String(ch) : t
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Rebuild a Russian/English mixed word using the key behind each letter.
    /// Only an unambiguous dictionary result is offered on an explicit manual request.
    func repairMixedWord(_ word: String, classifier: Classifier?) -> (text: String, language: Lang)? {
        guard let classifier, hasBothLayouts, (3...32).contains(word.count),
              let en = preferred[.en], let ru = preferred[.ru] else { return nil }
        let enKeys = reverseMap(for: en)
        let ruKeys = reverseMap(for: ru)
        var latin = false
        var cyrillic = false
        var english = ""
        var russian = ""
        for letter in word {
            if letter == "-" || letter == "'" {
                english.append(letter)
                russian.append(letter)
            } else if letter.isLetter, let stroke = enKeys[letter] {
                latin = true
                english.append(letter)
                russian += character(stroke, layout: ru.layout)
            } else if letter.isLetter, let stroke = ruKeys[letter] {
                cyrillic = true
                russian.append(letter)
                english += character(stroke, layout: en.layout)
            } else {
                return nil
            }
        }
        guard latin && cyrillic else { return nil }
        let enWord = normalizeWord(english)
        let ruWord = normalizeWord(russian)
        let knownEN = classifier.models[.en]?.score(enWord) != nil
        let knownRU = classifier.models[.ru]?.score(ruWord) != nil
        guard knownEN != knownRU else { return nil }
        return knownEN ? (english, .en) : (russian, .ru)
    }

    /// Punctuation of the EN layout whose keys type letters in the RU layout ("," → "б", "." → "ю").
    var letterPunctuation: Set<Character> {
        guard let en = preferred[.en], let ru = preferred[.ru] else { return [] }
        var result = Set<Character>()
        for (ch, stroke) in reverseMap(for: en) where !ch.isLetter && !ch.isNumber {
            if character(stroke, layout: ru.layout).first?.isLetter == true { result.insert(ch) }
        }
        return result
    }

    private func reverseMap(for src: Source) -> [Character: Stroke] {
        if let m = reverseMaps[src.id] { return m }
        var m: [Character: Stroke] = [:]
        // Main typing block: key codes 0...50 minus Return(36), Tab(48), Space(49).
        for code in UInt16(0)...UInt16(50) where ![36, 48, 49].contains(code) {
            for shift in [false, true] {
                let s = Stroke(keyCode: code, shift: shift, caps: false)
                let c = character(s, layout: src.layout)
                if c.count == 1, let ch = c.first, m[ch] == nil, !ch.isWhitespace { m[ch] = s }
            }
        }
        reverseMaps[src.id] = m
        return m
    }

    // MARK: - TIS helpers

    static func makeSource(_ ref: TISInputSource) -> Source {
        let id = string(ref, kTISPropertyInputSourceID) ?? "?"
        var lang: Lang?
        if let langs = property(ref, kTISPropertyInputSourceLanguages) as? [String], let first = langs.first {
            if first.hasPrefix("ru") { lang = .ru } else if first.hasPrefix("en") { lang = .en }
        }
        let data = property(ref, kTISPropertyUnicodeKeyLayoutData) as? Data
        return Source(ref: ref, id: id, lang: lang, layout: data)
    }

    private static func property(_ ref: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(ref, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }

    private static func string(_ ref: TISInputSource, _ key: CFString) -> String? {
        property(ref, key) as? String
    }
}
