import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class PrivacyLockServiceTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var defaultSuiteNames: [String] = []

    override func tearDownWithError() throws {
        for suiteName in defaultSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaultSuiteNames.removeAll()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testPINValidationRequiresFourToEightNumericCharacters() {
        XCTAssertTrue(PrivacyLockService.isValidPIN("1234"))
        XCTAssertTrue(PrivacyLockService.isValidPIN("12345678"))

        XCTAssertFalse(PrivacyLockService.isValidPIN(""))
        XCTAssertFalse(PrivacyLockService.isValidPIN("123"))
        XCTAssertFalse(PrivacyLockService.isValidPIN("123456789"))
        XCTAssertFalse(PrivacyLockService.isValidPIN("12 34"))
        XCTAssertFalse(PrivacyLockService.isValidPIN("12a4"))
        XCTAssertFalse(PrivacyLockService.isValidPIN("1234\n"))
    }

    func testAsyncSetHasVerifyAndRemoveRoundTripsPINWithStrictPermissions() async throws {
        let directory = try makeTemporaryDirectory()
        let service = PrivacyLockService(directory: directory)
        let fileURL = directory.appendingPathComponent("privacy-pin.json")

        let initiallyHasPIN = await service.hasPINAsync()
        XCTAssertFalse(initiallyHasPIN)
        XCTAssertFalse(service.hasPIN())

        try await service.setPINAsync("123456")

        let hasPINAfterSet = await service.hasPINAsync()
        let asyncVerifiesCorrectPIN = await service.verifyAsync(pin: "123456")
        let asyncRejectsWrongPIN = await service.verifyAsync(pin: "654321")
        let asyncRejectsInvalidPIN = await service.verifyAsync(pin: "123")
        XCTAssertTrue(hasPINAfterSet)
        XCTAssertTrue(service.hasPIN())
        XCTAssertTrue(asyncVerifiesCorrectPIN)
        XCTAssertTrue(service.verify(pin: "123456"))
        XCTAssertFalse(asyncRejectsWrongPIN)
        XCTAssertFalse(asyncRejectsInvalidPIN)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let stored = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(stored.contains("123456"))

        await service.removePINAsync()

        let hasPINAfterRemove = await service.hasPINAsync()
        XCTAssertFalse(hasPINAfterRemove)
        XCTAssertFalse(service.verify(pin: "123456"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSyncAndAsyncAPIsShareTheSameStoredCredential() async throws {
        let directory = try makeTemporaryDirectory()
        let service = PrivacyLockService(directory: directory)

        try service.setPIN("2468")

        let asyncHasSyncPIN = await service.hasPINAsync()
        let asyncVerifiesSyncPIN = await service.verifyAsync(pin: "2468")
        XCTAssertTrue(asyncHasSyncPIN)
        XCTAssertTrue(asyncVerifiesSyncPIN)

        try await service.setPINAsync("13579")

        XCTAssertTrue(service.hasPIN())
        XCTAssertTrue(service.verify(pin: "13579"))
        XCTAssertFalse(service.verify(pin: "2468"))

        service.removePIN()

        let asyncHasPINAfterSyncRemove = await service.hasPINAsync()
        let asyncVerifiesRemovedPIN = await service.verifyAsync(pin: "13579")
        XCTAssertFalse(asyncHasPINAfterSyncRemove)
        XCTAssertFalse(asyncVerifiesRemovedPIN)
    }

    func testAsyncSetRejectsInvalidPINAndLeavesNoCredentialFile() async throws {
        let directory = try makeTemporaryDirectory()
        let service = PrivacyLockService(directory: directory)
        let fileURL = directory.appendingPathComponent("privacy-pin.json")

        do {
            try await service.setPINAsync("12a4")
            XCTFail("Expected invalid PIN to throw")
        } catch PrivacyLockError.invalidPIN {
            let hasPIN = await service.hasPINAsync()
            XCTAssertFalse(hasPIN)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCorruptedCredentialFileIsTreatedAsMissingAndCanBeOverwritten() async throws {
        let directory = try makeTemporaryDirectory()
        let service = PrivacyLockService(directory: directory)
        let fileURL = directory.appendingPathComponent("privacy-pin.json")
        try Data("{\"salt\":".utf8).write(to: fileURL)

        let hasCorruptedPIN = await service.hasPINAsync()
        let verifiesCorruptedPIN = await service.verifyAsync(pin: "1234")
        XCTAssertFalse(hasCorruptedPIN)
        XCTAssertFalse(verifiesCorruptedPIN)

        try await service.setPINAsync("9876")

        let hasOverwrittenPIN = await service.hasPINAsync()
        let verifiesOverwrittenPIN = await service.verifyAsync(pin: "9876")
        let rejectsOldPIN = await service.verifyAsync(pin: "1234")
        XCTAssertTrue(hasOverwrittenPIN)
        XCTAssertTrue(verifiesOverwrittenPIN)
        XCTAssertFalse(rejectsOldPIN)
    }

    func testAsyncRemovePINIsIdempotent() async throws {
        let directory = try makeTemporaryDirectory()
        let service = PrivacyLockService(directory: directory)
        let fileURL = directory.appendingPathComponent("privacy-pin.json")

        await service.removePINAsync()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try await service.setPINAsync("112233")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await service.removePINAsync()
        await service.removePINAsync()

        let hasPINAfterRepeatedRemove = await service.hasPINAsync()
        XCTAssertFalse(hasPINAfterRepeatedRemove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSyncAndAsyncRemovePINReportFailureWhenCredentialCannotBeDeleted() async throws {
        struct TestRemoveError: Error {}

        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("privacy-pin.json")
        let service = PrivacyLockService(
            directory: directory,
            io: PrivacyLockService.IO(
                fileURL: { directoryOverride in
                    (directoryOverride ?? directory).appendingPathComponent("privacy-pin.json")
                },
                write: { data, url in
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: url, options: .atomic)
                },
                read: { url in
                    try Data(contentsOf: url)
                },
                remove: { _ in
                    throw TestRemoveError()
                }
            )
        )

        try service.setPIN("998877")

        let syncRemoved = service.removePIN()
        let asyncRemoved = await service.removePINAsync()

        XCTAssertFalse(syncRemoved)
        XCTAssertFalse(asyncRemoved)
        XCTAssertTrue(service.hasPIN())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testConcurrentAsyncSetPINOperationsLeaveReadableCredential() async throws {
        let directory = try makeTemporaryDirectory()
        let service = PrivacyLockService(directory: directory)
        let candidatePINs = (0..<30).map { String(format: "%04d", $0) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for pin in candidatePINs {
                group.addTask {
                    try await service.setPINAsync(pin)
                }
            }
            try await group.waitForAll()
        }

        let hasPINAfterConcurrentWrites = await service.hasPINAsync()
        XCTAssertTrue(hasPINAfterConcurrentWrites)
        let readablePINs = await readablePINs(candidatePINs, using: service)
        XCTAssertEqual(readablePINs.count, 1)

        let fileURL = directory.appendingPathComponent("privacy-pin.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAsyncPINFlowPersistsPrivacySettingsAndCredentialStateTogether() async throws {
        let directory = try makeTemporaryDirectory()
        let pinDirectory = directory.appendingPathComponent("PIN", isDirectory: true)
        let secretDirectory = directory.appendingPathComponent("Secrets", isDirectory: true)
        let suiteName = "PrivacyLockServiceTests-\(UUID().uuidString)"
        defaultSuiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = AppSettingsStore(
            defaults: defaults,
            secretStore: SecretStore(directory: secretDirectory)
        )
        let service = PrivacyLockService(directory: pinDirectory)

        var settings = AppSettings()
        settings.privacyVaultName = "Private Shelf"
        settings.privacyPINEnabled = true

        try await service.setPINAsync("445566")
        await settingsStore.saveAsync(settings)

        var loaded = settingsStore.load()
        let verifiesSavedPIN = await service.verifyAsync(pin: "445566")
        XCTAssertTrue(loaded.privacyPINEnabled)
        XCTAssertEqual(loaded.privacyVaultName, "Private Shelf")
        XCTAssertTrue(verifiesSavedPIN)

        settings.privacyPINEnabled = false
        await service.removePINAsync()
        await settingsStore.saveAsync(settings)

        loaded = settingsStore.load()
        let hasPINAfterRemoval = await service.hasPINAsync()
        XCTAssertFalse(loaded.privacyPINEnabled)
        XCTAssertFalse(hasPINAfterRemoval)
    }

    func testAsyncPINFileOperationsRunThroughInjectedIOOnBlockingIOQueue() async throws {
        let directory = try makeTemporaryDirectory()
        let recorder = RecordingPrivacyLockIO(directory: directory)
        let service = PrivacyLockService(directory: directory, io: recorder.io())

        try await service.setPINAsync("778899")
        let hasPIN = await service.hasPINAsync()
        let verifiesPIN = await service.verifyAsync(pin: "778899")
        await service.removePINAsync()

        XCTAssertTrue(hasPIN)
        XCTAssertTrue(verifiesPIN)
        XCTAssertEqual(recorder.operationNames, [
            "fileURL",
            "write",
            "fileURL",
            "read",
            "fileURL",
            "read",
            "fileURL",
            "remove"
        ])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.fileURL.path))
    }

    private func readablePINs(
        _ pins: [String],
        using service: PrivacyLockService
    ) async -> [String] {
        var matches: [String] = []
        for pin in pins {
            if await service.verifyAsync(pin: pin) {
                matches.append(pin)
            }
        }
        return matches
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyLockServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }
}

private final class RecordingPrivacyLockIO: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(name: String, onBlockingIOQueue: Bool)] = []
    let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("privacy-pin.json")
    }

    var operationNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.name)
    }

    var didObserveBlockingIOOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.onBlockingIOQueue }
    }

    var allOperationsObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !records.isEmpty && records.allSatisfy(\.onBlockingIOQueue)
    }

    func io() -> PrivacyLockService.IO {
        PrivacyLockService.IO(
            fileURL: { [weak self] directoryOverride in
                guard let self else { return nil }
                record("fileURL")
                if let directoryOverride {
                    try? FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
                    return directoryOverride.appendingPathComponent("privacy-pin.json")
                }
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                return fileURL
            },
            write: { [weak self] data, url in
                self?.record("write")
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            },
            read: { [weak self] url in
                self?.record("read")
                return try Data(contentsOf: url)
            },
            remove: { [weak self] url in
                self?.record("remove")
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    private func record(_ name: String) {
        lock.lock()
        records.append((name, BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()))
        lock.unlock()
    }
}
