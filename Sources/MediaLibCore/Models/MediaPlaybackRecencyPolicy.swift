import Foundation

public enum MediaPlaybackRecencyPolicy {
    public static func isMoreRecent(_ lhs: MediaItem, than rhs: MediaItem) -> Bool {
        playbackRecencyDate(for: lhs) > playbackRecencyDate(for: rhs)
    }

    public static func sortedByMostRecentPlaybackTrace(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted(by: isMoreRecent)
    }

    public static func playbackRecencyDate(for item: MediaItem) -> Date {
        item.lastPlayedAt ?? item.updatedAt
    }

    /// 首页的“最近播放”只承载影视、照片等非音乐内容；音乐播放记录应统一由
    /// “继续听”承接，避免首页出现两套相互重叠的音乐历史。
    ///
    /// 这条规则要在两个地方各判一次：客户端手里是 `MediaItem`，服务端手里是它
    /// 自己的卡片模型，而 `MediaLibCore` 与 `MediaLibServerProtocol` 是互不依赖
    /// 的两个 target，谁也看不见谁的类型。能共享的只有规则本身，所以规则挂在下
    /// 面这个最小协议上，两端各自认领——网页端从前是在页面里另写了一遍筛选，写
    /// 漏了类型判断，于是音乐和照片就混进了影视海报墙里。
    public static func recentNonMusicItems<Item: PlaybackRecencyRepresentable>(
        _ items: [Item],
        limit: Int
    ) -> [Item] {
        Array(items
            .filter { !$0.isMusicMedia && $0.hasRecencyTrace }
            .sorted { $0.recencyDate > $1.recencyDate }
            .prefix(max(limit, 0)))
    }
}

/// 参与“最近播放”排序所需要知道的全部信息。
public protocol PlaybackRecencyRepresentable {
    /// 音乐由“继续听”承接，不进最近播放。
    var isMusicMedia: Bool { get }
    /// 是否真的被播放过。没有任何播放痕迹的条目不该出现在一份播放历史里。
    var hasRecencyTrace: Bool { get }
    var recencyDate: Date { get }
}

extension MediaItem: PlaybackRecencyRepresentable {
    public var isMusicMedia: Bool { type == .music }
    public var hasRecencyTrace: Bool { hasPlaybackTrace || lastPlayedAt != nil }
    public var recencyDate: Date { MediaPlaybackRecencyPolicy.playbackRecencyDate(for: self) }
}
