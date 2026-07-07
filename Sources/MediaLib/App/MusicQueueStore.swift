import Combine
import Foundation
import MediaLibCore

/// 音乐播放队列状态容器。
///
/// 只拥有队列本身和播放顺序开关；队列持久化、随机导航策略、实际播放命令仍由
/// AppState 过渡层编排，避免这个 Store 变成新的播放器 god object。
@MainActor
final class MusicQueueStore: ObservableObject {
    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var repeatMode: MusicRepeatMode = .sequential
    @Published private(set) var shuffleEnabled = false

    /// 队列弹层的进程内滚动锚点。它是临时 UI 位置，不参与 @Published 刷新和持久化。
    var scrollAnchorID: String?

    func replaceQueue(_ queue: [MediaItem]) {
        self.queue = queue
    }

    func setRepeatMode(_ repeatMode: MusicRepeatMode) {
        self.repeatMode = repeatMode
    }

    func setShuffleEnabled(_ shuffleEnabled: Bool) {
        self.shuffleEnabled = shuffleEnabled
    }
}
