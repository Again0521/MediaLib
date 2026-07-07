import XCTest
import MediaLibCore
@testable import MediaLib

final class LyricAlignmentCacheTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testWriteAndReadCacheRoundTripsAlignedSegments() async throws {
        let url = cacheFileURL("round-trip.json")
        let estimated = [
            TimedLyricLine(time: 1, text: "Hello"),
            TimedLyricLine(time: 3, text: "World")
        ]
        let aligned = [
            TimedLyricLine(
                time: 1,
                text: "Hello",
                segments: [
                    TimedLyricSegment(time: 1.1, text: "Hel", source: .aligned, durationHint: 0.2),
                    TimedLyricSegment(time: 1.4, text: "lo", source: .aligned, durationHint: 0.3)
                ],
                source: .aligned
            ),
            TimedLyricLine(
                time: 3,
                text: "World",
                segments: [
                    TimedLyricSegment(time: 3.2, text: "World", source: .aligned, durationHint: 0.4)
                ],
                source: .aligned
            )
        ]

        await LyricAlignmentService.writeCache(lines: aligned, to: url)
        let cachedResult = await LyricAlignmentService.cachedLines(from: url, estimatedLines: estimated)
        let cached = try XCTUnwrap(cachedResult)

        XCTAssertEqual(cached.count, 2)
        XCTAssertEqual(cached.map(\.text), ["Hello", "World"])
        XCTAssertEqual(cached[0].source, .aligned)
        XCTAssertEqual(cached[0].segments.map(\.source), [.aligned, .aligned])
        XCTAssertEqual(cached[0].segments[0].time, 1.1, accuracy: 0.0001)
        XCTAssertEqual(cached[0].segments[1].durationHint ?? -1, 0.3, accuracy: 0.0001)
    }

    func testReadCacheRejectsMismatchedEstimatedLines() async throws {
        let url = cacheFileURL("mismatch.json")
        let aligned = [
            TimedLyricLine(
                time: 1,
                text: "Original",
                segments: [
                    TimedLyricSegment(time: 1.1, text: "Original", source: .aligned, durationHint: 0.2)
                ],
                source: .aligned
            )
        ]
        let mismatched = [TimedLyricLine(time: 1, text: "Different")]

        await LyricAlignmentService.writeCache(lines: aligned, to: url)
        let cached = await LyricAlignmentService.cachedLines(from: url, estimatedLines: mismatched)

        XCTAssertNil(cached)
    }

    func testReadCacheReturnsNilForCorruptedJSON() async throws {
        let url = cacheFileURL("corrupted.json")
        try Data("not-json".utf8).write(to: url)

        let cached = await LyricAlignmentService.cachedLines(
            from: url,
            estimatedLines: [TimedLyricLine(time: 1, text: "Hello")]
        )

        XCTAssertNil(cached)
    }

    func testCacheKeyChangesWhenFileFingerprintChanges() async throws {
        let fileURL = cacheFileURL("fingerprint-audio.mp3")
        try Data([0x01]).write(to: fileURL)
        var item = MediaItem(id: "song", type: .music, title: "Song")
        item.filePath = fileURL.path

        let first = await LyricAlignmentService.cacheKey(
            item: item,
            filePath: fileURL.path,
            lyricsText: "[00:01.00]Hello",
            algorithm: .audioEnergy
        )
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)
        let second = await LyricAlignmentService.cacheKey(
            item: item,
            filePath: fileURL.path,
            lyricsText: "[00:01.00]Hello",
            algorithm: .audioEnergy
        )

        XCTAssertNotEqual(first, second)
    }

    private func cacheFileURL(_ name: String) -> URL {
        if tempDirectory == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LyricAlignmentCacheTests-\(UUID().uuidString)", isDirectory: true)
            tempDirectory = root
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return tempDirectory!.appendingPathComponent(name)
    }
}
