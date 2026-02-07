// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "geforcenow-awdl0",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "geforcenow-awdl0", targets: ["geforcenow-awdl0"]),
        .library(name: "GFNAwdl0Lib", targets: ["GFNAwdl0Lib"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "geforcenow-awdl0",
            dependencies: [
                "GFNAwdl0Lib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "GFNAwdl0Lib",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
        ),
        .testTarget(
            name: "GFNAwdl0Tests",
            dependencies: ["GFNAwdl0Lib"],
        )
    ]
)
