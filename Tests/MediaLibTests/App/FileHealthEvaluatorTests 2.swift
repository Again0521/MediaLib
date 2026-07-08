import XCTest
import MediaLibCore
@testable import MediaLib

final class FileHealthEvaluatorTests: XCTestCase {
    func testLocalMissingFileIsReportedAndSafeWhenSourceIsOnline() {
        let source = mediaSource(id: "local", path: "/Media")
        let existing = mediaItem(id: "existing", sourcePath: "/Media/existing.mkv", filePath: "/Media/existing.mkv")
        let missing = mediaItem(id: "missing", sourcePath: "/Media/missing.mkv", filePath: "/Media/missing.mkv")

        let result = evaluate(
            items: [existing, missing],
            sources: [source],
            existingPaths: ["/Media", "/Media/existing.mkv"]
        )

        XCTAssertEqual(result.missingItemIDs, ["missing"])
        XCTAssertEqual(result.safeMissingItemIDs, ["missing"])
        XCTAssertTrue(result.offlineSourceIDs.isEmpty)
    }

    func testOfflineSourceKeepsMissingItemsUnsafeForIndexRemoval() {
        let source = mediaSource(id: "offline", path: "/Volumes/Archive")
        let missing = mediaItem(
            id: "archived-movie",
            sourcePath: "/Volumes/Archive/movie.mkv",
            filePath: "/Volumes/Archive/movie.mkv"
        )

        let result = evaluate(items: [missing], sources: [source], existingPaths: [])

        XCTAssertEqual(result.missingItemIDs, ["archived-movie"])
        XCTAssertTrue(result.safeMissingItemIDs.isEmpty)
        XCTAssertEqual(result.offlineSourceIDs, ["offline"])
    }

    func testSourcesExcludedFromHealthCheckDoNotReportOfflineOrMissingItems() {
        let source = mediaSource(id: "excluded", path: "/Media/Excluded", includeInHealthCheck: false)
        let missing = mediaItem(
            id: "excluded-movie",
            sourcePath: "/Media/Excluded/movie.mkv",
            filePath: "/Media/Excluded/movie.mkv"
        )

        let result = evaluate(items: [missing], sources: [source], existingPaths: [])

        XCTAssertTrue(result.missingItemIDs.isEmpty)
        XCTAssertTrue(result.safeMissingItemIDs.isEmpty)
        XCTAssertTrue(result.offlineSourceIDs.isEmpty)
    }

    func testRemoteMediaServerReportsOnlyItemsWithoutPlayablePathAndNeverMarksSourceOffline() {
        let source = mediaSource(id: "emby", path: "emby://server", mediaType: .movie)
        let missingRemotePath = mediaItem(
            id: "remote-missing",
            sourcePath: "emby://server/library/movies",
            filePath: nil
        )
        let playableRemote = mediaItem(
            id: "remote-playable",
            sourcePath: "emby://server/library/movies",
            filePath: "https://server.example/stream/movie.mkv"
        )

        let result = evaluate(items: [missingRemotePath, playableRemote], sources: [source], existingPaths: [])

        XCTAssertEqual(result.missingItemIDs, ["remote-missing"])
        XCTAssertEqual(result.safeMissingItemIDs, ["remote-missing"])
        XCTAssertTrue(result.offlineSourceIDs.isEmpty)
    }

    func testURLSourceRemoteResourcesAreNotTreatedAsMissingOrOffline() {
        let source = mediaSource(id: "url-source", path: "urlsource://manual", mediaType: .movie)
        let urlItem = mediaItem(
            id: "url-item",
            sourcePath: "urlsource://manual",
            filePath: "https://cdn.example/movie.mkv"
        )

        let result = evaluate(items: [urlItem], sources: [source], existingPaths: [])

        XCTAssertTrue(result.missingItemIDs.isEmpty)
        XCTAssertTrue(result.safeMissingItemIDs.isEmpty)
        XCTAssertTrue(result.offlineSourceIDs.isEmpty)
    }

    func testPrivateAndMusicItemsAreSkippedFromMissingFileEvaluation() {
        let source = mediaSource(id: "local", path: "/Media")
        let privateMovie = mediaItem(
            id: "private-movie",
            sourcePath: "/Media/private.mkv",
            filePath: "/Media/private.mkv"
        )
        let music = mediaItem(
            id: "track",
            type: .music,
            sourcePath: "/Media/track.flac",
            filePath: "/Media/track.flac"
        )

        let result = evaluate(
            items: [privateMovie, music],
            sources: [source],
            privateItemIDs: ["private-movie"],
            existingPaths: ["/Media"]
        )

        XCTAssertTrue(result.missingItemIDs.isEmpty)
        XCTAssertTrue(result.safeMissingItemIDs.isEmpty)
        XCTAssertTrue(result.offlineSourceIDs.isEmpty)
    }

    private func evaluate(
        items: [MediaItem],
        sources: [MediaSource],
        privateItemIDs: Set<String> = [],
        existingPaths: Set<String>
    ) -> FileHealthEvaluation {
        FileHealthEvaluator.evaluate(
            items: items,
            sources: sources,
            privateItemIDs: privateItemIDs,
            fileExists: { existingPaths.contains($0) }
        )
    }

    private func mediaSource(
        id: String,
        path: String,
        mediaType: MediaType = .movie,
        includeInHealthCheck: Bool = true
    ) -> MediaSource {
        MediaSource(
            id: id,
            name: id,
            path: path,
            mediaType: mediaType,
            includeInHealthCheck: includeInHealthCheck
        )
    }

    private func mediaItem(
        id: String,
        type: MediaType = .movie,
        sourcePath: String,
        filePath: String?
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            title: id,
            sourcePath: sourcePath,
            filePath: filePath
        )
    }
}
