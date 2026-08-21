import Foundation

/// 智能歌单的求值规则：筛选 → 排序 → 截断。
///
/// 从前它只存在于客户端的 `AppState+MusicPlaylist`，服务端因此完全给不出智能歌单。
/// 规则本身不依赖任何客户端状态——输入是一组曲目，输出是同一组曲目的子集——所以它
/// 属于 `MediaLibCore`，两端各自把自己那份候选集喂进来。
///
/// 谁的候选集，就决定了谁的"收藏""播放过"。服务端必须传入**请求者**有权看到、且
/// 带着请求者播放状态的曲目：直接拿桌面机主的库来求值，会把机主的收藏和播放历史
/// 通过歌单内容泄露给每一个登录用户。
public enum MusicSmartPlaylistPolicy {
    public static func tracks(
        in playlist: MusicSmartPlaylist,
        from candidates: [MediaItem],
        now: Date = Date()
    ) -> [MediaItem] {
        var tracks = candidates

        switch playlist.filter {
        case .any:
            break
        case .favorites:
            tracks = tracks.filter(\.favorite)
        case .recentlyPlayed:
            tracks = tracks.filter { $0.lastPlayedAt != nil }
        case .neverPlayed:
            tracks = tracks.filter { ($0.playCount ?? 0) == 0 }
        }

        if playlist.recency != .anytime {
            let cutoff = now.addingTimeInterval(-Double(playlist.recency.rawValue) * 86_400)
            tracks = tracks.filter { $0.createdAt >= cutoff }
        }

        switch playlist.sort {
        case .dateAddedDesc:
            tracks.sort { $0.createdAt > $1.createdAt }
        case .playCountDesc:
            tracks.sort { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .lastPlayedDesc:
            tracks.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .titleAsc:
            tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artistAsc:
            tracks.sort { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .yearDesc:
            tracks.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        }

        if playlist.limit != .unlimited {
            tracks = Array(tracks.prefix(playlist.limit.rawValue))
        }
        return tracks
    }
}
