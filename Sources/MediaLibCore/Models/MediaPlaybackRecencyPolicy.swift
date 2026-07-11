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
    public static func recentNonMusicItems(_ items: [MediaItem], limit: Int) -> [MediaItem] {
        Array(items
            .filter { $0.type != .music && ($0.hasPlaybackTrace || $0.lastPlayedAt != nil) }
            .sorted(by: isMoreRecent)
            .prefix(max(limit, 0)))
    }
}
