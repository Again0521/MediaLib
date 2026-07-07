import XCTest
@testable import MediaLibCore

final class MusicLyricsSidecarWriterTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testWritePersistsLyricsAsUTF8() async throws {
        let url = try temporaryDirectory().appendingPathComponent("song.lrc")
        let lyrics = "[00:01.00]海边的歌词\n[00:02.00]next line\n"

        try await MusicLyricsSidecarWriter.write(lyrics, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), lyrics)
    }

    func testWritePreservesCRLFAndUnicodeExactly() async throws {
        let url = try temporaryDirectory().appendingPathComponent("song-crlf.lrc")
        let lyrics = "[00:01.00]第一行\r\n[00:02.00]café & symbols <>\r\n"

        try await MusicLyricsSidecarWriter.write(lyrics, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), lyrics)
    }

    func testWriteOverwritesExistingLyrics() async throws {
        let url = try temporaryDirectory().appendingPathComponent("replace.lrc")
        try "[00:00.00]old".write(to: url, atomically: true, encoding: .utf8)

        try await MusicLyricsSidecarWriter.write("[00:01.00]new\n", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[00:01.00]new\n")
    }

    func testWriteAllowsEmptyLyricsFile() async throws {
        let url = try temporaryDirectory().appendingPathComponent("empty.lrc")

        try await MusicLyricsSidecarWriter.write("", to: url)

        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testWriteThrowsWhenParentDirectoryIsMissing() async throws {
        let url = try temporaryDirectory()
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("song.lrc")

        do {
            try await MusicLyricsSidecarWriter.write("lyrics", to: url)
            XCTFail("Expected missing parent directory to throw")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    private func temporaryDirectory() throws -> URL {
        if let tempDirectory {
            return tempDirectory
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLyricsSidecarWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectory = root
        return root
    }
}
