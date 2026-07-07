import Foundation

public struct PlaybackClockUpdate: Equatable {
    public let currentTime: Double
    public let lyricTime: Double
    public let didChangeCurrentTime: Bool
    public let didChangeLyricTime: Bool

    public var didChange: Bool {
        didChangeCurrentTime || didChangeLyricTime
    }
}

public enum PlaybackClockPolicy {
    public static func update(
        observedTime: Double,
        currentTime: Double,
        lyricTime: Double,
        currentTolerance: Double,
        lyricTolerance: Double,
        force: Bool = false
    ) -> PlaybackClockUpdate? {
        guard observedTime.isFinite, observedTime >= 0 else { return nil }

        let safeCurrentTolerance = max(currentTolerance, 0)
        let safeLyricTolerance = max(lyricTolerance, 0)
        let shouldUpdateCurrent = !currentTime.isFinite ||
            abs(currentTime - observedTime) > safeCurrentTolerance
        let shouldUpdateLyric = force ||
            !lyricTime.isFinite ||
            abs(lyricTime - observedTime) > safeLyricTolerance

        return PlaybackClockUpdate(
            currentTime: shouldUpdateCurrent ? observedTime : currentTime,
            lyricTime: shouldUpdateLyric ? observedTime : lyricTime,
            didChangeCurrentTime: shouldUpdateCurrent,
            didChangeLyricTime: shouldUpdateLyric
        )
    }

    public static func displayTime(currentTime: Double, seekState: PlaybackSeekState?) -> Double {
        guard let seekState else { return currentTime }
        switch seekState.phase {
        case .scrubbing, .seeking:
            return seekState.presentationTime
        case .settled:
            return seekState.resolvedTime ?? currentTime
        }
    }
}
