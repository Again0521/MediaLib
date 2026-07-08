import XCTest
@testable import MediaLibCore

final class VideoOfflineSubscriptionTests: XCTestCase {
    func testDecoderDefaultsUnknownEnumsAndKeepsValidFields() throws {
        let json = """
        {
          "id": "sub-future",
          "seriesID": "series-1",
          "seriesTitle": "Future Show",
          "mode": "queuedSeason",
          "episodeLimit": 250,
          "seasonNumber": 1000,
          "qualityID": "  height-1080  ",
          "enabled": true,
          "pausedUntil": 3000,
          "expiresAt": 4000,
          "networkPolicy": "meteredOnly",
          "createdAt": 1000,
          "updatedAt": 2000
        }
        """.data(using: .utf8)!

        let subscription = try JSONDecoder().decode(VideoOfflineSubscription.self, from: json)

        XCTAssertEqual(subscription.id, "sub-future")
        XCTAssertEqual(subscription.seriesID, "series-1")
        XCTAssertEqual(subscription.seriesTitle, "Future Show")
        XCTAssertEqual(subscription.mode, .nextEpisode)
        XCTAssertEqual(subscription.episodeLimit, 99)
        XCTAssertEqual(subscription.seasonNumber, 999)
        XCTAssertEqual(subscription.qualityID, "height-1080")
        XCTAssertTrue(subscription.enabled)
        XCTAssertEqual(subscription.pausedUntil, Date(timeIntervalSinceReferenceDate: 3000))
        XCTAssertEqual(subscription.expiresAt, Date(timeIntervalSinceReferenceDate: 4000))
        XCTAssertEqual(subscription.networkPolicy, .allowRemote)
        XCTAssertEqual(subscription.createdAt, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(subscription.updatedAt, Date(timeIntervalSinceReferenceDate: 2000))
        XCTAssertEqual(subscription.displayName, "自动缓存下一集")
    }

    func testDecoderPreservesKnownEnumsAndAppliesInitializerDefaults() throws {
        let json = """
        {
          "seriesID": "series-2",
          "seriesTitle": " \\n\\t ",
          "mode": "season",
          "episodeLimit": 0,
          "seasonNumber": 2,
          "qualityID": " \\n\\t ",
          "enabled": false,
          "networkPolicy": "wifiOnly"
        }
        """.data(using: .utf8)!

        let subscription = try JSONDecoder().decode(VideoOfflineSubscription.self, from: json)

        XCTAssertFalse(subscription.id.isEmpty)
        XCTAssertEqual(subscription.seriesID, "series-2")
        XCTAssertEqual(subscription.seriesTitle, "未命名系列")
        XCTAssertEqual(subscription.mode, .season)
        XCTAssertEqual(subscription.episodeLimit, 1)
        XCTAssertEqual(subscription.seasonNumber, 2)
        XCTAssertNil(subscription.qualityID)
        XCTAssertFalse(subscription.enabled)
        XCTAssertEqual(subscription.networkPolicy, .wifiOnly)
        XCTAssertEqual(subscription.compactDisplayName, "第 2 季")
        XCTAssertFalse(subscription.isRunnable)
    }
}
