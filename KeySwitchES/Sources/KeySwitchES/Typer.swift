import CoreGraphics
import Foundation

/// Posts synthetic keyboard events tagged so the event tap lets them through.
/// Context changes cancel a pending run; physical typing is held by SwitchEngine.
final class Typer {
    static let marker: Int64 = 0x4B53_5749 // "KSWI"

    enum Action {
        case backspace(Int)
        case text(String)
        case key(UInt16, CGEventFlags)
        case command(UInt16)
        case pause(TimeInterval)
    }

    private let queue: DispatchQueue
    private let eventSink: (CGEvent) -> Void

    init(queue: DispatchQueue = DispatchQueue(label: "keyswitch.typer"),
         eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.queue = queue
        self.eventSink = eventSink
    }
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private let source = CGEventSource(stateID: .privateState)
    private let perCharDelay: useconds_t = 1_500

    /// Called on the tap/main thread after a rewrite, preserving the original event fields.
    func replay(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        eventSink(event)
    }

    func cancel() {
        lock.lock()
        epoch &+= 1
        lock.unlock()
    }

    /// Main-thread focus observation; workers never query NSWorkspace.
    func updateFrontmostPID(_ pid: pid_t?) {
        lock.lock()
        activePID = pid
        lock.unlock()
    }

    private var activePID: pid_t?

    func run(_ actions: [Action], targetPID: pid_t? = nil, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        let runEpoch = epoch
        let targetPID = targetPID ?? activePID
        lock.unlock()
        queue.async {
            var finished = true
            for action in actions where finished { finished = self.perform(action, epoch: runEpoch, targetPID: targetPID) }
            if let completion { DispatchQueue.main.async { completion(finished && self.isCurrent(runEpoch, targetPID: targetPID)) } }
        }
    }

    private func isCurrent(_ runEpoch: UInt64, targetPID: pid_t?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // An unknown target is never "current": never post into an unidentified app.
        guard let targetPID else { return false }
        return epoch == runEpoch && activePID == targetPID
    }

    private func perform(_ action: Action, epoch runEpoch: UInt64, targetPID: pid_t?) -> Bool {
        switch action {
        case .backspace(let count):
            for _ in 0..<max(0, count) {
                guard postKeyPair(key: 51, flags: [], epoch: runEpoch, targetPID: targetPID) else { return false }
                usleep(perCharDelay)
            }
        case .text(let string):
            for character in string {
                if character == "\n" || character == "\r" {
                    guard postKeyPair(key: 36, flags: .maskShift, epoch: runEpoch, targetPID: targetPID) else { return false }
                } else {
                    guard postUnicodePair(String(character), epoch: runEpoch, targetPID: targetPID) else { return false }
                }
                usleep(perCharDelay)
            }
        case .key(let code, let flags):
            guard postKeyPair(key: code, flags: flags, epoch: runEpoch, targetPID: targetPID) else { return false }
            usleep(perCharDelay)
        case .command(let code):
            guard postKeyPair(key: code, flags: .maskCommand, epoch: runEpoch, targetPID: targetPID) else { return false }
            usleep(20_000)
        case .pause(let interval):
            var remaining = max(0, interval)
            while remaining > 0 {
                guard isCurrent(runEpoch, targetPID: targetPID) else { return false }
                let step = min(remaining, 0.01)
                usleep(useconds_t(step * 1_000_000))
                remaining -= step
            }
        }
        return isCurrent(runEpoch, targetPID: targetPID)
    }

    /// Check before each pair; once started, always post key-up even if cancelled meanwhile.
    /// Do not hold a lock while posting: the event tap may run on the main thread.
    private func postKeyPair(key: UInt16, flags: CGEventFlags, epoch runEpoch: UInt64, targetPID: pid_t?) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        }
        guard isCurrent(runEpoch, targetPID: targetPID) else { return false }
        eventSink(down)
        eventSink(up)
        return true
    }

    /// Unicode is independent of the active keyboard layout.
    private func postUnicodePair(_ string: String, epoch runEpoch: UInt64, targetPID: pid_t?) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        let units = Array(string.utf16)
        for event in [down, up] {
            event.flags = []
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        }
        guard isCurrent(runEpoch, targetPID: targetPID) else { return false }
        eventSink(down)
        eventSink(up)
        return true
    }
}
