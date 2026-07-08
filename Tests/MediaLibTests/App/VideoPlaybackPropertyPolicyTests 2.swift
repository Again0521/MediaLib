import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoPlaybackPropertyPolicyTests: XCTestCase {
    func testAspectOverrideValuesMatchExistingMpvValues() {
        XCTAssertEqual(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: .source), "no")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: .square), "1:1")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: .fourByThree), "4:3")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: .sixteenByNine), "16:9")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: .sixteenByTen), "16:10")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: .twentyOneByNine), "21:9")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: .cinemaScope), "2.39:1")
    }

    func testCropPanscanValuesMatchExistingMpvValues() {
        XCTAssertEqual(VideoPlaybackPropertyPolicy.panscanValue(for: .none), 0)
        XCTAssertEqual(VideoPlaybackPropertyPolicy.panscanValue(for: .gentle), 0.18)
        XCTAssertEqual(VideoPlaybackPropertyPolicy.panscanValue(for: .balanced), 0.42)
        XCTAssertEqual(VideoPlaybackPropertyPolicy.panscanValue(for: .fill), 1)
    }

    func testDeinterlaceValuesMatchExistingMpvValues() {
        XCTAssertEqual(VideoPlaybackPropertyPolicy.deinterlaceValue(for: .off), "no")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.deinterlaceValue(for: .auto), "auto")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.deinterlaceValue(for: .on), "yes")
    }

    func testRotationValuesPreserveSourceMetadataBehavior() {
        XCTAssertEqual(VideoPlaybackPropertyPolicy.rotationValue(for: .source), "0")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.rotationValue(for: .clockwise90), "90")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.rotationValue(for: .rotate180), "180")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.rotationValue(for: .counterclockwise90), "270")
    }

    func testHardwareDecodingValuesMatchExistingMpvValues() {
        XCTAssertEqual(VideoPlaybackPropertyPolicy.hardwareDecodingValue(for: .safe), "auto-safe")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.hardwareDecodingValue(for: .automatic), "auto")
        XCTAssertEqual(VideoPlaybackPropertyPolicy.hardwareDecodingValue(for: .off), "no")
    }

    func testPlaybackPropertiesMatchExistingMpvPropertyOrderNamesAndValues() {
        XCTAssertEqual(
            VideoPlaybackPropertyPolicy.playbackProperties(
                aspectOverride: .sixteenByNine,
                cropMode: .balanced,
                deinterlaceMode: .on,
                rotationMode: .clockwise90,
                hardwareDecodingMode: .automatic
            ),
            [
                .string(VideoPlaybackStringProperty(name: "video-aspect-override", value: "16:9")),
                .double(VideoPlaybackDoubleProperty(name: "panscan", value: 0.42)),
                .string(VideoPlaybackStringProperty(name: "deinterlace", value: "yes")),
                .string(VideoPlaybackStringProperty(name: "video-rotate", value: "90")),
                .string(VideoPlaybackStringProperty(name: "hwdec", value: "auto")),
            ]
        )
    }

    func testIndividualPropertiesKeepExistingMpvNamesAndValues() {
        XCTAssertEqual(
            VideoPlaybackPropertyPolicy.aspectOverrideProperty(for: .source),
            VideoPlaybackStringProperty(name: "video-aspect-override", value: "no")
        )
        XCTAssertEqual(
            VideoPlaybackPropertyPolicy.cropPanscanProperty(for: .fill),
            VideoPlaybackDoubleProperty(name: "panscan", value: 1)
        )
        XCTAssertEqual(
            VideoPlaybackPropertyPolicy.deinterlaceProperty(for: .auto),
            VideoPlaybackStringProperty(name: "deinterlace", value: "auto")
        )
        XCTAssertEqual(
            VideoPlaybackPropertyPolicy.rotationProperty(for: .source),
            VideoPlaybackStringProperty(name: "video-rotate", value: "0")
        )
        XCTAssertEqual(
            VideoPlaybackPropertyPolicy.hardwareDecodingProperty(for: .safe),
            VideoPlaybackStringProperty(name: "hwdec", value: "auto-safe")
        )
    }

    func testAllStringPropertiesProduceNonEmptyValues() {
        for mode in VideoAspectOverride.allCases {
            XCTAssertFalse(VideoPlaybackPropertyPolicy.aspectOverrideValue(for: mode).isEmpty)
        }
        for mode in VideoDeinterlaceMode.allCases {
            XCTAssertFalse(VideoPlaybackPropertyPolicy.deinterlaceValue(for: mode).isEmpty)
        }
        for mode in VideoRotationMode.allCases {
            XCTAssertFalse(VideoPlaybackPropertyPolicy.rotationValue(for: mode).isEmpty)
        }
        for mode in VideoHardwareDecodingMode.allCases {
            XCTAssertFalse(VideoPlaybackPropertyPolicy.hardwareDecodingValue(for: mode).isEmpty)
        }
    }
}
