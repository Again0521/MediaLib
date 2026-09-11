import Foundation
import XCTest

final class ReleaseMetadataScriptTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testGeneratorWritesAndChecksSwiftReadmesAndInfoPlistFromOneSource() throws {
        let root = try makeFixtureRoot(version: "2.3.4", build: "108", channel: "prerelease")
        let write = try run(root: root, arguments: ["--write"])
        XCTAssertEqual(write.status, 0, write.stderr)

        let swift = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibServerProtocol/GeneratedReleaseMetadata.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(swift.contains("productVersion = \"2.3.4\""))
        XCTAssertTrue(swift.contains("buildNumber = \"108\""))
        XCTAssertTrue(swift.contains("isPrerelease = true"))
        for name in ["README.md", "README.en.md", "README.ja.md"] {
            let readme = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(readme.contains("-2.3.4-34C759"), name)
        }

        let plistURL = root.appendingPathComponent("Info.plist")
        let original: [String: Any] = ["CFBundleIdentifier": "test.MediaLib"]
        try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
            .write(to: plistURL)
        let plist = try run(root: root, arguments: ["--write-info-plist", plistURL.path])
        XCTAssertEqual(plist.status, 0, plist.stderr)
        let data = try Data(contentsOf: plistURL)
        let value = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(value["CFBundleIdentifier"] as? String, "test.MediaLib")
        XCTAssertEqual(value["CFBundleShortVersionString"] as? String, "2.3.4")
        XCTAssertEqual(value["CFBundleVersion"] as? String, "108")
        XCTAssertEqual(value["MediaLibReleaseChannel"] as? String, "prerelease")

        let check = try run(root: root, arguments: ["--check"])
        XCTAssertEqual(check.status, 0, check.stderr)
    }

    func testCheckFailsClosedWhenGeneratedFileDrifts() throws {
        let root = try makeFixtureRoot(version: "1.5.5", build: "97", channel: "stable")
        XCTAssertEqual(try run(root: root, arguments: ["--write"]).status, 0)
        try "stale".write(
            to: root.appendingPathComponent("Sources/MediaLibServerProtocol/GeneratedReleaseMetadata.swift"),
            atomically: true,
            encoding: .utf8
        )

        let result = try run(root: root, arguments: ["--check"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("generated release metadata is stale"), result.stderr)
    }

    func testInvalidOrExpandedConfigurationIsRejected() throws {
        let root = try makeFixtureRoot(version: "1.5-beta", build: "0", channel: "nightly")

        let result = try run(root: root, arguments: ["--write"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("productVersion"), result.stderr)
    }

    func testTrackedReadmesContainCompletePublicServerBoundary() throws {
        let root = try repositoryScriptURL().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["README.md", "README.en.md", "README.ja.md"] {
            let readme = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(readme.contains("macOS 14"), name)
            XCTAssertTrue(readme.contains("MediaLIB-LAN-CA.cer"), name)
            XCTAssertTrue(readme.contains("setup_lan_https_proxy.sh"), name)
            XCTAssertTrue(readme.contains("release_metadata.py --check"), name)
            XCTAssertFalse(readme.contains("](doc/"), "\(name) must not link to Git-ignored documentation")
        }
    }

    private func makeFixtureRoot(version: String, build: String, channel: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib release metadata \(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config"), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: try repositoryScriptURL(),
            to: root.appendingPathComponent("scripts/release_metadata.py")
        )
        let config: [String: String] = [
            "productVersion": version,
            "buildNumber": build,
            "releaseChannel": channel,
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("config/release.json"))
        for (name, label) in [
            ("README.md", "![版本]"),
            ("README.en.md", "![Version]"),
            ("README.ja.md", "![バージョン]"),
        ] {
            let text = """
            header
            <!-- release-version-badge: generated from config/release.json -->
            \(label)(https://img.shields.io/badge/placeholder-0.0.0-34C759?style=flat-square)
            footer
            """
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func run(root: URL, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/release_metadata.py").path, "--root", root.path] + arguments
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

    private func repositoryScriptURL() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/release_metadata.py")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("release_metadata.py is unavailable")
        }
        return url
    }
}
