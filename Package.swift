// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WLTools",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WLKit", targets: ["WLKit"]),
        .executable(name: "WLInspector", targets: ["WLInspector"]),
        .executable(name: "WLMicroManager", targets: ["WLMicroManager"]),
        .executable(name: "WLProviderBridge", targets: ["WLProviderBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.65.1"),
    ],
    targets: [
        // Device transport, vendor protocol, Herdr client and the bridge engine.
        // Shared by the debug inspector and the menu-bar manager.
        .target(name: "WLKit", path: "Sources/WLKit", plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]),

        // Debug UI: traffic log and manual lighting control.
        .executableTarget(name: "WLInspector", dependencies: ["WLKit"], path: "Sources/WLInspector", plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]),

        // Menu-bar app: runs the bridge in the background.
        .executableTarget(name: "WLMicroManager", dependencies: ["WLKit"], path: "Sources/WLMicroManager", plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]),

        // Standalone companion binary: HerdrProvider behind a
        // ProviderBridgeServer, so a provider can run out of process from
        // Micromanager itself. Optional — WLMicroManager still ships
        // HerdrProvider in-process by default; this is for `config.json`'s
        // `"provider": {"connect": ...}` / `{"launch": ...}`.
        .executableTarget(name: "WLProviderBridge", dependencies: ["WLKit"], path: "Sources/WLProviderBridge", plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]),

        // Fixtures are read from the source directory via #filePath rather than
        // from the test bundle, so they are excluded rather than declared as
        // resources — SwiftPM would otherwise warn about an unhandled file.
        .testTarget(
            name: "WLKitTests",
            dependencies: ["WLKit"],
            path: "Tests/WLKitTests",
            exclude: ["Fixtures"],
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")],
        ),
    ]
)
