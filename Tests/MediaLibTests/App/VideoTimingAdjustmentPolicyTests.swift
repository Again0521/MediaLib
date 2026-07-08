import XCTest
@testable import MediaLib

final class VideoTimingAdjustmentPolicyTests: XCTestCase {
    func testTimingAdjustmentPropertiesMatchExistingMpvPropertyOrderAndValues() {
        XCTAssertEqual(
            VideoTimingAdjustmentPolicy.properties(
                audioDelay: 1.25,
                subtitleDelay: -0.75,
                subtitleScale: 1.3,
                subtitlePosition: 92
            ),
            [
                VideoTimingAdjustmentProperty(name: "audio-delay", value: 1.25),
                VideoTimingAdjustmentProperty(name: "sub-delay", value: -0.75),
                VideoTimingAdjustmentProperty(name: "sub-scale", value: 1.3),
                VideoTimingAdjustmentProperty(name: "sub-pos", value: 92),
            ]
        )
    }

    func testIndividualPropertiesMatchBulkPropertyNames() {
        let bulk = VideoTimingAdjustmentPolicy.properties(
            audioDelay: 0.1,
            subtitleDelay: 0.2,
            subtitleScale: 0.3,
            subtitlePosition: 0.4
        )

        XCTAssertEqual(bulk[0], VideoTimingAdjustmentPolicy.audioDelayProperty(0.1))
        XCTAssertEqual(bulk[1], VideoTimingAdjustmentPolicy.subtitleDelayProperty(0.2))
        XCTAssertEqual(bulk[2], VideoTimingAdjustmentPolicy.subtitleScaleProperty(0.3))
        XCTAssertEqual(bulk[3], VideoTimingAdjustmentPolicy.subtitlePositionProperty(0.4))
    }

    func testPolicyDoesNotClampValuesOwnedByAppSettings() {
        XCTAssertEqual(
            VideoTimingAdjustmentPolicy.properties(
                audioDelay: 999,
                subtitleDelay: -999,
                subtitleScale: -1,
                subtitlePosition: 200
            ).map(\.value),
            [999, -999, -1, 200]
        )
    }
}
