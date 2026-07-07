import Foundation

public enum PlaybackTimelineMediaKind: Equatable {
    case music
    case video
}

public enum PendingPlaybackClockDecision: Equatable {
    case hold
    case release
    case expire
}

public enum PlaybackTimelinePolicy {
    public static let pendingSeekHoldTimeout: TimeInterval = 3.8
    public static let minimumSeekReissueInterval: TimeInterval = 0.48
    public static let maximumSeekReissueCount = 4

    public static func clampedTime(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let upperBound = duration.isFinite ? max(duration, 0) : 0
        return min(max(seconds, 0), upperBound)
    }

    public static func clampedUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    public static func normalizedProgress(currentTime: Double, duration: Double) -> Double {
        guard currentTime.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return clampedUnit(currentTime / duration)
    }

    public static func timelineTime(forHorizontalPosition position: Double, width: Double, duration: Double) -> Double {
        let safeWidth = width.isFinite ? max(width, 1) : 1
        let safeDuration = duration.isFinite ? max(duration, 0) : 0
        let safePosition = position.isFinite ? position : 0
        let clampedPosition = min(max(safePosition, 0), safeWidth)
        return (clampedPosition / safeWidth) * safeDuration
    }

    public static func remainingTime(currentTime: Double, duration: Double) -> Double {
        guard currentTime.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return max(duration - currentTime, 0)
    }

    public static func pendingClockDecision(
        observedTime: Double,
        targetTime: Double,
        originTime: Double,
        elapsedSinceSeek: TimeInterval,
        mediaKind: PlaybackTimelineMediaKind
    ) -> PendingPlaybackClockDecision {
        guard observedTime.isFinite, targetTime.isFinite, originTime.isFinite else {
            return elapsedSinceSeek < pendingSeekHoldTimeout ? .hold : .expire
        }

        let distanceFromTarget = abs(observedTime - targetTime)
        let distanceFromOrigin = abs(observedTime - originTime)
        let requestedDistance = abs(targetTime - originTime)
        let targetTolerance = seekSettleTolerance(for: mediaKind)
        let didActuallyLeaveOrigin = requestedDistance <= 0.08 ||
            distanceFromOrigin >= originLeaveDistance(forRequestedDistance: requestedDistance)

        if distanceFromTarget <= targetTolerance, didActuallyLeaveOrigin {
            return .release
        }
        return elapsedSinceSeek < pendingSeekHoldTimeout ? .hold : .expire
    }

    public static func isSeekClockSettled(
        observedTime: Double,
        targetTime: Double,
        duration: Double,
        mediaKind: PlaybackTimelineMediaKind
    ) -> Bool {
        guard observedTime.isFinite, observedTime >= 0, targetTime.isFinite, targetTime >= 0 else {
            return false
        }
        if abs(observedTime - targetTime) <= seekSettleTolerance(for: mediaKind) {
            return true
        }
        guard mediaKind == .video, duration.isFinite, duration > 0 else { return false }
        let nearEndTolerance = 0.35
        return targetTime >= duration - nearEndTolerance &&
            observedTime >= duration - nearEndTolerance
    }

    public static func shouldReissueSeek(
        observedTime: Double,
        targetTime: Double,
        originTime: Double,
        reissueCount: Int,
        secondsSinceLastReissue: TimeInterval?,
        mediaKind: PlaybackTimelineMediaKind
    ) -> Bool {
        guard observedTime.isFinite, targetTime.isFinite, originTime.isFinite else { return false }
        guard abs(observedTime - targetTime) > seekReissueTolerance(for: mediaKind),
              abs(targetTime - originTime) > 0.08,
              reissueCount < maximumSeekReissueCount else {
            return false
        }
        if let secondsSinceLastReissue,
           secondsSinceLastReissue < minimumSeekReissueInterval {
            return false
        }
        return true
    }

    private static func seekSettleTolerance(for mediaKind: PlaybackTimelineMediaKind) -> Double {
        mediaKind == .music ? 0.08 : 0.24
    }

    private static func seekReissueTolerance(for mediaKind: PlaybackTimelineMediaKind) -> Double {
        mediaKind == .music ? 0.08 : 0.20
    }

    private static func originLeaveDistance(forRequestedDistance requestedDistance: Double) -> Double {
        min(max(requestedDistance * 0.45, 0.12), 0.85)
    }
}
