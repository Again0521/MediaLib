import XCTest
@testable import MediaLib

@MainActor
final class OnboardingReplayStoreTests: XCTestCase {
    func testInitialStateHasNoReplayRequest() {
        let store = OnboardingReplayStore()

        XCTAssertFalse(store.isReplayRequested)
    }

    func testRequestReplayPublishesReplayRequest() {
        let store = OnboardingReplayStore()

        store.requestReplay()

        XCTAssertTrue(store.isReplayRequested)
    }

    func testClearReplayRequestDismissesRequestAfterViewConsumesIt() {
        let store = OnboardingReplayStore()
        store.requestReplay()

        store.clearReplayRequest()

        XCTAssertFalse(store.isReplayRequested)
    }

    func testSetterSupportsExistingAppStateFacadeBinding() {
        let store = OnboardingReplayStore()

        store.setReplayRequested(true)
        XCTAssertTrue(store.isReplayRequested)

        store.setReplayRequested(false)
        XCTAssertFalse(store.isReplayRequested)
    }
}
