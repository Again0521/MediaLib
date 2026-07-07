import XCTest
@testable import MediaLibCore

final class PlaybackQueuePolicyTests: XCTestCase {
    func testSequentialMusicQueueMovesForwardAndStopsAtEnd() {
        XCTAssertEqual(
            PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "b",
                direction: 1,
                repeatModeRawValue: "sequential"
            ),
            "c"
        )

        XCTAssertNil(
            PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "c",
                direction: 1,
                repeatModeRawValue: "sequential"
            )
        )
    }

    func testRepeatAllWrapsBothDirections() {
        XCTAssertEqual(
            PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "c",
                direction: 1,
                repeatModeRawValue: "repeatAll"
            ),
            "a"
        )

        XCTAssertEqual(
            PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "a",
                direction: -1,
                repeatModeRawValue: "repeatAll"
            ),
            "c"
        )
    }

    func testRepeatOneReturnsCurrentID() {
        XCTAssertEqual(
            PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: [],
                currentItemID: "current",
                direction: 1,
                repeatModeRawValue: "repeatOne"
            ),
            "current"
        )
    }

    func testGenericAdjacentPolicyDoesNotWrapWhenDisabled() {
        XCTAssertNil(
            PlaybackQueuePolicy.adjacentItemID(
                queueIDs: ["a", "b"],
                currentItemID: "a",
                direction: -1,
                wraps: false
            )
        )

        XCTAssertEqual(
            PlaybackQueuePolicy.adjacentItemID(
                queueIDs: ["a", "b"],
                currentItemID: "a",
                direction: -1,
                wraps: true
            ),
            "b"
        )
    }

    func testMissingCurrentAndUnknownRepeatModeUseSequentialSemantics() {
        XCTAssertNil(
            PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: ["a", "b"],
                currentItemID: "missing",
                direction: 1,
                repeatModeRawValue: "repeatAll"
            )
        )

        XCTAssertNil(
            PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: ["a", "b"],
                currentItemID: "b",
                direction: 1,
                repeatModeRawValue: "futureMode"
            )
        )
    }

    func testZeroDirectionKeepsExistingNextTrackSemantics() {
        XCTAssertEqual(
            PlaybackQueuePolicy.adjacentItemID(
                queueIDs: ["a", "b"],
                currentItemID: "a",
                direction: 0,
                wraps: false
            ),
            "b"
        )
    }
}
