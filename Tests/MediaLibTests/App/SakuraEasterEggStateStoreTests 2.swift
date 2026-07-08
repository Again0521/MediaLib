import XCTest
@testable import MediaLib

@MainActor
final class SakuraEasterEggStateStoreTests: XCTestCase {
    func testInitialStateIsInactiveAndUnshownForLaunch() {
        let store = SakuraEasterEggStateStore()

        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.shownThisLaunch)
    }

    func testSetActiveTogglesOnlyVisibleAnimationState() {
        let store = SakuraEasterEggStateStore()

        store.setActive(true)
        XCTAssertTrue(store.isActive)
        XCTAssertFalse(store.shownThisLaunch)

        store.setActive(false)
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.shownThisLaunch)
    }

    func testLaunchShownFlagSurvivesAnimationDismissal() {
        let store = SakuraEasterEggStateStore()

        store.setShownThisLaunch(true)
        store.setActive(true)
        store.setActive(false)

        XCTAssertFalse(store.isActive)
        XCTAssertTrue(store.shownThisLaunch)
    }

    func testSettersSupportExistingAppStateFacadeBindings() {
        let store = SakuraEasterEggStateStore()

        store.setShownThisLaunch(true)
        store.setActive(true)

        XCTAssertTrue(store.shownThisLaunch)
        XCTAssertTrue(store.isActive)

        store.setShownThisLaunch(false)
        store.setActive(false)

        XCTAssertFalse(store.shownThisLaunch)
        XCTAssertFalse(store.isActive)
    }
}
