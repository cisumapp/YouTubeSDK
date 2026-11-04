// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "YouTubeSDK",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "YouTubeSDK", targets: ["YouTubeSDK"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "YouTubeSDK",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.process("Resources")]
        ),
    ]
)
