import XCTest
import MediaLibCore
@testable import MediaLib

@MainActor
final class QuickPreviewStoreTests: XCTestCase {
    private func makeItem(_ id: String, title: String? = nil) -> MediaItem {
        MediaItem(id: id, type: .movie, title: title ?? id)
    }

    func testSetItemPublishesCurrentPreview() {
        let store = QuickPreviewStore()

        store.setItem(makeItem("movie-a"))

        XCTAssertEqual(store.item?.id, "movie-a")
    }

    func testClearRemovesCurrentPreview() {
        let store = QuickPreviewStore()
        store.setItem(makeItem("movie-a"))

        store.clear()

        XCTAssertNil(store.item)
    }

    func testReplaceIfCurrentItemMatchesUpdatesOnlySameID() {
        let store = QuickPreviewStore()
        store.setItem(makeItem("movie-a", title: "Old"))

        store.replaceIfCurrentItemMatches(id: "movie-b", with: makeItem("movie-b", title: "Other"))
        XCTAssertEqual(store.item?.title, "Old")

        store.replaceIfCurrentItemMatches(id: "movie-a", with: makeItem("movie-a", title: "New"))
        XCTAssertEqual(store.item?.title, "New")
    }

    func testReplaceIfCurrentItemMatchesDoesNothingWhenPreviewIsEmpty() {
        let store = QuickPreviewStore()

        store.replaceIfCurrentItemMatches(id: "movie-a", with: makeItem("movie-a"))

        XCTAssertNil(store.item)
    }
}
