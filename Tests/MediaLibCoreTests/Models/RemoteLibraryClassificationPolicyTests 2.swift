import XCTest
@testable import MediaLibCore

final class RemoteLibraryClassificationPolicyTests: XCTestCase {
    func testLibraryNameHasPriorityOverGenreAndCollectionType() {
        let item = mediaItem(type: .movie, genre: "documentary")
        let hint = RemoteLibraryClassificationHint(libraryName: "动漫剧场", collectionType: "movies")

        XCTAssertEqual(RemoteLibraryClassificationPolicy.inferredMediaType(for: item, hint: hint), .anime)
    }

    func testGenreIsUsedWhenLibraryNameDoesNotClassify() {
        let item = mediaItem(type: .movie, genre: "Reality, Talk Show")
        let hint = RemoteLibraryClassificationHint(libraryName: "Unsorted", collectionType: "movies")

        XCTAssertEqual(RemoteLibraryClassificationPolicy.inferredMediaType(for: item, hint: hint), .variety)
    }

    func testCollectionTypeIsUsedAfterNameAndGenre() {
        XCTAssertEqual(
            RemoteLibraryClassificationPolicy.inferredMediaType(
                for: mediaItem(type: .movie),
                hint: RemoteLibraryClassificationHint(libraryName: nil, collectionType: "tvshows")
            ),
            .tvShow
        )
        XCTAssertEqual(
            RemoteLibraryClassificationPolicy.inferredMediaType(
                for: mediaItem(type: .movie),
                hint: RemoteLibraryClassificationHint(libraryName: nil, collectionType: "homevideos")
            ),
            .homeVideo
        )
        XCTAssertEqual(
            RemoteLibraryClassificationPolicy.inferredMediaType(
                for: mediaItem(type: .movie),
                hint: RemoteLibraryClassificationHint(libraryName: nil, collectionType: "music")
            ),
            .music
        )
    }

    func testEpisodeFallsBackToTVShowWhenNoHintMatches() {
        let item = mediaItem(type: .episode, genre: nil)

        XCTAssertEqual(RemoteLibraryClassificationPolicy.inferredMediaType(for: item, hint: nil), .tvShow)
    }

    func testCurrentTypeIsPreservedWhenNoHintMatches() {
        let item = mediaItem(type: .documentary, genre: nil)
        let hint = RemoteLibraryClassificationHint(libraryName: "Archive", collectionType: "mixed")

        XCTAssertEqual(RemoteLibraryClassificationPolicy.inferredMediaType(for: item, hint: hint), .documentary)
    }

    func testClassifierTextDecodesPercentEncodingAndFoldsCaseAndWidth() {
        XCTAssertEqual(RemoteLibraryClassificationPolicy.inferMediaType(fromLibraryName: "Home%20Movies"), .homeVideo)
        XCTAssertEqual(RemoteLibraryClassificationPolicy.inferMediaType(fromLibraryName: "ＡＮＩＭＥ"), .anime)
    }

    private func mediaItem(type: MediaType, genre: String? = nil) -> MediaItem {
        MediaItem(
            id: UUID().uuidString,
            type: type,
            title: "Remote Item",
            genre: genre
        )
    }
}
