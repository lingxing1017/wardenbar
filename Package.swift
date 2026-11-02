// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WardenBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WardenBarCore", targets: ["WardenBarCore"]),
        .executable(name: "wardenbar-check", targets: ["WardenBarCheck"])
    ],
    targets: [
        .target(name: "WardenBarCore"),
        .executableTarget(name: "WardenBarCheck", dependencies: ["WardenBarCore"]),
        .testTarget(
            name: "WardenBarCoreTests", dependencies: ["WardenBarCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "WardenBarCheckTests", dependencies: ["WardenBarCheck", "WardenBarCore"])
    ]
)
