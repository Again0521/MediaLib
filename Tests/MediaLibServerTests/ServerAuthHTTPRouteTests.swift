import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

final class ServerAuthHTTPRouteTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerIdentityRepository!
    private var authentication: ServerAuthenticationService!
    private var router: LocalHTTPRouter!
    private var generator: HTTPRouteTokenGenerator!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerAuthHTTPRouteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerIdentityRepository(database: database)
        let hasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 4, count: count) }
        )
        let user = try repository.createUser(
            id: "user-alice", username: "alice", displayName: "Alice"
        )
        try repository.setCredential(
            userID: user.id,
            argon2idEncodedHash: try hasher.hash(password: "correct horse battery staple")
        )
        generator = HTTPRouteTokenGenerator()
        authentication = try ServerAuthenticationService(
            database: database,
            identityRepository: repository,
            passwordHasher: hasher,
            accessTokenLifetime: 900,
            refreshTokenLifetime: 86_400,
            tokenGenerator: { [generator] in generator?.next() ?? String(repeating: "z", count: 32) }
        )
        router = LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            currentUserProfileProvider: { [authentication] in
                try authentication?.currentUserProfile(for: $0)
            },
            authenticationService: authentication,
            authenticationProvider: { [authentication] in try authentication?.principal(forRequestHead: $0) }
        )
    }

    override func tearDownWithError() throws {
        router = nil
        authentication = nil
        repository = nil
        database = nil
        generator = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testTokenDeliveryLoginAndSingleUseRefreshRoute() throws {
        let login = try requestBody([
            "username": "alice",
            "password": "correct horse battery staple",
            "deviceName": "Native Client",
            "platform": "macOS",
            "delivery": "token"
        ])
        let loginResponse = router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: login
        )
        let first = try decodeTokens(loginResponse.body)

        XCTAssertEqual(loginResponse.statusCode, 200)
        XCTAssertFalse(String(data: loginResponse.serializedHeaders(), encoding: .utf8)?.contains("Set-Cookie") ?? true)
        let refreshBody = try requestBody(["refreshToken": first.refreshToken, "delivery": "token"])
        let refreshResponse = router.response(
            for: "POST /api/v1/auth/refresh HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: refreshBody
        )
        let second = try decodeTokens(refreshResponse.body)
        let replay = router.response(
            for: "POST /api/v1/auth/refresh HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: refreshBody
        )

        XCTAssertEqual(refreshResponse.statusCode, 200)
        XCTAssertNotEqual(first.accessToken, second.accessToken)
        XCTAssertEqual(replay.statusCode, 401)
    }

    func testCookieDeliveryNeverReturnsRawTokensAndLogoutExpiresCookies() throws {
        let login = try requestBody([
            "username": "alice",
            "password": "correct horse battery staple",
            "deviceName": "Web Browser",
            "platform": "Web",
            "delivery": "cookie"
        ])
        let loginResponse = router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: login
        )
        let headers = String(data: loginResponse.serializedHeaders(), encoding: .utf8) ?? ""
        let accessToken = try XCTUnwrap(cookieValue(
            named: ServerAuthenticationService.accessCookieName,
            in: headers
        ))

        XCTAssertEqual(loginResponse.statusCode, 200)
        XCTAssertFalse(String(data: loginResponse.body, encoding: .utf8)?.contains(accessToken) ?? true)
        XCTAssertTrue(headers.contains("HttpOnly; Secure; SameSite=Strict"))
        XCTAssertTrue(headers.contains("Path=/api/v1/auth"))

        let logout = router.response(
            for: "POST /api/v1/auth/logout HTTP/1.1\r\nHost: localhost\r\nCookie: MediaLIBAccess=\(accessToken)\r\n\r\n"
        )
        let logoutHeaders = String(data: logout.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(logout.statusCode, 204)
        XCTAssertTrue(logoutHeaders.contains("Max-Age=0"))
        XCTAssertNil(try authentication.principal(forAccessToken: accessToken))
    }

    func testCookieRefreshRotatesPersistedBrowserSessionWithoutExposingTokens() throws {
        let login = try requestBody([
            "username": "alice",
            "password": "correct horse battery staple",
            "deviceName": "Web Browser",
            "platform": "Web",
            "delivery": "cookie"
        ])
        let loginResponse = router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: login
        )
        let loginHeaders = String(data: loginResponse.serializedHeaders(), encoding: .utf8) ?? ""
        let refreshToken = try XCTUnwrap(cookieValue(
            named: ServerAuthenticationService.refreshCookieName,
            in: loginHeaders
        ))

        let refresh = router.response(
            for: "POST /api/v1/auth/refresh HTTP/1.1\r\nHost: localhost\r\nCookie: MediaLIBRefresh=\(refreshToken)\r\n\r\n"
        )
        let refreshHeaders = String(data: refresh.serializedHeaders(), encoding: .utf8) ?? ""
        let refreshBody = String(data: refresh.body, encoding: .utf8) ?? ""

        XCTAssertEqual(refresh.statusCode, 200)
        XCTAssertTrue(refreshHeaders.contains("Set-Cookie: MediaLIBAccess="))
        XCTAssertTrue(refreshHeaders.contains("Set-Cookie: MediaLIBRefresh="))
        XCTAssertTrue(refreshHeaders.contains("HttpOnly; Secure; SameSite=Strict"))
        XCTAssertFalse(refreshBody.contains("MediaLIBAccess"))
        XCTAssertFalse(refreshBody.contains("MediaLIBRefresh"))
        XCTAssertFalse(refreshBody.contains(refreshToken))
    }

    func testWrongPasswordAndMalformedJSONUseSafeStatuses() throws {
        let wrong = try requestBody([
            "username": "alice", "password": "wrong-password-value",
            "deviceName": "Browser", "platform": "Web"
        ])

        XCTAssertEqual(
            router.response(
                for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
                body: wrong
            ).statusCode,
            401
        )
        XCTAssertEqual(
            router.response(
                for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
                body: Data("{broken".utf8)
            ).statusCode,
            400
        )
        let invalidRefreshDelivery = try requestBody([
            "refreshToken": String(repeating: "r", count: 32), "delivery": "local-storage"
        ])
        XCTAssertEqual(
            router.response(
                for: "POST /api/v1/auth/refresh HTTP/1.1\r\nHost: localhost\r\n\r\n",
                body: invalidRefreshDelivery
            ).statusCode,
            400
        )
    }

    func testAuthenticatedHTTPStillHasNoAdministratorRecoveryRoute() throws {
        let login = try requestBody([
            "username": "alice",
            "password": "correct horse battery staple",
            "deviceName": "Native Client",
            "platform": "macOS",
            "delivery": "token"
        ])
        let tokens = try decodeTokens(router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: login
        ).body)

        let response = router.response(
            for: "POST /api/v1/auth/recover HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(tokens.accessToken)\r\n\r\n"
        )

        XCTAssertEqual(response.statusCode, 405)
        let responseText = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertFalse(responseText.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(responseText.localizedCaseInsensitiveContains("recover"))
    }

    func testCurrentUserProfileAndAccountPageAreAuthenticatedAndTokenFree() throws {
        let login = try requestBody([
            "username": "alice",
            "password": "correct horse battery staple",
            "deviceName": "Web Browser",
            "platform": "Web",
            "delivery": "token"
        ])
        let tokens = try decodeTokens(router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: login
        ).body)
        let profile = router.response(for: authenticatedRequest("/api/v1/auth/me", token: tokens.accessToken))
        let page = router.response(for: authenticatedRequest("/account", token: tokens.accessToken))
        let asset = router.response(for: "GET /assets/account.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let stylesheet = router.response(for: "GET /assets/account.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let profileObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: profile.body) as? [String: Any]
        )
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(router.response(for: "GET /api/v1/auth/me HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode, 401)
        XCTAssertEqual(profile.statusCode, 200)
        XCTAssertEqual(profileObject["username"] as? String, "alice")
        XCTAssertEqual(profileObject["displayName"] as? String, "Alice")
        XCTAssertNotNil(profileObject["roleIDs"] as? [String])
        XCTAssertNotNil(profileObject["permissionIDs"] as? [String])
        XCTAssertNil(profileObject["id"])
        XCTAssertNil(profileObject["sessionID"])
        XCTAssertNil(profileObject["deviceID"])
        XCTAssertFalse(String(data: profile.body, encoding: .utf8)?.contains(tokens.accessToken) ?? true)
        XCTAssertEqual(page.statusCode, 200)
        XCTAssertTrue(html.contains("src=\"/assets/account.js?v="))
        XCTAssertTrue(html.contains("href=\"/assets/account.css?v="))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(html.contains("设置"))
        XCTAssertTrue(html.contains("id=\"logout\""))
        XCTAssertTrue(html.contains("content=\"test-csrf-token\""))
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(script.contains("/api/v1/auth/me"))
        XCTAssertTrue(script.contains("/api/v1/auth/logout"))
        XCTAssertTrue(script.contains("/api/v1/auth/password"))
        XCTAssertTrue(script.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(script.contains("JSON.stringify({ currentPassword, newPassword })"))
        XCTAssertTrue(script.contains("currentField.value = ''"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("sessionStorage"))
        XCTAssertFalse(script.contains("eval("))
        let stylesheetHeaders = String(data: stylesheet.serializedHeaders(), encoding: .utf8) ?? ""
        let stylesheetText = String(data: stylesheet.body, encoding: .utf8) ?? ""
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Content-Type: text/css; charset=utf-8"))
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(stylesheetText.contains(".account-form"))
        XCTAssertFalse(stylesheetText.contains("alice"))
        XCTAssertFalse(stylesheetText.contains(tokens.accessToken))
    }

    func testCurrentUserPasswordChangeRequiresExactBodyAndRevokesEverySession() throws {
        let login = try requestBody([
            "username": "alice",
            "password": "correct horse battery staple",
            "deviceName": "Web Browser",
            "platform": "Web",
            "delivery": "token"
        ])
        let tokens = try decodeTokens(router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: login
        ).body)
        let body = Data(#"{"currentPassword":"correct horse battery staple","newPassword":"new horse battery staple"}"#.utf8)
        let response = router.response(
            for: passwordChangeRequest(token: tokens.accessToken, bodyLength: body.count),
            body: body
        )
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""
        let oldLogin = router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: login
        )
        let newLogin = try requestBody([
            "username": "alice",
            "password": "new horse battery staple",
            "deviceName": "Web Browser",
            "platform": "Web",
            "delivery": "token"
        ])
        let unexpected = Data(#"{"currentPassword":"new horse battery staple","newPassword":"another secure password","userID":"other"}"#.utf8)

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertTrue(headers.contains("Max-Age=0"))
        XCTAssertNil(try authentication.principal(forAccessToken: tokens.accessToken))
        XCTAssertEqual(oldLogin.statusCode, 401)
        let newSession = router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: newLogin
        )
        let newTokens = try decodeTokens(newSession.body)
        XCTAssertEqual(newSession.statusCode, 200)
        XCTAssertEqual(router.response(
            for: passwordChangeRequest(token: newTokens.accessToken, bodyLength: unexpected.count),
            body: unexpected
        ).statusCode, 400)
        XCTAssertTrue(try repository.securityEvents(limit: 20).contains {
            $0.action == "credential.changed" && $0.actorUserID == "user-alice" && $0.detailCode == "sessions.revoked"
        })
    }

    private func requestBody(_ value: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func decodeTokens(_ data: Data) throws -> ServerIssuedTokens {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ServerIssuedTokens.self, from: data)
    }

    private func authenticatedRequest(_ path: String, token: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n"
    }

    private func passwordChangeRequest(token: String, bodyLength: Int) -> String {
        "POST /api/v1/auth/password HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(bodyLength)\r\nX-MediaLIB-CSRF: test-csrf-token\r\n\r\n"
    }

    private func cookieValue(named name: String, in headers: String) -> String? {
        headers.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("Set-Cookie: \(name)=") }?
            .dropFirst("Set-Cookie: \(name)=".count)
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
    }
}

private final class HTTPRouteTokenGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        return "token-\(index)-" + String(repeating: "x", count: 32)
    }
}
