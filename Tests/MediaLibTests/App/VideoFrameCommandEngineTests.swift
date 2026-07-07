import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class VideoFrameCommandEngineTests: XCTestCase {
    func testFrameStepCommandsMapDirectionToMpvArguments() {
        let transport = FakeFrameCommandTransport()
        let engine = MpvVideoFrameCommandEngine(transport: transport)

        engine.stepFrame(backward: false)
        engine.stepFrame(backward: true)

        XCTAssertEqual(
            transport.commands,
            [
                ["frame-step"],
                ["frame-back-step"]
            ]
        )
    }

    func testScreenshotCommandPreservesTargetPathAndModeArguments() throws {
        let transport = FakeFrameCommandTransport()
        let engine = MpvVideoFrameCommandEngine(transport: transport)
        let targetURL = URL(fileURLWithPath: "/tmp/MediaLIB Screenshot.png")

        try engine.captureCurrentFrame(to: targetURL, mode: .subtitles)
        try engine.captureCurrentFrame(to: targetURL, mode: .video)
        try engine.captureCurrentFrame(to: targetURL, mode: .window)

        XCTAssertEqual(
            transport.commands,
            [
                ["screenshot-to-file", "/tmp/MediaLIB Screenshot.png", "subtitles"],
                ["screenshot-to-file", "/tmp/MediaLIB Screenshot.png", "video"],
                ["screenshot-to-file", "/tmp/MediaLIB Screenshot.png", "window"]
            ]
        )
    }

    func testScreenshotFailureIsPropagatedForControllerFallback() {
        let transport = FakeFrameCommandTransport()
        let engine = MpvVideoFrameCommandEngine(transport: transport)
        let targetURL = URL(fileURLWithPath: "/tmp/fallback.png")
        transport.errorToThrow = FakeFrameCommandError.commandRejected

        XCTAssertThrowsError(try engine.captureCurrentFrame(to: targetURL, mode: .window)) { error in
            XCTAssertEqual(error as? FakeFrameCommandError, .commandRejected)
        }
        XCTAssertEqual(transport.commands, [["screenshot-to-file", "/tmp/fallback.png", "window"]])
    }
}

@MainActor
private final class FakeFrameCommandTransport: MpvFrameCommandTransport {
    var commands: [[String]] = []
    var errorToThrow: Error?

    func command(_ arguments: [String]) throws {
        commands.append(arguments)
        if let errorToThrow {
            throw errorToThrow
        }
    }
}

private enum FakeFrameCommandError: Error, Equatable {
    case commandRejected
}
