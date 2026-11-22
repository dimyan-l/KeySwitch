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

/// Wraps the Text Input Sources API: finding the EN/ES layouts, switching, and translating
/// key codes into characters with the real installed layouts (Español, Español ISO, Latinoamericano, ABC, US…).
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
    private let requestSource: (Source) -> Bool
    private let translate: (Stroke, Data?) -> String

    init(sources: [Lang: Source]? = nil, readSource: (() -> Source)? = nil,
         requestSource: ((Source) -> Bool)? = nil, translate: ((Stroke, Data?) -> String)? = nil) {
        self.readSource = readSource ?? {
            guard let ref = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
                return Source(ref: nil, id: "?", lang: nil, layout: nil)
            }
            return Self.makeSource(ref)
        }
        self.requestSource = requestSource ?? { source in
            guard let ref = source.ref else { return false }
            return TISSelectInputSource(ref) == noErr
        }
        self.translate = translate ?? Self.translateKey
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

    func current() -> Source {
        readSource()
    }

    var currentLang: Lang? { current().lang }

    var hasBothLayouts: Bool { preferred[.es] != nil && preferred[.en] != nil }

    /// Issue one request. Reissuing it later can override a deliberate Fn/Globe switch.
    @discardableResult
    func select(_ lang: Lang) -> Bool {
        guard let source = preferred[lang] else { return false }
        return current().id == source.id || requestSource(source)
    }

    func confirmSelection(_ id: String) {
        inputSourceContext.recordSelection(id)
    }

    // MARK: - Translation

    func character(_ s: Stroke, layout: Data?) -> String {
        translate(s, layout)
    }

    private static func translateKey(_ s: Stroke, layout: Data?) -> String {
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

    /// Re-read physical keys in the other layout. English and Spanish share their alphabet,
    /// so manual conversion uses the active layout or an explicit source language.
    func flipText(_ text: String, from: Lang) -> String {
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

    /// Punctuation in the active layout that corresponds to a letter in the other layout.
    var letterPunctuation: Set<Character> {
        guard let from = currentLang, let source = preferred[from], let target = preferred[from.other] else { return [] }
        return Set(reverseMap(for: source).compactMap { character, stroke in
            guard !character.isLetter, character.isPunctuation,
                  self.character(stroke, layout: target.layout).first?.isLetter == true else { return nil }
            return character
        })
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
            if first.hasPrefix("es") { lang = .es } else if first.hasPrefix("en") { lang = .en }
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
