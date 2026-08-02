import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
import MediaLibServerProtocol

final class LocalHTTPRouterTests: XCTestCase {
    private let router = LocalHTTPRouter(
        serverID: "server-001",
        serverName: "客厅服务器",
        authenticationProvider: { _ in .testAdministrator() }
    )

    func testHealthRouteReturnsJSONHealth() throws {
        let response = router.response(for: "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let health = try decoder.decode(ServerHealth.self, from: response.body)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(response.declaredContentLength, response.body.count)
        XCTAssertEqual(health.serverID, "server-001")
        XCTAssertEqual(health.serverName, "客厅服务器")
    }

    func testWellKnownRouteSupportsHeadWithoutBody() {
        let response = router.response(for: "HEAD /.well-known/mlink HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertGreaterThan(response.declaredContentLength, 0)
    }

    func testPersistentConnectionPolicyIsHTTPVersionAwareAndBoundedByExplicitClose() {
        XCTAssertTrue(LocalLoopbackHTTPServer.supportsPersistentConnection(
            "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        ))
        XCTAssertFalse(LocalLoopbackHTTPServer.supportsPersistentConnection(
            "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        ))
        XCTAssertFalse(LocalLoopbackHTTPServer.supportsPersistentConnection(
            "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"
        ))
        XCTAssertTrue(LocalLoopbackHTTPServer.supportsPersistentConnection(
            "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
        ))
        XCTAssertFalse(LocalLoopbackHTTPServer.supportsPersistentConnection(
            "GET / HTTP/2\r\nHost: localhost\r\n\r\n"
        ))
    }

    func testResponseHeadersOnlyAdvertiseKeepAliveWhenTransportOptsIn() {
        let response = LocalHTTPResponse.ok(body: Data("{}".utf8), omitBody: false)
        let defaultHeaders = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""
        let persistentHeaders = String(
            data: response.serializedHeaders(keepAlive: true), encoding: .utf8
        ) ?? ""

        XCTAssertTrue(defaultHeaders.contains("Connection: close"))
        XCTAssertFalse(defaultHeaders.contains("Keep-Alive:"))
        XCTAssertTrue(persistentHeaders.contains("Connection: keep-alive"))
        XCTAssertTrue(persistentHeaders.contains("Keep-Alive: timeout=10, max=64"))
        XCTAssertTrue(persistentHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(persistentHeaders.contains("Content-Security-Policy:"))
    }

    func testAuthenticatedStatusPageKeepsMachineHealthProbeSeparateAndUsesSafeScript() {
        let page = router.response(for: "GET /status HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let head = router.response(for: "HEAD /status HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let asset = router.response(for: "GET /assets/status.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let stylesheet = router.response(for: "GET /assets/status.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""
        let stylesheetHeaders = String(data: stylesheet.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: stylesheet.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertGreaterThan(head.declaredContentLength, 0)
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(html.contains("src=\"/assets/status.js\""))
        XCTAssertTrue(html.contains("href=\"/assets/status.css\""))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(html.contains("/health"))
        XCTAssertTrue(script.contains("credentials:'same-origin'"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".state"))
        XCTAssertFalse(style.contains("server-001"))
    }

    func testWebShellStyleIsSameOriginCacheableAndUsedByEveryPageFamily() {
        let asset = router.response(for: "GET /assets/app-shell.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let head = router.response(for: "HEAD /assets/app-shell.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: asset.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: asset.body, encoding: .utf8) ?? ""
        let pages = ["/", "/library", "/search", "/watching", "/history", "/favorites", "/watchlist", "/ratings", "/watched", "/unwatched", "/people", "/collections", "/photos", "/queue", "/status", "/account", "/admin", "/sources"]

        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/css; charset=utf-8")
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".shell > aside"))
        XCTAssertTrue(style.contains("--ml-sidebar"))
        XCTAssertTrue(style.contains(".app-nav .nav-group-title"))
        XCTAssertTrue(style.contains(".app-mobile-nav"))
        XCTAssertTrue(style.contains(".app-mobile-nav summary"))
        XCTAssertTrue(style.contains("--ml-pink"))
        XCTAssertTrue(style.contains(".brand-copy"))
        XCTAssertTrue(style.contains(".nav-disclosure"))
        XCTAssertTrue(style.contains(".sidebar-status-card"))
        XCTAssertTrue(style.contains("width:252px"))
        XCTAssertTrue(style.contains("min-height:44px"))
        XCTAssertTrue(style.contains("app-shell-navigating::before"))
        XCTAssertTrue(style.contains("touch-action:manipulation"))
        XCTAssertTrue(style.contains("position:sticky"))
        XCTAssertTrue(style.contains("display:grid"))
        XCTAssertTrue(style.contains("min-height:100dvh"))

        let scriptAsset = router.response(for: "GET /assets/app-shell.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let scriptHeaders = String(data: scriptAsset.serializedHeaders(), encoding: .utf8) ?? ""
        let script = String(data: scriptAsset.body, encoding: .utf8) ?? ""
        XCTAssertEqual(scriptAsset.statusCode, 200)
        XCTAssertEqual(scriptAsset.contentType, "text/javascript; charset=utf-8")
        XCTAssertTrue(scriptHeaders.contains("Cache-Control: private, max-age=300"))
        XCTAssertTrue(script.contains("DOMParser"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("medialib:pagewillunload"))
        XCTAssertTrue(script.contains("maxPageCacheEntries = 32"))
        XCTAssertTrue(script.contains("navigationSerial"))
        XCTAssertTrue(script.contains("activeNavigationRequest"))
        XCTAssertTrue(script.contains("navigationFallbackTimer"))
        XCTAssertTrue(script.contains("prefersNativeNavigation"))
        XCTAssertTrue(script.contains("supportsProgressiveNavigation"))
        XCTAssertTrue(script.contains("window.navigator?.maxTouchPoints"))
        XCTAssertTrue(script.contains("eventAnchor"))
        XCTAssertTrue(script.contains("composedPath"))
        XCTAssertTrue(script.contains("pointerdown"))
        XCTAssertTrue(script.contains("{ capture: true }"))
        XCTAssertTrue(script.contains("window.location.assign(url.href)"))
        XCTAssertTrue(script.contains("window.location.assign(anchor.href)"))
        XCTAssertTrue(script.contains("window.location.href = href"))
        XCTAssertTrue(script.contains("const assignNativeLocation = href"))
        XCTAssertTrue(script.contains("data-native-navigation"))
        XCTAssertTrue(script.contains("isSidebarNavigation"))
        XCTAssertTrue(script.contains("if (isSidebarNavigation(anchor)) return false;"))
        XCTAssertTrue(script.contains("if (isSidebarNavigation(anchor)) {"))
        XCTAssertTrue(script.contains("assignNativeLocation(anchor.href)"))
        XCTAssertTrue(script.contains("prefersNativeNavigation() || !supportsProgressiveNavigation()"))
        XCTAssertTrue(script.contains("isPrimaryUnmodifiedClick"))
        XCTAssertTrue(script.contains("document.documentElement.classList.add('app-shell-navigating')"))
        XCTAssertFalse(script.contains("if (anchor.hasAttribute('data-native-navigation')) return false"))
        XCTAssertTrue(script.contains("__medialibFetchInstalled"))
        XCTAssertTrue(script.contains("refreshPromise"))
        XCTAssertTrue(script.contains("/api/v1/auth/refresh"))
        XCTAssertTrue(script.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(script.contains("response.redirected"))
        XCTAssertTrue(script.contains("request.clone()"))
        XCTAssertTrue(script.contains("new window.Request(input, init)"))
        XCTAssertTrue(script.contains("['GET', 'HEAD', 'OPTIONS']"))
        XCTAssertTrue(script.contains("8_000"))
        XCTAssertTrue(script.contains("isAnchorElement"))
        XCTAssertTrue(script.contains("different realm"))
        XCTAssertTrue(script.contains("1800"))
        XCTAssertTrue(script.contains("new AbortController()"))
        XCTAssertTrue(script.contains("oldestEntry?.controller.abort()"))
        XCTAssertTrue(script.contains("content-length"))
        XCTAssertTrue(script.contains("base-element"))
        XCTAssertTrue(script.contains("cross-origin-asset"))
        XCTAssertTrue(script.contains("inline-handler"))
        XCTAssertTrue(script.contains("headResourceKey"))
        XCTAssertTrue(script.contains("existingHeadResources"))
        XCTAssertTrue(script.contains("/assets/app-shell.js"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))

        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.declaredContentLength, asset.declaredContentLength)

        for path in pages {
            let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let html = String(data: response.body, encoding: .utf8) ?? ""
            XCTAssertEqual(response.statusCode, 200, path)
            XCTAssertTrue(html.contains("href=\"/assets/app-shell.css?v=68\""), path)
            XCTAssertTrue(html.contains("src=\"/assets/app-shell.js?v=68\""), path)
            XCTAssertTrue(html.contains("class=\"app-sidebar\""), path)
            XCTAssertTrue(html.contains("class=\"brand-copy\""), path)
            XCTAssertTrue(html.contains("家庭影音库"), path)
            XCTAssertTrue(html.contains("class=\"nav-disclosure\""), path)
            XCTAssertTrue(html.contains("class=\"sidebar-status-card\""), path)
            XCTAssertTrue(html.contains("aria-label=\"主导航\""), path)
            XCTAssertTrue(html.contains("aria-label=\"移动端主导航\""), path)
            XCTAssertTrue(html.contains("class=\"nav-icon\""), path)
            XCTAssertTrue(html.contains(">媒体库</span>"), path)
            XCTAssertTrue(html.contains(">管理</span>"), path)
        }
    }

    func testSharedWebNavigationPreservesActiveStateAndHidesManagementDestinations() {
        let member = ServerWebNavigation.render(
            active: .watching, showAdministration: false, note: .library
        )
        let administrator = ServerWebNavigation.render(
            active: .administration, showAdministration: true, note: .security
        )

        XCTAssertTrue(member.contains("href=\"/watching\""))
        XCTAssertTrue(member.contains("data-native-navigation=\"true\""))
        XCTAssertTrue(member.contains("class=\"nav-item active\" aria-current=\"page\" href=\"/watching\""))
        XCTAssertFalse(member.contains("href=\"/admin\""))
        XCTAssertFalse(member.contains("href=\"/sources\""))
        XCTAssertTrue(member.contains("href=\"/status\""))
        XCTAssertTrue(member.contains("href=\"/account\""))
        XCTAssertTrue(member.contains("href=\"/library\""))
        XCTAssertTrue(member.contains("class=\"nav-disclosure\""))
        XCTAssertTrue(member.contains("class=\"sidebar-status-card\""))
        XCTAssertTrue(administrator.contains("class=\"nav-item active\" aria-current=\"page\" href=\"/admin\""))
        XCTAssertTrue(administrator.contains("href=\"/sources\""))
        XCTAssertTrue(administrator.contains("路径、连接地址、凭据、Cookie 和令牌"))
        XCTAssertFalse(administrator.contains("app-shell.js"))
        XCTAssertFalse(administrator.contains("<script>"))
    }

    func testOrdinaryWebPagesRenderTheSharedPageHeader() {
        let library = String(
            data: router.response(for: "GET /library HTTP/1.1\r\nHost: localhost\r\n\r\n").body,
            encoding: .utf8
        ) ?? ""
        let status = String(
            data: router.response(for: "GET /status HTTP/1.1\r\nHost: localhost\r\n\r\n").body,
            encoding: .utf8
        ) ?? ""

        for html in [library, status] {
            XCTAssertTrue(html.contains("class=\"page-heading\""))
            XCTAssertTrue(html.contains("class=\"page-title-icon\""))
            XCTAssertTrue(html.contains("id=\"page-icon-blue\""))
            XCTAssertTrue(html.contains("class=\"page-title-copy\""))
        }
        XCTAssertTrue(library.contains("浏览资料库"))
        XCTAssertTrue(status.contains("服务状态"))
    }

    func testDynamicAuthenticatedHTMLAndAPIsRemainNoStoreWhenStaticAssetsAreCacheable() {
        let page = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let api = router.response(for: "GET /api/v1/library/items HTTP/1.1\r\nHost: localhost\r\n\r\n")

        for response in [page, api] {
            let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""
            XCTAssertTrue(headers.contains("Cache-Control: no-store"))
            XCTAssertFalse(headers.contains("Cache-Control: private, max-age=300"))
        }
    }

    func testNonProbeRoutesDoNotExposeData() {
        let response = router.response(for: "GET /api/v1/libraries HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "{\"error\":\"Not Found\"}")
    }

    func testProtectedMediaRoutesRequireAuthentication() {
        let unauthenticated = LocalHTTPRouter(serverID: "server-001", serverName: "客厅服务器")

        let response = unauthenticated.response(
            for: "GET /api/v1/library/items HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertTrue(
            String(data: response.serializedHeaders(), encoding: .utf8)?
                .contains("WWW-Authenticate: Bearer realm=\"MediaLIB\"") == true
        )
    }

    func testUnauthenticatedBrowserHomeRedirectsToPublicLogin() {
        let unauthenticated = LocalHTTPRouter(serverID: "server-001", serverName: "客厅服务器")

        let response = unauthenticated.response(
            for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 303)
        XCTAssertTrue(headers.contains("Location: /login"))
    }

    func testPublicLoginPageUsesSameOriginScriptUnderCSP() {
        let unauthenticated = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅 <服务器>",
            csrfToken: "known-token"
        )

        let page = unauthenticated.response(for: "GET /login HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let script = unauthenticated.response(for: "GET /assets/login.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let stylesheet = unauthenticated.response(for: "GET /assets/login.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let headers = String(data: page.serializedHeaders(), encoding: .utf8) ?? ""
        let stylesheetHeaders = String(data: stylesheet.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: stylesheet.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertTrue(html.contains("客厅 &lt;服务器&gt;"))
        XCTAssertTrue(html.contains("content=\"known-token\""))
        XCTAssertTrue(html.contains("src=\"/assets/login.js\""))
        XCTAssertTrue(html.contains("href=\"/assets/login.css\""))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(headers.contains("script-src 'self'"))
        XCTAssertEqual(script.contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains("#status"))
        XCTAssertFalse(style.contains("known-token"))
        XCTAssertFalse(style.contains("客厅"))
    }

    func testLibraryPreviewRoutesReturnOnlyProtocolDTOs() throws {
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 2, countsByType: ["movie": 2]),
            items: ServerLibraryItemsResponse(
                totalItemCount: 1,
                items: [
                    ServerLibraryItem(
                        id: "movie-1",
                        type: "movie",
                        title: "安全的卡片标题",
                        year: 2026,
                        artworkAvailable: true
                    )
                ]
            )
        )
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            librarySnapshotProvider: { _ in snapshot },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let summaryResponse = router.response(for: "GET /api/v1/library/summary HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let itemsResponse = router.response(for: "GET /api/v1/library/items HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(summaryResponse.statusCode, 200)
        XCTAssertEqual(itemsResponse.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(ServerLibrarySummary.self, from: summaryResponse.body), snapshot.summary)
        XCTAssertEqual(try JSONDecoder().decode(ServerLibraryItemsResponse.self, from: itemsResponse.body), snapshot.items)
        XCTAssertFalse(String(data: itemsResponse.body, encoding: .utf8)?.contains("filePath") ?? true)
    }

    func testWebHomeUsesSafeDTOsAndEscapesCardTitles() {
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 1, countsByType: ["movie": 1]),
            items: ServerLibraryItemsResponse(
                totalItemCount: 1,
                items: [
                    ServerLibraryItem(
                        id: "movie-1",
                        type: "movie",
                        title: "<script>alert('x')</script>",
                        year: 2026,
                        artworkAvailable: false,
                        userState: ServerMediaUserState(
                            itemID: "movie-1", positionSeconds: 300, progress: 0.5,
                            isWatched: false, playCount: 1, lastPlayedAt: nil,
                            updatedAt: Date(timeIntervalSince1970: 1)
                        )
                    )
                ]
            )
        )
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅 <服务器>",
            librarySnapshotProvider: { _ in snapshot },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let response = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(data: response.body, encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.contentType, "text/html; charset=utf-8")
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("客厅 &lt;服务器&gt;"))
        XCTAssertTrue(html.contains("name=\"medialib-csrf-token\""))
        XCTAssertTrue(html.contains("href=\"/assets/home.css\""))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(html.contains("继续观看 · 50%"))
        XCTAssertTrue(html.contains("aria-label=\"已播放 50%\""))
        XCTAssertTrue(html.contains("href=\"/library?type=movie\""))
        XCTAssertTrue(html.contains(">电影</span>"))
        XCTAssertTrue(html.contains("<span class=\"mlink\">Mlink</span>"))
        XCTAssertFalse(html.contains("filePath"))
        XCTAssertFalse(html.contains("sourcePath"))
    }

    func testHomeStyleIsPrivateCacheableAndContainsNoServerOrUserData() {
        let response = router.response(for: "GET /assets/home.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headResponse = router.response(for: "HEAD /assets/home.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""
        let headHeaders = String(data: headResponse.serializedHeaders(), encoding: .utf8) ?? ""
        let css = String(data: response.body, encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(headers.contains("Content-Type: text/css; charset=utf-8"))
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))
        XCTAssertTrue(css.contains(".summary-grid"))
        XCTAssertTrue(css.contains(".media-grid"))
        XCTAssertTrue(css.contains("@media (max-width:720px)"))
        XCTAssertFalse(css.contains("server-001"))
        XCTAssertFalse(css.contains("movie-1"))
        XCTAssertFalse(css.contains("token"))
        XCTAssertEqual(headResponse.statusCode, 200)
        XCTAssertTrue(headResponse.body.isEmpty)
        XCTAssertEqual(headerValue(named: "Content-Length", in: headHeaders), headerValue(named: "Content-Length", in: headers))
    }

    func testEveryResponseCarriesBrowserSecurityHeaders() {
        let response = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertTrue(headers.contains("Content-Security-Policy: default-src 'none'"))
        XCTAssertTrue(headers.contains("style-src 'self'"))
        XCTAssertFalse(headers.contains("style-src 'self' 'unsafe-inline'"))
        XCTAssertTrue(headers.contains("frame-ancestors 'none'"))
        XCTAssertTrue(headers.contains("Cross-Origin-Resource-Policy: same-origin"))
        XCTAssertTrue(headers.contains("Referrer-Policy: no-referrer"))
        XCTAssertTrue(headers.contains("X-Content-Type-Options: nosniff"))
        XCTAssertTrue(headers.contains("X-Frame-Options: DENY"))
        XCTAssertFalse(headers.lowercased().contains("access-control-allow-origin"))
    }

    func testLibraryBrowseParsesOnlyBoundedAllowlistedQueryAndSupportsHead() throws {
        var captured: ServerLibraryQuery?
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            libraryBrowseProvider: { query, _ in
                captured = query
                return ServerLibraryItemsPage(totalItemCount: 1, offset: query.offset, limit: query.limit, items: [])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let valid = router.response(for: "GET /api/v1/library/browse?q=%E9%93%B6%E6%B2%B3+1&type=movie&state=inProgress&offset=48&limit=48&sort=titleAscending HTTP/1.1\r\n\r\n")
        XCTAssertEqual(valid.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(searchText: "银河 1", type: "movie", offset: 48, limit: 48, sort: .titleAscending, playbackFilter: .inProgress))
        XCTAssertEqual(try JSONDecoder().decode(ServerLibraryItemsPage.self, from: valid.body).offset, 48)

        let history = router.response(for: "GET /api/v1/library/browse?state=history&sort=lastPlayedDescending&limit=48 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(history.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(limit: 48, sort: .lastPlayedDescending, playbackFilter: .history))

        let favorites = router.response(for: "GET /api/v1/library/browse?preference=favorite&limit=48 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(favorites.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(limit: 48, preferenceFilter: .favorite))

        for target in [
            "/api/v1/library/browse?limit=101",
            "/api/v1/library/browse?offset=-1",
            "/api/v1/library/browse?type=private",
            "/api/v1/library/browse?type=unknown",
            "/api/v1/library/browse?state=anyoneElse",
            "/api/v1/library/browse?preference=someoneElse",
            "/api/v1/library/browse?q=one&q=two",
            "/api/v1/library/browse?unknown=value",
            "/api/v1/library/browse?q=%ZZ"
        ] {
            XCTAssertEqual(router.response(for: "GET \(target) HTTP/1.1\r\n\r\n").statusCode, 400, target)
        }
        let head = router.response(for: "HEAD /api/v1/library/browse?limit=1 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertGreaterThan(head.declaredContentLength, 0)
    }

    func testLibraryPageUsesSameOriginScriptAndSafeDOMConstruction() {
        let router = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅 <服务器>",
            libraryCategoriesProvider: { _ in
                ServerLibraryCategoriesResponse(categories: [
                    ServerLibraryCategory(id: "movie", title: "电影 <精选>", itemCount: 12)
                ])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let page = router.response(for: "GET /library HTTP/1.1\r\n\r\n")
        let selectedPage = router.response(for: "GET /library?type=movie HTTP/1.1\r\n\r\n")
        let asset = router.response(for: "GET /assets/library.js HTTP/1.1\r\n\r\n")
        let styleAsset = router.response(for: "GET /assets/library.css HTTP/1.1\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let selectedHTML = String(data: selectedPage.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""
        let style = String(data: styleAsset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/javascript; charset=utf-8")
        XCTAssertTrue(html.contains("客厅 &lt;服务器&gt;"))
        XCTAssertTrue(html.contains("href=\"/assets/library.css\""))
        XCTAssertTrue(html.contains("src=\"/assets/library.js\""))
        XCTAssertTrue(html.contains("<option value=\"movie\">电影 &lt;精选&gt;（12）</option>"))
        XCTAssertTrue(html.contains("href=\"/library?type=movie\""))
        XCTAssertTrue(selectedHTML.contains("class=\"nav-item nav-category active\" aria-current=\"page\" href=\"/library?type=movie\""))
        XCTAssertFalse(selectedHTML.contains("class=\"nav-item active\" aria-current=\"page\" href=\"/library\""))
        let watching = router.response(for: "GET /watching HTTP/1.1\r\n\r\n")
        let watchingHTML = String(data: watching.body, encoding: .utf8) ?? ""
        XCTAssertEqual(watching.statusCode, 200)
        XCTAssertTrue(watchingHTML.contains("data-playback-filter=\"inProgress\""))
        let history = router.response(for: "GET /history HTTP/1.1\r\n\r\n")
        let historyHTML = String(data: history.body, encoding: .utf8) ?? ""
        XCTAssertEqual(history.statusCode, 200)
        XCTAssertTrue(historyHTML.contains("data-page-route=\"/history\""))
        XCTAssertTrue(historyHTML.contains("data-playback-filter=\"history\""))
        XCTAssertTrue(historyHTML.contains("data-default-sort=\"lastPlayedDescending\""))
        let favorites = router.response(for: "GET /favorites HTTP/1.1\r\n\r\n")
        let favoritesHTML = String(data: favorites.body, encoding: .utf8) ?? ""
        XCTAssertEqual(favorites.statusCode, 200)
        XCTAssertTrue(favoritesHTML.contains("data-page-route=\"/favorites\""))
        XCTAssertTrue(favoritesHTML.contains("data-preference-filter=\"favorite\""))
        XCTAssertTrue(favoritesHTML.contains("class=\"nav-item active\" aria-current=\"page\" href=\"/favorites\""))
        let watchlist = router.response(for: "GET /watchlist HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: watchlist.body, encoding: .utf8) ?? "").contains("data-preference-filter=\"watchlist\""))
        let watched = router.response(for: "GET /watched HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: watched.body, encoding: .utf8) ?? "").contains("data-playback-filter=\"watched\""))
        let ratings = router.response(for: "GET /ratings HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: ratings.body, encoding: .utf8) ?? "").contains("data-preference-filter=\"rated\""))
        let unwatched = router.response(for: "GET /unwatched HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: unwatched.body, encoding: .utf8) ?? "").contains("data-playback-filter=\"unwatched\""))
        XCTAssertTrue(style.contains("prefers-reduced-motion"))
        XCTAssertTrue(html.contains("Mlink"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("encodeURIComponent"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("/api/v1/images/"))
        XCTAssertTrue(script.contains("image.loading = 'lazy'"))
        XCTAssertTrue(script.contains("image.decoding = 'async'"))
        XCTAssertTrue(script.contains("lastPlayedDescending"))
        XCTAssertTrue(script.contains("'history'"))
        XCTAssertTrue(script.contains("state.lastPlayedAt"))
        XCTAssertTrue(script.contains("params.set('preference', preferenceFilter)"))
        XCTAssertTrue(script.contains("void loadPage();"))
        XCTAssertFalse(script.contains("/api/v1/library/categories"), "分类应随认证页面首屏交付，避免第二个导航请求")
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("eval("))
    }

    func testAuthenticatedPageCopyUsesRuntimeServerNameAndDetailSidebarKeepsCategories() {
        let categories = [
            ServerLibraryCategory(id: "movie", title: "电影", itemCount: 12)
        ]
        let status = ServerWebStatusPage.render(
            serverName: "客厅 <服务器>", csrfToken: "csrf", categories: categories
        )
        let sources = ServerWebSourcesPage.render(
            serverName: "客厅 <服务器>", csrfToken: "csrf", categories: categories
        )
        let administration = ServerWebAdministrationPage.render(
            serverName: "客厅 <服务器>", csrfToken: "csrf", categories: categories
        )
        let detail = ServerMediaItemDetail(
            id: "movie-1", type: "movie", title: "电影", originalTitle: nil,
            year: nil, overview: nil, genres: [], communityRating: nil,
            runtimeSeconds: nil, videoCodec: nil, audioCodec: nil, resolution: nil,
            artworkAvailable: false, backdropAvailable: false,
            canDirectPlay: true, canTranscode: false
        )
        let detailPage = ServerWebMediaDetailPage.render(
            serverName: "客厅 <服务器>", detail: detail, csrfToken: "csrf",
            showAdministration: false, categories: categories
        )

        XCTAssertTrue(status.contains("客厅 &lt;服务器&gt; 的受认证状态视图"))
        XCTAssertTrue(sources.contains("客厅 &lt;服务器&gt; 当前已配置的媒体来源"))
        XCTAssertTrue(administration.contains("客厅 &lt;服务器&gt; 的用户"))
        XCTAssertFalse(status.contains("(serverName)"))
        XCTAssertFalse(sources.contains("(serverName)"))
        XCTAssertFalse(administration.contains("(serverName)"))
        XCTAssertTrue(detailPage.contains("class=\"nav-item nav-category\" href=\"/library?type=movie\""))
        XCTAssertTrue(detailPage.contains(">电影</span>"))
    }

    func testLibraryStyleIsPrivateCacheableAndContainsNoServerOrUserData() {
        let asset = router.response(for: "GET /assets/library.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let head = router.response(for: "HEAD /assets/library.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: asset.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/css; charset=utf-8")
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".filters"))
        XCTAssertTrue(style.contains("@media (max-width:720px)"))
        XCTAssertFalse(style.contains("server-001"))
        XCTAssertFalse(style.contains("token"))
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.declaredContentLength, asset.declaredContentLength)
    }

    func testGlobalSearchPageReusesAuthorizedBoundedSearchWithoutLosingDeepLinkRoute() {
        let router = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅 <服务器>",
            authenticationProvider: { _ in .testAdministrator() }
        )

        let page = router.response(for: "GET /search?q=%E6%B5%8B%E8%AF%95 HTTP/1.1\r\n\r\n")
        let head = router.response(for: "HEAD /search HTTP/1.1\r\n\r\n")
        let asset = router.response(for: "GET /assets/library.js HTTP/1.1\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertTrue(html.contains("全局搜索"))
        XCTAssertTrue(html.contains("data-page-route=\"/search\""))
        XCTAssertTrue(html.contains("href=\"/search\""))
        XCTAssertTrue(script.contains("pageRoute"))
        XCTAssertTrue(script.contains("/api/v1/library/browse"))
        XCTAssertFalse(script.contains("innerHTML"))
    }

    func testArtworkRouteUsesOpaqueAuthorizedIDBoundedKindAndPrivateCache() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: imageURL) }
        var captured: (String, ServerArtworkKind)?
        let router = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅服务器",
            artworkAssetProvider: { id, kind, _ in
                captured = (id, kind)
                guard id == "movie 1", kind == .poster else { return nil }
                return ServerMediaAsset(id: id, fileURL: imageURL, byteLength: 4)
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let response = router.response(for: "GET /api/v1/images/movie%201/poster HTTP/1.1\r\n\r\n")
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.contentType, "image/png")
        XCTAssertEqual(response.declaredContentLength, 4)
        XCTAssertEqual(captured?.0, "movie 1")
        XCTAssertEqual(captured?.1, .poster)
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(headers.contains(imageURL.path))
        guard case let .fileRange(range) = response.payload else { return XCTFail("Expected streamed image") }
        XCTAssertEqual(range.length, 4)

        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie%2F1/poster HTTP/1.1\r\n\r\n").statusCode, 404)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie%201/svg HTTP/1.1\r\n\r\n").statusCode, 404)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie%201/poster/extra HTTP/1.1\r\n\r\n").statusCode, 404)
        let head = router.response(for: "HEAD /api/v1/images/movie%201/poster HTTP/1.1\r\n\r\n")
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.declaredContentLength, 4)
    }

    func testLibraryPreviewReturnsSafeFailureWhenCatalogIsUnavailable() {
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            librarySnapshotProvider: { _ in throw CatalogFailure.unavailable },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let response = router.response(for: "GET /api/v1/library/summary HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "{\"error\":\"Service Unavailable\"}")
    }

    func testMutatingMethodsAreRejected() {
        let response = router.response(for: "POST /health HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(response.statusCode, 405)
        XCTAssertTrue(String(data: response.serialized(), encoding: .utf8)?.contains("Allow: GET, HEAD") == true)
    }

    func testStreamRouteReturnsAChunkedPartialFileResponseWithoutPathLeakage() throws {
        let fixtureURL = try makeFixtureFile(contents: Data("0123456789".utf8))
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            mediaAssetProvider: { id, _, _ in
                guard id == "movie-1" else { return nil }
                return ServerMediaAsset(id: id, fileURL: fixtureURL, byteLength: 10)
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let response = router.response(
            for: "GET /api/v1/stream/movie-1 HTTP/1.1\r\nHost: localhost\r\nRange: bytes=2-5\r\n\r\n"
        )
        let serializedHeaders = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.declaredContentLength, 4)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertTrue(serializedHeaders.contains("Content-Range: bytes 2-5/10"))
        XCTAssertTrue(serializedHeaders.contains("Accept-Ranges: bytes"))
        XCTAssertFalse(serializedHeaders.contains(fixtureURL.path))
        guard case let .fileRange(range) = response.payload else {
            return XCTFail("Expected a chunked file response")
        }
        XCTAssertEqual(range.offset, 2)
        XCTAssertEqual(range.length, 4)
    }

    func testStreamRouteRejectsMalformedAndUnknownRangeRequests() throws {
        let fixtureURL = try makeFixtureFile(contents: Data("0123456789".utf8))
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            mediaAssetProvider: { id, _, _ in
                id == "movie-1" ? ServerMediaAsset(id: id, fileURL: fixtureURL, byteLength: 10) : nil
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let malformed = router.response(
            for: "GET /api/v1/stream/movie-1 HTTP/1.1\r\nRange: bytes=0-1,4-5\r\n\r\n"
        )
        let unknown = router.response(for: "GET /api/v1/stream/no-such-item HTTP/1.1\r\n\r\n")

        XCTAssertEqual(malformed.statusCode, 416)
        XCTAssertTrue(String(data: malformed.serializedHeaders(), encoding: .utf8)?.contains("Content-Range: bytes */10") == true)
        XCTAssertEqual(unknown.statusCode, 404)
    }

    func testFileRangeStreamerEmitsOnlyRequestedBytesInBoundedChunks() throws {
        let fixtureURL = try makeFixtureFile(contents: Data("0123456789".utf8))
        var chunks: [Data] = []

        try streamFileRange(
            LocalHTTPFileRange(url: fixtureURL, offset: 2, length: 6),
            maximumChunkLength: 2
        ) { chunk in
            chunks.append(chunk)
            return true
        }

        XCTAssertEqual(chunks.map(\.count), [2, 2, 2])
        XCTAssertEqual(Data(chunks.joined()), Data("234567".utf8))
    }

    func testPlaybackInfoRouteUsesSafeProbeDTOAndHidesFailures() throws {
        let info = ServerMediaPlaybackInfo(
            itemID: "movie-1",
            durationSeconds: 90,
            container: "mp4",
            bitrate: 2_000_000,
            streams: [
                ServerMediaStreamInfo(
                    id: 0, type: "video", codec: "h264", profile: nil,
                    language: nil, width: 1280, height: 720, channels: nil
                )
            ]
        )
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            playbackInfoProvider: { id, _ in
                guard id == "movie-1" else { return nil }
                return info
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let response = router.response(for: "GET /api/v1/playback/info/movie-1 HTTP/1.1\r\n\r\n")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(ServerMediaPlaybackInfo.self, from: response.body), info)
        XCTAssertFalse(String(data: response.body, encoding: .utf8)?.contains("filePath") ?? true)

        let failingRouter = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            playbackInfoProvider: { _, _ in throw ProbeFailure.pathInError },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let failure = failingRouter.response(for: "GET /api/v1/playback/info/movie-1 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(failure.statusCode, 503)
        XCTAssertFalse(String(data: failure.body, encoding: .utf8)?.contains("private") ?? true)
    }

    func testWebVTTSubtitleRoutesRequireAuthorizedOpaqueItemAndNeverExposePaths() throws {
        let subtitle = try makeFixtureFile(contents: Data("WEBVTT\n\n".utf8))
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            webVTTSubtitleTracksProvider: { itemID, _ in
                itemID == "movie-1" ? [ServerWebVTTSubtitleTrack(id: 0, label: "字幕 1")] : nil
            },
            webVTTSubtitleAssetProvider: { itemID, trackID, _ in
                guard itemID == "movie-1", trackID == 0 else { return nil }
                return ServerMediaAsset(id: itemID, fileURL: subtitle, byteLength: 8)
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let list = router.response(for: "GET /api/v1/playback/subtitles/movie-1 HTTP/1.1\r\n\r\n")
        let asset = router.response(for: "GET /api/v1/subtitles/movie-1/0 HTTP/1.1\r\n\r\n")
        let malformed = router.response(for: "GET /api/v1/subtitles/movie-1/0/extra HTTP/1.1\r\n\r\n")

        XCTAssertEqual(list.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode([ServerWebVTTSubtitleTrack].self, from: list.body), [ServerWebVTTSubtitleTrack(id: 0, label: "字幕 1")])
        XCTAssertFalse((String(data: list.body, encoding: .utf8) ?? "").contains(subtitle.path))
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/vtt; charset=utf-8")
        XCTAssertEqual(asset.declaredContentLength, Data("WEBVTT\n\n".utf8).count)
        XCTAssertTrue(asset.body.isEmpty, "文件内容会由 socket 流式写出，路由层不复制进内存 body")
        XCTAssertEqual(malformed.statusCode, 404)
    }

    func testWebPlayerDoesNotExposeServerTranscodeRoutes() {
        XCTAssertEqual(router.response(for: "POST /api/v1/playback/hls/movie-1 HTTP/1.1\r\n\r\n").statusCode, 405)
        XCTAssertEqual(router.response(for: "GET /api/v1/hls/session/index.m3u8 HTTP/1.1\r\n\r\n").statusCode, 404)
        XCTAssertEqual(router.response(for: "DELETE /api/v1/hls/session HTTP/1.1\r\n\r\n").statusCode, 405)
    }

    private func makeFixtureFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func headerValue(named name: String, in headers: String) -> String? {
        headers
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(name): ") }
            .map { String($0.dropFirst(name.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private enum ProbeFailure: LocalizedError {
    case pathInError

    var errorDescription: String? { "/private/secret/media.mkv" }
}

private enum CatalogFailure: Error {
    case unavailable
}
