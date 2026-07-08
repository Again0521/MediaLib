import XCTest
import MediaLibCore
@testable import MediaLib

@MainActor
final class DetailNavigationStoreTests: XCTestCase {
    private func makeItem(_ id: String, title: String? = nil) -> MediaItem {
        MediaItem(id: id, type: .movie, title: title ?? id)
    }

    func testPresentDetailSelectsItemClearsPersonAndNormalizesReturnSearchText() {
        let store = DetailNavigationStore()
        store.setSelectedPersonID("person-a")

        store.presentDetail(
            makeItem("movie-a"),
            from: "home",
            anchorID: "anchor-a",
            searchText: "  noir  "
        )

        XCTAssertEqual(store.selectedItem?.id, "movie-a")
        XCTAssertNil(store.selectedPersonID)
        XCTAssertEqual(store.detailReturnContext?.destinationID, "home")
        XCTAssertEqual(store.detailReturnContext?.anchorID, "anchor-a")
        XCTAssertEqual(store.detailReturnContext?.searchText, "noir")
    }

    func testPresentDetailStoresNilSearchTextWhenBlank() {
        let store = DetailNavigationStore()

        store.presentDetail(
            makeItem("movie-a"),
            from: "library",
            anchorID: "movie-a",
            searchText: "   "
        )

        XCTAssertNil(store.detailReturnContext?.searchText)
    }

    func testRelatedDetailPushesCurrentMediaAndDismissRestoresIt() {
        let store = DetailNavigationStore()
        let first = makeItem("movie-a")
        let second = makeItem("movie-b")

        store.presentDetail(first, from: "home", anchorID: first.id)
        store.presentRelatedDetail(second)
        XCTAssertEqual(store.selectedItem?.id, "movie-b")

        store.dismissDetail { id in
            id == first.id ? first : nil
        }

        XCTAssertEqual(store.selectedItem?.id, "movie-a")
        XCTAssertNil(store.selectedPersonID)
    }

    func testPersonNavigationPushesMediaAndPersonHistory() {
        let store = DetailNavigationStore()
        let item = makeItem("movie-a")
        store.presentDetail(item, from: "home", anchorID: item.id)

        store.presentPersonDetail("person-a")
        XCTAssertNil(store.selectedItem)
        XCTAssertEqual(store.selectedPersonID, "person-a")

        store.presentPersonDetail("person-b")
        XCTAssertEqual(store.selectedPersonID, "person-b")

        store.dismissDetail { _ in nil }
        XCTAssertEqual(store.selectedPersonID, "person-a")

        store.dismissDetail { id in
            id == item.id ? item : nil
        }
        XCTAssertEqual(store.selectedItem?.id, item.id)
        XCTAssertNil(store.selectedPersonID)
    }

    func testDismissWithoutHistoryClearsSelection() {
        let store = DetailNavigationStore()
        store.setSelectedItem(makeItem("movie-a"))
        store.setSelectedPersonID("person-a")

        store.dismissDetail { _ in
            XCTFail("Resolver should not be called when history is empty")
            return nil
        }

        XCTAssertNil(store.selectedItem)
        XCTAssertNil(store.selectedPersonID)
    }

    func testDismissToMissingMediaClearsSelectedItemAndPerson() {
        let store = DetailNavigationStore()
        store.presentDetail(makeItem("movie-a"), from: "home", anchorID: "movie-a")
        store.presentRelatedDetail(makeItem("movie-b"))

        store.dismissDetail { _ in nil }

        XCTAssertNil(store.selectedItem)
        XCTAssertNil(store.selectedPersonID)
    }

    func testConsumeReturnContextOnlyClearsExactDestinationAndAnchor() {
        let store = DetailNavigationStore()
        store.presentDetail(makeItem("movie-a"), from: "home", anchorID: "movie-a")

        store.consumeReturnContext(destinationID: "library", anchorID: "movie-a")
        XCTAssertNotNil(store.detailReturnContext)

        store.consumeReturnContext(destinationID: "home", anchorID: "other")
        XCTAssertNotNil(store.detailReturnContext)

        store.consumeReturnContext(destinationID: "home", anchorID: "movie-a")
        XCTAssertNil(store.detailReturnContext)
    }

    func testPresentDetailResetsPreviousHistory() {
        let store = DetailNavigationStore()
        store.presentDetail(makeItem("movie-a"), from: "home", anchorID: "movie-a")
        store.presentRelatedDetail(makeItem("movie-b"))

        store.presentDetail(makeItem("movie-c"), from: "library", anchorID: "movie-c")
        store.dismissDetail { _ in
            XCTFail("History should be reset by presentDetail")
            return nil
        }

        XCTAssertNil(store.selectedItem)
        XCTAssertNil(store.selectedPersonID)
    }

    func testClearRemovesSelectionReturnContextAndHistory() {
        let store = DetailNavigationStore()
        store.presentDetail(makeItem("movie-a"), from: "home", anchorID: "movie-a")
        store.presentRelatedDetail(makeItem("movie-b"))

        store.clear()
        XCTAssertNil(store.selectedItem)
        XCTAssertNil(store.selectedPersonID)
        XCTAssertNil(store.detailReturnContext)

        store.dismissDetail { _ in
            XCTFail("History should be empty after clear")
            return nil
        }
        XCTAssertNil(store.selectedItem)
        XCTAssertNil(store.selectedPersonID)
    }
}
