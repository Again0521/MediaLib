import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class MusicLyricsLoaderTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testLoadLyricsPrefersLRCOverTXTAndDoesNotQueryMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        let audioURL = directory.appendingPathComponent("song.flac")
        try Data([0x01]).write(to: audioURL)
        try "lrc lyric".write(to: directory.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8)
        try "txt lyric".write(to: directory.appendingPathComponent("song.txt"), atomically: true, encoding: .utf8)
        let probe = MetadataProbe()

        let text = await MusicLyricsLoader.loadLyrics(for: makeMusicItem(audioURL: audioURL)) { _ in
            await probe.recordAndReturn("metadata lyric")
        }

        XCTAssertEqual(text, "lrc lyric")
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testLoadLyricsUsesTXTWhenLRCIsMissing() async throws {
        let directory = try makeTemporaryDirectory()
        let audioURL = directory.appendingPathComponent("song.m4a")
        try Data([0x01]).write(to: audioURL)
        try "txt fallback".write(to: directory.appendingPathComponent("song.txt"), atomically: true, encoding: .utf8)

        let text = await MusicLyricsLoader.loadLyrics(for: makeMusicItem(audioURL: audioURL)) { _ in
            "metadata lyric"
        }

        XCTAssertEqual(text, "txt fallback")
    }

    func testLoadLyricsIgnoresEmptySidecarAndUsesTrimmedMetadataLyrics() async throws {
        let directory = try makeTemporaryDirectory()
        let audioURL = directory.appendingPathComponent("song.mp3")
        try Data([0x01]).write(to: audioURL)
        try " \n\t ".write(to: directory.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8)

        let text = await MusicLyricsLoader.loadLyrics(for: makeMusicItem(audioURL: audioURL)) { _ in
            "  embedded lyric  \n"
        }

        XCTAssertEqual(text, "embedded lyric")
    }

    func testLoadLyricsReturnsDefaultMessagesForNilPathAndMissingLyrics() async throws {
        let directory = try makeTemporaryDirectory()
        let audioURL = directory.appendingPathComponent("missing-sidecar.wav")
        try Data([0x01]).write(to: audioURL)

        let nilPathText = await MusicLyricsLoader.loadLyrics(for: MediaItem(id: "nil", type: .music, title: "Nil")) { _ in
            "metadata lyric"
        }
        let missingText = await MusicLyricsLoader.loadLyrics(for: makeMusicItem(audioURL: audioURL)) { _ in
            nil
        }

        XCTAssertEqual(nilPathText, MusicLyricsLoader.emptyLyricsText)
        XCTAssertEqual(missingText, MusicLyricsLoader.missingLyricsText)
    }

    func testConcurrentSidecarLyricsReadsRemainStable() async throws {
        let directory = try makeTemporaryDirectory()
        let entries = try (0..<40).map { index -> (URL, String) in
            let audioURL = directory.appendingPathComponent("song-\(index).flac")
            try Data([UInt8(index)]).write(to: audioURL)
            let lyric = "lyric-\(index)"
            try lyric.write(
                to: directory.appendingPathComponent("song-\(index).lrc"),
                atomically: true,
                encoding: .utf8
            )
            return (audioURL, lyric)
        }

        await withTaskGroup(of: (String, String?).self) { group in
            for (url, expected) in entries {
                group.addTask {
                    (expected, await MusicLyricsLoader.sidecarLyrics(forAudioFileURL: url))
                }
            }
            for await (expected, actual) in group {
                XCTAssertEqual(actual, expected)
            }
        }
    }

    func testLocalFileExistsUsesAsyncBlockingIOPath() async throws {
        let directory = try makeTemporaryDirectory()
        let existingURL = directory.appendingPathComponent("song.aiff")
        let missingURL = directory.appendingPathComponent("missing.aiff")
        try Data([0x01]).write(to: existingURL)

        let existing = await MusicLyricsLoader.localFileExists(atPath: existingURL.path)
        let missing = await MusicLyricsLoader.localFileExists(atPath: missingURL.path)

        XCTAssertTrue(existing)
        XCTAssertFalse(missing)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLyricsLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }

    private func makeMusicItem(audioURL: URL) -> MediaItem {
        MediaItem(id: UUID().uuidString, type: .music, title: "Song", filePath: audioURL.path)
    }
}

private actor MetadataProbe {
    private var calls = 0

    var callCount: Int { calls }

    func recordAndReturn(_ value: String?) -> String? {
        calls += 1
        return value
    }
}
