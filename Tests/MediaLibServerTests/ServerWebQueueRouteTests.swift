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

    private var viewer: ServerRequestPrincipal {
        ServerRequestPrincipal(userID: "viewer", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia], libraryGrants: [:])
    }

    private func request(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n"
    }
}
