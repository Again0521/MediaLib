import XCTest
@testable import MediaLib

@MainActor
final class EmbyRestrictionNoticeStoreTests: XCTestCase {
    func testPresentNoticePublishesPayload() {
        let store = EmbyRestrictionNoticeStore()
        let identity = makeIdentity()

        store.presentNotice(serverHost: "example.test", reason: "blocked", identity: identity)

        XCTAssertEqual(store.notice?.serverHost, "example.test")
        XCTAssertEqual(store.notice?.reason, "blocked")
        XCTAssertEqual(store.notice?.identity, identity)
    }

    func testSetNoticeAllowsSheetBindingToDismiss() {
        let store = EmbyRestrictionNoticeStore()
        let notice = EmbyRestrictionNotice(serverHost: "example.test", reason: nil, identity: makeIdentity())

        store.setNotice(notice)
        XCTAssertEqual(store.notice?.serverHost, "example.test")

        store.setNotice(nil)
        XCTAssertNil(store.notice)
    }

    func testClearDismissesCurrentNotice() {
        let store = EmbyRestrictionNoticeStore()
        store.presentNotice(serverHost: "example.test", reason: nil, identity: makeIdentity())

        store.clear()

        XCTAssertNil(store.notice)
    }

    private func makeIdentity() -> EmbyClientIdentity {
        EmbyClientIdentity(
            client: "MediaLIB",
            device: "Mac",
            deviceID: "device-1",
            version: "1.0",
            userAgent: "MediaLIB/1.0"
        )
    }
}
