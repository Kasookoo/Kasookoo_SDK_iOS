// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

//import PackageDescription
//
//let package = Package(
//    name: "KasookooSDK",
//    products: [
//        // Products define the executables and libraries a package produces, making them visible to other packages.
//        .library(
//            name: "KasookooSDK",
//            targets: ["KasookooSDK"]
//        ),
//    ],
//    targets: [
//        // Targets are the basic building blocks of a package, defining a module or a test suite.
//        // Targets can depend on other targets in this package and products from dependencies.
//        .target(
//            name: "KasookooSDK"
//        ),
//        .testTarget(
//            name: "KasookooSDKTests",
//            dependencies: ["KasookooSDK"]
//        ),
//    ],
//    swiftLanguageModes: [.v6]
//)

// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KasookooSDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        // The main library product that consumers will import
        .library(
            name: "KasookooSDK",
            targets: ["KasookooSDK"]
        ),
    ],
    dependencies: [
        // LiveKit Swift SDK for WebRTC functionality
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            from: "2.0.0"
        ),
    ],
    targets: [
        // Main SDK target
        .target(
            name: "KasookooSDK",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            path: "Sources/KasookooSDK"
        ),
        
        // Test target
        .testTarget(
            name: "KasookooSDKTests",
            dependencies: ["KasookooSDK"],
            path: "Tests/KasookooSDKTests"
        ),
    ]
)
