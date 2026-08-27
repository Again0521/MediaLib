// swift-tools-version: 5.9

import PackageDescription
import Foundation

/// Cloud storage conflict copies are recovery artifacts, not Swift sources. Keep them on disk,
/// but prevent SwiftPM from compiling duplicate declarations when a checkout is being reconciled.
func sourceArtifactExclusions(in relativeRoot: String) -> [String] {
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let targetRoot = packageRoot.appendingPathComponent(relativeRoot, isDirectory: true)
    guard let files = FileManager.default.enumerator(
        at: targetRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    let sourceFiles = files.compactMap { entry -> URL? in
        guard let url = entry as? URL else { return nil }
        guard url.pathExtension == "swift" else { return nil }
        return url
    }
    var exclusions = sourceFiles.compactMap { url -> String? in
        let name = url.lastPathComponent
        guard name.contains(".sync-conflict-") || name.hasSuffix(" 2.swift") else {
            return nil
        }
        return String(url.path.dropFirst(targetRoot.path.count + 1))
    }

    // Swift emits one object file per basename. Shallow duplicate basenames are recovery copies
    // produced beside the organized test tree, so prefer the canonical, more-specific path.
    let candidates = Dictionary(grouping: sourceFiles) { $0.lastPathComponent }
    for duplicates in candidates.values where duplicates.count > 1 {
        let canonical = duplicates.sorted {
            let lhsDepth = $0.pathComponents.count
            let rhsDepth = $1.pathComponents.count
            return lhsDepth == rhsDepth ? $0.path < $1.path : lhsDepth > rhsDepth
        }.first
        for url in duplicates where url != canonical {
            exclusions.append(String(url.path.dropFirst(targetRoot.path.count + 1)))
        }
    }
    return Array(Set(exclusions)).sorted()
}

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
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.26.0"
        )
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
            exclude: sourceArtifactExclusions(in: "Sources/MediaLibCore"),
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MediaLib",
            dependencies: ["MediaLibCore", "MediaLibServerProtocol"],
            path: "Sources/MediaLib",
            exclude: sourceArtifactExclusions(in: "Sources/MediaLib"),
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
            path: "Sources/MediaLibChecks",
            exclude: sourceArtifactExclusions(in: "Sources/MediaLibChecks")
        ),
        .target(
            name: "MediaLibServerProtocol",
            path: "Sources/MediaLibServerProtocol",
            exclude: sourceArtifactExclusions(in: "Sources/MediaLibServerProtocol")
        ),
        .executableTarget(
            name: "MediaLibServer",
            dependencies: [
                "MediaLibCore",
                "MediaLibServerProtocol",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird")
            ],
            path: "Sources/MediaLibServer",
            exclude: sourceArtifactExclusions(in: "Sources/MediaLibServer"),
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MediaLibCoreTests",
            dependencies: ["MediaLibCore"],
            path: "Tests/MediaLibCoreTests",
            exclude: sourceArtifactExclusions(in: "Tests/MediaLibCoreTests")
        ),
        .testTarget(
            name: "MediaLibTests",
            dependencies: ["MediaLib", "MediaLibCore"],
            path: "Tests/MediaLibTests",
            exclude: sourceArtifactExclusions(in: "Tests/MediaLibTests")
        ),
        .testTarget(
            name: "MediaLibServerProtocolTests",
            dependencies: ["MediaLibServerProtocol"],
            path: "Tests/MediaLibServerProtocolTests",
            exclude: sourceArtifactExclusions(in: "Tests/MediaLibServerProtocolTests")
        ),
        .testTarget(
            name: "MediaLibServerTests",
            dependencies: ["MediaLibCore", "MediaLibServer", "MediaLibServerProtocol"],
            path: "Tests/MediaLibServerTests",
            exclude: sourceArtifactExclusions(in: "Tests/MediaLibServerTests")
        )
    ]
)
