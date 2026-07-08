import XCTest
@testable import MediaLib

@MainActor
final class LastfmAuthorizationStateStoreTests: XCTestCase {
    func testInitialStateIsNotAuthorizing() {
        let store = LastfmAuthorizationStateStore()

        XCTAssertFalse(store.isAuthorizing)
    }

    func testSetAuthorizingControlsPublishedState() {
        let store = LastfmAuthorizationStateStore()

        store.setAuthorizing(true)
        XCTAssertTrue(store.isAuthorizing)

        store.setAuthorizing(false)
        XCTAssertFalse(store.isAuthorizing)
    }

    func testBeginAndFinishWrapAuthorizationLifecycle() {
        let store = LastfmAuthorizationStateStore()

        store.begin()
        XCTAssertTrue(store.isAuthorizing)

        store.finish()
        XCTAssertFalse(store.isAuthorizing)
    }
}
