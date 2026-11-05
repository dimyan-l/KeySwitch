// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeySwitch",
    platforms: [.macOS("27.0")],
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
        )
    ]
)
