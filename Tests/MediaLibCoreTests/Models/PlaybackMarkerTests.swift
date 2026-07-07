import XCTest
@testable import MediaLibCore

final class PlaybackMarkerTests: XCTestCase {
    func testInitializerNormalizesNegativeTimesAndClampsConfidence() {
        let marker = PlaybackMarker(
            mediaID: "episode",
            kind: .intro,
            title: "Intro",
            startTime: -12,
            endTime: -1,
            confidence: 1.5
        )

        XCTAssertEqual(marker.startTime, 0)
        XCTAssertEqual(marker.endTime, 0)
        XCTAssertEqual(marker.confidence, 1)
        XCTAssertFalse(marker.isCompleteRange)
    }

    func testInitializerDropsNonFiniteEndTimeAndConfidence() {
        for value in [Double.nan, .infinity, -.infinity] {
            let marker = PlaybackMarker(
                mediaID: "episode-\(value)",
                kind: .credits,
                title: "Credits",
                startTime: value,
                endTime: value,
                confidence: value
            )

            XCTAssertEqual(marker.startTime, 0)
            XCTAssertNil(marker.endTime)
            XCTAssertNil(marker.confidence)
            XCTAssertFalse(marker.isCompleteRange)
        }
    }

    func testContainsRejectsNonFiniteProbeTimes() {
        let marker = PlaybackMarker(
            mediaID: "episode",
            kind: .intro,
            title: "Intro",
            startTime: 10,
            endTime: 20
        )

        XCTAssertTrue(marker.contains(10))
        XCTAssertTrue(marker.contains(19.99))
        XCTAssertFalse(marker.contains(20))
        XCTAssertFalse(marker.contains(.nan))
        XCTAssertFalse(marker.contains(.infinity))
        XCTAssertFalse(marker.contains(-.infinity))
    }
}
