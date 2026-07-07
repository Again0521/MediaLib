import XCTest
@testable import MediaLibCore

final class PlaybackSeekCommandPolicyTests: XCTestCase {
    func testCompletionDecisionIgnoresStaleGenerationOrRevision() {
        XCTAssertEqual(
            PlaybackSeekCommandPolicy.completionDecision(
                finished: true,
                observedTime: 40,
                targetTime: 40,
                expectedGeneration: 3,
                currentGeneration: 4,
                expectedRevision: 9,
                currentRevision: 9,
                duration: 120,
                mediaKind: .music
            ),
            .ignore
        )

        XCTAssertEqual(
            PlaybackSeekCommandPolicy.completionDecision(
                finished: true,
                observedTime: 40,
                targetTime: 40,
                expectedGeneration: 3,
                currentGeneration: 3,
                expectedRevision: 9,
                currentRevision: 10,
                duration: 120,
                mediaKind: .music
            ),
            .ignore
        )
    }

    func testCompletionDecisionSchedulesCorrectionWhenSeekDidNotFinish() {
        XCTAssertEqual(
            PlaybackSeekCommandPolicy.completionDecision(
                finished: false,
                observedTime: nil,
                targetTime: 40,
                expectedGeneration: 3,
                currentGeneration: 3,
                expectedRevision: 9,
                currentRevision: 9,
                duration: 120,
                mediaKind: .music
            ),
            .scheduleCorrection
        )
    }

    func testCompletionDecisionReissuesUntilPlaybackClockSettles() {
        XCTAssertEqual(
            PlaybackSeekCommandPolicy.completionDecision(
                finished: true,
                observedTime: 12,
                targetTime: 40,
                expectedGeneration: 3,
                currentGeneration: 3,
                expectedRevision: 9,
                currentRevision: 9,
                duration: 120,
                mediaKind: .music
            ),
            .reissue
        )

        XCTAssertEqual(
            PlaybackSeekCommandPolicy.completionDecision(
                finished: true,
                observedTime: nil,
                targetTime: 40,
                expectedGeneration: 3,
                currentGeneration: 3,
                expectedRevision: 9,
                currentRevision: 9,
                duration: 120,
                mediaKind: .music
            ),
            .reissue
        )
    }

    func testCompletionDecisionSettlesNearTargetOrVideoEnd() {
        XCTAssertEqual(
            PlaybackSeekCommandPolicy.completionDecision(
                finished: true,
                observedTime: 40.04,
                targetTime: 40,
                expectedGeneration: 3,
                currentGeneration: 3,
                expectedRevision: 9,
                currentRevision: 9,
                duration: 120,
                mediaKind: .music
            ),
            .settle
        )

        XCTAssertEqual(
            PlaybackSeekCommandPolicy.completionDecision(
                finished: true,
                observedTime: 119.8,
                targetTime: 119.9,
                expectedGeneration: 3,
                currentGeneration: 3,
                expectedRevision: 9,
                currentRevision: 9,
                duration: 120,
                mediaKind: .video
            ),
            .settle
        )
    }

    func testReissueIntentMarksPendingSeekAndReturnsTarget() throws {
        let now = Date(timeIntervalSince1970: 200)
        let pending = PendingPlaybackSeek(
            revision: 4,
            generation: 7,
            targetTime: 50,
            originTime: 10,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        let intent = try XCTUnwrap(
            PlaybackSeekCommandPolicy.reissueIntent(
                pending: pending,
                observedTime: 12,
                generation: 7,
                now: now,
                mediaKind: .music
            )
        )

        XCTAssertEqual(intent.targetTime, 50)
        XCTAssertEqual(intent.pending.revision, 4)
        XCTAssertEqual(intent.pending.generation, 7)
        XCTAssertEqual(intent.pending.reissueCount, 1)
        XCTAssertEqual(intent.pending.lastReissuedAt, now)
    }

    func testReissueIntentRejectsInvalidStaleThrottledAndExhaustedRequests() {
        let now = Date(timeIntervalSince1970: 200)
        let pending = PendingPlaybackSeek(
            revision: 4,
            generation: 7,
            targetTime: 50,
            originTime: 10,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(
            PlaybackSeekCommandPolicy.reissueIntent(
                pending: pending,
                observedTime: .nan,
                generation: 7,
                now: now,
                mediaKind: .music
            )
        )
        XCTAssertNil(
            PlaybackSeekCommandPolicy.reissueIntent(
                pending: pending,
                observedTime: 12,
                generation: 8,
                now: now,
                mediaKind: .music
            )
        )

        let throttled = PendingPlaybackSeek(
            revision: 4,
            generation: 7,
            targetTime: 50,
            originTime: 10,
            startedAt: Date(timeIntervalSince1970: 100),
            lastReissuedAt: now.addingTimeInterval(-PlaybackTimelinePolicy.minimumSeekReissueInterval / 2),
            reissueCount: 1
        )
        XCTAssertNil(
            PlaybackSeekCommandPolicy.reissueIntent(
                pending: throttled,
                observedTime: 12,
                generation: 7,
                now: now,
                mediaKind: .music
            )
        )

        let exhausted = PendingPlaybackSeek(
            revision: 4,
            generation: 7,
            targetTime: 50,
            originTime: 10,
            startedAt: Date(timeIntervalSince1970: 100),
            reissueCount: PlaybackTimelinePolicy.maximumSeekReissueCount
        )
        XCTAssertNil(
            PlaybackSeekCommandPolicy.reissueIntent(
                pending: exhausted,
                observedTime: 12,
                generation: 7,
                now: now,
                mediaKind: .music
            )
        )
    }

    func testSettledStateAfterClockUpdateUsesPendingSeekIdentity() throws {
        let pending = PendingPlaybackSeek(
            revision: 4,
            generation: 7,
            targetTime: 50,
            originTime: 10,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        let state = try XCTUnwrap(
            PlaybackSeekCommandPolicy.settledStateAfterClockUpdate(
                pendingBeforeClockUpdate: pending,
                pendingAfterClockUpdate: nil,
                generation: 7,
                resolvedTime: 50.02,
                force: false
            )
        )

        XCTAssertEqual(state.phase, .settled)
        XCTAssertEqual(state.revision, 4)
        XCTAssertEqual(state.targetTime, 50)
        XCTAssertEqual(state.originTime, 10)
        XCTAssertEqual(state.resolvedTime, 50.02)
    }

    func testSettledStateAfterClockUpdateRequiresReleasedPendingSeekUnlessForced() throws {
        let pending = PendingPlaybackSeek(
            revision: 4,
            generation: 7,
            targetTime: 50,
            originTime: 10,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(
            PlaybackSeekCommandPolicy.settledStateAfterClockUpdate(
                pendingBeforeClockUpdate: pending,
                pendingAfterClockUpdate: pending,
                generation: 7,
                resolvedTime: 50,
                force: false
            )
        )
        XCTAssertNil(
            PlaybackSeekCommandPolicy.settledStateAfterClockUpdate(
                pendingBeforeClockUpdate: pending,
                pendingAfterClockUpdate: nil,
                generation: 8,
                resolvedTime: 50,
                force: false
            )
        )
        XCTAssertNil(
            PlaybackSeekCommandPolicy.settledStateAfterClockUpdate(
                pendingBeforeClockUpdate: pending,
                pendingAfterClockUpdate: nil,
                generation: 7,
                resolvedTime: .nan,
                force: false
            )
        )

        let forced = try XCTUnwrap(
            PlaybackSeekCommandPolicy.settledStateAfterClockUpdate(
                pendingBeforeClockUpdate: pending,
                pendingAfterClockUpdate: pending,
                generation: 7,
                resolvedTime: 50,
                force: true
            )
        )
        XCTAssertEqual(forced.phase, .settled)
    }
}
