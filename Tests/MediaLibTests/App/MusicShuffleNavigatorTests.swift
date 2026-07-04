import XCTest
import MediaLibCore
@testable import MediaLib

@MainActor
final class MusicShuffleNavigatorTests: XCTestCase {
    private func items(_ ids: [String]) -> [MediaItem] {
        ids.map { MediaItem(id: $0, type: .music, title: $0) }
    }

    /// 注入恒等「洗牌」以获得确定性顺序，便于断言行为。
    private func makeNavigator() -> MusicShuffleNavigator {
        MusicShuffleNavigator(shuffle: { $0 })
    }

    func testCyclePlaysEveryTrackOnceBeforeRepeating() {
        let nav = makeNavigator()
        let queue = items(["a", "b", "c", "d"])
        var current = queue[0] // a
        var played = [current.id]
        // 取接下来 3 首，应覆盖剩余 b/c/d 各一次（整轮不重复）。
        for _ in 0..<3 {
            let next = nav.next(current: current, queue: queue)
            current = try! XCTUnwrap(next)
            played.append(current.id)
        }
        XCTAssertEqual(Set(played), ["a", "b", "c", "d"])
        XCTAssertEqual(played.count, 4) // 无重复
    }

    func testPreviousRetracesHistory() {
        let nav = makeNavigator()
        let queue = items(["a", "b", "c", "d"])
        let a = queue[0]
        let next1 = try! XCTUnwrap(nav.next(current: a, queue: queue))      // a→某首
        let next2 = try! XCTUnwrap(nav.next(current: next1, queue: queue))  // →下一首
        // 从 next2 回退应回到 next1
        let back = nav.previous(current: next2, queue: queue)
        XCTAssertEqual(back?.id, next1.id)
    }

    func testPreviousReturnsNilWhenNoHistory() {
        let nav = makeNavigator()
        let queue = items(["a", "b", "c"])
        XCTAssertNil(nav.previous(current: queue[0], queue: queue))
    }

    func testSingleItemQueueReturnsItself() {
        let nav = makeNavigator()
        let queue = items(["solo"])
        let next = nav.next(current: queue[0], queue: queue)
        XCTAssertEqual(next?.id, "solo")
    }

    func testEmptyQueueReturnsNil() {
        let nav = makeNavigator()
        XCTAssertNil(nav.next(current: MediaItem(id: "x", type: .music, title: "x"), queue: []))
    }

    func testResetClearsHistorySoPreviousReturnsNil() {
        let nav = makeNavigator()
        let queue = items(["a", "b", "c"])
        let n1 = try! XCTUnwrap(nav.next(current: queue[0], queue: queue))
        _ = nav.next(current: n1, queue: queue)
        nav.reset()
        XCTAssertNil(nav.previous(current: queue[1], queue: queue))
    }

    func testQueueChangeDropsStaleHistory() {
        let nav = makeNavigator()
        let queue1 = items(["a", "b", "c"])
        let n1 = try! XCTUnwrap(nav.next(current: queue1[0], queue: queue1)) // 历史含 a
        // 换成完全不同的队列：旧历史(a)应被丢弃 → previous 无可回溯
        let queue2 = items(["x", "y", "z"])
        _ = nav.next(current: queue2[0], queue: queue2)
        let back = nav.previous(current: queue2[1], queue: queue2)
        XCTAssertNotEqual(back?.id, n1.id) // 不会回到已不在队列里的旧曲目
    }
}
