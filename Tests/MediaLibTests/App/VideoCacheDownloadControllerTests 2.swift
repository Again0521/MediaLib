import XCTest
@testable import MediaLib

final class VideoCacheDownloadControllerTests: XCTestCase {
    func testResumeByteCountReadsKnownResumeDataKeys() throws {
        XCTAssertEqual(
            VideoCacheDownloadController.resumeByteCount(from: try resumeData(["NSURLSessionResumeBytesReceived": 123])),
            123
        )
        XCTAssertEqual(
            VideoCacheDownloadController.resumeByteCount(from: try resumeData(["_kCFURLSessionResumeBytesReceived": "456"])),
            456
        )
        XCTAssertEqual(
            VideoCacheDownloadController.resumeByteCount(from: try resumeData(["NSURLSessionResumeInfoBytesReceived": 789])),
            789
        )
    }

    func testResumeByteCountRejectsMalformedAndNegativeValues() throws {
        XCTAssertEqual(VideoCacheDownloadController.resumeByteCount(from: Data("not a plist".utf8)), 0)
        XCTAssertEqual(
            VideoCacheDownloadController.resumeByteCount(from: try resumeData(["NSURLSessionResumeBytesReceived": -20])),
            0
        )
        XCTAssertEqual(
            VideoCacheDownloadController.resumeByteCount(from: try resumeData(["NSURLSessionResumeBytesReceived": "not-a-number"])),
            0
        )
    }

    func testProgressSnapshotForFreshDownloadUsesReportedExpectedBytes() {
        let progress = VideoCacheDownloadController.progressSnapshot(
            reportedWritten: 40,
            reportedExpected: 100,
            baseBytes: 0,
            previousExpected: -1
        )

        XCTAssertEqual(progress.receivedBytes, 40)
        XCTAssertEqual(progress.expectedBytes, 100)
        XCTAssertEqual(progress.resumedBytes, 0)
        XCTAssertEqual(progress.fraction ?? -1, 0.4, accuracy: 1e-8)
    }

    func testProgressSnapshotKeepsPreviousExpectedWhenServerOmitsExpectedBytes() {
        let progress = VideoCacheDownloadController.progressSnapshot(
            reportedWritten: 60,
            reportedExpected: -1,
            baseBytes: 0,
            previousExpected: 200
        )

        XCTAssertEqual(progress.receivedBytes, 60)
        XCTAssertEqual(progress.expectedBytes, 200)
        XCTAssertEqual(progress.fraction ?? -1, 0.3, accuracy: 1e-8)
    }

    func testProgressSnapshotWithoutAnyExpectedBytesHasNilFraction() {
        let progress = VideoCacheDownloadController.progressSnapshot(
            reportedWritten: 60,
            reportedExpected: -1,
            baseBytes: 0,
            previousExpected: -1
        )

        XCTAssertEqual(progress.receivedBytes, 60)
        XCTAssertEqual(progress.expectedBytes, -1)
        XCTAssertNil(progress.fraction)
    }

    func testProgressSnapshotForResumeWhenSessionReportsRemainingBytes() {
        let progress = VideoCacheDownloadController.progressSnapshot(
            reportedWritten: 100,
            reportedExpected: 200,
            baseBytes: 150,
            previousExpected: -1
        )

        XCTAssertEqual(progress.receivedBytes, 250)
        XCTAssertEqual(progress.expectedBytes, 350)
        XCTAssertEqual(progress.resumedBytes, 150)
        XCTAssertEqual(progress.fraction ?? -1, 250.0 / 350.0, accuracy: 1e-8)
    }

    func testProgressSnapshotForResumeWhenSessionReportsAbsoluteBytes() {
        let progress = VideoCacheDownloadController.progressSnapshot(
            reportedWritten: 150,
            reportedExpected: 300,
            baseBytes: 100,
            previousExpected: -1
        )

        XCTAssertEqual(progress.receivedBytes, 150)
        XCTAssertEqual(progress.expectedBytes, 300)
        XCTAssertEqual(progress.resumedBytes, 100)
        XCTAssertEqual(progress.fraction ?? -1, 0.5, accuracy: 1e-8)
    }

    func testProgressSnapshotNeverReportsExpectedBelowReceivedBytes() {
        let progress = VideoCacheDownloadController.progressSnapshot(
            reportedWritten: 240,
            reportedExpected: 200,
            baseBytes: 100,
            previousExpected: 250
        )

        XCTAssertEqual(progress.receivedBytes, 240)
        XCTAssertEqual(progress.expectedBytes, 250)
        XCTAssertEqual(progress.fraction ?? -1, 0.96, accuracy: 1e-8)
    }

    func testProgressSnapshotClampsNegativeByteInputs() {
        let progress = VideoCacheDownloadController.progressSnapshot(
            reportedWritten: -10,
            reportedExpected: 100,
            baseBytes: -5,
            previousExpected: -1
        )

        XCTAssertEqual(progress.receivedBytes, 0)
        XCTAssertEqual(progress.expectedBytes, 100)
        XCTAssertEqual(progress.resumedBytes, 0)
        XCTAssertEqual(progress.fraction ?? -1, 0, accuracy: 1e-8)
    }

    func testFallbackResponseUsesOriginalRequestURL() {
        let url = URL(string: "https://media.example/video.mp4")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: url)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        let response = VideoCacheDownloadController.fallbackResponse(for: task)

        XCTAssertEqual(response.url, url)
        XCTAssertEqual(response.expectedContentLength, -1)
    }

    private func resumeData(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        )
    }
}
