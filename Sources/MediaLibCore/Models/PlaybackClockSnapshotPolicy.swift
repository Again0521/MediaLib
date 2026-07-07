import Foundation

public struct PlaybackClockSnapshot: Equatable {
    public let clockUpdate: PlaybackClockUpdate
    public let pendingSeek: PendingPlaybackSeek?
    public let settledSeekState: PlaybackSeekState?
}

public enum PlaybackClockSnapshotDecision: Equatable {
    case hold
    case apply(PlaybackClockSnapshot)
}

public enum PlaybackClockSnapshotPolicy {
    public static func decision(
        observedTime: Double,
        currentTime: Double,
        lyricTime: Double,
        currentTolerance: Double,
        lyricTolerance: Double,
        force: Bool = false,
        pendingSeek: PendingPlaybackSeek?,
        generation: Int,
        now: Date,
        mediaKind: PlaybackTimelineMediaKind
    ) -> PlaybackClockSnapshotDecision? {
        guard observedTime.isFinite, observedTime >= 0 else { return nil }

        let pendingBeforeClockUpdate = pendingSeek
        var pendingAfterClockUpdate = pendingSeek

        if force {
            pendingAfterClockUpdate = nil
        } else if let pending = pendingSeek {
            guard pending.generation == generation else {
                pendingAfterClockUpdate = nil
                return applySnapshot(
                    observedTime: observedTime,
                    currentTime: currentTime,
                    lyricTime: lyricTime,
                    currentTolerance: currentTolerance,
                    lyricTolerance: lyricTolerance,
                    force: false,
                    pendingBeforeClockUpdate: pendingBeforeClockUpdate,
                    pendingAfterClockUpdate: pendingAfterClockUpdate,
                    generation: generation
                )
            }

            let pendingDecision = PlaybackTimelinePolicy.pendingClockDecision(
                observedTime: observedTime,
                targetTime: pending.targetTime,
                originTime: pending.originTime,
                elapsedSinceSeek: pending.elapsedTime(at: now),
                mediaKind: mediaKind
            )
            switch pendingDecision {
            case .hold:
                return .hold
            case .release, .expire:
                pendingAfterClockUpdate = nil
            }
        }

        return applySnapshot(
            observedTime: observedTime,
            currentTime: currentTime,
            lyricTime: lyricTime,
            currentTolerance: currentTolerance,
            lyricTolerance: lyricTolerance,
            force: force,
            pendingBeforeClockUpdate: pendingBeforeClockUpdate,
            pendingAfterClockUpdate: pendingAfterClockUpdate,
            generation: generation
        )
    }

    private static func applySnapshot(
        observedTime: Double,
        currentTime: Double,
        lyricTime: Double,
        currentTolerance: Double,
        lyricTolerance: Double,
        force: Bool,
        pendingBeforeClockUpdate: PendingPlaybackSeek?,
        pendingAfterClockUpdate: PendingPlaybackSeek?,
        generation: Int
    ) -> PlaybackClockSnapshotDecision? {
        guard let clockUpdate = PlaybackClockPolicy.update(
            observedTime: observedTime,
            currentTime: currentTime,
            lyricTime: lyricTime,
            currentTolerance: currentTolerance,
            lyricTolerance: lyricTolerance,
            force: force
        ) else { return nil }

        let settledState = PlaybackSeekCommandPolicy.settledStateAfterClockUpdate(
            pendingBeforeClockUpdate: pendingBeforeClockUpdate,
            pendingAfterClockUpdate: pendingAfterClockUpdate,
            generation: generation,
            resolvedTime: observedTime,
            force: force
        )
        return .apply(
            PlaybackClockSnapshot(
                clockUpdate: clockUpdate,
                pendingSeek: pendingAfterClockUpdate,
                settledSeekState: settledState
            )
        )
    }
}
