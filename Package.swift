// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChargeWatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GaugeCore", targets: ["GaugeCore"]),
        .executable(name: "gaugectl", targets: ["gaugectl"]),
        .executable(name: "ChargeWatch", targets: ["ChargeWatch"]),
        .executable(name: "gaugecheck", targets: ["gaugecheck"]),
    ],
    targets: [
        // Pure Foundation logic for the gauging plist. No UI, no restart code.
        .target(name: "GaugeCore"),
        // Small command-line helper. The only code that ever runs as root.
        .executableTarget(name: "gaugectl", dependencies: ["GaugeCore"]),
        // Menu-bar item and dashboard.
        .executableTarget(name: "ChargeWatch", dependencies: ["GaugeCore"]),
        // Fixture checks as a plain executable: `swift run gaugecheck`.
        // No XCTest, so it runs with the Command Line Tools alone.
        .executableTarget(name: "gaugecheck", dependencies: ["GaugeCore"]),
    ]
)
