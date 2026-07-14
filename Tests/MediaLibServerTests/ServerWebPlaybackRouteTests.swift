import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerWebPlaybackRouteTests: XCTestCase {
    private let safeDetail = ServerMediaItemDetail(
        id: "movie-1",
        type: "movie",
        title: "标题 <script>alert(1)</script>",
        originalTitle: "Original & Movie",
        year: 2026,
        overview: "简介 </style><script>bad()</script>",
        genres: ["剧情", "科幻"],
        communityRating: 8.5,
        runtimeSeconds: 7_200,
        videoCodec: "h264",
        audioCodec: "aac",
        resolution: "1920x1080",
        artworkAvailable: true,
        backdropAvailable: false,
        canDirectPlay: true,
        canTranscode: true,
        userState: ServerMediaUserState(
            itemID: "movie-1", positionSeconds: 300, progress: 0.5,
            isWatched: false, playCount: 1, lastPlayedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    )

    func testDetailAPIAndPageRequireAuthenticationAndHideUnknownItems() throws {
        let router = makeRouter()
        let unauthenticated = LocalHTTPRouter(
            serverID: "server", serverName: "Server", mediaDetailProvider: { _, _ in self.safeDetail }
        )

        XCTAssertEqual(unauthenticated.response(
            for: "GET /item/movie-1 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        ).statusCode, 401)
        XCTAssertEqual(router.response(
            for: request("/item/unknown", token: "viewer")
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: request("/api/v1/items/unknown", token: "viewer")
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: request("/item/movie-1/extra", token: "viewer")
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: request("/item/movie-1%0Aheader", token: "viewer")
        ).statusCode, 404)

        let api = router.response(for: request("/api/v1/items/movie-1", token: "viewer"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(api.statusCode, 200)
        XCTAssertEqual(try decoder.decode(ServerMediaItemDetail.self, from: api.body), safeDetail)
    }

    func testDetailPageEscapesMetadataAndUsesOnlyExternalSameOriginScript() {
        let response = makeRouter().response(for: request("/item/movie-1", token: "viewer"))
        let html = String(data: response.body, encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(html.contains("标题 &lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("简介 &lt;/style&gt;&lt;script&gt;bad()&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertFalse(html.contains("</style><script>bad()</script>"))
        XCTAssertTrue(html.contains("content=\"known-csrf\""))
        XCTAssertTrue(html.contains("src=\"/assets/player.js\""))
        XCTAssertTrue(html.contains("data-item-id=\"movie-1\""))
        XCTAssertTrue(html.contains("data-resume-position=\"300.0\""))
        XCTAssertTrue(html.contains("id=\"user-playback-state\""))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("filePath"))
        XCTAssertFalse(html.contains("/private/"))
    }

    func testPlayerScriptUsesAuthorizedLifecycleWithoutUnsafeHTMLOrTokenStorage() {
        let asset = makeRouter().response(
            for: "GET /assets/player.js HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        let script = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(script.contains("/api/v1/stream/"))
        XCTAssertTrue(script.contains("/api/v1/playback/hls/"))
        XCTAssertTrue(script.contains("/api/v1/playback/state/"))
        XCTAssertTrue(script.contains("method: 'POST'"))
        XCTAssertTrue(script.contains("method: 'DELETE'"))
        XCTAssertTrue(script.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("encodeURIComponent(itemID)"))
        XCTAssertTrue(script.contains("pagehide"))
        XCTAssertTrue(script.contains("timeupdate"))
        XCTAssertTrue(script.contains("loadedmetadata"))
        XCTAssertTrue(script.contains("JSON.stringify({ event, positionSeconds, durationSeconds })"))
        XCTAssertTrue(script.contains("nativeHLS"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("insertAdjacentHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("sessionStorage"))
        XCTAssertFalse(script.contains("eval("))
    }

    func testHomeCardsDeepLinkWithEncodedIdentifierAndEscapedTitle() {
        let detail = ServerMediaItemDetail(
            id: "movie id+1", type: "movie", title: "Movie", originalTitle: nil,
            year: nil, overview: nil, genres: [], communityRating: nil, runtimeSeconds: nil,
            videoCodec: nil, audioCodec: nil, resolution: nil,
            artworkAvailable: false, backdropAvailable: false,
            canDirectPlay: false, canTranscode: false
        )
        let router = makeRouter(detail: detail)
        let response = router.response(for: request("/", token: "viewer"))
        let html = String(data: response.body, encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(html.contains("href=\"/item/movie%20id%2B1\""))
        XCTAssertTrue(html.contains("content=\"known-csrf\""))
        XCTAssertTrue(html.contains("跳到主要内容"))
    }

    func testDetailHeadOmitsBodyAndProviderFailureIsSafe503() {
        let head = makeRouter().response(for: request("/api/v1/items/movie-1", token: "viewer", method: "HEAD"))
        let failing = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaDetailProvider: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            authenticationProvider: { _ in .testAdministrator() }
        ).response(for: request("/item/movie-1", token: "viewer"))

        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertGreaterThan(head.declaredContentLength, 0)
        XCTAssertEqual(failing.statusCode, 503)
        XCTAssertEqual(String(data: failing.body, encoding: .utf8), "{\"error\":\"Service Unavailable\"}")
    }

    func testPlaybackStateMutationUsesAuthenticatedPrincipalAndRejectsUnknownFields() throws {
        var receivedUserID: String?
        let state = ServerMediaUserState(
            itemID: "movie-1", positionSeconds: 300, progress: 0.5,
            isWatched: false, playCount: 1,
            lastPlayedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaPlaybackStateUpdater: { itemID, request, principal in
                receivedUserID = principal.userID
                return itemID == "movie-1" && request.event == .progress ? state : nil
            },
            authenticationProvider: { head in
                head.contains("Authorization: Bearer viewer")
                    ? ServerRequestPrincipal(
                        userID: "viewer", deviceID: "device", sessionID: "session",
                        permissions: [.viewMedia, .playMedia], libraryGrants: [:]
                    )
                    : nil
            },
            csrfToken: "known-csrf"
        )
        let validBody = Data(#"{"event":"progress","positionSeconds":300,"durationSeconds":600}"#.utf8)
        let response = router.response(
            for: mutationRequest("/api/v1/playback/state/movie-1", bodyLength: validBody.count),
            body: validBody
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(receivedUserID, "viewer")
        XCTAssertEqual(try decoder.decode(ServerMediaUserState.self, from: response.body), state)

        let injected = Data(#"{"event":"progress","positionSeconds":300,"durationSeconds":600,"userID":"admin"}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/state/movie-1", bodyLength: injected.count),
            body: injected
        ).statusCode, 400)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/state/unknown", bodyLength: validBody.count),
            body: validBody
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/state/movie-1", bodyLength: validBody.count, token: "missing"),
            body: validBody
        ).statusCode, 401)
    }

    private func makeRouter(detail: ServerMediaItemDetail? = nil) -> LocalHTTPRouter {
        let item = detail ?? safeDetail
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 1, countsByType: [item.type: 1]),
            items: ServerLibraryItemsResponse(
                totalItemCount: 1,
                items: [ServerLibraryItem(
                    id: item.id, type: item.type, title: item.title,
                    year: item.year, artworkAvailable: item.artworkAvailable
                )]
            )
        )
        return LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            librarySnapshotProvider: { _ in snapshot },
            mediaDetailProvider: { requestedID, _ in requestedID == item.id ? item : nil },
            authenticationProvider: { requestHead in
                guard requestHead.contains("Authorization: Bearer viewer") else { return nil }
                return ServerRequestPrincipal(
                    userID: "viewer", deviceID: "device", sessionID: "session",
                    permissions: [.viewMedia, .playMedia, .transcodePlayback], libraryGrants: [:]
                )
            },
            csrfToken: "known-csrf"
        )
    }

    private func request(_ path: String, token: String, method: String = "GET") -> String {
        "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n"
    }

    private func mutationRequest(_ path: String, bodyLength: Int, token: String = "viewer") -> String {
        "POST \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(bodyLength)\r\nX-MediaLIB-CSRF: known-csrf\r\n\r\n"
    }
}
