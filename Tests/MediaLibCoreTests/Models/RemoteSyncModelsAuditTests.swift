import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级远程服务聚合模型与 Trakt 载荷生成专项】
/// 审计目标：验证 `TraktSyncPayloadBuilder` 在聚合海量电影、整部剧集与零散分集条目时，
/// 能否把散落的 `TraktMediaRef` 精确归并去重为符合 Trakt API 规范的层次化 JSON 字典结构；
/// 同时验证 `RemoteConnectorAccount` 和多端同步模型的序列化完整性。
/// 对应报告问题 ID：TC-REMOTE-003
final class RemoteSyncModelsAuditTests: XCTestCase {

    /// 测试 TraktSyncPayloadBuilder 将散乱的电影和分集完美去重归结为标准的 Payload 结构
    func testTraktPayloadBuilderAggregatesMoviesAndEpisodesWithoutDuplicates() {
        let refs: [TraktMediaRef] = [
            .movie(tmdbID: 101),
            .movie(tmdbID: 102),
            .movie(tmdbID: 101), // 重复电影，应当去重
            .show(tmdbID: 200),
            .episode(showTmdbID: 300, season: 1, episode: 1),
            .episode(showTmdbID: 300, season: 1, episode: 2),
            .episode(showTmdbID: 300, season: 2, episode: 5),
            .episode(showTmdbID: 300, season: 1, episode: 1) // 重复剧集，应当去重
        ]
        
        let payload = TraktSyncPayloadBuilder.buildPayload(from: refs)
        
        guard let movies = payload["movies"] as? [[String: Any]],
              let shows = payload["shows"] as? [[String: Any]] else {
            XCTFail("必须生成包含 movies 和 shows 数组的合法 Payload")
            return
        }
        
        XCTAssertEqual(movies.count, 2, "去重后的电影数量必须为 2")
        
        // 验证剧集层级聚合
        guard let show300 = shows.first(where: { ($0["ids"] as? [String: Int])?["tmdb"] == 300 }),
              let seasons = show300["seasons"] as? [[String: Any]] else {
            XCTFail("必须正确提取出剧集 300 及其季/集结构")
            return
        }
        
        XCTAssertEqual(seasons.count, 2, "剧集 300 应包含第 1 季和第 2 季")
        
        guard let s1 = seasons.first(where: { ($0["number"] as? Int) == 1 }),
              let s1Eps = s1["episodes"] as? [[String: Any]] else {
            XCTFail("应该包含第 1 季的集数列表")
            return
        }
        XCTAssertEqual(s1Eps.count, 2, "去重后第 1 季应只有第 1 集和第 2 集")
    }

    /// 测试远程连接提供商展示名称与鉴别
    func testRemoteConnectorProviderDisplayNames() {
        XCTAssertEqual(RemoteConnectorProvider.emby.displayName, "Emby")
        XCTAssertEqual(RemoteConnectorProvider.jellyfin.displayName, "Jellyfin")
        XCTAssertEqual(RemoteConnectorProvider.plex.displayName, "Plex")
        XCTAssertEqual(RemoteConnectorProvider.trakt.displayName, "Trakt")
        XCTAssertEqual(RemoteConnectorProvider.iCloud.displayName, "iCloud")
    }

    func testRemoteConnectorAccountDecoderDefaultsUnknownEnumFieldsAndKeepsData() throws {
        let json = """
        {
          "id": "account-1",
          "provider": "future-provider",
          "accountLabel": "  Imported Account  ",
          "serverURL": "https://media.example.test",
          "username": "user-a",
          "sourceID": "source-1",
          "connectionMode": "future-mode",
          "syncEnabled": true,
          "capabilitiesJSON": "{\\"sync\\":true}",
          "privacyNote": "private-note",
          "createdAt": 100,
          "updatedAt": 200,
          "lastSyncedAt": 300
        }
        """.data(using: .utf8)!

        let account = try JSONDecoder().decode(RemoteConnectorAccount.self, from: json)

        XCTAssertEqual(account.id, "account-1")
        XCTAssertEqual(account.provider, .emby)
        XCTAssertEqual(account.accountLabel, "  Imported Account  ")
        XCTAssertEqual(account.serverURL, "https://media.example.test")
        XCTAssertEqual(account.username, "user-a")
        XCTAssertEqual(account.sourceID, "source-1")
        XCTAssertEqual(account.connectionMode, .library)
        XCTAssertTrue(account.syncEnabled)
        XCTAssertEqual(account.capabilitiesJSON, "{\"sync\":true}")
        XCTAssertEqual(account.privacyNote, "private-note")
        XCTAssertEqual(account.createdAt, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(account.updatedAt, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(account.lastSyncedAt, Date(timeIntervalSinceReferenceDate: 300))
    }

    func testSyncConflictDecoderDefaultsUnknownEnumFieldsAndKeepsData() throws {
        let json = """
        {
          "id": "conflict-1",
          "mediaID": "media-1",
          "profileID": "profile-1",
          "provider": "future-provider",
          "accountID": "account-1",
          "fieldName": "watched",
          "localValue": "false",
          "remoteValue": "true",
          "localUpdatedAt": 10,
          "remoteUpdatedAt": 20,
          "status": "deferred",
          "resolution": "future-resolution",
          "errorMessage": "remote changed",
          "createdAt": 30,
          "updatedAt": 40,
          "resolvedAt": 50
        }
        """.data(using: .utf8)!

        let conflict = try JSONDecoder().decode(SyncConflict.self, from: json)

        XCTAssertEqual(conflict.id, "conflict-1")
        XCTAssertEqual(conflict.mediaID, "media-1")
        XCTAssertEqual(conflict.profileID, "profile-1")
        XCTAssertEqual(conflict.provider, .emby)
        XCTAssertEqual(conflict.accountID, "account-1")
        XCTAssertEqual(conflict.fieldName, "watched")
        XCTAssertEqual(conflict.localValue, "false")
        XCTAssertEqual(conflict.remoteValue, "true")
        XCTAssertEqual(conflict.localUpdatedAt, Date(timeIntervalSinceReferenceDate: 10))
        XCTAssertEqual(conflict.remoteUpdatedAt, Date(timeIntervalSinceReferenceDate: 20))
        XCTAssertEqual(conflict.status, .pending)
        XCTAssertNil(conflict.resolution)
        XCTAssertEqual(conflict.errorMessage, "remote changed")
        XCTAssertEqual(conflict.createdAt, Date(timeIntervalSinceReferenceDate: 30))
        XCTAssertEqual(conflict.updatedAt, Date(timeIntervalSinceReferenceDate: 40))
        XCTAssertEqual(conflict.resolvedAt, Date(timeIntervalSinceReferenceDate: 50))
    }

    func testProfileMediaStateClampsFinitePlaybackValues() {
        let state = ProfileMediaState(
            profileID: "profile",
            mediaID: "media",
            playCount: -3,
            playPosition: -12,
            playProgress: 1.5
        )

        XCTAssertEqual(state.playCount, 0)
        XCTAssertEqual(state.playPosition, 0)
        XCTAssertEqual(state.playProgress, 1)
    }

    func testProfileMediaStateTreatsNonFinitePlaybackValuesAsZero() {
        for value in [Double.nan, .infinity, -.infinity] {
            let state = ProfileMediaState(
                profileID: "profile",
                mediaID: "media-\(value)",
                playPosition: value,
                playProgress: value
            )

            XCTAssertEqual(state.playPosition, 0)
            XCTAssertEqual(state.playProgress, 0)
        }
    }

    func testProfileMediaStateTreatsNonFiniteUserRatingAsNil() {
        for value in [Double.nan, .infinity, -.infinity] {
            let state = ProfileMediaState(
                profileID: "profile",
                mediaID: "rating-\(value)",
                userRating: value
            )

            XCTAssertNil(state.userRating)
        }
    }

    func testProfileMediaStateNormalizesFiniteUserRatingBounds() throws {
        for value in [-1.0, 0, 5.1] {
            let state = ProfileMediaState(
                profileID: "profile",
                mediaID: "rating-\(value)",
                userRating: value
            )

            XCTAssertNil(state.userRating)
        }

        let lowBoundary = ProfileMediaState(
            profileID: "profile",
            mediaID: "rating-low",
            userRating: 0.5
        )
        XCTAssertEqual(try XCTUnwrap(lowBoundary.userRating), 0.5, accuracy: 0.0001)

        let highBoundary = ProfileMediaState(
            profileID: "profile",
            mediaID: "rating-high",
            userRating: 5
        )
        XCTAssertEqual(try XCTUnwrap(highBoundary.userRating), 5, accuracy: 0.0001)
    }
}
