// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UchidenLinkCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "UchidenLinkCore", targets: ["UchidenLinkCore"]),
    ],
    targets: [
        .target(name: "UchidenLinkCore"),
        .testTarget(name: "UchidenLinkCoreTests", dependencies: ["UchidenLinkCore"]),
    ]
)
