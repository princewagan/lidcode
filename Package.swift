// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode for v0: the runtime is deliberately built on DispatchQueue +
// BSD sockets (the layers that talk to IOKit and launchd are callback-shaped), and
// full Swift 6 sendability annotation is a follow-up rather than a v0 blocker.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "lidcode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LidCodeKit", targets: ["LidCodeKit"]),
        // Named "LidCodeApp", not "LidCode": macOS filesystems are case-insensitive by
        // default, so a "LidCode" product and the "lidcode" CLI resolve to the same file
        // in .build and silently clobber each other. Script/build-app.sh renames the
        // binary to LidCode inside the .app bundle, where nothing else competes for it.
        .executable(name: "LidCodeApp", targets: ["LidCodeApp"]),
        .executable(name: "lidcode", targets: ["LidCodeCli"]),
        .executable(name: "lidcode-helper", targets: ["LidCodeHelper"]),
    ],
    targets: [
        .target(name: "LidCodeKit", swiftSettings: mode),
        .executableTarget(name: "LidCodeApp", dependencies: ["LidCodeKit"], swiftSettings: mode),
        .executableTarget(name: "LidCodeCli", dependencies: ["LidCodeKit"], swiftSettings: mode),
        .executableTarget(name: "LidCodeHelper", dependencies: ["LidCodeKit"], swiftSettings: mode),
        .testTarget(name: "LidCodeKitTest", dependencies: ["LidCodeKit"], swiftSettings: mode),
    ]
)
