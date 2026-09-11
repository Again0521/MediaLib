import Foundation
import Darwin
import XCTest

final class PackageDMGScriptPathTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testPackageScriptResolvesRelocatedRootWithSpacesAndUnicode() throws {
        let root = try makeTemporaryPackageRoot(name: "MediaLib relocated 测试 root")

        let paths = try runPathProbe(script: root.appendingPathComponent("scripts/package_dmg.sh"))

        XCTAssertEqual(canonicalPath(paths["SCRIPT_DIR"]), canonicalPath(root.appendingPathComponent("scripts")))
        XCTAssertEqual(canonicalPath(paths["ROOT_DIR"]), canonicalPath(root))
        XCTAssertTrue(paths["BUILD_ROOT"]?.hasPrefix("/private/tmp/MediaLib-package-") == true)
        XCTAssertEqual(paths["SWIFT_BUILD_DIR"], paths["BUILD_ROOT"].map { "\($0)/swiftpm-build" })
        XCTAssertFalse(paths["SWIFT_BUILD_DIR"]?.hasPrefix(root.appendingPathComponent(".build").path) == true)
    }

    func testPackageScriptResolvesRealRootWhenInvokedThroughSymlink() throws {
        let root = try makeTemporaryPackageRoot(name: "MediaLib real source root")
        let launcherDirectory = try makeTemporaryDirectory(name: "MediaLib package launchers")
        let linkURL = launcherDirectory.appendingPathComponent("package_dmg_link.sh")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: root.appendingPathComponent("scripts/package_dmg.sh")
        )

        let paths = try runPathProbe(script: linkURL)

        XCTAssertEqual(canonicalPath(paths["SCRIPT_DIR"]), canonicalPath(root.appendingPathComponent("scripts")))
        XCTAssertEqual(canonicalPath(paths["ROOT_DIR"]), canonicalPath(root))
    }

    func testPackageScriptUsesSourceSpecificTemporaryDirectories() throws {
        let firstRoot = try makeTemporaryPackageRoot(name: "MediaLib source one")
        let secondRoot = try makeTemporaryPackageRoot(name: "MediaLib source two")

        let firstPaths = try runPathProbe(script: firstRoot.appendingPathComponent("scripts/package_dmg.sh"))
        let secondPaths = try runPathProbe(script: secondRoot.appendingPathComponent("scripts/package_dmg.sh"))

        XCTAssertNotEqual(firstPaths["BUILD_ROOT"], secondPaths["BUILD_ROOT"])
        XCTAssertNotEqual(firstPaths["SWIFT_MODULE_CACHE"], secondPaths["SWIFT_MODULE_CACHE"])
        XCTAssertNotEqual(firstPaths["SWIFT_BUILD_DIR"], secondPaths["SWIFT_BUILD_DIR"])
    }

    func testPackageScriptBuildsThroughIsolatedScratchPath() throws {
        let script = try String(contentsOf: repositoryPackageScriptURL(), encoding: .utf8)

        XCTAssertTrue(script.contains("--package-path \"$ROOT_DIR\""))
        XCTAssertTrue(script.contains("--scratch-path \"$SWIFT_BUILD_DIR\""))
        XCTAssertTrue(script.contains("--show-bin-path"))
        XCTAssertFalse(script.contains("\"$ROOT_DIR/.build/release/$APP_NAME\""))
    }

    func testPackageScriptUsesVerifiedReleaseMetadataInsteadOfHardcodedVersion() throws {
        let script = try String(contentsOf: repositoryPackageScriptURL(), encoding: .utf8)

        XCTAssertTrue(script.contains("release_metadata.py"))
        XCTAssertTrue(script.contains("--check"))
        XCTAssertTrue(script.contains("--get productVersion"))
        XCTAssertTrue(script.contains("--get buildNumber"))
        XCTAssertTrue(script.contains("--write-info-plist"))
        XCTAssertFalse(script.contains("VERSION=\"1.5.5\""))
        XCTAssertFalse(script.contains("BUILD=\"97\""))
    }

    func testPackageScriptBundlesBothFFmpegAndFFprobeForServerPlayback() throws {
        let script = try String(contentsOf: repositoryPackageScriptURL(), encoding: .utf8)

        XCTAssertTrue(script.contains("for tool_name in ffmpeg ffprobe"))
        XCTAssertTrue(script.contains("$APP_BUNDLE/Contents/MacOS/$tool_name"))
        XCTAssertTrue(script.contains("required $label was not found"))
        XCTAssertTrue(script.contains("FFPROBE_SOURCE="))
    }

    func testPackagePreflightFailsWhenAnyRequiredRuntimeIsMissing() throws {
        let root = try makeTemporaryPackageRoot(name: "MediaLib missing runtime")
        let runtimeDirectory = try makeTemporaryDirectory(name: "MediaLib runtime fixtures")
        let libmpv = runtimeDirectory.appendingPathComponent("libmpv.2.dylib")
        let ffmpeg = runtimeDirectory.appendingPathComponent("ffmpeg")
        let ffprobe = runtimeDirectory.appendingPathComponent("ffprobe")
        try Data("libmpv".utf8).write(to: libmpv)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: ffmpeg)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: ffprobe)

        let completeEnvironment = [
            "MEDIALIB_PACKAGE_DMG_PREFLIGHT_ONLY": "1",
            "MEDIALIB_LIBMPV_PATH": libmpv.path,
            "MEDIALIB_FFMPEG_PATH": ffmpeg.path,
            "MEDIALIB_FFPROBE_PATH": ffprobe.path,
        ]
        for (label, variable) in [
            ("libmpv", "MEDIALIB_LIBMPV_PATH"),
            ("ffmpeg", "MEDIALIB_FFMPEG_PATH"),
            ("ffprobe", "MEDIALIB_FFPROBE_PATH"),
        ] {
            var environment = completeEnvironment
            environment[variable] = runtimeDirectory.appendingPathComponent("missing-\(label)").path
            let result = try runProcess(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [root.appendingPathComponent("scripts/package_dmg.sh").path],
                environment: environment
            )

            XCTAssertNotEqual(result.status, 0, label)
            XCTAssertTrue(result.stderr.contains("required \(label) was not found"), result.stderr)
        }
    }

    func testPackageScriptRemovesNestedPythonLauncherWithHostDependency() throws {
        let script = try String(contentsOf: repositoryPackageScriptURL(), encoding: .utf8)

        XCTAssertTrue(script.contains("Resources/Python.app"))
    }

    func testPackageScriptSerializesWritesToPublicDistributionArtifact() throws {
        let script = try String(contentsOf: repositoryPackageScriptURL(), encoding: .utf8)

        XCTAssertTrue(script.contains("/usr/bin/shlock"))
        XCTAssertTrue(script.contains("PACKAGE_LOCK_PATH"))
    }

    func testPackagePreflightRejectsMissingFFprobeWithClearDiagnostic() throws {
        let root = try makeTemporaryPackageRoot(name: "MediaLib missing ffprobe")
        let runtimeDirectory = try makeTemporaryDirectory(name: "MediaLib missing ffprobe fixtures")
        let libmpv = runtimeDirectory.appendingPathComponent("libmpv.2.dylib")
        let ffmpeg = runtimeDirectory.appendingPathComponent("ffmpeg")
        try Data("libmpv".utf8).write(to: libmpv)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: ffmpeg)

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [root.appendingPathComponent("scripts/package_dmg.sh").path],
            environment: [
                "MEDIALIB_PACKAGE_DMG_PREFLIGHT_ONLY": "1",
                "MEDIALIB_LIBMPV_PATH": libmpv.path,
                "MEDIALIB_FFMPEG_PATH": ffmpeg.path,
                "MEDIALIB_FFPROBE_PATH": runtimeDirectory.appendingPathComponent("missing-ffprobe").path,
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("required ffprobe was not found"), result.stderr)
    }

    func testPackagePreflightAcceptsExplicitCompleteRuntimeSet() throws {
        let root = try makeTemporaryPackageRoot(name: "MediaLib complete runtime")
        let runtimeDirectory = try makeTemporaryDirectory(name: "MediaLib complete fixtures")
        let libmpv = runtimeDirectory.appendingPathComponent("libmpv.2.dylib")
        let ffmpeg = runtimeDirectory.appendingPathComponent("ffmpeg")
        let ffprobe = runtimeDirectory.appendingPathComponent("ffprobe")
        try Data("libmpv".utf8).write(to: libmpv)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: ffmpeg)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: ffprobe)

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [root.appendingPathComponent("scripts/package_dmg.sh").path],
            environment: [
                "MEDIALIB_PACKAGE_DMG_PREFLIGHT_ONLY": "1",
                "MEDIALIB_LIBMPV_PATH": libmpv.path,
                "MEDIALIB_FFMPEG_PATH": ffmpeg.path,
                "MEDIALIB_FFPROBE_PATH": ffprobe.path,
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("runtime-preflight: complete"), result.stdout)
    }

    func testBundleRuntimeValidatorRejectsWrongArchitectureAndHostDependency() throws {
        let bundle = try makeRuntimeFixtureBundle()
        let validator = try repositoryScriptURL(named: "check_bundle_runtime.sh")

        let fakeLipo = try repositoryScriptURL(named: "test_support/package_fake_lipo.sh")
        let fakeOtool = try repositoryScriptURL(named: "test_support/package_fake_otool.sh")
        let wrongArchitecture = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [validator.path, bundle.path, "arm64"],
            environment: [
                "MEDIALIB_LIPO": fakeLipo.path,
                "MEDIALIB_OTOOL": fakeOtool.path,
                "FAKE_ARCH_RESULT": "x86_64",
            ]
        )
        XCTAssertNotEqual(wrongArchitecture.status, 0, wrongArchitecture.stdout + wrongArchitecture.stderr)
        XCTAssertTrue(wrongArchitecture.stderr.contains("missing required architecture arm64"), wrongArchitecture.stderr)

        let hostDependency = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [validator.path, bundle.path, "arm64"],
            environment: [
                "MEDIALIB_LIPO": fakeLipo.path,
                "MEDIALIB_OTOOL": fakeOtool.path,
                "FAKE_ARCH_RESULT": "arm64",
                "FAKE_DEPENDENCY": "/opt/homebrew/lib/libescaped.dylib",
            ]
        )
        XCTAssertNotEqual(hostDependency.status, 0, hostDependency.stdout + hostDependency.stderr)
        XCTAssertTrue(hostDependency.stderr.contains("unbundled host dependency"), hostDependency.stderr)

        let unresolvedRPath = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [validator.path, bundle.path, "arm64"],
            environment: [
                "MEDIALIB_LIPO": fakeLipo.path,
                "MEDIALIB_OTOOL": fakeOtool.path,
                "FAKE_ARCH_RESULT": "arm64",
                "FAKE_DEPENDENCY": "@rpath/libmissing.dylib",
            ]
        )
        XCTAssertNotEqual(unresolvedRPath.status, 0, unresolvedRPath.stdout + unresolvedRPath.stderr)
        XCTAssertTrue(unresolvedRPath.stderr.contains("unresolved bundled dependency"), unresolvedRPath.stderr)
    }

    func testBuildManifestIsDeterministicAndDoesNotLeakPaths() throws {
        let output = try makeTemporaryDirectory(name: "MediaLib manifest").appendingPathComponent("manifest.json")
        let generator = try repositoryScriptURL(named: "generate_build_manifest.swift")
        let arguments = [
            generator.path, output.path, "1.5.5", "97", "deadbeef", "true", "arm64",
            "Swift 6.2", "libmpv 2.3.0", "ffmpeg 8.1.1", "ffprobe 8.1.1", "abc123",
        ]

        let first = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: arguments,
            environment: ["HOME": "/Users/private-builder", "SECRET_TOKEN": "do-not-leak"]
        )
        XCTAssertEqual(first.status, 0, first.stderr)
        let firstData = try Data(contentsOf: output)

        let second = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: arguments,
            environment: ["HOME": "/Users/another-builder", "SECRET_TOKEN": "another-secret"]
        )
        XCTAssertEqual(second.status, 0, second.stderr)
        let secondData = try Data(contentsOf: output)

        XCTAssertEqual(firstData, secondData)
        let text = String(decoding: secondData, as: UTF8.self)
        XCTAssertFalse(text.contains("/Users/"), text)
        XCTAssertFalse(text.contains("SECRET_TOKEN"), text)
        XCTAssertFalse(text.contains("do-not-leak"), text)
        XCTAssertTrue(text.contains("\"dependencyDigest\""), text)
    }

    func testPackagePublishesOnlyAfterCandidateAndMountedValidation() throws {
        let script = try String(contentsOf: repositoryPackageScriptURL(), encoding: .utf8)
        let publisher = try String(
            contentsOf: repositoryScriptURL(named: "publish_verified_dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("CANDIDATE_DMG_PATH"))
        XCTAssertTrue(script.contains("check_bundle_runtime.sh"))
        XCTAssertTrue(script.contains("hdiutil attach \"$TEMP_DMG_PATH\""))
        XCTAssertTrue(script.contains("publish_verified_dmg.sh"))
        XCTAssertTrue(publisher.contains("mv -f \"$CANDIDATE_DMG_PATH\" \"$DMG_PATH\""))
        XCTAssertFalse(script.contains("rm -rf \"$APP_COPY\" \"$LEGACY_APP_COPY\" \"$DMG_PATH\""))
    }

    func testFailedDMGPublishPreservesLastKnownGoodArtifact() throws {
        let directory = try makeTemporaryDirectory(name: "MediaLib atomic publish")
        let temporaryDMG = directory.appendingPathComponent("fresh.dmg")
        let candidateDMG = directory.appendingPathComponent("candidate.dmg")
        let publicDMG = directory.appendingPathComponent("MediaLib.dmg")
        try Data("fresh-unverified".utf8).write(to: temporaryDMG)
        let previousBytes = Data("last-known-good".utf8)
        try previousBytes.write(to: publicDMG)

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                try repositoryScriptURL(named: "publish_verified_dmg.sh").path,
                temporaryDMG.path,
                candidateDMG.path,
                publicDMG.path,
            ],
            environment: ["MEDIALIB_HDIUTIL": "/usr/bin/false"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try Data(contentsOf: publicDMG), previousBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateDMG.path))
    }

    func testPackageScriptCanSeedRepositoriesWithoutReusingBuildProducts() throws {
        let script = try String(contentsOf: repositoryPackageScriptURL(), encoding: .utf8)

        XCTAssertTrue(script.contains("MEDIALIB_PACKAGE_SEED_LOCAL_REPOSITORIES"))
        XCTAssertTrue(script.contains("$ROOT_DIR/.build/repositories/."))
        XCTAssertTrue(script.contains("$SWIFT_BUILD_DIR/repositories/"))
        XCTAssertTrue(script.contains("swift build \"${swift_package_args[@]}\" --product \"$APP_NAME\""))
        XCTAssertTrue(script.contains("swift build \"${swift_package_args[@]}\" --product \"$SERVER_NAME\""))
    }

    private func makeTemporaryPackageRoot(name: String) throws -> URL {
        let root = try makeTemporaryDirectory(name: name)
        let scriptsDirectory = root.appendingPathComponent("scripts", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let protocolDirectory = root.appendingPathComponent("Sources/MediaLibServerProtocol", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protocolDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repositoryPackageScriptURL(),
            to: scriptsDirectory.appendingPathComponent("package_dmg.sh")
        )
        try FileManager.default.copyItem(
            at: try repositoryScriptURL(named: "release_metadata.py"),
            to: scriptsDirectory.appendingPathComponent("release_metadata.py")
        )
        let repositoryRoot = try repositoryPackageScriptURL().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("config/release.json"),
            to: configDirectory.appendingPathComponent("release.json")
        )
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Sources/MediaLibServerProtocol/GeneratedReleaseMetadata.swift"),
            to: protocolDirectory.appendingPathComponent("GeneratedReleaseMetadata.swift")
        )
        for name in ["README.md", "README.en.md", "README.ja.md"] {
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent(name),
                to: root.appendingPathComponent(name)
            )
        }
        return root
    }

    func testRejectedConcurrentPackageLeavesActiveScratchAndCandidateUntouched() throws {
        let root = try makeTemporaryPackageRoot(name: "MediaLib active package")
        let script = root.appendingPathComponent("scripts/package_dmg.sh")
        let paths = try runPathProbe(script: script)
        let scratch = URL(fileURLWithPath: try XCTUnwrap(paths["BUILD_ROOT"]))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        temporaryDirectories.append(scratch)
        let marker = scratch.appendingPathComponent("active-build")
        try Data("keep build".utf8).write(to: marker)
        let dist = root.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        let lock = dist.appendingPathComponent(".medialib-package.lock")
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: lock)
        let candidate = dist.appendingPathComponent(".MediaLib-default.candidate.dmg")
        try Data("keep candidate".utf8).write(to: candidate)
        let runtime = root.appendingPathComponent("runtime")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: runtime)

        let result = try runProcess(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path], environment: [
            "MEDIALIB_LIBMPV_PATH": runtime.path,
            "MEDIALIB_FFMPEG_PATH": runtime.path,
            "MEDIALIB_FFPROBE_PATH": runtime.path,
            "MEDIALIB_PACKAGE_INSTANCE": "default",
        ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("another MediaLIB package operation"), result.stderr)
        XCTAssertEqual(try String(contentsOf: marker), "keep build")
        XCTAssertEqual(try String(contentsOf: candidate), "keep candidate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testRuntimeValidatorFailsWhenRequiredBinaryCannotBeInspected() throws {
        let bundle = try makeRuntimeFixtureBundle()
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [try repositoryScriptURL(named: "check_bundle_runtime.sh").path, bundle.path, "arm64"],
            environment: ["MEDIALIB_OTOOL": "/usr/bin/false"]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("unable to inspect Mach-O dependencies"), result.stderr)
    }

    func testRuntimeValidatorSupportsToolAndDependencyPathsContainingSpaces() throws {
        let bundle = try makeRuntimeFixtureBundle()
        let directory = try makeTemporaryDirectory(name: "MediaLib tools with spaces")
        let otool = directory.appendingPathComponent("fake otool")
        let lipo = directory.appendingPathComponent("fake lipo")
        try FileManager.default.copyItem(at: repositoryScriptURL(named: "test_support/package_fake_otool.sh"), to: otool)
        try FileManager.default.copyItem(at: repositoryScriptURL(named: "test_support/package_fake_lipo.sh"), to: lipo)
        let dependency = bundle.appendingPathComponent("Contents/Frameworks/codec library.dylib")
        try Data("fixture".utf8).write(to: dependency)
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [try repositoryScriptURL(named: "check_bundle_runtime.sh").path, bundle.path, "arm64"],
            environment: [
                "MEDIALIB_OTOOL": otool.path, "MEDIALIB_LIPO": lipo.path,
                "FAKE_DEPENDENCY": "@loader_path/../Frameworks/codec library.dylib",
            ]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeRuntimeFixtureBundle() throws -> URL {
        let bundle = try makeTemporaryDirectory(name: "MediaLib runtime bundle").appendingPathComponent("MediaLIB.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        for name in ["MediaLib", "MediaLibServer", "ffmpeg", "ffprobe"] {
            try writeExecutable("fixture", to: macOS.appendingPathComponent(name))
        }
        try Data("fixture".utf8).write(to: frameworks.appendingPathComponent("libmpv.2.dylib"))
        return bundle
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        environment additions: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in additions {
            environment[key] = value
        }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func runPathProbe(script: URL) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["MEDIALIB_PACKAGE_DMG_PRINT_PATHS_ONLY"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)

        return Dictionary(uniqueKeysWithValues: output
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                guard let separator = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<separator]), String(line[line.index(after: separator)...]))
            })
    }

    private func canonicalPath(_ path: String?) -> String? {
        path.map { canonicalPath(URL(fileURLWithPath: $0)) }
    }

    private func canonicalPath(_ url: URL) -> String {
        guard let resolvedPath = url.withUnsafeFileSystemRepresentation({ representation -> String? in
            guard let representation, let resolved = realpath(representation, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }) else {
            return normalizeMacOSTemporaryDirectoryAlias(url.resolvingSymlinksInPath().path)
        }
        return normalizeMacOSTemporaryDirectoryAlias(resolvedPath)
    }

    private func normalizeMacOSTemporaryDirectoryAlias(_ path: String) -> String {
        guard path == "/var" || path.hasPrefix("/var/") else { return path }
        return "/private\(path)"
    }

    private func repositoryPackageScriptURL() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/package_dmg.sh")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("package_dmg.sh is not available in this test environment.")
        }
        return url
    }

    private func repositoryScriptURL(named name: String) throws -> URL {
        let url = try repositoryPackageScriptURL().deletingLastPathComponent().appendingPathComponent(name)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("\(name) is not available in this test environment.")
        }
        return url
    }
}
