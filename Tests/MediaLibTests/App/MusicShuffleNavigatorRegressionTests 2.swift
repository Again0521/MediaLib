import XCTest
import MediaLibCore
@testable import MediaLib

@MainActor
final class MusicShuffleNavigatorRegressionTests: XCTestCase {
    private func items(_ ids: [String]) -> [MediaItem] {
        ids.map { MediaItem(id: $0, type: .music, title: $0) }
    }

    private func makeNavigator() -> MusicShuffleNavigator {
        MusicShuffleNavigator(shuffle: { $0 })
    }

    func testPreviousReinsertsCurrentTrackSoItIsNotSkippedAfterGoingBack() throws {
        let nav = makeNavigator()
        let queue = items(["a", "b", "c"])
        let b = try XCTUnwrap(nav.next(current: queue[0], queue: queue))
        let c = try XCTUnwrap(nav.next(current: b, queue: queue))

        let previous = nav.previous(current: c, queue: queue)
        let replayed = nav.next(current: b, queue: queue)

        XCTAssertEqual(previous?.id, "b")
        XCTAssertEqual(replayed?.id, "c")
    }

    func testBagReloadAfterCycleExcludesCurrentTrack() throws {
        let nav = makeNavigator()
        let queue = items(["a", "b"])
        let b = try XCTUnwrap(nav.next(current: queue[0], queue: queue))

        let afterCycle = nav.next(current: b, queue: queue)

        XCTAssertEqual(b.id, "b")
        XCTAssertEqual(afterCycle?.id, "a")
    }

    func testQueueChangeViaNextDropsHistoryItemsThatAreNoLongerPresent() throws {
        let nav = makeNavigator()
        let originalQueue = items(["a", "b", "c"])
        let b = try XCTUnwrap(nav.next(current: originalQueue[0], queue: originalQueue))
        _ = nav.next(current: b, queue: originalQueue)

        let changedQueue = items(["x", "y"])
        let y = try XCTUnwrap(nav.next(current: changedQueue[0], queue: changedQueue))
        let previous = nav.previous(current: y, queue: changedQueue)

        XCTAssertEqual(y.id, "y")
        XCTAssertEqual(previous?.id, "x")
    }

    func testQueueReorderRebuildsBagUsingNewQueueOrder() throws {
        let nav = makeNavigator()
        let queue = items(["a", "b", "c"])
        let b = try XCTUnwrap(nav.next(current: queue[0], queue: queue))

        let reordered = items(["a", "c", "b"])
        let next = nav.next(current: b, queue: reordered)

        XCTAssertEqual(next?.id, "a")
    }

    func testRepeatedNextCallsWithUnchangedCurrentDoNotDuplicatePreviousHistory() throws {
        let nav = makeNavigator()
        let queue = items(["a", "b", "c"])
        _ = try XCTUnwrap(nav.next(current: queue[0], queue: queue))
        let c = try XCTUnwrap(nav.next(current: queue[0], queue: queue))

        let previous = nav.previous(current: c, queue: queue)
        let previousAgain = nav.previous(current: try XCTUnwrap(previous), queue: queue)

        XCTAssertEqual(c.id, "c")
        XCTAssertEqual(previous?.id, "a")
        XCTAssertNil(previousAgain)
    }
}
