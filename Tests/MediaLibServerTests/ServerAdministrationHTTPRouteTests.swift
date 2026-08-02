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
        catalog = ServerAdministrationCatalog(database: database)

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
        let managedUser = try repository.createUser(
            id: "user-bob", username: "bob", displayName: "Bob"
        )
        let managedDevice = try repository.registerDevice(
            id: "device-bob", userID: managedUser.id, name: "卧室浏览器", platform: "Web"
        )
        _ = try repository.createSession(
            id: "session-bob",
            userID: managedUser.id,
            deviceID: managedDevice.id,
            accessTokenDigest: String(repeating: "c", count: 64),
            refreshTokenDigest: String(repeating: "d", count: 64),
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
        try SourceRepository(database: database).save(MediaSource(
            id: "source-private",
            name: "家庭电影 <script>",
            path: "/private/Media/Movies",
            mediaType: .movie,
            autoScan: true,
            includeInMetadataFetch: true,
            includeInHealthCheck: true
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
        XCTAssertEqual(response(path: "/api/v1/admin/sources", token: "server-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/libraries", token: "server-manager").statusCode, 403)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "user-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/libraries", token: "user-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "user-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "user-manager").statusCode, 403)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "session-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "session-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "session-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/sources", token: "session-manager").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/libraries", token: "library-manager").statusCode, 200)

        XCTAssertEqual(response(path: "/api/v1/admin/users", token: "administrator").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/sessions", token: "administrator").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/security-events", token: "administrator").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/sources", token: "administrator").statusCode, 200)
        XCTAssertEqual(response(path: "/api/v1/admin/libraries", token: "administrator").statusCode, 200)
    }

    func testAdministrationResponsesAreBoundedAndContainNoCredentialOrPathFields() throws {
        let usersResponse = response(path: "/api/v1/admin/users", token: "administrator")
        let sessionsResponse = response(path: "/api/v1/admin/sessions", token: "administrator")
        let eventsResponse = response(path: "/api/v1/admin/security-events", token: "administrator")
        let sourcesResponse = response(path: "/api/v1/admin/sources", token: "administrator")
        let allText = [usersResponse, sessionsResponse, eventsResponse, sourcesResponse]
            .compactMap { String(data: $0.body, encoding: .utf8) }
            .joined(separator: "\n")
            .lowercased()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let users = try decoder.decode(ServerManagedUsersResponse.self, from: usersResponse.body)
        let sessions = try decoder.decode(ServerManagedSessionsResponse.self, from: sessionsResponse.body)
        let events = try decoder.decode(ServerSecurityEventsResponse.self, from: eventsResponse.body)
        let sources = try decoder.decode(ServerManagedSourcesResponse.self, from: sourcesResponse.body)

        XCTAssertEqual(users.users.first(where: { $0.id == "user-alice" })?.libraryGrantCount, 1)
        XCTAssertTrue(sessions.sessions.map(\.id).contains("session-alice"))
        XCTAssertTrue(sessions.sessions.map(\.id).contains("session-bob"))
        XCTAssertEqual(events.events.first?.action, "test.denied")
        XCTAssertEqual(sources.sources.first?.sourceKind, "local")
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
        let stylesheet = router.response(for: "GET /assets/admin.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(data: administratorPage.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""
        let stylesheetHeaders = String(data: stylesheet.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: stylesheet.body, encoding: .utf8) ?? ""

        XCTAssertEqual(administratorPage.statusCode, 200)
        XCTAssertEqual(deniedPage.statusCode, 403)
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("src=\"/assets/admin.js\""))
        XCTAssertTrue(html.contains("href=\"/assets/admin.css\""))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(html.contains("id=\"create-member\""))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertTrue(script.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(script.contains("encodeURIComponent"))
        XCTAssertTrue(script.contains("/api/v1/admin/libraries"))
        XCTAssertTrue(script.contains("/api/v1/admin/users"))
        XCTAssertTrue(script.contains("/access`"))
        XCTAssertTrue(script.contains("/password`"))
        XCTAssertTrue(script.contains("edit-member"))
        XCTAssertTrue(script.contains("editLibraryID"))
        XCTAssertTrue(script.contains("JSON.stringify({ username, displayName, password, libraryIDs })"))
        XCTAssertTrue(script.contains("passwordField.value = ''"))
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".create-form"))
        XCTAssertTrue(style.contains(".library-options"))
        XCTAssertFalse(style.contains("administrator"))
        XCTAssertFalse(style.contains("test-csrf-token"))
    }

    func testSourcesPageIsServerManagerOnlyAndUsesSafeExternalScript() {
        let page = router.response(
            for: "GET /sources HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer server-manager\r\n\r\n"
        )
        let denied = router.response(
            for: "GET /sources HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer member\r\n\r\n"
        )
        let asset = router.response(for: "GET /assets/sources.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let stylesheet = router.response(for: "GET /assets/sources.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""
        let stylesheetHeaders = String(data: stylesheet.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: stylesheet.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(html.contains("src=\"/assets/sources.js\""))
        XCTAssertTrue(html.contains("href=\"/assets/sources.css\""))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=300"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".rows"))
        XCTAssertFalse(style.contains("server-manager"))
        XCTAssertFalse(style.contains("credential"))
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

    func testSessionRevocationRequiresSessionManagementPermissionAndWritesNoSensitiveResponse() throws {
        let denied = router.response(
            for: "POST /api/v1/admin/sessions/session-alice/revoke HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer member\r\n\r\n"
        )
        let success = router.response(
            for: "POST /api/v1/admin/sessions/session-alice/revoke HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer session-manager\r\n\r\n"
        )
        let malformed = router.response(
            for: "POST /api/v1/admin/sessions/session-alice/revoke/extra HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer session-manager\r\n\r\n"
        )

        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertEqual(success.statusCode, 204)
        XCTAssertTrue(success.body.isEmpty)
        XCTAssertEqual(malformed.statusCode, 404)
        XCTAssertTrue(try repository.sessions(userID: "user-alice").isEmpty)
        let events = try repository.securityEvents(limit: 10)
        XCTAssertTrue(events.contains { $0.action == "session.revoked" && $0.actorUserID == "user-alice" })
    }

    func testUserAvailabilityRequiresUserManagementRevokesSessionsAndAudits() throws {
        let denied = router.response(
            for: "POST /api/v1/admin/users/user-bob/disable HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer member\r\n\r\n"
        )
        let disabled = router.response(
            for: "POST /api/v1/admin/users/user-bob/disable HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer user-manager\r\n\r\n"
        )
        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertEqual(disabled.statusCode, 204)
        XCTAssertTrue(disabled.body.isEmpty)
        XCTAssertTrue(try XCTUnwrap(repository.user(id: "user-bob")).isDisabled)
        XCTAssertTrue(try repository.sessions(userID: "user-bob").isEmpty)
        let enabled = router.response(
            for: "POST /api/v1/admin/users/user-bob/enable HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer user-manager\r\n\r\n"
        )
        XCTAssertEqual(enabled.statusCode, 204)
        XCTAssertFalse(try XCTUnwrap(repository.user(id: "user-bob")).isDisabled)
        let protected = router.response(
            for: "POST /api/v1/admin/users/server-user-local-admin/disable HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer user-manager\r\n\r\n"
        )
        XCTAssertEqual(protected.statusCode, 404)
        let events = try repository.securityEvents(limit: 10)
        XCTAssertTrue(events.contains { $0.action == "user.disabled" && $0.targetUserID == "user-bob" })
        XCTAssertTrue(events.contains { $0.action == "user.enabled" && $0.targetUserID == "user-bob" })
    }

    func testMemberCreationRequiresExplicitLibraryPermissionAndUsesStrictBody() throws {
        let request = Data(#"{"username":"new-member","displayName":"New Member","password":"a long unique password","libraryIDs":["source-private"]}"#.utf8)
        let denied = router.response(
            for: mutationRequest("/api/v1/admin/users", token: "user-manager", bodyLength: request.count),
            body: request
        )
        let success = router.response(
            for: mutationRequest("/api/v1/admin/users", token: "administrator", bodyLength: request.count),
            body: request
        )
        let created = try XCTUnwrap(try repository.users().first(where: { $0.username == "new-member" }))
        let grants = try repository.libraryGrants(userID: created.id)
        let extraField = Data(#"{"username":"other","displayName":"Other","password":"a long unique password","libraryIDs":[],"roleID":"server-role-admin"}"#.utf8)

        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertEqual(success.statusCode, 204)
        XCTAssertFalse(created.isDisabled)
        XCTAssertFalse(created.requiresInitialPassword)
        XCTAssertEqual(try repository.roleIDs(userID: created.id), [ServerIdentityRepository.memberRoleID])
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants.first?.libraryID, "source-private")
        XCTAssertTrue(grants.first?.canView ?? false)
        XCTAssertTrue(grants.first?.canPlay ?? false)
        XCTAssertFalse(grants.first?.canDownload ?? true)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/admin/users", token: "administrator", bodyLength: extraField.count),
            body: extraField
        ).statusCode, 400)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/admin/users", token: "administrator", bodyLength: request.count),
            body: request
        ).statusCode, 400)
        XCTAssertTrue(try repository.securityEvents(limit: 20).contains {
            $0.action == "user.created" &&
                $0.actorUserID == ServerIdentityRepository.initialAdministratorUserID && $0.targetUserID == created.id
        })
    }

    func testMemberAccessEditRequiresLibraryPermissionRevokesSessionsAndUsesStrictBody() throws {
        let request = Data(#"{"displayName":"Bob Updated","libraryIDs":["source-private"]}"#.utf8)
        let denied = router.response(
            for: mutationRequest("/api/v1/admin/users/user-bob/access", token: "user-manager", bodyLength: request.count),
            body: request
        )
        let success = router.response(
            for: mutationRequest("/api/v1/admin/users/user-bob/access", token: "administrator", bodyLength: request.count),
            body: request
        )
        let updated = try XCTUnwrap(repository.user(id: "user-bob"))
        let grants = try repository.libraryGrants(userID: updated.id)
        let extraField = Data(#"{"displayName":"Bob","libraryIDs":[],"roleID":"administrator"}"#.utf8)
        let protected = router.response(
            for: mutationRequest("/api/v1/admin/users/server-user-local-admin/access", token: "administrator", bodyLength: request.count),
            body: request
        )

        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertEqual(success.statusCode, 204)
        XCTAssertEqual(updated.displayName, "Bob Updated")
        XCTAssertEqual(grants.map(\.libraryID), ["source-private"])
        XCTAssertTrue(grants.allSatisfy { $0.canView && $0.canPlay && !$0.canDownload && !$0.canEditMetadata && !$0.canDeleteItems })
        XCTAssertTrue(try repository.sessions(userID: "user-bob").isEmpty)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/admin/users/user-bob/access", token: "administrator", bodyLength: extraField.count),
            body: extraField
        ).statusCode, 400)
        XCTAssertEqual(protected.statusCode, 400)
        XCTAssertTrue(try repository.securityEvents(limit: 20).contains {
            $0.action == "user.access.updated" && $0.targetUserID == "user-bob"
        })
    }

    func testMemberPasswordResetRequiresUserPermissionRevokesSessionsAndUsesStrictBody() throws {
        let request = Data(#"{"password":"a freshly rotated password"}"#.utf8)
        let denied = router.response(
            for: mutationRequest("/api/v1/admin/users/user-bob/password", token: "member", bodyLength: request.count),
            body: request
        )
        let success = router.response(
            for: mutationRequest("/api/v1/admin/users/user-bob/password", token: "user-manager", bodyLength: request.count),
            body: request
        )
        let extraField = Data(#"{"password":"a freshly rotated password","roleID":"administrator"}"#.utf8)
        let protected = router.response(
            for: mutationRequest("/api/v1/admin/users/server-user-local-admin/password", token: "administrator", bodyLength: request.count),
            body: request
        )

        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertEqual(success.statusCode, 204)
        XCTAssertTrue(try repository.hasCredential(userID: "user-bob"))
        XCTAssertTrue(try repository.sessions(userID: "user-bob").isEmpty)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/admin/users/user-bob/password", token: "user-manager", bodyLength: extraField.count),
            body: extraField
        ).statusCode, 400)
        XCTAssertEqual(protected.statusCode, 400)
        XCTAssertTrue(try repository.securityEvents(limit: 20).contains {
            $0.action == "credential.reset" && $0.targetUserID == "user-bob"
        })
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
                case "administrator": permissions = [.manageServer, .manageUsers, .manageLibraries, .manageSessions, .viewMedia]
                case "server-manager": permissions = [.manageServer]
                case "user-manager": permissions = [.manageUsers]
                case "library-manager": permissions = [.manageLibraries]
                case "session-manager": permissions = [.manageSessions]
                case "member": permissions = [.viewMedia]
                default: return nil
                }
                return ServerRequestPrincipal(
                    userID: token == "administrator"
                        ? ServerIdentityRepository.initialAdministratorUserID
                        : (["session-manager", "user-manager", "library-manager"].contains(token) ? "user-alice" : token),
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

    private func mutationRequest(_ path: String, token: String, bodyLength: Int) -> String {
        "POST \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(bodyLength)\r\nX-MediaLIB-CSRF: test-csrf-token\r\n\r\n"
    }
}
