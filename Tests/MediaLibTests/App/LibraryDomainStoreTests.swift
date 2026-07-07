import Combine
import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class LibraryDomainStoreTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testSourcesItemsAndRevisionsAreOwnedByStore() {
        let store = LibraryDomainStore()
        let source = makeSource(id: "source-1")
        let item = makeItem(id: "movie-1")

        store.replaceLibrary(sources: [source], items: [item])
        store.bumpLibraryRevision()
        store.bumpPosterRevision()
        store.bumpFavoriteRevision()
        store.bumpWatchlistRevision()
        store.bumpRatingRevision()
        store.bumpVideoCacheRevision()
        store.bumpMusicProjectionRevision()
        store.bumpMusicContentRevision()

        XCTAssertEqual(store.sources.map(\.id), ["source-1"])
        XCTAssertEqual(store.items.map(\.id), ["movie-1"])
        XCTAssertEqual(store.libraryRevision, 1)
        XCTAssertEqual(store.posterRevision, 1)
        XCTAssertEqual(store.favoriteRevision, 1)
        XCTAssertEqual(store.watchlistRevision, 1)
        XCTAssertEqual(store.ratingRevision, 1)
        XCTAssertEqual(store.videoCacheRevision, 1)
        XCTAssertEqual(store.musicProjectionRevision, 1)
        XCTAssertEqual(store.musicContentRevision, 1)
    }

    func testReplaceLibraryPublishesSingleChangeForSnapshotBatch() {
        let store = LibraryDomainStore()
        var publishCount = 0
        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        store.replaceLibrary(
            sources: [makeSource(id: "source-1"), makeSource(id: "source-2")],
            items: [makeItem(id: "movie-1"), makeItem(id: "movie-2")]
        )

        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(store.sources.count, 2)
        XCTAssertEqual(store.items.count, 2)
    }

    func testIndividualReplacementsRemainAvailableForFacadeCompatibility() {
        let store = LibraryDomainStore()

        store.replaceSources([makeSource(id: "source-1")])
        store.replaceItems([makeItem(id: "movie-1")])
        store.setLibraryRevision(7)

        XCTAssertEqual(store.sources.map(\.id), ["source-1"])
        XCTAssertEqual(store.items.map(\.id), ["movie-1"])
        XCTAssertEqual(store.libraryRevision, 7)
    }

    private func makeSource(id: String) -> MediaSource {
        MediaSource(
            id: id,
            name: "Source \(id)",
            path: "/Media/\(id)",
            mediaType: .movie
        )
    }

    private func makeItem(id: String) -> MediaItem {
        MediaItem(
            id: id,
            type: .movie,
            title: "Movie \(id)",
            fileSize: 4096
        )
    }
}
