// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Tangerine",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TangerineApp", targets: ["TangerineApp"]),
        .executable(name: "tangerine", targets: ["TangerineCLI"]),
        .library(name: "TangerineKit", targets: ["TangerineKit"]),
    ],
    targets: [
        // Shared types: formats, options, backend protocols, output naming, process + ffmpeg helpers.
        .target(name: "TangerineCore", swiftSettings: v5),

        // Engines. Each depends only on TangerineCore so they can evolve independently.
        .target(name: "TangerineImage", dependencies: ["TangerineCore"], swiftSettings: v5),
        .target(name: "TangerineMedia", dependencies: ["TangerineCore"], swiftSettings: v5),
        .target(name: "TangerineDocuments", dependencies: ["TangerineCore"], swiftSettings: v5),

        // Registry that routes conversions and tools to the right engine.
        .target(
            name: "TangerineKit",
            dependencies: ["TangerineCore", "TangerineImage", "TangerineMedia", "TangerineDocuments"],
            swiftSettings: v5
        ),

        .executableTarget(name: "TangerineApp", dependencies: ["TangerineKit"], swiftSettings: v5),
        .executableTarget(name: "TangerineCLI", dependencies: ["TangerineKit"], swiftSettings: v5),

        .testTarget(name: "TangerineImageTests", dependencies: ["TangerineImage"], swiftSettings: v5),
        .testTarget(name: "TangerineMediaTests", dependencies: ["TangerineMedia"], swiftSettings: v5),
        .testTarget(name: "TangerineDocumentsTests", dependencies: ["TangerineDocuments"], swiftSettings: v5),
        .testTarget(name: "TangerineKitTests", dependencies: ["TangerineKit"], swiftSettings: v5),
    ]
)
