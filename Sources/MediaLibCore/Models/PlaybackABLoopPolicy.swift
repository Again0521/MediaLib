public enum PlayerABLoopSelection: Equatable {
    case start(Double)
    case range(Double, Double)
    case cleared
}

public enum PlaybackABLoopPolicy {
    public static let minimumRangeDuration = 0.20

    public static func cycleSelection(
        currentTime: Double,
        start: Double?,
        end: Double?
    ) -> PlayerABLoopSelection {
        if start == nil || end != nil {
            return .start(currentTime)
        }
        guard let start else {
            return .start(currentTime)
        }
        if currentTime <= start + minimumRangeDuration {
            return .start(currentTime)
        }
        return .range(start, currentTime)
    }
}
