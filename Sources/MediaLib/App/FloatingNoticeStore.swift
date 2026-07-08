import Combine
import Foundation

/// 当前正在展示的浮窗通知状态容器。
///
/// 只保存可见通知数组；通知队列、前台兜底、系统通知投递和自动 dismiss 任务仍由 AppState 编排。
@MainActor
final class FloatingNoticeStore: ObservableObject {
    @Published private(set) var notices: [AppFloatingNotice] = []

    var isEmpty: Bool {
        notices.isEmpty
    }

    func replaceVisibleNotices(with notices: [AppFloatingNotice]) {
        self.notices = notices
    }

    func present(_ notice: AppFloatingNotice) {
        notices = [notice]
    }

    func remove(id: UUID) {
        notices.removeAll { $0.id == id }
    }

    func clear() {
        notices.removeAll()
    }
}
