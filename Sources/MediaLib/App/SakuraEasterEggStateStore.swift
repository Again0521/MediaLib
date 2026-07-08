import Combine
import Foundation

/// 樱花彩蛋的本次启动内展示状态容器。
///
/// 只保存彩蛋是否正在展示、以及本次启动是否已经展示过；歌曲匹配、播放触发、
/// 动画视图和延迟关闭任务仍由 AppState / View 层原有位置编排。
@MainActor
final class SakuraEasterEggStateStore: ObservableObject {
    @Published private(set) var isActive = false
    private(set) var shownThisLaunch = false

    func setActive(_ active: Bool) {
        isActive = active
    }

    func setShownThisLaunch(_ shown: Bool) {
        shownThisLaunch = shown
    }
}
