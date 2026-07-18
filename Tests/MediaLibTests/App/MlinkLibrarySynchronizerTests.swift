import XCTest
@testable import MediaLib
@testable import MediaLibCore
@testable import MediaLibServerProtocol

final class MlinkLibrarySynchronizerTests: XCTestCase {
    func testLocalItemKeepsOpaqueIDAndNeverCreatesDirectMediaURL() {
        let synchronizer = MlinkLibrarySynchronizer()
        let card = ServerLibraryItem(
            id: "server/item?opaque", type: "movie", title: "影片", year: 2026, artworkAvailable: true,
            userState: ServerMediaUserState(
                itemID: "server/item?opaque", positionSeconds: 120, progress: 0.5, isWatched: false,
                playCount: 2, lastPlayedAt: nil, updatedAt: Date()
            ),
            userPreference: ServerMediaUserPreference(isFavorite: true, isWatchlist: true, rating: 4.5)
        )

        let item = synchronizer.localItem(card, sourceID: "source-1", sourcePath: "mlink://server-1/source-1")

        XCTAssertEqual(item.id, "mlink:source-1:server/item?opaque")
        XCTAssertEqual(item.sourcePath, "mlink://server-1/source-1/item/server/item%3Fopaque")
        XCTAssertNil(item.filePath)
        XCTAssertEqual(item.externalID, "server/item?opaque")
        XCTAssertEqual(item.metadataProvider, "Mlink")
        XCTAssertEqual(item.playPosition, 120)
        XCTAssertEqual(item.playProgress, 0.5)
        XCTAssertTrue(item.favorite)
        XCTAssertTrue(item.watchlist)
        XCTAssertEqual(item.userRating, 4.5)
    }

    func testSeriesCardKeepsSafeSeriesWebDestinationWithoutMediaURL() {
        let card = ServerLibraryItem(
            id: "series?opaque", type: "tvShow", title: "系列", year: 2026,
            artworkAvailable: true, isSeries: true
        )
        let item = MlinkLibrarySynchronizer().localItem(
            card, sourceID: "source-1", sourcePath: "mlink://server-1/source-1"
        )

        XCTAssertEqual(item.sourcePath, "mlink://server-1/source-1/series/series%3Fopaque")
        XCTAssertNil(item.filePath)
        XCTAssertEqual(item.externalID, "series?opaque")
    }
}
