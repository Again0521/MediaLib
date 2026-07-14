import XCTest
@testable import MediaLibCore

final class ServerLocalCredentialRecoveryServiceTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerIdentityRepository!
    private var hasher: ServerPasswordHasher!
    private let adminID = ServerIdentityRepository.initialAdministratorUserID

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerLocalCredentialRecoveryServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerIdentityRepository(database: database)
        hasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 6, count: count) }
        )
        try repository.setInitialCredential(
            userID: adminID,
            argon2idEncodedHash: try hasher.hash(password: "forgotten administrator password")
        )
    }

    override func tearDownWithError() throws {
        hasher = nil
        repository = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testRecoveryReplacesCredentialRevokesEveryDeviceAndSessionAndAuditsLocalPresence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accessDigest = String(repeating: "a", count: 64)
        let device = try repository.registerDevice(
            id: "lost-browser", userID: adminID, name: "Lost Browser", platform: "Web", at: now
        )
        _ = try repository.createSession(
            id: "lost-session", userID: adminID, deviceID: device.id,
            accessTokenDigest: accessDigest,
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        try database.execute(
            "UPDATE server_credentials SET failed_attempt_count = 5, locked_until = ? WHERE user_id = ?",
            bindings: [.optionalDate(now.addingTimeInterval(900)), .text(adminID)]
        )
        let service = ServerLocalCredentialRecoveryService(database: database, passwordHasher: hasher)

        try service.recoverAdministratorPassword(
            newPassword: "recovered administrator password",
            at: now.addingTimeInterval(1)
        )

        let state = try XCTUnwrap(database.query(
            "SELECT password_hash, failed_attempt_count, locked_until FROM server_credentials WHERE user_id = ?",
            bindings: [.text(adminID)]
        ) { ($0.string(0) ?? "", $0.int(1) ?? -1, $0.date(2)) }.first)
        XCTAssertFalse(hasher.verify(password: "forgotten administrator password", encodedHash: state.0))
        XCTAssertTrue(hasher.verify(password: "recovered administrator password", encodedHash: state.0))
        XCTAssertEqual(state.1, 0)
        XCTAssertNil(state.2)
        XCTAssertNil(try repository.activeSession(accessTokenDigest: accessDigest, at: now.addingTimeInterval(2)))
        XCTAssertTrue(try repository.devices(userID: adminID).isEmpty)
        XCTAssertEqual(try repository.devices(userID: adminID, includeRevoked: true).count, 1)
        XCTAssertEqual(try repository.sessions(userID: adminID, includeRevoked: true).count, 1)

        let event = try XCTUnwrap(repository.securityEvents().first {
            $0.action == "credential.recovered"
        })
        XCTAssertEqual(event.action, "credential.recovered")
        XCTAssertEqual(event.outcome, .success)
        XCTAssertNil(event.actorUserID, "本机用户存在性验证不应伪装成已登录管理员 actor")
        XCTAssertEqual(event.targetUserID, adminID)
        XCTAssertEqual(event.detailCode, "local.user-presence")
        let serialized = [event.action, event.detailCode ?? "", event.targetUserID ?? ""].joined(separator: "|")
        XCTAssertFalse(serialized.contains("forgotten administrator password"))
        XCTAssertFalse(serialized.contains("recovered administrator password"))
        XCTAssertFalse(serialized.contains(accessDigest))
    }

    func testRecoveryRejectsPasswordReuseAndNonAdministratorWithoutChangingCredential() throws {
        let originalHash = try storedHash()
        let service = ServerLocalCredentialRecoveryService(database: database, passwordHasher: hasher)

        XCTAssertThrowsError(try service.recoverAdministratorPassword(
            newPassword: "forgotten administrator password"
        )) { error in
            XCTAssertEqual(error as? ServerLocalCredentialRecoveryError, .newPasswordMatchesCurrent)
        }
        XCTAssertThrowsError(try service.recoverAdministratorPassword(
            userID: "some-member",
            newPassword: "replacement administrator password"
        )) { error in
            XCTAssertEqual(error as? ServerLocalCredentialRecoveryError, .unsupportedUser)
        }

        XCTAssertEqual(try storedHash(), originalHash)
        let event = try XCTUnwrap(repository.securityEvents().first {
            $0.action == "credential.recovery.rejected" && $0.detailCode == "password.reused"
        })
        XCTAssertEqual(event.action, "credential.recovery.rejected")
        XCTAssertEqual(event.detailCode, "password.reused")
    }

    func testConcurrentRecoveriesFromSameCredentialAllowExactlyOneCommit() throws {
        let barrier = RecoveryTwoPartyBarrier()
        let concurrentHasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in
                barrier.arriveAndWait()
                return [UInt8](repeating: 8, count: count)
            }
        )
        let service = ServerLocalCredentialRecoveryService(database: database, passwordHasher: concurrentHasher)
        let results = LockedRecoveryResults()
        let group = DispatchGroup()
        let candidates = ["first recovered password", "second recovered password"]
        for password in candidates {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    try service.recoverAdministratorPassword(newPassword: password)
                    results.append(nil)
                } catch {
                    results.append(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let captured = results.values
        XCTAssertEqual(captured.filter { $0 == nil }.count, 1)
        XCTAssertEqual(
            captured.compactMap { $0 as? ServerLocalCredentialRecoveryError },
            [.credentialChangedConcurrently]
        )
        let finalHash = try storedHash()
        XCTAssertEqual(candidates.filter { concurrentHasher.verify(password: $0, encodedHash: finalHash) }.count, 1)
        XCTAssertEqual(try repository.securityEvents().filter { $0.action == "credential.recovered" }.count, 1)
        XCTAssertEqual(
            try repository.securityEvents().filter {
                $0.action == "credential.recovery.rejected" && $0.detailCode == "credential.changed"
            }.count,
            1
        )
    }

    private func storedHash() throws -> String {
        try XCTUnwrap(database.query(
            "SELECT password_hash FROM server_credentials WHERE user_id = ?",
            bindings: [.text(adminID)]
        ) { $0.string(0) }.first ?? nil)
    }
}

private final class RecoveryTwoPartyBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrivals = 0

    func arriveAndWait() {
        condition.lock()
        arrivals += 1
        if arrivals == 2 {
            condition.broadcast()
        } else {
            while arrivals < 2 { condition.wait() }
        }
        condition.unlock()
    }
}

private final class LockedRecoveryResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error?] = []

    var values: [Error?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Error?) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
