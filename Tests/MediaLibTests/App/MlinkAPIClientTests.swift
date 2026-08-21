import Foundation
import XCTest
@testable import MediaLib
@testable import MediaLibServerProtocol

final class MlinkAPIClientTests: XCTestCase {
    func testDiscoveryNormalizesURLAndAcceptsOnlyVerifiedDescriptor() async throws {
        let descriptor = MlinkServerDescriptor(
            serverID: "server-001", serverName: "客厅服务器", capabilities: ["authenticated-library"]
        )
        let client = MlinkAPIClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://media.example.test/.well-known/mlink")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (try self.encoded(descriptor), self.response(for: request, status: 200))
        }

        let discovered = try await client.discover(serverURL: try XCTUnwrap(URL(string: "https://media.example.test/base?token=discarded#fragment")))

        XCTAssertEqual(discovered, descriptor)
    }

    func testDiscoveryRejectsCredentialsAndNonLoopbackHTTP() async {
        let client = MlinkAPIClient { request in
            XCTFail("不安全地址不应发起网络请求：\(request)")
            throw URLError(.badURL)
        }

        await XCTAssertThrowsErrorAsync(try await client.discover(serverURL: try XCTUnwrap(URL(string: "https://user:pass@media.example.test")))) { error in
            XCTAssertEqual(error as? MlinkAPIClient.Error, .invalidServerURL)
        }
        await XCTAssertThrowsErrorAsync(try await client.discover(serverURL: try XCTUnwrap(URL(string: "http://media.example.test")))) { error in
            XCTAssertEqual(error as? MlinkAPIClient.Error, .insecureTransport)
        }
    }

    func testLoginAndCategoriesUseBearerWithoutLeakingCredentialsIntoURL() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = MlinkAPIClient.SessionTokens(
            accessToken: String(repeating: "a", count: 48),
            refreshToken: String(repeating: "r", count: 48),
            tokenType: "Bearer",
            accessExpiresAt: now,
            refreshExpiresAt: now.addingTimeInterval(86_400),
            sessionID: "session-001",
            deviceID: "device-001"
        )
        let categories = ServerLibraryCategoriesResponse(categories: [
            ServerLibraryCategory(id: "movie", title: "电影", itemCount: 12)
        ])
        let client = MlinkAPIClient { request in
            if request.url?.path == "/api/v1/auth/login" {
                XCTAssertEqual(request.url?.absoluteString, "https://media.example.test/api/v1/auth/login")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.url?.query)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-MediaLIB-Client"), "mlink-native/1")
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(object["username"], "alice")
                XCTAssertEqual(object["password"], "correct horse battery staple")
                XCTAssertEqual(object["delivery"], "token")
                return (try self.encoded(tokens), self.response(for: request, status: 200))
            }
            XCTAssertEqual(request.url?.absoluteString, "https://media.example.test/api/v1/library/categories")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(tokens.accessToken)")
            return (try self.encoded(categories), self.response(for: request, status: 200))
        }

        let serverURL = try XCTUnwrap(URL(string: "https://media.example.test"))
        let issued = try await client.login(
            serverURL: serverURL, username: " alice ", password: "correct horse battery staple", deviceName: "MediaLIB Mac"
        )
        let result = try await client.categories(serverURL: serverURL, accessToken: issued.accessToken)

        XCTAssertEqual(issued, tokens)
        XCTAssertEqual(result, categories)
    }

    func testBrowseUsesWhitelistedQueryAndRejectsUnsafePage() async throws {
        let token = String(repeating: "a", count: 48)
        let page = ServerLibraryItemsPage(
            totalItemCount: 1,
            offset: 0,
            limit: 100,
            items: [ServerLibraryItem(id: "movie-1", type: "movie", title: "影片", year: 2026, artworkAvailable: true)]
        )
        let client = MlinkAPIClient { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/api/v1/library/browse")
            XCTAssertEqual(Set(components.queryItems ?? []), Set([
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "sort", value: "recentlyUpdated"),
                URLQueryItem(name: "type", value: "movie")
            ]))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            return (try self.encoded(page), self.response(for: request, status: 200))
        }

        let result = try await client.browse(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test")), accessToken: token, type: "movie"
        )

        XCTAssertEqual(result, page)
        await XCTAssertThrowsErrorAsync(try await client.browse(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test")), accessToken: token, type: "private"
        )) { error in
            XCTAssertEqual(error as? MlinkAPIClient.Error, .untrustedResponse)
        }
    }

    func testBrowseRejectsServerItemIDsThatCouldEscapeWebPath() async throws {
        let token = String(repeating: "a", count: 48)
        let page = ServerLibraryItemsPage(
            totalItemCount: 1,
            offset: 0,
            limit: 100,
            items: [ServerLibraryItem(id: "movie/../admin", type: "movie", title: "危险条目", year: nil, artworkAvailable: false)]
        )
        let client = MlinkAPIClient { request in
            (try self.encoded(page), self.response(for: request, status: 200))
        }

        await XCTAssertThrowsErrorAsync(try await client.browse(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test")), accessToken: token, type: "movie"
        )) { error in
            XCTAssertEqual(error as? MlinkAPIClient.Error, .untrustedResponse)
        }
    }

    func testRefreshPostsTokenInBodyAndNotURL() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldRefresh = String(repeating: "r", count: 48)
        let tokens = MlinkAPIClient.SessionTokens(
            accessToken: String(repeating: "a", count: 48), refreshToken: String(repeating: "n", count: 48),
            tokenType: "Bearer", accessExpiresAt: now, refreshExpiresAt: now.addingTimeInterval(86_400),
            sessionID: "session-002", deviceID: "device-001"
        )
        let client = MlinkAPIClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://media.example.test/api/v1/auth/refresh")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MediaLIB-Client"), "mlink-native/1")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["refreshToken"], oldRefresh)
            XCTAssertEqual(object["delivery"], "token")
            return (try self.encoded(tokens), self.response(for: request, status: 200))
        }

        let refreshed = try await client.refresh(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test")), refreshToken: oldRefresh
        )

        XCTAssertEqual(refreshed, tokens)
    }

    func testPreferenceUpdateUsesBearerNativeMarkerAndExactlyOneJSONField() async throws {
        let token = String(repeating: "a", count: 48)
        let expected = ServerMediaUserPreference(isFavorite: true, isWatchlist: false, rating: 4.5)
        let client = MlinkAPIClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://media.example.test/api/v1/user-media/preferences/movie-1")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MediaLIB-Client"), "mlink-native/1")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-MediaLIB-CSRF"))
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["rating"]))
            XCTAssertEqual(object["rating"] as? Double, 4.5)
            return (try self.encoded(expected), self.response(for: request, status: 200))
        }

        let result = try await client.updatePreference(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test")), accessToken: token,
            itemID: "movie-1", update: .rating(4.5)
        )

        XCTAssertEqual(result, expected)
        await XCTAssertThrowsErrorAsync(try await client.updatePreference(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test")), accessToken: token,
            itemID: "movie/1", update: .favorite(true)
        )) { error in
            XCTAssertEqual(error as? MlinkAPIClient.Error, .untrustedResponse)
        }
    }

    func testPlaybackStateUpdateUsesBearerNativeMarkerWithoutMediaURL() async throws {
        let token = String(repeating: "a", count: 48)
        let state = ServerMediaUserState(
            itemID: "movie-1", positionSeconds: 0, progress: 1, isWatched: true,
            playCount: 3, lastPlayedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 101)
        )
        let client = MlinkAPIClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://media.example.test/api/v1/playback/state/movie-1")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MediaLIB-Client"), "mlink-native/1")
            XCTAssertNil(request.url?.query)
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["event", "positionSeconds"]))
            XCTAssertEqual(object["event"] as? String, "completed")
            XCTAssertEqual(object["positionSeconds"] as? Double, 0)
            return (try self.encoded(state), self.response(for: request, status: 200))
        }

        let result = try await client.updatePlaybackState(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test")), accessToken: token,
            itemID: "movie-1", event: .completed, positionSeconds: 0
        )

        XCTAssertEqual(result, state)
    }

    func testWebItemURLContainsNoTokenAndRejectsPathTraversalIdentifiers() throws {
        let client = MlinkAPIClient { _ in
            XCTFail("构造网页地址不应发起网络请求")
            throw URLError(.badURL)
        }

        let url = try client.webItemURL(
            serverURL: try XCTUnwrap(URL(string: "https://media.example.test/base?token=discarded#fragment")),
            itemID: "movie-001"
        )

        XCTAssertEqual(url.absoluteString, "https://media.example.test/item/movie-001")
        XCTAssertEqual(
            try client.webItemURL(
                serverURL: try XCTUnwrap(URL(string: "https://media.example.test")),
                itemID: "series-001",
                isSeries: true
            ).absoluteString,
            "https://media.example.test/series/series-001"
        )
        XCTAssertNil(url.query)
        XCTAssertFalse(MlinkAPIClient.isSafeWebItemIdentifier("../admin"))
        XCTAssertFalse(MlinkAPIClient.isSafeWebItemIdentifier("movie/001"))
        XCTAssertFalse(MlinkAPIClient.isSafeWebItemIdentifier("movie\\001"))
        XCTAssertFalse(MlinkAPIClient.isSafeWebItemIdentifier("movie\n001"))
    }

    private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("预期抛出错误")
    } catch {
        handler(error)
    }
}
