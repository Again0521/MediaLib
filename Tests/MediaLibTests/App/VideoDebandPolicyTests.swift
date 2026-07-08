import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoDebandPolicyTests: XCTestCase {
    func testOffModeMatchesExistingMpvProperties() {
        XCTAssertEqual(
            VideoDebandPolicy.properties(for: .off),
            VideoDebandProperties(enabled: false, threshold: 64, range: 16, grain: 48)
        )
    }

    func testLightModeMatchesExistingMpvProperties() {
        XCTAssertEqual(
            VideoDebandPolicy.properties(for: .light),
            VideoDebandProperties(enabled: true, threshold: 32, range: 12, grain: 24)
        )
    }

    func testStrongModeMatchesExistingMpvProperties() {
        XCTAssertEqual(
            VideoDebandPolicy.properties(for: .strong),
            VideoDebandProperties(enabled: true, threshold: 48, range: 18, grain: 36)
        )
    }

    func testPlaybackPropertiesMatchExistingMpvPropertyOrderNamesAndValues() {
        XCTAssertEqual(
            VideoDebandPolicy.playbackProperties(for: .light),
            [
                .flag(name: "deband", value: true),
                .double(name: "deband-threshold", value: 32),
                .double(name: "deband-range", value: 12),
                .double(name: "deband-grain", value: 24),
            ]
        )
    }

    func testOffPlaybackPropertiesStillWriteExistingNumericDefaults() {
        XCTAssertEqual(
            VideoDebandPolicy.playbackProperties(for: .off),
            [
                .flag(name: "deband", value: false),
                .double(name: "deband-threshold", value: 64),
                .double(name: "deband-range", value: 16),
                .double(name: "deband-grain", value: 48),
            ]
        )
    }

    func testAllModesProduceFinitePositiveMpvNumbers() {
        for mode in VideoDebandMode.allCases {
            let properties = VideoDebandPolicy.properties(for: mode)

            XCTAssertTrue(properties.threshold.isFinite)
            XCTAssertTrue(properties.range.isFinite)
            XCTAssertTrue(properties.grain.isFinite)
            XCTAssertGreaterThan(properties.threshold, 0)
            XCTAssertGreaterThan(properties.range, 0)
            XCTAssertGreaterThan(properties.grain, 0)
        }
    }
}
