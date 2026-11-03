// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WardenBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WardenBarCore", targets: ["WardenBarCore"]),
        .library(name: "WardenBarDesktop", targets: ["WardenBarDesktop"]),
        .executable(name: "WardenBar", targets: ["WardenBarApp"]),
        .executable(name: "wardenbar-check", targets: ["WardenBarCheck"])
    ],
    targets: [
        .target(name: "WardenBarCore"),
        .target(name: "WardenBarDesktop", dependencies: ["WardenBarCore"]),
        .executableTarget(name: "WardenBarApp", dependencies: ["WardenBarCore", "WardenBarDesktop"]),
        .executableTarget(name: "WardenBarCheck", dependencies: ["WardenBarCore"]),
        .testTarget(
            name: "WardenBarCoreTests", dependencies: ["WardenBarCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "WardenBarCheckTests", dependencies: ["WardenBarCheck", "WardenBarCore"]),
        .testTarget(name: "WardenBarDesktopTests", dependencies: ["WardenBarDesktop", "WardenBarCore", "WardenBarApp"])
    ]
)
