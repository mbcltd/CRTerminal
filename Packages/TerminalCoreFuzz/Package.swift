// swift-tools-version: 6.0
// libFuzzer harness for TerminalCore. Not part of the normal build/test cycle
// (it links against libFuzzer's main); build and run it via Scripts/fuzz.sh.
import PackageDescription

let package = Package(
    name: "TerminalCoreFuzz",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../TerminalCore")
    ],
    targets: [
        .executableTarget(
            name: "TerminalCoreFuzz",
            dependencies: [.product(name: "TerminalCore", package: "TerminalCore")]
        )
    ]
)
