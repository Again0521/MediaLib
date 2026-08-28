import XCTest
@testable import MediaLibCore

final class ServerIdentityRepositoryTests: XCTestCase {
    private var workDirectory: URL!
    private var database: DatabaseManager!
    private var repository: ServerIdentityRepository!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerIdentityRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: workDirectory.appendingPathComponent("library.sqlite"))
        repository = ServerIdentityRepository(database: database)
    }

    override func tearDownWithError() throws {
        repository = nil
        database = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    func testInitialAdministratorRequiresPasswordAndHasAdministrativePermissions() throws {
        let user = try XCTUnwrap(repository.user(id: ServerIdentityRepository.initialAdministratorUserID))

        XCTAssertTrue(user.requiresInitialPassword)
        XCTAssertFalse(try repository.hasCredential(userID: user.id))
        XCTAssertTrue(try repository.permissions(userID: user.id).contains(.manageServer))
    }

    func testCredentialBoundaryAcceptsOnlyArgon2idEncodedHash() throws {
        let user = try makeUser(username: "alice")

        XCTAssertThrowsError(
            try repository.setCredential(userID: user.id, argon2idEncodedHash: "plain-password")
        ) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .invalidPasswordHash)
        }

        let encodedHash = "$argon2id$v=19$m=65536,t=3,p=1$c2FsdC12YWx1ZQ$aGFzaC12YWx1ZS1mb3ItdGVzdA"
        try repository.setCredential(userID: user.id, argon2idEncodedHash: encodedHash)

        XCTAssertTrue(try repository.hasCredential(userID: user.id))
        XCTAssertFalse(try XCTUnwrap(repository.user(id: user.id)).requiresInitialPassword)
        let stored = try database.query(
            "SELECT password_algorithm, password_hash FROM server_credentials WHERE user_id = ?",
            bindings: [.text(user.id)]
        ) { ($0.string(0) ?? "", $0.string(1) ?? "") }.first
        XCTAssertEqual(stored?.0, "argon2id")
        XCTAssertEqual(stored?.1, encodedHash)
    }

    func testInitialCredentialCanOnlyBeSetOnceAndDoesNotOverwriteExistingHash() throws {
        let userID = ServerIdentityRepository.initialAdministratorUserID
        let first = "$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$Zmlyc3Q"
        let second = "$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$c2Vjb25k"

        try repository.setInitialCredential(userID: userID, argon2idEncodedHash: first)
        XCTAssertThrowsError(
            try repository.setInitialCredential(userID: userID, argon2idEncodedHash: second)
        ) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .initialCredentialAlreadySet)
        }

        XCTAssertEqual(
            try database.query(
                "SELECT password_hash FROM server_credentials WHERE user_id = ?",
                bindings: [.text(userID)]
            ) { $0.string(0) }.first ?? nil,
            first
        )
    }

    func testLibraryGrantsRemainIsolatedPerUser() throws {
        let alice = try makeUser(username: "alice")
        let bob = try makeUser(username: "bob")
        _ = try repository.setLibraryGrant(ServerLibraryGrant(
            userID: alice.id,
            libraryID: "library-films",
            canView: true,
            canPlay: true,
            canDownload: false
        ))
        _ = try repository.setLibraryGrant(ServerLibraryGrant(
            userID: bob.id,
            libraryID: "library-music",
            canView: true,
            canPlay: true,
            canDownload: true
        ))

        XCTAssertEqual(try repository.libraryGrants(userID: alice.id).map(\.libraryID), ["library-films"])
        XCTAssertEqual(try repository.libraryGrants(userID: bob.id).map(\.libraryID), ["library-music"])
    }

    func testIncoherentLibraryGrantIsRejectedBeforeSQLite() throws {
        let user = try makeUser(username: "alice")
        let grant = ServerLibraryGrant(
            userID: user.id,
            libraryID: "library-films",
            canView: false,
            canPlay: true,
            canDownload: false
        )

        XCTAssertThrowsError(try repository.setLibraryGrant(grant))
        XCTAssertTrue(try repository.libraryGrants(userID: user.id).isEmpty)
    }

    func testSessionStoresOnlyDigestsAndDeviceRevocationInvalidatesIt() throws {
        let user = try makeUser(username: "alice")
        let device = try repository.registerDevice(
            id: "device-alice-mac",
            userID: user.id,
            name: "Alice Mac",
            platform: "macOS"
        )
        let accessDigest = String(repeating: "a", count: 64)
        let refreshDigest = String(repeating: "b", count: 64)
        let now = Date()
        let session = try repository.createSession(
            id: "session-alice-mac",
            userID: user.id,
            deviceID: device.id,
            accessTokenDigest: accessDigest,
            refreshTokenDigest: refreshDigest,
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400),
            createdAt: now
        )

        XCTAssertEqual(try repository.activeSession(accessTokenDigest: accessDigest, at: now)?.id, session.id)
        let stored = try database.query(
            "SELECT access_token_digest, refresh_token_digest FROM server_auth_sessions WHERE id = ?",
            bindings: [.text(session.id)]
        ) { ($0.string(0) ?? "", $0.string(1) ?? "") }.first
        XCTAssertEqual(stored?.0, accessDigest)
        XCTAssertEqual(stored?.1, refreshDigest)

        try repository.revokeDevice(id: device.id, at: now.addingTimeInterval(1))

        XCTAssertNil(try repository.activeSession(accessTokenDigest: accessDigest, at: now.addingTimeInterval(2)))
        XCTAssertNotNil(try repository.device(id: device.id)?.revokedAt)
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) FROM server_auth_sessions WHERE device_id = ? AND revoked_at IS NOT NULL",
                bindings: [.text(device.id)]
            ) { $0.int(0) ?? 0 }.first,
            1
        )
    }

    func testDeviceAndActiveSessionQueriesSupportAdministrationAndRevocation() throws {
        let user = try makeUser(username: "session-owner")
        let firstDevice = try repository.registerDevice(
            id: "device-one", userID: user.id, name: "Safari", platform: "Web"
        )
        let secondDevice = try repository.registerDevice(
            id: "device-two", userID: user.id, name: "Mac", platform: "macOS"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try repository.createSession(
            id: "session-one", userID: user.id, deviceID: firstDevice.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        _ = try repository.createSession(
            id: "session-two", userID: user.id, deviceID: secondDevice.id,
            accessTokenDigest: String(repeating: "c", count: 64),
            refreshTokenDigest: String(repeating: "d", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )

        XCTAssertEqual(try repository.devices(userID: user.id).count, 2)
        XCTAssertEqual(try repository.sessions(userID: user.id, at: now).count, 2)

        try repository.revokeDevice(id: firstDevice.id, at: now.addingTimeInterval(1))
        XCTAssertEqual(try repository.devices(userID: user.id).map(\.id), [secondDevice.id])
        XCTAssertEqual(
            try repository.sessions(userID: user.id, at: now.addingTimeInterval(2)).map(\.id),
            ["session-two"]
        )

        try repository.revokeAllSessions(userID: user.id, at: now.addingTimeInterval(3))
        XCTAssertTrue(try repository.sessions(userID: user.id, at: now.addingTimeInterval(4)).isEmpty)
        XCTAssertEqual(try repository.sessions(userID: user.id, includeRevoked: true).count, 2)
    }

    func testManagedSessionsFiltersAndPaginatesBeforeStableMapping() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixtures = [
            ("alice", "Safari", "Web", "a", "b", 30.0),
            ("bob", "Living Room", "tvOS", "c", "d", 20.0),
            ("carol", "Tablet", "iOS", "e", "f", 10.0)
        ]
        for fixture in fixtures {
            let user = try makeUser(username: fixture.0)
            let createdAt = now.addingTimeInterval(fixture.5)
            let device = try repository.registerDevice(
                id: "device-\(fixture.0)", userID: user.id,
                name: fixture.1, platform: fixture.2, at: createdAt
            )
            _ = try repository.createSession(
                id: "session-\(fixture.0)", userID: user.id, deviceID: device.id,
                accessTokenDigest: String(repeating: fixture.3, count: 64),
                refreshTokenDigest: String(repeating: fixture.4, count: 64),
                accessExpiresAt: createdAt.addingTimeInterval(900),
                refreshExpiresAt: createdAt.addingTimeInterval(86_400),
                createdAt: createdAt
            )
        }

        let first = try repository.managedSessions(limit: 2, at: now)
        let second = try repository.managedSessions(limit: 2, offset: 2, at: now)
        XCTAssertEqual(first.totalCount, 3)
        XCTAssertEqual(first.sessions.map(\.session.id), ["session-alice", "session-bob"])
        XCTAssertEqual(second.sessions.map(\.session.id), ["session-carol"])
        XCTAssertEqual(first.sessions.first?.device.name, "Safari")
        XCTAssertEqual(first.sessions.first?.displayName, "Alice")

        let filtered = try repository.managedSessions(limit: 10, searchText: "living", at: now)
        XCTAssertEqual(filtered.totalCount, 1)
        XCTAssertEqual(filtered.sessions.first?.session.id, "session-bob")
        XCTAssertEqual(try repository.managedSessions(limit: 10, searchText: "BOB", at: now).totalCount, 1)
        XCTAssertEqual(try repository.managedSessions(limit: 10, searchText: "%", at: now).totalCount, 0)
    }

    func testRawTokenAndInvalidExpiryAreRejectedWithoutPersistence() throws {
        let user = try makeUser(username: "alice")
        let device = try repository.registerDevice(userID: user.id, name: "Browser", platform: "Web")
        let now = Date()

        XCTAssertThrowsError(try repository.createSession(
            userID: user.id,
            deviceID: device.id,
            accessTokenDigest: "raw-access-token",
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(60),
            refreshExpiresAt: now.addingTimeInterval(120),
            createdAt: now
        )) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .invalidTokenDigest)
        }
        XCTAssertThrowsError(try repository.createSession(
            userID: user.id,
            deviceID: device.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(120),
            refreshExpiresAt: now.addingTimeInterval(60),
            createdAt: now
        )) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .invalidExpiration)
        }
        XCTAssertEqual(
            try database.query("SELECT COUNT(*) FROM server_auth_sessions") { $0.int(0) ?? -1 }.first,
            0
        )
    }

    func testDisablingUserRevokesAllSessionsAndSuppressesRolePermissions() throws {
        let user = try makeUser(username: "alice")
        let device = try repository.registerDevice(userID: user.id, name: "Browser", platform: "Web")
        let now = Date()
        let accessDigest = String(repeating: "c", count: 64)
        _ = try repository.createSession(
            userID: user.id,
            deviceID: device.id,
            accessTokenDigest: accessDigest,
            refreshTokenDigest: String(repeating: "d", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400),
            createdAt: now
        )

        try repository.setUserDisabled(id: user.id, disabled: true, at: now.addingTimeInterval(1))

        XCTAssertNil(try repository.activeSession(accessTokenDigest: accessDigest, at: now.addingTimeInterval(2)))
        XCTAssertTrue(try repository.permissions(userID: user.id).isEmpty)
        XCTAssertTrue(try XCTUnwrap(repository.user(id: user.id)).isDisabled)
    }

    func testConfiguredUserCreationIsAtomicAndRejectsDuplicateUsername() throws {
        let hash = "$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$aGFzaA"
        let actorID = ServerIdentityRepository.initialAdministratorUserID
        let userID = "configured-alice"
        let grant = ServerLibraryGrant(
            userID: userID,
            libraryID: "library-films",
            canView: true,
            canPlay: true,
            canDownload: false
        )

        let user = try repository.createConfiguredUser(
            id: userID,
            username: "alice",
            displayName: "Alice",
            argon2idEncodedHash: hash,
            libraryGrants: [grant],
            actorUserID: actorID
        )

        XCTAssertEqual(user.id, userID)
        XCTAssertTrue(try repository.hasCredential(userID: userID))
        let storedGrant = try XCTUnwrap(repository.libraryGrants(userID: userID).first)
        XCTAssertEqual(storedGrant.libraryID, grant.libraryID)
        XCTAssertTrue(storedGrant.canView)
        XCTAssertTrue(storedGrant.canPlay)
        XCTAssertFalse(storedGrant.canDownload)
        XCTAssertThrowsError(try repository.createConfiguredUser(
            id: "duplicate-alice",
            username: "ALICE",
            displayName: "Duplicate",
            argon2idEncodedHash: hash,
            libraryGrants: [],
            actorUserID: actorID
        )) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .usernameAlreadyExists)
        }
        XCTAssertNil(try repository.user(id: "duplicate-alice"))

        let invalidUserID = "invalid-grants-user"
        let duplicateGrant = ServerLibraryGrant(
            userID: invalidUserID,
            libraryID: "library-films",
            canView: true,
            canPlay: true,
            canDownload: false
        )
        XCTAssertThrowsError(try repository.createConfiguredUser(
            id: invalidUserID,
            username: "rollback-user",
            displayName: "Rollback",
            argon2idEncodedHash: hash,
            libraryGrants: [duplicateGrant, duplicateGrant],
            actorUserID: actorID
        ))
        XCTAssertNil(try repository.user(id: invalidUserID), "事务失败不能留下半配置用户")
    }

    func testManagedAccessUpdateReplacesRoleAndGrantsAndRevokesSessions() throws {
        let user = try makeUser(username: "alice")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let device = try repository.registerDevice(
            id: "alice-browser", userID: user.id, name: "Browser", platform: "Web", at: now
        )
        _ = try repository.createSession(
            id: "alice-session", userID: user.id, deviceID: device.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        let replacement = ServerLibraryGrant(
            userID: user.id, libraryID: "library-music",
            canView: true, canPlay: true, canDownload: true
        )

        try repository.updateManagedUser(
            userID: user.id,
            displayName: "Alice Updated",
            roleID: ServerIdentityRepository.administratorRoleID,
            libraryGrants: [replacement],
            disabled: false,
            actorUserID: ServerIdentityRepository.initialAdministratorUserID,
            at: now.addingTimeInterval(1)
        )

        XCTAssertEqual(try repository.roleIDs(userID: user.id), [ServerIdentityRepository.administratorRoleID])
        XCTAssertEqual(try repository.libraryGrants(userID: user.id).map(\.libraryID), ["library-music"])
        XCTAssertTrue(try repository.sessions(userID: user.id, at: now.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(try repository.user(id: user.id)?.displayName, "Alice Updated")
        XCTAssertEqual(try repository.securityEvents().first?.action, "user.access.updated")
    }

    func testInitialAdministratorCannotBeDisabledDemotedOrResetThroughManagedFlow() throws {
        let adminID = ServerIdentityRepository.initialAdministratorUserID
        XCTAssertThrowsError(try repository.setUserDisabled(id: adminID, disabled: true)) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .cannotModifyInitialAdministrator)
        }
        XCTAssertThrowsError(try repository.replaceRole(
            userID: adminID,
            roleID: ServerIdentityRepository.memberRoleID
        )) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .cannotModifyInitialAdministrator)
        }
        XCTAssertThrowsError(try repository.resetCredential(
            userID: adminID,
            argon2idEncodedHash: "$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$aGFzaA",
            actorUserID: adminID
        )) { error in
            XCTAssertEqual(error as? ServerIdentityRepositoryError, .cannotModifyInitialAdministrator)
        }
    }

    func testSecurityAuditIsStructuredBoundedAndContainsNoSecretFields() throws {
        for index in 0..<5 {
            try repository.appendSecurityEvent(
                ServerSecurityEvent(
                    id: "event-\(index)",
                    occurredAt: Date(timeIntervalSince1970: Double(index)),
                    category: .authentication,
                    action: "login.rejected",
                    outcome: .denied,
                    detailCode: "password.mismatch"
                ),
                maximumRetained: 3
            )
        }

        let events = try repository.securityEvents(limit: 10)
        XCTAssertEqual(events.map(\.id), ["event-4", "event-3", "event-2"])
        let columns = Set(try database.query("PRAGMA table_info(server_security_events)") {
            $0.string(1) ?? ""
        })
        XCTAssertTrue(columns.isDisjoint(with: [
            "password", "password_hash", "access_token", "refresh_token", "request_headers",
            "remote_ip", "file_path", "media_title"
        ]))
    }

    func testSecurityAuditRetentionPrunesRowsOlderThanConfiguredCutoff() throws {
        try repository.appendSecurityEvent(ServerSecurityEvent(
            id: "expired", occurredAt: Date(timeIntervalSince1970: 100),
            category: .authentication, action: "login.rejected", outcome: .denied
        ))
        try repository.appendSecurityEvent(ServerSecurityEvent(
            id: "retained", occurredAt: Date(timeIntervalSince1970: 300),
            category: .authentication, action: "login.succeeded", outcome: .success
        ))

        try repository.pruneSecurityEvents(before: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try repository.securityEvents(limit: 10).map(\.id), ["retained"])
    }

    func testManagedSecurityAuditFiltersCountsAndPagesWithStableOrdering() throws {
        let occurredAt = Date(timeIntervalSince1970: 500)
        let events: [ServerSecurityEvent] = [
            .init(id: "event-a", occurredAt: occurredAt, category: .authentication,
                  action: "login.succeeded", outcome: .success),
            .init(id: "event-b", occurredAt: occurredAt, category: .authorization,
                  action: "stream.denied", outcome: .denied,
                  detailCode: "policy.remote-user-bob"),
            .init(id: "event-c", occurredAt: occurredAt, category: .authorization,
                  action: "download.denied", outcome: .denied,
                  detailCode: "policy.download")
        ]
        for event in events { try repository.appendSecurityEvent(event) }

        let first = try repository.managedSecurityEvents(
            limit: 1, category: .authorization, outcome: .denied, searchText: "policy"
        )
        let second = try repository.managedSecurityEvents(
            limit: 1, offset: 1, category: .authorization, outcome: .denied, searchText: "policy"
        )

        XCTAssertEqual(first.totalCount, 2)
        XCTAssertEqual(first.events.map(\.id), ["event-c"])
        XCTAssertEqual(second.totalCount, 2)
        XCTAssertEqual(second.events.map(\.id), ["event-b"])
        XCTAssertTrue(try repository.managedSecurityEvents(limit: 10, searchText: "user_bob").events.isEmpty)
        XCTAssertEqual(
            try repository.managedSecurityEvents(limit: 10, searchText: "user-bob").events.map(\.id),
            ["event-b"]
        )
    }

    private func makeUser(username: String) throws -> ServerUser {
        try repository.createUser(
            id: "user-\(username)",
            username: username,
            displayName: username.capitalized
        )
    }
}
