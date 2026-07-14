import XCTest
@testable import MediaLib
import MediaLibCore

@MainActor
final class ServerAdministrationStoreTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerIdentityRepository!
    private var hasher: ServerPasswordHasher!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerAdministrationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerIdentityRepository(database: database)
        hasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 9, count: count) }
        )
    }

    override func tearDownWithError() throws {
        hasher = nil
        repository = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testRefreshAndInitialPasswordSetupPublishOnlyAdministrationState() async throws {
        let store = ServerAdministrationStore(repository: repository, passwordHasher: hasher)

        await store.refresh()
        XCTAssertTrue(store.requiresInitialPassword)
        XCTAssertEqual(store.snapshot?.administrator.username, "admin")

        let didSetPassword = await store.setInitialAdministratorPassword("correct horse battery staple")
        XCTAssertTrue(didSetPassword)
        XCTAssertFalse(store.requiresInitialPassword)
        XCTAssertNil(store.errorMessage)

        let encodedHash = try XCTUnwrap(database.query(
            "SELECT password_hash FROM server_credentials WHERE user_id = ?",
            bindings: [.text(ServerIdentityRepository.initialAdministratorUserID)]
        ) { $0.string(0) }.first ?? nil)
        XCTAssertTrue(hasher.verify(password: "correct horse battery staple", encodedHash: encodedHash))
    }

    func testInitialSetupRejectsShortPasswordAndCannotOverwriteConfiguredPassword() async throws {
        let store = ServerAdministrationStore(repository: repository, passwordHasher: hasher)

        let shortPasswordAccepted = await store.setInitialAdministratorPassword("too-short")
        XCTAssertFalse(shortPasswordAccepted)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(try repository.user(id: ServerIdentityRepository.initialAdministratorUserID)?.requiresInitialPassword == true)

        let firstPasswordAccepted = await store.setInitialAdministratorPassword("first secure password")
        let secondPasswordAccepted = await store.setInitialAdministratorPassword("second secure password")
        XCTAssertTrue(firstPasswordAccepted)
        XCTAssertFalse(secondPasswordAccepted)
        XCTAssertEqual(store.errorMessage, "管理员密码已经设置；首次设置入口已关闭。")
    }

    func testSessionAndDeviceRevocationRefreshesSnapshot() async throws {
        let userID = ServerIdentityRepository.initialAdministratorUserID
        let now = Date()
        let device = try repository.registerDevice(
            id: "browser-device", userID: userID, name: "Safari", platform: "Web"
        )
        _ = try repository.createSession(
            id: "browser-session", userID: userID, deviceID: device.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        let store = ServerAdministrationStore(repository: repository, passwordHasher: hasher)

        await store.refresh()
        XCTAssertEqual(store.activeDeviceCount, 1)
        XCTAssertEqual(store.activeSessionCount, 1)

        await store.revokeSession(id: "browser-session")
        XCTAssertEqual(store.activeSessionCount, 0)
        XCTAssertEqual(store.activeDeviceCount, 1)

        await store.revokeDevice(id: "browser-device")
        XCTAssertEqual(store.activeDeviceCount, 0)
        XCTAssertNil(store.errorMessage)
    }

    func testCreateUpdateAndResetMemberPublishesLeastPrivilegeState() async throws {
        let store = ServerAdministrationStore(repository: repository, passwordHasher: hasher)
        let filmAccess = ServerLibraryAccessSelection(
            libraryID: "library-films", canView: true, canPlay: true, canDownload: false
        )

        let didCreate = await store.createUser(
            username: "alice",
            displayName: "Alice",
            password: "correct horse battery staple",
            roleID: ServerIdentityRepository.memberRoleID,
            access: [filmAccess]
        )
        XCTAssertTrue(didCreate)
        let alice = try XCTUnwrap(store.snapshot?.users.first { $0.user.username == "alice" })
        XCTAssertEqual(alice.roleID, ServerIdentityRepository.memberRoleID)
        XCTAssertEqual(alice.grants.map(\.libraryID), ["library-films"])

        let device = try repository.registerDevice(
            id: "alice-browser", userID: alice.id, name: "Browser", platform: "Web"
        )
        let now = Date()
        _ = try repository.createSession(
            id: "alice-session", userID: alice.id, deviceID: device.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )

        let didUpdate = await store.updateUser(
            id: alice.id,
            displayName: "Alice Updated",
            roleID: ServerIdentityRepository.memberRoleID,
            access: [ServerLibraryAccessSelection(
                libraryID: "library-music", canView: true, canPlay: false, canDownload: false
            )],
            disabled: false
        )
        XCTAssertTrue(didUpdate)
        let updated = try XCTUnwrap(store.snapshot?.users.first { $0.id == alice.id })
        XCTAssertEqual(updated.user.displayName, "Alice Updated")
        XCTAssertEqual(updated.grants.map(\.libraryID), ["library-music"])
        XCTAssertEqual(updated.activeSessionCount, 0, "权限变更必须让旧会话失效")

        let didReset = await store.resetPassword(
            userID: alice.id,
            password: "a newly rotated secure password"
        )
        XCTAssertTrue(didReset)
        let storedHash = try XCTUnwrap(database.query(
            "SELECT password_hash FROM server_credentials WHERE user_id = ?",
            bindings: [.text(alice.id)]
        ) { $0.string(0) }.first ?? nil)
        XCTAssertTrue(hasher.verify(password: "a newly rotated secure password", encodedHash: storedHash))
        XCTAssertEqual(store.snapshot?.securityEvents.first?.action, "credential.reset")
    }

    func testAdministratorPasswordChangeRequiresCurrentPasswordAndRefreshesRevokedSessions() async throws {
        let adminID = ServerIdentityRepository.initialAdministratorUserID
        try repository.setInitialCredential(
            userID: adminID,
            argon2idEncodedHash: try hasher.hash(password: "original administrator password")
        )
        let now = Date()
        let device = try repository.registerDevice(
            id: "admin-browser", userID: adminID, name: "Safari", platform: "Web", at: now
        )
        _ = try repository.createSession(
            id: "admin-session", userID: adminID, deviceID: device.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        let rotationService = ServerCredentialRotationService(database: database, passwordHasher: hasher)
        let store = ServerAdministrationStore(
            repository: repository,
            passwordHasher: hasher,
            credentialRotationService: rotationService
        )
        await store.refresh()

        let rejected = await store.changeAdministratorPassword(
            currentPassword: "incorrect administrator password",
            newPassword: "rotated administrator password"
        )
        XCTAssertFalse(rejected)
        XCTAssertEqual(store.errorMessage, "当前管理员密码不正确。")
        XCTAssertEqual(store.activeSessionCount, 1)

        let changed = await store.changeAdministratorPassword(
            currentPassword: "original administrator password",
            newPassword: "rotated administrator password"
        )
        XCTAssertTrue(changed)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.activeSessionCount, 0)
        XCTAssertEqual(store.snapshot?.securityEvents.first?.action, "credential.changed")
        let storedHash = try XCTUnwrap(database.query(
            "SELECT password_hash FROM server_credentials WHERE user_id = ?",
            bindings: [.text(adminID)]
        ) { $0.string(0) }.first ?? nil)
        XCTAssertTrue(hasher.verify(password: "rotated administrator password", encodedHash: storedHash))
    }

    func testLocalAdministratorRecoveryRequiresUserPresenceAndSuccessfulServiceStop() async throws {
        let adminID = ServerIdentityRepository.initialAdministratorUserID
        try repository.setInitialCredential(
            userID: adminID,
            argon2idEncodedHash: try hasher.hash(password: "forgotten administrator password")
        )
        let now = Date()
        let device = try repository.registerDevice(
            id: "admin-browser", userID: adminID, name: "Safari", platform: "Web", at: now
        )
        _ = try repository.createSession(
            id: "admin-session", userID: adminID, deviceID: device.id,
            accessTokenDigest: String(repeating: "a", count: 64),
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        let authorizer = MockServerLocalUserPresenceAuthorizer(result: false)
        let recoveryService = ServerLocalCredentialRecoveryService(database: database, passwordHasher: hasher)
        let store = ServerAdministrationStore(
            repository: repository,
            passwordHasher: hasher,
            credentialRecoveryService: recoveryService,
            localUserPresenceAuthorizer: authorizer
        )
        await store.refresh()
        var stopAttempts = 0

        let rejectedShortPassword = await store.recoverAdministratorPassword(
            newPassword: "too-short",
            prepareForRecovery: { stopAttempts += 1; return true }
        )
        XCTAssertFalse(rejectedShortPassword)
        XCTAssertEqual(authorizer.authorizationAttempts, 0)
        XCTAssertEqual(stopAttempts, 0, "无效新密码不应触发系统认证或停服")

        let rejectedPresence = await store.recoverAdministratorPassword(
            newPassword: "recovered administrator password",
            prepareForRecovery: { stopAttempts += 1; return true }
        )
        XCTAssertFalse(rejectedPresence)
        XCTAssertEqual(stopAttempts, 0, "系统身份验证失败时不应干扰正在运行的服务")
        XCTAssertEqual(store.activeSessionCount, 1)

        authorizer.result = true
        let rejectedStop = await store.recoverAdministratorPassword(
            newPassword: "recovered administrator password",
            prepareForRecovery: { stopAttempts += 1; return false }
        )
        XCTAssertFalse(rejectedStop)
        XCTAssertEqual(stopAttempts, 1)
        XCTAssertEqual(store.errorMessage, "服务进程未能安全停止，管理员密码没有改变。")
        XCTAssertEqual(store.activeSessionCount, 1)

        let recovered = await store.recoverAdministratorPassword(
            newPassword: "recovered administrator password",
            prepareForRecovery: { stopAttempts += 1; return true }
        )
        XCTAssertTrue(recovered)
        XCTAssertEqual(stopAttempts, 2)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.activeSessionCount, 0)
        XCTAssertEqual(store.activeDeviceCount, 0)
        XCTAssertEqual(store.snapshot?.securityEvents.first?.action, "credential.recovered")
        let storedHash = try XCTUnwrap(database.query(
            "SELECT password_hash FROM server_credentials WHERE user_id = ?",
            bindings: [.text(adminID)]
        ) { $0.string(0) }.first ?? nil)
        XCTAssertTrue(hasher.verify(password: "recovered administrator password", encodedHash: storedHash))
        XCTAssertEqual(authorizer.authorizationAttempts, 3)
    }
}

@MainActor
private final class MockServerLocalUserPresenceAuthorizer: ServerLocalUserPresenceAuthorizing {
    var result: Bool
    private(set) var authorizationAttempts = 0

    init(result: Bool) {
        self.result = result
    }

    func authorizeAdministratorRecovery() async throws -> Bool {
        authorizationAttempts += 1
        return result
    }
}
