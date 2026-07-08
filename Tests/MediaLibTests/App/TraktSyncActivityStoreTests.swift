import XCTest
@testable import MediaLib

@MainActor
final class TraktSyncActivityStoreTests: XCTestCase {
    func testInitialStateIsIdle() {
        let store = TraktSyncActivityStore()

        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isImporting)
    }

    func testConnectingLifecycleIsIndependentFromImporting() {
        let store = TraktSyncActivityStore()

        store.beginConnecting()
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.isImporting)

        store.finishConnecting()
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isImporting)
    }

    func testImportingLifecycleIsIndependentFromConnecting() {
        let store = TraktSyncActivityStore()

        store.beginImporting()
        XCTAssertFalse(store.isConnecting)
        XCTAssertTrue(store.isImporting)

        store.finishImporting()
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isImporting)
    }

    func testSettersSupportExistingAppStateFacadeBindings() {
        let store = TraktSyncActivityStore()

        store.setConnecting(true)
        store.setImporting(true)

        XCTAssertTrue(store.isConnecting)
        XCTAssertTrue(store.isImporting)

        store.setConnecting(false)
        store.setImporting(false)

        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isImporting)
    }
}
