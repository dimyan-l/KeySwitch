import Carbon
import Foundation

/// One physical keystroke. We store keys, not characters, so the same keystrokes can be
/// re-read in any layout (that is the whole trick of layout correction).
struct Stroke: Equatable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
}

/// Wraps the Text Input Sources API: finding the RU/EN layouts, switching, and translating
/// key codes into characters with the real installed layouts (Russian, Russian–PC, ABC, US…).
final class KeyboardLayouts {
    struct Source {
        let ref: TISInputSource
        let id: String
        let lang: Lang?
        let layout: Data?
    }

    /// Read from the keyboard thread, written on the main thread: every field below goes through `lock`.
    /// The Text Input Sources API itself is only called on the main thread.
    private let lock = NSLock()
    private var _preferred: [Lang: Source] = [:]
    private var reverse: [Lang: [Character: Stroke]] = [:]
    /// The active layout as macOS last reported it (refreshed on every layout-change notification),
    /// so the keyboard thread never has to ask the system.
    private var _current: Source?
    /// A switch asked for from the keyboard thread that the main thread has not made yet: until it has,
    /// a refresh triggered by an older notification must not put the previous layout back.
    private var _pending: Source?
    private var _simulated: Lang?

    var preferred: [Lang: Source] { lock.withLock { _preferred } }
    /// Self-test only: the "active" layout lives here instead of in macOS, so tests never switch your layout.
    var simulated: Lang? {
        get { lock.withLock { _simulated } }
        set { lock.withLock { _simulated = newValue } }
    }

    init() { refresh() }

    // MARK: - Enumeration

    /// Main thread: re-reads the enabled layouts and the active one.
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
        let active = Self.makeSource(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        lock.withLock {
            reverse = [:]
            for lang in Lang.allCases {
                // Keep the user's last-used source per language if it is still enabled.
                if let keep = _preferred[lang], list.contains(where: { Self.string($0, kTISPropertyInputSourceID) == keep.id }) {
                    continue
                }
                _preferred[lang] = found[lang]
            }
            // Also remember whatever is active right now.
            if let lang = active.lang, active.layout != nil { _preferred[lang] = active }
            _current = _pending ?? active
        }
    }

    /// Any thread: the active layout as last reported.
    func current() -> Source {
        lock.withLock {
            if let s = _simulated, let src = _preferred[s] { return src }
            return _current! // set by refresh(), which init runs
        }
    }

    var currentLang: Lang? { current().lang }

    var hasBothLayouts: Bool { lock.withLock { _preferred[.ru] != nil && _preferred[.en] != nil } }

    /// Any thread. The new layout counts as active at once (the next key is read in it);
    /// macOS is asked to switch on the main thread.
    func select(_ lang: Lang) {
        let src: Source? = lock.withLock {
            if _simulated != nil { _simulated = lang; return nil }
            guard let src = _preferred[lang] else { return nil }
            _current = src
            _pending = src
            return src
        }
        guard let src else { return }
        let apply = { [weak self] in
            TISSelectInputSource(src.ref)
            self?.lock.withLock { if self?._pending?.id == src.id { self?._pending = nil } }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
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

    /// Which key types `ch` in `lang` (unshifted keys win over shifted ones). Used to re-read text that is
    /// already on screen: the word you clicked back into, or a selection.
    func reverseMap(_ lang: Lang) -> [Character: Stroke] {
        if let m = lock.withLock({ reverse[lang] }) { return m }
        var m: [Character: Stroke] = [:]
        for shift in [true, false] {
            for code in UInt16(0)...50 where ![36, 48, 49].contains(code) {
                let s = Stroke(keyCode: code, shift: shift, caps: false)
                if let ch = character(s, in: lang).first { m[ch] = s }
            }
        }
        lock.withLock { reverse[lang] = m }
        return m
    }

    // MARK: - TIS helpers

    private static func makeSource(_ ref: TISInputSource) -> Source {
        let id = string(ref, kTISPropertyInputSourceID) ?? "?"
        var lang: Lang?
        if let langs = property(ref, kTISPropertyInputSourceLanguages) as? [String], let first = langs.first {
            if first.hasPrefix("ru") { lang = .ru } else if first.hasPrefix("en") { lang = .en }
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
