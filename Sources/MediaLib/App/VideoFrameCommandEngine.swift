import Foundation
import MediaLibCore

@MainActor
protocol MpvFrameCommandTransport: AnyObject {
    func command(_ arguments: [String]) throws
}

extension LibMpvClient: MpvFrameCommandTransport {}

@MainActor
protocol VideoFrameCommandEngine: AnyObject {
    func stepFrame(backward: Bool)
    func captureCurrentFrame(to targetURL: URL, mode: VideoScreenshotMode) throws
}

@MainActor
final class MpvVideoFrameCommandEngine: VideoFrameCommandEngine {
    private let transport: MpvFrameCommandTransport

    init(transport: MpvFrameCommandTransport) {
        self.transport = transport
    }

    func stepFrame(backward: Bool) {
        try? transport.command([backward ? "frame-back-step" : "frame-step"])
    }

    func captureCurrentFrame(to targetURL: URL, mode: VideoScreenshotMode) throws {
        try transport.command(["screenshot-to-file", targetURL.path, VideoScreenshotModePolicy.mpvArgument(for: mode)])
    }
}
