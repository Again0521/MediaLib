import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class RemotePlaybackPreparationCoordinatorTests: XCTestCase {
    func testNewRequestDiscardsOlderPreparedItemEvenWhenPrepareIgnoresCancellation() async {
        let gate = PlaybackPreparationGate()
        let coordinator = RemotePlaybackPreparationCoordinator()
        var openedItemIDs: [String] = []
        var failures = 0

        coordinator.start(
            request(itemID: "old", sourceID: "source-a"),
            prepare: { request in
                if request.item.id == "old" { await gate.wait() }
                return request.item
            },
            apply: { item, _ in openedItemIDs.append(item.id) },
            failure: { _, _ in failures += 1 }
        )
        await gate.waitUntilBlocked()

        coordinator.start(
            request(itemID: "new", sourceID: "source-b"),
            prepare: { $0.item },
            apply: { item, _ in openedItemIDs.append(item.id) },
            failure: { _, _ in failures += 1 }
        )
        await waitUntil { openedItemIDs == ["new"] }
        await gate.release()
        await Task.yield()

        XCTAssertEqual(openedItemIDs, ["new"])
        XCTAssertEqual(failures, 0)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testCancellingMatchingSourcePreventsLateApply() async {
        let gate = PlaybackPreparationGate()
        let coordinator = RemotePlaybackPreparationCoordinator()
        var openedItemIDs: [String] = []

        coordinator.start(
            request(itemID: "movie", sourceID: "deleted-source"),
            prepare: { request in
                await gate.wait()
                return request.item
            },
            apply: { item, _ in openedItemIDs.append(item.id) },
            failure: { _, _ in XCTFail("unexpected failure") }
        )
        await gate.waitUntilBlocked()

        XCTAssertFalse(coordinator.cancel(sourceID: "another-source"))
        XCTAssertNotNil(coordinator.pendingRequest)
        XCTAssertTrue(coordinator.cancel(sourceID: "deleted-source"))
        await gate.release()
        await Task.yield()

        XCTAssertTrue(openedItemIDs.isEmpty)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testExplicitCancelPreventsLateFailurePresentation() async {
        enum TestError: Error { case expected }
        let gate = PlaybackPreparationGate()
        let coordinator = RemotePlaybackPreparationCoordinator()
        var failures = 0

        coordinator.start(
            request(itemID: "movie", sourceID: "source"),
            prepare: { _ in
                await gate.wait()
                throw TestError.expected
            },
            apply: { _, _ in XCTFail("unexpected apply") },
            failure: { _, _ in failures += 1 }
        )
        await gate.waitUntilBlocked()
        coordinator.cancel()
        await gate.release()
        await Task.yield()

        XCTAssertEqual(failures, 0)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testLatestFailureIsReportedWithOriginalRequest() async {
        enum TestError: Error { case expected }
        let coordinator = RemotePlaybackPreparationCoordinator()
        var failedRequest: RemotePlaybackPreparationRequest?

        coordinator.start(
            request(itemID: "movie", sourceID: "source", preserveSelection: true),
            prepare: { _ in throw TestError.expected },
            apply: { _, _ in XCTFail("unexpected apply") },
            failure: { _, request in failedRequest = request }
        )
        await waitUntil { failedRequest != nil }

        XCTAssertEqual(failedRequest?.item.id, "movie")
        XCTAssertEqual(failedRequest?.sourceID, "source")
        XCTAssertEqual(failedRequest?.preserveSelection, true)
        XCTAssertNil(coordinator.pendingRequest)
    }

    private func request(
        itemID: String,
        sourceID: String,
        preserveSelection: Bool = false
    ) -> RemotePlaybackPreparationRequest {
        RemotePlaybackPreparationRequest(
            item: MediaItem(
                id: itemID,
                type: .movie,
                title: itemID,
                sourcePath: "emby://\(sourceID)",
                filePath: "https://example.invalid/\(itemID)"
            ),
            sourceID: sourceID,
            preserveSelection: preserveSelection
        )
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

private actor PlaybackPreparationGate {
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
