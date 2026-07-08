import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class SubtitleSearchServiceTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testSubtitleOutputURLUsesDownloadedExtensionLowercased() throws {
        let videoURL = try temporaryFileURL("Movie.Name.mkv")

        let outputURL = SubtitleSearchService.subtitleOutputURL(
            videoPath: videoURL.path,
            downloadedFileName: "Release.Subtitle.ASS"
        )

        XCTAssertEqual(outputURL.lastPathComponent, "Movie.Name.ass")
        XCTAssertEqual(outputURL.deletingLastPathComponent().path, videoURL.deletingLastPathComponent().path)
    }

    func testSubtitleOutputURLFallsBackToSRTWhenDownloadedNameHasNoExtension() throws {
        let videoURL = try temporaryFileURL("Episode 01.mp4")

        let outputURL = SubtitleSearchService.subtitleOutputURL(
            videoPath: videoURL.path,
            downloadedFileName: "subtitle"
        )

        XCTAssertEqual(outputURL.lastPathComponent, "Episode 01.srt")
    }

    func testSubtitleOutputURLFallsBackToSRTForUnsupportedDownloadedExtension() throws {
        let videoURL = try temporaryFileURL("Episode 02.mp4")

        let outputURL = SubtitleSearchService.subtitleOutputURL(
            videoPath: videoURL.path,
            downloadedFileName: "subtitle.zip"
        )

        XCTAssertEqual(outputURL.lastPathComponent, "Episode 02.srt")
    }

    func testSubtitleExtensionAllowsKnownSubtitleFormatsAndRejectsBlankOrUnsupportedValues() {
        XCTAssertEqual(SubtitleSearchService.subtitleExtension(from: "ASS"), "ass")
        XCTAssertEqual(SubtitleSearchService.subtitleExtension(from: " vtt\n"), "vtt")
        XCTAssertEqual(SubtitleSearchService.subtitleExtension(from: "ttml"), "ttml")
        XCTAssertEqual(SubtitleSearchService.subtitleExtension(from: ""), "srt")
        XCTAssertEqual(SubtitleSearchService.subtitleExtension(from: "zip"), "srt")
        XCTAssertEqual(SubtitleSearchService.subtitleExtension(from: "exe"), "srt")
    }

    func testDeduplicatedResultsByDisplayNameTrimsAndMatchesCaseInsensitively() {
        let results = SubtitleSearchService.deduplicatedResultsByDisplayName([
            onlineResult(id: "pod-1", displayName: " Movie.Release.zh.srt ", source: .podnapisi(subtitleID: 1)),
            onlineResult(id: "os-1", displayName: "\nmovie.release.ZH.srt", source: .openSubtitles(fileID: 10)),
            onlineResult(id: "pod-2", displayName: "Movie.Release.en.srt", source: .podnapisi(subtitleID: 2))
        ])

        XCTAssertEqual(results.map(\.id), ["pod-1", "pod-2"])
    }

    func testDeduplicatedResultsByDisplayNameUsesWidthAndDiacriticInsensitiveKeys() {
        let results = SubtitleSearchService.deduplicatedResultsByDisplayName([
            onlineResult(id: "full-width", displayName: "Ｃａｆｅ.ass", source: .podnapisi(subtitleID: 1)),
            onlineResult(id: "plain", displayName: "Cafe.ass", source: .openSubtitles(fileID: 10)),
            onlineResult(id: "distinct", displayName: "Cafe Commentary.ass", source: .openSubtitles(fileID: 11))
        ])

        XCTAssertEqual(results.map(\.id), ["full-width", "distinct"])
    }

    func testDownloadAndSaveRejectsBlankOpenSubtitlesAPIKeyBeforeNetwork() async throws {
        let videoURL = try temporaryFileURL("Feature.mov")
        let service = SubtitleSearchService()

        do {
            _ = try await service.downloadAndSave(
                fileID: 42,
                videoPath: videoURL.path,
                apiKey: " \n\t "
            )
            XCTFail("Expected blank API key to fail before download request")
        } catch SubtitleError.missingAPIKey {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadOnlineRejectsBlankOpenSubtitlesAPIKeyBeforeNetwork() async throws {
        let videoURL = try temporaryFileURL("Feature.mov")
        let service = SubtitleSearchService()
        let result = OnlineSubtitleResult(
            id: "os-42",
            sourceName: "OpenSubtitles",
            displayName: "Feature.zh.srt",
            language: "zh-Hans",
            downloads: 10,
            source: .openSubtitles(fileID: 42)
        )

        do {
            _ = try await service.downloadOnline(
                result: result,
                videoPath: videoURL.path,
                apiKey: "\n"
            )
            XCTFail("Expected blank API key to fail before download request")
        } catch SubtitleError.missingAPIKey {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveSubtitleDataWritesThroughInjectedIOOnBlockingIOQueue() async throws {
        let videoURL = try temporaryFileURL("Feature.mov")
        let expectedData = Data("subtitle-body".utf8)
        let recorder = RecordingSubtitleSidecarIO()

        let outputURL = try await SubtitleSearchService.saveSubtitleData(
            expectedData,
            videoPath: videoURL.path,
            downloadedFileName: "feature.zh.vtt",
            io: recorder.io()
        )

        XCTAssertEqual(outputURL.lastPathComponent, "Feature.vtt")
        XCTAssertEqual(recorder.writes.map(\.url), [outputURL])
        XCTAssertEqual(recorder.writes.map(\.data), [expectedData])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    func testSaveSubtitleDataPropagatesWriteError() async throws {
        struct WriteFailed: Error {}
        let videoURL = try temporaryFileURL("Broken.mkv")
        let io = SubtitleSidecarIO { _, _ in throw WriteFailed() }

        do {
            _ = try await SubtitleSearchService.saveSubtitleData(
                Data("subtitle-body".utf8),
                videoPath: videoURL.path,
                downloadedFileName: nil,
                io: io
            )
            XCTFail("Expected subtitle sidecar write to fail")
        } catch is WriteFailed {
            // Expected.
        }
    }

    func testFileSystemSubtitleSaveRoundTripsData() async throws {
        let videoURL = try temporaryFileURL("Documentary.mp4")
        let expectedData = Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8)

        let outputURL = try await SubtitleSearchService.saveSubtitleData(
            expectedData,
            videoPath: videoURL.path,
            downloadedFileName: nil
        )

        XCTAssertEqual(outputURL.lastPathComponent, "Documentary.srt")
        XCTAssertEqual(try Data(contentsOf: outputURL), expectedData)
    }

    private func temporaryFileURL(_ name: String) throws -> URL {
        if tempDirectory == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SubtitleSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tempDirectory = root
        }
        return tempDirectory!.appendingPathComponent(name)
    }

    private func onlineResult(
        id: String,
        displayName: String,
        source: OnlineSubtitleResult.Source
    ) -> OnlineSubtitleResult {
        OnlineSubtitleResult(
            id: id,
            sourceName: "Test",
            displayName: displayName,
            language: "zh-Hans",
            downloads: 1,
            source: source
        )
    }
}

private final class RecordingSubtitleSidecarIO: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(data: Data, url: URL, onBlockingIOQueue: Bool)] = []

    var writes: [(data: Data, url: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return records.map { ($0.data, $0.url) }
    }

    var didObserveBlockingIOOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.onBlockingIOQueue }
    }

    var allOperationsObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !records.isEmpty && records.allSatisfy(\.onBlockingIOQueue)
    }

    func io() -> SubtitleSidecarIO {
        SubtitleSidecarIO { [self] data, url in
            lock.lock()
            records.append((
                data: data,
                url: url,
                onBlockingIOQueue: BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()
            ))
            lock.unlock()
        }
    }
}
