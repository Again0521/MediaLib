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
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

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
        targets.append(center.skipForwardCommand.addTarget { [weak self] _ in
            self?.send(.seekForward) ?? .commandFailed
        })
        targets.append(center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.send(.seekBackward) ?? .commandFailed
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

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    @MainActor
    static func clear() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
