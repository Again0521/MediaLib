import Foundation

@MainActor
protocol MpvTrackSelectionTransport: AnyObject {
    func command(_ arguments: [String]) throws
    func getFlag(_ name: String) -> Bool?
    func setFlag(_ name: String, _ value: Bool)
    func setString(_ name: String, _ value: String)
}

extension LibMpvClient: MpvTrackSelectionTransport {}

@MainActor
protocol VideoTrackSelectionEngine: AnyObject {
    func enableAutoSubtitle()
    func disableSubtitle()
    func toggleSubtitleVisibility()
    func cycleSubtitle()
    func addExternalSubtitle(path: String)
    func selectSubtitleTrack(_ id: Int)
    func selectSecondarySubtitleTrack(_ id: Int?)
    func cycleAudioTrack()
    func selectDefaultAudioTrack()
    func selectAudioTrack(_ id: Int)
    func selectAudioDevice(_ name: String)
}

@MainActor
final class MpvVideoTrackSelectionEngine: VideoTrackSelectionEngine {
    private let transport: MpvTrackSelectionTransport

    init(transport: MpvTrackSelectionTransport) {
        self.transport = transport
    }

    func enableAutoSubtitle() {
        try? transport.command(["set", "sub-auto", "fuzzy"])
        try? transport.command(["rescan_external_files"])
        try? transport.command(["set", "sub-visibility", "yes"])
    }

    func disableSubtitle() {
        try? transport.command(["set", "sub-visibility", "no"])
        try? transport.command(["set", "sid", "no"])
    }

    func toggleSubtitleVisibility() {
        let visible = transport.getFlag("sub-visibility") ?? true
        transport.setFlag("sub-visibility", !visible)
    }

    func cycleSubtitle() {
        try? transport.command(["set", "sub-visibility", "yes"])
        try? transport.command(["cycle", "sub"])
    }

    func addExternalSubtitle(path: String) {
        try? transport.command(["sub-add", path, "select"])
        try? transport.command(["set", "sub-visibility", "yes"])
    }

    func selectSubtitleTrack(_ id: Int) {
        try? transport.command(["set", "sid", "\(id)"])
        try? transport.command(["set", "sub-visibility", "yes"])
    }

    func selectSecondarySubtitleTrack(_ id: Int?) {
        if let id {
            try? transport.command(["set", "secondary-sid", "\(id)"])
            try? transport.command(["set", "secondary-sub-visibility", "yes"])
        } else {
            try? transport.command(["set", "secondary-sid", "no"])
        }
    }

    func cycleAudioTrack() {
        try? transport.command(["cycle", "audio"])
    }

    func selectDefaultAudioTrack() {
        try? transport.command(["set", "aid", "auto"])
    }

    func selectAudioTrack(_ id: Int) {
        try? transport.command(["set", "aid", "\(id)"])
    }

    func selectAudioDevice(_ name: String) {
        transport.setString("audio-device", name)
    }
}
