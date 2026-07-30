// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WLInspector",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WLInspector",
            path: "Sources/WLInspector"
        )
    ]
)
