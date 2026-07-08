import XCTest
@testable import MediaLib

@MainActor
final class VideoManualCollectionCreationStoreTests: XCTestCase {
    func testRequestCreationPublishesItemIDs() {
        let store = VideoManualCollectionCreationStore()

        store.requestCreation(itemIDs: ["a", "b"])

        XCTAssertEqual(store.request?.itemIDs, ["a", "b"])
    }

    func testRequestCreationIgnoresEmptyItemIDsAndKeepsCurrentRequest() {
        let store = VideoManualCollectionCreationStore()
        store.requestCreation(itemIDs: ["a"])
        let first = store.request

        store.requestCreation(itemIDs: [])

        XCTAssertEqual(store.request, first)
    }

    func testSetRequestAllowsSheetBindingToDismiss() {
        let store = VideoManualCollectionCreationStore()
        let request = VideoManualCollectionCreationRequest(itemIDs: ["a"])

        store.setRequest(request)
        XCTAssertEqual(store.request, request)

        store.setRequest(nil)
        XCTAssertNil(store.request)
    }

    func testClearIfCurrentOnlyClearsMatchingRequest() {
        let store = VideoManualCollectionCreationStore()
        let stale = VideoManualCollectionCreationRequest(itemIDs: ["old"])
        let current = VideoManualCollectionCreationRequest(itemIDs: ["new"])
        store.setRequest(current)

        store.clearIfCurrent(stale)
        XCTAssertEqual(store.request, current)

        store.clearIfCurrent(current)
        XCTAssertNil(store.request)
    }
}
