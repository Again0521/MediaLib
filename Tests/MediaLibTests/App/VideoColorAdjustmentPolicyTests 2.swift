import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoColorAdjustmentPolicyTests: XCTestCase {
    func testColorAdjustmentPropertiesMatchExistingMpvPropertyOrderAndValues() {
        let adjustments = VideoColorAdjustments(
            brightness: 12.4,
            contrast: -12.6,
            saturation: 33,
            gamma: -44,
            hue: 55
        )

        XCTAssertEqual(
            VideoColorAdjustmentPolicy.properties(for: adjustments),
            [
                VideoColorAdjustmentProperty(name: "brightness", value: 12),
                VideoColorAdjustmentProperty(name: "contrast", value: -13),
                VideoColorAdjustmentProperty(name: "saturation", value: 33),
                VideoColorAdjustmentProperty(name: "gamma", value: -44),
                VideoColorAdjustmentProperty(name: "hue", value: 55),
            ]
        )
    }

    func testNeutralColorAdjustmentsProduceZeroValuesForEveryProperty() {
        let properties = VideoColorAdjustmentPolicy.properties(for: .neutral)

        XCTAssertEqual(properties.map(\.name), ["brightness", "contrast", "saturation", "gamma", "hue"])
        XCTAssertTrue(properties.allSatisfy { $0.value == 0 })
    }

    func testUnsafeValuesAreClampedBeforePolicyBuildsProperties() {
        let adjustments = VideoColorAdjustments(
            brightness: 500,
            contrast: -500,
            saturation: Double.nan,
            gamma: Double.infinity,
            hue: -100.001
        )

        XCTAssertEqual(
            VideoColorAdjustmentPolicy.properties(for: adjustments).map(\.value),
            [100, -100, 0, 0, -100]
        )
    }
}
