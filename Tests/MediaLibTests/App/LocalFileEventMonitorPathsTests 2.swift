import XCTest
import MediaLibCore
@testable import MediaLib

final class LocalFileEventMonitorPathsTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testLocalFileEventMonitorPathsIncludesOnlyReachableAutoScanLocalDirectories() async throws {
        let root = try temporaryDirectory()
        let reachable = root.appendingPathComponent("Reachable", isDirectory: true)
        let disabled = root.appendingPathComponent("Disabled", isDirectory: true)
        let regularFile = root.appendingPathComponent("file.txt")
        let missing = root.appendingPathComponent("Missing", isDirectory: true)
        try FileManager.default.createDirectory(at: reachable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabled, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: regularFile)

        let sources = [
            source(id: "reachable", name: "Reachable", path: reachable.path, autoScan: true),
            source(id: "disabled", name: "Disabled", path: disabled.path, autoScan: false),
            source(id: "file", name: "File", path: regularFile.path, autoScan: true),
            source(id: "missing", name: "Missing", path: missing.path, autoScan: true),
            source(id: "emby", name: "Emby", path: "emby://server/library", autoScan: true),
            source(id: "smb", name: "SMB Share", path: "smb://server/share", autoScan: true)
        ]

        let paths = await AppState.localFileEventMonitorPaths(in: sources)

        XCTAssertEqual(paths, [reachable.path])
    }

    func testLocalFileEventMonitorPathsPreservesSourceOrderForReachableDirectories() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let paths = await AppState.localFileEventMonitorPaths(in: [
            source(id: "first", name: "First", path: first.path),
            source(id: "second", name: "Second", path: second.path)
        ])

        XCTAssertEqual(paths, [first.path, second.path])
    }

    private func source(
        id: String,
        name: String,
        path: String,
        autoScan: Bool = true
    ) -> MediaSource {
        MediaSource(
            id: id,
            name: name,
            path: path,
            mediaType: .movie,
            autoScan: autoScan
        )
    }

    private func temporaryDirectory() throws -> URL {
        if let tempDirectory {
            return tempDirectory
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileEventMonitorPathsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectory = root
        return root
    }
}
