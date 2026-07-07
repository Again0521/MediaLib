import AVFoundation
import Foundation

@MainActor
protocol MusicPlayerTransport: AnyObject {
    var currentItem: AVPlayerItem? { get }
    var rate: Float { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }

    func currentTime() -> CMTime
    func pause()
    func playImmediately(atRate rate: Float)
    func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    )
}

@MainActor
final class AVQueueMusicPlayerTransport: MusicPlayerTransport {
    private let player: AVQueuePlayer

    init(player: AVQueuePlayer) {
        self.player = player
    }

    var currentItem: AVPlayerItem? {
        player.currentItem
    }

    var rate: Float {
        player.rate
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    func currentTime() -> CMTime {
        player.currentTime()
    }

    func pause() {
        player.pause()
    }

    func playImmediately(atRate rate: Float) {
        player.playImmediately(atRate: rate)
    }

    func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        player.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter,
            completionHandler: completionHandler
        )
    }
}

@MainActor
protocol MusicPlaybackEngine: AnyObject {
    var hasCurrentItem: Bool { get }
    var isPlaying: Bool { get }
    var currentTimeSeconds: Double? { get }

    func pause()
    func playImmediately(atRate rate: Float)
    func seek(to seconds: Double, completion: @escaping @Sendable (Bool) -> Void)
    func seekToStart(completion: @escaping @Sendable (Bool) -> Void)
    func setVolume(_ volume: Float)
    func setMuted(_ muted: Bool)
}

@MainActor
final class AVQueueMusicPlaybackEngine: MusicPlaybackEngine {
    private let transport: MusicPlayerTransport

    init(transport: MusicPlayerTransport) {
        self.transport = transport
    }

    var hasCurrentItem: Bool {
        transport.currentItem != nil
    }

    var isPlaying: Bool {
        transport.rate > 0
    }

    var currentTimeSeconds: Double? {
        let seconds = transport.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    func pause() {
        transport.pause()
    }

    func playImmediately(atRate rate: Float) {
        transport.playImmediately(atRate: rate)
    }

    func seek(to seconds: Double, completion: @escaping @Sendable (Bool) -> Void) {
        transport.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: completion
        )
    }

    func seekToStart(completion: @escaping @Sendable (Bool) -> Void) {
        transport.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: completion
        )
    }

    func setVolume(_ volume: Float) {
        transport.volume = min(max(volume, 0), 1)
    }

    func setMuted(_ muted: Bool) {
        transport.isMuted = muted
    }
}
