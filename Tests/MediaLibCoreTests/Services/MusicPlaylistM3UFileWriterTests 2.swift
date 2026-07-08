import XCTest
@testable import MediaLibCore

final class MusicPlaylistM3UFileWriterTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testWriterPersistsUTF8ContentExactly() async throws {
        let url = try temporaryFileURL("export.m3u")
        let expected = "#EXTM3U\n#EXTINF:4,海边\n/音乐/海边.flac\n"

        try await MusicPlaylistM3UFileWriter.writeContent(expected, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
    }

    func testWriterOverwritesExistingContentAtomically() async throws {
        let url = try temporaryFileURL("replace.m3u8")
        try "old".write(to: url, atomically: true, encoding: .utf8)

        try await MusicPlaylistM3UFileWriter.writeContent("#EXTM3U\nnew.mp3\n", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "#EXTM3U\nnew.mp3\n")
    }

    func testWriterPreservesCRLFAndWindowsPathsExactly() async throws {
        let url = try temporaryFileURL("windows.m3u")
        let expected = "#EXTM3U\r\n#EXTINF:5,Drive Song\r\nC:\\Music\\Drive Song.mp3\r\n"

        try await MusicPlaylistM3UFileWriter.writeContent(expected, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
    }

    func testWriterAllowsEmptyContent() async throws {
        let url = try temporaryFileURL("empty.m3u")

        try await MusicPlaylistM3UFileWriter.writeContent("", to: url)

        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testWriterThrowsWhenParentDirectoryIsMissing() async throws {
        let url = try temporaryDirectoryURL()
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("export.m3u")

        do {
            try await MusicPlaylistM3UFileWriter.writeContent("#EXTM3U\n", to: url)
            XCTFail("Expected writing into a missing parent directory to throw")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    private func temporaryFileURL(_ name: String) throws -> URL {
        try temporaryDirectoryURL().appendingPathComponent(name)
    }

    private func temporaryDirectoryURL() throws -> URL {
        if tempDirectory == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MusicPlaylistM3UFileWriterTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tempDirectory = root
        }
        return tempDirectory!
    }
}
