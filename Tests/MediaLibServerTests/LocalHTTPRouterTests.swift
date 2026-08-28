import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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
        XCTAssertTrue(persistentHeaders.contains("Cross-Origin-Embedder-Policy: require-corp"))
        XCTAssertTrue(persistentHeaders.contains("Cross-Origin-Opener-Policy: same-origin"))
        // `same-origin`，不是 `no-referrer`：详情页的「返回」目标由 `Referer` 推导，
        // 一个字节都不发等于让每一页都返回首页。跨站请求仍然不带任何来源信息。
        XCTAssertTrue(persistentHeaders.contains("Referrer-Policy: same-origin"))
        XCTAssertTrue(persistentHeaders.contains("X-Content-Type-Options: nosniff"))
        XCTAssertTrue(persistentHeaders.contains("X-Frame-Options: DENY"))
    }

    func testAuthenticatedStatusPageKeepsMachineHealthProbeSeparateAndUsesSafeScript() {
        let page = router.response(for: "GET /admin HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let head = router.response(for: "HEAD /admin HTTP/1.1\r\nHost: localhost\r\n\r\n")
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
        XCTAssertTrue(html.contains("src=\"/assets/status.js?v="))
        XCTAssertTrue(html.contains("href=\"/assets/status.css?v="))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(script.contains("credentials:'same-origin'"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".status-policy"))
        XCTAssertFalse(style.contains("server-001"))
    }

    func testWebShellStyleIsSameOriginCacheableAndUsedByEveryPageFamily() {
        let asset = router.response(for: "GET /assets/app-shell.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let head = router.response(for: "HEAD /assets/app-shell.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let tokensAsset = router.response(for: "GET /assets/tokens.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let baseAsset = router.response(for: "GET /assets/base.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let primitivesAsset = router.response(for: "GET /assets/primitives.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: asset.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: asset.body, encoding: .utf8) ?? ""
        let tokens = String(data: tokensAsset.body, encoding: .utf8) ?? ""
        let base = String(data: baseAsset.body, encoding: .utf8) ?? ""
        let primitives = String(data: primitivesAsset.body, encoding: .utf8) ?? ""
        let playbackPages = ["/", "/category/video", "/search", "/watching", "/history", "/favorites", "/watchlist", "/ratings", "/watched", "/unwatched", "/music/songs", "/music/albums", "/music/artists", "/music/playlists", "/music/recent", "/people", "/collections", "/photos", "/queue", "/account", "/vault"]
        let administrationPages = ["/admin", "/admin/users", "/admin/sessions", "/admin/libraries", "/admin/playback", "/admin/network", "/admin/tasks", "/admin/storage", "/admin/security", "/admin/logs"]
        let pages = playbackPages + administrationPages

        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/css; charset=utf-8")
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))

        // The cascade order is declared once, in the first sheet every page loads.
        XCTAssertEqual(tokensAsset.statusCode, 200)
        XCTAssertTrue(tokens.hasPrefix("@layer tokens, base, primitives, shell;"))
        XCTAssertTrue(tokens.contains("--bg-canvas"))
        XCTAssertTrue(tokens.contains("--glass-thick-blur"))
        XCTAssertTrue(tokens.contains("--space-4"))
        XCTAssertTrue(tokens.contains("--type-body-size"))

        // Dark is authored twice on purpose: once for the system preference and
        // once for an explicit choice, so neither state can go undefined.
        XCTAssertTrue(tokens.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(tokens.contains(":root:not([data-theme=\"light\"])"))
        XCTAssertTrue(tokens.contains(":root[data-theme=\"dark\"]"))

        // Translucency must degrade on all three signals, from the tokens
        // themselves, so every glass surface falls back together.
        XCTAssertTrue(tokens.contains("@supports not ((backdrop-filter: blur(1px))"))
        XCTAssertTrue(tokens.contains("prefers-reduced-transparency: reduce"))
        XCTAssertTrue(tokens.contains("prefers-contrast: more"))
        XCTAssertTrue(tokens.contains("--glass-thick-opaque"))

        XCTAssertEqual(baseAsset.statusCode, 200)
        XCTAssertTrue(base.contains("@layer base"))
        XCTAssertTrue(base.contains("prefers-reduced-motion: reduce"))
        // Reduced motion substitutes a cross-fade; it must not silence loading
        // feedback the way a blanket `animation: none` did.
        XCTAssertFalse(base.contains("animation: none !important;\n        }"))
        XCTAssertTrue(base.contains("ui-reduced-pulse"))
        XCTAssertTrue(base.contains(":focus-visible"))

        XCTAssertEqual(primitivesAsset.statusCode, 200)
        XCTAssertTrue(primitives.contains("@layer primitives"))
        for component in [".ui-btn", ".ui-input", ".ui-card", ".ui-glass", ".ui-empty", ".ui-skeleton", ".ui-toast", ".ui-modal", ".ui-table", ".ui-segmented", ".ui-media-grid"] {
            XCTAssertTrue(primitives.contains(component), component)
        }
        XCTAssertTrue(primitives.contains("(hover: none), (pointer: coarse)"))

        XCTAssertTrue(style.contains("@layer shell"))
        XCTAssertTrue(style.contains(".app-sidebar"))
        XCTAssertTrue(style.contains(".app-tabbar"))
        XCTAssertTrue(style.contains(".app-drawer-state:checked"))
        XCTAssertTrue(style.contains("grid-template-columns: var(--sidebar-width)"))
        XCTAssertTrue(style.contains("min-height: 100dvh"))
        XCTAssertTrue(style.contains("app-shell-navigating::before"))
        XCTAssertTrue(style.contains("#medialib-audio-dock"))
        // The app frame styles the frame only; controls live in the primitives.
        XCTAssertFalse(style.contains(".ui-btn-primary {"))

        let scriptAsset = router.response(for: "GET /assets/app-shell.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let scriptHeaders = String(data: scriptAsset.serializedHeaders(), encoding: .utf8) ?? ""
        let script = String(data: scriptAsset.body, encoding: .utf8) ?? ""
        XCTAssertEqual(scriptAsset.statusCode, 200)
        XCTAssertEqual(scriptAsset.contentType, "text/javascript; charset=utf-8")
        XCTAssertTrue(scriptHeaders.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertTrue(script.contains("DOMParser"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("medialib:pagewillunload"))
        XCTAssertTrue(script.contains("maxPageCacheEntries = 24"))
        XCTAssertFalse(script.contains("maxPageCacheEntries = 32"))
        XCTAssertTrue(script.contains("pageCacheLifetime = 60_000"))
        XCTAssertTrue(script.contains("__medialibPageCache"))
        XCTAssertTrue(script.contains("__medialibLibraryBrowseCache"))
        XCTAssertTrue(script.contains("primeLibraryBrowse"))
        XCTAssertTrue(script.contains("libraryBrowseCacheLifetime = 30_000"))
        XCTAssertTrue(script.contains("invalidatesLibraryBrowseCache"))
        XCTAssertTrue(script.contains("url.pathname.startsWith('/api/v1/user-media/')"))
        XCTAssertTrue(script.contains("window.__medialibPageCache?.clear?.()"))
        XCTAssertTrue(script.contains("navigationSerial"))
        XCTAssertTrue(script.contains("activeNavigationRequest"))
        XCTAssertTrue(script.contains("navigationFallbackTimer"))
        XCTAssertTrue(script.contains("prefersNativeNavigation"))
        XCTAssertTrue(script.contains("supportsProgressiveNavigation"))
        XCTAssertTrue(script.contains("window.navigator?.maxTouchPoints"))
        XCTAssertTrue(script.contains("eventAnchor"))
        XCTAssertTrue(script.contains("composedPath"))
        XCTAssertTrue(script.contains("const nativeDetailRoute"))
        XCTAssertTrue(script.contains("/^\\/series\\/[^/]+(?:\\/play)?$/"))
        XCTAssertTrue(script.contains("if (nativeDetailRoute(url.pathname)) return true;"))
        XCTAssertTrue(script.contains("pointerdown"))
        XCTAssertTrue(script.contains("document.addEventListener('pointerover'"))
        XCTAssertTrue(script.contains("scheduleNavigationWarm"))
        XCTAssertTrue(script.contains("connection?.saveData !== true"))
        XCTAssertTrue(script.contains("['slow-2g', '2g']"))
        XCTAssertTrue(script.contains("}, 140)"))
        XCTAssertFalse(script.contains("const prefetchTimers"))
        XCTAssertTrue(script.contains("prefersNativeNavigation() || !supportsProgressiveNavigation()) return;"))
        XCTAssertTrue(script.contains("{ capture: true }"))
        XCTAssertTrue(script.contains("window.location.assign(url.href)"))
        XCTAssertTrue(script.contains("window.location.assign(anchor.href)"))
        XCTAssertTrue(script.contains("window.location.href = href"))
        XCTAssertTrue(script.contains("const assignNativeLocation = href"))
        XCTAssertTrue(script.contains("const requiresNativeDocumentNavigation"))
        XCTAssertTrue(script.contains("if (requiresNativeDocumentNavigation(anchor))"))
        XCTAssertTrue(script.contains("const supportsProgressiveRoute"))
        XCTAssertTrue(script.contains("'/music/albums'"))
        // 导航归属的两条铁律，钉的是行为不是某一行的写法：
        //   1. 详情/播放页始终整页加载（重媒体控制器，且音乐要在那里让位）；
        //   2. 渐进白名单内的路由一律就地换文档——否则每翻一页都重建整个文档，
        //      正在放的音乐会断，侧栏展开状态与滚动位置也会丢。
        XCTAssertTrue(script.contains("if (nativeDetailRoute(url.pathname)) return true;"))
        XCTAssertTrue(script.contains("if (supportsProgressiveRoute(url.pathname)) return false;"))
        // 侧栏是常驻导航，不跟着内容重建：活着的那个节点被搬进新文档。
        XCTAssertTrue(script.contains("incomingSidebar.replaceWith(liveSidebar)"))
        XCTAssertFalse(script.contains("isSidebarNavigation"))
        XCTAssertTrue(script.contains("cannot swallow a sidebar item"))
        XCTAssertTrue(script.contains("if (prefersNativeNavigation() || !supportsProgressiveNavigation()) {"))
        XCTAssertFalse(script.contains("try { navigate(new URL(anchor.href, window.location.href)); } catch (_) { assignNativeLocation(anchor.href); }"))
        XCTAssertTrue(script.contains("document.documentElement.classList.add('app-shell-navigating')"))
        XCTAssertFalse(script.contains("if (anchor.hasAttribute('data-native-navigation')) return false"))
        XCTAssertTrue(script.contains("__medialibFetchInstalled"))
        XCTAssertTrue(script.contains("refreshPromise"))
        XCTAssertTrue(script.contains("/api/v1/auth/refresh"))
        XCTAssertTrue(script.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(script.contains("window.__medialibRefreshSession = refreshSession"))
        XCTAssertTrue(script.contains("parsePage = async (url, signal, mayRefresh = true)"))
        XCTAssertTrue(script.contains("return parsePage(url, signal, false)"))
        XCTAssertTrue(script.contains("response.redirected"))
        XCTAssertTrue(script.contains("request.clone()"))
        XCTAssertTrue(script.contains("new window.Request(input, init)"))
        XCTAssertTrue(script.contains("['GET', 'HEAD', 'OPTIONS']"))
        XCTAssertTrue(script.contains("8_000"))
        XCTAssertTrue(script.contains("isAnchorElement"))
        XCTAssertTrue(script.contains("different realm"))
        XCTAssertTrue(script.contains("navigationFallbackDelay = 4_000"))
        XCTAssertFalse(script.contains("navigationFallbackDelay = 800"))
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
            XCTAssertTrue(html.contains("href=\"/assets/tokens.css?v="), path)
            XCTAssertTrue(html.contains("href=\"/assets/base.css?v="), path)
            XCTAssertTrue(html.contains("href=\"/assets/primitives.css?v="), path)
            XCTAssertTrue(html.contains("href=\"/assets/app-shell.css?v="), path)
            XCTAssertTrue(html.contains("src=\"/assets/app-shell.js?v="), path)
            // The appearance script is render-blocking and first, so a stored
            // dark choice never flashes a white page.
            XCTAssertTrue(html.contains("<script src=\"/assets/appearance.js?v="), path)
            XCTAssertFalse(html.contains("appearance.js?v=88\" defer"), path)
            XCTAssertTrue(html.contains("class=\"app-sidebar\""), path)
            XCTAssertTrue(html.contains("class=\"app-drawer-state\""), path)
            XCTAssertTrue(html.contains("class=\"app-status-card\""), path)
            XCTAssertTrue(html.contains("data-appearance-mode=\"auto\""), path)
            if administrationPages.contains(path) {
                XCTAssertFalse(html.contains("class=\"app-tabbar\""), path)
                XCTAssertFalse(html.contains("class=\"nav-disclosure\""), path)
                XCTAssertTrue(html.contains("aria-label=\"管理导航\""), path)
                XCTAssertTrue(html.contains(">管理控制台</p>"), path)
                XCTAssertFalse(html.contains(">媒体库</p>"), path)
            } else {
                XCTAssertTrue(html.contains("class=\"app-tabbar\""), path)
                XCTAssertTrue(html.contains("class=\"nav-disclosure\""), path)
                XCTAssertTrue(html.contains("aria-label=\"主导航\""), path)
                XCTAssertTrue(html.contains(">媒体库</p>"), path)
                XCTAssertFalse(html.contains(">管理控制台</p>"), path)
            }
            // The override stylesheet that used to flatten every page to white
            // is gone, along with the fake macOS window furniture.
            XCTAssertFalse(html.contains("reference-system.css"), path)
            XCTAssertFalse(html.contains("mac-window-controls"), path)
            XCTAssertFalse(html.contains("<style"), path)
            XCTAssertFalse(html.contains("onclick="), path)
            XCTAssertFalse(html.contains("color-scheme\" content=\"light\""), path)
        }
    }

    func testAuthenticatedPagesUseReferenceSidebarGeometryInsteadOfTheLegacyTheme() {
        let home = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let songs = router.response(for: "GET /music/songs HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let homeHTML = String(data: home.body, encoding: .utf8) ?? ""
        let songsHTML = String(data: songs.body, encoding: .utf8) ?? ""

        XCTAssertEqual(home.statusCode, 200)
        XCTAssertEqual(songs.statusCode, 200)
        for page in [homeHTML, songsHTML] {
            XCTAssertTrue(page.contains("app-sidebar"))
            XCTAssertTrue(page.contains("app-tabbar"))
            XCTAssertTrue(page.contains("app-nav-title"))
        }
        let shell = String(data: router.response(for: "GET /assets/app-shell.css HTTP/1.1\r\nHost: localhost\r\n\r\n").body, encoding: .utf8) ?? ""
        XCTAssertTrue(shell.contains("--sidebar-width"))
        XCTAssertTrue(shell.contains("var(--glass-thick-bg)"))
        XCTAssertTrue(shell.contains(".app-drawer-scrim"))
        XCTAssertTrue(shell.contains(".nav-item[aria-current]"))
    }

    func testAuditLogPageUsesSharedServerFilteredControlsAndPaging() {
        let page = router.response(for: "GET /admin/logs HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let script = router.response(for: "GET /assets/operations.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(decoding: page.body, as: UTF8.self)
        let javascript = String(decoding: script.body, as: UTF8.self)

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertTrue(html.contains("<form class=\"app-page-search\" id=\"log-search-form\""))
        XCTAssertTrue(html.contains("id=\"log-category\""))
        XCTAssertTrue(html.contains("id=\"log-outcome\""))
        XCTAssertTrue(html.contains("id=\"audit-load-more\""))
        XCTAssertTrue(javascript.contains("parameters.set('category', category)"))
        XCTAssertTrue(javascript.contains("parameters.set('outcome', outcome)"))
        XCTAssertTrue(javascript.contains("logEvents.concat(events)"))
        XCTAssertFalse(javascript.contains("logEvents.filter"))
    }

    func testSharedWebNavigationPreservesActiveStateAndHidesManagementDestinations() {
        let member = ServerWebNavigation.render(
            active: .home, showAdministration: false, note: .library, extras: .empty
        )
        let administrator = ServerWebNavigation.render(
            active: .administration, showAdministration: true, note: .security, extras: .empty,
            context: .administration
        )

        XCTAssertTrue(member.contains("href=\"/\""))
        XCTAssertTrue(member.contains("data-native-navigation=\"true\""))
        XCTAssertTrue(member.contains("class=\"nav-item\" href=\"/\" data-native-navigation=\"true\" aria-current=\"page\""))
        // 「我的」分组已取消，与客户端一致。继续观看不再是侧栏条目——它是视频库
        // 控制栏里的一个观看状态胶囊；想看和喜欢则移到了「视频」分组下面。
        XCTAssertFalse(member.contains("href=\"/watching\""))
        XCTAssertFalse(member.contains("app-nav-title\">我的"))
        XCTAssertTrue(member.contains("href=\"/watchlist\""))
        XCTAssertTrue(member.contains("href=\"/favorites\""))
        XCTAssertTrue(member.contains("href=\"/vault\""))
        XCTAssertTrue(member.contains("href=\"/albums\""))
        XCTAssertFalse(member.contains("href=\"/admin\""))
        XCTAssertFalse(member.contains("href=\"/sources\""))
        XCTAssertFalse(member.contains("href=\"/status\""))
        XCTAssertTrue(member.contains("href=\"/account\""))
        XCTAssertTrue(member.contains("href=\"/category/video\""))
        XCTAssertTrue(member.contains("href=\"/category/video\" data-native-navigation=\"true\""))
        XCTAssertTrue(member.contains("class=\"nav-disclosure\""))
        XCTAssertTrue(member.contains("href=\"/music/songs\""))
        XCTAssertFalse(member.contains("\\n"))
        // 空分类不再出现在侧栏（与客户端一致）：这个夹具没有照片，所以「照片」这一
        // 条不该被画出来；「相册 · 全部」是分组入口，始终保留。
        XCTAssertFalse(member.contains("href=\"/photos\""))
        XCTAssertTrue(member.contains("href=\"/albums\""))
        XCTAssertTrue(member.contains("class=\"nav-disclosure\""))
        // 三个可展开分组：视频 / 音乐 / 相册，与客户端一致。
        XCTAssertEqual(member.components(separatedBy: "class=\"nav-disclosure\"").count - 1, 3)
        XCTAssertEqual(administrator.components(separatedBy: "class=\"nav-disclosure\"").count - 1, 0)
        XCTAssertTrue(member.contains("class=\"app-status-card\""))
        XCTAssertTrue(administrator.contains("href=\"/admin/users\" data-native-navigation=\"true\" aria-current=\"page\""))
        XCTAssertTrue(administrator.contains("href=\"/admin/libraries\""))
        XCTAssertTrue(administrator.contains("敏感信息不会显示在这里"))
        XCTAssertFalse(administrator.contains("app-shell.js"))
        XCTAssertFalse(administrator.contains("<script>"))
    }

    func testOrdinaryWebPagesUseTheAppropriateSystemPageHeader() {
        let library = String(
            data: router.response(for: "GET /category/video HTTP/1.1\r\nHost: localhost\r\n\r\n").body,
            encoding: .utf8
        ) ?? ""
        let status = String(
            data: router.response(for: "GET /admin HTTP/1.1\r\nHost: localhost\r\n\r\n").body,
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(library.contains("class=\"app-page-head\""))
        XCTAssertTrue(library.contains("class=\"app-eyebrow\""))
        // The search field is part of the page-header contract, in the trailing
        // slot, rather than a loose block each page positions for itself.
        XCTAssertTrue(library.contains("class=\"app-page-search\""))
        XCTAssertTrue(library.contains("class=\"app-page-actions\""))
        XCTAssertTrue(status.contains("class=\"status-grid\""))
        XCTAssertTrue(status.contains("class=\"ui-card status-runtime\""))
        XCTAssertTrue(status.contains("id=\"state-title\""))
        XCTAssertTrue(status.contains("class=\"status-policy\""))
        // A scoped browse page is titled by its scope, not "browse everything".
        XCTAssertTrue(library.contains("视频"))
        XCTAssertTrue(status.contains("仪表盘"))
    }

    func testDynamicAuthenticatedHTMLAndAPIsRemainNoStoreWhenStaticAssetsAreCacheable() {
        let page = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let api = router.response(for: "GET /api/v1/library/items HTTP/1.1\r\nHost: localhost\r\n\r\n")

        // Authenticated HTML and API responses must both be uncacheable, but they
        // do not use the same directive string: HTML additionally revalidates.
        // Asserting one literal prefix for both silently never matched the HTML.
        for response in [page, api] {
            let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""
            XCTAssertTrue(headers.contains("no-store"), "预期不可缓存，实际响应头：\(headers)")
            XCTAssertFalse(headers.contains("Cache-Control: private, max-age=31536000, immutable"))
        }
        let pageHeaders = String(data: page.serializedHeaders(), encoding: .utf8) ?? ""
        XCTAssertTrue(pageHeaders.contains("Cache-Control: no-cache, no-store, must-revalidate"))
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

    func testUnauthenticatedHTMLDeepLinkRedirectsToPublicLoginWithoutChangingAPISemantics() {
        let unauthenticated = LocalHTTPRouter(serverID: "server-001", serverName: "客厅服务器")

        let page = unauthenticated.response(
            for: "GET /item/episode-2?autoplay=1 HTTP/1.1\r\nHost: localhost\r\nAccept: text/html,application/xhtml+xml\r\n\r\n"
        )
        let api = unauthenticated.response(
            for: "GET /api/v1/auth/me HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\n\r\n"
        )
        let headers = String(data: page.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 303)
        XCTAssertTrue(headers.contains("Location: /login?next=L2l0ZW0vZXBpc29kZS0yP2F1dG9wbGF5PTE"))
        XCTAssertEqual(api.statusCode, 401)
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
        XCTAssertTrue(html.contains("src=\"/assets/login.js?v="))
        XCTAssertTrue(html.contains("href=\"/assets/login.css?v="))
        XCTAssertTrue(html.contains("action=\"/login\" method=\"post\""))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(headers.contains("script-src 'self'"))
        XCTAssertEqual(script.contentType, "text/javascript; charset=utf-8")
        let scriptText = String(data: script.body, encoding: .utf8) ?? ""
        XCTAssertTrue(scriptText.contains("/api/v1/auth/refresh"))
        XCTAssertTrue(scriptText.contains("credentials: 'same-origin'"))
        XCTAssertTrue(scriptText.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(scriptText.contains("const safeReturnPath"))
        XCTAssertTrue(scriptText.contains("new URLSearchParams(window.location.search).get('next')"))
        XCTAssertTrue(scriptText.contains("new TextDecoder().decode"))
        XCTAssertTrue(scriptText.contains("location.replace(safeReturnPath)"))
        XCTAssertTrue(scriptText.contains("!value.startsWith('//')"))
        XCTAssertTrue(scriptText.contains("!value.includes('\\\\')"))
        XCTAssertFalse(scriptText.contains("document.cookie"))
        XCTAssertFalse(scriptText.contains("localStorage"))
        XCTAssertFalse(scriptText.contains("sessionStorage"))
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".login-status"))
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

    /// 首页那两栏（最近添加／高分精选）与首页看板同口径：跨本地与远程。
    ///
    /// 少了这一条，同一页上「继续观看」里有 Emby 的剧、「最近添加」里一部都没有。
    /// 而一级分类页走的仍然是不含远程的那条查询——两者用的是同一个 provider，
    /// 所以差别只能在查询本身上看。
    func testHomeShelvesReachAcrossRemoteSourcesWhileCategoryPagesDoNot() {
        let recorded = QueryRecorder()
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            libraryBrowseProvider: { query, _ in
                recorded.append(query)
                return ServerLibraryItemsPage(totalItemCount: 0, offset: query.offset, limit: query.limit, items: [])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        _ = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let homeQueries = recorded.values
        XCTAssertEqual(homeQueries.count, 2)
        XCTAssertTrue(homeQueries.allSatisfy { $0.includesRemoteSources }, "首页两栏必须跨来源")
        XCTAssertEqual(Set(homeQueries.map(\.sort)), [.dateAdded, .score])

        recorded.reset()
        _ = router.response(for: "GET /api/v1/library/browse?limit=24 HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertFalse(
            recorded.values.contains { $0.includesRemoteSources },
            "浏览接口不认识这个选项，浏览器无从把一级分类页扩成含远程"
        )
    }

    /// 保险库作用域是一个**换掉整个范围**的开关，不是又一个筛选。它只认字面量
    /// `1`，而且与远程作用域互斥——同时给出两个作用域是矛盾的请求。
    func testVaultScopeQueryIsStrictAndMutuallyExclusiveWithRemoteScope() {
        let recorded = QueryRecorder()
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            libraryBrowseProvider: { query, _ in
                recorded.append(query)
                return ServerLibraryItemsPage(totalItemCount: 0, offset: query.offset, limit: query.limit, items: [])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
        func browse(_ query: String) -> Int {
            router.response(for: "GET /api/v1/library/browse?\(query) HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode
        }

        XCTAssertEqual(browse("limit=24&vault=1"), 200)
        XCTAssertEqual(recorded.values.last?.vaultScope, true)

        for rejected in ["limit=24&vault=0", "limit=24&vault=true", "limit=24&vault=", "limit=24&vault=1&remoteScope=abc"] {
            XCTAssertEqual(browse(rejected), 400, rejected)
        }
        // 不写这个键时它就是关的——保险库不会因为"没说不要"而进入任何一次浏览。
        recorded.reset()
        XCTAssertEqual(browse("limit=24"), 200)
        XCTAssertEqual(recorded.values.last?.vaultScope, false)
    }

    /// 网页保险库页面把"锁着"和"没授权"分开说。合成一句会让读者一直去解锁一个
    /// 已经解锁的保险库，然后以为是坏了。
    func testVaultPageDistinguishesLockedFromNotGranted() {
        func html(_ access: ServerLibraryCatalog.VaultAccess) -> String {
            let router = LocalHTTPRouter(
                serverID: "server-001",
                serverName: "客厅服务器",
                vaultAccessProvider: { _ in access },
                authenticationProvider: { _ in .testAdministrator() }
            )
            let response = router.response(for: "GET /vault HTTP/1.1\r\nHost: localhost\r\n\r\n")
            XCTAssertEqual(response.statusCode, 200)
            return String(data: response.body, encoding: .utf8) ?? ""
        }

        let locked = html(.locked)
        XCTAssertTrue(locked.contains("保险库已锁定"))
        XCTAssertTrue(locked.contains("Touch ID"))

        let notGranted = html(.notGranted)
        XCTAssertTrue(notGranted.contains("这个账号没有保险库权限"))
        XCTAssertFalse(notGranted.contains("保险库已锁定"))

        // 解锁且已授权时它根本不是锁屏，而是一个普通的资料库页面。
        let unlocked = html(.unlocked)
        XCTAssertFalse(unlocked.contains("保险库已锁定"))
        XCTAssertTrue(unlocked.contains("data-vault-scope=\"true\""))
        XCTAssertTrue(unlocked.contains("/assets/library.js"))
        // 口令永远不在网页上出现——三种状态都不接收它。
        for markup in [locked, notGranted, unlocked] {
            XCTAssertFalse(markup.contains("type=\"password\""))
        }
    }

    func testWebHomeUsesSafeDTOsAndEscapesCardTitles() {
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 3, countsByType: ["movie": 1, "anime": 1, "music": 1]),
            items: ServerLibraryItemsResponse(
                totalItemCount: 3,
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
                    ),
                    ServerLibraryItem(
                        id: "series-1", type: "anime", title: "独立剧集", year: 2025,
                        artworkAvailable: true, isSeries: true
                    ),
                    ServerLibraryItem(
                        id: "music-1", type: "music", title: "紧凑单曲", year: 2024,
                        artworkAvailable: true
                    ),
                    // 「剧集推荐」凑够四条，好让这一页同时走到两种版面：这一栏是
                    // 密集的横排（`.ui-shelf`），而只有一条内容的「继续观看」走
                    // 宽卡（`.home-feature-row`）。只有三条数据的那一版永远只能
                    // 测到其中一种。
                    ServerLibraryItem(
                        id: "series-2", type: "anime", title: "第二部剧集", year: 2025,
                        artworkAvailable: true, isSeries: true
                    ),
                    ServerLibraryItem(
                        id: "series-3", type: "anime", title: "第三部剧集", year: 2025,
                        artworkAvailable: true, isSeries: true
                    ),
                    ServerLibraryItem(
                        id: "series-4", type: "anime", title: "第四部剧集", year: 2024,
                        artworkAvailable: true, isSeries: true
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
        XCTAssertTrue(html.contains("href=\"/assets/home.css?v="))
        XCTAssertLessThan(
            html.range(of: "href=\"/assets/app-shell.css?v=")!.lowerBound,
            html.range(of: "href=\"/assets/home.css?v=")!.lowerBound,
            "页面专属样式必须在公共壳层之后加载，避免被壳层规则覆盖。"
        )
        XCTAssertTrue(html.contains("src=\"/assets/home.js?v="))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(html.contains("继续观看 · 50%"))
        XCTAssertTrue(html.contains("data-progress=\"50\""))
        // 「资料库构成」与「电影与视频」已删除：客户端首页没有这两栏，前者与统计
        // 四格和「运行状态」重复，后者与「最近添加」重复。
        XCTAssertFalse(html.contains("class=\"runtime-row\""))
        XCTAssertFalse(html.contains(">资料库构成</h2>"))
        XCTAssertFalse(html.contains(">电影与视频</h2>"))
        // 栏目顺序对齐客户端 `HomeModuleKind.defaultOrder`，只有一处有意的偏离：
        // 「统计四格」与「运行状态」在网页端合成开头的一块「资料库概览」。两者
        // 此前是同一屏里两条版式完全相同的四格指标条，只有数字不同。
        // 按标题 id 定位，不按 `>标题</h2>` 的字面形状。区块标题现在可以把标题
        // 文本包进一条「标题即出口」的链接（尾随一枚 `›`），于是 `</h2>` 前面
        // 是 `</a>` 而不是标题本身——原来的写法会一条都匹配不到，然后拿一个空
        // 数组和自己的排序比，永远为真。
        let sectionIDs = ["overview", "series", "continue", "recent", "watchlist", "favorites", "music"]
        let order = sectionIDs.compactMap { html.range(of: "id=\"home-\($0)-title\"")?.lowerBound }
        // 每一栏只在真的有内容时出现，所以这里不数总数——这个夹具没有想看/收藏。
        // 要钉的是**出现的那些**保持客户端的相对顺序，以及定位方式本身没退化成
        // 一条永远匹配不到的字面量。
        XCTAssertGreaterThanOrEqual(order.count, 5, "定位方式失效时这里会是 0")
        XCTAssertEqual(order, order.sorted(), "首页栏目顺序必须与客户端一致")
        XCTAssertFalse(html.contains(">运行状态</h2>"), "页尾那条重复的四格已并入开头的概览")
        XCTAssertTrue(html.contains("id=\"home-series-title\"") && html.contains(">剧集推荐"))
        // 卡片按内容类型换形状，但不为了占满一行而拉伸：正在看的剧集用横版剧照，
        // 音乐用方封面，其余用竖版海报墙。一排放不满就放不满。
        XCTAssertTrue(html.contains("ui-shelf home-shelf-landscape"), "继续观看应使用横版剧照")
        XCTAssertTrue(html.contains("ui-shelf home-shelf-poster"), "其余栏目应使用海报墙")
        XCTAssertTrue(html.contains("class=\"home-landscape-copy\""), "横版卡的文案压在画面上")
        XCTAssertFalse(html.contains("home-feature-row"), "撑满整行的宽卡已移除")
        XCTAssertTrue(html.contains("data-hero-carousel"))
        XCTAssertTrue(html.contains("data-hero-track"))
        XCTAssertTrue(html.contains("class=\"hero-slide\""))
        XCTAssertTrue(html.contains("class=\"hero-mobile-play-link\""))
        XCTAssertTrue(html.contains("aria-label=\"播放 "))
        XCTAssertTrue(html.contains("data-hero-previous"))
        XCTAssertTrue(html.contains("data-hero-next"))
        // 分页点是真正的 tablist，而不是三个装饰性的圆。
        XCTAssertTrue(html.contains("role=\"tablist\""))
        XCTAssertTrue(html.contains("aria-controls=\"hero-panel-0\""))
        // 环境辉光取最小的缩略图桶：20px 模糊之后更高的清晰度没有意义。
        XCTAssertTrue(html.contains("class=\"hero-ambient\""))
        XCTAssertTrue(html.contains("/backdrop?size=160") || html.contains("/poster?size=160"))
        XCTAssertFalse(html.contains(">扫描<"))
        XCTAssertTrue(html.contains("/poster?size=640"))
        XCTAssertFalse(html.contains("/poster?size=1280"), "首页精选不得请求服务端不存在的 1280 尺寸桶。")
        // 系列海报直接进播放解析路由；剧集页已删除。
        XCTAssertTrue(html.contains("href=\"/series/series-1/play\""))
        XCTAssertTrue(html.contains("id=\"home-music-title\"") && html.contains(">音乐推荐"))
        XCTAssertTrue(html.contains("class=\"home-music-layout\""))
        XCTAssertTrue(html.contains("class=\"track-row\""))
        XCTAssertTrue(html.contains("class=\"ui-media-card\""))
        XCTAssertTrue(html.contains("data-music-play=\"music-1\""))
        XCTAssertFalse(html.contains("最近索引的内容"))
        XCTAssertFalse(html.contains("media-card-music"))
        XCTAssertFalse(html.contains("media-grid"))
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
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))
        // `.home-shelf-section` 已随列宽一起归到形状变体里；一个发了类名却没有
        // 任何规则命中的选择器只会误导下一个人。
        XCTAssertFalse(css.contains(".home-shelf-section"))
        XCTAssertTrue(css.contains(".home-shelf-poster"))
        XCTAssertTrue(css.contains(".hero-slide"))
        // 「资料库构成」那一栏删掉之后，它的 `.runtime-*` 样式跟着删了——一份没
        // 有任何标记命中的规则，只会让下一个人以为这一栏还在。
        XCTAssertFalse(css.contains(".runtime-row"))
        XCTAssertTrue(css.contains(".home-overview"))
        XCTAssertTrue(css.contains(".home-shelf-landscape"))
        XCTAssertFalse(css.contains(".home-feature-card"), "撑满整行的宽卡已移除")
        XCTAssertTrue(css.contains(".home-music-layout"))
        XCTAssertTrue(css.contains(".photo-shelf"))
        XCTAssertTrue(css.contains("--grid-min: 168px"))
        XCTAssertTrue(css.contains(".hero-track"))
        XCTAssertTrue(css.contains(".hero-arrow"))
        XCTAssertTrue(css.contains(".hero-arrow-previous"))
        // App Store Discover 的两个可测量常数：16/9 与 17px 圆角。
        XCTAssertTrue(css.contains("aspect-ratio: 16 / 9"))
        XCTAssertTrue(css.contains("aspect-ratio: 5 / 3"), "移动端 banner 高度应为原 5:4 的 3/4")
        XCTAssertTrue(css.contains("max-height: 255px"))
        XCTAssertTrue(css.contains(".hero-actions { display: none; }"))
        XCTAssertTrue(css.contains(".hero-mobile-play-link"))
        XCTAssertTrue(css.contains("border-radius: 17px"))
        // 遮罩必须是两层，且都取自共用停靠色。
        //
        // 从前这里钉的是"一条 55° 渐变"。那条渐变在左上角最浓，而文案排在左下
        // 角——最该压暗的地方恰恰最薄，底部偏亮的剧照上标题就会糊掉。所以这条
        // 断言现在钉的是"文案那条带子上方必须有一层自下而上的遮罩"，而不是某个
        // 具体角度：角度可以再调，那条带子的可读性不能丢。
        XCTAssertTrue(css.contains("linear-gradient(to top, var(--hero-scrim-strong)"))
        XCTAssertTrue(css.contains("var(--hero-scrim-clear)"))
        // 遮罩与文字颜色都经每张 slide 的变量间接，`.is-light-art` 整套翻过来——
        // 亮画面配深字浅遮罩。少了这一层间接，反色就只能改文字颜色，遮罩仍是深的。
        XCTAssertTrue(css.contains(".hero-slide.is-light-art"))
        XCTAssertTrue(css.contains("--hero-scrim-strong: var(--on-media-scrim-strong)"))
        // 画面上的文字一律走语义色，不再手写白色透明度。
        XCTAssertFalse(css.contains("color: rgba(255, 255, 255, 0.72)"))
        // 可读性靠反色与磨砂，不靠给每个字描一圈阴影。
        XCTAssertFalse(css.contains("text-shadow: var(--text-on-media-shadow)"), "banner 文案不应再依赖阴影")
        XCTAssertTrue(css.contains("blur(20px) saturate(1.3)"))
        XCTAssertTrue(css.contains("@media (max-width: 719px)"))
        XCTAssertFalse(css.contains("server-001"))
        XCTAssertFalse(css.contains("movie-1"))
        XCTAssertFalse(css.contains("token"))
        XCTAssertEqual(headResponse.statusCode, 200)
        XCTAssertTrue(headResponse.body.isEmpty)
        XCTAssertEqual(headerValue(named: "Content-Length", in: headHeaders), headerValue(named: "Content-Length", in: headers))
    }

    func testHomeScriptIsPrivateCacheableAndOnlyUsesSafeDOMOperations() {
        let response = router.response(for: "GET /assets/home.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let script = String(data: response.body, encoding: .utf8) ?? ""
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertTrue(script.contains("data-hero-carousel"))
        XCTAssertTrue(script.contains("data-hero-previous"))
        XCTAssertTrue(script.contains("data-hero-next"))
        XCTAssertTrue(script.contains("track.addEventListener('pointerdown'"))
        XCTAssertTrue(script.contains("track.setPointerCapture"))
        // 松手后按速度投影落点，并把该速度交给弹簧——拖拽与动画之间没有接缝。
        XCTAssertTrue(script.contains("const project = (initialVelocity, decelerationRate = 0.998)"))
        XCTAssertTrue(script.contains("const rubberband = (overshoot, dimension, constant = 0.55)"))
        XCTAssertTrue(script.contains("prefers-reduced-motion: reduce"))
        XCTAssertTrue(script.contains("image.remove()"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("apply(index)"), "轮播不得再调用已删除的自动轮播函数；这正是旧实现在 pointerleave 上抛 ReferenceError 的原因")
        XCTAssertFalse(script.contains("data-src"), "首屏之外的推荐必须直接带 src，否则第二张之后的图片永远为空")
        XCTAssertFalse(script.contains("localStorage"))
    }

    func testEveryResponseCarriesBrowserSecurityHeaders() {
        let response = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertTrue(headers.contains("Content-Security-Policy: default-src 'none'"))
        XCTAssertTrue(headers.contains("style-src 'self'"))
        XCTAssertTrue(headers.contains("media-src 'self' blob:"))
        XCTAssertFalse(headers.contains("style-src 'self' 'unsafe-inline'"))
        XCTAssertFalse(headers.contains("style-src-attr 'unsafe-inline'"))
        XCTAssertTrue(headers.contains("frame-ancestors 'none'"))
        XCTAssertTrue(headers.contains("Cross-Origin-Resource-Policy: same-origin"))
        XCTAssertTrue(headers.contains("Referrer-Policy: same-origin"))
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

        let valid = router.response(for: "GET /api/v1/library/browse?q=%E9%93%B6%E6%B2%B3+1&type=movie&state=inProgress&offset=48&limit=48&sort=title HTTP/1.1\r\n\r\n")
        XCTAssertEqual(valid.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(searchText: "银河 1", type: "movie", offset: 48, limit: 48, sort: .title, playbackFilter: .inProgress))
        XCTAssertEqual(try JSONDecoder().decode(ServerLibraryItemsPage.self, from: valid.body).offset, 48)

        let reversed = router.response(for: "GET /api/v1/library/browse?sort=year&order=reverse&genre=%E7%A7%91%E5%B9%BB&limit=48 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(reversed.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(limit: 48, sort: .year, sortOrder: .reverse, genre: "科幻"))

        // 旧的四个 sort 值出现在用户已经保存的链接里，所以它们永远被接受，
        // 并各自代表一个完整状态（键 + 正序）。
        let legacy = router.response(for: "GET /api/v1/library/browse?state=history&sort=lastPlayedDescending&limit=48 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(legacy.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(limit: 48, sort: .lastPlayed, playbackFilter: .history))

        let favorites = router.response(for: "GET /api/v1/library/browse?preference=favorite&limit=48 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(favorites.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(limit: 48, preferenceFilter: .favorite))

        let videos = router.response(for: "GET /api/v1/library/browse?group=video&limit=48 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(videos.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(limit: 48, mediaGroup: .video))

        for target in [
            "/api/v1/library/browse?limit=101",
            "/api/v1/library/browse?offset=-1",
            "/api/v1/library/browse?type=private",
            "/api/v1/library/browse?type=unknown",
            "/api/v1/library/browse?group=unknown",
            "/api/v1/library/browse?type=movie&group=video",
            "/api/v1/library/browse?state=anyoneElse",
            "/api/v1/library/browse?preference=someoneElse",
            "/api/v1/library/browse?q=one&q=two",
            "/api/v1/library/browse?unknown=value",
            "/api/v1/library/browse?q=%ZZ",
            "/api/v1/library/browse?sort=sideways",
            "/api/v1/library/browse?order=sideways",
            // 同一个状态不能有两种拼法：旧 sort 值已经隐含了方向。
            "/api/v1/library/browse?sort=updatedDescending&order=reverse",
            "/api/v1/library/browse?genre=",
            "/api/v1/library/browse?genre=\(String(repeating: "a", count: 65))"
        ] {
            XCTAssertEqual(router.response(for: "GET \(target) HTTP/1.1\r\n\r\n").statusCode, 400, target)
        }
        let head = router.response(for: "HEAD /api/v1/library/browse?limit=1 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertGreaterThan(head.declaredContentLength, 0)
    }

    /// 预取键漂移是静默的：不会报错，只是外壳不再预热资料库页。
    ///
    /// `app-shell.js` 拼出的预取 URL 必须与 `library.js` 首次请求的 URL 逐字
    /// 相同。两处各自写着默认的排序值和参数顺序，改一处忘了另一处，唯一的症状
    /// 就是"页面变慢了一点"。
    func testLibraryPrefetchKeyMatchesTheLibraryScriptsFirstRequest() {
        let shell = String(
            data: router.response(for: "GET /assets/app-shell.js HTTP/1.1\r\nHost: localhost\r\n\r\n").body,
            encoding: .utf8
        ) ?? ""
        let library = String(
            data: router.response(for: "GET /assets/library.js HTTP/1.1\r\nHost: localhost\r\n\r\n").body,
            encoding: .utf8
        ) ?? ""

        // 同一组默认值。
        XCTAssertTrue(shell.contains("offset: '0', limit: '24'"))
        XCTAssertTrue(library.contains("const pageSize = 24"))
        XCTAssertTrue(shell.contains("'lastPlayed' : 'recentlyUpdated'"))
        XCTAssertTrue(library.contains("'lastPlayed' : 'recentlyUpdated'"))
        // 同一个参数顺序：offset、limit、sort 打头，其余键只在非默认时追加。
        XCTAssertTrue(library.contains("new URLSearchParams({ offset: String(offset), limit: String(pageSize), sort: sort.value })"))
        XCTAssertTrue(library.contains("if (reversed) params.set('order', 'reverse')"))
        XCTAssertFalse(library.contains("params.set('order', 'primary')"), "写入默认方向会让预取永远落空")
        // 分类页也走预取：`/library` 不是路由，`/category/{id}` 才是。
        XCTAssertTrue(shell.contains("/^\\/category\\/([^/?#]+)$/"))
        XCTAssertFalse(shell.contains("'/library', '/search'"), "`/library` 不是路由，预取它只会命中 404")
    }

    func testLibraryFacetsEndpointIsScopedAllowlistedAndSupportsHead() {
        var captured: (type: String?, group: ServerLibraryMediaGroup?)?
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            libraryFacetsProvider: { type, group, _ in
                captured = (type, group)
                return ServerLibraryFacetsResponse(genres: ["动作", "科幻"], availableSorts: [.recentlyUpdated, .title])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let scoped = router.response(for: "GET /api/v1/library/facets?type=movie HTTP/1.1\r\n\r\n")
        XCTAssertEqual(scoped.statusCode, 200)
        XCTAssertEqual(captured?.type, "movie")
        XCTAssertNil(captured?.group)
        let decoded = try? JSONDecoder().decode(ServerLibraryFacetsResponse.self, from: scoped.body)
        XCTAssertEqual(decoded?.genres, ["动作", "科幻"])

        let grouped = router.response(for: "GET /api/v1/library/facets?group=video HTTP/1.1\r\n\r\n")
        XCTAssertEqual(grouped.statusCode, 200)
        XCTAssertEqual(captured?.group, .video)

        for target in [
            "/api/v1/library/facets?type=private",
            "/api/v1/library/facets?type=unknown",
            "/api/v1/library/facets?group=unknown",
            "/api/v1/library/facets?type=movie&group=video",
            "/api/v1/library/facets?unknown=value"
        ] {
            XCTAssertEqual(router.response(for: "GET \(target) HTTP/1.1\r\n\r\n").statusCode, 400, target)
        }

        let head = router.response(for: "HEAD /api/v1/library/facets HTTP/1.1\r\n\r\n")
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
        // Browsing is scoped: the group route and a single category, never an
        // unscoped "everything" page.
        let page = router.response(for: "GET /category/video HTTP/1.1\r\n\r\n")
        let selectedPage = router.response(for: "GET /category/movie HTTP/1.1\r\n\r\n")
        // The page that mixed every media type into one grid is gone.
        XCTAssertEqual(router.response(for: "GET /library HTTP/1.1\r\n\r\n").statusCode, 404)
        // An id outside this principal's authorized categories is a 404, not a
        // silently unscoped page.
        XCTAssertEqual(router.response(for: "GET /category/not-a-category HTTP/1.1\r\n\r\n").statusCode, 404)
        let asset = router.response(for: "GET /assets/library.js HTTP/1.1\r\n\r\n")
        let styleAsset = router.response(for: "GET /assets/library.css HTTP/1.1\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let selectedHTML = String(data: selectedPage.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""
        let style = String(data: styleAsset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(styleAsset.contentType, "text/css; charset=utf-8")
        XCTAssertTrue(style.contains(".library-status"))
        XCTAssertTrue(html.contains("客厅 &lt;服务器&gt;"))
        XCTAssertTrue(html.contains("href=\"/assets/library.css?v="))
        XCTAssertLessThan(
            html.range(of: "href=\"/assets/app-shell.css?v=")!.lowerBound,
            html.range(of: "href=\"/assets/library.css?v=")!.lowerBound,
            "资料库的 PosterCard 规则必须覆盖公共壳层的通用卡片规则。"
        )
        XCTAssertTrue(html.contains("src=\"/assets/library.js?v="))
        XCTAssertTrue(script.contains("poster.append(image);"))
        // 取图失败不再由这一页自己处理：外壳会重试三次，把 <img> 从文档里摘掉
        // 等于让它连一次重试的机会都没有。兜底那一层本来就压在下面。
        XCTAssertFalse(script.contains("poster.replaceChildren(glyph)"))
        XCTAssertTrue(script.contains("const glyph = element('span', 'ui-poster-fallback', title);"))
        XCTAssertTrue(script.contains("function setArtworkPalette"))
        XCTAssertTrue(script.contains("node.dataset.artworkPalette"))
        // 取色的分桶由 Swift 从 `ServerWebArtworkPalette` 插值下来，脚本不再自
        // 带一份。此前这里抄的那份把桶数写成 13/8，而服务端真正的桶数不是这两
        // 个数——同一个条目，服务端渲染的卡片和脚本补进来的卡片会落到两种颜色
        // 上。颜色值本来就属于 tokens.css，脚本里出现它们就是那份重复本身。
        XCTAssertTrue(script.contains("medialibArtworkPalette"))
        XCTAssertFalse(script.contains("'#0e4a37','#06281f','#22d3a8'"), "取色表不该再抄进脚本")
        // 服务端是 10/10。脚本抄的那份写的是 13/8，于是同一个条目在服务端渲染
        // 的卡片和脚本补进来的卡片上是两种颜色——这条断言把两边钉在一起。
        XCTAssertEqual(ServerWebArtworkPalette.bucketCounts.poster, 10)
        XCTAssertEqual(ServerWebArtworkPalette.bucketCounts.music, 10)
        XCTAssertFalse(script.contains("node.style.setProperty('--artwork-g1'"))
        XCTAssertFalse(script.contains("artworkHue"))
        // 分类下拉只出现在无作用域的视图上；`/category/*` 的作用域由侧栏表达。
        XCTAssertFalse(html.contains("<option value=\"movie\">电影 &lt;精选&gt;（12）</option>"))
        XCTAssertTrue(html.contains("href=\"/category/movie\""))
        XCTAssertTrue(selectedHTML.contains("href=\"/category/movie\" data-native-navigation=\"true\" aria-current=\"page\""))
        XCTAssertFalse(selectedHTML.contains("class=\"nav-item active\" aria-current=\"page\" href=\"/category/video\""))
        let watching = router.response(for: "GET /watching HTTP/1.1\r\n\r\n")
        let watchingHTML = String(data: watching.body, encoding: .utf8) ?? ""
        XCTAssertEqual(watching.statusCode, 200)
        XCTAssertTrue(watchingHTML.contains("data-playback-filter=\"inProgress\""))
        let history = router.response(for: "GET /history HTTP/1.1\r\n\r\n")
        let historyHTML = String(data: history.body, encoding: .utf8) ?? ""
        XCTAssertEqual(history.statusCode, 200)
        XCTAssertTrue(historyHTML.contains("data-page-route=\"/history\""))
        XCTAssertTrue(historyHTML.contains("data-playback-filter=\"history\""))
        XCTAssertTrue(historyHTML.contains("data-default-sort=\"lastPlayed\""))
        let favorites = router.response(for: "GET /favorites HTTP/1.1\r\n\r\n")
        let favoritesHTML = String(data: favorites.body, encoding: .utf8) ?? ""
        XCTAssertEqual(favorites.statusCode, 200)
        XCTAssertTrue(favoritesHTML.contains("data-page-route=\"/favorites\""))
        XCTAssertTrue(favoritesHTML.contains("data-preference-filter=\"favorite\""))
        XCTAssertFalse(favoritesHTML.contains("class=\"nav-item active\" aria-current=\"page\" href=\"/favorites\""))
        let watchlist = router.response(for: "GET /watchlist HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: watchlist.body, encoding: .utf8) ?? "").contains("data-preference-filter=\"watchlist\""))
        let watched = router.response(for: "GET /watched HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: watched.body, encoding: .utf8) ?? "").contains("data-playback-filter=\"watched\""))
        let ratings = router.response(for: "GET /ratings HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: ratings.body, encoding: .utf8) ?? "").contains("data-preference-filter=\"rated\""))
        let unwatched = router.response(for: "GET /unwatched HTTP/1.1\r\n\r\n")
        XCTAssertTrue((String(data: unwatched.body, encoding: .utf8) ?? "").contains("data-playback-filter=\"unwatched\""))
        XCTAssertTrue(reducedMotionPolicyIsCentralised(in: router), "减少动效策略集中在 base.css，不再由每个页面各写一份")
        XCTAssertTrue(html.contains("class=\"app-eyebrow\""))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("encodeURIComponent"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("/api/v1/images/"))
        XCTAssertTrue(script.contains("ui-play-affordance"))
        XCTAssertTrue(script.contains("播放视频"))
        XCTAssertTrue(script.contains("/play/${encodeURIComponent(itemID)}#play"))
        XCTAssertTrue(script.contains("const isPhoto = mediaType === 'photo'"))
        // 首行 eager、其余 lazy。`loading='lazy'` 与 `fetchPriority='high'` 同时加在
        // 同一张图上是自相抵消的：懒加载先把请求推迟，高优先级再作用在被推迟的
        // 请求上。所以断言的是"分档"，不是"全部 lazy"。
        XCTAssertTrue(script.contains("image.loading = index < 6 ? 'eager' : 'lazy'"))
        XCTAssertTrue(script.contains("image.decoding = 'async'"))
        XCTAssertTrue(script.contains("image.fetchPriority = 'high'"))
        XCTAssertTrue(script.contains("const pageSize = 24"))
        XCTAssertTrue(script.contains("lastPlayedDescending"))
        XCTAssertTrue(script.contains("'history'"))
        XCTAssertTrue(script.contains("state.lastPlayedAt"))
        XCTAssertTrue(script.contains("params.set('preference', preferenceFilter)"))
        XCTAssertTrue(script.contains("params.set('group', requestedGroup)"))
        XCTAssertTrue(script.contains("fetchBrowsePage"))
        XCTAssertTrue(script.contains("browseCacheLifetime = 8_000"))
        XCTAssertTrue(script.contains("__medialibLibraryBrowseCache"))
        XCTAssertTrue(script.contains("void loadPage();"))
        XCTAssertFalse(script.contains("/api/v1/library/categories"), "分类应随认证页面首屏交付，避免第二个导航请求")
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertTrue(script.contains("function renderMusicRow"))
        XCTAssertTrue(script.contains("'ui-track-row'"))
        XCTAssertFalse(script.contains("article.classList.add('music-card')"))
        XCTAssertTrue(script.contains("grid.classList.toggle('music-layout'"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("eval("))
    }

    func testMusicSystemPagesUseAuthorizedDTOsAndSystemPageStructures() {
        let tracks = [
            ServerLibraryItem(
                id: "track-1", type: "music", title: "<script>unsafe</script>", year: 2026,
                artist: "艺术家 <A>", album: "专辑 & 一", durationSeconds: 245,
                artworkAvailable: true
            )
        ]
        let router = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅 <服务器>",
            libraryCategoriesProvider: { _ in ServerLibraryCategoriesResponse(categories: [
                ServerLibraryCategory(id: "music", title: "音乐", itemCount: 1)
            ]) },
            musicItemsProvider: { _ in tracks },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let songs = router.response(for: "GET /music/songs HTTP/1.1\r\n\r\n")
        let albums = router.response(for: "GET /music/albums HTTP/1.1\r\n\r\n")
        let artists = router.response(for: "GET /music/artists HTTP/1.1\r\n\r\n")
        let playlists = router.response(for: "GET /music/playlists HTTP/1.1\r\n\r\n")
        let recent = router.response(for: "GET /music/recent HTTP/1.1\r\n\r\n")
        let style = router.response(for: "GET /assets/music.css HTTP/1.1\r\n\r\n")
        let songsHTML = String(data: songs.body, encoding: .utf8) ?? ""
        let albumsHTML = String(data: albums.body, encoding: .utf8) ?? ""
        let artistsHTML = String(data: artists.body, encoding: .utf8) ?? ""
        let playlistsHTML = String(data: playlists.body, encoding: .utf8) ?? ""
        let recentHTML = String(data: recent.body, encoding: .utf8) ?? ""
        let css = String(data: style.body, encoding: .utf8) ?? ""

        XCTAssertEqual(songs.statusCode, 200)
        XCTAssertEqual(albums.statusCode, 200)
        XCTAssertEqual(artists.statusCode, 200)
        XCTAssertEqual(playlists.statusCode, 200)
        XCTAssertEqual(recent.statusCode, 200)
        XCTAssertEqual(style.contentType, "text/css; charset=utf-8")
        XCTAssertTrue(songsHTML.contains("歌曲</span><span>艺术家</span><span>专辑</span><span>歌词</span><span>时长</span>"))
        // One heading per page.  Each music view used to print a second title
        // block of its own directly under the shared page header, so every page
        // shipped two `<h1>`s and two descriptions saying the same thing.
        for (name, html, title) in [
            ("songs", songsHTML, "歌曲"), ("albums", albumsHTML, "专辑"), ("artists", artistsHTML, "艺术家"),
            ("playlists", playlistsHTML, "歌单"), ("recent", recentHTML, "最近播放")
        ] {
            XCTAssertTrue(html.contains("<h1 id=\"music-title\">\(title)</h1>"), name)
            XCTAssertEqual(html.components(separatedBy: "<h1").count - 1, 1, "\(name) 应只有一个 h1")
        }
        XCTAssertTrue(songsHTML.contains("&lt;script&gt;unsafe&lt;/script&gt;"))
        XCTAssertTrue(songsHTML.contains("艺术家 &lt;A&gt;"))
        XCTAssertTrue(songsHTML.contains("专辑 &amp; 一"))
        XCTAssertTrue(songsHTML.contains("4:05"))
        XCTAssertTrue(songsHTML.contains("data-music-play=\"track-1\""))
        XCTAssertTrue(albumsHTML.contains("class=\"album-grid\""))
        XCTAssertTrue(albumsHTML.contains("/poster?size=320"))
        XCTAssertFalse(albumsHTML.contains("/poster?size=480"))
        XCTAssertTrue(artistsHTML.contains("class=\"artist-grid\""))
        // 没有歌单时给空态，而不是四张写死名字、点进去都一样的伪造卡片。
        XCTAssertFalse(playlistsHTML.contains("class=\"playlist-grid\""))
        XCTAssertTrue(playlistsHTML.contains("还没有歌单"))
        XCTAssertFalse(playlistsHTML.contains("按艺术家浏览"), "四张伪造歌单卡已删除")
        XCTAssertTrue(recentHTML.contains("class=\"recent-table\""))
        XCTAssertTrue(songsHTML.contains("href=\"/music/albums\""))
        XCTAssertTrue(songsHTML.contains("href=\"/music/artists\""))
        XCTAssertTrue(songsHTML.contains("href=\"/music/playlists\""))
        XCTAssertTrue(songsHTML.contains("href=\"/music/recent\""))
        XCTAssertTrue(css.contains(".album-grid"))
        XCTAssertTrue(css.contains(".artist-grid"))
        // 分段项现在就是 `.ui-segmented > a`，共用 primitives 的样式；
        // music.css 里那份逐行重复的实现已经删掉。
        XCTAssertFalse(css.contains(".music-segment-item"))
        XCTAssertFalse(songsHTML.contains("filePath"))
        XCTAssertFalse(songsHTML.contains("<script>unsafe</script>"))
    }

    func testAlbumPageBoundsFirstPaintArtworkRequests() {
        let tracks = (0..<40).map { index in
            ServerLibraryItem(
                id: "album-track-\(index)", type: "music", title: "曲目 \(index)", year: 2026,
                artist: "艺术家 \(index)", album: "专辑 \(index)", artworkAvailable: true
            )
        }
        let router = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅服务器",
            musicItemsProvider: { _ in tracks },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let response = router.response(for: "GET /music/albums HTTP/1.1\r\n\r\n")
        let html = String(data: response.body, encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        // 首屏开销由"只有前几张抢优先级"来约束，而不是把列表截断。
        //
        // 这里从前钉的是 24 张卡：那不是一个分页上限，而是一个硬截断——40 张专辑
        // 的曲库永远只显示 24 张，剩下的没有任何入口可以看到，筛选与排序也只在这
        // 24 张里做。真正花钱的是封面解码，而它已经由 `fetchpriority` 与
        // `loading="lazy"` 管住了：屏外的图不会在首屏解码。
        XCTAssertEqual(html.components(separatedBy: "class=\"album-card\"").count - 1, 40)
        XCTAssertEqual(html.components(separatedBy: "fetchpriority=\"high\"").count - 1, 4)
        XCTAssertEqual(html.components(separatedBy: "/poster?size=320").count - 1, 40)
        XCTAssertFalse(html.contains("/poster?size=480"))
    }

    func testMusicListsBoundFirstPaintRowsAndArtworkRequests() {
        let tracks = (0..<140).map { index in
            ServerLibraryItem(
                id: "music-track-\(index)", type: "music", title: "曲目 \(index)", year: 2026,
                artist: "艺术家 \(index)", album: "专辑 \(index)", artworkAvailable: true
            )
        }
        let router = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅服务器",
            musicItemsProvider: { _ in tracks },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let songs = String(data: router.response(for: "GET /music/songs HTTP/1.1\r\n\r\n").body, encoding: .utf8) ?? ""
        let artists = String(data: router.response(for: "GET /music/artists HTTP/1.1\r\n\r\n").body, encoding: .utf8) ?? ""
        let recent = String(data: router.response(for: "GET /music/recent HTTP/1.1\r\n\r\n").body, encoding: .utf8) ?? ""

        // 全部条目都要出现：从前的 50 / 24 / 30 是硬截断，没有任何"加载更多"在
        // 后面接着——300 首的曲库只看得到 50 首，而且筛选排序也只对这 50 首生效。
        XCTAssertEqual(songs.components(separatedBy: "class=\"ui-track-row\"").count - 1, 140)
        XCTAssertEqual(artists.components(separatedBy: "class=\"artist-card\"").count - 1, 140)
        XCTAssertEqual(recent.components(separatedBy: "class=\"recent-row\"").count - 1, 140)
        // 首屏开销仍然受控：三页都只有前四张封面抢高优先级，其余走 lazy。
        XCTAssertEqual(songs.components(separatedBy: "fetchpriority=\"high\"").count - 1, 4)
        XCTAssertEqual(artists.components(separatedBy: "fetchpriority=\"high\"").count - 1, 4)
        XCTAssertEqual(recent.components(separatedBy: "fetchpriority=\"high\"").count - 1, 4)
        XCTAssertTrue(songs.contains("loading=\"lazy\""))
    }

    func testAuthenticatedPageCopyUsesRuntimeServerNameAndDetailSidebarKeepsCategories() {
        let categories = [
            ServerLibraryCategory(id: "movie", title: "电影", itemCount: 12)
        ]
        let status = ServerWebStatusPage.render(
            serverName: "客厅 <服务器>", csrfToken: "csrf", categories: categories, sidebarExtras: .empty
        )
        let sources = ServerWebSourcesPage.render(
            serverName: "客厅 <服务器>", csrfToken: "csrf", categories: categories, sidebarExtras: .empty
        )
        let administration = ServerWebAdministrationPage.render(
            section: .users,
            serverName: "客厅 <服务器>", csrfToken: "csrf", categories: categories, sidebarExtras: .empty
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
            showAdministration: false, categories: categories, sidebarExtras: .empty
        )

        XCTAssertTrue(status.contains("<title>仪表盘 · 客厅 &lt;服务器&gt;</title>"))
        XCTAssertTrue(sources.contains("<title>媒体库与来源 · 客厅 &lt;服务器&gt;</title>"))
        XCTAssertTrue(administration.contains("客厅 &lt;服务器&gt; 的敏感信息不会显示在网页中"))
        XCTAssertFalse(status.contains("(serverName)"))
        XCTAssertFalse(sources.contains("(serverName)"))
        XCTAssertFalse(administration.contains("(serverName)"))
        XCTAssertTrue(detailPage.contains("href=\"/category/movie\" data-native-navigation=\"true\""))
        XCTAssertTrue(detailPage.contains(">电影</span>"))
    }

    func testLibraryStyleIsPrivateCacheableAndContainsNoServerOrUserData() {
        let asset = router.response(for: "GET /assets/library.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let head = router.response(for: "HEAD /assets/library.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: asset.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/css; charset=utf-8")
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".library-filters"))
        // Search is a shell control now, not a library-page one: it sits in the
        // shared page header, so its rule lives in app-shell.css and must not
        // reappear here.
        XCTAssertFalse(style.contains(".library-search"))
        XCTAssertTrue(style.contains("#grid.music-layout"))
        XCTAssertFalse(style.contains("!important"), "页面样式表不再需要 !important 覆盖公共层")
        // 曲目行的样式属于 primitives，不属于这一页。这一页和音乐目录页此前各带
        // 一份逐字相同的六列声明；断言从"这里有这些规则"改成"这里**不再**有"。
        let sharedRow = String(
            data: router.response(for: "GET /assets/primitives.css HTTP/1.1\r\n\r\n").body,
            encoding: .utf8
        ) ?? ""
        for rule in [".ui-track-head", ".ui-track-row", ".ui-track-art", ".ui-track-duration", ".ui-track-copy"] {
            XCTAssertTrue(sharedRow.contains("\(rule) {") || sharedRow.contains("\(rule),"), "primitives 缺少 \(rule)")
            XCTAssertFalse(style.contains("\(rule) {"), "\(rule) 在页面样式表里被重新声明了一遍")
        }
        // 移动筛选断点现在属于所有浏览页面共用的 control bar，不应再由资料库
        // 页面私藏一份；否则音乐、相册等页面会再次漂移。
        XCTAssertFalse(style.contains("@media (max-width: 719px)"))
        XCTAssertTrue(sharedRow.contains(".ui-control-bar.is-mobile-disclosable"))
        XCTAssertFalse(style.contains("server-001"))
        XCTAssertFalse(style.contains("token"))
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.declaredContentLength, asset.declaredContentLength)
    }

    func testArtworkFallbackPalettesAreExternalStylesheetTokensUnderStrictCSP() {
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 2, countsByType: ["anime": 1, "music": 1]),
            items: ServerLibraryItemsResponse(totalItemCount: 2, items: [
                ServerLibraryItem(id: "fallback-poster", type: "anime", title: "剧集", year: 2026, artworkAvailable: false, isSeries: true),
                ServerLibraryItem(id: "fallback-music", type: "music", title: "单曲", year: 2026, artworkAvailable: false)
            ])
        )
        let paletteRouter = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅服务器",
            librarySnapshotProvider: { _ in snapshot },
            musicItemsProvider: { _ in snapshot.items.items.filter { $0.type == "music" } },
            authenticationProvider: { _ in .testAdministrator() }
        )
        // Artwork palettes now ship with the token layer, alongside every other
        // custom property the components read.
        let shell = paletteRouter.response(for: "GET /assets/tokens.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let home = paletteRouter.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let music = paletteRouter.response(for: "GET /music/songs HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let shellCSS = String(data: shell.body, encoding: .utf8) ?? ""
        let homeHTML = String(data: home.body, encoding: .utf8) ?? ""
        let musicHTML = String(data: music.body, encoding: .utf8) ?? ""

        XCTAssertTrue(shellCSS.contains("[data-artwork-palette=\"poster-0\"]{--artwork-g1:"))
        XCTAssertTrue(shellCSS.contains("[data-artwork-palette=\"music-0\"]{--artwork-g1:"))
        XCTAssertTrue(homeHTML.contains("data-artwork-palette=\""))
        XCTAssertTrue(musicHTML.contains("data-artwork-palette=\""))
        XCTAssertFalse(homeHTML.contains("style=\"--artwork-g1:"))
        XCTAssertFalse(musicHTML.contains("style=\"--artwork-g1:"))
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
        XCTAssertTrue(html.contains("action=\"/search\""))
        XCTAssertTrue(script.contains("pageRoute"))
        XCTAssertTrue(script.contains("/api/v1/library/browse"))
        XCTAssertTrue(script.contains("const initialState = safeInitialState()"))
        XCTAssertTrue(script.contains("const activeType = (type ? type.value : '') || requestedType"))
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

    func testArtworkRouteGeneratesOnlyBoundedCachedThumbnailVariants() throws {
        let fileManager = FileManager.default
        let imageURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Sources/MediaLib/Resources/AppIcon.png")
        try fileManager.copyItem(at: sourceURL, to: imageURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: cacheDirectory)
        }
        let sourceByteLength = Int64(try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let thumbnailer = ServerArtworkThumbnailer(cacheDirectory: cacheDirectory)
        let router = LocalHTTPRouter(
            serverID: "server-001", serverName: "客厅服务器",
            artworkAssetProvider: { id, kind, _ in
                guard id == "movie-1", kind == .poster else { return nil }
                return ServerMediaAsset(id: id, fileURL: imageURL, byteLength: sourceByteLength)
            },
            artworkThumbnailer: thumbnailer,
            authenticationProvider: { _ in .testAdministrator() }
        )

        let first = router.response(for: "GET /api/v1/images/movie-1/poster?size=320 HTTP/1.1\r\n\r\n")
        let second = router.response(for: "GET /api/v1/images/movie-1/poster?size=320 HTTP/1.1\r\n\r\n")
        let head = router.response(for: "HEAD /api/v1/images/movie-1/poster?size=320 HTTP/1.1\r\n\r\n")

        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(first.contentType, "image/jpeg")
        XCTAssertGreaterThan(first.declaredContentLength, 0)
        XCTAssertLessThan(first.declaredContentLength, Int(sourceByteLength))
        XCTAssertEqual(second.statusCode, 200)
        XCTAssertEqual(second.declaredContentLength, first.declaredContentLength)
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.declaredContentLength, first.declaredContentLength)

        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?size=319 HTTP/1.1\r\n\r\n").statusCode, 400)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?size=320&size=640 HTTP/1.1\r\n\r\n").statusCode, 400)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?width=320 HTTP/1.1\r\n\r\n").statusCode, 400)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?size=%33%32%30 HTTP/1.1\r\n\r\n").statusCode, 200)

        // 失败的封面要能真正重取，而浏览器对同一个地址不会再发第二次请求，所以
        // 重试必须换一个 URL。服务端认识这个序号、然后忽略它——不认识它的话每一
        // 次重试都是 400，等于没有重试。
        XCTAssertEqual(
            router.response(for: "GET /api/v1/images/movie-1/poster?size=320&_retry=2 HTTP/1.1\r\n\r\n").statusCode,
            200
        )
        XCTAssertEqual(
            router.response(for: "GET /api/v1/images/movie-1/poster?_retry=1 HTTP/1.1\r\n\r\n").statusCode,
            200
        )
        // 但它仍然是一个受限的键：非数字、超长和重复一律拒绝，允许的键也没有变多。
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?_retry=abc HTTP/1.1\r\n\r\n").statusCode, 400)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?_retry=1234 HTTP/1.1\r\n\r\n").statusCode, 400)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?_retry=1&_retry=2 HTTP/1.1\r\n\r\n").statusCode, 400)
        XCTAssertEqual(router.response(for: "GET /api/v1/images/movie-1/poster?_retry= HTTP/1.1\r\n\r\n").statusCode, 400)
    }

    func testArtworkThumbnailerGeneratesDifferentColdPostersWithTwoWorkers() throws {
        let fileManager = FileManager.default
        let firstSource = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-first.png")
        let secondSource = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-second.png")
        let cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Sources/MediaLib/Resources/AppIcon.png")
        try fileManager.copyItem(at: sourceURL, to: firstSource)
        try fileManager.copyItem(at: sourceURL, to: secondSource)
        addTeardownBlock {
            try? fileManager.removeItem(at: firstSource)
            try? fileManager.removeItem(at: secondSource)
            try? fileManager.removeItem(at: cacheDirectory)
        }

        let gate = ThumbnailGenerationGate()
        let thumbnailer = ServerArtworkThumbnailer(
            cacheDirectory: cacheDirectory,
            maximumConcurrentGenerations: 2,
            generationObserver: { gate.enterGeneration() }
        )
        let firstLength = Int64(try firstSource.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let secondLength = Int64(try secondSource.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let assets = [
            ServerMediaAsset(id: "first", fileURL: firstSource, byteLength: firstLength),
            ServerMediaAsset(id: "second", fileURL: secondSource, byteLength: secondLength)
        ]
        let completed = DispatchGroup()
        for asset in assets {
            completed.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = thumbnailer.thumbnail(for: asset, maximumPixel: 320)
                completed.leave()
            }
        }

        XCTAssertTrue(gate.waitForTwoGenerations(timeout: 1), "不同冷海报不能被一把全局锁串行")
        gate.releaseTwoGenerations()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        let generated = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(generated.filter { $0.pathExtension == "jpg" }.count, 2)
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

    func testRemoteStreamAndArtworkStaySameOriginAndNeverExposeUpstreamToken() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://media.example/Videos/movie-1/stream.mp4?api_key=secret-token"))
        let posterURL = try XCTUnwrap(URL(string: "https://media.example/Items/movie-1/Images/Primary.jpg?api_key=secret-token"))
        var requestedRanges: [(Int64?, Int64?)] = []
        // 上游字节现在一律由服务端派生成 JPEG 再发出（这也是授权层敢放宽"远程地址
        // 必须带图片扩展名"的前提），所以桩数据必须是一张**真能解码**的图片，而不是
        // 三个字节的 JPEG 魔数。
        let upstreamJPEG = try Self.tinyJPEGData()
        let thumbnailCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibRemoteArtworkRouteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: thumbnailCacheDirectory) }
        let fetcher = ServerRemoteAssetFetcher(responseOverride: { url, offset, length in
            XCTAssertTrue(url.host == "media.example")
            requestedRanges.append((offset, length))
            if offset == nil { return upstreamJPEG }
            if offset == 0, length == 10 { return Data("0123456789".utf8) }
            return Data("4567".utf8)
        }, mediaLengthOverride: { _ in 10 })
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            mediaAssetProvider: { id, _, _ in
                id == "remote-item" ? ServerMediaAsset(id: id, remoteURL: remoteURL, byteLength: 0) : nil
            },
            artworkAssetProvider: { id, _, _ in
                id == "remote-item" ? ServerMediaAsset(id: id, remoteURL: posterURL, byteLength: 0) : nil
            },
            // 用例自带缓存目录：默认的派生缓存在用户缓存目录里跨进程存活，上一次
            // 运行留下的那张缩略图会让这一次根本不去联系上游，断言随之飘。
            artworkThumbnailer: ServerArtworkThumbnailer(cacheDirectory: thumbnailCacheDirectory),
            remoteAssetFetcher: fetcher,
            authenticationProvider: { _ in .testAdministrator() }
        )

        let stream = router.response(
            for: "GET /api/v1/stream/remote-item HTTP/1.1\r\nHost: localhost\r\nRange: bytes=4-7\r\n\r\n"
        )
        let openEndedStream = router.response(
            for: "GET /api/v1/stream/remote-item HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-\r\n\r\n"
        )
        let artwork = router.response(
            for: "GET /api/v1/images/remote-item/poster HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        let headers = String(data: stream.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(stream.statusCode, 206)
        guard case .remoteRange = stream.payload else {
            return XCTFail("远程媒体必须保留为 socket 写入时才消费的流式 Range")
        }
        XCTAssertEqual(stream.body, Data("4567".utf8))
        XCTAssertEqual(stream.declaredContentLength, 4)
        XCTAssertTrue(headers.contains("Content-Range: bytes 4-7/10"))
        XCTAssertFalse(headers.contains("secret-token"))
        XCTAssertEqual(openEndedStream.statusCode, 206)
        XCTAssertEqual(openEndedStream.body, Data("0123456789".utf8))
        XCTAssertEqual(openEndedStream.declaredContentLength, 10)
        XCTAssertEqual(artwork.statusCode, 200)
        XCTAssertEqual(artwork.contentType, "image/jpeg")
        // 派生结果是磁盘文件，所以 payload 是 `.fileRange`（不再把整张图读进内存），
        // `body` 因此为空——真正的字节在写 socket 时才流出去。
        guard case let .fileRange(range) = artwork.payload else {
            return XCTFail("远程封面必须由服务端派生成本地 JPEG 后再发出")
        }
        let derived = try Data(contentsOf: range.url)
        XCTAssertTrue(derived.starts(with: [0xFF, 0xD8]), "发出的必须是一张真 JPEG")
        XCTAssertEqual(artwork.declaredContentLength, Int(range.length))
        let artworkHeaders = String(data: artwork.serializedHeaders(), encoding: .utf8) ?? ""
        XCTAssertFalse(artworkHeaders.contains("secret-token"))
        XCTAssertTrue(artworkHeaders.contains("ETag: "), "封面要能被复验，否则每次刷新都整张重传")
        // 封面在准备缩略图时就被完整读入（一次整体读取，`offset`/`length` 为 nil），
        // 而远程媒体保持惰性：Range 要等 socket／测试真正消费时才取，因此选路由
        // 期间不会占住一大块缓冲。
        XCTAssertEqual(requestedRanges.map { $0.0 }, [nil, 4, 0])
        XCTAssertEqual(requestedRanges.map { $0.1 }, [nil, 4, 10])
    }

    func testRemoteMediaStreamUsesBoundedChunksAndHonorsDisconnectedConsumer() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://media.example/Videos/movie-1/stream.mp4"))
        let body = Data(repeating: 0xAB, count: 600 * 1_024)
        let fetcher = ServerRemoteAssetFetcher(responseOverride: { _, offset, length in
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(length, Int64(body.count))
            return body
        })
        var chunks: [Data] = []

        XCTAssertTrue(fetcher.streamMediaBytes(url: remoteURL, offset: 0, length: Int64(body.count)) { chunk in
            chunks.append(chunk)
            return true
        })
        XCTAssertEqual(chunks.flatMap(Array.init), Array(body))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 256 * 1_024 })
        XCTAssertGreaterThan(chunks.count, 1)

        var receivedChunks = 0
        XCTAssertFalse(fetcher.streamMediaBytes(url: remoteURL, offset: 0, length: Int64(body.count)) { _ in
            receivedChunks += 1
            return false
        })
        XCTAssertEqual(receivedChunks, 1, "客户端断开后不得继续读取远程媒体")
    }

    func testRemoteMediaLengthProbeIsSharedByConcurrentRequests() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://media.example/Videos/movie-1/stream.mp4?api_key=secret-token"))
        let countLock = NSLock()
        var probeCount = 0
        let fetcher = ServerRemoteAssetFetcher(mediaLengthOverride: { _ in
            countLock.lock()
            probeCount += 1
            countLock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            return 1_024
        })
        let completed = DispatchGroup()
        let resultLock = NSLock()
        var results: [Int64] = []

        for _ in 0..<12 {
            completed.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                if let length = fetcher.mediaByteLength(url: remoteURL) {
                    resultLock.lock()
                    results.append(length)
                    resultLock.unlock()
                }
                completed.leave()
            }
        }

        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        countLock.lock()
        let finalProbeCount = probeCount
        countLock.unlock()
        XCTAssertEqual(finalProbeCount, 1)
        XCTAssertEqual(results, Array(repeating: 1_024, count: 12))
        XCTAssertEqual(fetcher.mediaByteLength(url: remoteURL), 1_024)
        countLock.lock()
        XCTAssertEqual(probeCount, 1)
        countLock.unlock()
    }

    func testRemoteArtworkThumbnailIsBoundedCachedAndNeverPersistsUpstreamURL() throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Sources/MediaLib/Resources/AppIcon.png")
        let sourceData = try Data(contentsOf: sourceURL)
        let cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? fileManager.removeItem(at: cacheDirectory) }
        let remoteURL = try XCTUnwrap(URL(string: "https://media.example/Items/movie-1/Images/Primary.jpg?api_key=secret-token"))
        var requestCount = 0
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            artworkAssetProvider: { id, kind, _ in
                guard id == "remote-item", kind == .poster else { return nil }
                return ServerMediaAsset(id: id, remoteURL: remoteURL, byteLength: 0)
            },
            artworkThumbnailer: ServerArtworkThumbnailer(cacheDirectory: cacheDirectory),
            remoteAssetFetcher: ServerRemoteAssetFetcher(responseOverride: { _, _, _ in
                requestCount += 1
                return sourceData
            }),
            authenticationProvider: { _ in .testAdministrator() }
        )

        let first = router.response(for: "GET /api/v1/images/remote-item/poster?size=160 HTTP/1.1\r\n\r\n")
        let second = router.response(for: "GET /api/v1/images/remote-item/poster?size=160 HTTP/1.1\r\n\r\n")
        let head = router.response(for: "HEAD /api/v1/images/remote-item/poster?size=160 HTTP/1.1\r\n\r\n")
        let cachedNames = try fileManager.contentsOfDirectory(atPath: cacheDirectory.path)

        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(first.contentType, "image/jpeg")
        XCTAssertGreaterThan(first.declaredContentLength, 0)
        XCTAssertLessThan(first.declaredContentLength, sourceData.count)
        XCTAssertEqual(second.statusCode, 200)
        XCTAssertEqual(second.declaredContentLength, first.declaredContentLength)
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.declaredContentLength, first.declaredContentLength)
        XCTAssertEqual(requestCount, 1, "热缩略图不能再次触发远端海报请求")
        XCTAssertFalse(cachedNames.joined(separator: " ").contains("secret-token"))
        XCTAssertFalse(cachedNames.joined(separator: " ").contains("media.example"))

        // 复验：带上服务端刚发的 ETag 再问一次，应该是一次没有 body 的 304。
        //
        // 没有它的时候，`max-age` 一过、用户按一次刷新、或者浏览器缓存被挤掉，
        // 整墙海报就是整份重传——远程封面还要连带一次上游取图。
        let headers = String(data: first.serializedHeaders(), encoding: .utf8) ?? ""
        let entityTag = try XCTUnwrap(
            headers.split(separator: "\r\n")
                .first { $0.hasPrefix("ETag: ") }
                .map { String($0.dropFirst("ETag: ".count)) },
            "缩略图响应必须带 ETag"
        )
        let revalidated = router.response(
            for: "GET /api/v1/images/remote-item/poster?size=160 HTTP/1.1\r\nIf-None-Match: \(entityTag)\r\n\r\n"
        )
        let mismatched = router.response(
            for: "GET /api/v1/images/remote-item/poster?size=160 HTTP/1.1\r\nIf-None-Match: \"stale\"\r\n\r\n"
        )
        // 弱标签的弱比较：`W/"x"` 与 `"x"` 是同一个表示。
        let strongForm = entityTag.hasPrefix("W/") ? String(entityTag.dropFirst(2)) : entityTag
        let strongRevalidated = router.response(
            for: "GET /api/v1/images/remote-item/poster?size=160 HTTP/1.1\r\nIf-None-Match: \(strongForm)\r\n\r\n"
        )
        let wildcard = router.response(
            for: "GET /api/v1/images/remote-item/poster?size=160 HTTP/1.1\r\nIf-None-Match: *\r\n\r\n"
        )

        XCTAssertEqual(revalidated.statusCode, 304)
        XCTAssertEqual(revalidated.declaredContentLength, 0)
        XCTAssertTrue(revalidated.body.isEmpty)
        XCTAssertEqual(strongRevalidated.statusCode, 304)
        XCTAssertEqual(wildcard.statusCode, 304)
        XCTAssertEqual(mismatched.statusCode, 200, "标签对不上就必须重新发整张图")
        XCTAssertEqual(mismatched.declaredContentLength, first.declaredContentLength)
        XCTAssertEqual(requestCount, 1, "复验不得回源")
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
        // 扩展名要真的是 `.vtt`：只有已经是 WebVTT 的那一份才原样流式送出，
        // SRT 与 ASS 必须先在服务端转换（`<track>` 只认 WebVTT）。
        let subtitle = try makeFixtureFile(contents: Data("WEBVTT\n\n".utf8), pathExtension: "vtt")
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            webVTTSubtitleTracksProvider: { itemID, _ in
                itemID == "movie-1" ? [
                    ServerWebVTTSubtitleTrack(id: 0, label: "字幕 1"),
                    ServerWebVTTSubtitleTrack(id: 17, label: "简体中文", language: "zh-Hans", origin: .embedded)
                ] : nil
            },
            subtitleTrackProvider: { itemID, trackID, _ in
                guard itemID == "movie-1", trackID == 0 || trackID == 17 else { return nil }
                return ServerSubtitleTrackReference(
                    label: trackID == 17 ? "简体中文" : "字幕 1", language: trackID == 17 ? "zh-Hans" : nil, origin: .sidecar,
                    source: .sidecar(ServerMediaAsset(id: itemID, fileURL: subtitle, byteLength: 8))
                )
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let list = router.response(for: "GET /api/v1/playback/subtitles/movie-1 HTTP/1.1\r\n\r\n")
        let asset = router.response(for: "GET /api/v1/subtitles/movie-1/0 HTTP/1.1\r\n\r\n")
        let highIndexAsset = router.response(for: "GET /api/v1/subtitles/movie-1/17 HTTP/1.1\r\n\r\n")
        let malformed = router.response(for: "GET /api/v1/subtitles/movie-1/0/extra HTTP/1.1\r\n\r\n")

        XCTAssertEqual(list.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode([ServerWebVTTSubtitleTrack].self, from: list.body), [
            ServerWebVTTSubtitleTrack(id: 0, label: "字幕 1"),
            ServerWebVTTSubtitleTrack(id: 17, label: "简体中文", language: "zh-Hans", origin: .embedded)
        ])
        XCTAssertFalse((String(data: list.body, encoding: .utf8) ?? "").contains(subtitle.path))
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertEqual(highIndexAsset.statusCode, 200, "第 18 条内封字幕仍须可寻址")
        XCTAssertEqual(asset.contentType, "text/vtt; charset=utf-8")
        XCTAssertEqual(asset.declaredContentLength, Data("WEBVTT\n\n".utf8).count)
        XCTAssertTrue(asset.body.isEmpty, "文件内容会由 socket 流式写出，路由层不复制进内存 body")
        XCTAssertEqual(malformed.statusCode, 404)
    }

    /// 轨道名单是"网页上有没有字幕/音轨入口"的唯一来源。它必须逐条目授权，
    /// 而且既不能泄露文件名，也不能泄露上游地址。
    func testPlaybackTrackRouteIsAuthorizedAndOpaque() throws {
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            playbackTracksProvider: { itemID, _ in
                guard itemID == "movie-1" else { return nil }
                return ServerWebPlaybackTrackSet(
                    audio: [ServerWebAudioTrack(
                        id: 0, label: "英语 · AC3 · 6 声道", language: "eng", codec: "ac3",
                        channels: 6, browserPlayable: false, isDefault: true
                    )],
                    subtitles: [ServerWebVTTSubtitleTrack(
                        id: 0, label: "简体中文", language: "zh-Hans", origin: .embedded
                    )],
                    remuxable: true,
                    remuxUnavailableReason: nil,
                    durationSeconds: 3_019
                )
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let response = router.response(for: "GET /api/v1/playback/tracks/movie-1 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(response.statusCode, 200)
        let payload = try JSONDecoder().decode(ServerWebPlaybackTrackSet.self, from: response.body)
        XCTAssertEqual(payload.audio.first?.browserPlayable, false)
        XCTAssertEqual(payload.subtitles.first?.origin, .embedded)
        XCTAssertTrue(payload.remuxable)
        XCTAssertEqual(payload.durationSeconds, 3_019)
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("/"), "名单里只有序号与标签，没有任何路径或地址")
        XCTAssertEqual(router.response(for: "GET /api/v1/playback/tracks/unknown HTTP/1.1\r\n\r\n").statusCode, 404)
    }

    /// 重封装端点的查询串按白名单解析，未知键与越界值一律 404；未授权条目拿不到流。
    func testAudioRemuxRouteRejectsUnknownQueryKeysAndUnauthorizedItems() {
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            audioRemuxProvider: { itemID, audioTrackID, startSeconds, _ in
                guard itemID == "movie-1", audioTrackID == 1, startSeconds == 120 else { return nil }
                return ServerAudioRemuxStream(
                    asset: ServerMediaAsset(
                        id: itemID, fileURL: URL(fileURLWithPath: "/media/a.mkv"), byteLength: 1
                    ),
                    audioTrackID: audioTrackID,
                    startSeconds: startSeconds,
                    executableURL: URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double")
                )
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        let accepted = router.response(for: "HEAD /api/v1/transcode/movie-1?audio=1&start=120 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(accepted.statusCode, 200)
        XCTAssertEqual(accepted.contentType, "video/mp4")
        // 分片流不接受 Range：字节是边转边给的，长度要等转完才知道。跳转靠改
        // `start=` 重开一条流，不靠 Range。
        XCTAssertTrue(accepted.additionalHeaders.contains("Accept-Ranges: none"))

        XCTAssertEqual(router.response(for: "GET /api/v1/transcode/movie-1?audio=1&start=120&x=1 HTTP/1.1\r\n\r\n").statusCode, 404)
        XCTAssertEqual(router.response(for: "GET /api/v1/transcode/movie-1?audio=99&start=0 HTTP/1.1\r\n\r\n").statusCode, 404)
        XCTAssertEqual(router.response(for: "GET /api/v1/transcode/movie-1?audio=1&audio=1 HTTP/1.1\r\n\r\n").statusCode, 404)
        XCTAssertEqual(router.response(for: "GET /api/v1/transcode/other HTTP/1.1\r\n\r\n").statusCode, 404)
    }

    /// 往一条对端已经关掉的 socket 上 `send()` 会触发 SIGPIPE，默认处置是**终止
    /// 进程**——整台服务器跟着一个离开的浏览器一起死。真实验收里，中止一条重封装
    /// 流一次就让服务端退出了。
    ///
    /// 这条断言守的是"每条已接受的连接都关掉了 SIGPIPE"这个设置本身；行为一侧
    /// 由真实浏览器中止流的验收覆盖（连续三次中止后服务端仍在监听）。
    func testAcceptedSocketsDisableSIGPIPE() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MediaLibServer/LocalLoopbackHTTPServer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("SO_NOSIGPIPE"))
    }

    /// 没有 `Content-Length` 的响应无法在同一条连接上界定边界，所以它一定关连接。
    func testUnknownLengthResponsesOmitContentLengthAndCloseTheConnection() throws {
        let response = LocalHTTPResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "video/mp4",
            payload: .data(Data()),
            declaredContentLength: LocalHTTPResponse.unknownContentLength,
            additionalHeaders: []
        )
        let headers = try XCTUnwrap(String(data: response.serializedHeaders(keepAlive: true), encoding: .utf8))
        XCTAssertFalse(headers.contains("Content-Length"))
    }

    func testWebPlayerDoesNotExposeServerTranscodeRoutes() {
        XCTAssertEqual(router.response(for: "POST /api/v1/playback/hls/movie-1 HTTP/1.1\r\n\r\n").statusCode, 405)
        XCTAssertEqual(router.response(for: "GET /api/v1/hls/session/index.m3u8 HTTP/1.1\r\n\r\n").statusCode, 404)
        XCTAssertEqual(router.response(for: "DELETE /api/v1/hls/session HTTP/1.1\r\n\r\n").statusCode, 405)
        XCTAssertEqual(router.response(for: "GET /api/v1/transcode/movie-1 HTTP/1.1\r\n\r\n").statusCode, 404)
    }

    private func makeFixtureFile(contents: Data, pathExtension: String = "") throws -> URL {
        var name = UUID().uuidString
        if !pathExtension.isEmpty { name += ".\(pathExtension)" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
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

private final class ThumbnailGenerationGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func enterGeneration() {
        entered.signal()
        _ = released.wait(timeout: .now() + 2)
    }

    func waitForTwoGenerations(timeout: TimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
            && entered.wait(timeout: .now() + timeout) == .success
    }

    func releaseTwoGenerations() {
        released.signal()
        released.signal()
    }
}

extension LocalHTTPRouterTests {
    /// 一张 2×2 的真 JPEG。
    ///
    /// 远程封面的响应现在一定是服务端派生出来的图片，桩数据必须真能被 ImageIO
    /// 解码——用三个字节的 JPEG 魔数只会让派生失败、路由回 503。
    static func tinyJPEGData() throws -> Data {
        let width = 2
        let height = 2
        var pixels = [UInt8](repeating: 0x80, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private enum ProbeFailure: LocalizedError {
    case pathInError

    var errorDescription: String? { "/private/secret/media.mkv" }
}

private enum CatalogFailure: Error {
    case unavailable
}

/// The reduced-motion policy lives in the shared base sheet rather than being
/// re-declared, inconsistently, by every page stylesheet — the previous layout
/// had twenty copies, several of which failed to stop infinite animations.
func reducedMotionPolicyIsCentralised(in router: LocalHTTPRouter) -> Bool {
    let response = router.response(for: "GET /assets/base.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let css = String(data: response.body, encoding: .utf8) ?? ""
    return css.contains("prefers-reduced-motion: reduce")
}

/// 记录路由实际发出的浏览查询。`libraryBrowseProvider` 是个 `@escaping` 闭包，
/// 直接捕获局部数组会在并发检查下报错，所以用一个带锁的小盒子。
private final class QueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ServerLibraryQuery] = []

    var values: [ServerLibraryQuery] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ query: ServerLibraryQuery) {
        lock.lock()
        storage.append(query)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
