// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CRTRendering",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CRTRendering", targets: ["CRTRendering"])
    ],
    dependencies: [
        .package(path: "../TerminalCore")
    ],
    targets: [
        .target(
            name: "CRTRendering",
            dependencies: [.product(name: "TerminalCore", package: "TerminalCore")],
            resources: [.copy("Presets"), .copy("Fonts")]
        ),
        .testTarget(name: "CRTRenderingTests", dependencies: ["CRTRendering"]),
    ],
    swiftLanguageModes: [.v6]
)
