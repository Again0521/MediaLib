import XCTest
@testable import MediaLib

@MainActor
final class VideoTrackSelectionEngineTests: XCTestCase {
    func testSubtitleCommandsMapToMpvArguments() {
        let transport = FakeTrackSelectionTransport()
        let engine = MpvVideoTrackSelectionEngine(transport: transport)

        engine.enableAutoSubtitle()
        engine.disableSubtitle()
        engine.cycleSubtitle()
        engine.addExternalSubtitle(path: "/subs/movie.zh.srt")
        engine.selectSubtitleTrack(7)

        XCTAssertEqual(
            transport.commands,
            [
                ["set", "sub-auto", "fuzzy"],
                ["rescan_external_files"],
                ["set", "sub-visibility", "yes"],
                ["set", "sub-visibility", "no"],
                ["set", "sid", "no"],
                ["set", "sub-visibility", "yes"],
                ["cycle", "sub"],
                ["sub-add", "/subs/movie.zh.srt", "select"],
                ["set", "sub-visibility", "yes"],
                ["set", "sid", "7"],
                ["set", "sub-visibility", "yes"]
            ]
        )
    }

    func testSubtitleVisibilityTogglesFromCurrentMpvFlag() {
        let transport = FakeTrackSelectionTransport()
        let engine = MpvVideoTrackSelectionEngine(transport: transport)

        transport.flags["sub-visibility"] = true
        engine.toggleSubtitleVisibility()
        transport.flags["sub-visibility"] = nil
        engine.toggleSubtitleVisibility()

        XCTAssertEqual(
            transport.setFlags,
            [
                RecordedTrackFlag(name: "sub-visibility", value: false),
                RecordedTrackFlag(name: "sub-visibility", value: false)
            ]
        )
    }

    func testSecondarySubtitleCommandsMapOnAndOffStates() {
        let transport = FakeTrackSelectionTransport()
        let engine = MpvVideoTrackSelectionEngine(transport: transport)

        engine.selectSecondarySubtitleTrack(11)
        engine.selectSecondarySubtitleTrack(nil)

        XCTAssertEqual(
            transport.commands,
            [
                ["set", "secondary-sid", "11"],
                ["set", "secondary-sub-visibility", "yes"],
                ["set", "secondary-sid", "no"]
            ]
        )
    }

    func testAudioTrackAndDeviceCommandsStayNarrow() {
        let transport = FakeTrackSelectionTransport()
        let engine = MpvVideoTrackSelectionEngine(transport: transport)

        engine.cycleAudioTrack()
        engine.selectDefaultAudioTrack()
        engine.selectAudioTrack(3)
        engine.selectAudioDevice("coreaudio/default")

        XCTAssertEqual(
            transport.commands,
            [
                ["cycle", "audio"],
                ["set", "aid", "auto"],
                ["set", "aid", "3"]
            ]
        )
        XCTAssertEqual(
            transport.setStrings,
            [RecordedTrackString(name: "audio-device", value: "coreaudio/default")]
        )
    }
}

@MainActor
private final class FakeTrackSelectionTransport: MpvTrackSelectionTransport {
    var commands: [[String]] = []
    var flags: [String: Bool] = [:]
    var setFlags: [RecordedTrackFlag] = []
    var setStrings: [RecordedTrackString] = []

    func command(_ arguments: [String]) throws {
        commands.append(arguments)
    }

    func getFlag(_ name: String) -> Bool? {
        flags[name]
    }

    func setFlag(_ name: String, _ value: Bool) {
        setFlags.append(RecordedTrackFlag(name: name, value: value))
    }

    func setString(_ name: String, _ value: String) {
        setStrings.append(RecordedTrackString(name: name, value: value))
    }
}

private struct RecordedTrackFlag: Equatable {
    let name: String
    let value: Bool
}

private struct RecordedTrackString: Equatable {
    let name: String
    let value: String
}
