import Foundation
import XCTest
@testable import MediaLibCore

final class ServerExperienceRepositoryTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var identity: ServerIdentityRepository!
    private var repository: ServerExperienceRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-ServerExperience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("test.sqlite"))
        identity = ServerIdentityRepository(database: database)
        _ = try identity.createUser(id: "user-1", username: "viewer", displayName: "Viewer")
        _ = try identity.registerDevice(id: "device-1", userID: "user-1", name: "Safari", platform: "Web")
        repository = ServerExperienceRepository(database: database)
    }

    override func tearDownWithError() throws {
        repository = nil
        identity = nil
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsPreservePreMigrationBehaviorAndFirstSaveUsesVersionOne() throws {
        let initial = try repository.userPreferences(userID: "user-1")
        XCTAssertEqual(initial.version, 0)
        XCTAssertEqual(initial.value.appearance, .system)
        XCTAssertEqual(initial.value.defaultQuality, .auto)
        XCTAssertTrue(initial.value.autoplayNext)
        XCTAssertEqual(initial.value.subtitleMode, .foreignAudio)

        var changed = initial.value
        changed.preferredAudioLanguage = "zh-Hans"
        changed.subtitleMode = .preferForced
        let saved = try repository.saveUserPreferences(userID: "user-1", value: changed, expectedVersion: 0)
        XCTAssertEqual(saved.version, 1)
        let reloaded = try repository.userPreferences(userID: "user-1")
        XCTAssertEqual(reloaded.version, saved.version)
        XCTAssertEqual(reloaded.value, saved.value)
    }

    func testVersionConflictPreventsLostUpdate() throws {
        let original = ServerUserExperiencePreferences()
        _ = try repository.saveUserPreferences(userID: "user-1", value: original, expectedVersion: 0)

        XCTAssertThrowsError(
            try repository.saveUserPreferences(userID: "user-1", value: original, expectedVersion: 0)
        ) { error in
            XCTAssertEqual(error as? ServerExperienceRepositoryError, .versionConflict(currentVersion: 1))
        }
    }

    func testDeviceOverrideCanBeVersionedAndDeleted() throws {
        let override = ServerDeviceExperienceOverrides(
            appearance: .dark,
            contentDensity: .compact,
            defaultQuality: .quality1080p,
            remoteBitrateMbps: 18
        )
        let saved = try repository.saveDevicePreferences(
            userID: "user-1", deviceID: "device-1", value: override, expectedVersion: 0
        )
        XCTAssertEqual(saved.version, 1)
        let reloaded = try repository.devicePreferences(userID: "user-1", deviceID: "device-1")
        XCTAssertEqual(reloaded?.version, saved.version)
        XCTAssertEqual(reloaded?.value, saved.value)

        try repository.deleteDevicePreferences(userID: "user-1", deviceID: "device-1", expectedVersion: 1)
        XCTAssertNil(try repository.devicePreferences(userID: "user-1", deviceID: "device-1"))
    }

    func testOperationalSettingsEnforceBoundedConcurrencyAndOptimisticLocking() throws {
        let initial = try repository.operationalSettings()
        XCTAssertEqual(initial.value.maximumTranscodeSessions, 2)
        var changed = initial.value
        changed.maximumTranscodeSessions = 4
        let saved = try repository.saveOperationalSettings(changed, expectedVersion: initial.version)
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.value.maximumTranscodeSessions, 4)
    }

    func testTrackOverrideAndJobsRemainScopedAndPaginated() throws {
        let track = ServerTrackSelectionOverride(
            scope: .media,
            scopeID: "media-1",
            audioFingerprint: "aac:zh:2",
            subtitleFingerprint: "vtt:zh-Hans:3"
        )
        _ = try repository.saveTrackOverride(userID: "user-1", value: track)
        XCTAssertEqual(
            try repository.trackOverride(userID: "user-1", scope: .media, scopeID: "media-1")?.audioFingerprint,
            "aac:zh:2"
        )

        _ = try repository.saveJob(ServerJob(id: "job-1", kind: "library.scan", requestedByUserID: "user-1"))
        _ = try repository.saveJob(ServerJob(id: "job-2", kind: "metadata.refresh", state: .running, progress: 0.5))
        XCTAssertEqual(try repository.jobs(limit: 1).count, 1)
        XCTAssertEqual(try repository.jobs(state: .running).map(\.id), ["job-2"])
    }

    func testManagedJobsFiltersCountsAndPagesInsidePermissionKindsWithStableOrdering() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let jobs = [
            ServerJob(id: "job-a", kind: "library.scan", state: .succeeded, progress: 1, resultCode: "scan_100%", createdAt: createdAt),
            ServerJob(id: "job-b", kind: "metadata.refresh", state: .failed, progress: 1, resultCode: "metadata.failed", createdAt: createdAt),
            ServerJob(id: "job-c", kind: "library.reindex", state: .running, progress: 0.5, createdAt: createdAt),
            ServerJob(id: "job-d", kind: "database.backup", state: .queued, createdAt: createdAt)
        ]
        for job in jobs { _ = try repository.saveJob(job) }

        let libraryKinds: Set<String> = ["library.scan", "library.reindex", "metadata.refresh"]
        let page = try repository.managedJobs(
            limit: 2,
            offset: 1,
            allowedKinds: libraryKinds
        )
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertEqual(page.jobs.map(\.id), ["job-b", "job-a"])

        let failed = try repository.managedJobs(
            limit: 10,
            state: .failed,
            searchText: "metadata",
            allowedKinds: libraryKinds
        )
        XCTAssertEqual(failed.totalCount, 1)
        XCTAssertEqual(failed.jobs.map(\.id), ["job-b"])

        let escapedSearch = try repository.managedJobs(limit: 10, searchText: "_100%")
        XCTAssertEqual(escapedSearch.jobs.map(\.id), ["job-a"])

        let counts = try repository.jobStateCounts()
        XCTAssertEqual(counts[.queued], 1)
        XCTAssertEqual(counts[.running], 1)
        XCTAssertEqual(counts[.succeeded], 1)
        XCTAssertEqual(counts[.failed], 1)

        XCTAssertThrowsError(try repository.managedJobs(limit: 10, searchText: "bad\u{0001}"))
    }
}
