import Foundation

@MainActor
protocol MpvCommandTransport: AnyObject {
    func command(_ arguments: [String]) throws
    func setFlag(_ name: String, _ value: Bool)
    func setDouble(_ name: String, _ value: Double)
    func stopPlayback()
}

extension LibMpvClient: MpvCommandTransport {}

enum VideoPlaybackSeekPrecision {
    case exact
    case keyframes

    var mpvArgument: String {
        switch self {
        case .exact:
            return "exact"
        case .keyframes:
            return "keyframes"
        }
    }
}

@MainActor
protocol VideoPlaybackEngine: AnyObject {
    func loadFile(_ path: String) throws
    func loadReplacing(path: String, startTime: Double?) throws
    func seek(toMpvTime time: Double, precision: VideoPlaybackSeekPrecision) throws
    func setPaused(_ paused: Bool)
    func setVolume(_ volume: Float, boost: Double)
    func setPlaybackRate(_ rate: Float)
    func stopPlayback()
}

@MainActor
final class MpvVideoPlaybackEngine: VideoPlaybackEngine {
    private let transport: MpvCommandTransport

    init(transport: MpvCommandTransport) {
        self.transport = transport
    }

    func loadFile(_ path: String) throws {
        try transport.command(["loadfile", path])
    }

    func loadReplacing(path: String, startTime: Double?) throws {
        var command = ["loadfile", path, "replace"]
        if let startTime {
            command.append("start=\(String(format: "%.3f", startTime))")
        }
        try transport.command(command)
    }

    func seek(toMpvTime time: Double, precision: VideoPlaybackSeekPrecision = .exact) throws {
        try transport.command(["seek", "\(time)", "absolute", precision.mpvArgument])
    }

    func setPaused(_ paused: Bool) {
        transport.setFlag("pause", paused)
    }

    func setVolume(_ volume: Float, boost: Double) {
        transport.setDouble("volume", Double(volume * 100) * boost)
    }

    func setPlaybackRate(_ rate: Float) {
        transport.setDouble("speed", Double(rate))
    }

    func stopPlayback() {
        transport.stopPlayback()
    }
}
