import CoreGraphics
import Foundation

/// Posts synthetic keyboard events. Every event is tagged with `marker` so our own event tap
/// lets it through untouched.
final class Typer {
    static let marker: Int64 = 0x4B53_5749 // "KSWI"

    enum Action {
        case backspace(Int)
        case forwardDelete(Int)
        case left(Int)                   // ← n times: puts the caret back inside a retyped word
        case text(String)
        case key(UInt16, CGEventFlags)   // e.g. Return with Shift
        case command(UInt16)             // ⌘ + key code (8 = C, 9 = V)
        case pause(TimeInterval)
    }

    private let queue = DispatchQueue(label: "keyswitch.typer")
    private let source = CGEventSource(stateID: .privateState)
    private let perCharDelay: useconds_t = 1_500
    /// Most apps take a whole word in one Unicode event (at most 20 UTF-16 units); "compatible typing" in
    /// Settings goes back to one character per event for the rare app that keeps only the first one.
    private static let chunk = 20
    private var compatible: Bool { Settings.shared.compatibleTyping }
    private var keyDelay: useconds_t { compatible ? perCharDelay : 800 }

    /// Frontmost app as last reported on the main thread; read here from the typing queue.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _frontPID: pid_t = 0
    static var frontPID: pid_t {
        get { lock.lock(); defer { lock.unlock() }; return _frontPID }
        set { lock.lock(); _frontPID = newValue; lock.unlock() }
    }
    nonisolated(unsafe) private var _cancelled = false
    private var cancelled: Bool {
        get { Self.lock.lock(); defer { Self.lock.unlock() }; return _cancelled }
        set { Self.lock.lock(); _cancelled = newValue; Self.lock.unlock() }
    }
    /// The app the current run started in: if another app comes to the front, the rest is not typed there.
    nonisolated(unsafe) private var targetPID: pid_t = 0

    /// Where `run`'s completion is called: the keyboard thread once the engine has one, else the main thread.
    var deliver: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// Self-test only: actions go here, synchronously, instead of to the system.
    var sink: ((Action) -> Void)?

    /// Stops the current run before its next key (a click elsewhere, focus moved).
    func cancel() { cancelled = true }

    /// `completion(true)` when every action was posted, `false` when the run stopped early
    /// because focus left the app or `cancel()` was called.
    func run(_ actions: [Action], completion: ((Bool) -> Void)? = nil) {
        if let sink {
            actions.forEach(sink)
            completion?(true)
            return
        }
        let pid = Self.frontPID
        queue.async {
            self.cancelled = false
            self.targetPID = pid
            var finished = true
            for a in actions where finished { finished = self.perform(a) }
            if let completion { self.deliver { completion(finished) } }
        }
    }

    private var mayContinue: Bool {
        !cancelled && (targetPID == 0 || Self.frontPID == targetPID)
    }

    private func perform(_ a: Action) -> Bool {
        guard mayContinue else { return false }
        switch a {
        case .backspace(let n):
            for _ in 0..<max(0, n) {
                guard mayContinue else { return false }
                post(key: 51, down: true, flags: [])
                post(key: 51, down: false, flags: [])
                usleep(keyDelay)
            }
        case .forwardDelete(let n), .left(let n):
            let code: UInt16 = if case .left = a { 123 } else { 117 }
            for _ in 0..<max(0, n) {
                guard mayContinue else { return false }
                post(key: code, down: true, flags: [])
                post(key: code, down: false, flags: [])
                usleep(perCharDelay)
            }
        case .text(let s):
            return type(s)
        case .key(let code, let flags):
            post(key: code, down: true, flags: flags)
            post(key: code, down: false, flags: flags)
            usleep(perCharDelay)
        case .command(let code):
            post(key: code, down: true, flags: .maskCommand)
            post(key: code, down: false, flags: .maskCommand)
            usleep(20_000)
        case .pause(let t):
            usleep(useconds_t(t * 1_000_000))
        }
        return true
    }

    private func post(key: UInt16, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Typer.marker)
        e.post(tap: .cghidEventTap)
    }

    /// Types characters directly as Unicode, independent of the active layout: whole runs of up to 20 UTF-16
    /// units per event (never splitting a character), or one character per event in compatible mode.
    private func type(_ s: String) -> Bool {
        var run: [UInt16] = []
        func flush() {
            guard !run.isEmpty else { return }
            postUnicode(run)
            run = []
            usleep(compatible ? perCharDelay : 1_000)
        }
        for ch in s {
            guard mayContinue else { return false }
            if ch == "\n" || ch == "\r" {
                flush()
                post(key: 36, down: true, flags: .maskShift) // Shift+Return = new line, never "send"
                post(key: 36, down: false, flags: .maskShift)
                usleep(perCharDelay)
                continue
            }
            let units = Array(String(ch).utf16)
            if compatible || run.count + units.count > Self.chunk { flush() }
            run += units
        }
        flush()
        return true
    }

    private func postUnicode(_ units: [UInt16]) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            units.withUnsafeBufferPointer { buf in
                e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            e.setIntegerValueField(.eventSourceUserData, value: Typer.marker)
            e.post(tap: .cghidEventTap)
        }
    }
}
