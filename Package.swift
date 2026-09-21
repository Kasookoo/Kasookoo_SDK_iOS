// swift-tools-version: 5.9
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
        // Pinned to 2.13.x deliberately. Two separate reasons, both real:
        //
        // 1. LiveKit 2.17.0 added a `CLiveKitProto` target that vendors nanopb
        //    0.4.9.2 and exposes it as a public header named `pb.h`. Firebase
        //    vendors nanopb 0.3.9.10 and pins it, so in any app using both,
        //    LiveKit's generated headers resolve `#include <pb.h>` to Firebase's
        //    older copy and fail the PB_PROTO_HEADER_VERSION guard (40 vs 30).
        //    A consumer cannot reconcile this.
        //    See livekit/client-sdk-swift issue #1133.
        //
        // 2. 2.13 is the version this SDK and its host app are written and
        //    tested against. An open `from:` range silently upgraded to 2.16 on
        //    a cache reset and broke call handling at compile time.
        //
        // Moving off 2.13 is a deliberate upgrade with its own testing, not
        // something a dependency resolution should do on its own.
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            .upToNextMinor(from: "2.13.0")
        ),
        // OpenTelemetry API and SDK only. On iOS this package has no external
        // dependencies of its own, so it adds nothing to a tenant's graph.
        //
        // The matching exporter package (`opentelemetry-swift`) is deliberately
        // NOT used: it pulls in grpc-swift, SwiftNIO, swift-crypto,
        // swift-certificates, Thrift and swift-protobuf, and its nanopb headers
        // collide with LiveKit's. `OTLPJSONExporter.swift` replaces it.
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
            from: "2.5.1"
        ),
    ],
    targets: [
        .target(
            name: "KasookooSDK",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
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
