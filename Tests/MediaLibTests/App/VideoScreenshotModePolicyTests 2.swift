import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoScreenshotModePolicyTests: XCTestCase {
    func testScreenshotModeArgumentsMatchExistingMpvValues() {
        XCTAssertEqual(VideoScreenshotModePolicy.mpvArgument(for: .subtitles), "subtitles")
        XCTAssertEqual(VideoScreenshotModePolicy.mpvArgument(for: .video), "video")
        XCTAssertEqual(VideoScreenshotModePolicy.mpvArgument(for: .window), "window")
    }

    func testAllScreenshotModesProduceNonEmptyMpvArguments() {
        for mode in VideoScreenshotMode.allCases {
            XCTAssertFalse(VideoScreenshotModePolicy.mpvArgument(for: mode).isEmpty)
        }
    }
}
