import XCTest
@testable import MediaLib

@MainActor
final class VideoAudioDeviceReaderTests: XCTestCase {
    func testSnapshotReadsSelectedDeviceAndParsesDeviceList() {
        let transport = FakeAudioDeviceReadTransport()
        transport.strings["audio-device"] = "coreaudio/headphones"
        transport.strings["audio-device-list"] = """
        [
          {"name": "coreaudio/default", "description": "System Default"},
          {"name": "coreaudio/headphones", "description": "Headphones"},
          {"description": "Missing name is ignored"},
          {"name": "coreaudio/nameless"}
        ]
        """
        let reader = MpvVideoAudioDeviceReader(transport: transport)

        let snapshot = reader.readSnapshot()

        XCTAssertEqual(snapshot.selectedDeviceName, "coreaudio/headphones")
        XCTAssertEqual(
            snapshot.devices,
            [
                MpvAudioDevice(name: "coreaudio/default", deviceDescription: "System Default"),
                MpvAudioDevice(name: "coreaudio/headphones", deviceDescription: "Headphones"),
                MpvAudioDevice(name: "coreaudio/nameless", deviceDescription: "")
            ]
        )
    }

    func testSnapshotDefaultsSelectedDeviceAndReturnsEmptyDevicesForInvalidList() {
        let transport = FakeAudioDeviceReadTransport()
        transport.strings["audio-device-list"] = "{not valid json"
        let reader = MpvVideoAudioDeviceReader(transport: transport)

        let snapshot = reader.readSnapshot()

        XCTAssertEqual(snapshot.selectedDeviceName, "auto")
        XCTAssertEqual(snapshot.devices, [])
    }

    func testParserRejectsNonArrayOrMissingDeviceList() {
        XCTAssertEqual(MpvVideoAudioDeviceReader.parseDeviceListJSON(nil), [])
        XCTAssertEqual(MpvVideoAudioDeviceReader.parseDeviceListJSON(#"{"name":"coreaudio/default"}"#), [])
    }
}

@MainActor
private final class FakeAudioDeviceReadTransport: MpvAudioDeviceReadTransport {
    var strings: [String: String] = [:]

    func getString(_ name: String) -> String? {
        strings[name]
    }
}
