import AppKit

/// Soft layout-switch sounds. They are synthesized once (a few short decaying tones with a 4 ms attack,
/// so there is no click), kept in memory and played through NSSound. No audio files to bundle.
enum SwitchSound: String, CaseIterable, Identifiable {
    case drop, tick, bell, tone, wood

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drop: "Капля"
        case .tick: "Мягкий клик"
        case .bell: "Колокольчик"
        case .tone: "Тихий тон"
        case .wood: "Дерево"
        }
    }

    fileprivate struct Partial { let from: Double; let to: Double; let glide: Double; let amp: Double; let decay: Double }

    fileprivate var duration: Double {
        switch self { case .drop: 0.22; case .tick: 0.08; case .bell: 0.55; case .tone: 0.3; case .wood: 0.18 }
    }

    fileprivate var partials: [Partial] {
        switch self {
        case .drop: [Partial(from: 880, to: 520, glide: 0.09, amp: 1, decay: 0.07)]
        case .tick: [Partial(from: 1500, to: 1500, glide: 0, amp: 1, decay: 0.012), Partial(from: 3000, to: 3000, glide: 0, amp: 0.3, decay: 0.008)]
        case .bell: [Partial(from: 1319, to: 1319, glide: 0, amp: 1, decay: 0.12), Partial(from: 1976, to: 1976, glide: 0, amp: 0.45, decay: 0.08),
                     Partial(from: 2637, to: 2637, glide: 0, amp: 0.2, decay: 0.05)]
        case .tone: [Partial(from: 587, to: 587, glide: 0, amp: 1, decay: 0.09), Partial(from: 1175, to: 1175, glide: 0, amp: 0.2, decay: 0.05)]
        case .wood: [Partial(from: 660, to: 660, glide: 0, amp: 1, decay: 0.035), Partial(from: 1320, to: 1320, glide: 0, amp: 0.5, decay: 0.02),
                     Partial(from: 1980, to: 1980, glide: 0, amp: 0.2, decay: 0.012)]
        }
    }
}

enum SoundPlayer {
    private static let rate = 44100.0
    private static var cache: [SwitchSound: NSSound] = [:]

    static func play(_ choice: String, volume: Double) {
        play(SwitchSound(rawValue: choice) ?? .drop, volume: volume)
    }

    static func play(_ sound: SwitchSound, volume: Double) {
        let player: NSSound
        if let cached = cache[sound] {
            player = cached
        } else {
            guard let made = NSSound(data: wav(sound)) else { return }
            cache[sound] = made
            player = made
        }
        player.stop()
        player.volume = Float(min(max(volume, 0), 1))
        player.play()
    }

    private static func wav(_ sound: SwitchSound) -> Data {
        let count = Int(rate * sound.duration)
        var samples = [Double](repeating: 0, count: count)
        for p in sound.partials {
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / rate
                let f = p.from + (p.to - p.from) * (p.glide > 0 ? min(1, t / p.glide) : 0)
                phase += 2 * .pi * f / rate
                samples[i] += p.amp * sin(phase) * min(1, t / 0.004) * exp(-t / p.decay)
            }
        }
        let peak = max(samples.map { abs($0) }.max() ?? 1, 0.0001)
        let pcm = samples.map { Int16(($0 / peak * 0.6 * Double(Int16.max)).rounded()) }

        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in pcm { u16(UInt16(bitPattern: s)) }
        return d
    }
}
