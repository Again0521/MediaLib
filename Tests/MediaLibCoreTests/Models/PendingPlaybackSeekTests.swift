import XCTest
@testable import MediaLibCore

final class PendingPlaybackSeekTests: XCTestCase {
    func testInitializerStoresSeekIdentityAndDefaultsReissueState() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let pending = PendingPlaybackSeek(
            revision: 3,
            generation: 9,
            targetTime: 42,
            originTime: 12,
            startedAt: startedAt
        )

        XCTAssertEqual(pending.revision, 3)
        XCTAssertEqual(pending.generation, 9)
        XCTAssertEqual(pending.targetTime, 42)
        XCTAssertEqual(pending.originTime, 12)
        XCTAssertEqual(pending.startedAt, startedAt)
        XCTAssertNil(pending.lastReissuedAt)
        XCTAssertEqual(pending.reissueCount, 0)
    }

    func testElapsedTimeUsesStartedAt() {
        let pending = PendingPlaybackSeek(
            revision: 1,
            generation: 2,
            targetTime: 30,
            originTime: 0,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            pending.elapsedTime(at: Date(timeIntervalSince1970: 103.5)),
            3.5,
            accuracy: 0.0001
        )
    }

    func testSecondsSinceLastReissueReturnsNilUntilMarked() throws {
        var pending = PendingPlaybackSeek(
            revision: 1,
            generation: 2,
            targetTime: 30,
            originTime: 0,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(pending.secondsSinceLastReissue(at: Date(timeIntervalSince1970: 101)))

        pending.markReissued(at: Date(timeIntervalSince1970: 102))

        XCTAssertEqual(pending.reissueCount, 1)
        XCTAssertEqual(pending.lastReissuedAt, Date(timeIntervalSince1970: 102))
        let secondsSinceLastReissue = try XCTUnwrap(
            pending.secondsSinceLastReissue(at: Date(timeIntervalSince1970: 102.7))
        )
        XCTAssertEqual(secondsSinceLastReissue, 0.7, accuracy: 0.0001)
    }

    func testMarkReissuedIncrementsExistingCount() {
        var pending = PendingPlaybackSeek(
            revision: 1,
            generation: 2,
            targetTime: 30,
            originTime: 0,
            startedAt: Date(timeIntervalSince1970: 100),
            lastReissuedAt: Date(timeIntervalSince1970: 101),
            reissueCount: 2
        )

        pending.markReissued(at: Date(timeIntervalSince1970: 105))

        XCTAssertEqual(pending.reissueCount, 3)
        XCTAssertEqual(pending.lastReissuedAt, Date(timeIntervalSince1970: 105))
    }
}
