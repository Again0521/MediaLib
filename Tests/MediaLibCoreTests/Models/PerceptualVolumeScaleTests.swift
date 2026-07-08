import XCTest
@testable import MediaLibCore

final class PerceptualVolumeScaleTests: XCTestCase {
    func testSliderValueKeepsCurrentLinearMappingAndClampsBounds() {
        XCTAssertEqual(PerceptualVolumeScale.sliderValue(fromLinear: 0.42), 0.42, accuracy: 0.0001)
        XCTAssertEqual(PerceptualVolumeScale.sliderValue(fromLinear: -0.3), 0, accuracy: 0.0001)
        XCTAssertEqual(PerceptualVolumeScale.sliderValue(fromLinear: 1.4), 1, accuracy: 0.0001)
    }

    func testLinearVolumeKeepsCurrentLinearMappingAndClampsBounds() {
        XCTAssertEqual(PerceptualVolumeScale.linearVolume(fromSlider: 0.68), 0.68, accuracy: 0.0001)
        XCTAssertEqual(PerceptualVolumeScale.linearVolume(fromSlider: -0.2), 0, accuracy: 0.0001)
        XCTAssertEqual(PerceptualVolumeScale.linearVolume(fromSlider: 1.2), 1, accuracy: 0.0001)
    }

    func testAdjustedVolumeUsesExistingSliderStepAndDirection() {
        XCTAssertEqual(
            PerceptualVolumeScale.adjustedVolume(0.5, direction: 1),
            0.555,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PerceptualVolumeScale.adjustedVolume(0.5, direction: -1),
            0.445,
            accuracy: 0.0001
        )
    }

    func testAdjustedVolumeClampsAtLinearVolumeBounds() {
        XCTAssertEqual(
            PerceptualVolumeScale.adjustedVolume(0.98, direction: 1),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PerceptualVolumeScale.adjustedVolume(0.02, direction: -1),
            0,
            accuracy: 0.0001
        )
    }

    func testAdjustedVolumeHonorsCustomSliderStep() {
        XCTAssertEqual(
            PerceptualVolumeScale.adjustedVolume(0.5, direction: 1, sliderStep: 0.1),
            0.6,
            accuracy: 0.0001
        )
    }
}
