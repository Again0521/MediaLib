import XCTest
@testable import MediaLibCore

final class PlaybackSeekStateTests: XCTestCase {
    func testScrubbingStatePresentsTargetAndMarksUserPreview() {
        let state = PlaybackSeekState.scrubbing(
            revision: 3,
            targetTime: 42,
            originTime: 12
        )

        XCTAssertEqual(state.revision, 3)
        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertEqual(state.targetTime, 42)
        XCTAssertEqual(state.originTime, 12)
        XCTAssertEqual(state.presentationTime, 42)
        XCTAssertTrue(state.isUserPreview)
        XCTAssertFalse(state.isAwaitingPlaybackClock)
    }

    func testSeekingStateAwaitsPlaybackClock() {
        let state = PlaybackSeekState.seeking(
            revision: 4,
            targetTime: 80,
            originTime: 20
        )

        XCTAssertEqual(state.phase, .seeking)
        XCTAssertEqual(state.presentationTime, 80)
        XCTAssertFalse(state.isUserPreview)
        XCTAssertTrue(state.isAwaitingPlaybackClock)
    }

    func testSettledStatePresentsResolvedPlaybackClockTime() {
        let state = PlaybackSeekState.settled(
            revision: 5,
            targetTime: 100,
            originTime: 60,
            resolvedTime: 99.82
        )

        XCTAssertEqual(state.phase, .settled)
        XCTAssertEqual(state.presentationTime, 99.82)
        XCTAssertFalse(state.isUserPreview)
        XCTAssertFalse(state.isAwaitingPlaybackClock)
    }

    func testNextRevisionAdvancesFromCurrentStateAndStartsAtOne() {
        XCTAssertEqual(PlaybackSeekState.nextRevision(after: nil), 1)

        let state = PlaybackSeekState.seeking(
            revision: 12,
            targetTime: 40,
            originTime: 10
        )
        XCTAssertEqual(PlaybackSeekState.nextRevision(after: state), 13)
    }
}
