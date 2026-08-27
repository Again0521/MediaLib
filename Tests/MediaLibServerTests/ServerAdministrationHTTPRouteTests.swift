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

    func testAdministrationPagesAreSeparatedByPathAndPermission() {
        XCTAssertEqual(response(path: "/admin", token: "server-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/admin/users", token: "user-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/admin/sessions", token: "session-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/admin/libraries", token: "library-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/admin/playback", token: "server-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/admin/tasks", token: "library-manager").statusCode, 200)
        XCTAssertEqual(response(path: "/admin/network", token: "member").statusCode, 403)

        let legacyStatus = response(path: "/status", token: "server-manager")
        XCTAssertEqual(legacyStatus.statusCode, 303)
        XCTAssertTrue(legacyStatus.additionalHeaders.contains("Location: /admin"))
        XCTAssertEqual(response(path: "/status", token: "member").statusCode, 403)
    }

    func testPreferencesAPIUsesETagAndRejectsLostUpdates() throws {
        let initial = response(path: "/api/v1/me/preferences", token: "preferences")
        XCTAssertEqual(initial.statusCode, 200)
        XCTAssertTrue(initial.additionalHeaders.contains("ETag: \"0\""))
        let head = router.response(
            for: "HEAD /api/v1/me/preferences HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer preferences\r\n\r\n"
        )
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.declaredContentLength, initial.declaredContentLength)

        var preferences = ServerUserExperiencePreferences()
        preferences.preferredAudioLanguage = "zh-Hans"
        preferences.subtitleMode = .preferForced
        let body = try JSONEncoder().encode(preferences)
        let request = "PATCH /api/v1/me/preferences HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer preferences\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nIf-Match: \"0\"\r\nX-MediaLIB-CSRF: test-csrf-token\r\n\r\n"
        let saved = router.response(for: request, body: body)
        XCTAssertEqual(saved.statusCode, 200)
        XCTAssertTrue(saved.additionalHeaders.contains("ETag: \"1\""))

        let stale = router.response(for: request, body: body)
        XCTAssertEqual(stale.statusCode, 409)
        XCTAssertTrue(stale.additionalHeaders.contains("ETag: \"1\""))

        let missingPrecondition = request.replacingOccurrences(of: "If-Match: \"0\"\r\n", with: "")
        XCTAssertEqual(router.response(for: missingPrecondition, body: body).statusCode, 428)

        var unknownObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        unknownObject["administrator"] = true
        let unknownBody = try JSONSerialization.data(withJSONObject: unknownObject, options: [.sortedKeys])
        let unknownRequest = request
            .replacingOccurrences(of: "Content-Length: \(body.count)", with: "Content-Length: \(unknownBody.count)")
            .replacingOccurrences(of: "If-Match: \"0\"", with: "If-Match: \"1\"")
        XCTAssertEqual(router.response(for: unknownRequest, body: unknownBody).statusCode, 400)

        var nestedUnknown = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var subtitleStyle = try XCTUnwrap(nestedUnknown["subtitleStyle"] as? [String: Any])
        subtitleStyle["unsafeCSS"] = "url(https://example.invalid)"
        nestedUnknown["subtitleStyle"] = subtitleStyle
        let nestedBody = try JSONSerialization.data(withJSONObject: nestedUnknown, options: [.sortedKeys])
        let nestedRequest = request
            .replacingOccurrences(of: "Content-Length: \(body.count)", with: "Content-Length: \(nestedBody.count)")
            .replacingOccurrences(of: "If-Match: \"0\"", with: "If-Match: \"1\"")
        XCTAssertEqual(router.response(for: nestedRequest, body: nestedBody).statusCode, 400)
    }

    func testUserPolicyRequiresUserManagementUsesETagAndWritesAudit() throws {
        let path = "/api/v1/admin/users/user-bob/policy"
        XCTAssertEqual(response(path: path, token: "member").statusCode, 403)
        let initial = response(path: path, token: "user-manager")
        XCTAssertEqual(initial.statusCode, 200)
        XCTAssertTrue(initial.additionalHeaders.contains("ETag: \"0\""))
        XCTAssertTrue(String(decoding: initial.body, as: UTF8.self).contains("\"directPlayAllowed\":true"))

        var policy = ServerUserPolicy()
        policy.directPlayAllowed = false
        policy.maximumConcurrentStreams = 1
        policy.remoteBitrateLimitMbps = 12
        let body = try JSONEncoder().encode(policy)
        let request = "PATCH \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer user-manager\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nIf-Match: \"0\"\r\nX-MediaLIB-CSRF: test-csrf-token\r\n\r\n"
        let saved = router.response(for: request, body: body)
        XCTAssertEqual(saved.statusCode, 200)
        XCTAssertTrue(saved.additionalHeaders.contains("ETag: \"1\""))
        XCTAssertEqual(router.response(for: request, body: body).statusCode, 409)
        XCTAssertTrue(try repository.sessions(userID: "user-bob").isEmpty)

        let unknown = Data(#"{"schemaVersion":1,"playbackAllowed":true,"remoteAccessAllowed":true,"directPlayAllowed":false,"remuxAllowed":true,"transcodeAllowed":true,"downloadAllowed":false,"maximumConcurrentStreams":1,"remoteBitrateLimitMbps":12,"accessStartMinute":null,"accessEndMinute":null,"maximumContentRating":null,"roleID":"server-role-admin"}"#.utf8)
        let unknownRequest = request
            .replacingOccurrences(of: "Content-Length: \(body.count)", with: "Content-Length: \(unknown.count)")
            .replacingOccurrences(of: "If-Match: \"0\"", with: "If-Match: \"1\"")
        XCTAssertEqual(router.response(for: unknownRequest, body: unknown).statusCode, 400)
        XCTAssertEqual(response(path: "/api/v1/admin/users/no-such-user/policy", token: "user-manager").statusCode, 404)
        XCTAssertTrue(try repository.securityEvents(limit: 20).contains {
            $0.action == "user.policy.updated" && $0.targetUserID == "user-bob" &&
                $0.actorUserID == "user-alice"
        })
    }

    func testBackupMaintenanceIsPermissionedAsynchronousOpaqueAndAudited() async throws {
        XCTAssertEqual(response(path: "/api/v1/admin/backups", token: "member").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/logs", token: "member").statusCode, 403)

        let creation = router.response(
            for: mutationRequest("/api/v1/admin/backups", token: "server-manager", bodyLength: 0)
        )
        XCTAssertEqual(creation.statusCode, 201)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(ServerJob.self, from: creation.body)
        XCTAssertEqual(job.kind, "database.backup")
        XCTAssertEqual(job.state, .queued)

        let experience = ServerExperienceRepository(database: database)
        var completed: ServerJob?
        for _ in 0..<100 {
            completed = try experience.jobs(limit: 20).first(where: { $0.id == job.id })
            if completed?.state == .succeeded || completed?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(completed?.state, .succeeded)
        XCTAssertEqual(completed?.resultCode, "backup.created")

        let listing = response(path: "/api/v1/admin/backups", token: "server-manager")
        XCTAssertEqual(listing.statusCode, 200)
        let backups = try decoder.decode([ServerBackupSummary].self, from: listing.body)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(backup.id.count, 32)
        XCTAssertGreaterThan(backup.byteLength, 0)
        let serialized = String(decoding: listing.body, as: UTF8.self)
        XCTAssertFalse(serialized.contains(directory.path))
        XCTAssertFalse(serialized.contains(".sqlite"))

        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
        XCTAssertEqual(files.count, 1)
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: backupDirectory.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)

        let download = response(
            path: "/api/v1/admin/backups/\(backup.id)/download",
            token: "server-manager"
        )
        XCTAssertEqual(download.statusCode, 200)
        XCTAssertEqual(Int64(download.declaredContentLength), backup.byteLength)
        XCTAssertTrue(try repository.securityEvents(limit: 20).contains {
            $0.action == "backup.created" && $0.actorUserID == "user-alice"
        })

        let logs = response(path: "/api/v1/admin/logs", token: "server-manager")
        XCTAssertEqual(logs.statusCode, 200)
        XCTAssertFalse(String(decoding: logs.body, as: UTF8.self).contains(directory.path))
    }

    func testLibraryMaintenanceJobExecutesAndRejectsDecorativeUnsupportedKinds() async throws {
        let sourceRepository = SourceRepository(database: database)
        let existingSources = try sourceRepository.fetchAll()
        for source in existingSources {
            try sourceRepository.delete(id: source.id)
        }
        defer {
            for source in existingSources {
                try? sourceRepository.save(source)
            }
        }

        let body = Data(#"{"kind":"library.scan"}"#.utf8)
        let denied = router.response(
            for: mutationRequest("/api/v1/admin/jobs", token: "member", bodyLength: body.count),
            body: body
        )
        XCTAssertEqual(denied.statusCode, 403)

        let creation = router.response(
            for: mutationRequest("/api/v1/admin/jobs", token: "library-manager", bodyLength: body.count),
            body: body
        )
        XCTAssertEqual(creation.statusCode, 201)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(ServerJob.self, from: creation.body)
        let experience = ServerExperienceRepository(database: database)
        var completed: ServerJob?
        for _ in 0..<100 {
            completed = try experience.jobs(limit: 20).first(where: { $0.id == job.id })
            if completed?.state == .succeeded || completed?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(completed?.state, .succeeded)
        XCTAssertEqual(completed?.resultCode, "scan.no-eligible-sources")
        XCTAssertTrue(try repository.securityEvents(limit: 20).contains {
            $0.action == "maintenance.completed" && $0.detailCode == "library.scan"
        })

        let unsupported = Data(#"{"kind":"metadata.refresh"}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/admin/jobs", token: "library-manager", bodyLength: unsupported.count),
            body: unsupported
        ).statusCode, 400)
    }

    /// 局域网就绪度属于服务管理面，未认证与非管理员都拿不到部署形态。
    func testLanReadinessRouteRequiresServerManagementAndLeaksNoDeploymentDetail() throws {
        XCTAssertEqual(response(path: "/api/v1/admin/lan-readiness", token: nil).statusCode, 401)
        XCTAssertEqual(response(path: "/api/v1/admin/lan-readiness", token: "member").statusCode, 403)
        XCTAssertEqual(response(path: "/api/v1/admin/lan-readiness", token: "session-manager").statusCode, 403)

        let granted = response(path: "/api/v1/admin/lan-readiness", token: "server-manager")
        XCTAssertEqual(granted.statusCode, 200)
        let json = try XCTUnwrap(String(data: granted.body, encoding: .utf8))
        // 默认部署仍是纯回环：未就绪，且直连被配置层挡在门外。
        XCTAssertTrue(json.contains("\"isReadyForLanAccess\":false"))
        XCTAssertTrue(json.contains("\"lanDirectPlayBlockedBy\":\"lanDirectPlayDisabled\""))
        XCTAssertTrue(json.contains("\"supportedUpstreamsIssueScopedTickets\":false"))
        XCTAssertFalse(json.contains("127.0.0.1"))
        XCTAssertFalse(json.contains("8098"))
    }

    /// 播放遥测同样属于服务管理面，且只能是聚合数据。
    func testPlaybackTelemetryRouteRequiresServerManagementAndStaysAggregate() throws {
        XCTAssertEqual(response(path: "/api/v1/admin/playback-telemetry", token: nil).statusCode, 401)
        XCTAssertEqual(response(path: "/api/v1/admin/playback-telemetry", token: "member").statusCode, 403)
        XCTAssertEqual(
            response(path: "/api/v1/admin/playback-telemetry", token: "session-manager").statusCode, 403
        )

        let granted = response(path: "/api/v1/admin/playback-telemetry", token: "server-manager")
        XCTAssertEqual(granted.statusCode, 200)
        let json = try XCTUnwrap(String(data: granted.body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"rangeSizeBuckets\""))
        XCTAssertTrue(json.contains("\"peakConcurrentBufferedBytes\""))
        for forbidden in ["browser-fixture", "/private/", "api_key", "Bearer", "session-", "user-"] {
            XCTAssertFalse(json.contains(forbidden), "播放遥测不得出现 \(forbidden)")
        }
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

        let firstPageResponse = self.response(
            path: "/api/v1/admin/users?offset=0&limit=100", token: "administrator"
        )
        let secondPageResponse = self.response(
            path: "/api/v1/admin/users?offset=100&limit=100", token: "administrator"
        )
        let firstPage = try JSONDecoder().decode(ServerManagedUsersResponse.self, from: firstPageResponse.body)
        let secondPage = try JSONDecoder().decode(ServerManagedUsersResponse.self, from: secondPageResponse.body)
        XCTAssertEqual(firstPage.users.count, 100)
        XCTAssertEqual(secondPage.users.count, 100)
        XCTAssertTrue(Set(firstPage.users.map(\.id)).isDisjoint(with: secondPage.users.map(\.id)))
        XCTAssertEqual(firstPage.totalCount, secondPage.totalCount)
        XCTAssertEqual(self.response(
            path: "/api/v1/admin/users?limit=100&sort=password", token: "administrator"
        ).statusCode, 400)
    }

    func testAdministrationPageAndScriptKeepDynamicContentOutOfHTMLSinks() {
        let administratorPage = router.response(
            for: "GET /admin/users HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer administrator\r\n\r\n"
        )
        let deniedPage = router.response(
            for: "GET /admin/users HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer member\r\n\r\n"
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
        XCTAssertTrue(html.contains("src=\"/assets/admin.js?v="))
        XCTAssertTrue(html.contains("href=\"/assets/admin.css?v="))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(html.contains("id=\"create-member\""))
        XCTAssertTrue(html.contains("id=\"policy-direct\""))
        XCTAssertTrue(html.contains("id=\"policy-streams\""))
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
        XCTAssertTrue(script.contains("/policy`"))
        XCTAssertTrue(script.contains("method: 'PATCH'"))
        XCTAssertTrue(script.contains("'If-Match': editingPolicyETag"))
        XCTAssertTrue(script.contains("edit-member"))
        XCTAssertTrue(script.contains("editLibraryID"))
        XCTAssertTrue(script.contains("JSON.stringify({ username, displayName, password, libraryIDs })"))
        XCTAssertTrue(script.contains("passwordField.value = ''"))
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(stylesheetHeaders.contains("Cache-Control: no-store"))
        XCTAssertTrue(style.contains(".admin-form"))
        XCTAssertTrue(style.contains(".library-options"))
        XCTAssertTrue(style.contains(".admin-policy-grid"))
        XCTAssertFalse(style.contains("administrator"))
        XCTAssertFalse(style.contains("test-csrf-token"))
    }

    func testLibrariesPageUsesLibraryPermissionAndLegacyPathIsAuthorizedRedirect() {
        let page = router.response(
            for: "GET /admin/libraries HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer library-manager\r\n\r\n"
        )
        let denied = router.response(
            for: "GET /sources HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer member\r\n\r\n"
        )
        let legacy = router.response(
            for: "GET /sources HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer library-manager\r\n\r\n"
        )
        let asset = router.response(for: "GET /assets/sources.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let stylesheet = router.response(for: "GET /assets/sources.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let html = String(data: page.body, encoding: .utf8) ?? ""
        let script = String(data: asset.body, encoding: .utf8) ?? ""
        let stylesheetHeaders = String(data: stylesheet.serializedHeaders(), encoding: .utf8) ?? ""
        let style = String(data: stylesheet.body, encoding: .utf8) ?? ""

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertEqual(legacy.statusCode, 303)
        XCTAssertTrue(legacy.additionalHeaders.contains("Location: /admin/libraries"))
        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(html.contains("src=\"/assets/sources.js?v="))
        XCTAssertTrue(html.contains("href=\"/assets/sources.css?v="))
        XCTAssertFalse(html.contains("<style>"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertEqual(stylesheet.statusCode, 200)
        XCTAssertTrue(stylesheetHeaders.contains("Cache-Control: private, max-age=31536000, immutable"))
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

    /// 保险库可以被授权，也就可以被撤销。
    ///
    /// 这三处（可授权列表、创建用户、修改授权）此前一律把 `privateCollection`
    /// 过滤掉，于是保险库是一个**管理不了**的资源：界面上画不出那一行，接口也
    /// 拒绝那个 id。它的保护从来不来自"不出现在列表里"——网页侧要同时满足逐库
    /// 授权与"这台 Mac 上的 App 正解锁着"，缺一不可。
    func testVaultLibraryCanBeListedAndGrantedLikeAnyOtherSource() throws {
        try SourceRepository(database: database).save(MediaSource(
            id: "source-vault", name: "保险库", path: "/private/Media/Vault",
            mediaType: .privateCollection
        ))
        router = makeRouter()

        let libraries = response(path: "/api/v1/admin/libraries", token: "administrator")
        XCTAssertEqual(libraries.statusCode, 200)
        let listed = String(data: libraries.body, encoding: .utf8) ?? ""
        XCTAssertTrue(listed.contains("source-vault"), "保险库必须出现在可授权资料库里")

        let request = Data(#"{"username":"vault-member","displayName":"Vault Member","password":"a long unique password","libraryIDs":["source-vault"]}"#.utf8)
        let created = router.response(
            for: mutationRequest("/api/v1/admin/users", token: "administrator", bodyLength: request.count),
            body: request
        )
        XCTAssertEqual(created.statusCode, 204)

        let user = try XCTUnwrap(try repository.users().first(where: { $0.username == "vault-member" }))
        let grants = try repository.libraryGrants(userID: user.id)
        XCTAssertEqual(grants.map(\.libraryID), ["source-vault"])
        XCTAssertTrue(grants.first?.canView ?? false)
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
            experienceRepository: ServerExperienceRepository(database: database),
            maintenanceService: ServerMaintenanceService(
                database: database,
                backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
            ),
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
                case "preferences": permissions = [.viewMedia]
                case "member": permissions = [.viewMedia]
                default: return nil
                }
                return ServerRequestPrincipal(
                    userID: token == "preferences" ? "user-alice" : (token == "administrator"
                        ? ServerIdentityRepository.initialAdministratorUserID
                        : (["server-manager", "session-manager", "user-manager", "library-manager"].contains(token) ? "user-alice" : token)),
                    deviceID: token == "preferences" ? "device-alice" : "device-\(token)",
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
