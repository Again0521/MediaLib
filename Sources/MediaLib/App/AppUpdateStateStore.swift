import Combine
import Foundation

/// 应用更新提示状态容器。
///
/// 只拥有更新检查中的 UI 状态和当前可用版本提示；GitHub 请求、版本比较、
/// 偏好节流、任务生命周期和赞赏邀请仍留在 AppState+Updates 的编排层。
@MainActor
final class AppUpdateStateStore: ObservableObject {
    @Published private(set) var availableUpdate: AppUpdateInfo?
    @Published private(set) var isCheckingForUpdates = false

    func setAvailableUpdate(_ update: AppUpdateInfo?) {
        availableUpdate = update
    }

    func setCheckingForUpdates(_ checking: Bool) {
        isCheckingForUpdates = checking
    }

    func clearAvailableUpdate() {
        availableUpdate = nil
    }
}
