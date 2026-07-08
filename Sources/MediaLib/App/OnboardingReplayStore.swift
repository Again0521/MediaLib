import Combine
import Foundation

/// 设置页触发重新查看引导的瞬时请求状态容器。
///
/// 只保存“是否请求重新展示引导”；引导页内容、完成/跳过、启动后任务和视图展示仍由
/// 视图层与 AppState 原有流程编排。
@MainActor
final class OnboardingReplayStore: ObservableObject {
    @Published private(set) var isReplayRequested = false

    func setReplayRequested(_ requested: Bool) {
        isReplayRequested = requested
    }

    func requestReplay() {
        isReplayRequested = true
    }

    func clearReplayRequest() {
        isReplayRequested = false
    }
}
