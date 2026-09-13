import Foundation
import XCTest
@testable import MediaLib

@MainActor
final class MusicPlaybackLoadCoordinatorTests: XCTestCase {
    private enum LoadError: Error { case failed }

    func testOldFailureAfterRapidTrackChangeCannotFailNewLoad() async {
        let coordinator = MusicPlaybackLoadCoordinator<Int>()
        let oldGate = MusicPlaybackLoadGate()
        var applied: [Int] = []
        var failures = 0
        var oldLoadFinished = false

        coordinator.start(request(item: "a"), prepare: {
            await oldGate.wait()
            oldLoadFinished = true
            throw LoadError.failed
        }, apply: { applied.append($0) }, fail: { _ in failures += 1 })
        await oldGate.waitUntilBlocked()
        coordinator.start(request(item: "b"), prepare: { 2 },
                          apply: { applied.append($0) }, fail: { _ in failures += 1 })
        await waitUntil { applied == [2] && coordinator.pendingRequest == nil }
        await oldGate.release()
        await waitUntil { oldLoadFinished }
        await Task.yield()

        XCTAssertEqual(applied, [2])
        XCTAssertEqual(failures, 0)
    }

    func testOldSuccessAfterRapidTrackChangeCannotReplaceNewTrack() async {
        let coordinator = MusicPlaybackLoadCoordinator<Int>()
        let oldGate = MusicPlaybackLoadGate()
        var applied: [Int] = []
        var oldLoadFinished = false

        coordinator.start(request(item: "a"), prepare: {
            await oldGate.wait()
            oldLoadFinished = true
            return 1
        }, apply: { applied.append($0) }, fail: { _ in XCTFail("old load failed") })
        await oldGate.waitUntilBlocked()
        coordinator.start(request(item: "b"), prepare: { 2 },
                          apply: { applied.append($0) }, fail: { _ in XCTFail("new load failed") })
        await waitUntil { applied == [2] }
        await oldGate.release()
        await waitUntil { oldLoadFinished }
        await Task.yield()

        XCTAssertEqual(applied, [2])
    }

    func testCancelForCloseSuppressesLateFailure() async {
        let coordinator = MusicPlaybackLoadCoordinator<Int>()
        let gate = MusicPlaybackLoadGate()
        var failures = 0
        var loadFinished = false

        coordinator.start(request(item: "a"), prepare: {
            await gate.wait()
            loadFinished = true
            throw LoadError.failed
        }, apply: { _ in XCTFail("closed load applied") }, fail: { _ in failures += 1 })
        await gate.waitUntilBlocked()
        coordinator.cancel()
        await gate.release()
        await waitUntil { loadFinished }
        await Task.yield()

        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertEqual(failures, 0)
    }

    func testOnlyCurrentFailureIsPresentedAndClearsPendingRequest() async {
        let coordinator = MusicPlaybackLoadCoordinator<Int>()
        var failures = 0
        coordinator.start(request(item: "a"), prepare: { throw LoadError.failed },
                          apply: { _ in XCTFail("failure applied") }, fail: { _ in failures += 1 })
        await waitUntil { failures == 1 && coordinator.pendingRequest == nil }
    }

    func testRequestIdentityIncludesTrackPathPlayerAndGeneration() {
        let playerA = NSObject()
        let playerB = NSObject()
        let base = request(item: "a", player: playerA)
        XCTAssertNotEqual(base, request(item: "b", player: playerA))
        XCTAssertNotEqual(base, request(item: "a", path: "/new/a.flac", player: playerA))
        XCTAssertNotEqual(base, request(item: "a", player: playerB))
        XCTAssertNotEqual(base, request(item: "a", generation: 2, player: playerA))
    }

    private func request(
        item: String,
        path: String = "/music/a.flac",
        generation: Int = 1,
        player: NSObject? = nil
    ) -> MusicPlaybackLoadRequest {
        MusicPlaybackLoadRequest(
            itemID: item,
            path: path,
            playbackGeneration: generation,
            playerIdentity: player.map(ObjectIdentifier.init)
        )
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}

private actor MusicPlaybackLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while continuation == nil { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
