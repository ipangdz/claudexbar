// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ClaudexBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudexBar", targets: ["ClaudexBarApp"]),
        .executable(name: "ClaudexBarTestRunner", targets: ["ClaudexBarTestRunner"]),
        .library(name: "ClaudexBarCore", targets: ["ClaudexBarCore"])
    ],
    targets: [
        .target(name: "ClaudexBarCore"),
        .executableTarget(
            name: "ClaudexBarApp",
            dependencies: ["ClaudexBarCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ClaudexBarTestRunner",
            dependencies: ["ClaudexBarCore"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
