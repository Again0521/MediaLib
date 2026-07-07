import XCTest
@testable import MediaLibCore

final class MediaMetadataCompletenessPolicyTests: XCTestCase {
    func testMusicRequiresPosterArtistAndAlbum() {
        XCTAssertFalse(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .music, posterPath: "/poster.jpg", artist: "Artist", album: "Album")
        ))

        XCTAssertTrue(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .music, posterPath: nil, artist: "Artist", album: "Album")
        ))
        XCTAssertTrue(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .music, posterPath: "/poster.jpg", artist: " \n ", album: "Album")
        ))
        XCTAssertTrue(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .music, posterPath: "/poster.jpg", artist: "Artist", album: nil)
        ))
    }

    func testMusicDoesNotRequireMetadataProvider() {
        let item = mediaItem(
            type: .music,
            posterPath: "/poster.jpg",
            artist: "Artist",
            album: "Album",
            metadataProvider: nil
        )

        XCTAssertFalse(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(item))
    }

    func testVideoRequiresPosterYearAndOverview() {
        XCTAssertFalse(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .movie, posterPath: "/poster.jpg", year: 2026, overview: "Overview")
        ))

        XCTAssertTrue(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .movie, posterPath: nil, year: 2026, overview: "Overview")
        ))
        XCTAssertTrue(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .movie, posterPath: "/poster.jpg", year: nil, overview: "Overview")
        ))
        XCTAssertTrue(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .movie, posterPath: "/poster.jpg", year: 2026, overview: " \t ")
        ))
    }

    func testNonNilPosterPathIsConsideredPresentEvenWhenEmpty() {
        XCTAssertFalse(MediaMetadataCompletenessPolicy.isMissingCoreMetadata(
            mediaItem(type: .movie, posterPath: "", year: 2026, overview: "Overview")
        ))
    }

    private func mediaItem(
        type: MediaType,
        posterPath: String?,
        artist: String? = nil,
        album: String? = nil,
        year: Int? = nil,
        overview: String? = nil,
        metadataProvider: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: UUID().uuidString,
            type: type,
            title: "Item",
            artist: artist,
            album: album,
            year: year,
            overview: overview,
            posterPath: posterPath,
            metadataProvider: metadataProvider
        )
    }
}
