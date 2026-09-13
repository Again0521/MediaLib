import Foundation
import XCTest
@testable import MediaLib

@MainActor
final class VideoQualityResumeCoordinatorTests: XCTestCase {
    func testReloadOfSameStreamCannotIssueLateSeekEvenWhenSleepIgnoresCancellation() async {
        let coordinator = VideoQualityResumeCoordinator()
        let oldGate = VideoQualityResumeGate()
        let engine = NSObject()
        var commands: [Double] = []
        var oldSleepFinished = false

        coordinator.start(request(target: 40, engine: engine), sleep: { _ in
            await oldGate.wait()
            oldSleepFinished = true
        }, isCurrent: { true }, observedTime: { 0 }, seek: { commands.append($0) })
        await oldGate.waitUntilBlocked()
        coordinator.start(request(target: 40, engine: engine), sleep: { _ in },
                          isCurrent: { true }, observedTime: { 100 },
                          seek: { commands.append($0) })
        await waitUntil { coordinator.pendingRequest == nil }
        await oldGate.release()
        await waitUntil { oldSleepFinished }
        await Task.yield()

        XCTAssertTrue(commands.isEmpty)
    }

    func testCancelForClosePreventsLateSeek() async {
        let coordinator = VideoQualityResumeCoordinator()
        let gate = VideoQualityResumeGate()
        var commands: [Double] = []
        var sleepFinished = false

        coordinator.start(request(target: 40), sleep: { _ in
            await gate.wait()
            sleepFinished = true
        }, isCurrent: { true }, observedTime: { 0 }, seek: { commands.append($0) })
        await gate.waitUntilBlocked()
        coordinator.cancel()
        await gate.release()
        await waitUntil { sleepFinished }
        await Task.yield()

        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertTrue(commands.isEmpty)
    }

    func testRetriesAreBoundedAndStopWhenTimelineRecovers() async {
        let coordinator = VideoQualityResumeCoordinator()
        var observed = 0.0
        var delays: [UInt64] = []
        var commands: [Double] = []

        coordinator.start(request(target: 40), sleep: { delays.append($0) },
                          isCurrent: { true }, observedTime: { observed },
                          seek: { target in
                              commands.append(target)
                              observed = target
                          })
        await waitUntil { coordinator.pendingRequest == nil }

        XCTAssertEqual(commands, [40])
        XCTAssertEqual(delays, [120_000_000, 175_000_000])
    }

    func testRejectsDifferentCurrentStreamAndRequestIdentity() async {
        let firstEngine = NSObject()
        let secondEngine = NSObject()
        let base = request(target: 40, engine: firstEngine)
        XCTAssertNotEqual(base, request(target: 90, engine: firstEngine))
        XCTAssertNotEqual(base, request(target: 40, engine: secondEngine))
        XCTAssertNotEqual(base, request(target: 40, engine: firstEngine, url: "stream-b"))
        XCTAssertNotEqual(base, request(target: 40, engine: firstEngine, generation: 2))

        let coordinator = VideoQualityResumeCoordinator()
        var commands: [Double] = []
        coordinator.start(base, sleep: { _ in }, isCurrent: { false },
                          observedTime: { 0 }, seek: { commands.append($0) })
        await waitUntil { coordinator.pendingRequest == nil }
        XCTAssertTrue(commands.isEmpty)
    }

    private func request(
        target: Double,
        engine: NSObject = NSObject(),
        url: String = "stream-a",
        generation: Int = 1
    ) -> VideoQualityResumeRequest {
        VideoQualityResumeRequest(
            playbackGeneration: generation,
            optionID: "original",
            playbackURL: url,
            targetTime: target,
            engineIdentity: ObjectIdentifier(engine)
        )
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}

private actor VideoQualityResumeGate {
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
