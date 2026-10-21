// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moorbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoorboxCore", targets: ["MoorboxCore"]),
    ],
    targets: [
        // All SDK, runtime, and device logic. No UI imports, fully unit-testable.
        // The app itself is built by the Xcode project (project.yml) and links this library.
        .target(name: "MoorboxCore"),
        .testTarget(
            name: "MoorboxCoreTests",
            dependencies: ["MoorboxCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
