import XCTest
@testable import MediaLibCore

final class PlaybackSeekCoordinatorTests: XCTestCase {
    func testScrubbingTransitionCreatesNewRevisionAndOriginWhenNeeded() throws {
        let transition = try XCTUnwrap(
            PlaybackSeekCoordinator.scrubbingTransition(
                currentState: nil,
                targetTime: 42,
                fallbackOriginTime: 12,
                createIfNeeded: true
            )
        )

        XCTAssertEqual(transition.revision, 1)
        XCTAssertEqual(transition.targetTime, 42)
        XCTAssertEqual(transition.originTime, 12)
        XCTAssertEqual(transition.state, .scrubbing(revision: 1, targetTime: 42, originTime: 12))
    }

    func testScrubbingTransitionReusesExistingScrubRevisionAndOrigin() throws {
        let current = PlaybackSeekState.scrubbing(
            revision: 7,
            targetTime: 20,
            originTime: 5
        )

        let transition = try XCTUnwrap(
            PlaybackSeekCoordinator.scrubbingTransition(
                currentState: current,
                targetTime: 48,
                fallbackOriginTime: 99,
                createIfNeeded: true
            )
        )

        XCTAssertEqual(transition.revision, 7)
        XCTAssertEqual(transition.originTime, 5)
        XCTAssertEqual(transition.state, .scrubbing(revision: 7, targetTime: 48, originTime: 5))
    }

    func testScrubbingTransitionCanDeclineCreation() {
        XCTAssertNil(
            PlaybackSeekCoordinator.scrubbingTransition(
                currentState: nil,
                targetTime: 10,
                fallbackOriginTime: 0,
                createIfNeeded: false
            )
        )
    }

    func testSeekingTransitionReusesActiveScrubIdentity() {
        let current = PlaybackSeekState.scrubbing(
            revision: 8,
            targetTime: 44,
            originTime: 11
        )

        let transition = PlaybackSeekCoordinator.seekingTransition(
            currentState: current,
            targetTime: 50,
            fallbackOriginTime: 99
        )

        XCTAssertEqual(transition.revision, 8)
        XCTAssertEqual(transition.originTime, 11)
        XCTAssertEqual(transition.state, .seeking(revision: 8, targetTime: 50, originTime: 11))
    }

    func testSeekingTransitionCreatesNextRevisionFromSettledState() {
        let current = PlaybackSeekState.settled(
            revision: 8,
            targetTime: 44,
            originTime: 11,
            resolvedTime: 44.1
        )

        let transition = PlaybackSeekCoordinator.seekingTransition(
            currentState: current,
            targetTime: 50,
            fallbackOriginTime: 44.1
        )

        XCTAssertEqual(transition.revision, 9)
        XCTAssertEqual(transition.originTime, 44.1)
        XCTAssertEqual(transition.state, .seeking(revision: 9, targetTime: 50, originTime: 44.1))
    }

    func testCanCancelOnlyActiveScrubbing() {
        XCTAssertFalse(PlaybackSeekCoordinator.canCancelScrubbing(currentState: nil))
        XCTAssertTrue(
            PlaybackSeekCoordinator.canCancelScrubbing(
                currentState: .scrubbing(revision: 1, targetTime: 10, originTime: 0)
            )
        )
        XCTAssertFalse(
            PlaybackSeekCoordinator.canCancelScrubbing(
                currentState: .seeking(revision: 1, targetTime: 10, originTime: 0)
            )
        )
    }
}
