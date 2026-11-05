// Draws the KeySwitch app icon and builds AppIcon.icns.
// Usage:
//   swift tools/make_icon.swift icns <style> Resources/AppIcon.icns
//   swift tools/make_icon.swift sheet out.png          (all styles side by side, to choose from)
// Styles: split, keycap, swap, caret
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func font(_ size: CGFloat, rounded: Bool = true, weight: NSFont.Weight = .black) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard rounded, let d = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: d, size: size) ?? base
}

func text(_ s: String, center: NSPoint, size: CGFloat, color: NSColor, shadow: CGFloat = 0, rounded: Bool = true, weight: NSFont.Weight = .black) {
    var attrs: [NSAttributedString.Key: Any] = [.font: font(size, rounded: rounded, weight: weight), .foregroundColor: color]
    if shadow > 0 {
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(shadow)
        sh.shadowBlurRadius = 10
        sh.shadowOffset = NSSize(width: 0, height: -6)
        attrs[.shadow] = sh
    }
    let a = NSAttributedString(string: s, attributes: attrs)
    let b = a.size()
    a.draw(at: NSPoint(x: center.x - b.width / 2, y: center.y - b.height / 2))
}

let body = NSRect(x: 100, y: 100, width: 824, height: 824)   // macOS icon grid: 824×824 tile, 100 px margins
let tile = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

/// Tile with drop shadow, `fill` drawn clipped inside it, then a hairline edge.
func drawTile(edge: NSColor = NSColor.white.withAlphaComponent(0.18), _ fill: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
    sh.shadowBlurRadius = 28
    sh.shadowOffset = NSSize(width: 0, height: -12)
    sh.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    fill()
    NSGraphicsContext.restoreGraphicsState()

    let e = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    e.lineWidth = 3
    edge.setStroke()
    e.stroke()
}

// MARK: - Styles

/// 1. Orange / blue halves with Я and A.
func split() {
    drawTile {
        NSGradient(starting: rgb(0x3B66F0), ending: rgb(0x1D4ED8))!.draw(in: body, angle: -90)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: body.minX - 10, y: body.maxY + 10))
        p.line(to: NSPoint(x: body.maxX + 40, y: body.maxY + 10))
        p.curve(to: NSPoint(x: body.minX - 10, y: body.minY - 40),
                controlPoint1: NSPoint(x: body.midX + 140, y: body.midY + 60),
                controlPoint2: NSPoint(x: body.midX - 60, y: body.midY - 140))
        p.close()
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSGradient(starting: rgb(0xEA580C), ending: rgb(0xC2410C))!.draw(in: body, angle: -60)
        NSGraphicsContext.restoreGraphicsState()
        text("Я", center: NSPoint(x: body.minX + 262, y: body.minY + 562), size: 330, color: .white, shadow: 0.22)
        text("A", center: NSPoint(x: body.minX + 566, y: body.minY + 252), size: 330, color: .white, shadow: 0.22)
    }
}

/// 2. A real keycap on graphite: Latin legend top-left, Cyrillic bottom-right in orange, like on a Russian Mac keyboard.
func keycap() {
    drawTile(edge: NSColor.white.withAlphaComponent(0.10)) {
        NSGradient(starting: rgb(0x34363D), ending: rgb(0x15161A))!.draw(in: body, angle: -90)
        let cap = NSRect(x: body.midX - 280, y: body.midY - 250, width: 560, height: 540)
        // Key side (darker, sits lower)
        let side = NSBezierPath(roundedRect: cap.offsetBy(dx: 0, dy: -34), xRadius: 96, yRadius: 96)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.55)
        sh.shadowBlurRadius = 40
        sh.shadowOffset = NSSize(width: 0, height: -24)
        sh.set()
        rgb(0xB9BDC6).setFill()
        side.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Key top face
        let face = NSBezierPath(roundedRect: cap, xRadius: 96, yRadius: 96)
        NSGraphicsContext.saveGraphicsState()
        face.addClip()
        NSGradient(starting: rgb(0xFFFFFF), ending: rgb(0xE3E6EC))!.draw(in: cap, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        text("A", center: NSPoint(x: cap.minX + 165, y: cap.maxY - 160), size: 230, color: rgb(0x1F2430), rounded: false, weight: .semibold)
        text("Я", center: NSPoint(x: cap.maxX - 160, y: cap.minY + 150), size: 230, color: rgb(0xE4570F), rounded: false, weight: .semibold)
    }
}

/// 3. Two arrows chasing each other around Я ⇄ A on deep indigo.
func swap() {
    drawTile {
        NSGradient(starting: rgb(0x5B5CF0), ending: rgb(0x3A1FA8))!.draw(in: body, angle: -70)
        let c = NSPoint(x: body.midX, y: body.midY)
        let r: CGFloat = 300
        func arc(from a0: CGFloat, to a1: CGFloat) {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
            p.lineWidth = 50
            p.lineCapStyle = .round
            rgb(0xF3F2FF).setStroke()
            p.stroke()
            // Arrowhead at the end of the arc, pointing along the direction of travel.
            let t = a1 * .pi / 180
            let tip = NSPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
            let dir = NSPoint(x: -sin(t), y: cos(t))          // counter-clockwise tangent
            let n = NSPoint(x: cos(t), y: sin(t))             // outward normal
            let head = NSBezierPath()
            head.move(to: NSPoint(x: tip.x + dir.x * 70, y: tip.y + dir.y * 70))
            head.line(to: NSPoint(x: tip.x + n.x * 62 - dir.x * 20, y: tip.y + n.y * 62 - dir.y * 20))
            head.line(to: NSPoint(x: tip.x - n.x * 62 - dir.x * 20, y: tip.y - n.y * 62 - dir.y * 20))
            head.close()
            rgb(0xF3F2FF).setFill()
            head.fill()
        }
        arc(from: 200, to: 320)
        arc(from: 20, to: 140)
        text("Я", center: NSPoint(x: c.x - 105, y: c.y + 4), size: 250, color: rgb(0xFFB27A), shadow: 0.25)
        text("A", center: NSPoint(x: c.x + 110, y: c.y + 4), size: 250, color: .white, shadow: 0.25)
    }
}

/// 4. Typing: Я | A with a blinking-caret bar, on clean white.
func caret() {
    drawTile(edge: NSColor.black.withAlphaComponent(0.08)) {
        NSGradient(starting: rgb(0xFFFFFF), ending: rgb(0xECEFF5))!.draw(in: body, angle: -90)
        let y = body.midY + 6
        text("Я", center: NSPoint(x: body.midX - 175, y: y), size: 400, color: rgb(0xE4570F), weight: .heavy)
        text("A", center: NSPoint(x: body.midX + 185, y: y), size: 400, color: rgb(0x1D4ED8), weight: .heavy)
        let bar = NSBezierPath(roundedRect: NSRect(x: body.midX - 14, y: body.midY - 200, width: 28, height: 400), xRadius: 14, yRadius: 14)
        rgb(0x1F2430).setFill()
        bar.fill()
    }
}

let styles: [(String, () -> Void)] = [("split", split), ("keycap", keycap), ("swap", swap), ("caret", caret)]

func render(_ paint: () -> Void, px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: k, y: k)
    paint()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep, _ path: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
switch args.count >= 3 ? args[1] : "" {
case "sheet":
    // Each style large, plus a 64 px copy to judge it at Dock size, numbered.
    let cell = 520, w = cell * styles.count, h = cell + 150
    let sheet = render({}, px: 1)  // placeholder to keep types simple
    _ = sheet
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    rgb(0xF4F4F6).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    for (i, s) in styles.enumerated() {
        let big = NSImage(size: NSSize(width: 480, height: 480))
        big.addRepresentation(render(s.1, px: 480))
        big.draw(in: NSRect(x: i * cell + 20, y: 150, width: 480, height: 480))
        let small = NSImage(size: NSSize(width: 64, height: 64))
        small.addRepresentation(render(s.1, px: 64))
        small.draw(in: NSRect(x: i * cell + 300, y: 40, width: 64, height: 64))
        text("\(i + 1)", center: NSPoint(x: CGFloat(i * cell + 200), y: 72), size: 64, color: rgb(0x1F2430), rounded: false, weight: .bold)
    }
    NSGraphicsContext.restoreGraphicsState()
    try png(rep, args[2])
    print("→ \(args[2])")

case "icns" where args.count >= 4:
    guard let s = styles.first(where: { $0.0 == args[2] }) else { print("unknown style \(args[2])"); exit(1) }
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try png(render(s.1, px: base * scale), iconset.appendingPathComponent(name).path)
        }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", args[3]]
    try p.run()
    p.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    print(p.terminationStatus == 0 ? "→ \(args[3])" : "iconutil failed")

default:
    print("usage: make_icon.swift sheet out.png | icns <split|keycap|swap|caret> out.icns")
    exit(1)
}
