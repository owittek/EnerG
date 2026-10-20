// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnerGKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "EnerGCore", targets: ["EnerGCore"]),
        .library(name: "EnerGMac", targets: ["EnerGMac"]),
        .executable(name: "energ-smoke", targets: ["energ-smoke"]),
    ],
    targets: [
        .target(name: "EnerGCore"),
        .testTarget(name: "EnerGCoreTests", dependencies: ["EnerGCore"]),
        .target(
            name: "CPlatform",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Foundation")]
        ),
        .target(name: "EnerGMac", dependencies: ["EnerGCore", "CPlatform"]),
        .executableTarget(name: "energ-smoke", dependencies: ["EnerGCore", "EnerGMac", "CPlatform"]),
    ]
)
