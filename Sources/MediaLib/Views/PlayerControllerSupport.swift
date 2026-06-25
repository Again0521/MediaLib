import Combine
import Foundation

// 从 PlayerView.swift 物理拆出（零行为变化）：视频播放器控制层的三个 @MainActor 非视觉辅助对象。
// 均保留原 @MainActor 隔离与逻辑，仅相对源文件改为模块内部可见。MpvPlayerController 同属 MediaLib 模块。

/// 播放期间阻止系统/显示休眠；暂停或结束时释放 activity。
@MainActor
final class VideoPlaybackSleepGuard: ObservableObject {
    private var activity: NSObjectProtocol?

    func update(isPlaying: Bool) {
        if isPlaying {
            begin()
        } else {
            end()
        }
    }

    func end() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    private func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "MediaLIB 正在播放视频"
        )
    }
}

/// 控制栏自动隐藏的去抖调度器：可选节流间隔内合并多次 schedule，取消上一个隐藏任务。
@MainActor
final class PlayerControlsAutoHideCoordinator: ObservableObject {
    private var hideTask: Task<Void, Never>?
    private var lastScheduleTime = Date.distantPast

    func schedule(throttleInterval: TimeInterval = 0, _ action: @escaping @MainActor () async -> Void) {
        let now = Date()
        if hideTask != nil, throttleInterval > 0, now.timeIntervalSince(lastScheduleTime) < throttleInterval {
            return
        }
        lastScheduleTime = now
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            await action()
        }
    }

    func cancel() {
        hideTask?.cancel()
        hideTask = nil
        lastScheduleTime = .distantPast
    }
}

/// 把 MpvPlayerController 的某个派生值投影成去重后的 @Published，合并 objectWillChange 风暴为单次刷新。
/// 高频刷新隔离的通用机制（视频侧大量使用），只搬位置不改去重/合批语义。
@MainActor
final class PlayerControllerProjection<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value
    private weak var controller: MpvPlayerController?
    private let map: @MainActor (MpvPlayerController) -> Value
    private var cancellable: AnyCancellable?
    private var refreshScheduled = false

    init(controller: MpvPlayerController, map: @escaping @MainActor (MpvPlayerController) -> Value) {
        self.controller = controller
        self.map = map
        self.value = map(controller)
        self.cancellable = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let controller else { return }
        let nextValue = map(controller)
        guard nextValue != value else { return }
        value = nextValue
    }
}
