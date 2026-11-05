import AppKit
import ApplicationServices
import SwiftUI

enum ToastKind {
    case fix(to: Lang, typed: String, result: String, undoable: Bool)
    /// `saved: false`: the rule works, but only until you quit.
    case learned(String, saved: Bool)
}

struct ToastView: View {
    let kind: ToastKind

    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .fix(let to, let typed, let result, let undoable):
                LangBadge(lang: to, size: 22)
                Text(typed).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.secondary).strikethrough()
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(result).font(.system(size: 13, weight: .semibold))
                // Only when right ⌥ can really undo it: not after Enter / Tab.
                if undoable {
                    Text("правый ⌥ — отменить")
                        .font(.system(size: 12)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.selected, in: Capsule())
                }
            case .learned(let word, let saved):
                StatusDot(color: saved ? Theme.success : Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Запомнил «\(word)»").font(.system(size: 13, weight: .semibold))
                    Text(saved ? "Больше не исправляю автоматически" : "Не сохранилось — действует до выхода")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 8)
        // Solid, not glass: the pill floats over any text and has to stay readable on every background.
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
        .padding(16)
        .fixedSize()
    }
}

/// Floating, click-through, non-activating pill near the caret. Never takes focus from the app you type in.
final class ToastController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var lastAnchor: NSRect?

    func show(_ kind: ToastKind, near anchor: NSRect?, duration: TimeInterval?) {
        let host = NSHostingView(rootView: ToastView(kind: kind))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        panel.setContentSize(size)

        let anchor = anchor ?? lastAnchor
        lastAnchor = anchor
        panel.setFrameOrigin(origin(for: size, anchor: anchor))
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }

        hideWork?.cancel()
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        }
        lastAnchor = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }

    private func origin(for size: NSSize, anchor: NSRect?) -> NSPoint {
        var point: NSPoint
        if let a = anchor {
            point = NSPoint(x: a.midX - size.width / 2, y: a.maxY + 2)
        } else {
            let m = NSEvent.mouseLocation
            point = NSPoint(x: m.x - size.width / 2, y: m.y + 18)
        }
        let probe = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            point.x = min(max(point.x, v.minX + 4), v.maxX - size.width - 4)
            point.y = min(max(point.y, v.minY + 4), v.maxY - size.height - 4)
        }
        return point
    }
}

/// Finds the text caret of the focused field through Accessibility. Many apps (Electron, Qt) do not
/// expose it; the caller then falls back to the mouse position.
enum CaretLocator {
    static func locate(_ completion: @escaping (NSRect?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let rect = caretRect()
            DispatchQueue.main.async { completion(rect) }
        }
    }

    private static func caretRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }

        // The character just before the caret: its box is where the corrected word ends.
        var probe = CFRange(location: max(0, range.location - 1), length: 1)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, probeValue, &boundsRef) == .success,
              let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.height > 0, rect.width < 2000 else { return nil }

        // Accessibility uses a top-left origin on the primary screen; AppKit uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        return NSScreen.screens.contains { $0.frame.intersects(cocoa) } ? cocoa : nil
    }
}
