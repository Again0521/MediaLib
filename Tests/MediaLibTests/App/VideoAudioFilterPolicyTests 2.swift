import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoAudioFilterPolicyTests: XCTestCase {
    func testFilterIsEmptyWhenEqualizerIsDisabled() {
        XCTAssertEqual(
            VideoAudioFilterPolicy.filter(enabled: false, preset: .rock),
            ""
        )
    }

    func testFilterIsEmptyForFlatPresetEvenWhenEnabled() {
        XCTAssertEqual(
            VideoAudioFilterPolicy.filter(enabled: true, preset: .flat),
            ""
        )
    }

    func testFilterBuildsExistingFiveBandFirequalizerString() {
        XCTAssertEqual(
            VideoAudioFilterPolicy.filter(enabled: true, preset: .rock),
            "lavfi=[firequalizer=gain_entry='entry(60,4.0);entry(230,2.0);entry(910,-1.0);entry(3600,2.0);entry(14000,4.0)']"
        )
    }

    func testPropertyUsesExistingAfNameAndFilterValue() {
        XCTAssertEqual(
            VideoAudioFilterPolicy.property(enabled: true, preset: .rock),
            VideoAudioFilterProperty(
                name: "af",
                value: "lavfi=[firequalizer=gain_entry='entry(60,4.0);entry(230,2.0);entry(910,-1.0);entry(3600,2.0);entry(14000,4.0)']"
            )
        )
    }

    func testPropertyWritesEmptyStringWhenEqualizerIsDisabled() {
        XCTAssertEqual(
            VideoAudioFilterPolicy.property(enabled: false, preset: .rock),
            VideoAudioFilterProperty(name: "af", value: "")
        )
    }

    func testAllNonFlatPresetsProduceFiveEntries() {
        for preset in MusicEqualizerPreset.allCases where !preset.isFlat {
            let filter = VideoAudioFilterPolicy.filter(enabled: true, preset: preset)

            XCTAssertTrue(filter.hasPrefix("lavfi=[firequalizer=gain_entry='"))
            XCTAssertTrue(filter.hasSuffix("']"))
            XCTAssertEqual(filter.components(separatedBy: "entry(").count - 1, 5)
            XCTAssertFalse(filter.contains("nan"))
            XCTAssertFalse(filter.contains("inf"))
        }
    }
}
