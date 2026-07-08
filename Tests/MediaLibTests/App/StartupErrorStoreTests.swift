import XCTest
@testable import MediaLib

@MainActor
final class StartupErrorStoreTests: XCTestCase {
    func testSetMessagePublishesStartupErrorText() {
        let store = StartupErrorStore()
        XCTAssertNil(store.message)

        store.setMessage("Database unavailable")

        XCTAssertEqual(store.message, "Database unavailable")
    }

    func testSetNilAndClearDismissStartupError() {
        let store = StartupErrorStore()
        store.setMessage("Directory unavailable")

        store.setMessage(nil)
        XCTAssertNil(store.message)

        store.setMessage("Database unavailable")
        store.clear()
        XCTAssertNil(store.message)
    }
}
