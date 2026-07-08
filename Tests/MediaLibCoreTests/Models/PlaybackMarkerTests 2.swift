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

    func testDecoderDefaultsOnlyUnknownEnumFieldsAndKeepsValidMarkerData() throws {
        let json = """
        {
          "id": "marker-1",
          "mediaID": "episode-1",
          "kind": "future-marker-kind",
          "title": "Known Title",
          "startTime": 12.5,
          "endTime": 34.75,
          "origin": "imported-by-future-version",
          "reviewStatus": "needs-second-review",
          "detectorIdentifier": "detector-v2",
          "confidence": 0.82,
          "createdAt": 1000,
          "updatedAt": 2000
        }
        """.data(using: .utf8)!

        let marker = try JSONDecoder().decode(PlaybackMarker.self, from: json)

        XCTAssertEqual(marker.id, "marker-1")
        XCTAssertEqual(marker.mediaID, "episode-1")
        XCTAssertEqual(marker.kind, .chapter)
        XCTAssertEqual(marker.title, "Known Title")
        XCTAssertEqual(marker.startTime, 12.5)
        XCTAssertEqual(marker.endTime, 34.75)
        XCTAssertEqual(marker.origin, .manual)
        XCTAssertEqual(marker.reviewStatus, .accepted)
        XCTAssertEqual(marker.detectorIdentifier, "detector-v2")
        XCTAssertEqual(marker.confidence, 0.82)
        XCTAssertEqual(marker.createdAt, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(marker.updatedAt, Date(timeIntervalSinceReferenceDate: 2000))
    }

    func testDecoderNormalizesNumericFieldsAndUsesKindTitleFallback() throws {
        let json = """
        {
          "mediaID": "episode-2",
          "kind": "intro",
          "startTime": -10,
          "endTime": -1,
          "origin": "automatic",
          "reviewStatus": "pending",
          "confidence": 2
        }
        """.data(using: .utf8)!

        let marker = try JSONDecoder().decode(PlaybackMarker.self, from: json)

        XCTAssertFalse(marker.id.isEmpty)
        XCTAssertEqual(marker.mediaID, "episode-2")
        XCTAssertEqual(marker.kind, .intro)
        XCTAssertEqual(marker.title, "片头")
        XCTAssertEqual(marker.startTime, 0)
        XCTAssertEqual(marker.endTime, 0)
        XCTAssertEqual(marker.origin, .automatic)
        XCTAssertEqual(marker.reviewStatus, .pending)
        XCTAssertEqual(marker.confidence, 1)
        XCTAssertTrue(marker.isPendingReview)
    }
}
