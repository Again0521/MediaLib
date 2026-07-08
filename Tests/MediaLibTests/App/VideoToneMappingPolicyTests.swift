import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoToneMappingPolicyTests: XCTestCase {
    func testToneMappingValuesMatchExistingMpvValues() {
        XCTAssertEqual(VideoToneMappingPolicy.mpvValue(for: .auto), "auto")
        XCTAssertEqual(VideoToneMappingPolicy.mpvValue(for: .bt2390), "bt.2390")
        XCTAssertEqual(VideoToneMappingPolicy.mpvValue(for: .hable), "hable")
        XCTAssertEqual(VideoToneMappingPolicy.mpvValue(for: .mobius), "mobius")
        XCTAssertEqual(VideoToneMappingPolicy.mpvValue(for: .reinhard), "reinhard")
        XCTAssertEqual(VideoToneMappingPolicy.mpvValue(for: .clip), "clip")
    }

    func testToneMappingPropertiesMatchExistingMpvNameAndValues() {
        XCTAssertEqual(VideoToneMappingPolicy.property(for: .auto), VideoToneMappingProperty(name: "tone-mapping", value: "auto"))
        XCTAssertEqual(VideoToneMappingPolicy.property(for: .bt2390), VideoToneMappingProperty(name: "tone-mapping", value: "bt.2390"))
        XCTAssertEqual(VideoToneMappingPolicy.property(for: .hable), VideoToneMappingProperty(name: "tone-mapping", value: "hable"))
        XCTAssertEqual(VideoToneMappingPolicy.property(for: .mobius), VideoToneMappingProperty(name: "tone-mapping", value: "mobius"))
        XCTAssertEqual(VideoToneMappingPolicy.property(for: .reinhard), VideoToneMappingProperty(name: "tone-mapping", value: "reinhard"))
        XCTAssertEqual(VideoToneMappingPolicy.property(for: .clip), VideoToneMappingProperty(name: "tone-mapping", value: "clip"))
    }

    func testAllToneMappingModesProduceNonEmptyMpvValues() {
        for mode in VideoToneMappingMode.allCases {
            XCTAssertFalse(VideoToneMappingPolicy.mpvValue(for: mode).isEmpty)
        }
    }
}
