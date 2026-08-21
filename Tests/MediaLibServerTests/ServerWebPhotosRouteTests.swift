import XCTest
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerWebPhotosRouteTests: XCTestCase {
    private let page = ServerLibraryItemsPage(
        totalItemCount: 1, offset: 0, limit: 24,
        items: [ServerLibraryItem(id: "photo id+1", type: "photo", title: "照片 <script>", year: 2026, artworkAvailable: true)]
    )
    private let detail = ServerMediaItemDetail(
        id: "photo id+1", type: "photo", title: "照片 <script>", originalTitle: nil, year: 2026,
        overview: nil, genres: [], communityRating: nil, runtimeSeconds: nil, videoCodec: nil,
        audioCodec: nil, resolution: "2048×1536", artworkAvailable: true, backdropAvailable: false,
        canDirectPlay: false, canTranscode: false
    )

    func testPhotoGalleryAndDetailRequireAuthAndUseSameOriginImage() {
        let unauthenticated = LocalHTTPRouter(serverID: "server", serverName: "Server")
        XCTAssertEqual(unauthenticated.response(for: "GET /photos HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 401)
        let router = makeRouter()
        let gallery = String(data: router.response(for: request("/photos")).body, encoding: .utf8) ?? ""
        XCTAssertTrue(gallery.contains("照片 &lt;script&gt;"))
        XCTAssertTrue(gallery.contains("href=\"/photo/photo%20id%2B1\""))
        XCTAssertTrue(gallery.contains("/api/v1/images/photo%20id%2B1/poster"))
        XCTAssertTrue(gallery.contains("href=\"/assets/photos.css?v="))
        XCTAssertTrue(gallery.contains("src=\"/assets/photos.js?v="))
        XCTAssertTrue(gallery.contains("class=\"ui-control-bar gallery-toolbar\""))
        XCTAssertTrue(gallery.contains("class=\"gallery-grid\""))
        XCTAssertTrue(gallery.contains("data-artwork-palette=\"poster-"))
        XCTAssertFalse(gallery.contains("<script>"))

        let photo = String(data: router.response(for: request("/photo/photo%20id%2B1")).body, encoding: .utf8) ?? ""
        XCTAssertTrue(photo.contains("class=\"photo-stage\""))
        XCTAssertTrue(photo.contains("/api/v1/images/photo%20id%2B1/poster"))
        XCTAssertEqual(router.response(for: request("/photo/photo%2Fescape")).statusCode, 404)
        XCTAssertEqual(router.response(for: request("/photo/unknown")).statusCode, 404)
    }

    func testPhotoAPIUsesStrictBoundedQueriesAndCurrentPrincipal() {
        var received: (query: ServerLibraryQuery, userID: String)?
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            libraryBrowseProvider: { query, principal in
                received = (query, principal.userID)
                return self.page
            },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )
        XCTAssertEqual(router.response(for: request("/api/v1/photos?offset=24&limit=12")).statusCode, 200)
        XCTAssertEqual(received?.query.type, "photo")
        XCTAssertEqual(received?.query.offset, 24)
        XCTAssertEqual(received?.query.limit, 12)
        XCTAssertEqual(received?.userID, "viewer")
        for invalid in [
            "/api/v1/photos?type=movie&offset=0&limit=24",
            "/api/v1/photos?offset=0&offset=1&limit=24",
            "/api/v1/photos?offset=-1&limit=24",
            "/api/v1/photos?offset=0&limit=101"
        ] { XCTAssertEqual(router.response(for: request(invalid)).statusCode, 400, invalid) }
    }

    func testPhotoAssetsUseSafeDOMAndReducedMotion() {
        let router = makeRouter()
        let js = String(data: router.response(for: "GET /assets/photos.js HTTP/1.1\r\nHost: localhost\r\n\r\n").body, encoding: .utf8) ?? ""
        XCTAssertEqual(router.response(for: "GET /assets/photos.css HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 200)
        XCTAssertTrue(ServerWebBaseStyle.css.contains("prefers-reduced-motion: reduce"), "减少动效策略集中在 base.css")
        XCTAssertTrue(ServerWebPhotosPage.style.contains("grid-template-columns: repeat(12, minmax(0, 1fr))"))
        XCTAssertTrue(ServerWebPhotosPage.style.contains("var(--media-scrim)"))
        XCTAssertTrue(ServerWebPhotosPage.style.contains(".photo-art"))
        // 「加载更多」的包装是公共的 `.ui-load-more`；相册、合集、人物此前各带一份逐字相同的拷贝。
        XCTAssertTrue(ServerWebPrimitives.css.contains(".ui-load-more {"))
        XCTAssertFalse(ServerWebPhotosPage.style.contains(".gallery-more {"))
        XCTAssertTrue(js.contains("textContent"))
        XCTAssertTrue(js.contains("createDocumentFragment"))
        XCTAssertTrue(js.contains("art.append(image); image.src"))
        XCTAssertTrue(js.contains("credentials: 'same-origin'"))
        XCTAssertTrue(js.contains("photo-refresh"))
        XCTAssertFalse(js.contains("innerHTML"))
        XCTAssertFalse(js.contains("document.cookie"))
        XCTAssertFalse(js.contains("localStorage"))
        XCTAssertFalse(js.contains("eval("))
    }

    private var viewer: ServerRequestPrincipal {
        ServerRequestPrincipal(userID: "viewer", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia], libraryGrants: [:])
    }

    private func makeRouter() -> LocalHTTPRouter {
        LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            libraryBrowseProvider: { _, _ in self.page },
            mediaDetailProvider: { id, _ in id == self.detail.id ? self.detail : nil },
            authenticationProvider: { head in head.contains("Authorization: Bearer viewer") ? self.viewer : nil }
        )
    }

    private func request(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\n\r\n"
    }
}
