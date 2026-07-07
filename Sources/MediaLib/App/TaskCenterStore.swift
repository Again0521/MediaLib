import Combine
import Foundation

/// 后台任务中心的状态容器。
///
/// AppState 仍保留 `backgroundTasks` facade 供旧视图过渡使用；新页面应优先观察本 Store，
/// 避免任务进度刷新继续扩大成整个 AppState 的无关刷新。
@MainActor
final class TaskCenterStore: ObservableObject {
    @Published private(set) var tasks: [BackgroundTaskSnapshot] = []

    var onTasksChanged: (([BackgroundTaskSnapshot]) -> Void)?

    func replaceTasks(_ tasks: [BackgroundTaskSnapshot]) {
        self.tasks = tasks
        onTasksChanged?(tasks)
    }

    func mutateTasks(_ mutation: (inout [BackgroundTaskSnapshot]) -> Void) {
        var next = tasks
        mutation(&next)
        replaceTasks(next)
    }
}
