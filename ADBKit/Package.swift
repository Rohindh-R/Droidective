// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADBKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBKit", targets: ["ADBKit"])
    ],
    targets: [
        .target(name: "ADBKit"),
        .testTarget(name: "ADBKitTests", dependencies: ["ADBKit"]),
    ]
)
