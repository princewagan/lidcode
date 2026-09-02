// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WarpMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "warp-monitor", targets: ["WarpMonitorCLI"]),
        .executable(name: "WarpMonitorApp", targets: ["WarpMonitorApp"]),
        .library(name: "WarpMonitor", targets: ["WarpMonitor"]),
    ],
    targets: [
        // System SQLite3 wrapper
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: nil,
            providers: nil
        ),
        // Core library: SQLite reader, log tailer, state manager, models, pusher
        .target(
            name: "WarpMonitor",
            dependencies: ["CSQLite"],
            path: "Sources/WarpMonitor",
            swiftSettings: [
                .unsafeFlags(["-Xlinker", "-lsqlite3"])
            ]
        ),
        // CLI: prints JSON to stdout, push mode, single-shot mode
        .executableTarget(
            name: "WarpMonitorCLI",
            dependencies: ["WarpMonitor"],
            path: "Sources/WarpMonitorCLI"
        ),
        // Menu bar app: SwiftUI MenuBarExtra, no Dock icon
        .executableTarget(
            name: "WarpMonitorApp",
            dependencies: ["WarpMonitor"],
            path: "Sources/WarpMonitorApp",
            swiftSettings: [
                .unsafeFlags(["-Xlinker", "-lsqlite3"])
            ]
        ),
        // Tests
        .testTarget(
            name: "WarpMonitorTests",
            dependencies: ["WarpMonitor"],
            path: "Tests/WarpMonitorTests"
        ),
    ]
)
