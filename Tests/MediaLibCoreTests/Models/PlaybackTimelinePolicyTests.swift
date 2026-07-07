import XCTest
@testable import MediaLibCore

final class PlaybackTimelinePolicyTests: XCTestCase {
    func testClampedTimeBoundsInvalidAndOutOfRangeValues() {
        XCTAssertEqual(PlaybackTimelinePolicy.clampedTime(-12, duration: 180), 0)
        XCTAssertEqual(PlaybackTimelinePolicy.clampedTime(240, duration: 180), 180)
        XCTAssertEqual(PlaybackTimelinePolicy.clampedTime(90, duration: 180), 90)
        XCTAssertEqual(PlaybackTimelinePolicy.clampedTime(.nan, duration: 180), 0)
        XCTAssertEqual(PlaybackTimelinePolicy.clampedTime(90, duration: .nan), 0)
    }

    func testNormalizedProgressIsClampedAndRejectsInvalidInputs() {
        XCTAssertEqual(PlaybackTimelinePolicy.normalizedProgress(currentTime: 30, duration: 120), 0.25)
        XCTAssertEqual(PlaybackTimelinePolicy.normalizedProgress(currentTime: 150, duration: 120), 1)
        XCTAssertEqual(PlaybackTimelinePolicy.normalizedProgress(currentTime: -10, duration: 120), 0)
        XCTAssertEqual(PlaybackTimelinePolicy.normalizedProgress(currentTime: 10, duration: 0), 0)
        XCTAssertEqual(PlaybackTimelinePolicy.normalizedProgress(currentTime: .infinity, duration: 120), 0)
    }

    func testTimelineTimeConvertsHorizontalPositionWithClamping() {
        XCTAssertEqual(
            PlaybackTimelinePolicy.timelineTime(forHorizontalPosition: 50, width: 200, duration: 120),
            30
        )
        XCTAssertEqual(
            PlaybackTimelinePolicy.timelineTime(forHorizontalPosition: -12, width: 200, duration: 120),
            0
        )
        XCTAssertEqual(
            PlaybackTimelinePolicy.timelineTime(forHorizontalPosition: 250, width: 200, duration: 120),
            120
        )
        XCTAssertEqual(
            PlaybackTimelinePolicy.timelineTime(forHorizontalPosition: 0.5, width: 0, duration: 120),
            60,
            accuracy: 0.0001
        )
    }

    func testRemainingTimeNeverGoesNegative() {
        XCTAssertEqual(PlaybackTimelinePolicy.remainingTime(currentTime: 40, duration: 120), 80)
        XCTAssertEqual(PlaybackTimelinePolicy.remainingTime(currentTime: 140, duration: 120), 0)
        XCTAssertEqual(PlaybackTimelinePolicy.remainingTime(currentTime: .nan, duration: 120), 0)
    }

    func testPendingClockReleasesOnlyAfterTargetIsReachedAndOriginWasLeft() {
        XCTAssertEqual(
            PlaybackTimelinePolicy.pendingClockDecision(
                observedTime: 12.05,
                targetTime: 12,
                originTime: 3,
                elapsedSinceSeek: 0.4,
                mediaKind: .music
            ),
            .release
        )

        XCTAssertEqual(
            PlaybackTimelinePolicy.pendingClockDecision(
                observedTime: 3.04,
                targetTime: 12,
                originTime: 3,
                elapsedSinceSeek: 0.4,
                mediaKind: .music
            ),
            .hold
        )
    }

    func testPendingClockExpiresAfterHoldTimeout() {
        XCTAssertEqual(
            PlaybackTimelinePolicy.pendingClockDecision(
                observedTime: 4,
                targetTime: 12,
                originTime: 3,
                elapsedSinceSeek: PlaybackTimelinePolicy.pendingSeekHoldTimeout + 0.1,
                mediaKind: .video
            ),
            .expire
        )
    }

    func testSeekClockSettledUsesMusicVideoAndNearEndTolerances() {
        XCTAssertTrue(
            PlaybackTimelinePolicy.isSeekClockSettled(
                observedTime: 20.07,
                targetTime: 20,
                duration: 200,
                mediaKind: .music
            )
        )
        XCTAssertFalse(
            PlaybackTimelinePolicy.isSeekClockSettled(
                observedTime: 20.12,
                targetTime: 20,
                duration: 200,
                mediaKind: .music
            )
        )
        XCTAssertTrue(
            PlaybackTimelinePolicy.isSeekClockSettled(
                observedTime: 99.72,
                targetTime: 99.8,
                duration: 100,
                mediaKind: .video
            )
        )
    }

    func testSeekReissuePolicyHonorsDistanceCountAndThrottle() {
        XCTAssertTrue(
            PlaybackTimelinePolicy.shouldReissueSeek(
                observedTime: 2,
                targetTime: 10,
                originTime: 1,
                reissueCount: 0,
                secondsSinceLastReissue: nil,
                mediaKind: .music
            )
        )
        XCTAssertFalse(
            PlaybackTimelinePolicy.shouldReissueSeek(
                observedTime: 9.95,
                targetTime: 10,
                originTime: 1,
                reissueCount: 0,
                secondsSinceLastReissue: nil,
                mediaKind: .music
            )
        )
        XCTAssertFalse(
            PlaybackTimelinePolicy.shouldReissueSeek(
                observedTime: 2,
                targetTime: 10,
                originTime: 1,
                reissueCount: PlaybackTimelinePolicy.maximumSeekReissueCount,
                secondsSinceLastReissue: nil,
                mediaKind: .video
            )
        )
        XCTAssertFalse(
            PlaybackTimelinePolicy.shouldReissueSeek(
                observedTime: 2,
                targetTime: 10,
                originTime: 1,
                reissueCount: 0,
                secondsSinceLastReissue: PlaybackTimelinePolicy.minimumSeekReissueInterval - 0.01,
                mediaKind: .video
            )
        )
    }
}
