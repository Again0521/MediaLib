import Combine
import Foundation

/// 「打开网络串流」sheet 的展示状态容器。
///
/// 只拥有输入弹窗是否展示；URL 校验、错误 alert、临时媒体条目构造和实际播放仍留在
/// AppState+ExternalPlayback，避免把播放入口逻辑合并进 transient presentation Store。
@MainActor
final class NetworkStreamPromptStore: ObservableObject {
    @Published private(set) var isShowingPrompt = false

    func setShowingPrompt(_ showing: Bool) {
        isShowingPrompt = showing
    }

    func presentPrompt() {
        isShowingPrompt = true
    }

    func dismissPrompt() {
        isShowingPrompt = false
    }
}
