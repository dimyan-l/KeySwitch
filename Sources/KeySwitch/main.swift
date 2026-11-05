import AppKit

// `KeySwitch --selftest` checks the dictionaries and the classifier without any permissions.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

// `KeySwitch --snapshots <folder>` draws the main screens into PNGs, for design review.
if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count {
    Snapshots.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
