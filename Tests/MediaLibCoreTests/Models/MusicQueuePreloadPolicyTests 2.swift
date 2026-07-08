import XCTest
@testable import MediaLibCore

final class MusicQueuePreloadPolicyTests: XCTestCase {
    func testSequentialModePreloadsNextTrackAndStopsAtEnd() {
        XCTAssertEqual(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "b",
                repeatModeRawValue: "sequential",
                shuffleEnabled: false
            ),
            "c"
        )

        XCTAssertNil(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "c",
                repeatModeRawValue: "sequential",
                shuffleEnabled: false
            )
        )
    }

    func testRepeatAllWrapsToFirstTrackButDoesNotPreloadSingleItemLoop() {
        XCTAssertEqual(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "c",
                repeatModeRawValue: "repeatAll",
                shuffleEnabled: false
            ),
            "a"
        )

        XCTAssertNil(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["solo"],
                currentItemID: "solo",
                repeatModeRawValue: "repeatAll",
                shuffleEnabled: false
            )
        )
    }

    func testRepeatOneAndShuffleNeverGuessNextPreloadTarget() {
        XCTAssertNil(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "b",
                repeatModeRawValue: "repeatOne",
                shuffleEnabled: false
            )
        )

        XCTAssertNil(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b", "c"],
                currentItemID: "b",
                repeatModeRawValue: "sequential",
                shuffleEnabled: true
            )
        )
    }

    func testMissingCurrentOrEmptyQueueProducesNoPreloadTarget() {
        XCTAssertNil(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: [],
                currentItemID: "a",
                repeatModeRawValue: "sequential",
                shuffleEnabled: false
            )
        )

        XCTAssertNil(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b"],
                currentItemID: "missing",
                repeatModeRawValue: "repeatAll",
                shuffleEnabled: false
            )
        )
    }

    func testUnknownRepeatModeFallsBackToSequentialSemantics() {
        XCTAssertEqual(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b"],
                currentItemID: "a",
                repeatModeRawValue: "futureMode",
                shuffleEnabled: false
            ),
            "b"
        )

        XCTAssertNil(
            MusicQueuePreloadPolicy.nextItemID(
                queueIDs: ["a", "b"],
                currentItemID: "b",
                repeatModeRawValue: "futureMode",
                shuffleEnabled: false
            )
        )
    }
}
