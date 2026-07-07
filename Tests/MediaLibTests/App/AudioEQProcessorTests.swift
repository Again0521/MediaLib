import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class AudioEQProcessorTests: XCTestCase {
    func testNormalizedGainsPadsShortInputWithZeroes() {
        XCTAssertEqual(
            AudioEQProcessor.normalizedGains([1, -2]),
            [1, -2, 0, 0, 0]
        )
    }

    func testNormalizedGainsTruncatesExtraBandsBeforeSanitizing() {
        XCTAssertEqual(
            AudioEQProcessor.normalizedGains([1, 2, 3, 4, 5, 999]),
            [1, 2, 3, 4, 5]
        )
    }

    func testNormalizedGainsSanitizesNonFiniteAndExtremeValues() {
        XCTAssertEqual(
            AudioEQProcessor.normalizedGains([.nan, .infinity, -.infinity, 99, -99]),
            [0, 0, 0, AudioEQProcessor.gainDBLimit, -AudioEQProcessor.gainDBLimit]
        )
    }

    func testFlatPresetInitializesInactiveProcessor() {
        let processor = AudioEQProcessor(gainsDB: MusicEqualizerPreset.flat.gainsDB)

        let snapshot = processor.snapshot()

        XCTAssertEqual(snapshot.gainsDB, [0, 0, 0, 0, 0])
        XCTAssertFalse(snapshot.hasNonZeroGain)
    }

    func testProcessorInitializesWithSanitizedUnsafeValues() {
        let processor = AudioEQProcessor(gainsDB: [.nan, .infinity, -.infinity, 1_000, -1_000])

        let snapshot = processor.snapshot()

        XCTAssertEqual(snapshot.gainsDB, [0, 0, 0, AudioEQProcessor.gainDBLimit, -AudioEQProcessor.gainDBLimit])
        XCTAssertTrue(snapshot.hasNonZeroGain)
    }

    func testUpdateGainsReplacesStateAndHonorsAudibleThreshold() {
        let processor = AudioEQProcessor(gainsDB: MusicEqualizerPreset.rock.gainsDB)

        processor.updateGains([0.005, -0.005])
        let nearFlat = processor.snapshot()

        XCTAssertEqual(nearFlat.gainsDB, [0.005, -0.005, 0, 0, 0])
        XCTAssertFalse(nearFlat.hasNonZeroGain)

        processor.updateGains([0.011])
        let audible = processor.snapshot()

        XCTAssertEqual(audible.gainsDB, [0.011, 0, 0, 0, 0])
        XCTAssertTrue(audible.hasNonZeroGain)
    }

    func testBuiltInEqualizerPresetsMatchProcessorBandsAndSafeRange() {
        XCTAssertEqual(AudioEQProcessor.bands.count, 5)
        XCTAssertTrue(AudioEQProcessor.bands.allSatisfy { $0.frequency > 0 && $0.q > 0 })

        for preset in MusicEqualizerPreset.allCases {
            XCTAssertEqual(preset.gainsDB.count, AudioEQProcessor.bands.count, "\(preset.rawValue) should define all EQ bands")
            XCTAssertTrue(preset.gainsDB.allSatisfy(\.isFinite), "\(preset.rawValue) should not contain non-finite gains")
            XCTAssertTrue(
                preset.gainsDB.allSatisfy { abs($0) <= AudioEQProcessor.gainDBLimit },
                "\(preset.rawValue) should stay within the processor safety limit"
            )
        }
    }
}
