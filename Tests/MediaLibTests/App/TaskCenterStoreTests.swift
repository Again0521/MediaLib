import XCTest
@testable import MediaLib

@MainActor
final class TaskCenterStoreTests: XCTestCase {
    func testReplaceTasksPublishesStateAndInvokesChangeHook() {
        let store = TaskCenterStore()
        let task = makeTask(title: "扫描任务")
        var persistedSnapshots: [[BackgroundTaskSnapshot]] = []
        store.onTasksChanged = { persistedSnapshots.append($0) }

        store.replaceTasks([task])

        XCTAssertEqual(store.tasks.map(\.id), [task.id])
        XCTAssertEqual(persistedSnapshots.count, 1)
        XCTAssertEqual(persistedSnapshots.first?.map(\.id), [task.id])
    }

    func testMutateTasksKeepsMutationInsideStoreBoundary() {
        let store = TaskCenterStore()
        let task = makeTask(title: "封面预热")
        store.replaceTasks([task])

        store.mutateTasks { tasks in
            tasks[0].state = .completed
            tasks[0].progress = 1
        }

        XCTAssertEqual(store.tasks.first?.state, .completed)
        XCTAssertEqual(store.tasks.first?.progress, 1)
    }

    private func makeTask(title: String) -> BackgroundTaskSnapshot {
        BackgroundTaskSnapshot(
            kind: .fullScan,
            state: .running,
            title: title,
            detail: nil,
            progress: 0,
            startedAt: Date(timeIntervalSince1970: 1_000),
            isCancellable: true
        )
    }
}
