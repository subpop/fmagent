// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "fmagent",
    platforms: [
        // Apple Foundation Models image attachments require macOS 27+.
        .macOS(.v27)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/subpop/ACPKit.git", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "fmagent",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ACPKit",
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .testTarget(
            name: "fmagentTests",
            dependencies: ["fmagent"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
    ]
)
