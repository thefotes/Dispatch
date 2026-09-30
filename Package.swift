// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Dispatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DispatchCore", targets: ["DispatchCore"]),
        .library(name: "DispatchCreatorMicro", targets: ["DispatchCreatorMicro"]),
        .library(name: "DispatchProviders", targets: ["DispatchProviders"]),
        .library(name: "DispatchMacOS", targets: ["DispatchMacOS"]),
        .library(name: "DispatchRuntime", targets: ["DispatchRuntime"]),
        .executable(name: "Dispatch", targets: ["DispatchApp"]),
        .executable(name: "dispatch-probe", targets: ["DispatchProbe"])
    ],
    dependencies: [
        // Test-only: seeded, shrinking property-based tests under Swift Testing.
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "2.0.0")
    ],
    targets: [
        .target(name: "DispatchCore"),
        .target(
            name: "DispatchCreatorMicro",
            dependencies: ["DispatchCore"]
        ),
        .target(
            name: "DispatchProviders",
            dependencies: ["DispatchCore"]
        ),
        .target(
            name: "DispatchMacOS",
            dependencies: ["DispatchCore"]
        ),
        .target(
            name: "DispatchRuntime",
            dependencies: ["DispatchCore"]
        ),
        .executableTarget(
            name: "DispatchApp",
            dependencies: [
                "DispatchCore",
                "DispatchCreatorMicro",
                "DispatchProviders",
                "DispatchMacOS",
                "DispatchRuntime"
            ]
        ),
        .executableTarget(
            name: "DispatchProbe",
            dependencies: ["DispatchCreatorMicro"]
        ),
        .target(
            name: "DispatchTestSupport",
            dependencies: ["DispatchCore"]
        ),
        .testTarget(
            name: "DispatchCoreTests",
            dependencies: [
                "DispatchCore",
                "DispatchTestSupport",
                .product(name: "PropertyBased", package: "swift-property-based")
            ]
        ),
        .testTarget(
            name: "DispatchCreatorMicroTests",
            dependencies: [
                "DispatchCreatorMicro",
                "DispatchTestSupport",
                .product(name: "PropertyBased", package: "swift-property-based")
            ]
        ),
        .testTarget(
            name: "DispatchProvidersTests",
            dependencies: ["DispatchProviders", "DispatchTestSupport"]
        ),
        .testTarget(
            name: "DispatchMacOSTests",
            dependencies: ["DispatchMacOS", "DispatchTestSupport"]
        ),
        .testTarget(
            name: "DispatchRuntimeTests",
            dependencies: ["DispatchRuntime", "DispatchTestSupport"]
        ),
        .testTarget(
            name: "DispatchAppTests",
            dependencies: [
                "DispatchApp",
                "DispatchCore",
                "DispatchCreatorMicro",
                "DispatchProviders",
                "DispatchMacOS",
                "DispatchRuntime",
                "DispatchTestSupport"
            ]
        )
    ]
)
