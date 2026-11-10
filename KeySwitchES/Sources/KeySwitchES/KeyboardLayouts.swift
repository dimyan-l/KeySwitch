import Carbon
import Foundation

/// Pure source identity tracking, independent of typing or the Text Input Sources API.
struct InputSourceContext {
    private var sourceID: String?

    /// Advance synchronously on success, before queued source notifications arrive.
    mutating func recordSelection(_ id: String, succeeded: Bool) {
        if succeeded { sourceID = id }
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
}

/// Wraps the Text Input Sources API: finding the EN/ES layouts, switching, and translating
/// key codes into characters with the real installed layouts (Spanish, ABC, US…).
final class KeyboardLayouts {
    struct Source {
        let ref: TISInputSource
        let id: String
        let lang: Lang?
        let layout: Data?
    }

    private(set) var preferred: [Lang: Source] = [:]
    private var reverseMaps: [String: [Character: Stroke]] = [:]
    private var inputSourceContext = InputSourceContext()

    init() {
        refresh()
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
        // Also remember whatever is active right now.
        let cur = current()
        if let lang = cur.lang, cur.layout != nil { preferred[lang] = cur }
    }

    func current() -> Source {
        Self.makeSource(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    var currentLang: Lang? { current().lang }

    var hasBothLayouts: Bool { preferred[.es] != nil && preferred[.en] != nil }

    func select(_ lang: Lang) {
        guard let src = preferred[lang] else { return }
        let status = TISSelectInputSource(src.ref)
        inputSourceContext.recordSelection(src.id, succeeded: status == noErr)
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
                UInt32(LMGetKbdType()),
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

    /// Re-read the selected text using the other physical keyboard layout.
    /// EN and ES share an alphabet, so the active source determines direction.
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

    private static func makeSource(_ ref: TISInputSource) -> Source {
        let id = string(ref, kTISPropertyInputSourceID) ?? "?"
        var lang: Lang?
        if let langs = property(ref, kTISPropertyInputSourceLanguages) as? [String], let first = langs.first {
            if first.hasPrefix("es") { lang = .es } else if first.hasPrefix("en") { lang = .en }
        }
        var data: Data?
        if let obj = property(ref, kTISPropertyUnicodeKeyLayoutData) {
            let cf = unsafeBitCast(obj, to: CFData.self)
            data = cf as Data
        }
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
