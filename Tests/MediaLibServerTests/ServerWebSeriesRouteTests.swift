import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerWebSeriesRouteTests: XCTestCase {
    private let detail = ServerSeriesDetail(
        id: "series id+1", type: "tvShow", title: "系列 <script>bad()</script>",
        originalTitle: "Original & Series", year: 2026,
        overview: "简介 </style><script>bad()</script>", genres: ["剧情", "科幻"],
        communityRating: 8.8, artworkAvailable: true, backdropAvailable: false,
        totalEpisodeCount: 3,
        seasons: [
            ServerSeriesSeason(id: "season-1", seasonNumber: 1, title: "第 1 季", episodeCount: 2, watchedCount: 1, inProgressCount: 1),
            ServerSeriesSeason(id: "unspecified", seasonNumber: nil, title: "未分季", episodeCount: 1, watchedCount: 0, inProgressCount: 0)
        ],
        userPreference: ServerMediaUserPreference(isFavorite: true, isWatchlist: false, rating: 4.5)
    )

    func testSeriesEpisodeAPIUsesStrictBoundedQueryAndCurrentPrincipal() throws {
        var received: (id: String, season: ServerSeriesSeasonSelector, offset: Int, limit: Int, userID: String)?
        let expected = ServerSeriesEpisodesPage(
            totalItemCount: 2, offset: 0, limit: 50,
            items: [ServerSeriesEpisode(
                id: "episode-1", title: "第一集", seasonNumber: 1, episodeNumber: 1,
                runtimeSeconds: 1_200, artworkAvailable: true,
                userState: ServerMediaUserState(
                    itemID: "episode-1", positionSeconds: 300, progress: 0.25,
                    isWatched: false, playCount: 1, lastPlayedAt: nil,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            )]
        )
        let router = self.router { id, season, offset, limit, principal in
            received = (id, season, offset, limit, principal.userID)
            return expected
        }
        let valid = router.response(for: request("/api/v1/series/series%20id%2B1/episodes?season=1&offset=0&limit=50"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(valid.statusCode, 200)
        XCTAssertEqual(try decoder.decode(ServerSeriesEpisodesPage.self, from: valid.body), expected)
        XCTAssertEqual(received?.id, "series id+1")
        XCTAssertEqual(received?.season, .numbered(1))
        XCTAssertEqual(received?.offset, 0)
        XCTAssertEqual(received?.limit, 50)
        XCTAssertEqual(received?.userID, "viewer")

        let unspecified = router.response(for: request("/api/v1/series/series%20id%2B1/episodes?season=unspecified&offset=0&limit=10"))
        XCTAssertEqual(unspecified.statusCode, 200)
        XCTAssertEqual(received?.season, .unspecified)
        for invalid in [
            "/api/v1/series/series%20id%2B1/episodes",
            "/api/v1/series/series%20id%2B1/episodes?season=-1&offset=0&limit=50",
            "/api/v1/series/series%20id%2B1/episodes?season=1&season=2&offset=0&limit=50",
            "/api/v1/series/series%20id%2B1/episodes?season=1&offset=0&limit=101",
            "/api/v1/series/series%20id%2B1/episodes?season=1&offset=0&limit=50&userID=admin",
            "/api/v1/series/series%2Fescape/episodes?season=1&offset=0&limit=50"
        ] {
            XCTAssertEqual(router.response(for: request(invalid)).statusCode, 400, invalid)
        }
    }

    /// 海报是"我要看"，不是"我要先看一个目录页"。剧集页已删除：所有指向系列的
    /// 链接都走 `/series/{id}/play`，由服务端解析到真正的一集。
    func testSeriesCardRoutesStraightToPlaybackAndTheSeriesPageIsGone() {
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 1, countsByType: ["tvShow": 1]),
            items: ServerLibraryItemsResponse(totalItemCount: 1, items: [
                ServerLibraryItem(id: "series id+1", type: "tvShow", title: "系列", year: 2026, artworkAvailable: true, isSeries: true)
            ])
        )
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server", librarySnapshotProvider: { _ in snapshot },
            libraryBrowseProvider: { query, _ in
                ServerLibraryItemsPage(totalItemCount: 1, offset: query.offset, limit: query.limit, items: snapshot.items.items)
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let home = String(data: router.response(for: request("/")).body, encoding: .utf8) ?? ""
        let libraryScript = String(data: router.response(for: "GET /assets/library.js HTTP/1.1\r\nHost: localhost\r\n\r\n").body, encoding: .utf8) ?? ""
        XCTAssertTrue(home.contains("/series/series%20id%2B1/play"))
        XCTAssertFalse(home.contains("\"/series/series%20id%2B1\""), "首页不得再链到已删除的剧集页")
        XCTAssertTrue(libraryScript.contains("item.isSeries === true"))
        XCTAssertTrue(libraryScript.contains("`/series/${encodeURIComponent(itemID)}/play`"))

        let playRouter = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            seriesDetailProvider: { id, _ in id == self.detail.id ? self.detail : nil },
            seriesEpisodesProvider: { _, _, _, _, _ in
                ServerSeriesEpisodesPage(totalItemCount: 1, offset: 0, limit: 100, items: [
                    ServerSeriesEpisode(id: "episode first", title: "第一集", seasonNumber: 1, episodeNumber: 1, runtimeSeconds: 1_200, artworkAvailable: true)
                ])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let redirect = playRouter.response(for: request("/series/series%20id%2B1/play"))
        XCTAssertEqual(redirect.statusCode, 303)
        XCTAssertTrue(String(data: redirect.serializedHeaders(), encoding: .utf8)?.contains("Location: /item/episode%20first#play") == true)
    }

    private func router(
        episodes: @escaping (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage? = { _, _, _, _, _ in nil }
    ) -> LocalHTTPRouter {
        LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            seriesDetailProvider: { id, _ in id == self.detail.id ? self.detail : nil },
            seriesEpisodesProvider: episodes,
            authenticationProvider: { head in
                guard head.contains("Authorization: Bearer viewer") else { return nil }
                return ServerRequestPrincipal(
                    userID: "viewer", deviceID: "device", sessionID: "session",
                    permissions: [.viewMedia, .playMedia], libraryGrants: [:]
                )
            },
            csrfToken: "known-csrf"
        )
    }

    private func request(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n"
    }
}
