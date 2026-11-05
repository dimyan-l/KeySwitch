import AppKit
import SwiftUI

/// «Полночь и лёд»: every color of the app, by role, for the dark and light appearance and for
/// Increase Contrast. RU and EN share one accent; the letters tell the languages apart.
/// Status always comes with text or a symbol, never color alone.
enum Theme {
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// dark, light, then the Increase Contrast variants (nil = same as normal).
    private static func token(_ name: String, dark: UInt32, light: UInt32, darkHC: UInt32? = nil, lightHC: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("ks." + name)) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
            case .accessibilityHighContrastDarkAqua: hex(darkHC ?? dark)
            case .accessibilityHighContrastAqua: hex(lightHC ?? light)
            case .darkAqua: hex(dark)
            default: hex(light)
            }
        })
    }

    // Values from palette.json; contrast on `panel`: text 13.9:1, secondary 7.8:1 (dark).
    static let background = token("background", dark: 0x111824, light: 0xEEF3F8)
    static let panel = token("panel", dark: 0x1C2635, light: 0xFFFFFF)
    static let sidebar = token("sidebar", dark: 0x172130, light: 0xE5ECF4, darkHC: 0x101722, lightHC: 0xDCE5EF)
    static let text = token("text", dark: 0xF1F5FA, light: 0x152233, darkHC: 0xFFFFFF, lightHC: 0x0B1522)
    static let secondary = token("secondary", dark: 0xAEBBCB, light: 0x56687C, darkHC: 0xD3DCE7, lightHC: 0x3A4A5C)
    static let accent = token("accent", dark: 0x8FBCE8, light: 0x315D8D, darkHC: 0xB3D3F4, lightHC: 0x1F4570)
    /// Text and knobs on a fully filled accent.
    static let onAccent = token("onAccent", dark: 0x132438, light: 0xFFFFFF)
    /// Soft selected surface; accent text on it reads 5.7:1 (dark).
    static let selected = token("selected", dark: 0x2B3B4F, light: 0xDDE9F6, darkHC: 0x34485F, lightHC: 0xCCDDF0)
    static let separator = token("separator", dark: 0x374557, light: 0xD5DFE9, darkHC: 0x5A6B80, lightHC: 0xA9B8C8)
    static let success = token("success", dark: 0x91C7A4, light: 0x346C49, darkHC: 0xB0DCC0, lightHC: 0x245536)
    static let warning = token("warning", dark: 0xD6A76B, light: 0x8A5B23, darkHC: 0xEBC08A, lightHC: 0x6E4718)
    static let error = token("error", dark: 0xF0A8AC, light: 0xA6323D, darkHC: 0xF8C4C7, lightHC: 0x86222C)
    /// A group inside the panel: one step off the panel, no glass.
    static let group = token("group", dark: 0x151E2B, light: 0xF3F7FB, darkHC: 0x0E151F, lightHC: 0xEAF0F6)
}

/// Local view state without `@State`: the SwiftUIMacros plugin that `@State` needs ships with Xcode,
/// and this project builds with Command Line Tools only.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.selected, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// RU / EN tag. Both languages look the same: the letters tell them apart.
struct LangBadge: View {
    let lang: Lang
    var size: CGFloat = 30
    var body: some View {
        Text(lang.label)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.selected, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityLabel(lang == .ru ? "Русская раскладка" : "Английская раскладка")
    }
}

/// A calm group: solid surface and a hairline, readable with Reduce Transparency and Increase Contrast.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.group, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1))
    }
}

/// Small status dot that always sits next to a text.
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true) }
}

/// Filled-on-soft button of the panel: "Это ошибка".
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.selected.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The app's mark: Я and A on the midnight tile, drawn in the palette (also used for the menu bar fallback).
struct AppIcon: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Compact mark for the panel header: "ЯA" on the soft surface, as in the design.
struct MarkTile: View {
    var size: CGFloat = 32
    var body: some View {
        Text("ЯA")
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .tracking(-0.5)
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.selected, in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}
