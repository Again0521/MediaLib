import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class ScanActivityStoreTests: XCTestCase {
    func testBeginAndFinishOwnScanActivityState() {
        let store = ScanActivityStore()

        store.begin(queueCount: 3)

        XCTAssertTrue(store.isScanning)
        XCTAssertEqual(store.queueCount, 3)

        store.setProgress(scanProgress(processedFiles: 2, totalFiles: 10))
        XCTAssertEqual(store.progress?.processedFiles, 2)

        store.finish()

        XCTAssertFalse(store.isScanning)
        XCTAssertEqual(store.queueCount, 0)
        XCTAssertNil(store.progress)
    }

    func testQueueCountIsClampedAtZero() {
        let store = ScanActivityStore()

        store.setQueueCount(-4)

        XCTAssertEqual(store.queueCount, 0)
    }

    private func scanProgress(processedFiles: Int, totalFiles: Int) -> ScanProgress {
        ScanProgress(
            sourceID: "source-1",
            status: "扫描中",
            totalFiles: totalFiles,
            processedFiles: processedFiles,
            currentPath: "/Media",
            errorMessage: nil
        )
    }
}
