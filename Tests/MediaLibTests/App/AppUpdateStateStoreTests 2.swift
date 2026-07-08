import XCTest
@testable import MediaLib

@MainActor
final class AppUpdateStateStoreTests: XCTestCase {
    func testCheckingFlagCanBeSetAndCleared() {
        let store = AppUpdateStateStore()
        XCTAssertFalse(store.isCheckingForUpdates)

        store.setCheckingForUpdates(true)
        XCTAssertTrue(store.isCheckingForUpdates)

        store.setCheckingForUpdates(false)
        XCTAssertFalse(store.isCheckingForUpdates)
    }

    func testAvailableUpdateCanBeSetAndCleared() throws {
        let store = AppUpdateStateStore()
        let update = try makeUpdate(version: "2.0.0", tagName: "v2.0.0")

        store.setAvailableUpdate(update)
        XCTAssertEqual(store.availableUpdate, update)

        store.clearAvailableUpdate()
        XCTAssertNil(store.availableUpdate)
    }

    func testSettingNilAvailableUpdateMatchesSheetDismissalBinding() throws {
        let store = AppUpdateStateStore()
        store.setAvailableUpdate(try makeUpdate(version: "2.0.0", tagName: "v2.0.0"))

        store.setAvailableUpdate(nil)

        XCTAssertNil(store.availableUpdate)
    }

    private func makeUpdate(version: String, tagName: String) throws -> AppUpdateInfo {
        AppUpdateInfo(
            version: version,
            tagName: tagName,
            title: "MediaLIB \(version)",
            releaseNotes: "Notes",
            releaseURL: try XCTUnwrap(URL(string: "https://example.test/releases/\(tagName)")),
            downloadURL: try XCTUnwrap(URL(string: "https://example.test/MediaLIB-\(version).dmg")),
            assetName: "MediaLIB-\(version).dmg",
            assetSize: 123_456,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            prerelease: false
        )
    }
}
