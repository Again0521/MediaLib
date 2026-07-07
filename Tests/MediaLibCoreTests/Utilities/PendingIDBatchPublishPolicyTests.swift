import XCTest
@testable import MediaLibCore

final class PendingIDBatchPublishPolicyTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstNonEmptyRecordIsReadyBecauseNoPreviousPublishExists() {
        var policy = PendingIDBatchPublishPolicy()

        XCTAssertTrue(policy.record(["item-1"], now: baseDate))
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertTrue(policy.flush(now: baseDate))
        XCTAssertEqual(policy.pendingCount, 0)
    }

    func testEmptyRecordAndEmptyFlushDoNotPublish() {
        var policy = PendingIDBatchPublishPolicy()

        XCTAssertFalse(policy.record([], now: baseDate))
        XCTAssertFalse(policy.flush(now: baseDate))
        XCTAssertEqual(policy.pendingCount, 0)
    }

    func testPendingIDsAreDeduplicatedBeforeCountThresholdIsEvaluated() {
        var policy = PendingIDBatchPublishPolicy(minimumInterval: 60, minimumItemCount: 3)
        XCTAssertTrue(policy.record(["seed"], now: baseDate))
        XCTAssertTrue(policy.flush(now: baseDate))

        XCTAssertFalse(policy.record(["a", "a"], now: baseDate.addingTimeInterval(1)))
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertFalse(policy.record(["a", "b"], now: baseDate.addingTimeInterval(2)))
        XCTAssertEqual(policy.pendingCount, 2)
        XCTAssertTrue(policy.record(["c"], now: baseDate.addingTimeInterval(3)))
        XCTAssertEqual(policy.pendingCount, 3)
    }

    func testPendingIDsBecomeReadyWhenIntervalPassesEvenBelowCountThreshold() {
        var policy = PendingIDBatchPublishPolicy(minimumInterval: 1.2, minimumItemCount: 18)
        XCTAssertTrue(policy.record(["seed"], now: baseDate))
        XCTAssertTrue(policy.flush(now: baseDate))

        XCTAssertFalse(policy.record(["a"], now: baseDate.addingTimeInterval(0.5)))
        XCTAssertFalse(policy.record([], now: baseDate.addingTimeInterval(1.199)))
        XCTAssertTrue(policy.record([], now: baseDate.addingTimeInterval(1.201)))
    }

    func testFlushResetsPendingBatchAndIntervalBaseline() {
        var policy = PendingIDBatchPublishPolicy(minimumInterval: 1.2, minimumItemCount: 18)
        XCTAssertTrue(policy.record(["seed"], now: baseDate))
        XCTAssertTrue(policy.flush(now: baseDate))

        XCTAssertFalse(policy.record(["a"], now: baseDate.addingTimeInterval(0.5)))
        XCTAssertTrue(policy.flush(now: baseDate.addingTimeInterval(0.5)))
        XCTAssertEqual(policy.pendingCount, 0)
        XCTAssertFalse(policy.record(["b"], now: baseDate.addingTimeInterval(1.0)))
        XCTAssertTrue(policy.record([], now: baseDate.addingTimeInterval(1.701)))
    }

    func testManualFlushPublishesAccumulatedIDsBeforeThresholdsAreReached() {
        var policy = PendingIDBatchPublishPolicy(minimumInterval: 60, minimumItemCount: 10)
        XCTAssertTrue(policy.record(["seed"], now: baseDate))
        XCTAssertTrue(policy.flush(now: baseDate))

        XCTAssertFalse(policy.record(["a", "b"], now: baseDate.addingTimeInterval(1)))
        XCTAssertEqual(policy.pendingCount, 2)
        XCTAssertTrue(policy.flush(now: baseDate.addingTimeInterval(1)))
        XCTAssertEqual(policy.pendingCount, 0)
    }
}
