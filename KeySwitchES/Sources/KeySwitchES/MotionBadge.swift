import AppKit

/// Compact native language switch with a brief correction acknowledgement.
final class MotionBadge {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var position: CGFloat = 0
    private var start: CGFloat = 0
    private var target: CGFloat = 0
    private var began = Date.distantPast
    private var pulseBegan = Date.distantPast
    private var pulseColor = NSColor.controlAccentColor
    private var paused = false
    private let duration: TimeInterval = 0.16
    private var second: Lang { Lang.allCases.first { $0.rawValue != "en" }! }

    func attach(to button: NSStatusBarButton, language: Lang?) {
        self.button = button
        position = language == second ? 1 : 0; target = position
        button.title = ""; button.toolTip = nil
        button.imagePosition = .imageOnly; button.imageScaling = .scaleNone
        render()
    }
    func setPaused(_ value: Bool) { guard value != paused else { return }; paused = value; render() }
    func show(_ language: Lang?) {
        guard let language else { return }
        let value: CGFloat = language == second ? 1 : 0
        guard value != target else { return }
        target = value
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { position = target; render(); return }
        start = position; began = Date(); animate()
    }
    func acknowledgeCorrection() { pulse(.controlAccentColor) }
    func suggestCorrection() { pulse(.systemOrange) }
    private func pulse(_ color: NSColor) {
        guard !paused, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pulseColor = color; pulseBegan = Date(); animate()
    }
    private func animate() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func tick() {
        let elapsed = Date().timeIntervalSince(began)
        let t = CGFloat(min(1, max(0, elapsed / duration)))
        position = start + (target - start) * t * t * (3 - 2 * t)
        render()
        if elapsed >= duration && Date().timeIntervalSince(pulseBegan) >= 0.26 { timer?.invalidate(); timer = nil }
    }
    private func render() {
        guard let button else { return }
        let progress = position, isPaused = paused, other = second.label
        let age = Date().timeIntervalSince(pulseBegan)
        let pulse = !paused && age >= 0 && age < 0.26 ? sin(age / 0.26 * .pi) : 0
        let color = pulseColor
        let image = NSImage(size: NSSize(width: 54, height: 20), flipped: false) { _ in
            let outer = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 52, height: 18), xRadius: 7, yRadius: 7)
            NSColor.labelColor.withAlphaComponent(0.07).setFill(); outer.fill()
            if pulse > 0 { color.withAlphaComponent(pulse * 0.65).setStroke(); outer.lineWidth = 1.2; outer.stroke() }
            let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
            if isPaused {
                let text = NSAttributedString(string: "Ⅱ  " + (progress >= 0.5 ? other : "EN"), attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                let size = text.size(); text.draw(at: NSPoint(x: (54 - size.width) / 2, y: (20 - size.height) / 2))
            } else {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 3 + 25 * progress, y: 3, width: 23, height: 14), xRadius: 5, yRadius: 5).fill()
                for (label, x, selected) in [("EN", CGFloat(3), progress < 0.5), (other, CGFloat(28), progress >= 0.5)] {
                    let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: selected ? NSColor.white : NSColor.labelColor])
                    let size = text.size(); text.draw(at: NSPoint(x: x + (23 - size.width) / 2, y: (20 - size.height) / 2))
                }
            }
            return true
        }
        image.isTemplate = false; button.image = image
        button.setAccessibilityLabel("KeySwitch, " + (target == 1 ? second.label : "EN") + (paused ? ", paused" : ", active"))
    }
}
