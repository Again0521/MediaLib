import XCTest
@testable import MediaLib

@MainActor
final class MusicMetadataActivityStoreTests: XCTestCase {
    func testInitialStateIsIdleWithEmptyProgress() {
        let store = MusicMetadataActivityStore()

        XCTAssertFalse(store.isFetching)
        XCTAssertFalse(store.isSupplementing)
        XCTAssertEqual(store.fetchProgress, "")
    }

    func testFetchingLifecyclePreservesLatestProgressWhenFinishing() {
        let store = MusicMetadataActivityStore()

        store.beginFetching(progress: "准备补充 3 首")
        XCTAssertTrue(store.isFetching)
        XCTAssertEqual(store.fetchProgress, "准备补充 3 首")

        store.setFetchProgress("完成 2/3 首")
        store.finishFetching()

        XCTAssertFalse(store.isFetching)
        XCTAssertEqual(store.fetchProgress, "完成 2/3 首")
    }

    func testSettersSupportExistingAppStateFacadeBindings() {
        let store = MusicMetadataActivityStore()

        store.setFetching(true)
        store.setSupplementing(true)
        store.setFetchProgress("1/2 Track")

        XCTAssertTrue(store.isFetching)
        XCTAssertTrue(store.isSupplementing)
        XCTAssertEqual(store.fetchProgress, "1/2 Track")

        store.setFetching(false)
        store.setSupplementing(false)

        XCTAssertFalse(store.isFetching)
        XCTAssertFalse(store.isSupplementing)
    }

    func testSupplementingLifecycleIsIndependentFromFetching() {
        let store = MusicMetadataActivityStore()
        store.beginFetching(progress: "准备补充 1 首")

        store.beginSupplementing()
        XCTAssertTrue(store.isFetching)
        XCTAssertTrue(store.isSupplementing)

        store.finishSupplementing()
        XCTAssertTrue(store.isFetching)
        XCTAssertFalse(store.isSupplementing)
    }
}
