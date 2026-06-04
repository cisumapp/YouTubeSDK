// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "YouTubeSDK",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "YouTubeSDK", targets: ["YouTubeSDK"]),
    ],
    targets: [
        .target(
            name: "YouTubeSDK",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "YouTubeSDKTests", dependencies: ["YouTubeSDK"]),
    ]
)
