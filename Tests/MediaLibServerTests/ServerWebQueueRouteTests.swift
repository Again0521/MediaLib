import XCTest
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerWebQueueRouteTests: XCTestCase {
    func testQueuePageUsesCurrentPrincipalAndInProgressFilter() {
        var received: (query: ServerLibraryQuery, userID: String)?
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            libraryBrowseProvider: { query, principal in
                received = (query, principal.userID)
                return ServerLibraryItemsPage(totalItemCount: 0, offset: query.offset, limit: query.limit, items: [])
            },
            libraryCategoriesProvider: { _ in ServerLibraryCategoriesResponse(categories: []) },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )
        let response = router.response(for: request("/queue"))
        let html = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(html.contains("播放队列"))
        XCTAssertTrue(html.contains("data-page-route=\"/queue\""))
        XCTAssertTrue(html.contains("data-playback-filter=\"inProgress\""))
        let api = router.response(for: request("/api/v1/library/browse?offset=0&limit=48&state=inProgress&sort=updatedDescending"))
        XCTAssertEqual(api.statusCode, 200)
        XCTAssertEqual(received?.query.playbackFilter, .inProgress)
        XCTAssertEqual(received?.userID, "viewer")
    }

    func testQueuePageRequiresAuthentication() {
        let router = LocalHTTPRouter(serverID: "server", serverName: "Server")
        XCTAssertEqual(router.response(for: "GET /queue HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 401)
    }

    func testQueueAPIIsPerPrincipalAndMutationIsStrict() {
        let expected = ServerQueueResponse(
            repeatMode: "repeatAll",
            shuffleEnabled: true,
            currentPosition: 0,
            items: [ServerQueueItem(id: "movie-1", type: "movie", title: "电影", year: 2026, artworkAvailable: false, isSeries: false)]
        )
        var received: (ServerQueueMutationRequest, String)?
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            queueProvider: { principal in
                XCTAssertEqual(principal.userID, "viewer")
                return expected
            },
            queueMutationProvider: { request, principal in
                received = (request, principal.userID)
                return expected
            },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )
        let api = router.response(for: request("/api/v1/queue"))
        XCTAssertEqual(api.statusCode, 200)
        XCTAssertTrue(String(data: api.body, encoding: .utf8)?.contains("\"repeatMode\":\"repeatAll\"") == true)

        let body = Data(#"{"action":"settings","repeatMode":"repeatAll","shuffleEnabled":true}"#.utf8)
        let updated = router.response(
            for: "POST /api/v1/queue HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n",
            body: body
        )
        XCTAssertEqual(updated.statusCode, 200)
        XCTAssertEqual(received?.0.action, "settings")
        XCTAssertEqual(received?.0.repeatMode, "repeatAll")
        XCTAssertEqual(received?.1, "viewer")

        let unknown = Data(#"{"action":"clear","unexpected":true}"#.utf8)
        XCTAssertEqual(router.response(for: "POST /api/v1/queue HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n", body: unknown).statusCode, 400)
    }

    func testQueuePageAndAssetsUseSafeDOM() {
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            queueProvider: { _ in ServerQueueResponse(repeatMode: "sequential", shuffleEnabled: false, currentPosition: 0, items: []) },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )
        let html = String(data: router.response(for: request("/queue")).body, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("href=\"/assets/queue.css\""))
        XCTAssertTrue(html.contains("src=\"/assets/queue.js\""))
        let script = String(data: router.response(for: "GET /assets/queue.js HTTP/1.1\r\nHost: localhost\r\n\r\n").body, encoding: .utf8) ?? ""
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("eval("))
        XCTAssertEqual(router.response(for: "GET /assets/queue.css HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 200)
    }

    private var viewer: ServerRequestPrincipal {
        ServerRequestPrincipal(userID: "viewer", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia], libraryGrants: [:])
    }

    private func request(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n"
    }
}
