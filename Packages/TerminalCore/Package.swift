// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"])
    ],
    targets: [
        .target(name: "TerminalCore"),
        .executableTarget(name: "TerminalBench", dependencies: ["TerminalCore"]),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
    ],
    swiftLanguageModes: [.v6]
)
