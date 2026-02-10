// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "rssss",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "rssss", targets: ["rssss"])
    ],
    dependencies: [
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.0")
    ],
    targets: [
        .executableTarget(
            name: "rssss",
            dependencies: [
                .product(name: "FeedKit", package: "FeedKit")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "rssssTests",
            dependencies: ["rssss"]
        )
    ]
)
