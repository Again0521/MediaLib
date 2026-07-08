import XCTest
@testable import MediaLib

@MainActor
final class VideoOfflineSubscriptionLimitStoreTests: XCTestCase {
    func testPresentRequestPublishesAllSheetFields() {
        let store = VideoOfflineSubscriptionLimitStore()

        store.presentRequest(
            itemID: "series-1",
            seriesTitle: "Series",
            qualityID: "1080p",
            initialEpisodeLimit: 5,
            hidesDetail: true
        )

        XCTAssertEqual(store.request?.itemID, "series-1")
        XCTAssertEqual(store.request?.seriesTitle, "Series")
        XCTAssertEqual(store.request?.qualityID, "1080p")
        XCTAssertEqual(store.request?.initialEpisodeLimit, 5)
        XCTAssertEqual(store.request?.hidesDetail, true)
        XCTAssertEqual(store.request?.displayTitle, "这个系列")
    }

    func testSetRequestAllowsSheetBindingToDismiss() {
        let store = VideoOfflineSubscriptionLimitStore()
        let request = VideoOfflineSubscriptionLimitRequest(
            itemID: "series-1",
            seriesTitle: "Series",
            qualityID: nil,
            initialEpisodeLimit: 3,
            hidesDetail: false
        )

        store.setRequest(request)
        XCTAssertEqual(store.request, request)

        store.setRequest(nil)
        XCTAssertNil(store.request)
    }

    func testClearIfCurrentOnlyClearsMatchingRequest() {
        let store = VideoOfflineSubscriptionLimitStore()
        let stale = VideoOfflineSubscriptionLimitRequest(
            itemID: "old",
            seriesTitle: "Old",
            qualityID: nil,
            initialEpisodeLimit: 3,
            hidesDetail: false
        )
        let current = VideoOfflineSubscriptionLimitRequest(
            itemID: "new",
            seriesTitle: "New",
            qualityID: "720p",
            initialEpisodeLimit: 4,
            hidesDetail: true
        )
        store.setRequest(current)

        store.clearIfCurrent(stale)
        XCTAssertEqual(store.request, current)

        store.clearIfCurrent(current)
        XCTAssertNil(store.request)
    }
}
