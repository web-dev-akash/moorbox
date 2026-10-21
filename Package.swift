// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moorbox",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Moorbox", targets: ["Moorbox"]),
    ],
    targets: [
        // All SDK, runtime, and device logic. No UI imports, fully unit-testable.
        .target(name: "MoorboxCore"),
        // SwiftUI app shell.
        .executableTarget(name: "Moorbox", dependencies: ["MoorboxCore"]),
        .testTarget(
            name: "MoorboxCoreTests",
            dependencies: ["MoorboxCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
