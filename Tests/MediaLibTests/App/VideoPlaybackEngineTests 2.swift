import XCTest
@testable import MediaLib

@MainActor
final class VideoPlaybackEngineTests: XCTestCase {
    func testInitialLoadUsesLoadfileCommand() throws {
        let transport = FakeMpvCommandTransport()
        let engine = MpvVideoPlaybackEngine(transport: transport)

        try engine.loadFile("/media/movie.mkv")

        XCTAssertEqual(transport.commands, [["loadfile", "/media/movie.mkv"]])
    }

    func testReplacingLoadPreservesOptionalStartArgumentFormatting() throws {
        let transport = FakeMpvCommandTransport()
        let engine = MpvVideoPlaybackEngine(transport: transport)

        try engine.loadReplacing(path: "https://example.test/stream.m3u8", startTime: 12)
        try engine.loadReplacing(path: "https://example.test/live.m3u8", startTime: nil)

        XCTAssertEqual(
            transport.commands,
            [
                ["loadfile", "https://example.test/stream.m3u8", "replace", "start=12.000"],
                ["loadfile", "https://example.test/live.m3u8", "replace"]
            ]
        )
    }

    func testSeekMapsPrecisionToMpvArguments() throws {
        let transport = FakeMpvCommandTransport()
        let engine = MpvVideoPlaybackEngine(transport: transport)

        try engine.seek(toMpvTime: 42.5, precision: .exact)
        try engine.seek(toMpvTime: 7, precision: .keyframes)

        XCTAssertEqual(
            transport.commands,
            [
                ["seek", "42.5", "absolute", "exact"],
                ["seek", "7.0", "absolute", "keyframes"]
            ]
        )
    }

    func testPlaybackPropertiesMapToNarrowTransportCalls() {
        let transport = FakeMpvCommandTransport()
        let engine = MpvVideoPlaybackEngine(transport: transport)

        engine.setPaused(true)
        engine.setVolume(0.25, boost: 1.5)
        engine.setPlaybackRate(1.25)
        engine.stopPlayback()

        XCTAssertEqual(transport.flags, [RecordedFlag(name: "pause", value: true)])
        XCTAssertEqual(transport.doubles.count, 2)
        XCTAssertEqual(transport.doubles[0].name, "volume")
        XCTAssertEqual(transport.doubles[0].value, 37.5, accuracy: 0.0001)
        XCTAssertEqual(transport.doubles[1].name, "speed")
        XCTAssertEqual(transport.doubles[1].value, 1.25, accuracy: 0.0001)
        XCTAssertEqual(transport.stopPlaybackCount, 1)
    }
}

@MainActor
private final class FakeMpvCommandTransport: MpvCommandTransport {
    var commands: [[String]] = []
    var flags: [RecordedFlag] = []
    var doubles: [RecordedDouble] = []
    var stopPlaybackCount = 0

    func command(_ arguments: [String]) throws {
        commands.append(arguments)
    }

    func setFlag(_ name: String, _ value: Bool) {
        flags.append(RecordedFlag(name: name, value: value))
    }

    func setDouble(_ name: String, _ value: Double) {
        doubles.append(RecordedDouble(name: name, value: value))
    }

    func stopPlayback() {
        stopPlaybackCount += 1
    }
}

private struct RecordedFlag: Equatable {
    let name: String
    let value: Bool
}

private struct RecordedDouble {
    let name: String
    let value: Double
}
