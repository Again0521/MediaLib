import XCTest
@testable import MediaLib

final class VideoPitchCorrectionPolicyTests: XCTestCase {
    func testEnabledPitchCorrectionMatchesExistingMpvFlag() {
        XCTAssertEqual(
            VideoPitchCorrectionPolicy.property(enabled: true),
            VideoPitchCorrectionProperty(name: "audio-pitch-correction", enabled: true)
        )
    }

    func testDisabledPitchCorrectionMatchesExistingMpvFlag() {
        XCTAssertEqual(
            VideoPitchCorrectionPolicy.property(enabled: false),
            VideoPitchCorrectionProperty(name: "audio-pitch-correction", enabled: false)
        )
    }
}
