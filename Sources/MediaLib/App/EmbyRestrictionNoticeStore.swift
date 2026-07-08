import Combine
import Foundation

/// 受限远程媒体服务器专用 sheet 的 notice 状态容器。
///
/// 只拥有当前提示 payload；受限错误识别、日志、连接状态、账号回滚和同步流程仍留在
/// 原有远程连接路径，避免把远程服务业务塞进 presentation Store。
@MainActor
final class EmbyRestrictionNoticeStore: ObservableObject {
    @Published private(set) var notice: EmbyRestrictionNotice?

    func setNotice(_ notice: EmbyRestrictionNotice?) {
        self.notice = notice
    }

    func presentNotice(serverHost: String, reason: String?, identity: EmbyClientIdentity) {
        notice = EmbyRestrictionNotice(
            serverHost: serverHost,
            reason: reason,
            identity: identity
        )
    }

    func clear() {
        notice = nil
    }
}
