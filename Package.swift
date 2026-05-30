// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MediaLib",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MediaLib", targets: ["MediaLib"]),
        .executable(name: "MediaLibChecks", targets: ["MediaLibChecks"]),
        .library(name: "MediaLibCore", targets: ["MediaLibCore"])
    ],
    targets: [
        .target(
            name: "MediaLibCore",
            path: "Sources/MediaLibCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MediaLib",
            dependencies: ["MediaLibCore"],
            path: "Sources/MediaLib",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MediaLibChecks",
            dependencies: ["MediaLibCore"],
            path: "Sources/MediaLibChecks"
        )
    ]
)
