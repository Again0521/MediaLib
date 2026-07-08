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

    private func makeTemporaryPackageRoot(name: String) throws -> URL {
        let root = try makeTemporaryDirectory(name: name)
        let scriptsDirectory = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repositoryPackageScriptURL(),
            to: scriptsDirectory.appendingPathComponent("package_dmg.sh")
        )
        return root
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
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
}
