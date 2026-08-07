import PackageDescription

let package = Package(
    name: "KasookooSDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "KasookooSDK",
            targets: ["KasookooSDK"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            from: "2.0.0"
        ),
    ],
    targets: [
        .target(
            name: "KasookooSDK",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            path: "Sources/KasookooSDK"
        ),
        .testTarget(
            name: "KasookooSDKTests",
            dependencies: ["KasookooSDK"],
            path: "Tests/KasookooSDKTests"
        ),
    ]
)
