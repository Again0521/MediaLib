import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

final class ServerAuthenticationServiceTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerIdentityRepository!
    private var hasher: ServerPasswordHasher!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerAuthenticationServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerIdentityRepository(database: database)
        hasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            parallelism: 1,
            randomBytes: { count in [UInt8](repeating: 7, count: count) }
        )
    }

    override func tearDownWithError() throws {
        hasher = nil
        repository = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testInitialAdministratorCannotLoginBeforePasswordSetup() throws {
        let service = try makeService()

        let result = try service.login(
            username: "admin",
            password: "unconfigured-password",
            deviceName: "Browser",
            platform: "Web"
        )

        XCTAssertEqual(result, .initialSetupRequired)
        XCTAssertEqual(try database.query("SELECT COUNT(*) FROM server_auth_sessions") { $0.int(0) ?? -1 }.first, 0)
    }

    func testInitialAdministratorCanLoginImmediatelyAfterAtomicDesktopSetup() throws {
        let generator = LockedTokenGenerator(tokens: [token("access"), token("refresh")])
        let service = try makeService(tokenGenerator: { generator.next() })
        try repository.setInitialCredential(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            argon2idEncodedHash: try hasher.hash(password: "correct horse battery staple")
        )

        let result = try service.login(
            username: "admin",
            password: "correct horse battery staple",
            deviceName: "Safari",
            platform: "Web"
        )

        guard case let .success(tokens) = result else {
            return XCTFail("Desktop initialization should make admin login available")
        }
        XCTAssertEqual(tokens.accessToken, token("access"))
        XCTAssertFalse(try XCTUnwrap(
            repository.user(id: ServerIdentityRepository.initialAdministratorUserID)
        ).requiresInitialPassword)
    }

    func testLoginReturnsRawTokensOnceButPersistsOnlyDigests() throws {
        let user = try configuredUser(username: "alice")
        let generator = LockedTokenGenerator(tokens: [token("access"), token("refresh")])
        let service = try makeService(tokenGenerator: { generator.next() })
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let result = try service.login(
            username: "ALICE",
            password: "correct horse battery staple",
            deviceName: "Alice Browser",
            platform: "Web",
            at: now
        )
        guard case let .success(tokens) = result else { return XCTFail("Expected successful login") }

        XCTAssertEqual(tokens.accessToken, token("access"))
        XCTAssertEqual(tokens.refreshToken, token("refresh"))
        let stored = try database.query(
            """
            SELECT access_token_digest, refresh_token_digest
            FROM server_auth_sessions WHERE user_id = ?
            """,
            bindings: [.text(user.id)]
        ) { ($0.string(0) ?? "", $0.string(1) ?? "") }.first
        XCTAssertEqual(stored?.0, ServerTokenSecurity.digest(tokens.accessToken))
        XCTAssertEqual(stored?.1, ServerTokenSecurity.digest(tokens.refreshToken))
        XCTAssertNotEqual(stored?.0, tokens.accessToken)
        XCTAssertNotEqual(stored?.1, tokens.refreshToken)
    }

    func testWrongPasswordLocksAccountAndCorrectPasswordWorksAfterLockExpires() throws {
        _ = try configuredUser(username: "alice")
        let generator = LockedTokenGenerator(tokens: [token("access"), token("refresh")])
        let service = try makeService(maximumFailedAttempts: 3, tokenGenerator: { generator.next() })
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for offset in 0..<2 {
            XCTAssertEqual(
                try service.login(
                    username: "alice", password: "wrong-password-value",
                    deviceName: "Browser", platform: "Web",
                    at: now.addingTimeInterval(Double(offset))
                ),
                .rejected
            )
        }
        let locked = try service.login(
            username: "alice", password: "wrong-password-value",
            deviceName: "Browser", platform: "Web",
            at: now.addingTimeInterval(2)
        )
        guard case let .temporarilyLocked(until) = locked else { return XCTFail("Expected lock") }
        XCTAssertEqual(
            try service.login(
                username: "alice", password: "correct horse battery staple",
                deviceName: "Browser", platform: "Web",
                at: now.addingTimeInterval(3)
            ),
            .temporarilyLocked(until: until)
        )

        let recovered = try service.login(
            username: "alice", password: "correct horse battery staple",
            deviceName: "Browser", platform: "Web",
            at: until.addingTimeInterval(1)
        )
        guard case .success = recovered else { return XCTFail("Expected login after lock expiry") }
    }

    func testConcurrentWrongPasswordsCannotLoseFailureIncrementsOrBypassLock() throws {
        let user = try configuredUser(username: "parallel-user")
        let service = try makeService(maximumFailedAttempts: 5)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let results = LockedLoginResults()

        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                results.append(try service.login(
                    username: "parallel-user",
                    password: "wrong-password-value",
                    deviceName: "Browser",
                    platform: "Web",
                    at: now
                ))
            } catch {
                results.record(error)
            }
        }

        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertEqual(
            try database.query(
                "SELECT failed_attempt_count FROM server_credentials WHERE user_id = ?",
                bindings: [.text(user.id)]
            ) { $0.int(0) ?? -1 }.first,
            5,
            "并发失败必须串行累加至阈值，不能由旧快照覆盖"
        )
        XCTAssertNotNil(try database.query(
            "SELECT locked_until FROM server_credentials WHERE user_id = ?",
            bindings: [.text(user.id)]
        ) { $0.date(0) }.first ?? nil)
        XCTAssertTrue(results.values.contains { result in
            if case .temporarilyLocked = result { return true }
            return false
        })
    }

    func testRefreshRotationIsSingleUseAndRevokesOldAccessSession() throws {
        _ = try configuredUser(username: "alice")
        let generator = LockedTokenGenerator(tokens: [
            token("access-one"), token("refresh-one"),
            token("access-two"), token("refresh-two"),
            token("access-three"), token("refresh-three")
        ])
        let service = try makeService(tokenGenerator: { generator.next() })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard case let .success(first) = try service.login(
            username: "alice", password: "correct horse battery staple",
            deviceName: "Browser", platform: "Web", at: now
        ) else { return XCTFail("Expected login") }

        let rotated = try XCTUnwrap(service.refresh(
            refreshToken: first.refreshToken,
            at: now.addingTimeInterval(10)
        ))

        XCTAssertNil(try service.principal(forAccessToken: first.accessToken, at: now.addingTimeInterval(11)))
        XCTAssertNotNil(try service.principal(forAccessToken: rotated.accessToken, at: now.addingTimeInterval(11)))
        XCTAssertNil(try service.refresh(refreshToken: first.refreshToken, at: now.addingTimeInterval(12)))
    }

    func testBearerAndCookieResolveSamePrincipalButAmbiguousRequestIsRejected() throws {
        let user = try configuredUser(username: "alice")
        _ = try repository.setLibraryGrant(ServerLibraryGrant(
            userID: user.id,
            libraryID: "library-films",
            canView: true,
            canPlay: true,
            canDownload: false
        ))
        let generator = LockedTokenGenerator(tokens: [token("access"), token("refresh")])
        let service = try makeService(tokenGenerator: { generator.next() })
        guard case let .success(tokens) = try service.login(
            username: "alice", password: "correct horse battery staple",
            deviceName: "Browser", platform: "Web"
        ) else { return XCTFail("Expected login") }

        let bearer = try service.principal(
            forRequestHead: "GET / HTTP/1.1\r\nAuthorization: Bearer \(tokens.accessToken)\r\n\r\n"
        )
        let cookie = try service.principal(
            forRequestHead: "GET / HTTP/1.1\r\nCookie: theme=dark; MediaLIBAccess=\(tokens.accessToken)\r\n\r\n"
        )
        let ambiguous = try service.principal(
            forRequestHead: "GET / HTTP/1.1\r\nAuthorization: Bearer \(tokens.accessToken)\r\nCookie: MediaLIBAccess=\(tokens.accessToken)\r\n\r\n"
        )

        XCTAssertEqual(bearer, cookie)
        XCTAssertNil(ambiguous)
        XCTAssertTrue(bearer?.allows(.playMedia, libraryID: "library-films") == true)
        XCTAssertFalse(bearer?.allows(.downloadMedia, libraryID: "library-films") == true)
        XCTAssertFalse(bearer?.allows(.viewMedia, libraryID: "library-music") == true)
    }

    func testAuthenticationAuditRecordsOutcomesWithoutCredentialsOrTokens() throws {
        let user = try configuredUser(username: "alice")
        let generator = LockedTokenGenerator(tokens: [token("access"), token("refresh")])
        let service = try makeService(tokenGenerator: { generator.next() })
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(try service.login(
            username: "unknown-user",
            password: "do not persist this password",
            deviceName: "Browser",
            platform: "Web",
            at: now
        ), .rejected)
        guard case let .success(tokens) = try service.login(
            username: "alice",
            password: "correct horse battery staple",
            deviceName: "Browser",
            platform: "Web",
            at: now.addingTimeInterval(1)
        ) else { return XCTFail("Expected login") }

        let events = try repository.securityEvents(limit: 10)
        XCTAssertEqual(events.first?.action, "login.succeeded")
        XCTAssertEqual(events.first?.targetUserID, user.id)
        XCTAssertTrue(events.contains {
            $0.action == "login.rejected" && $0.detailCode == "unknown.user" && $0.targetUserID == nil
        })
        let serializedAudit = try database.query(
            """
            SELECT COALESCE(action, '') || COALESCE(detail_code, '') ||
                   COALESCE(session_id, '') || COALESCE(device_id, '')
            FROM server_security_events
            """
        ) { $0.string(0) ?? "" }.joined(separator: "|")
        XCTAssertFalse(serializedAudit.contains("do not persist this password"))
        XCTAssertFalse(serializedAudit.contains(tokens.accessToken))
        XCTAssertFalse(serializedAudit.contains(tokens.refreshToken))
    }

    private func configuredUser(username: String) throws -> ServerUser {
        let user = try repository.createUser(
            id: "user-\(username)",
            username: username,
            displayName: username.capitalized
        )
        try repository.setCredential(
            userID: user.id,
            argon2idEncodedHash: try hasher.hash(password: "correct horse battery staple")
        )
        return user
    }

    private func makeService(
        maximumFailedAttempts: Int = 5,
        tokenGenerator: @escaping ServerAuthenticationService.TokenGenerator = { ServerTokenSecurity.generateToken() }
    ) throws -> ServerAuthenticationService {
        try ServerAuthenticationService(
            database: database,
            identityRepository: repository,
            passwordHasher: hasher,
            accessTokenLifetime: 900,
            refreshTokenLifetime: 86_400,
            maximumFailedAttempts: maximumFailedAttempts,
            lockDuration: 60,
            tokenGenerator: tokenGenerator
        )
    }

    private func token(_ label: String) -> String {
        label + String(repeating: "x", count: max(32 - label.count, 0))
    }
}

private final class LockedTokenGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(tokens: [String]) { self.tokens = tokens }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return tokens.isEmpty ? String(repeating: "z", count: 32) : tokens.removeFirst()
    }
}

private final class LockedLoginResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ServerLoginResult] = []
    private var storedErrors: [Error] = []

    func append(_ value: ServerLoginResult) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }

    var values: [ServerLoginResult] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }
}
