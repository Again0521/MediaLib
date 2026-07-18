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
        XCTAssertTrue(html.contains("href=\"/assets/player.css\""))
        XCTAssertTrue(html.contains("data-item-id=\"movie-1\""))
        XCTAssertTrue(html.contains("data-resume-position=\"300.0\""))
        XCTAssertTrue(html.contains("id=\"user-playback-state\""))
        XCTAssertTrue(html.contains("id=\"technical-info\""))
        XCTAssertTrue(html.contains("id=\"stream-list\""))
        XCTAssertTrue(html.contains("id=\"reset-playback\""))
        XCTAssertTrue(html.contains("id=\"playback-speed\""))
        XCTAssertTrue(html.contains("id=\"fullscreen\""))
        XCTAssertTrue(html.contains("id=\"picture-in-picture\""))
        XCTAssertTrue(html.contains("id=\"toggle-favorite\""))
        XCTAssertTrue(html.contains("id=\"toggle-watchlist\""))
        XCTAssertTrue(html.contains("id=\"user-rating\""))
        XCTAssertTrue(html.contains("data-is-favorite=\"false\""))
        XCTAssertFalse(html.contains("id=\"automatic-next\""), "非剧集或没有已授权下一集时不能显示自动播放控件")
        XCTAssertFalse(html.localizedCaseInsensitiveContains("filePath"))
        XCTAssertFalse(html.contains("/private/"))
    }

    func testPlayerStylesheetIsPrivateCacheableAndContainsNoMediaData() throws {
        let router = makeRouter()
        let response = router.response(for: "GET /assets/player.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headResponse = router.response(for: "HEAD /assets/player.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""
        let headHeaders = String(data: headResponse.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(headers.contains("Content-Type: text/css; charset=utf-8"))
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))

        let stylesheet = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(stylesheet.contains(".player-card"))
        XCTAssertTrue(stylesheet.contains("video { display:block; inline-size:100%; max-inline-size:100%; min-inline-size:0; block-size:auto;"))
        XCTAssertTrue(stylesheet.contains("@media (max-width:480px)"))
        XCTAssertFalse(stylesheet.contains("movie-1"))
        XCTAssertFalse(stylesheet.contains("token"))

        XCTAssertEqual(headResponse.statusCode, 200)
        XCTAssertTrue(headResponse.body.isEmpty)
        XCTAssertEqual(headerValue(named: "Content-Length", in: headHeaders), headerValue(named: "Content-Length", in: headers))
    }

    func testPlayerScriptUsesAuthorizedLifecycleWithoutUnsafeHTMLOrTokenStorage() {
        let asset = makeRouter().response(
            for: "GET /assets/player.js HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        let script = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(script.contains("/api/v1/stream/"))
        XCTAssertTrue(script.contains("/api/v1/playback/info/"))
        XCTAssertTrue(script.contains("/api/v1/playback/state/"))
        XCTAssertTrue(script.contains("/api/v1/user-media/preferences/"))
        XCTAssertTrue(script.contains("/api/v1/playback/subtitles/"))
        XCTAssertTrue(script.contains("/api/v1/subtitles/"))
        XCTAssertTrue(script.contains("document.createElement('track')"))
        XCTAssertTrue(script.contains("method: 'POST'"))
        XCTAssertTrue(script.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("encodeURIComponent(itemID)"))
        XCTAssertTrue(script.contains("pagehide"))
        XCTAssertTrue(script.contains("timeupdate"))
        XCTAssertTrue(script.contains("loadedmetadata"))
        XCTAssertTrue(script.contains("JSON.stringify({ event, positionSeconds, durationSeconds })"))
        XCTAssertTrue(script.contains("JSON.stringify({ [field]: value })"))
        XCTAssertTrue(script.contains("event: 'reset'"))
        XCTAssertTrue(script.contains("requestFullscreen"))
        XCTAssertTrue(script.contains("requestPictureInPicture"))
        XCTAssertTrue(script.contains("keydown"))
        XCTAssertTrue(script.contains("scheduleAutomaticNext"))
        XCTAssertTrue(script.contains("#autoplay"))
        XCTAssertTrue(script.contains("window.location.assign"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("insertAdjacentHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("sessionStorage"))
        XCTAssertFalse(script.contains("eval("))
        XCTAssertFalse(script.contains("/api/v1/playback/hls/"))
        XCTAssertFalse(script.contains("/api/v1/hls/"))
        XCTAssertFalse(script.contains("ffmpeg"))
    }

    func testEpisodeNavigationControlsUseSafeServerDerivedLinks() {
        let detail = ServerMediaItemDetail(
            id: "episode-2", type: "episode", title: "第二集", originalTitle: nil, year: nil,
            overview: nil, genres: [], communityRating: nil, runtimeSeconds: nil,
            videoCodec: nil, audioCodec: nil, resolution: nil, artworkAvailable: false,
            backdropAvailable: false, canDirectPlay: true, canTranscode: false,
            previousEpisode: ServerEpisodeNavigation(id: "episode-1", title: "<上一集>"),
            nextEpisode: ServerEpisodeNavigation(id: "episode-3", title: "下一集")
        )
        let html = ServerWebMediaDetailPage.render(
            serverName: "测试服务器", detail: detail, csrfToken: "csrf", showAdministration: false
        )

        XCTAssertTrue(html.contains("id=\"previous-episode\""))
        XCTAssertTrue(html.contains("href=\"/item/episode-1\""))
        XCTAssertTrue(html.contains("id=\"next-episode\""))
        XCTAssertTrue(html.contains("href=\"/item/episode-3\""))
        XCTAssertTrue(html.contains("id=\"automatic-next\""))
        XCTAssertTrue(html.contains("id=\"cancel-automatic-next\""))
        XCTAssertTrue(html.contains("&lt;上一集&gt;"))
        XCTAssertFalse(html.contains("<上一集>"))
    }

    func testDetailPageUsesAuthorizedOpaquePosterWhenArtworkExists() {
        let detail = ServerMediaItemDetail(
            id: "movie id+1", type: "movie", title: "海报测试", originalTitle: nil,
            year: nil, overview: nil, genres: [], communityRating: nil, runtimeSeconds: nil,
            videoCodec: nil, audioCodec: nil, resolution: nil,
            artworkAvailable: true, backdropAvailable: false,
            canDirectPlay: true, canTranscode: false
        )
        let html = ServerWebMediaDetailPage.render(
            serverName: "测试服务器", detail: detail, csrfToken: "csrf", showAdministration: false
        )

        XCTAssertTrue(html.contains("src=\"/api/v1/images/movie%20id%2B1/poster\""))
        XCTAssertTrue(html.contains("loading=\"eager\""))
        XCTAssertTrue(html.contains("decoding=\"async\""))
        XCTAssertFalse(html.contains("role=\"img\""))
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

    func testMediaPreferenceMutationUsesAuthenticatedPrincipalAndSingleFieldBody() throws {
        var received: (itemID: String, preference: ServerUserMediaPreferenceUpdate, userID: String)?
        let expected = ServerMediaUserPreference(isFavorite: true, isWatchlist: false, rating: nil)
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaPreferenceUpdater: { itemID, preference, principal in
                received = (itemID, preference, principal.userID)
                return expected
            },
            authenticationProvider: { requestHead in
                requestHead.contains("Authorization: Bearer viewer")
                    ? ServerRequestPrincipal(
                        userID: "viewer", deviceID: "device", sessionID: "session",
                        permissions: [.viewMedia], libraryGrants: [:]
                    ) : nil
            },
            csrfToken: "known-csrf"
        )
        let body = Data(#"{"favorite":true}"#.utf8)
        let response = router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: body.count),
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(received?.itemID, "movie-1")
        XCTAssertEqual(received?.preference, .favorite(true))
        XCTAssertEqual(received?.userID, "viewer")
        XCTAssertEqual(try JSONDecoder().decode(ServerMediaUserPreference.self, from: response.body), expected)

        let combined = Data(#"{"favorite":true,"watchlist":true}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: combined.count),
            body: combined
        ).statusCode, 400)
        let invalidRating = Data(#"{"rating":5.5}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: invalidRating.count),
            body: invalidRating
        ).statusCode, 400)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: body.count, token: "missing"),
            body: body
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

    private func headerValue(named name: String, in headers: String) -> String? {
        headers
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(name): ") }
            .map { String($0.dropFirst(name.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
