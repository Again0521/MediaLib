import XCTest
@testable import MediaLib

@MainActor
final class TMDBMatchStateStoreTests: XCTestCase {
    func testInitialStateIsNotMatching() {
        let store = TMDBMatchStateStore()

        XCTAssertFalse(store.isMatching)
    }

    func testSetMatchingControlsPublishedState() {
        let store = TMDBMatchStateStore()

        store.setMatching(true)
        XCTAssertTrue(store.isMatching)

        store.setMatching(false)
        XCTAssertFalse(store.isMatching)
    }

    func testBeginAndFinishWrapMatchLifecycle() {
        let store = TMDBMatchStateStore()

        store.begin()
        XCTAssertTrue(store.isMatching)

        store.finish()
        XCTAssertFalse(store.isMatching)
    }
}
