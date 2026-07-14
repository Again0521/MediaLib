import XCTest
@testable import MediaLibCore

final class ServerCredentialRotationServiceTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerIdentityRepository!
    private var hasher: ServerPasswordHasher!
    private let adminID = ServerIdentityRepository.initialAdministratorUserID

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCredentialRotationServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerIdentityRepository(database: database)
        hasher = try testHasher()
        try repository.setInitialCredential(
            userID: adminID,
            argon2idEncodedHash: try hasher.hash(password: "original administrator password")
        )
    }

    override func tearDownWithError() throws {
        hasher = nil
        repository = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSuccessfulRotationRevokesSessionsResetsLockAndAuditsWithoutSecrets() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accessDigest = String(repeating: "a", count: 64)
        let device = try repository.registerDevice(
            id: "admin-browser", userID: adminID, name: "Safari", platform: "Web", at: now
        )
        _ = try repository.createSession(
            id: "admin-session", userID: adminID, deviceID: device.id,
            accessTokenDigest: accessDigest,
            refreshTokenDigest: String(repeating: "b", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        try database.execute(
            "UPDATE server_credentials SET failed_attempt_count = 4, locked_until = ? WHERE user_id = ?",
            bindings: [.optionalDate(now.addingTimeInterval(600)), .text(adminID)]
        )
        let service = ServerCredentialRotationService(database: database, passwordHasher: hasher)

        try service.changePassword(
            userID: adminID,
            currentPassword: "original administrator password",
            newPassword: "rotated administrator password",
            at: now.addingTimeInterval(1)
        )

        let state = try XCTUnwrap(database.query(
            "SELECT password_hash, failed_attempt_count, locked_until FROM server_credentials WHERE user_id = ?",
            bindings: [.text(adminID)]
        ) { ($0.string(0) ?? "", $0.int(1) ?? -1, $0.date(2)) }.first)
        XCTAssertFalse(hasher.verify(password: "original administrator password", encodedHash: state.0))
        XCTAssertTrue(hasher.verify(password: "rotated administrator password", encodedHash: state.0))
        XCTAssertEqual(state.1, 0)
        XCTAssertNil(state.2)
        XCTAssertNil(try repository.activeSession(accessTokenDigest: accessDigest, at: now.addingTimeInterval(2)))
        XCTAssertEqual(try repository.sessions(userID: adminID, includeRevoked: true).count, 1)

        let event = try XCTUnwrap(repository.securityEvents().first)
        XCTAssertEqual(event.action, "credential.changed")
        XCTAssertEqual(event.outcome, .success)
        let serialized = [event.action, event.detailCode ?? "", event.actorUserID ?? ""].joined(separator: "|")
        XCTAssertFalse(serialized.contains("original administrator password"))
        XCTAssertFalse(serialized.contains("rotated administrator password"))
        XCTAssertFalse(serialized.contains(accessDigest))
    }

    func testWrongCurrentPasswordAndReuseLeaveCredentialAndSessionsIntact() throws {
        let originalHash = try storedHash()
        let now = Date()
        let device = try repository.registerDevice(userID: adminID, name: "Browser", platform: "Web", at: now)
        _ = try repository.createSession(
            userID: adminID, deviceID: device.id,
            accessTokenDigest: String(repeating: "c", count: 64),
            refreshTokenDigest: String(repeating: "d", count: 64),
            accessExpiresAt: now.addingTimeInterval(900),
            refreshExpiresAt: now.addingTimeInterval(86_400), createdAt: now
        )
        let service = ServerCredentialRotationService(database: database, passwordHasher: hasher)

        XCTAssertThrowsError(try service.changePassword(
            userID: adminID,
            currentPassword: "incorrect administrator password",
            newPassword: "replacement administrator password"
        )) { error in
            XCTAssertEqual(error as? ServerCredentialRotationError, .currentPasswordIncorrect)
        }
        XCTAssertThrowsError(try service.changePassword(
            userID: adminID,
            currentPassword: "original administrator password",
            newPassword: "original administrator password"
        )) { error in
            XCTAssertEqual(error as? ServerCredentialRotationError, .newPasswordMatchesCurrent)
        }

        XCTAssertEqual(try storedHash(), originalHash)
        XCTAssertEqual(try repository.sessions(userID: adminID, at: now).count, 1)
        let rejected = try repository.securityEvents().filter { $0.action == "credential.change.rejected" }
        XCTAssertEqual(Set(rejected.compactMap(\.detailCode)), ["current.mismatch", "password.reused"])
    }

    func testConcurrentRotationsUsingSameOriginalCredentialAllowExactlyOneCommit() throws {
        let barrier = TwoPartyBarrier()
        let concurrentHasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in
                barrier.arriveAndWait()
                return [UInt8](repeating: 7, count: count)
            }
        )
        let service = ServerCredentialRotationService(database: database, passwordHasher: concurrentHasher)
        let results = LockedRotationResults()
        let group = DispatchGroup()
        for password in ["first concurrent replacement", "second concurrent replacement"] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    try service.changePassword(
                        userID: self.adminID,
                        currentPassword: "original administrator password",
                        newPassword: password
                    )
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
            captured.compactMap { $0 as? ServerCredentialRotationError },
            [.credentialChangedConcurrently]
        )
        let finalHash = try storedHash()
        let winners = ["first concurrent replacement", "second concurrent replacement"].filter {
            concurrentHasher.verify(password: $0, encodedHash: finalHash)
        }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(try repository.securityEvents().filter { $0.action == "credential.changed" }.count, 1)
        XCTAssertEqual(
            try repository.securityEvents().filter {
                $0.action == "credential.change.rejected" && $0.detailCode == "credential.changed"
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

    private func testHasher() throws -> ServerPasswordHasher {
        try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 5, count: count) }
        )
    }
}

private final class TwoPartyBarrier: @unchecked Sendable {
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

private final class LockedRotationResults: @unchecked Sendable {
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
