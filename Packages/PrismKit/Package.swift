// swift-tools-version: 6.2
import PackageDescription

let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let uiSettings: [SwiftSetting] = upcoming + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "PrismKit",
    defaultLocalization: "fr",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PrismCore", targets: ["PrismCore"]),
        .library(name: "PrismData", targets: ["PrismData"]),
        .library(name: "PrismDesign", targets: ["PrismDesign"]),
        .library(name: "PrismPlayer", targets: ["PrismPlayer"]),
        .library(name: "PrismUI", targets: ["PrismUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tylerjonesio/vlckit-spm", exact: "3.6.0"),
    ],
    targets: [
        .target(
            name: "PrismCore",
            swiftSettings: upcoming,
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "PrismData",
            dependencies: ["PrismCore"],
            swiftSettings: upcoming
        ),
        .target(
            name: "PrismDesign",
            swiftSettings: uiSettings
        ),
        .target(
            name: "PrismPlayer",
            dependencies: [.product(name: "VLCKitSPM", package: "vlckit-spm")],
            swiftSettings: uiSettings
        ),
        .target(
            name: "PrismUI",
            dependencies: ["PrismCore", "PrismData", "PrismDesign", "PrismPlayer"],
            resources: [.process("Resources")],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "PrismCoreTests",
            dependencies: ["PrismCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: upcoming
        ),
        .testTarget(
            name: "PrismDataTests",
            dependencies: ["PrismData"],
            swiftSettings: upcoming
        ),
        .testTarget(
            name: "PrismPlayerTests",
            dependencies: ["PrismPlayer"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "PrismUITests",
            dependencies: ["PrismUI"],
            swiftSettings: uiSettings
        ),
    ]
)
