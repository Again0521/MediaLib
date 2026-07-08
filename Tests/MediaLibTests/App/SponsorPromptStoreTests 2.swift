import XCTest
@testable import MediaLib

@MainActor
final class SponsorPromptStoreTests: XCTestCase {
    func testSetShowingInviteControlsSheetState() {
        let store = SponsorPromptStore()
        XCTAssertFalse(store.isShowingInvite)

        store.setShowingInvite(true)
        XCTAssertTrue(store.isShowingInvite)

        store.setShowingInvite(false)
        XCTAssertFalse(store.isShowingInvite)
    }

    func testPresentAndDismissInvite() {
        let store = SponsorPromptStore()

        store.presentInvite()
        XCTAssertTrue(store.isShowingInvite)

        store.dismissInvite()
        XCTAssertFalse(store.isShowingInvite)
    }
}
