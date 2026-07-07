import Foundation

enum BackgroundTaskListPolicy {
    static let activeListLimit = 40
    static let restoreLimit = 60
    static let inactiveHistoryLimit = 24

    struct RestoreResult {
        var tasks: [BackgroundTaskSnapshot]
        var resumableArtworkWarmupTasks: [BackgroundTaskSnapshot]
    }

    struct TrimResult {
        var tasks: [BackgroundTaskSnapshot]
        var removedCount: Int
    }

    struct CancellationResult {
        var tasks: [BackgroundTaskSnapshot]
        var changed: Bool
    }

    static func inserting(
        _ task: BackgroundTaskSnapshot,
        into tasks: [BackgroundTaskSnapshot],
        limit: Int = activeListLimit
    ) -> [BackgroundTaskSnapshot] {
        var next = tasks
        next.insert(task, at: 0)
        if next.count > limit {
            next.removeLast(next.count - limit)
        }
        return next
    }

    static func restoredTasks(
        from decoded: [BackgroundTaskSnapshot],
        now: Date = Date(),
        limit: Int = restoreLimit
    ) -> RestoreResult {
        var resumableArtworkWarmupTasks: [BackgroundTaskSnapshot] = []
        let restoredTasks = decoded.prefix(limit).map { task in
            var restored = task
            if restored.hidesDetail {
                restored.title = restored.kind.title
                restored.detail = nil
            }
            guard task.state.isActive else { return restored }
            if task.kind == .artworkWarmup, task.retrySourceID != nil {
                restored.state = .running
                restored.finishedAt = nil
                restored.isCancellable = false
                if !restored.hidesDetail {
                    restored.detail = "继续封面预热…"
                }
                resumableArtworkWarmupTasks.append(restored)
                return restored
            }
            restored.state = .failed
            restored.finishedAt = restored.finishedAt ?? now
            restored.isCancellable = false
            if !restored.hidesDetail {
                restored.detail = "上次退出时任务尚未完成。"
            }
            return restored
        }
        return RestoreResult(
            tasks: restoredTasks,
            resumableArtworkWarmupTasks: resumableArtworkWarmupTasks
        )
    }

    static func trimmingInactiveHistory(
        from tasks: [BackgroundTaskSnapshot],
        existingInactiveCount: Int,
        inactiveLimit: Int = inactiveHistoryLimit
    ) -> TrimResult {
        let activeTasks = tasks.filter(\.state.isActive)
        let inactiveTasks = tasks
            .filter { !$0.state.isActive }
            .sorted { lhs, rhs in
                (lhs.finishedAt ?? lhs.startedAt) > (rhs.finishedAt ?? rhs.startedAt)
            }
        let keptInactive = Array(inactiveTasks.prefix(inactiveLimit))
        let nextTasks = (activeTasks + keptInactive).sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }
        return TrimResult(
            tasks: nextTasks,
            removedCount: max(existingInactiveCount - keptInactive.count, 0)
        )
    }

    static func cancellingActiveScanTasks(
        in tasks: [BackgroundTaskSnapshot],
        now: Date = Date()
    ) -> CancellationResult {
        cancellingActiveCancellableTasks(in: tasks, now: now) { task in
            task.kind == .fullScan || task.kind == .incrementalScan
        }
    }

    static func cancellingAllActiveCancellableTasks(
        in tasks: [BackgroundTaskSnapshot],
        now: Date = Date()
    ) -> CancellationResult {
        cancellingActiveCancellableTasks(in: tasks, now: now) { _ in true }
    }

    private static func cancellingActiveCancellableTasks(
        in tasks: [BackgroundTaskSnapshot],
        now: Date,
        where shouldCancel: (BackgroundTaskSnapshot) -> Bool
    ) -> CancellationResult {
        var changed = false
        let nextTasks = tasks.map { task in
            guard task.state.isActive, task.isCancellable, shouldCancel(task) else {
                return task
            }
            changed = true
            var cancelled = task
            cancelled.state = .cancelled
            cancelled.finishedAt = now
            cancelled.isCancellable = false
            return cancelled
        }
        return CancellationResult(tasks: nextTasks, changed: changed)
    }
}
