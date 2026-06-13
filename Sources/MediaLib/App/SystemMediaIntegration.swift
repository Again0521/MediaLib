import AppKit
import Foundation
import MediaLibCore
import MediaPlayer

@MainActor
final class SystemMediaCommandCenter {
    static let shared = SystemMediaCommandCenter()

    private var targets: [Any] = []
    private weak var appState: AppState?

    private init() {}

    func configure(appState: AppState) {
        self.appState = appState
        guard targets.isEmpty else { return }

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.preferredIntervals = []
        center.skipBackwardCommand.preferredIntervals = []

        targets.append(center.playCommand.addTarget { [weak self] _ in
            self?.send(.play) ?? .commandFailed
        })
        targets.append(center.pauseCommand.addTarget { [weak self] _ in
            self?.send(.pause) ?? .commandFailed
        })
        targets.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.send(.togglePlay) ?? .commandFailed
        })
        targets.append(center.nextTrackCommand.addTarget { [weak self] _ in
            self?.send(.next) ?? .commandFailed
        })
        targets.append(center.previousTrackCommand.addTarget { [weak self] _ in
            self?.send(.previous) ?? .commandFailed
        })
    }

    private func send(_ command: PlaybackCommand) -> MPRemoteCommandHandlerStatus {
        guard let appState, appState.activePlayerItem != nil else {
            return .noActionableNowPlayingItem
        }
        Task { @MainActor in
            appState.sendPlaybackCommand(command)
        }
        return .success
    }
}

enum SystemNowPlayingCenter {
    /// 已构建好的封面（按封面路径缓存），避免每次刷新都重新读图。
    @MainActor private static var artworkCachePath: String?
    @MainActor private static var artworkCache: MPMediaItemArtwork?
    /// 正在异步加载的封面路径与对应的当前条目（保证只把封面贴回仍在播放的那首歌）。
    @MainActor private static var artworkLoadToken = 0

    @MainActor
    static func update(
        item: MediaItem?,
        currentTime: Double,
        duration: Double,
        playbackRate: Float,
        isPlaying: Bool
    ) {
        guard let item else {
            clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(currentTime, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(playbackRate),
            MPNowPlayingInfoPropertyMediaType: item.type == .music ? MPNowPlayingInfoMediaType.audio.rawValue : MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let artist = item.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = item.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        // 封面：命中缓存的同一封面直接带上，否则先不带、异步读图后再补上，
        // 不阻塞主线程。换歌（封面路径变化）时清掉旧封面缓存。
        let posterPath = item.posterPath
        if posterPath != artworkCachePath {
            artworkCachePath = posterPath
            artworkCache = nil
        }
        if let artwork = artworkCache {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused

        if artworkCache == nil, let posterPath, !posterPath.isEmpty {
            loadArtwork(path: posterPath, title: item.title)
        }
    }

    @MainActor
    private static func loadArtwork(path: String, title: String) {
        artworkLoadToken &+= 1
        let token = artworkLoadToken
        Task { @MainActor in
            // 读图放到后台，避免主线程卡顿。
            let image = await Task.detached(priority: .utility) {
                ArtworkImageCache.image(path: path, targetSize: CGSize(width: 600, height: 600))
            }.value
            // 期间若已换歌/换封面，丢弃这次结果。
            guard token == artworkLoadToken, path == artworkCachePath, let image else { return }
            // requestHandler 可能在任意线程被调用；直接返回已读好的图，
            // 不在回调里做 NSImage lockFocus（离开主线程绘制不稳定）。
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            artworkCache = artwork
            // 只把封面补进当前正在显示的信息里（标题一致才算同一首）。
            let center = MPNowPlayingInfoCenter.default()
            guard var info = center.nowPlayingInfo,
                  (info[MPMediaItemPropertyTitle] as? String) == title else { return }
            info[MPMediaItemPropertyArtwork] = artwork
            center.nowPlayingInfo = info
        }
    }

    @MainActor
    static func clear() {
        artworkCachePath = nil
        artworkCache = nil
        artworkLoadToken &+= 1
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
