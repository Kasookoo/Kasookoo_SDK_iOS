// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "KasookooSDKiOS",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "KasookooSDKiOS", targets: ["KasookooSDKiOS"])
    ],
    targets: [
        .target(name: "KasookooSDKiOS", dependencies: []),
        .testTarget(name: "KasookooSDKiOSTests", dependencies: ["KasookooSDKiOS"])
    ]
)
