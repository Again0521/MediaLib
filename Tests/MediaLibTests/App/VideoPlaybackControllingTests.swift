import XCTest
@testable import MediaLib

@MainActor
final class VideoPlaybackControllingTests: XCTestCase {
    func testMpvPlayerControllerConformsToVideoPlaybackControlling() {
        let controller = MpvPlayerController()
        let commands: VideoPlaybackControlling = controller

        XCTAssertTrue(commands === controller)
    }

    func testProtocolCanBeSatisfiedByCommandOnlyFake() {
        let fake = RecordingVideoPlaybackController()
        let commands: VideoPlaybackControlling = fake
        let option = VideoStreamQualityOption(
            id: "720p",
            label: "720p",
            detail: "测试画质",
            baseURLString: "https://example.test/video.mkv",
            isOriginal: false,
            appliesInPlace: false,
            videoFilter: nil,
            width: 1280,
            height: 720,
            videoBitrate: 2_000_000
        )

        commands.togglePlay()
        commands.seek(by: -15)
        commands.seek(to: 42)
        commands.toggleFullscreen()
        commands.switchVideoQuality(to: option)

        XCTAssertEqual(
            fake.commands,
            [
                "togglePlay",
                "seekBy:-15.0",
                "seekTo:42.0",
                "toggleFullscreen",
                "switchQuality:720p"
            ]
        )
    }
}

@MainActor
private final class RecordingVideoPlaybackController: VideoPlaybackControlling {
    private(set) var commands: [String] = []

    func togglePlay() {
        commands.append("togglePlay")
    }

    func seek(by seconds: Double) {
        commands.append("seekBy:\(seconds)")
    }

    func seek(to seconds: Double) {
        commands.append("seekTo:\(seconds)")
    }

    func toggleFullscreen() {
        commands.append("toggleFullscreen")
    }

    func switchVideoQuality(to option: VideoStreamQualityOption) {
        commands.append("switchQuality:\(option.id)")
    }
}
