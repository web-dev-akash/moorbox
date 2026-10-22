// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moorbox",
    // macOS 15 is required by gRPC Swift 2 (EmulatorControl).
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MoorboxCore", targets: ["MoorboxCore"]),
        .library(name: "EmulatorControl", targets: ["EmulatorControl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        // All SDK, runtime, and device logic. No UI imports, fully unit-testable.
        // The app itself is built by the Xcode project (project.yml) and links this library.
        .target(name: "MoorboxCore"),
        // Client for the emulator's gRPC control API (display streaming, input, sensors).
        // Generated code comes from Proto/ via scripts/generate-grpc.sh.
        .target(
            name: "EmulatorControl",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "MoorboxCoreTests",
            dependencies: ["MoorboxCore", "EmulatorControl"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
