import Combine
import Foundation

/// Last.fm 授权/连接流程的进行中状态容器。
///
/// 只保存“是否正在授权/换取 session”的并发闸门和按钮禁用态；凭据读取、token、
/// 浏览器打开、session 保存、错误提示和 scrobble 流程仍由 AppState+Lastfm 编排。
@MainActor
final class LastfmAuthorizationStateStore: ObservableObject {
    @Published private(set) var isAuthorizing = false

    func setAuthorizing(_ authorizing: Bool) {
        isAuthorizing = authorizing
    }

    func begin() {
        isAuthorizing = true
    }

    func finish() {
        isAuthorizing = false
    }
}
