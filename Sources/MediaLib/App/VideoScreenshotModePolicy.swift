import MediaLibCore

enum VideoScreenshotModePolicy {
    static func mpvArgument(for mode: VideoScreenshotMode) -> String {
        switch mode {
        case .subtitles: return "subtitles"
        case .video: return "video"
        case .window: return "window"
        }
    }
}
