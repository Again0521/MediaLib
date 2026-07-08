import XCTest
@testable import MediaLib

@MainActor
final class FloatingNoticeStoreTests: XCTestCase {
    func testInitialStateHasNoVisibleNotices() {
        let store = FloatingNoticeStore()

        XCTAssertTrue(store.notices.isEmpty)
        XCTAssertTrue(store.isEmpty)
    }

    func testPresentReplacesVisibleNoticeWithSingleCurrentNotice() {
        let store = FloatingNoticeStore()
        let first = AppFloatingNotice(id: UUID(), title: "First", kind: .info)
        let second = AppFloatingNotice(id: UUID(), title: "Second", kind: .success)

        store.present(first)
        store.present(second)

        XCTAssertEqual(store.notices, [second])
        XCTAssertFalse(store.isEmpty)
    }

    func testRemoveByIDOnlyDismissesMatchingNotice() {
        let store = FloatingNoticeStore()
        let first = AppFloatingNotice(id: UUID(), title: "First", kind: .info)
        let second = AppFloatingNotice(id: UUID(), title: "Second", kind: .warning)
        store.replaceVisibleNotices(with: [first, second])

        store.remove(id: first.id)

        XCTAssertEqual(store.notices, [second])
    }

    func testClearDismissesAllVisibleNotices() {
        let store = FloatingNoticeStore()
        store.present(AppFloatingNotice(title: "Visible", kind: .tip))

        store.clear()

        XCTAssertTrue(store.notices.isEmpty)
        XCTAssertTrue(store.isEmpty)
    }
}
