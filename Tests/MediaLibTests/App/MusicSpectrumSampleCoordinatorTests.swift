import CoreGraphics
import Foundation
import XCTest
@testable import MediaLib

@MainActor
final class MusicSpectrumSampleCoordinatorTests: XCTestCase {
    func testCancelledOldTrackCannotApplyOrOccupyNewTrackSlot() async {
        let coordinator = MusicSpectrumSampleCoordinator()
        let gate = MusicSpectrumSampleGate()
        var applied: [[CGFloat]] = []
        var oldSampleFinished = false

        coordinator.start(sample: {
            await gate.wait()
            oldSampleFinished = true
            return [0.1]
        }, apply: { applied.append($0) })
        await gate.waitUntilBlocked()
        coordinator.cancel()
        XCTAssertFalse(coordinator.isSampling)

        coordinator.start(sample: { [0.9] }, apply: { applied.append($0) })
        await waitUntil { applied == [[0.9]] && !coordinator.isSampling }
        await gate.release()
        await waitUntil { oldSampleFinished }
        await Task.yield()

        XCTAssertEqual(applied, [[0.9]])
        XCTAssertFalse(coordinator.isSampling)
    }

    func testRepeatedTickWhileSamplingDoesNotStartSecondDecode() async {
        let coordinator = MusicSpectrumSampleCoordinator()
        let gate = MusicSpectrumSampleGate()
        var starts = 0
        var applied: [[CGFloat]] = []

        coordinator.start(sample: {
            starts += 1
            await gate.wait()
            return [0.4]
        }, apply: { applied.append($0) })
        await gate.waitUntilBlocked()
        coordinator.start(sample: {
            starts += 1
            return [0.8]
        }, apply: { applied.append($0) })
        XCTAssertTrue(coordinator.isSampling)
        XCTAssertEqual(starts, 1)

        await gate.release()
        await waitUntil { applied == [[0.4]] && !coordinator.isSampling }
        coordinator.start(sample: { [0.7] }, apply: { applied.append($0) })
        await waitUntil { applied == [[0.4], [0.7]] && !coordinator.isSampling }
    }

    func testCloseSuppressesLateDecodeResult() async {
        let coordinator = MusicSpectrumSampleCoordinator()
        let gate = MusicSpectrumSampleGate()
        var applied: [[CGFloat]] = []
        var sampleFinished = false

        coordinator.start(sample: {
            await gate.wait()
            sampleFinished = true
            return [0.5]
        }, apply: { applied.append($0) })
        await gate.waitUntilBlocked()
        coordinator.cancel()
        await gate.release()
        await waitUntil { sampleFinished }
        await Task.yield()

        XCTAssertFalse(coordinator.isSampling)
        XCTAssertTrue(applied.isEmpty)
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}

private actor MusicSpectrumSampleGate {
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
