import XCTest
@testable import MediaLibCore

final class MusicTrackProjectionPolicyTests: XCTestCase {
    func testUniquePlayableMusicTracksFiltersNonMusicMissingPathAndDeduplicatesByIDInInputOrder() {
        let tracks = [
            track(id: "a", filePath: "/Music/a.flac"),
            track(id: "video", type: .movie, filePath: "/Movies/video.mkv"),
            track(id: "missing-path", filePath: nil),
            track(id: "b", filePath: "/Music/b.flac"),
            track(id: "a", title: "Duplicate A", filePath: "/Music/a-copy.flac")
        ]

        XCTAssertEqual(
            MusicTrackProjectionPolicy.uniquePlayableMusicTracks(tracks).map(\.id),
            ["a", "b"]
        )
        XCTAssertEqual(
            MusicTrackProjectionPolicy.uniquePlayableMusicTracks(tracks).first?.title,
            "a"
        )
    }

    func testLibraryOrderSortsByAlbumThenTrackNumberThenTitle() {
        let tracks = [
            track(id: "b2", title: "Beta", album: "Album 2", trackNumber: 2),
            track(id: "a1b", title: "Bravo", album: "Album 1", trackNumber: 1),
            track(id: "none", title: "No Track", album: "Album 1", trackNumber: nil),
            track(id: "a1a", title: "Alpha", album: "Album 1", trackNumber: 1),
            track(id: "b1", title: "Alpha", album: "Album 2", trackNumber: 1)
        ]

        XCTAssertEqual(
            MusicTrackProjectionPolicy.sortedByAlbumTrackAndTitle(tracks).map(\.id),
            ["none", "a1a", "a1b", "b1", "b2"]
        )
    }

    func testLibraryOrderTreatsMissingAlbumAsEmptyString() {
        let tracks = [
            track(id: "album", title: "With Album", album: "Album", trackNumber: 1),
            track(id: "missing", title: "Missing Album", album: nil, trackNumber: 1)
        ]

        XCTAssertEqual(
            MusicTrackProjectionPolicy.sortedByAlbumTrackAndTitle(tracks).map(\.id),
            ["missing", "album"]
        )
    }

    func testRecentlyPlayedTracksExcludesNeverPlayedAndSortsByLastPlayedDescending() {
        let tracks = [
            track(id: "never", lastPlayedAt: nil),
            track(id: "old", lastPlayedAt: day(1)),
            track(id: "new", lastPlayedAt: day(3))
        ]

        XCTAssertEqual(
            MusicTrackProjectionPolicy.recentlyPlayedTracks(tracks).map(\.id),
            ["new", "old"]
        )
    }

    func testContinueListeningIncludesPlayedOrInProgressTracksAndUsesUpdatedAtFallback() {
        let tracks = [
            track(id: "completed", updatedAt: day(30), playProgress: 0.98),
            track(id: "unstarted", updatedAt: day(40), playProgress: 0),
            track(id: "played", updatedAt: day(100), lastPlayedAt: day(2)),
            track(id: "in-progress-new", updatedAt: day(5), playProgress: 0.5),
            track(id: "in-progress-old", updatedAt: day(1), playProgress: 0.2)
        ]

        XCTAssertEqual(
            MusicTrackProjectionPolicy.continueListeningTracks(tracks, limit: 2).map(\.id),
            ["in-progress-new", "played"]
        )
    }

    func testSignalTracksIncludePlayCountLastPlayedFavoriteOrUserRating() {
        let tracks = [
            track(id: "plain"),
            track(id: "played-count", playCount: 1),
            track(id: "last-played", lastPlayedAt: day(1)),
            track(id: "favorite", favorite: true),
            track(id: "rated", userRating: 4)
        ]

        XCTAssertEqual(
            MusicTrackProjectionPolicy.signalTracks(tracks).map(\.id),
            ["played-count", "last-played", "favorite", "rated"]
        )
    }

    private func track(
        id: String,
        type: MediaType = .music,
        title: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        filePath: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        lastPlayedAt: Date? = nil,
        playProgress: Double = 0,
        playCount: Int? = 0,
        favorite: Bool = false,
        userRating: Double? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            title: title ?? id,
            album: album,
            trackNumber: trackNumber,
            userRating: userRating,
            filePath: filePath,
            playCount: playCount,
            playProgress: playProgress,
            favorite: favorite,
            updatedAt: updatedAt,
            lastPlayedAt: lastPlayedAt
        )
    }

    private func day(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value * 86_400)
    }
}
