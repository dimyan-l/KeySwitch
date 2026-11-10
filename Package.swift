// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeySwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeySwitch",
            path: "Sources/KeySwitch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "KeySwitchTests", dependencies: ["KeySwitch"], path: "Tests/KeySwitchTests")
    ]
)
