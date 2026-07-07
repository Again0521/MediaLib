import XCTest
@testable import MediaLibCore

final class MusicPlaylistM3UFileLoaderTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testAsyncLoaderReadsUTF8Content() async throws {
        let url = try temporaryFileURL("utf8.m3u")
        let expected = "#EXTM3U\n音乐/海边.mp3\n"
        try expected.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try await MusicPlaylistM3UFileLoader.loadContent(from: url)

        XCTAssertEqual(loaded, expected)
    }

    func testAsyncLoaderFallsBackToLatin1Content() async throws {
        let url = try temporaryFileURL("latin1.m3u")
        try Data([0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x2E, 0x6D, 0x70, 0x33])
            .write(to: url)

        let loaded = try await MusicPlaylistM3UFileLoader.loadContent(from: url)

        XCTAssertEqual(loaded, "#EXTM3U\nCafé.mp3")
    }

    func testSynchronousLoaderUsesSameDecodedContent() throws {
        let url = try temporaryFileURL("sync.m3u8")
        let expected = "#EXTM3U\n/Library/Song.flac\n"
        try expected.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(try MusicPlaylistM3UFileLoader.loadContentSynchronously(from: url), expected)
    }

    func testAsyncAndSynchronousLoadersPreserveCRLFContentIdentically() async throws {
        let url = try temporaryFileURL("crlf.m3u")
        let expected = "#EXTM3U\r\n#EXTINF:5,Song\r\nC:\\Music\\Song.mp3\r\n"
        try expected.write(to: url, atomically: true, encoding: .utf8)

        let asyncLoaded = try await MusicPlaylistM3UFileLoader.loadContent(from: url)
        let syncLoaded = try MusicPlaylistM3UFileLoader.loadContentSynchronously(from: url)

        XCTAssertEqual(asyncLoaded, expected)
        XCTAssertEqual(syncLoaded, expected)
    }

    func testLoaderReturnsEmptyStringForEmptyFile() async throws {
        let url = try temporaryFileURL("empty.m3u")
        try Data().write(to: url)

        let asyncLoaded = try await MusicPlaylistM3UFileLoader.loadContent(from: url)
        let syncLoaded = try MusicPlaylistM3UFileLoader.loadContentSynchronously(from: url)

        XCTAssertEqual(asyncLoaded, "")
        XCTAssertEqual(syncLoaded, "")
    }

    func testLoaderThrowsForMissingFile() async throws {
        let url = try temporaryFileURL("missing.m3u")

        do {
            _ = try await MusicPlaylistM3UFileLoader.loadContent(from: url)
            XCTFail("Expected missing M3U file read to throw")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    private func temporaryFileURL(_ name: String) throws -> URL {
        if tempDirectory == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MusicPlaylistM3UFileLoaderTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tempDirectory = root
        }
        return tempDirectory!.appendingPathComponent(name)
    }
}
