import Foundation

public enum PlaybackSeekCompletionDecision: Equatable {
    case ignore
    case scheduleCorrection
    case reissue
    case settle
}

public struct PlaybackSeekReissueIntent: Equatable {
    public let pending: PendingPlaybackSeek
    public let targetTime: Double
}

public enum PlaybackSeekCommandPolicy {
    public static func completionDecision(
        finished: Bool,
        observedTime: Double?,
        targetTime: Double,
        expectedGeneration: Int,
        currentGeneration: Int,
        expectedRevision: Int,
        currentRevision: Int?,
        duration: Double,
        mediaKind: PlaybackTimelineMediaKind
    ) -> PlaybackSeekCompletionDecision {
        guard currentGeneration == expectedGeneration,
              currentRevision == expectedRevision else {
            return .ignore
        }
        guard finished else { return .scheduleCorrection }
        guard let observedTime else { return .reissue }

        return PlaybackTimelinePolicy.isSeekClockSettled(
            observedTime: observedTime,
            targetTime: targetTime,
            duration: duration,
            mediaKind: mediaKind
        ) ? .settle : .reissue
    }

    public static func reissueIntent(
        pending: PendingPlaybackSeek?,
        observedTime: Double,
        generation: Int,
        now: Date,
        mediaKind: PlaybackTimelineMediaKind
    ) -> PlaybackSeekReissueIntent? {
        guard observedTime.isFinite,
              var pending,
              pending.generation == generation else { return nil }

        let secondsSinceLastReissue = pending.secondsSinceLastReissue(at: now)
        guard PlaybackTimelinePolicy.shouldReissueSeek(
            observedTime: observedTime,
            targetTime: pending.targetTime,
            originTime: pending.originTime,
            reissueCount: pending.reissueCount,
            secondsSinceLastReissue: secondsSinceLastReissue,
            mediaKind: mediaKind
        ) else { return nil }

        pending.markReissued(at: now)
        return PlaybackSeekReissueIntent(pending: pending, targetTime: pending.targetTime)
    }

    public static func settledStateAfterClockUpdate(
        pendingBeforeClockUpdate: PendingPlaybackSeek?,
        pendingAfterClockUpdate: PendingPlaybackSeek?,
        generation: Int,
        resolvedTime: Double,
        force: Bool
    ) -> PlaybackSeekState? {
        guard resolvedTime.isFinite,
              resolvedTime >= 0,
              let pending = pendingBeforeClockUpdate,
              pending.generation == generation,
              force || pendingAfterClockUpdate == nil else {
            return nil
        }

        return .settled(
            revision: pending.revision,
            targetTime: pending.targetTime,
            originTime: pending.originTime,
            resolvedTime: resolvedTime
        )
    }
}
