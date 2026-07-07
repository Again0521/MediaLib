import XCTest
@testable import MediaLibCore

final class ProgressPublishPolicyTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testScanProgressPublishesFirstRunningSnapshotAndSuppressesTinyImmediateAdvances() {
        var policy = ScanProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 0), now: baseDate))
        XCTAssertFalse(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 1), now: baseDate.addingTimeInterval(0.01)))
        XCTAssertFalse(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 7), now: baseDate.addingTimeInterval(0.02)))
    }

    func testScanProgressPublishesAtMinimumItemStepForSmallAndMediumLibraries() {
        var policy = ScanProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 0), now: baseDate))
        XCTAssertFalse(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 7), now: baseDate))
        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 8), now: baseDate))
    }

    func testScanProgressUsesProportionalItemStepForLargeLibraries() {
        var policy = ScanProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 5_000, processedFiles: 0), now: baseDate))
        XCTAssertFalse(policy.shouldPublish(scanProgress(totalFiles: 5_000, processedFiles: 21), now: baseDate))
        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 5_000, processedFiles: 22), now: baseDate))
    }

    func testScanProgressPublishesAfterMinimumIntervalEvenWithoutEnoughItemAdvance() {
        var policy = ScanProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 1_000, processedFiles: 0), now: baseDate))
        XCTAssertFalse(policy.shouldPublish(scanProgress(totalFiles: 1_000, processedFiles: 1), now: baseDate.addingTimeInterval(0.179)))
        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 1_000, processedFiles: 1), now: baseDate.addingTimeInterval(0.181)))
    }

    func testScanProgressPublishesTerminalAndErrorSnapshotsImmediately() {
        var policy = ScanProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 0), now: baseDate))
        XCTAssertTrue(policy.shouldPublish(scanProgress(status: "finished", totalFiles: 100, processedFiles: 1), now: baseDate))
        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 2, errorMessage: "scan failed"), now: baseDate))
        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 0, processedFiles: 0), now: baseDate))
    }

    func testScanProgressResetAllowsNextSnapshotAsInitialPublish() {
        var policy = ScanProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 0), now: baseDate))
        XCTAssertFalse(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 1), now: baseDate))

        policy.reset()

        XCTAssertTrue(policy.shouldPublish(scanProgress(totalFiles: 100, processedFiles: 1), now: baseDate))
    }

    func testFractionalProgressPublishesInitialValueAndOnePercentAdvance() {
        var policy = FractionalProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(0, now: baseDate))
        XCTAssertFalse(policy.shouldPublish(0.009, now: baseDate))
        XCTAssertTrue(policy.shouldPublish(0.011, now: baseDate))
    }

    func testFractionalProgressPublishesAfterMinimumIntervalForSmallAdvance() {
        var policy = FractionalProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(0.5, now: baseDate))
        XCTAssertFalse(policy.shouldPublish(0.505, now: baseDate.addingTimeInterval(0.179)))
        XCTAssertTrue(policy.shouldPublish(0.505, now: baseDate.addingTimeInterval(0.181)))
    }

    func testFractionalProgressDoesNotPublishRegressionUntilWaitWindowPasses() {
        var policy = FractionalProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(0.4, now: baseDate))
        XCTAssertFalse(policy.shouldPublish(0.3, now: baseDate))
        XCTAssertTrue(policy.shouldPublish(0.3, now: baseDate.addingTimeInterval(0.181)))
    }

    func testFractionalProgressClampsOutOfRangeValuesAndAlwaysPublishesTerminalProgress() {
        var policy = FractionalProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(-0.25, now: baseDate))
        XCTAssertFalse(policy.shouldPublish(0.005, now: baseDate))
        XCTAssertTrue(policy.shouldPublish(1.5, now: baseDate))
        XCTAssertTrue(policy.shouldPublish(1, now: baseDate))
    }

    func testFractionalProgressResetAllowsNextValueAsInitialPublish() {
        var policy = FractionalProgressPublishPolicy()

        XCTAssertTrue(policy.shouldPublish(0.8, now: baseDate))
        XCTAssertFalse(policy.shouldPublish(0.805, now: baseDate))

        policy.reset()

        XCTAssertTrue(policy.shouldPublish(0, now: baseDate))
    }

    private func scanProgress(
        status: String = "running",
        totalFiles: Int,
        processedFiles: Int,
        errorMessage: String? = nil
    ) -> ScanProgress {
        ScanProgress(
            sourceID: "source",
            status: status,
            totalFiles: totalFiles,
            processedFiles: processedFiles,
            currentPath: nil,
            errorMessage: errorMessage
        )
    }
}
