import XCTest
@testable import MediaLib

final class BackgroundTaskListPolicyTests: XCTestCase {
    func testInsertingTaskPrependsAndTrimsToActiveListLimit() {
        let existing = (0..<45).map { index in
            makeTask(title: "task-\(index)", startedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let newest = makeTask(title: "newest", startedAt: Date(timeIntervalSince1970: 100))

        let result = BackgroundTaskListPolicy.inserting(newest, into: existing)

        XCTAssertEqual(result.count, 40)
        XCTAssertEqual(result.first?.id, newest.id)
        XCTAssertEqual(result.dropFirst().map(\.title), (0..<39).map { "task-\($0)" })
        XCTAssertFalse(result.contains { $0.title == "task-39" })
        XCTAssertFalse(result.contains { $0.title == "task-44" })
    }

    func testRestoredTasksSanitizesActiveTasksAndCollectsResumableArtworkWarmup() {
        let now = Date(timeIntervalSince1970: 2_000)
        let hiddenRunning = makeTask(
            kind: .fullScan,
            state: .running,
            title: "Full Scan · Secret Source",
            detail: "secret path",
            hidesDetail: true
        )
        let activeScan = makeTask(kind: .incrementalScan, state: .running, title: "Incremental", detail: "old detail")
        let artworkWarmup = makeTask(
            kind: .artworkWarmup,
            state: .queued,
            title: "Artwork",
            detail: "old warmup",
            retrySourceID: "source-a"
        )
        let finished = makeTask(kind: .cleanup, state: .completed, title: "Cleanup", detail: "done")
        let overflow = (0..<60).map { makeTask(title: "overflow-\($0)") }

        let result = BackgroundTaskListPolicy.restoredTasks(
            from: [hiddenRunning, activeScan, artworkWarmup, finished] + overflow,
            now: now
        )

        XCTAssertEqual(result.tasks.count, 60)
        XCTAssertFalse(result.tasks.contains { $0.title == "overflow-56" })

        let restoredHidden = result.tasks[0]
        XCTAssertEqual(restoredHidden.kind, .fullScan)
        XCTAssertEqual(restoredHidden.title, BackgroundTaskKind.fullScan.title)
        XCTAssertNil(restoredHidden.detail)
        XCTAssertEqual(restoredHidden.state, .failed)
        XCTAssertEqual(restoredHidden.finishedAt, now)
        XCTAssertFalse(restoredHidden.isCancellable)

        let restoredScan = result.tasks[1]
        XCTAssertEqual(restoredScan.state, .failed)
        XCTAssertEqual(restoredScan.detail, "上次退出时任务尚未完成。")
        XCTAssertEqual(restoredScan.finishedAt, now)
        XCTAssertFalse(restoredScan.isCancellable)

        let restoredArtwork = result.tasks[2]
        XCTAssertEqual(restoredArtwork.state, .running)
        XCTAssertNil(restoredArtwork.finishedAt)
        XCTAssertFalse(restoredArtwork.isCancellable)
        XCTAssertEqual(restoredArtwork.detail, "继续封面预热…")
        XCTAssertEqual(result.resumableArtworkWarmupTasks.map(\.id), [artworkWarmup.id])

        XCTAssertEqual(result.tasks[3].state, .completed)
        XCTAssertEqual(result.tasks[3].detail, "done")
    }

    func testTrimmingInactiveHistoryKeepsActiveTasksAndMostRecentInactiveTasks() {
        let active = [
            makeTask(state: .running, title: "active-new", startedAt: Date(timeIntervalSince1970: 2_000)),
            makeTask(state: .paused, title: "active-old", startedAt: Date(timeIntervalSince1970: 1))
        ]
        let inactive = (0..<30).map { index in
            makeTask(
                state: .completed,
                title: "inactive-\(index)",
                startedAt: Date(timeIntervalSince1970: Double(1_000 - index)),
                finishedAt: Date(timeIntervalSince1970: Double(1_000 - index))
            )
        }

        let result = BackgroundTaskListPolicy.trimmingInactiveHistory(
            from: Array(inactive.reversed()) + active,
            existingInactiveCount: inactive.count
        )

        XCTAssertEqual(result.removedCount, 6)
        XCTAssertEqual(result.tasks.count, 26)
        XCTAssertTrue(result.tasks.contains { $0.title == "active-new" })
        XCTAssertTrue(result.tasks.contains { $0.title == "active-old" })
        XCTAssertTrue(result.tasks.contains { $0.title == "inactive-0" })
        XCTAssertTrue(result.tasks.contains { $0.title == "inactive-23" })
        XCTAssertFalse(result.tasks.contains { $0.title == "inactive-24" })
        XCTAssertFalse(result.tasks.contains { $0.title == "inactive-29" })
        XCTAssertEqual(result.tasks.first?.title, "active-new")
    }

    func testCancellingActiveScanTasksOnlyCancelsCancellableScans() {
        let now = Date(timeIntervalSince1970: 3_000)
        let fullScan = makeTask(kind: .fullScan, state: .running, title: "full")
        let incrementalScan = makeTask(kind: .incrementalScan, state: .paused, title: "incremental")
        let videoCache = makeTask(kind: .videoCache, state: .running, title: "cache")
        let completedScan = makeTask(kind: .fullScan, state: .completed, title: "completed")
        let lockedScan = makeTask(kind: .fullScan, state: .running, title: "locked", isCancellable: false)

        let result = BackgroundTaskListPolicy.cancellingActiveScanTasks(
            in: [fullScan, incrementalScan, videoCache, completedScan, lockedScan],
            now: now
        )

        XCTAssertTrue(result.changed)
        XCTAssertCancelled(result.tasks[0], now: now)
        XCTAssertCancelled(result.tasks[1], now: now)
        XCTAssertEqual(result.tasks[2].state, .running)
        XCTAssertNil(result.tasks[2].finishedAt)
        XCTAssertEqual(result.tasks[3].state, .completed)
        XCTAssertEqual(result.tasks[4].state, .running)
        XCTAssertFalse(result.tasks[4].isCancellable)

        let unchanged = BackgroundTaskListPolicy.cancellingActiveScanTasks(
            in: [videoCache, completedScan, lockedScan],
            now: now
        )
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(unchanged.tasks.count, 3)
    }

    func testCancellingAllActiveCancellableTasksLeavesCompletedAndLockedTasksUntouched() {
        let now = Date(timeIntervalSince1970: 4_000)
        let scan = makeTask(kind: .fullScan, state: .running, title: "scan")
        let cache = makeTask(kind: .videoCache, state: .pausing, title: "cache")
        let completed = makeTask(kind: .cleanup, state: .completed, title: "done")
        let locked = makeTask(kind: .markerAnalysis, state: .running, title: "locked", isCancellable: false)

        let result = BackgroundTaskListPolicy.cancellingAllActiveCancellableTasks(
            in: [scan, cache, completed, locked],
            now: now
        )

        XCTAssertTrue(result.changed)
        XCTAssertCancelled(result.tasks[0], now: now)
        XCTAssertCancelled(result.tasks[1], now: now)
        XCTAssertEqual(result.tasks[2].state, .completed)
        XCTAssertEqual(result.tasks[3].state, .running)
        XCTAssertFalse(result.tasks[3].isCancellable)

        let unchanged = BackgroundTaskListPolicy.cancellingAllActiveCancellableTasks(
            in: [completed, locked],
            now: now
        )
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(unchanged.tasks.count, 2)
    }

    private func makeTask(
        kind: BackgroundTaskKind = .cleanup,
        state: BackgroundTaskState = .running,
        title: String,
        detail: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 100),
        finishedAt: Date? = nil,
        isCancellable: Bool = true,
        hidesDetail: Bool = false,
        retrySourceID: String? = nil
    ) -> BackgroundTaskSnapshot {
        BackgroundTaskSnapshot(
            kind: kind,
            state: state,
            title: title,
            detail: detail,
            startedAt: startedAt,
            finishedAt: finishedAt,
            isCancellable: isCancellable,
            hidesDetail: hidesDetail,
            retrySourceID: retrySourceID
        )
    }

    private func XCTAssertCancelled(
        _ task: BackgroundTaskSnapshot,
        now: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(task.state, .cancelled, file: file, line: line)
        XCTAssertEqual(task.finishedAt, now, file: file, line: line)
        XCTAssertFalse(task.isCancellable, file: file, line: line)
    }
}
