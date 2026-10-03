// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode with approachable concurrency and member import visibility everywhere;
// no default MainActor isolation (the daemon opts into the main actor where it needs it).
let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "lidwake",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lidwake", targets: ["LidwakeCLI"]),
        .executable(name: "lidwake-daemon", targets: ["LidwakeDaemon"]),
        .executable(name: "lidwake-helper", targets: ["LidwakeHelper"]),
    ],
    targets: [
        .target(name: "LidwakeKit", swiftSettings: settings),
        .executableTarget(name: "LidwakeCLI", dependencies: ["LidwakeKit"], swiftSettings: settings),
        .executableTarget(name: "LidwakeDaemon", dependencies: ["LidwakeKit"], swiftSettings: settings),
        .executableTarget(name: "LidwakeHelper", dependencies: ["LidwakeKit"], swiftSettings: settings),
        .testTarget(name: "LidwakeKitTests", dependencies: ["LidwakeKit"], swiftSettings: settings),
    ],
)
