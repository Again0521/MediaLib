import Foundation
import XCTest
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerWebPeopleRouteTests: XCTestCase {
    private let people = ServerPeoplePage(
        totalItemCount: 2, offset: 0, limit: 24,
        items: [ServerPersonCard(id: "person id+1", name: "人物 <script>bad()</script>", department: "演员", mediaCount: 2)]
    )

    private let detail = ServerPersonDetail(
        id: "person id+1", name: "人物 <script>bad()</script>", biography: "简介 </style><script>bad()</script>",
        birthday: "1980-01-01", deathday: nil, placeOfBirth: "上海", department: "演员",
        credits: ServerPeopleCreditsPage(
            totalItemCount: 2, offset: 0, limit: 24,
            items: [ServerPersonCredit(id: "series id+1", type: "tvShow", title: "系列 <img>", year: 2026, artworkAvailable: true, isSeries: true, category: "cast", role: "主角")]
        )
    )

    func testPeoplePagesRequireAuthEscapeMetadataAndUseOnlySameOriginAssets() {
        let unauthenticated = LocalHTTPRouter(serverID: "server", serverName: "Server", peopleProvider: { _, offset, limit, _ in
            ServerPeoplePage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        })
        XCTAssertEqual(unauthenticated.response(for: "GET /people HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 401)

        let router = makeRouter()
        let directory = String(data: router.response(for: request("/people")).body, encoding: .utf8) ?? ""
        XCTAssertTrue(directory.contains("人物 &lt;script&gt;bad()&lt;/script&gt;"))
        XCTAssertTrue(directory.contains("href=\"/assets/people.css?v="))
        XCTAssertTrue(directory.contains("src=\"/assets/people.js?v="))
        XCTAssertFalse(directory.contains("profileURL"))
        XCTAssertFalse(directory.contains("<script>bad()</script>"))

        let page = String(data: router.response(for: request("/people/person%20id%2B1")).body, encoding: .utf8) ?? ""
        XCTAssertTrue(page.contains("简介 &lt;/style&gt;&lt;script&gt;bad()&lt;/script&gt;"))
        XCTAssertTrue(page.contains("href=\"/series/series%20id%2B1/play\""), "人物作品中的剧集海报必须直接进入播放页")
        XCTAssertTrue(page.contains("src=\"/api/v1/images/series%20id%2B1/poster?size=320\""))
        XCTAssertEqual(router.response(for: request("/people/person%2Fescape")).statusCode, 404)
        XCTAssertEqual(router.response(for: request("/people/unknown")).statusCode, 404)
    }

    func testPeopleAPIsHaveStrictQueriesAndCurrentPrincipal() throws {
        var receivedSearch: (query: String?, offset: Int, limit: Int, userID: String)?
        var receivedCredits: (id: String, offset: Int, limit: Int, userID: String)?
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            peopleProvider: { query, offset, limit, principal in
                receivedSearch = (query, offset, limit, principal.userID)
                return self.people
            },
            personDetailProvider: { id, offset, limit, principal in
                receivedCredits = (id, offset, limit, principal.userID)
                return id == self.detail.id ? self.detail : nil
            },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? .testViewer() : nil }
        )
        let response = router.response(for: request("/api/v1/people?q=%E4%BA%BA%E7%89%A9&offset=0&limit=24"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(receivedSearch?.query, "人物")
        XCTAssertEqual(receivedSearch?.offset, 0)
        XCTAssertEqual(receivedSearch?.limit, 24)
        XCTAssertEqual(receivedSearch?.userID, "viewer")

        let credits = router.response(for: request("/api/v1/people/person%20id%2B1/credits?offset=0&limit=24"))
        XCTAssertEqual(credits.statusCode, 200)
        XCTAssertEqual(receivedCredits?.id, "person id+1")
        XCTAssertEqual(receivedCredits?.userID, "viewer")
        for invalid in [
            "/api/v1/people?userID=admin",
            "/api/v1/people?q=x&q=y&offset=0&limit=24",
            "/api/v1/people?offset=-1&limit=24",
            "/api/v1/people?offset=0&limit=101",
            "/api/v1/people/person%2Fescape/credits?offset=0&limit=24",
            "/api/v1/people/person%20id%2B1/credits?offset=0&limit=24&role=admin"
        ] {
            XCTAssertEqual(router.response(for: request(invalid)).statusCode, 400, invalid)
        }
    }

    func testPeopleAssetsAreCacheableAndAvoidUnsafeDOMOrPersistentSecrets() {
        let router = makeRouter()
        let css = router.response(for: "GET /assets/people.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let js = String(data: router.response(for: "GET /assets/people.js HTTP/1.1\r\nHost: localhost\r\n\r\n").body, encoding: .utf8) ?? ""
        XCTAssertEqual(css.statusCode, 200)
        XCTAssertEqual(router.response(for: "GET /assets/people.js HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 200)
        XCTAssertTrue(ServerWebBaseStyle.css.contains("prefers-reduced-motion: reduce"), "减少动效策略集中在 base.css")
        XCTAssertTrue(js.contains("textContent"))
        XCTAssertTrue(js.contains("createDocumentFragment"))
        XCTAssertTrue(js.contains("credentials: 'same-origin'"))
        XCTAssertFalse(js.contains("innerHTML"))
        XCTAssertFalse(js.contains("insertAdjacentHTML"))
        XCTAssertFalse(js.contains("localStorage"))
        XCTAssertFalse(js.contains("document.cookie"))
        XCTAssertFalse(js.contains("eval("))
        XCTAssertFalse(js.localizedCaseInsensitiveContains("profileURL"))
    }

    private func makeRouter() -> LocalHTTPRouter {
        LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            peopleProvider: { _, _, _, _ in self.people },
            personDetailProvider: { id, _, _, _ in id == self.detail.id ? self.detail : nil },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? .testViewer() : nil }
        )
    }

    private func request(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n"
    }
}

private extension ServerRequestPrincipal {
    static func testViewer() -> ServerRequestPrincipal {
        ServerRequestPrincipal(userID: "viewer", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia], libraryGrants: [:])
    }
}
