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
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let headers = String(data: page.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertTrue(html.contains("客厅 &lt;服务器&gt;"))
        XCTAssertTrue(html.contains("content=\"known-token\""))
        XCTAssertTrue(html.contains("src=\"/assets/login.js\""))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(headers.contains("script-src 'self'"))
        XCTAssertEqual(script.contentType, "text/javascript; charset=utf-8")
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
                        artworkAvailable: false
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
        XCTAssertFalse(html.contains("filePath"))
        XCTAssertFalse(html.contains("sourcePath"))
    }

    func testEveryResponseCarriesBrowserSecurityHeaders() {
        let response = router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertTrue(headers.contains("Content-Security-Policy: default-src 'none'"))
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

        let valid = router.response(for: "GET /api/v1/library/browse?q=%E9%93%B6%E6%B2%B3+1&type=movie&offset=48&limit=48&sort=titleAscending HTTP/1.1\r\n\r\n")
        XCTAssertEqual(valid.statusCode, 200)
        XCTAssertEqual(captured, ServerLibraryQuery(searchText: "银河 1", type: "movie", offset: 48, limit: 48, sort: .titleAscending))
        XCTAssertEqual(try JSONDecoder().decode(ServerLibraryItemsPage.self, from: valid.body).offset, 48)

        for target in [
            "/api/v1/library/browse?limit=101",
            "/api/v1/library/browse?offset=-1",
            "/api/v1/library/browse?type=private",
            "/api/v1/library/browse?type=unknown",
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
            authenticationProvider: { _ in .testAdministrator() }
        )
        let page = router.response(for: "GET /library HTTP/1.1\r\n\r\n")
        let asset = router.response(for: "GET /assets/library.js HTTP/1.1\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(asset.contentType, "text/javascript; charset=utf-8")
        XCTAssertTrue(html.contains("客厅 &lt;服务器&gt;"))
        XCTAssertTrue(html.contains("src=\"/assets/library.js\""))
        XCTAssertTrue(html.contains("prefers-reduced-motion"))
        XCTAssertTrue(html.contains("Mlink"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("encodeURIComponent"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("/api/v1/images/"))
        XCTAssertTrue(script.contains("image.loading = 'lazy'"))
        XCTAssertTrue(script.contains("image.decoding = 'async'"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("eval("))
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

    func testHLSRoutesCreateServeAndCancelAnIsolatedSession() throws {
        let sourceURL = try makeFixtureFile(contents: Data("source".utf8))
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalHTTPRouterTests-HLS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDirectory) }
        let process = RouterHLSProcessStub()
        var capturedArguments: [String] = []
        let manager = FFmpegHLSSessionManager(
            cacheDirectory: cacheDirectory,
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            processFactory: { _, arguments, _ in
                capturedArguments = arguments
                return process
            }
        )
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            mediaAssetProvider: { id, _, _ in
                id == "movie-1" ? ServerMediaAsset(id: id, fileURL: sourceURL, byteLength: 6) : nil
            },
            hlsSessionManager: manager,
            authenticationProvider: { _ in .testAdministrator() }
        )

        let unsafeGet = router.response(for: "GET /api/v1/playback/hls/movie-1 HTTP/1.1\r\n\r\n")
        let startResponse = router.response(for: "POST /api/v1/playback/hls/movie-1 HTTP/1.1\r\n\r\n")
        let session = try JSONDecoder().decode(ServerHLSPlaybackSession.self, from: startResponse.body)
        guard let manifestArgument = capturedArguments.last else { return XCTFail("Expected manifest argument") }
        let manifestURL = URL(fileURLWithPath: manifestArgument)
        try Data("#EXTM3U\n".utf8).write(to: manifestURL)

        let outputResponse = router.response(for: "GET \(session.manifestPath) HTTP/1.1\r\n\r\n")
        XCTAssertEqual(unsafeGet.statusCode, 404)
        XCTAssertEqual(startResponse.statusCode, 200)
        XCTAssertEqual(outputResponse.statusCode, 200)
        XCTAssertEqual(outputResponse.contentType, "application/vnd.apple.mpegurl")
        XCTAssertFalse(String(data: startResponse.body, encoding: .utf8)?.contains(cacheDirectory.path) ?? true)

        let cancelResponse = router.response(for: "DELETE /api/v1/hls/\(session.id) HTTP/1.1\r\n\r\n")
        let afterCancel = router.response(for: "GET \(session.manifestPath) HTTP/1.1\r\n\r\n")
        XCTAssertEqual(cancelResponse.statusCode, 204)
        XCTAssertTrue(process.didTerminate)
        XCTAssertEqual(afterCancel.statusCode, 404)
    }

    private func makeFixtureFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private enum ProbeFailure: LocalizedError {
    case pathInError

    var errorDescription: String? { "/private/secret/media.mkv" }
}

private final class RouterHLSProcessStub: HLSManagedProcess {
    private(set) var didTerminate = false
    var isRunning: Bool { !didTerminate }
    func terminate() { didTerminate = true }
}

private enum CatalogFailure: Error {
    case unavailable
}
