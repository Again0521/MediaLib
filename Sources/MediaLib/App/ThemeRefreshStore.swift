import Combine
import Foundation

/// 主题刷新计数器状态容器。
///
/// 只保存配色主题与音乐主题参数的 revision；配色应用、窗口重绘、过场动画、
/// 音乐主题配置文件读写和视图 `.id` 重建仍由 AppState 与界面层原有流程编排。
@MainActor
final class ThemeRefreshStore: ObservableObject {
    @Published private(set) var themeRevision = 0
    @Published private(set) var musicThemeRevision = 0

    func setThemeRevision(_ revision: Int) {
        themeRevision = revision
    }

    func setMusicThemeRevision(_ revision: Int) {
        musicThemeRevision = revision
    }

    func bumpThemeRevision() {
        themeRevision &+= 1
    }

    func bumpMusicThemeRevision() {
        musicThemeRevision &+= 1
    }
}
