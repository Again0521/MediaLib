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
        .executable(name: "MediaLibServer", targets: ["MediaLibServer"]),
        .library(name: "MediaLibCore", targets: ["MediaLibCore"]),
        .library(name: "MediaLibServerProtocol", targets: ["MediaLibServerProtocol"])
    ],
    targets: [
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            publicHeadersPath: "include",
            cSettings: [
                .define("ARGON2_NO_THREADS"),
                .headerSearchPath(".")
            ]
        ),
        .target(
            name: "MediaLibCore",
            dependencies: ["CArgon2"],
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
            ],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("MetalKit")
            ]
        ),
        .executableTarget(
            name: "MediaLibChecks",
            dependencies: ["MediaLibCore"],
            path: "Sources/MediaLibChecks"
        ),
        .target(
            name: "MediaLibServerProtocol",
            path: "Sources/MediaLibServerProtocol"
        ),
        .executableTarget(
            name: "MediaLibServer",
            dependencies: ["MediaLibCore", "MediaLibServerProtocol"],
            path: "Sources/MediaLibServer"
        ),
        .testTarget(
            name: "MediaLibCoreTests",
            dependencies: ["MediaLibCore"],
            path: "Tests/MediaLibCoreTests"
        ),
        .testTarget(
            name: "MediaLibTests",
            dependencies: ["MediaLib", "MediaLibCore"],
            path: "Tests/MediaLibTests"
        ),
        .testTarget(
            name: "MediaLibServerProtocolTests",
            dependencies: ["MediaLibServerProtocol"],
            path: "Tests/MediaLibServerProtocolTests"
        ),
        .testTarget(
            name: "MediaLibServerTests",
            dependencies: ["MediaLibCore", "MediaLibServer", "MediaLibServerProtocol"],
            path: "Tests/MediaLibServerTests"
        )
    ]
)
