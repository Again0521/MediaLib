import XCTest
@testable import MediaLibCore

final class MusicOutputPolicyTests: XCTestCase {
    func testEffectiveVolumeMultipliesNormalizationAndTransitionThenClamps() {
        XCTAssertEqual(
            MusicOutputPolicy.effectiveVolume(baseVolume: 0.5, normalizationGain: 1.2, transitionScale: 0.5),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MusicOutputPolicy.effectiveVolume(baseVolume: 0.9, normalizationGain: 2, transitionScale: 1),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MusicOutputPolicy.effectiveVolume(baseVolume: -0.2, normalizationGain: 1, transitionScale: 1),
            0,
            accuracy: 0.0001
        )
    }

    func testInitialTransitionScaleOnlyStartsAtZeroForSoftFadeTrackTransitions() {
        XCTAssertEqual(
            MusicOutputPolicy.initialTransitionScale(isTrackTransition: true, mode: .softFade),
            0
        )
        XCTAssertEqual(
            MusicOutputPolicy.initialTransitionScale(isTrackTransition: false, mode: .softFade),
            1
        )
        XCTAssertEqual(
            MusicOutputPolicy.initialTransitionScale(isTrackTransition: true, mode: .immediate),
            1
        )
    }

    func testSoftFadeDurationUsesSettingsClamp() {
        XCTAssertEqual(MusicOutputPolicy.clampedSoftFadeDuration(0.1), 0.3, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.clampedSoftFadeDuration(1.4), 1.4, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.clampedSoftFadeDuration(4), 2, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.clampedSoftFadeDuration(.nan), 0.8, accuracy: 0.0001)
    }

    func testSoftFadeStepCountUsesSixtyHertzCadenceAndMinimumOneStep() {
        XCTAssertEqual(MusicOutputPolicy.softFadeStepCount(duration: 0.8), 48)
        XCTAssertEqual(MusicOutputPolicy.softFadeStepCount(duration: 0), 1)
        XCTAssertEqual(MusicOutputPolicy.softFadeStepCount(duration: -1), 1)
    }

    func testSoftFadeScaleUsesSmoothstepAndClampsStepBounds() {
        XCTAssertEqual(MusicOutputPolicy.softFadeScale(step: -5, totalSteps: 60), 0, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.softFadeScale(step: 0, totalSteps: 60), 0, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.softFadeScale(step: 30, totalSteps: 60), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.softFadeScale(step: 60, totalSteps: 60), 1, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.softFadeScale(step: 99, totalSteps: 60), 1, accuracy: 0.0001)
        XCTAssertEqual(MusicOutputPolicy.softFadeScale(step: 1, totalSteps: 0), 1, accuracy: 0.0001)
    }
}
