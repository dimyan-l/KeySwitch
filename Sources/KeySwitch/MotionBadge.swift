import AppKit

/// Pastel layout indicator. Motion reflects the confirmed macOS input source.
final class MotionBadge {
    private weak var button: NSStatusBarButton?
    private let second = Lang.allCases.first { $0 != .en } ?? .en
    private var position: CGFloat = 0
    private var start: CGFloat = 0
    private var target: CGFloat = 0
    private var began = Date.distantPast
    private var pulseBegan = Date.distantPast
    private var pulseColor = NSColor.systemGreen
    private var timer: Timer?
    private var language: Lang?
    private var paused = false
    private let duration: TimeInterval = 0.16

    deinit { timer?.invalidate() }

    func attach(to button: NSStatusBarButton, language: Lang?) {
        self.button = button
        self.language = language
        position = language == second ? 1 : 0
        start = position
        target = position
        render()
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        render()
    }

    func show(_ language: Lang?) {
        guard self.language != language else { return }
        self.language = language
        target = language == second ? 1 : 0
        if language == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            position = target
            start = position
            began = .distantPast
            render()
        } else {
            start = position
            began = Date()
            animate()
        }
    }

    func acknowledgeCorrection() { pulse(.systemGreen) }
    func suggestCorrection() { pulse(.systemOrange) }

    private func pulse(_ color: NSColor) {
        guard !paused, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pulseColor = color
        pulseBegan = Date()
        animate()
    }

    private func animate() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(began)
        let t = CGFloat(min(1, max(0, elapsed / duration)))
        position = start + (target - start) * t * t * (3 - 2 * t)
        render()
        if elapsed >= duration && Date().timeIntervalSince(pulseBegan) >= 0.26 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func render() {
        guard let button else { return }
        let progress = position
        let other = second.label
        let isPaused = paused
        let known = language != nil
        let age = Date().timeIntervalSince(pulseBegan)
        let pulse = !isPaused && age >= 0 && age < 0.26 ? sin(age / 0.26 * .pi) : 0
        let color = pulseColor
        let image = NSImage(size: NSSize(width: 62, height: 22), flipped: false) { _ in
            let frame = NSRect(x: 1, y: 2, width: 60, height: 19)
            let pill = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
            let ink = NSColor(srgbRed: 0.15, green: 0.22, blue: 0.20, alpha: 1)
            let cream = NSColor(srgbRed: 0.99, green: 0.96, blue: 0.90, alpha: 1)
            let sand = NSColor(srgbRed: 0.87, green: 0.83, blue: 0.75, alpha: 1)
            NSGradient(starting: sand, ending: cream)?.draw(in: pill, angle: 90)
            NSColor.white.withAlphaComponent(0.55).setStroke()
            pill.lineWidth = 0.7
            pill.stroke()

            if known && !isPaused {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowBlurRadius = 2
                shadow.shadowColor = ink.withAlphaComponent(0.42)
                shadow.set()
                let cap = NSBezierPath(roundedRect: NSRect(x: 3 + 28 * progress, y: 4, width: 28, height: 15),
                                       xRadius: 6, yRadius: 6)
                ink.withAlphaComponent(0.3).setFill()
                cap.fill()
                NSGraphicsContext.restoreGraphicsState()

                let lower = NSColor(srgbRed: 0.64 - 0.04 * progress, green: 0.78, blue: 0.63 + 0.24 * progress, alpha: 1)
                let upper = NSColor(srgbRed: 0.93 - 0.08 * progress, green: 0.97 - 0.04 * progress, blue: 0.83 + 0.15 * progress, alpha: 1)
                NSGradient(starting: lower, ending: upper)?.draw(in: cap, angle: 90)
                NSColor.white.withAlphaComponent(0.65).setStroke()
                cap.lineWidth = 0.7
                cap.stroke()
            }

            func drawLabel(_ label: String, at center: CGFloat, selected: Bool) {
                let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: selected ? .bold : .medium)
                let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
                let size = text.size()
                text.draw(at: NSPoint(x: center - size.width / 2, y: (22 - size.height) / 2 - 0.5))
            }
            if isPaused || !known {
                drawLabel(isPaused ? "Ⅱ  " + (known ? progress >= 0.5 ? other : "EN" : "—") : "—", at: 31, selected: true)
            } else {
                drawLabel("EN", at: 17, selected: progress < 0.5)
                drawLabel(other, at: 45, selected: progress >= 0.5)
            }
            if pulse > 0 {
                color.withAlphaComponent(pulse * 0.85).setStroke()
                pill.lineWidth = 1.25
                pill.stroke()
            }
            return true
        }
        image.isTemplate = false
        button.image = image
        button.setAccessibilityLabel("KeySwitch, " + (language?.label ?? "—") + (paused ? ", Ⅱ" : ""))
    }
}
