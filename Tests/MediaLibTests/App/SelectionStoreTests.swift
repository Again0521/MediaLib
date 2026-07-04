import XCTest
import MediaLibCore
@testable import MediaLib

@MainActor
final class SelectionStoreTests: XCTestCase {
    private func makeItem(_ id: String) -> MediaItem {
        MediaItem(id: id, type: .movie, title: id)
    }

    func testToggleModeEntersAndExitsClearingSelection() {
        let store = SelectionStore()
        XCTAssertFalse(store.isSelectionModeActive)

        store.toggleMode()
        XCTAssertTrue(store.isSelectionModeActive)

        store.toggleItem("a")
        XCTAssertEqual(store.selectedItemIDs, ["a"])

        store.toggleMode() // 退出应清空
        XCTAssertFalse(store.isSelectionModeActive)
        XCTAssertTrue(store.selectedItemIDs.isEmpty)
    }

    func testToggleItemAddsAndRemoves() {
        let store = SelectionStore()
        store.toggleItem("a")
        store.toggleItem("b")
        XCTAssertEqual(store.selectedItemIDs, ["a", "b"])
        store.toggleItem("a")
        XCTAssertEqual(store.selectedItemIDs, ["b"])
    }

    func testSetSelectionUnionAndSubtract() {
        let store = SelectionStore()
        store.setSelection(["a", "b", "c"], selected: true)
        XCTAssertEqual(store.selectedItemIDs, ["a", "b", "c"])
        store.setSelection(["b"], selected: false)
        XCTAssertEqual(store.selectedItemIDs, ["a", "c"])
    }

    func testExitShortCircuitsWhenIdle() {
        let store = SelectionStore()
        store.exit() // 无副作用
        XCTAssertFalse(store.isSelectionModeActive)
        XCTAssertTrue(store.selectedItemIDs.isEmpty)
    }

    func testResolveSelectedPreservesOrderAndFilters() {
        let store = SelectionStore()
        store.setSelection(["a", "c"], selected: true)
        let ordered = [makeItem("c"), makeItem("b"), makeItem("a")]
        let resolved = store.resolveSelected(orderedBy: ordered).map(\.id)
        XCTAssertEqual(resolved, ["c", "a"]) // 按传入顺序，过滤未选
    }
}
