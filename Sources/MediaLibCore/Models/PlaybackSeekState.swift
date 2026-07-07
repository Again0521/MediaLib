import Foundation

public struct PlaybackSeekState: Equatable {
    public enum Phase: Equatable {
        case scrubbing
        case seeking
        case settled
    }

    public let revision: Int
    public let phase: Phase
    public let targetTime: Double
    public let originTime: Double
    public let resolvedTime: Double?

    public init(
        revision: Int,
        phase: Phase,
        targetTime: Double,
        originTime: Double,
        resolvedTime: Double?
    ) {
        self.revision = revision
        self.phase = phase
        self.targetTime = targetTime
        self.originTime = originTime
        self.resolvedTime = resolvedTime
    }

    public var presentationTime: Double {
        resolvedTime ?? targetTime
    }

    public var isUserPreview: Bool {
        phase == .scrubbing
    }

    public var isAwaitingPlaybackClock: Bool {
        phase == .seeking
    }

    public static func nextRevision(after state: PlaybackSeekState?) -> Int {
        (state?.revision ?? 0) &+ 1
    }

    public static func scrubbing(revision: Int, targetTime: Double, originTime: Double) -> PlaybackSeekState {
        PlaybackSeekState(
            revision: revision,
            phase: .scrubbing,
            targetTime: targetTime,
            originTime: originTime,
            resolvedTime: nil
        )
    }

    public static func seeking(revision: Int, targetTime: Double, originTime: Double) -> PlaybackSeekState {
        PlaybackSeekState(
            revision: revision,
            phase: .seeking,
            targetTime: targetTime,
            originTime: originTime,
            resolvedTime: nil
        )
    }

    public static func settled(
        revision: Int,
        targetTime: Double,
        originTime: Double,
        resolvedTime: Double
    ) -> PlaybackSeekState {
        PlaybackSeekState(
            revision: revision,
            phase: .settled,
            targetTime: targetTime,
            originTime: originTime,
            resolvedTime: resolvedTime
        )
    }
}
