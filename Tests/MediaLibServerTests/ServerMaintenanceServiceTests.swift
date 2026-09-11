import Darwin
import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

final class ServerMaintenanceServiceTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var experience: ServerExperienceRepository!
    private var identity: ServerIdentityRepository!
    private var principal: ServerRequestPrincipal!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerMaintenanceServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("test.sqlite"))
        experience = ServerExperienceRepository(database: database)
        identity = ServerIdentityRepository(database: database)
        _ = try identity.createUser(id: "maintenance-user", username: "maintainer", displayName: "Maintainer")
        principal = ServerRequestPrincipal(
            userID: "maintenance-user",
            deviceID: "maintenance-device",
            sessionID: "maintenance-session",
            permissions: [.manageServer, .manageLibraries],
            libraryGrants: [:]
        )
    }

    override func tearDownWithError() throws {
        experience = nil
        identity = nil
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testConcurrentAdmissionNeverExceedsEightCommittedQueuedJobs() throws {
        let gate = BlockingFirstOperationGate()
        let sideEffects = LockedInteger()
        let service = try makeService(
            transcodeCacheCleanup: { sideEffects.increment() },
            hooks: ServerMaintenanceServiceHooks(beforeOperationStart: { _ in gate.waitOnce() })
        )
        let results = LockedAdmissionResults()

        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                let job = try service.enqueueTranscodeCacheCleanup(requestedBy: principal)
                results.append(.success(job.id))
            } catch {
                results.append(.failure(error))
            }
        }

        XCTAssertEqual(results.successCount, 8)
        XCTAssertEqual(results.queueFullCount, 4)
        XCTAssertEqual(try experience.jobStateCounts()[.queued], 8)
        XCTAssertEqual(sideEffects.value, 0)
        gate.release()
        XCTAssertTrue(waitUntil { (try? self.experience.jobStateCounts()[.succeeded]) == 8 })
        XCTAssertEqual(sideEffects.value, 8)
    }

    func testAdmissionAuditFailureRollsBackJobAndSchedulesNothing() throws {
        struct InjectedAuditFailure: Error {}
        let sideEffects = LockedInteger()
        let service = try makeService(
            transcodeCacheCleanup: { sideEffects.increment() },
            securityEventAppender: { event in
                if event.action.hasSuffix("requested") { throw InjectedAuditFailure() }
                try self.identity.appendSecurityEvent(event)
            }
        )

        XCTAssertThrowsError(try service.enqueueTranscodeCacheCleanup(requestedBy: principal))
        XCTAssertEqual(try experience.managedJobs(limit: 20).totalCount, 0)
        XCTAssertEqual(sideEffects.value, 0)
    }

    func testMetadataRefreshRereadsChangedNFOAndReportsNoChangePrecisely() throws {
        let mediaDirectory = directory.appendingPathComponent("metadata-source", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let movieURL = mediaDirectory.appendingPathComponent("Feature.mkv")
        let nfoURL = mediaDirectory.appendingPathComponent("Feature.nfo")
        try Data([0x01]).write(to: movieURL)
        try "<movie><title>First Local Title</title></movie>".write(
            to: nfoURL, atomically: true, encoding: .utf8
        )
        try SourceRepository(database: database).save(MediaSource(
            id: "metadata-local",
            name: "Local Metadata",
            path: mediaDirectory.path,
            mediaType: .movie,
            minimumFileSize: 0,
            readNFO: true,
            preferLocalArtwork: true,
            networkScrapingEnabled: true,
            screenshotFallbackEnabled: true,
            includeInMetadataFetch: true,
            preferMetadataWriteToSource: true
        ))
        let service = try makeService()
        let media = MediaRepository(database: database)

        let initial = try service.enqueueLibraryJob(kind: "metadata.refresh", requestedBy: principal)
        XCTAssertTrue(waitUntil { try self.experience.job(id: initial.id)?.state == .succeeded })
        XCTAssertEqual(try experience.job(id: initial.id)?.resultCode, "metadata.local-reload-completed")
        XCTAssertEqual(try media.fetchItems(sourcePath: mediaDirectory.path).first?.title, "First Local Title")

        try "<movie><title>Second Local Title</title></movie>".write(
            to: nfoURL, atomically: true, encoding: .utf8
        )
        let changed = try service.enqueueLibraryJob(kind: "metadata.refresh", requestedBy: principal)
        XCTAssertTrue(waitUntil { try self.experience.job(id: changed.id)?.state == .succeeded })
        XCTAssertEqual(try experience.job(id: changed.id)?.resultCode, "metadata.local-reload-completed")
        XCTAssertEqual(try media.fetchItems(sourcePath: mediaDirectory.path).first?.title, "Second Local Title")

        let unchanged = try service.enqueueLibraryJob(kind: "metadata.refresh", requestedBy: principal)
        XCTAssertTrue(waitUntil { try self.experience.job(id: unchanged.id)?.state == .succeeded })
        XCTAssertEqual(try experience.job(id: unchanged.id)?.resultCode, "metadata.local-reload-no-changes")
        XCTAssertEqual(
            try String(contentsOf: nfoURL, encoding: .utf8),
            "<movie><title>Second Local Title</title></movie>",
            "本地重读不得写回或改写 NFO"
        )
    }

    func testMetadataRefreshExcludesRemoteVaultAndOptedOutSources() throws {
        let sources = SourceRepository(database: database)
        try sources.save(MediaSource(
            id: "metadata-remote", name: "Remote", path: "emby://account/library",
            mediaType: .movie, minimumFileSize: 0, includeInMetadataFetch: true
        ))
        try sources.save(MediaSource(
            id: "metadata-vault", name: "Vault", path: directory.appendingPathComponent("vault").path,
            mediaType: .privateCollection, minimumFileSize: 0, includeInMetadataFetch: true
        ))
        try sources.save(MediaSource(
            id: "metadata-opted-out", name: "Opted Out", path: directory.path,
            mediaType: .movie, minimumFileSize: 0, includeInMetadataFetch: false
        ))
        let service = try makeService()

        let job = try service.enqueueLibraryJob(kind: "metadata.refresh", requestedBy: principal)

        XCTAssertTrue(waitUntil { try self.experience.job(id: job.id)?.state == .succeeded })
        XCTAssertEqual(try experience.job(id: job.id)?.resultCode, "metadata.no-eligible-sources")
        XCTAssertEqual(try MediaRepository(database: database).fetchAll(), [])
    }

    func testMetadataRefreshReportsPartialFailureWithoutPruningMissingRows() throws {
        let reachable = directory.appendingPathComponent("reachable", isDirectory: true)
        try FileManager.default.createDirectory(at: reachable, withIntermediateDirectories: true)
        let movieURL = reachable.appendingPathComponent("Available.mp4")
        try Data([0x01]).write(to: movieURL)
        try "<movie><title>Available Local Title</title></movie>".write(
            to: reachable.appendingPathComponent("Available.nfo"), atomically: true, encoding: .utf8
        )
        let missingDirectory = directory.appendingPathComponent("missing", isDirectory: true)
        let sources = SourceRepository(database: database)
        try sources.save(MediaSource(
            id: "metadata-reachable", name: "Reachable", path: reachable.path,
            mediaType: .movie, minimumFileSize: 0, includeInMetadataFetch: true
        ))
        try sources.save(MediaSource(
            id: "metadata-missing", name: "Missing", path: missingDirectory.path,
            mediaType: .movie, minimumFileSize: 0, includeInMetadataFetch: true
        ))
        let media = MediaRepository(database: database)
        let retained = MediaItem(
            id: "retained-missing-file",
            type: .movie,
            title: "Retained",
            sourcePath: reachable.path,
            filePath: reachable.appendingPathComponent("Removed.mp4").path,
            fileSize: 1
        )
        try media.upsert(retained)
        let service = try makeService()

        let job = try service.enqueueLibraryJob(kind: "metadata.refresh", requestedBy: principal)

        XCTAssertTrue(waitUntil { try self.experience.job(id: job.id)?.state == .failed })
        XCTAssertEqual(try experience.job(id: job.id)?.resultCode, "metadata.local-reload-partial")
        XCTAssertEqual(try media.fetch(id: retained.id)?.title, "Retained")
        XCTAssertTrue(try media.fetchItems(sourcePath: reachable.path).contains {
            $0.title == "Available Local Title"
        })
    }

    func testRunningPersistenceFailureProducesNoExternalSideEffectAndPausesAdmission() throws {
        struct InjectedStartFailure: Error {}
        let sideEffects = LockedInteger()
        let service = try makeService(
            transcodeCacheCleanup: { sideEffects.increment() },
            hooks: ServerMaintenanceServiceHooks(beforeRunningPersistence: { _ in throw InjectedStartFailure() })
        )

        let job = try service.enqueueTranscodeCacheCleanup(requestedBy: principal)
        XCTAssertTrue(waitUntil {
            try self.experience.job(id: job.id)?.resultCode == "job.start-persistence-failed"
        })
        XCTAssertEqual(sideEffects.value, 0)
        XCTAssertEqual(try experience.job(id: job.id)?.state, .failed)
        XCTAssertEqual(service.diagnosticCode, "job.start-persistence-failed")
        XCTAssertThrowsError(try service.enqueueTranscodeCacheCleanup(requestedBy: principal)) { error in
            XCTAssertEqual(error as? ServerMaintenanceError, .unavailable)
        }
    }

    func testTerminalAuditFailureLeavesQueryableFailedJobAndPausesAdmission() throws {
        struct InjectedCompletionAuditFailure: Error {}
        let sideEffects = LockedInteger()
        let service = try makeService(
            transcodeCacheCleanup: { sideEffects.increment() },
            securityEventAppender: { event in
                if event.action == "transcode-cache.cleared" {
                    throw InjectedCompletionAuditFailure()
                }
                try self.identity.appendSecurityEvent(event)
            }
        )

        let job = try service.enqueueTranscodeCacheCleanup(requestedBy: principal)
        XCTAssertTrue(waitUntil {
            try self.experience.job(id: job.id)?.resultCode == "job.finalization-failed"
        })
        XCTAssertEqual(sideEffects.value, 1)
        XCTAssertEqual(try experience.job(id: job.id)?.state, .failed)
        XCTAssertEqual(service.diagnosticCode, "job.finalization-failed")
        XCTAssertThrowsError(try service.enqueueTranscodeCacheCleanup(requestedBy: principal)) { error in
            XCTAssertEqual(error as? ServerMaintenanceError, .unavailable)
        }
    }

    func testStartupRecoveryInterruptsOnlyActiveJobsAndIsIdempotent() throws {
        for index in 0..<8 {
            _ = try experience.saveJob(ServerJob(
                id: "orphan-\(index)",
                kind: "library.scan",
                state: index.isMultiple(of: 2) ? .queued : .running,
                startedAt: index.isMultiple(of: 2) ? nil : Date()
            ))
        }
        _ = try experience.saveJob(ServerJob(
            id: "history",
            kind: "database.backup",
            state: .succeeded,
            progress: 1,
            resultCode: "backup.created",
            finishedAt: Date()
        ))

        _ = try makeService()
        XCTAssertEqual(try experience.jobStateCounts()[.failed], 8)
        XCTAssertEqual(try experience.job(id: "history")?.state, .succeeded)
        XCTAssertTrue((0..<8).allSatisfy {
            (try? experience.job(id: "orphan-\($0)")?.resultCode) == "job.interrupted"
        })
        XCTAssertEqual(try identity.securityEvents(limit: 20).filter { $0.action == "maintenance.recovered" }.count, 1)

        _ = try makeService()
        XCTAssertEqual(try identity.securityEvents(limit: 20).filter { $0.action == "maintenance.recovered" }.count, 1)
        let accepted = try makeService().enqueueTranscodeCacheCleanup(requestedBy: principal)
        XCTAssertTrue(waitUntil { try self.experience.job(id: accepted.id)?.state == .succeeded })
    }

    func testStartupRecoveryAuditFailureKeepsAdmissionDisabledAndRollsBackRecovery() throws {
        struct InjectedRecoveryAuditFailure: Error {}
        _ = try experience.saveJob(ServerJob(id: "orphan", kind: "library.scan"))
        let service = ServerMaintenanceService(
            database: database,
            experienceRepository: experience,
            identityRepository: identity,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true),
            securityEventAppender: { event in
                if event.action == "maintenance.recovered" { throw InjectedRecoveryAuditFailure() }
                try self.identity.appendSecurityEvent(event)
            }
        )

        XCTAssertThrowsError(try service.prepareForServing())
        XCTAssertEqual(service.diagnosticCode, "job.startup-recovery-failed")
        XCTAssertEqual(try experience.job(id: "orphan")?.state, .queued)
        XCTAssertThrowsError(try service.enqueueTranscodeCacheCleanup(requestedBy: principal)) { error in
            XCTAssertEqual(error as? ServerMaintenanceError, .unavailable)
        }
    }

    func testIndependentProcessExitIsRecoveredByNewServiceInstance() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute(\"INSERT INTO server_jobs (id,kind,state,progress,created_at) VALUES ('process-orphan','library.scan','running',0.25,strftime('%Y-%m-%dT%H:%M:%fZ','now'))\"); c.commit(); sys.stdout.write('1'); sys.stdout.flush(); time.sleep(30)",
            directory.appendingPathComponent("test.sqlite").path
        ]
        process.standardOutput = output
        try process.run()
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data([0x31]))
        process.terminate()
        process.waitUntilExit()

        database = nil
        experience = nil
        identity = nil
        database = try DatabaseManager(url: directory.appendingPathComponent("test.sqlite"))
        experience = ServerExperienceRepository(database: database)
        identity = ServerIdentityRepository(database: database)
        let service = try makeService()

        XCTAssertEqual(try experience.job(id: "process-orphan")?.state, .failed)
        XCTAssertEqual(try experience.job(id: "process-orphan")?.resultCode, "job.interrupted")
        let accepted = try service.enqueueTranscodeCacheCleanup(requestedBy: principal)
        XCTAssertTrue(waitUntil { try self.experience.job(id: accepted.id)?.state == .succeeded })
    }

    func testRestoreInterruptsSnapshotActiveJobsAndReinsertsCurrentJob() throws {
        _ = try experience.saveJob(ServerJob(id: "snapshot-orphan", kind: "library.scan"))
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        _ = try database.createBackup(in: backupDirectory, reason: "manual")
        var cleared = try XCTUnwrap(experience.job(id: "snapshot-orphan"))
        cleared.state = .succeeded
        cleared.progress = 1
        cleared.resultCode = "scan.completed"
        cleared.finishedAt = Date()
        _ = try experience.saveJob(cleared)

        let service = try makeService()
        let backupID = try XCTUnwrap(service.backups().first?.id)
        let restore = try service.enqueueRestore(backupID: backupID, requestedBy: principal)

        XCTAssertTrue(waitUntil(timeout: 8) {
            try self.experience.job(id: restore.id)?.state == .succeeded
        })
        XCTAssertEqual(try experience.job(id: restore.id)?.resultCode, "restore.completed")
        XCTAssertEqual(try experience.job(id: "snapshot-orphan")?.state, .failed)
        XCTAssertEqual(try experience.job(id: "snapshot-orphan")?.resultCode, "job.interrupted")
    }

    func testRestoreRemainsQueryableWhenRequesterDoesNotExistInSnapshot() throws {
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        _ = try database.createBackup(in: backupDirectory, reason: "manual")
        _ = try identity.createUser(id: "late-admin", username: "late-admin", displayName: "Late Admin")
        let latePrincipal = ServerRequestPrincipal(
            userID: "late-admin",
            deviceID: "late-device",
            sessionID: "late-session",
            permissions: [.manageServer],
            libraryGrants: [:]
        )
        let service = try makeService()
        let backupID = try XCTUnwrap(service.backups().first?.id)

        let restore = try service.enqueueRestore(backupID: backupID, requestedBy: latePrincipal)
        XCTAssertTrue(waitUntil(timeout: 8) {
            try self.experience.job(id: restore.id)?.state == .succeeded
        })
        XCTAssertNil(try experience.job(id: restore.id)?.requestedByUserID)
        let restoreEvents = try identity.securityEvents(limit: 20).filter {
            $0.action == "restore.snapshot-applied" || $0.action == "restore.completed"
        }
        XCTAssertEqual(restoreEvents.count, 2)
        XCTAssertTrue(restoreEvents.allSatisfy { $0.actorUserID == nil })
    }

    func testRestoreAdmissionIsExclusiveUntilRestoreFinishes() throws {
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        _ = try database.createBackup(in: backupDirectory, reason: "manual")
        let gate = BlockingFirstOperationGate()
        let service = try makeService(
            hooks: ServerMaintenanceServiceHooks(beforeOperationStart: { _ in gate.waitOnce() })
        )
        let backupID = try XCTUnwrap(service.backups().first?.id)
        let restore = try service.enqueueRestore(backupID: backupID, requestedBy: principal)

        XCTAssertThrowsError(try service.enqueueTranscodeCacheCleanup(requestedBy: principal)) { error in
            XCTAssertEqual(error as? ServerMaintenanceError, .exclusiveJobActive)
        }
        XCTAssertThrowsError(try service.enqueueRestore(backupID: backupID, requestedBy: principal)) { error in
            XCTAssertEqual(error as? ServerMaintenanceError, .exclusiveJobActive)
        }
        gate.release()
        XCTAssertTrue(waitUntil(timeout: 8) {
            try self.experience.job(id: restore.id)?.state == .succeeded
        })
    }

    func testRestoreIsRejectedWhenDesktopHostCannotBeCoordinated() throws {
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        _ = try database.createBackup(in: backupDirectory, reason: "manual")
        let service = try makeService(restoreAllowed: { false })
        let backupID = try XCTUnwrap(service.backups().first?.id)

        XCTAssertThrowsError(try service.enqueueRestore(backupID: backupID, requestedBy: principal)) { error in
            XCTAssertEqual(error as? ServerMaintenanceError, .restoreHostActive)
        }
        XCTAssertEqual(try experience.managedJobs(limit: 20).totalCount, 0)
    }

    func testShutdownStopsAdmissionAndWaitsForCommittedWorkWithinBound() throws {
        let sideEffects = LockedInteger()
        let service = try makeService(transcodeCacheCleanup: {
            Thread.sleep(forTimeInterval: 0.05)
            return sideEffects.increment()
        })
        let job = try service.enqueueTranscodeCacheCleanup(requestedBy: principal)

        XCTAssertTrue(service.shutdown(waitTimeout: 1))
        XCTAssertEqual(sideEffects.value, 1)
        XCTAssertEqual(try experience.job(id: job.id)?.state, .succeeded)
        XCTAssertThrowsError(try service.enqueueTranscodeCacheCleanup(requestedBy: principal)) { error in
            XCTAssertEqual(error as? ServerMaintenanceError, .unavailable)
        }
    }

    func testIndependentProcessLockExcludesSecondOwnerAndReleasesOnExit() throws {
        let lockDirectory = directory.appendingPathComponent("lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockPath = lockDirectory.appendingPathComponent(".medialib-maintenance.lock").path
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl,os,sys,time; f=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB); os.write(1,b'1'); time.sleep(2)",
            lockPath
        ]
        process.standardOutput = output
        try process.run()
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data([0x31]))
        XCTAssertThrowsError(try ServerMaintenanceExecutorLock.acquire(in: lockDirectory)) { error in
            XCTAssertEqual(error as? ServerMaintenanceExecutorLockError, .alreadyHeld)
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lock = try ServerMaintenanceExecutorLock.acquire(in: lockDirectory)
        withExtendedLifetime(lock) {}
    }

    func testExecutorLockRejectsSymbolicLinkTarget() throws {
        let lockDirectory = directory.appendingPathComponent("unsafe-lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("unrelated")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: lockDirectory.appendingPathComponent(".medialib-maintenance.lock"),
            withDestinationURL: target
        )

        XCTAssertThrowsError(try ServerMaintenanceExecutorLock.acquire(in: lockDirectory)) { error in
            XCTAssertEqual(error as? ServerMaintenanceExecutorLockError, .unsafeLockFile)
        }
    }

    private func makeService(
        transcodeCacheCleanup: @escaping @Sendable () -> Int = { 0 },
        restoreAllowed: @escaping @Sendable () -> Bool = { true },
        securityEventAppender: (@Sendable (ServerSecurityEvent) throws -> Void)? = nil,
        hooks: ServerMaintenanceServiceHooks = .live
    ) throws -> ServerMaintenanceService {
        let service = ServerMaintenanceService(
            database: database,
            experienceRepository: experience,
            identityRepository: identity,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true),
            transcodeCacheCleanup: transcodeCacheCleanup,
            restoreAllowed: restoreAllowed,
            securityEventAppender: securityEventAppender,
            hooks: hooks
        )
        try service.prepareForServing()
        return service
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () throws -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? condition()) == true { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return (try? condition()) == true
    }
}

private final class BlockingFirstOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var shouldWait = true

    func waitOnce() {
        condition.lock()
        guard shouldWait else {
            condition.unlock()
            return
        }
        while shouldWait { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        shouldWait = false
        condition.broadcast()
        condition.unlock()
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

private final class LockedAdmissionResults: @unchecked Sendable {
    enum Result { case success(String), failure(Error) }
    private let lock = NSLock()
    private var values: [Result] = []

    func append(_ result: Result) { lock.withLock { values.append(result) } }
    var successCount: Int { lock.withLock { values.filter { if case .success = $0 { true } else { false } }.count } }
    var queueFullCount: Int {
        lock.withLock {
            values.filter {
                guard case let .failure(error) = $0 else { return false }
                return error as? ServerMaintenanceError == .queueFull
            }.count
        }
    }
}
