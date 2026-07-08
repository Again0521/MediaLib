import XCTest
@testable import MediaLibCore

final class PlaybackABLoopPolicyTests: XCTestCase {
    func testCycleStartsNewLoopWhenNoStartExists() {
        XCTAssertEqual(
            PlaybackABLoopPolicy.cycleSelection(currentTime: 12.5, start: nil, end: nil),
            .start(12.5)
        )
    }

    func testCycleRestartsLoopWhenRangeAlreadyExists() {
        XCTAssertEqual(
            PlaybackABLoopPolicy.cycleSelection(currentTime: 40, start: 10, end: 30),
            .start(40)
        )
    }

    func testCycleRestartsStartWhenCurrentTimeIsTooCloseToStart() {
        XCTAssertEqual(
            PlaybackABLoopPolicy.cycleSelection(
                currentTime: 10 + PlaybackABLoopPolicy.minimumRangeDuration,
                start: 10,
                end: nil
            ),
            .start(10 + PlaybackABLoopPolicy.minimumRangeDuration)
        )
    }

    func testCycleCreatesRangeWhenCurrentTimeIsBeyondMinimumDuration() {
        XCTAssertEqual(
            PlaybackABLoopPolicy.cycleSelection(currentTime: 10.21, start: 10, end: nil),
            .range(10, 10.21)
        )
    }

    func testSelectionIncludesClearedStateForExplicitClearCommands() {
        XCTAssertEqual(PlayerABLoopSelection.cleared, .cleared)
    }
}
