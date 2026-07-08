import XCTest
@testable import MediaLibCore

final class PlaybackClockSnapshotPolicyTests: XCTestCase {
    func testDecisionRejectsInvalidObservedTime() {
        XCTAssertNil(
            PlaybackClockSnapshotPolicy.decision(
                observedTime: .nan,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                pendingSeek: nil,
                generation: 1,
                now: Date(timeIntervalSince1970: 100),
                mediaKind: .music
            )
        )
    }

    func testDecisionAppliesClockUpdateWhenNoPendingSeekExists() throws {
        let snapshot = try appliedSnapshot(
            PlaybackClockSnapshotPolicy.decision(
                observedTime: 12,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                pendingSeek: nil,
                generation: 1,
                now: Date(timeIntervalSince1970: 100),
                mediaKind: .music
            )
        )

        XCTAssertEqual(snapshot.clockUpdate.currentTime, 12)
        XCTAssertEqual(snapshot.clockUpdate.lyricTime, 12)
        XCTAssertNil(snapshot.pendingSeek)
        XCTAssertNil(snapshot.settledSeekState)
    }

    func testDecisionHoldsClockWhilePendingSeekHasNotReachedTarget() {
        let pending = pendingSeek(targetTime: 50, originTime: 10)

        XCTAssertEqual(
            PlaybackClockSnapshotPolicy.decision(
                observedTime: 10.05,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                pendingSeek: pending,
                generation: 7,
                now: Date(timeIntervalSince1970: 101),
                mediaKind: .music
            ),
            .hold
        )
    }

    func testDecisionClearsStalePendingSeekWithoutSettling() throws {
        let pending = pendingSeek(targetTime: 50, originTime: 10, generation: 7)
        let snapshot = try appliedSnapshot(
            PlaybackClockSnapshotPolicy.decision(
                observedTime: 12,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                pendingSeek: pending,
                generation: 8,
                now: Date(timeIntervalSince1970: 101),
                mediaKind: .music
            )
        )

        XCTAssertEqual(snapshot.clockUpdate.currentTime, 12)
        XCTAssertEqual(snapshot.clockUpdate.lyricTime, 12)
        XCTAssertNil(snapshot.pendingSeek)
        XCTAssertNil(snapshot.settledSeekState)
    }

    func testDecisionReleasesPendingSeekAndBuildsSettledState() throws {
        let pending = pendingSeek(targetTime: 50, originTime: 10)
        let snapshot = try appliedSnapshot(
            PlaybackClockSnapshotPolicy.decision(
                observedTime: 50.02,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                pendingSeek: pending,
                generation: 7,
                now: Date(timeIntervalSince1970: 101),
                mediaKind: .music
            )
        )

        XCTAssertNil(snapshot.pendingSeek)
        let state = try XCTUnwrap(snapshot.settledSeekState)
        XCTAssertEqual(state.phase, .settled)
        XCTAssertEqual(state.revision, 4)
        XCTAssertEqual(state.targetTime, 50)
        XCTAssertEqual(state.originTime, 10)
        XCTAssertEqual(state.resolvedTime, 50.02)
    }

    func testDecisionExpiresPendingSeekAfterHoldTimeoutAndSettlesToObservedTime() throws {
        let pending = pendingSeek(targetTime: 50, originTime: 10)
        let snapshot = try appliedSnapshot(
            PlaybackClockSnapshotPolicy.decision(
                observedTime: 14,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                pendingSeek: pending,
                generation: 7,
                now: Date(timeIntervalSince1970: 100 + PlaybackTimelinePolicy.pendingSeekHoldTimeout + 0.1),
                mediaKind: .music
            )
        )

        XCTAssertNil(snapshot.pendingSeek)
        XCTAssertEqual(snapshot.settledSeekState?.phase, .settled)
        XCTAssertEqual(snapshot.settledSeekState?.resolvedTime, 14)
    }

    func testForceClearsPendingSeekAndBuildsSettledStateEvenWhenClockWouldHold() throws {
        let pending = pendingSeek(targetTime: 50, originTime: 10)
        let snapshot = try appliedSnapshot(
            PlaybackClockSnapshotPolicy.decision(
                observedTime: 12,
                currentTime: 12,
                lyricTime: 12,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                force: true,
                pendingSeek: pending,
                generation: 7,
                now: Date(timeIntervalSince1970: 101),
                mediaKind: .music
            )
        )

        XCTAssertNil(snapshot.pendingSeek)
        XCTAssertFalse(snapshot.clockUpdate.didChangeCurrentTime)
        XCTAssertTrue(snapshot.clockUpdate.didChangeLyricTime)
        XCTAssertEqual(snapshot.settledSeekState?.phase, .settled)
        XCTAssertEqual(snapshot.settledSeekState?.resolvedTime, 12)
    }

    private func pendingSeek(
        targetTime: Double,
        originTime: Double,
        generation: Int = 7
    ) -> PendingPlaybackSeek {
        PendingPlaybackSeek(
            revision: 4,
            generation: generation,
            targetTime: targetTime,
            originTime: originTime,
            startedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func appliedSnapshot(
        _ decision: PlaybackClockSnapshotDecision?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PlaybackClockSnapshot {
        switch try XCTUnwrap(decision, file: file, line: line) {
        case .hold:
            XCTFail("Expected apply snapshot, got hold", file: file, line: line)
            throw TestError.unexpectedHold
        case .apply(let snapshot):
            return snapshot
        }
    }

    private enum TestError: Error {
        case unexpectedHold
    }
}
