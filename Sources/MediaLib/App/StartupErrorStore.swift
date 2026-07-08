import Combine
import Foundation

/// 启动失败展示状态容器。
///
/// 只保存启动初始化失败后的错误文案；目录、数据库和 repository 初始化仍由 AppState.init
/// 编排，避免把启动流程塞进展示状态 Store。
@MainActor
final class StartupErrorStore: ObservableObject {
    @Published private(set) var message: String?

    func setMessage(_ message: String?) {
        self.message = message
    }

    func clear() {
        message = nil
    }
}
