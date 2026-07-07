import XCTest
import Foundation
@testable import MediaLibCore

final class VideoSmartCollectionRepositoryAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoSmartCollectionRepoAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("smart_collection_audit.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    func testFetchAllPreservesValidRulesWhenRulesJSONContainsUnknownEnumValues() throws {
        let db = try DatabaseManager(url: dbURL)
        let repo = VideoSmartCollectionRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_234_567)
        let rulesJSON = """
        {
          "matchMode": "future-mode",
          "year": "since2020",
          "providerRating": "future-rating",
          "userRating": "rated",
          "genreKeyword": "  悬疑  ",
          "source": "emby"
        }
        """
        try db.execute(
            """
            INSERT INTO video_smart_collections (
              id, name, media_scope, state_filter, recency_days, rules_json, show_on_home, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text("smart-invalid-enum"),
                .text("未来规则兼容"),
                .text(VideoSmartCollectionMediaScope.movies.rawValue),
                .text(VideoSmartCollectionStateFilter.any.rawValue),
                .int(Int64(VideoSmartCollectionRecency.anytime.rawValue)),
                .text(rulesJSON),
                .bool(true),
                .optionalDate(now),
                .optionalDate(now)
            ]
        )

        let collection = try XCTUnwrap(try repo.fetchAll().first { $0.id == "smart-invalid-enum" })

        XCTAssertEqual(collection.rules.matchMode, .all)
        XCTAssertEqual(collection.rules.year, .since2020)
        XCTAssertEqual(collection.rules.providerRating, .any)
        XCTAssertEqual(collection.rules.userRating, .rated)
        XCTAssertEqual(collection.rules.genreKeyword, "悬疑")
        XCTAssertEqual(collection.rules.source, .emby)
        XCTAssertTrue(collection.showOnHome)
    }

    func testFetchAllFallsBackToDefaultRulesForMalformedRulesJSON() throws {
        let db = try DatabaseManager(url: dbURL)
        let repo = VideoSmartCollectionRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_234_568)
        try db.execute(
            """
            INSERT INTO video_smart_collections (
              id, name, media_scope, state_filter, recency_days, rules_json, show_on_home, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text("smart-malformed-json"),
                .text("损坏规则兼容"),
                .text(VideoSmartCollectionMediaScope.all.rawValue),
                .text(VideoSmartCollectionStateFilter.any.rawValue),
                .int(Int64(VideoSmartCollectionRecency.anytime.rawValue)),
                .text("{\"matchMode\":"),
                .bool(false),
                .optionalDate(now),
                .optionalDate(now)
            ]
        )

        let collection = try XCTUnwrap(try repo.fetchAll().first { $0.id == "smart-malformed-json" })

        XCTAssertEqual(collection.rules, VideoSmartCollectionRules())
    }
}
