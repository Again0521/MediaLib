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

    private func requestBody(_ value: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func decodeTokens(_ data: Data) throws -> ServerIssuedTokens {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ServerIssuedTokens.self, from: data)
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
