import Combine
import Foundation
import MediaLibCore

/// 当前播放会话的轻量状态容器。
///
/// 只拥有当前播放条目、视频播放队列和一次性播放命令请求；播放器窗口创建、mpv/AVPlayer
/// 控制、系统媒体中心上报和远程同步仍留在 AppState / 播放控制层继续拆分，避免形成新的
/// playback god object。
@MainActor
final class PlaybackSessionStore: ObservableObject {
    @Published private(set) var activePlayerItem: MediaItem?
    @Published private(set) var videoQueue: [MediaItem] = []
    @Published private(set) var playbackCommandRequest: PlaybackCommandRequest?

    func setActivePlayerItem(_ item: MediaItem?) {
        activePlayerItem = item
    }

    func replaceVideoQueue(_ queue: [MediaItem]) {
        videoQueue = queue
    }

    func setPlaybackCommandRequest(_ request: PlaybackCommandRequest?) {
        playbackCommandRequest = request
    }

    func requestCommand(_ command: PlaybackCommand) {
        playbackCommandRequest = PlaybackCommandRequest(command: command)
    }
}
