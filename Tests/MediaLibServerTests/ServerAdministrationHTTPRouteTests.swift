import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerAdministrationHTTPRouteTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerIdentityRepository!
    private var catalog: ServerAdministrationCatalog!
    private var router: LocalHTTPRouter!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerAdministrationHTTPRouteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerIdentityRepository(database: database)
        catalog = ServerAdministrationCatalog(repository: repository)

        let user = try repository.createUser(
            id: "user-alice", username: "alice", displayName: "Alice <script>"
        )
        _ = try repository.setLibraryGrant(ServerLibraryGrant(
            userID: user.id,
            libraryID: "library-movies",
            canView: true,
            canPlay: true,
            canDownload: false
        ))
        let device = try repository.registerDevice(
            id: "device-alice", userID: user.id, name: "客厅浏览器", platform: "Web"
        )
        _ = try repository.createSession(
            id: "session-alice",
            userID: user.id,
            deviceID: device.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: Date().addingTimeInterval(900),
            refreshExpiresAt: Date().addingTimeInterval(86_400)
        )
        try repository.appendSecurityEvent(ServerSecurityEvent(
            category: .authorization,
            action: "test.denied",
            outcome: .denied,
            actorUserID: ServerIdentityRepository.initialAdministratorUserID,
            targetUserID: user.id,
            detailCode: "test"
        ))
        router = makeRouter()
    }

    override func tearDownWithError() throws {
        router = nil
        catalog = nil
        repository = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAdministrationRoutesApplyIndependentPermissionMatrix() throws {
        XCTAssertEqual(response(path: "/api/v1/admin/users", token: nil).statusCode, 401)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "member").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "member").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "member").statusCode, 403)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "server-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "server-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "server-manager").statusCode, 200)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "user-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "user-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "user-manager").statusCode, 403)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "session-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "session-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "session-manager").statusCode, 403)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "administrator").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "administrator").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "administrator").statusCode, 200)
    }

    func testAdministrationResponsesAreBoundedAndContainNoCredentialOrPathFields() throws {
        let usersResponse = response(path: "/api/v1/admin/users", token: "administrator")
        let sessionsResponse = response(path: "/api/v1/admin/sessions", token: "administrator")
        let eventsResponse = response(path: "/api/v1/admin/security-events", token: "administrator")
        let allText = [usersResponse, sessionsResponse, eventsResponse]
            .compactMap { String(data: $0.body, encoding: .utf8) }
            .joined(separator: "\n")
            .lowercased()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let users = try decoder.decode(ServerManagedUsersResponse.self, from: usersResponse.body)
        let sessions = try decoder.decode(ServerManagedSessionsResponse.self, from: sessionsResponse.body)
        let events = try decoder.decode(ServerSecurityEventsResponse.self, from: eventsResponse.body)

        XCTAssertEqual(users.users.first(where: { $0.id == "user-alice" })?.libraryGrantCount, 1)
        XCTAssertEqual(sessions.sessions.map(\.id), ["session-alice"])
        XCTAssertEqual(events.events.first?.action, "test.denied")
        for forbiddenField in [
            "correct horse battery staple", "password_hash", "credential", "accesstokendigest",
            "refreshtokendigest", String(repeating: "a", count: 64),
            String(repeating: "b", count: 64), "cookie", "user-agent", "/private/", "filepath", "sourcepath"
        ] {
            XCTAssertFalse(allText.contains(forbiddenField), "unexpected sensitive field: \(forbiddenField)")
        }
    }

    func testUsersCatalogHasHardResponseLimit() throws {
        for index in 0...ServerAdministrationCatalog.maximumUserCount {
            _ = try repository.createUser(
                id: "bulk-user-\(index)",
                username: "bulk-user-\(index)",
                displayName: "Bulk User \(index)"
            )
        }

        let response = try catalog.users()
        XCTAssertGreaterThan(response.totalCount, ServerAdministrationCatalog.maximumUserCount)
        XCTAssertEqual(response.users.count, ServerAdministrationCatalog.maximumUserCount)
        XCTAssertTrue(response.isTruncated)
    }

    func testAdministrationPageAndScriptKeepDynamicContentOutOfHTMLSinks() {
        let administratorPage = router.response(
            for: "GET /admin HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer administrator\r\n\r\n"
        )
        let deniedPage = router.response(
            for: "GET /admin HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer member\r\n\r\n"
        )
        let asset = router.response(for: "GET /assets/admin.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(data: administratorPage.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(administratorPage.statusCode, 200)
        XCTAssertEqual(deniedPage.statusCode, 403)
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("src=\"/assets/admin.js\""))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
    }

    func testAdministrationReadUsesApiRateLimitAndHeadOmitsBody() {
        var policies = ServerRequestRateLimiter.productionPolicies
        policies[.apiRead] = ServerRateLimitPolicy(capacity: 1, refillPerSecond: 0.001)
        let limitedRouter = makeRouter(rateLimiter: ServerRequestRateLimiter(
            policies: policies,
            salt: "administration-route-test"
        ))
        let first = limitedRouter.response(
            for: "GET /api/v1/admin/users HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer administrator\r\n\r\n"
        )
        let second = limitedRouter.response(
            for: "GET /api/v1/admin/users HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer administrator\r\n\r\n"
        )
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(second.statusCode, 429)

        let head = router.response(
            for: "HEAD /api/v1/admin/security-events HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer administrator\r\n\r\n"
        )
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertGreaterThan(head.declaredContentLength, 0)
    }

    private func makeRouter(
        rateLimiter: ServerRequestRateLimiter = ServerRequestRateLimiter()
    ) -> LocalHTTPRouter {
        LocalHTTPRouter(
            serverID: "server",
            serverName: "Media & <script>alert(1)</script>",
            administrationCatalog: catalog,
            authenticationProvider: { requestHead in
                guard let token = httpHeader(named: "Authorization", in: requestHead)?
                    .replacingOccurrences(of: "Bearer ", with: "") else { return nil }
                let permissions: Set<ServerPermission>
                switch token {
                case "administrator": permissions = [.manageServer, .manageUsers, .manageSessions, .viewMedia]
                case "server-manager": permissions = [.manageServer]
                case "user-manager": permissions = [.manageUsers]
                case "session-manager": permissions = [.manageSessions]
                case "member": permissions = [.viewMedia]
                default: return nil
                }
                return ServerRequestPrincipal(
                    userID: token,
                    deviceID: "device-\(token)",
                    sessionID: "session-\(token)",
                    permissions: permissions,
                    libraryGrants: [:]
                )
            },
            rateLimiter: rateLimiter
        )
    }

    private func response(path: String, token: String?) -> LocalHTTPResponse {
        let authorization = token.map { "Authorization: Bearer \($0)\r\n" } ?? ""
        return router.response(
            for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\(authorization)\r\n"
        )
    }
}
