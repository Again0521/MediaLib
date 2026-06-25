import Foundation

// 从 MusicPlayerView.swift 物理拆出（零行为变化）：播放队列拖拽重排的节流协调器（≥0.115s 且目标变化才允许移动）。
// 纯逻辑、无视觉、无外部类型依赖。原为 private（紧邻 @MainActor），拆出后改为模块内部可见并保留 @MainActor。
@MainActor
final class MusicQueueDragCoordinator: ObservableObject {
    private var lastMoveDate = Date.distantPast
    private var lastTargetID: String?

    func shouldMove(to targetID: String) -> Bool {
        let now = Date()
        defer {
            lastMoveDate = now
            lastTargetID = targetID
        }
        if lastTargetID == targetID {
            return false
        }
        return now.timeIntervalSince(lastMoveDate) >= 0.115
    }

    func reset() {
        lastMoveDate = .distantPast
        lastTargetID = nil
    }
}
