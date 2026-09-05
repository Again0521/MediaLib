import Foundation
import XCTest
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerWebCollectionRouteTests: XCTestCase {
    private let page = ServerCollectionsPage(
        totalItemCount: 1, offset: 0, limit: 24,
        items: [ServerCollectionCard(id: "collection id+1", name: "合集 <script>bad()</script>", mediaCount: 1)]
    )
    private let detail = ServerCollectionDetail(
        id: "collection id+1", name: "合集 <script>bad()</script>",
        items: ServerCollectionItemsPage(
            totalItemCount: 1, offset: 0, limit: 24,
            items: [ServerCollectionMedia(id: "series id+1", type: "tvShow", title: "系列 <img>", year: 2026, artworkAvailable: true, isSeries: true)]
        )
    )

    func testCollectionPagesRequireAuthEscapeMetadataAndUseSameOriginAssets() {
        let unauthenticated = LocalHTTPRouter(serverID: "server", serverName: "Server")
        XCTAssertEqual(unauthenticated.response(for: "GET /collections HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 401)

        let router = makeRouter()
        let directory = String(data: router.response(for: request("/collections")).body, encoding: .utf8) ?? ""
        XCTAssertTrue(directory.contains("合集 &lt;script&gt;bad()&lt;/script&gt;"))
        XCTAssertTrue(directory.contains("href=\"/assets/collections.css?v="))
        XCTAssertTrue(directory.contains("src=\"/assets/collections.js?v="))
        XCTAssertFalse(directory.contains("<script>bad()</script>"))

        let collection = String(data: router.response(for: request("/collections/collection%20id%2B1")).body, encoding: .utf8) ?? ""
        XCTAssertTrue(collection.contains("href=\"/series/series%20id%2B1/play\""), "剧集海报必须直接解析至实际播放页，不经由旧选集详情页")
        XCTAssertTrue(collection.contains("src=\"/api/v1/images/series%20id%2B1/poster?size=320\""))
        XCTAssertEqual(router.response(for: request("/collections/collection%2Fescape")).statusCode, 404)
        XCTAssertEqual(router.response(for: request("/collections/unknown")).statusCode, 404)
    }

    func testCollectionAPIsHaveStrictQueriesAndUseCurrentPrincipal() {
        var receivedList: (offset: Int, limit: Int, userID: String)?
        var receivedItems: (id: String, offset: Int, limit: Int, userID: String)?
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            collectionsProvider: { offset, limit, principal in
                receivedList = (offset, limit, principal.userID)
                return self.page
            },
            collectionDetailProvider: { id, offset, limit, principal in
                receivedItems = (id, offset, limit, principal.userID)
                return id == self.detail.id ? self.detail : nil
            },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )
        XCTAssertEqual(router.response(for: request("/api/v1/collections?offset=0&limit=24")).statusCode, 200)
        XCTAssertEqual(receivedList?.userID, "viewer")
        XCTAssertEqual(router.response(for: request("/api/v1/collections/collection%20id%2B1/items?offset=0&limit=24")).statusCode, 200)
        XCTAssertEqual(receivedItems?.id, "collection id+1")
        XCTAssertEqual(receivedItems?.userID, "viewer")
        for invalid in [
            "/api/v1/collections?userID=admin",
            "/api/v1/collections?offset=0&offset=1&limit=24",
            "/api/v1/collections?offset=-1&limit=24",
            "/api/v1/collections/collection%2Fescape/items?offset=0&limit=24",
            "/api/v1/collections/collection%20id%2B1/items?offset=0&limit=24&source=all"
        ] { XCTAssertEqual(router.response(for: request(invalid)).statusCode, 400, invalid) }
    }

    func testSmartCollectionAndPlaylistAPIsShareStrictDiscoveryBoundary() {
        var calls: [String] = []
        let emptyItems = ServerLibraryItemsPage(totalItemCount: 0, offset: 0, limit: 24, items: [])
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            smartCollectionsProvider: { offset, limit, principal in
                calls.append("smart-list:\(offset):\(limit):\(principal.userID)")
                return ServerSmartCollectionsPage(
                    totalItemCount: 1, offset: offset, limit: limit,
                    items: [ServerSmartCollectionCard(id: "smart id+1", name: "智能合集", mediaCount: 0)]
                )
            },
            smartCollectionDetailProvider: { id, offset, limit, principal in
                calls.append("smart-items:\(id):\(offset):\(limit):\(principal.userID)")
                return id == "smart id+1"
                    ? ServerSmartCollectionDetail(id: id, name: "智能合集", items: emptyItems)
                    : nil
            },
            musicPlaylistsProvider: { offset, limit, principal in
                calls.append("playlist-list:\(offset):\(limit):\(principal.userID)")
                return ServerMusicPlaylistsPage(
                    totalItemCount: 1, offset: offset, limit: limit,
                    items: [ServerMusicPlaylistCard(id: "playlist id+1", name: "歌单", trackCount: 0, isSmart: false)]
                )
            },
            musicPlaylistDetailProvider: { id, offset, limit, principal in
                calls.append("playlist-items:\(id):\(offset):\(limit):\(principal.userID)")
                return id == "playlist id+1"
                    ? ServerMusicPlaylistDetail(id: id, name: "歌单", isSmart: false, items: emptyItems)
                    : nil
            },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )

        XCTAssertEqual(router.response(for: request("/api/v1/smart-collections?offset=2&limit=7")).statusCode, 200)
        XCTAssertEqual(router.response(for: request("/api/v1/smart-collections/smart%20id%2B1/items?offset=3&limit=4")).statusCode, 200)
        XCTAssertEqual(router.response(for: request("/api/v1/music/playlists?offset=5&limit=6")).statusCode, 200)
        XCTAssertEqual(router.response(for: request("/api/v1/music/playlists/playlist%20id%2B1/items?offset=7&limit=8")).statusCode, 200)
        XCTAssertEqual(calls, [
            "smart-list:2:7:viewer", "smart-items:smart id+1:3:4:viewer",
            "playlist-list:5:6:viewer", "playlist-items:playlist id+1:7:8:viewer"
        ])

        for invalid in [
            "/api/v1/smart-collections?sort=title",
            "/api/v1/smart-collections/smart%20id%2B1/items",
            "/api/v1/smart-collections/smart%2Fescape/items?offset=0&limit=24",
            "/api/v1/music/playlists?offset=0&limit=0",
            "/api/v1/music/playlists/playlist%20id%2B1/items?offset=0&limit=24&userID=admin"
        ] {
            XCTAssertEqual(router.response(for: request(invalid)).statusCode, 400, invalid)
        }
        XCTAssertEqual(calls.count, 4, "rejected discovery queries must not reach catalog providers")
    }

    func testDiscoveryRoutesRejectMethodsAndMissingViewPermissionBeforeProviders() {
        var providerCallCount = 0
        let restricted = ServerRequestPrincipal(
            userID: "restricted", deviceID: "device", sessionID: "session",
            permissions: [], libraryGrants: [:]
        )
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            collectionsProvider: { offset, limit, _ in
                providerCallCount += 1
                return ServerCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
            },
            authenticationProvider: { _ in restricted }
        )

        XCTAssertEqual(router.response(for: request("/api/v1/collections")).statusCode, 403)
        let post = "POST /api/v1/collections HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\nContent-Length: 0\r\n\r\n"
        XCTAssertEqual(router.response(for: post).statusCode, 405)
        XCTAssertEqual(providerCallCount, 0)
    }

    func testCollectionAssetsAvoidUnsafeDOMAndPersistentSecrets() {
        let router = makeRouter()
        let css = router.response(for: "GET /assets/collections.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let js = String(data: router.response(for: "GET /assets/collections.js HTTP/1.1\r\nHost: localhost\r\n\r\n").body, encoding: .utf8) ?? ""
        XCTAssertEqual(css.statusCode, 200)
        XCTAssertEqual(router.response(for: "GET /assets/collections.js HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 200)
        XCTAssertTrue(ServerWebBaseStyle.css.contains("prefers-reduced-motion: reduce"), "减少动效策略集中在 base.css")
        XCTAssertTrue(js.contains("textContent"))
        XCTAssertTrue(js.contains("createDocumentFragment"))
        XCTAssertTrue(js.contains("credentials: 'same-origin'"))
        XCTAssertFalse(js.contains("innerHTML"))
        XCTAssertFalse(js.contains("insertAdjacentHTML"))
        XCTAssertFalse(js.contains("localStorage"))
        XCTAssertFalse(js.contains("document.cookie"))
        XCTAssertFalse(js.contains("eval("))
    }

    private var viewer: ServerRequestPrincipal {
        ServerRequestPrincipal(userID: "viewer", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia], libraryGrants: [:])
    }

    private func makeRouter() -> LocalHTTPRouter {
        LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            collectionsProvider: { _, _, _ in self.page },
            collectionDetailProvider: { id, _, _, _ in id == self.detail.id ? self.detail : nil },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )
    }

    private func request(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n"
    }
}
