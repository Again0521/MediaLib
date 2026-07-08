import XCTest
@testable import MediaLib

@MainActor
final class MediaSearchIndexStateStoreTests: XCTestCase {
    func testInitialStateIsEmptyWithZeroRevision() {
        let store = MediaSearchIndexStateStore()

        XCTAssertTrue(store.detailMetadataGapsByMediaID.isEmpty)
        XCTAssertTrue(store.detailSearchTermsByMediaID.isEmpty)
        XCTAssertEqual(store.revision, 0)
    }

    func testReplaceDetailMetadataGapsPublishesSnapshot() {
        let store = MediaSearchIndexStateStore()
        let gaps: [String: Set<String>] = ["movie-1": ["overview", "cast"]]

        store.replaceDetailMetadataGaps(gaps)

        XCTAssertEqual(store.detailMetadataGapsByMediaID, gaps)
    }

    func testSetDetailMetadataGapsUpdatesAndRemovesSingleMediaID() {
        let store = MediaSearchIndexStateStore()
        store.replaceDetailMetadataGaps([
            "movie-1": ["overview"],
            "movie-2": ["cast"]
        ])

        store.setDetailMetadataGaps(["tagline"], forMediaID: "movie-1")
        store.setDetailMetadataGaps(nil, forMediaID: "movie-2")

        XCTAssertEqual(store.detailMetadataGapsByMediaID, ["movie-1": ["tagline"]])
    }

    func testReplaceDetailSearchTermsPublishesSnapshot() {
        let store = MediaSearchIndexStateStore()
        let terms = ["movie-1": ["alternative title", "director name"]]

        store.replaceDetailSearchTerms(terms)

        XCTAssertEqual(store.detailSearchTermsByMediaID, terms)
    }

    func testRevisionCanBeSetAndBumped() {
        let store = MediaSearchIndexStateStore()

        store.setRevision(11)
        store.bumpRevision()

        XCTAssertEqual(store.revision, 12)
    }
}
