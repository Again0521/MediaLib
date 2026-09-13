import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class LibraryReloadCoordinatorTests: XCTestCase {
    func testLiveSnapshotLoaderReadsRepositoriesIntoOneConsistentResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-reload-loader-\(UUID().uuidString)", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        let thumbnails = cache.appendingPathComponent("Thumbnails", isDirectory: true)
        let previews = cache.appendingPathComponent("PreviewFrames", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        for directory in [root, backups, cache, thumbnails, previews, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(
            applicationSupport: root,
            database: root.appendingPathComponent("MediaLib.sqlite"),
            databaseBackups: backups,
            cache: cache,
            thumbnails: thumbnails,
            previewFrames: previews,
            logs: logs
        )
        let database = try DatabaseManager(url: directories.database, backupDirectory: backups)
        let source = MediaSource(id: "source-1", name: "Fixture", path: "/Fixture", mediaType: .movie)
        try SourceRepository(database: database).save(source)
        try MediaRepository(database: database).upsert(MediaItem(
            id: "movie-1",
            type: .movie,
            title: "Fixture Movie",
            sourcePath: source.path,
            fileSize: 4_096
        ))

        let snapshot = try await LibraryReloadSnapshotLoader.load(directories: directories)

        XCTAssertEqual(snapshot.sources.map(\.id), ["source-1"])
        XCTAssertEqual(snapshot.items.map(\.id), ["movie-1"])
        XCTAssertTrue(snapshot.musicPlaylists.isEmpty)
        XCTAssertTrue(snapshot.pendingSyncConflicts.isEmpty)
        XCTAssertTrue(snapshot.detailMetadataGapsByMediaID.keys.contains("movie-1"))
    }

    func testLiveSnapshotLoaderDoesNotMixCommitsBetweenRepositories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-reload-interleaving-\(UUID().uuidString)", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        let thumbnails = cache.appendingPathComponent("Thumbnails", isDirectory: true)
        let previews = cache.appendingPathComponent("PreviewFrames", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        for directory in [root, backups, cache, thumbnails, previews, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(
            applicationSupport: root,
            database: root.appendingPathComponent("MediaLib.sqlite"),
            databaseBackups: backups,
            cache: cache,
            thumbnails: thumbnails,
            previewFrames: previews,
            logs: logs
        )
        let writer = try DatabaseManager(url: directories.database, backupDirectory: backups)
        let original = MediaSource(id: "source-original", name: "Original", path: "/Original", mediaType: .movie)
        let later = MediaSource(id: "source-later", name: "Later", path: "/Later", mediaType: .movie)
        try SourceRepository(database: writer).save(original)
        try MediaRepository(database: writer).upsert(MediaItem(
            id: "movie-original", type: .movie, title: "Original", sourcePath: original.path
        ))

        let first = try await LibraryReloadSnapshotLoader.load(
            directories: directories,
            afterSourcesRead: {
                try writer.transaction {
                    try SourceRepository(database: writer).save(later)
                    try MediaRepository(database: writer).upsert(MediaItem(
                        id: "movie-later", type: .movie, title: "Later", sourcePath: later.path
                    ))
                }
            }
        )
        XCTAssertEqual(first.sources.map(\.id), ["source-original"])
        XCTAssertEqual(first.items.map(\.id), ["movie-original"])
        XCTAssertFalse(first.detailMetadataGapsByMediaID.keys.contains("movie-later"))

        let next = try await LibraryReloadSnapshotLoader.load(directories: directories)
        XCTAssertEqual(Set(next.sources.map(\.id)), ["source-original", "source-later"])
        XCTAssertEqual(Set(next.items.map(\.id)), ["movie-original", "movie-later"])
    }

    func testLiveSnapshotLoaderCancelsBetweenRepositoryReadsAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-reload-cancellation-\(UUID().uuidString)", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        let thumbnails = cache.appendingPathComponent("Thumbnails", isDirectory: true)
        let previews = cache.appendingPathComponent("PreviewFrames", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        for directory in [root, backups, cache, thumbnails, previews, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(
            applicationSupport: root,
            database: root.appendingPathComponent("MediaLib.sqlite"),
            databaseBackups: backups,
            cache: cache,
            thumbnails: thumbnails,
            previewFrames: previews,
            logs: logs
        )
        let writer = try DatabaseManager(url: directories.database, backupDirectory: backups)
        try SourceRepository(database: writer).save(MediaSource(
            id: "source-1", name: "Fixture", path: "/Fixture", mediaType: .movie
        ))

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await LibraryReloadSnapshotLoader.load(
                directories: directories,
                afterSourcesRead: {
                    entered.signal()
                    release.wait()
                }
            )
        }
        let didEnter = await BlockingIOExecutor.run {
            entered.wait(timeout: .now() + 3) == .success
        }
        XCTAssertTrue(didEnter)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled reload must not publish a partial snapshot")
        } catch is CancellationError {
            // The explicit token crosses the Task -> GCD queue boundary.
        }

        let retry = try await LibraryReloadSnapshotLoader.load(directories: directories)
        XCTAssertEqual(retry.sources.map(\.id), ["source-1"])
    }

    func testNewRequestDiscardsOlderResultEvenWhenLoaderIgnoresCancellation() async {
        let gate = AsyncGate()
        let coordinator = LibraryReloadCoordinator<Int, Int> { input in
            if input == 1 { await gate.wait() }
            return input
        }
        var applied: [Int] = []
        var loadingStates: [Bool] = []

        coordinator.schedule(
            input: 1,
            delayNanoseconds: 0,
            loadingChanged: { loadingStates.append($0) },
            apply: { value, _ in applied.append(value) },
            failure: { _ in XCTFail("unexpected failure") }
        )
        await gate.waitUntilBlocked()

        coordinator.schedule(
            input: 2,
            delayNanoseconds: 0,
            loadingChanged: { loadingStates.append($0) },
            apply: { value, _ in applied.append(value) },
            failure: { _ in XCTFail("unexpected failure") }
        )
        await waitUntil { applied == [2] }
        await gate.release()
        await Task.yield()

        XCTAssertEqual(applied, [2])
        XCTAssertEqual(loadingStates, [true, false])
        XCTAssertFalse(coordinator.isLoading)
    }

    func testCancelInvalidatesInFlightResultAndClearsLoadingState() async {
        let gate = AsyncGate()
        let coordinator = LibraryReloadCoordinator<Int, Int> { input in
            await gate.wait()
            return input
        }
        var applied: [Int] = []
        var loadingStates: [Bool] = []

        coordinator.schedule(
            input: 7,
            delayNanoseconds: 0,
            loadingChanged: { loadingStates.append($0) },
            apply: { value, _ in applied.append(value) },
            failure: { _ in XCTFail("unexpected failure") }
        )
        await gate.waitUntilBlocked()
        coordinator.cancel { loadingStates.append($0) }
        await gate.release()
        await Task.yield()

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(loadingStates, [true, false])
        XCTAssertFalse(coordinator.isLoading)
    }

    func testLatestFailureIsReportedAndFinishesLoading() async {
        enum TestError: Error { case expected }
        let coordinator = LibraryReloadCoordinator<Int, Int> { _ in throw TestError.expected }
        var failureCount = 0
        var loadingStates: [Bool] = []

        coordinator.schedule(
            input: 1,
            delayNanoseconds: 0,
            loadingChanged: { loadingStates.append($0) },
            apply: { _, _ in XCTFail("unexpected apply") },
            failure: { _ in failureCount += 1 }
        )
        await waitUntil { failureCount == 1 }

        XCTAssertEqual(loadingStates, [true, false])
        XCTAssertFalse(coordinator.isLoading)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while continuation == nil { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
