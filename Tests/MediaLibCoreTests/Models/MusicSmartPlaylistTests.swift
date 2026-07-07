import XCTest
@testable import MediaLibCore

final class MusicSmartPlaylistTests: XCTestCase {
    func testDecoderDefaultsUnknownRuleEnumsAndKeepsValidFields() throws {
        let json = """
        {
          "id": "smart-1",
          "name": "  Road Mix  ",
          "filter": "future-filter",
          "recency": 365,
          "sort": "future-sort",
          "limit": 999,
          "createdAt": 1000,
          "updatedAt": 2000
        }
        """.data(using: .utf8)!

        let playlist = try JSONDecoder().decode(MusicSmartPlaylist.self, from: json)

        XCTAssertEqual(playlist.id, "smart-1")
        XCTAssertEqual(playlist.name, "Road Mix")
        XCTAssertEqual(playlist.filter, .any)
        XCTAssertEqual(playlist.recency, .anytime)
        XCTAssertEqual(playlist.sort, .dateAddedDesc)
        XCTAssertEqual(playlist.limit, .unlimited)
        XCTAssertEqual(playlist.createdAt, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(playlist.updatedAt, Date(timeIntervalSinceReferenceDate: 2000))
        XCTAssertEqual(playlist.ruleSummary, "全部 · 按最近加入")
    }

    func testDecoderPreservesKnownRulesAndFallsBackBlankName() throws {
        let json = """
        {
          "name": " \\n\\t ",
          "filter": "favorites",
          "recency": 30,
          "sort": "artistAsc",
          "limit": 50
        }
        """.data(using: .utf8)!

        let playlist = try JSONDecoder().decode(MusicSmartPlaylist.self, from: json)

        XCTAssertFalse(playlist.id.isEmpty)
        XCTAssertEqual(playlist.name, "智能歌单")
        XCTAssertEqual(playlist.filter, .favorites)
        XCTAssertEqual(playlist.recency, .thirtyDays)
        XCTAssertEqual(playlist.sort, .artistAsc)
        XCTAssertEqual(playlist.limit, .fifty)
        XCTAssertEqual(playlist.ruleSummary, "喜欢 · 最近 30 天 · 按艺术家 · 前 50 首")
    }
}
