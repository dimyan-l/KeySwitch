import Foundation

/// The keyboard's own thread. The event tap lives on its run loop, so every key is handled here,
/// never waiting for the menu bar panel, the toast, SwiftUI or a dictionary reload on the main thread.
final class EngineThread: Thread {
    private var loop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "KeySwitch keyboard"
        qualityOfService = .userInteractive
    }

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A run loop with no sources returns at once: this one keeps it alive.
        var ctx = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &ctx)
        CFRunLoopAddSource(loop, keepAlive, .commonModes)
        ready.signal()
        while !isCancelled { CFRunLoopRunInMode(.defaultMode, 60, false) }
    }

    /// Starts the thread and returns once its run loop accepts work.
    func launch() {
        start()
        ready.wait()
    }

    var runLoop: CFRunLoop { loop! }

    func async(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    func async(after delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) { [weak self] in self?.async(block) }
    }
}
