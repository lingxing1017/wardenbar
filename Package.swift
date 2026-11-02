// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WardenBar",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WardenBarCore", targets: ["WardenBarCore"])],
    targets: [
        .target(name: "WardenBarCore"),
        .testTarget(name: "WardenBarCoreTests", dependencies: ["WardenBarCore"])
    ]
)
