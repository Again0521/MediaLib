import Foundation

public enum MusicOutputPolicy {
    public static func effectiveVolume(
        baseVolume: Float,
        normalizationGain: Float,
        transitionScale: Float
    ) -> Float {
        min(max(baseVolume * normalizationGain * transitionScale, 0), 1)
    }

    public static func initialTransitionScale(
        isTrackTransition: Bool,
        mode: MusicTransitionMode
    ) -> Float {
        isTrackTransition && mode == .softFade ? 0 : 1
    }

    public static func clampedSoftFadeDuration(_ value: Double) -> Double {
        AppSettings.clampedMusicSoftFadeDuration(value)
    }

    public static func softFadeStepCount(duration: Double) -> Int {
        max(Int(duration * 60), 1)
    }

    public static func softFadeScale(step: Int, totalSteps: Int) -> Float {
        let steps = max(totalSteps, 1)
        let clampedStep = min(max(step, 0), steps)
        let progress = Float(clampedStep) / Float(steps)
        return progress * progress * (3 - 2 * progress)
    }
}
