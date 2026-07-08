import XCTest
@testable import MediaLib

@MainActor
final class ThemeRefreshStoreTests: XCTestCase {
    func testInitialRevisionsAreZero() {
        let store = ThemeRefreshStore()

        XCTAssertEqual(store.themeRevision, 0)
        XCTAssertEqual(store.musicThemeRevision, 0)
    }

    func testThemeRevisionCanBeSetAndBumpedIndependently() {
        let store = ThemeRefreshStore()

        store.setThemeRevision(41)
        store.bumpThemeRevision()

        XCTAssertEqual(store.themeRevision, 42)
        XCTAssertEqual(store.musicThemeRevision, 0)
    }

    func testMusicThemeRevisionCanBeSetAndBumpedIndependently() {
        let store = ThemeRefreshStore()

        store.setMusicThemeRevision(6)
        store.bumpMusicThemeRevision()

        XCTAssertEqual(store.themeRevision, 0)
        XCTAssertEqual(store.musicThemeRevision, 7)
    }

    func testBumpsUseOverflowingRevisionSemantics() {
        let store = ThemeRefreshStore()

        store.setThemeRevision(Int.max)
        store.setMusicThemeRevision(Int.max)
        store.bumpThemeRevision()
        store.bumpMusicThemeRevision()

        XCTAssertEqual(store.themeRevision, Int.min)
        XCTAssertEqual(store.musicThemeRevision, Int.min)
    }
}
