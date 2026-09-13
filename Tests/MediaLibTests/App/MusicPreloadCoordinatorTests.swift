import Foundation
import XCTest
@testable import MediaLib

@MainActor
final class MusicPreloadCoordinatorTests: XCTestCase {
    func testRepeatedRequestKeepsOneInFlightPreparation() async {
        let gate = MusicPreloadGate()
        let coordinator = MusicPreloadCoordinator<Int, Int>()
        var prepares = 0
        var applied: [Int] = []

        coordinator.start(1, prepare: {
            prepares += 1
            await gate.wait()
            return 11
        }, apply: { applied.append($0) })
        await gate.waitUntilBlocked()
        coordinator.start(1, prepare: {
            prepares += 1
            return 99
        }, apply: { applied.append($0) })
        XCTAssertEqual(prepares, 1)
        XCTAssertEqual(coordinator.pendingRequest, 1)

        await gate.release()
        await waitUntil { applied == [11] && coordinator.pendingRequest == nil }
    }

    func testNewRequestRejectsLateOldPreparationEvenIfItIgnoresCancellation() async {
        let gate = MusicPreloadGate()
        let coordinator = MusicPreloadCoordinator<Int, Int>()
        var applied: [Int] = []
        var oldPreparationFinished = false

        coordinator.start(1, prepare: {
            await gate.wait()
            oldPreparationFinished = true
            return 1
        }, apply: { applied.append($0) })
        await gate.waitUntilBlocked()
        coordinator.start(2, prepare: { 2 }, apply: { applied.append($0) })
        await waitUntil { applied == [2] && coordinator.pendingRequest == nil }
        await gate.release()
        await waitUntil { oldPreparationFinished }
        await Task.yield()

        XCTAssertEqual(applied, [2])
    }

    func testCancelForClosePreventsLateInsertion() async {
        let gate = MusicPreloadGate()
        let coordinator = MusicPreloadCoordinator<Int, Int>()
        var applied: [Int] = []
        var oldPreparationFinished = false

        coordinator.start(1, prepare: {
            await gate.wait()
            oldPreparationFinished = true
            return 1
        }, apply: { applied.append($0) })
        await gate.waitUntilBlocked()
        coordinator.cancel()
        await gate.release()
        await waitUntil { oldPreparationFinished }
        await Task.yield()

        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertTrue(applied.isEmpty)
    }

    func testPreparationFailureClearsPendingSoTheTrackCanRetry() async {
        enum FixtureError: Error { case failed }
        let coordinator = MusicPreloadCoordinator<Int, Int>()
        var applied: [Int] = []

        coordinator.start(1, prepare: { throw FixtureError.failed }, apply: { applied.append($0) })
        await waitUntil { coordinator.pendingRequest == nil }
        coordinator.start(1, prepare: { 7 }, apply: { applied.append($0) })
        await waitUntil { applied == [7] }
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testRequestKeySeparatesPlayerGenerationAndPath() {
        let firstPlayer = NSObject()
        let secondPlayer = NSObject()
        let base = MusicPreloadRequest(
            currentItemID: "current",
            nextItemID: "next",
            nextPath: "/music/next.flac",
            playbackGeneration: 3,
            playerIdentity: ObjectIdentifier(firstPlayer)
        )
        XCTAssertNotEqual(base, MusicPreloadRequest(
            currentItemID: "current",
            nextItemID: "next",
            nextPath: "/music/next.flac",
            playbackGeneration: 4,
            playerIdentity: ObjectIdentifier(firstPlayer)
        ))
        XCTAssertNotEqual(base, MusicPreloadRequest(
            currentItemID: "current",
            nextItemID: "next",
            nextPath: "/music/next.flac",
            playbackGeneration: 3,
            playerIdentity: ObjectIdentifier(secondPlayer)
        ))
        XCTAssertNotEqual(base, MusicPreloadRequest(
            currentItemID: "current",
            nextItemID: "next",
            nextPath: "/music/renamed.flac",
            playbackGeneration: 3,
            playerIdentity: ObjectIdentifier(firstPlayer)
        ))
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}

private actor MusicPreloadGate {
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
