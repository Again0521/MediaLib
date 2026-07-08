import XCTest
@testable import MediaLibCore

final class PlaybackClockPolicyTests: XCTestCase {
    func testUpdateRejectsInvalidObservedTime() {
        XCTAssertNil(
            PlaybackClockPolicy.update(
                observedTime: .nan,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.1,
                lyricTolerance: 0.1
            )
        )
        XCTAssertNil(
            PlaybackClockPolicy.update(
                observedTime: -0.1,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.1,
                lyricTolerance: 0.1
            )
        )
    }

    func testUpdateKeepsTimesWithinTolerance() throws {
        let update = try XCTUnwrap(
            PlaybackClockPolicy.update(
                observedTime: 10.02,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.05
            )
        )

        XCTAssertEqual(update.currentTime, 10)
        XCTAssertEqual(update.lyricTime, 10)
        XCTAssertFalse(update.didChange)
    }

    func testUpdateChangesCurrentAndLyricIndependentlyByTolerance() throws {
        let update = try XCTUnwrap(
            PlaybackClockPolicy.update(
                observedTime: 10.04,
                currentTime: 10,
                lyricTime: 10,
                currentTolerance: 0.05,
                lyricTolerance: 0.02
            )
        )

        XCTAssertEqual(update.currentTime, 10)
        XCTAssertEqual(update.lyricTime, 10.04)
        XCTAssertFalse(update.didChangeCurrentTime)
        XCTAssertTrue(update.didChangeLyricTime)
        XCTAssertTrue(update.didChange)
    }

    func testForceAlwaysRefreshesLyricTimeButKeepsCurrentTolerance() throws {
        let update = try XCTUnwrap(
            PlaybackClockPolicy.update(
                observedTime: 25,
                currentTime: 25,
                lyricTime: 25,
                currentTolerance: 0.05,
                lyricTolerance: 0.05,
                force: true
            )
        )

        XCTAssertEqual(update.currentTime, 25)
        XCTAssertEqual(update.lyricTime, 25)
        XCTAssertFalse(update.didChangeCurrentTime)
        XCTAssertTrue(update.didChangeLyricTime)
        XCTAssertTrue(update.didChange)
    }

    func testInvalidExistingTimesAreRepairedFromObservedTime() throws {
        let update = try XCTUnwrap(
            PlaybackClockPolicy.update(
                observedTime: 12,
                currentTime: .nan,
                lyricTime: .infinity,
                currentTolerance: 0.05,
                lyricTolerance: 0.05
            )
        )

        XCTAssertEqual(update.currentTime, 12)
        XCTAssertEqual(update.lyricTime, 12)
        XCTAssertTrue(update.didChangeCurrentTime)
        XCTAssertTrue(update.didChangeLyricTime)
    }

    func testDisplayTimeFollowsSeekPhase() {
        XCTAssertEqual(
            PlaybackClockPolicy.displayTime(currentTime: 5, seekState: nil),
            5
        )
        XCTAssertEqual(
            PlaybackClockPolicy.displayTime(
                currentTime: 5,
                seekState: .scrubbing(revision: 1, targetTime: 30, originTime: 5)
            ),
            30
        )
        XCTAssertEqual(
            PlaybackClockPolicy.displayTime(
                currentTime: 5,
                seekState: .seeking(revision: 2, targetTime: 40, originTime: 5)
            ),
            40
        )
        XCTAssertEqual(
            PlaybackClockPolicy.displayTime(
                currentTime: 5,
                seekState: .settled(revision: 3, targetTime: 40, originTime: 5, resolvedTime: 39.8)
            ),
            39.8
        )
    }
}
