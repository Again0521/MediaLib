import XCTest
@testable import MediaLib

@MainActor
final class NetworkStreamPromptStoreTests: XCTestCase {
    func testSetShowingPromptControlsSheetState() {
        let store = NetworkStreamPromptStore()
        XCTAssertFalse(store.isShowingPrompt)

        store.setShowingPrompt(true)
        XCTAssertTrue(store.isShowingPrompt)

        store.setShowingPrompt(false)
        XCTAssertFalse(store.isShowingPrompt)
    }

    func testPresentAndDismissPrompt() {
        let store = NetworkStreamPromptStore()

        store.presentPrompt()
        XCTAssertTrue(store.isShowingPrompt)

        store.dismissPrompt()
        XCTAssertFalse(store.isShowingPrompt)
    }
}
