import Foundation
import MediaLibCore
import XCTest
@testable import MediaLib

@MainActor
final class MpvVideoStartRetryTests: XCTestCase {
    func testClosingBeforeRenderSurfaceIsReadyDoesNotReportLateStartupFailure() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("medialib-video-start-retry-\(UUID().uuidString).mkv")
        try Data([0]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = MpvPlayerController()
        controller.configure(
            item: MediaItem(id: UUID().uuidString, type: .movie, title: "Retry", filePath: fileURL.path),
            settings: AppSettings()
        )
        XCTAssertTrue(controller.isPreparing)
        controller.teardown()

        // The old retry chain exhausted its 40 attempts after roughly two seconds,
        // calling fail() on an already closed player.
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isPreparing)
    }
}
