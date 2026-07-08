import Combine
import Foundation

/// 赞赏邀请 sheet 的展示状态容器。
///
/// 只拥有是否展示邀请弹层；启动次数、只弹一次的偏好判断和具体 sheet 呈现仍留在
/// AppState+Updates / Views，避免把所有 app-level 弹层合并成宽泛 presentation Store。
@MainActor
final class SponsorPromptStore: ObservableObject {
    @Published private(set) var isShowingInvite = false

    func setShowingInvite(_ showing: Bool) {
        isShowingInvite = showing
    }

    func presentInvite() {
        isShowingInvite = true
    }

    func dismissInvite() {
        isShowingInvite = false
    }
}
