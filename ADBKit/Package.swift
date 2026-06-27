// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADBKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBKit", targets: ["ADBKit"])
    ],
    targets: [
        // Pin the Swift 6 language mode (complete strict concurrency) explicitly
        // rather than inheriting it from the tools version, so it can't silently
        // relax if the tools-version line is ever lowered.
        .target(name: "ADBKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ADBKitTests", dependencies: ["ADBKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
