import XCTest
@testable import MediaLib

@MainActor
final class PrivacyLockStateStoreTests: XCTestCase {
    func testInitialStateIsLockedAndUnconfigured() {
        let store = PrivacyLockStateStore()

        XCTAssertFalse(store.isPINConfigured)
        XCTAssertFalse(store.isUnlocked)
    }

    func testConfigurePINAndUnlockMarksVaultVisible() {
        let store = PrivacyLockStateStore()

        store.configurePINAndUnlock()

        XCTAssertTrue(store.isPINConfigured)
        XCTAssertTrue(store.isUnlocked)
    }

    func testLockKeepsPINConfigurationButHidesVault() {
        let store = PrivacyLockStateStore()
        store.configurePINAndUnlock()

        store.lock()

        XCTAssertTrue(store.isPINConfigured)
        XCTAssertFalse(store.isUnlocked)
    }

    func testClearPINConfigurationLocksAndRemovesConfiguredState() {
        let store = PrivacyLockStateStore()
        store.configurePINAndUnlock()

        store.clearPINConfiguration()

        XCTAssertFalse(store.isPINConfigured)
        XCTAssertFalse(store.isUnlocked)
    }

    func testSettersSupportExistingAppStateFacadeBindings() {
        let store = PrivacyLockStateStore()

        store.setPINConfigured(true)
        store.setUnlocked(true)

        XCTAssertTrue(store.isPINConfigured)
        XCTAssertTrue(store.isUnlocked)

        store.setUnlocked(false)
        store.setPINConfigured(false)

        XCTAssertFalse(store.isPINConfigured)
        XCTAssertFalse(store.isUnlocked)
    }
}
