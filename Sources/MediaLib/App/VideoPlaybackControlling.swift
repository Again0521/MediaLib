import Foundation

@MainActor
protocol VideoPlaybackControlling: AnyObject {
    func togglePlay()
    func seek(by seconds: Double)
    func seek(to seconds: Double)
    func toggleFullscreen()
    func switchVideoQuality(to option: VideoStreamQualityOption)
}

extension MpvPlayerController: VideoPlaybackControlling {}
