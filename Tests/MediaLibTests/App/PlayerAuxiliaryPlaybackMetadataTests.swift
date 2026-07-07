import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class PlayerAuxiliaryPlaybackMetadataTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testLoadFindsSortedMatchingSidecarSubtitlesForLocalVideo() async throws {
        let directory = try makeTemporaryDirectory()
        let videoURL = directory.appendingPathComponent("Movie.mkv")
        try Data([0x01]).write(to: videoURL)
        try "1\n00:00:00,000 --> 00:00:01,000\nHello".write(
            to: directory.appendingPathComponent("Movie.srt"),
            atomically: true,
            encoding: .utf8
        )
        try "WEBVTT\n\n00:00.000 --> 00:01.000\nHi".write(
            to: directory.appendingPathComponent("Movie.zh.vtt"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored".write(
            to: directory.appendingPathComponent("OtherMovie.srt"),
            atomically: true,
            encoding: .utf8
        )
        let item = MediaItem(
            id: "local-video",
            type: .movie,
            title: "Movie",
            filePath: videoURL.path,
            resolution: "1920x1080"
        )

        let metadata = await PlayerAuxiliaryPlaybackMetadata.load(for: item)

        XCTAssertEqual(metadata.sidecarSubtitles.map(\.displayName), ["Movie.srt", "Movie.zh.vtt"])
        XCTAssertEqual(metadata.sidecarSubtitles.map(\.languageHint), [nil, "中文"])
        XCTAssertFalse(metadata.previewPrefersFFmpeg)
        XCTAssertTrue(metadata.qualityOptions.isEmpty)
    }

    func testLoadPrioritizesExactSiblingAndGenericSubtitleFiles() async throws {
        let directory = try makeTemporaryDirectory()
        let videoURL = directory.appendingPathComponent("Feature Film.mp4")
        try Data([0x01]).write(to: videoURL)

        let names = [
            "subtitle.en.srt",
            "Feature Film.forced.ass",
            "Feature Film.srt",
            "Feature Film_ja.vtt",
            "Feature Film-traditional.cht.ssa",
            ".Feature Film.hidden.srt",
            "Other Film.en.srt"
        ]
        for name in names {
            try "WEBVTT\n\n00:00.000 --> 00:01.000\n\(name)".write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        let item = MediaItem(
            id: "feature-film",
            type: .movie,
            title: "Feature Film",
            filePath: videoURL.path,
            resolution: "1920x1080"
        )

        let metadata = await PlayerAuxiliaryPlaybackMetadata.load(for: item)

        let displayNames = metadata.sidecarSubtitles.map(\.displayName)
        XCTAssertEqual(displayNames.first, "Feature Film.srt")
        XCTAssertEqual(displayNames.last, "subtitle.en.srt")
        XCTAssertEqual(
            Set(displayNames),
            Set([
                "Feature Film.srt",
                "Feature Film.forced.ass",
                "Feature Film-traditional.cht.ssa",
                "Feature Film_ja.vtt",
                "subtitle.en.srt"
            ])
        )

        let hintsByName = Dictionary(
            uniqueKeysWithValues: metadata.sidecarSubtitles.map { ($0.displayName, $0.languageHint) }
        )
        XCTAssertEqual(hintsByName["Feature Film-traditional.cht.ssa"] ?? nil, "繁体中文")
        XCTAssertEqual(hintsByName["Feature Film_ja.vtt"] ?? nil, "日文")
        XCTAssertEqual(hintsByName["subtitle.en.srt"] ?? nil, "英文")
    }

    func testLoadBuildsRemoteEmbyQualityOptionsWithoutLocalSidecarScan() async {
        let item = MediaItem(
            id: "emby-video",
            type: .movie,
            title: "Remote Movie",
            filePath: "https://emby.example.test/Videos/1/stream.mp4?api_key=token&MediaSourceId=source",
            resolution: "3840x2160",
            videoBitrate: 42_000_000,
            metadataProvider: "Emby"
        )

        let metadata = await PlayerAuxiliaryPlaybackMetadata.load(for: item)

        XCTAssertTrue(metadata.previewPrefersFFmpeg)
        XCTAssertTrue(metadata.sidecarSubtitles.isEmpty)
        XCTAssertGreaterThan(metadata.qualityOptions.count, 1)
        XCTAssertEqual(metadata.qualityOptions.first?.label, "原画")
        XCTAssertTrue(metadata.qualityOptions.dropFirst().allSatisfy { !$0.isOriginal })
    }

    func testLoadPrefersFFmpegForRemoteNonEmbyStreamWithoutQualityOptions() async {
        let item = MediaItem(
            id: "remote-stream",
            type: .movie,
            title: "Remote Stream",
            filePath: "https://stream.example.test/movie.mp4",
            resolution: "3840x2160",
            videoBitrate: 42_000_000,
            metadataProvider: "Manual"
        )

        let metadata = await PlayerAuxiliaryPlaybackMetadata.load(for: item)

        XCTAssertTrue(metadata.previewPrefersFFmpeg)
        XCTAssertTrue(metadata.sidecarSubtitles.isEmpty)
        XCTAssertTrue(metadata.qualityOptions.isEmpty)
    }

    func testLoadSkipsRemoteEmbyQualityOptionsWhenBitrateIsTooLow() async {
        let item = MediaItem(
            id: "emby-low-bitrate-video",
            type: .movie,
            title: "Remote Movie",
            filePath: "https://emby.example.test/Videos/1/stream.mp4?api_key=token&MediaSourceId=source",
            resolution: "1920x1080",
            videoBitrate: 4_000_000,
            metadataProvider: "Emby"
        )

        let metadata = await PlayerAuxiliaryPlaybackMetadata.load(for: item)

        XCTAssertTrue(metadata.previewPrefersFFmpeg)
        XCTAssertTrue(metadata.sidecarSubtitles.isEmpty)
        XCTAssertTrue(metadata.qualityOptions.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerAuxiliaryPlaybackMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }
}
