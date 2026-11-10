// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeySwitchES",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeySwitchES",
            path: "Sources/KeySwitchES",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "KeySwitchESTests", dependencies: ["KeySwitchES"], path: "Tests/KeySwitchESTests")
    ]
)
