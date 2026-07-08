import XCTest
@testable import MediaLibCore
@testable import MediaLib

final class VideoOfflineCacheStoreTests: XCTestCase {
    private struct StoreEnvironment {
        let root: URL
        let applicationSupport: URL
        let cache: URL
    }

    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testAsyncUpsertAndReloadRoundTripsManifest() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let videoURL = store.currentCacheDirectory.appendingPathComponent("movie-original.mp4")
        try Data([0x01, 0x02, 0x03]).write(to: videoURL)

        let entry = makeEntry(
            itemID: "movie-1",
            localPath: videoURL.path,
            qualityID: "original",
            fileSize: 3
        )
        try await store.upsertAsync(entry)

        let entries = await store.allEntriesAsync()
        XCTAssertEqual(entries["movie-1"], entry)

        let reloaded = try makeStore(in: environment)
        let reloadedEntries = await reloaded.allEntriesAsync()
        XCTAssertEqual(reloadedEntries["movie-1"], entry)
    }

    func testRefreshPruningMissingFilesAsyncRemovesManifestEntry() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let videoURL = store.currentCacheDirectory.appendingPathComponent("missing-after-upsert.mp4")
        try Data([0x01]).write(to: videoURL)

        try await store.upsertAsync(makeEntry(itemID: "missing", localPath: videoURL.path, fileSize: 1))
        try FileManager.default.removeItem(at: videoURL)

        let pruned = try await store.refreshEntriesPruningMissingFilesAsync()
        XCTAssertTrue(pruned.isEmpty)

        let reloaded = try makeStore(in: environment)
        let reloadedEntries = await reloaded.allEntriesAsync()
        XCTAssertTrue(reloadedEntries.isEmpty)
    }

    func testRemoveAsyncDeletesVideoAndMatchingSidecarsOnly() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let cacheDirectory = store.currentCacheDirectory
        let videoURL = cacheDirectory.appendingPathComponent("movie.mp4")
        let srtURL = cacheDirectory.appendingPathComponent("movie.zh.0.srt")
        let assURL = cacheDirectory.appendingPathComponent("movie.commentary.1.ass")
        let unrelatedURL = cacheDirectory.appendingPathComponent("movie-extra.zh.0.srt")
        try Data([0x01, 0x02]).write(to: videoURL)
        try Data([0x03]).write(to: srtURL)
        try Data([0x04]).write(to: assURL)
        try Data([0x05]).write(to: unrelatedURL)

        try await store.upsertAsync(makeEntry(itemID: "movie", localPath: videoURL.path, fileSize: 2))
        let removed = try await store.removeAsync(itemIDs: ["movie"])

        XCTAssertEqual(removed.map(\.itemID), ["movie"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srtURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: assURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        let entries = await store.allEntriesAsync()
        XCTAssertTrue(entries.isEmpty)
    }

    func testCacheScopeRejectsSiblingPrefixAndStandardizedParentTraversal() throws {
        let environment = try makeEnvironment()
        let cacheDirectory = environment.cache.appendingPathComponent("VideoCache", isDirectory: true)
        let insideURL = cacheDirectory.appendingPathComponent("movie.mp4")
        let siblingPrefixURL = environment.cache
            .appendingPathComponent("VideoCacheEvil", isDirectory: true)
            .appendingPathComponent("movie.mp4")
        let traversalURL = cacheDirectory
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("outside.mp4")

        XCTAssertTrue(VideoOfflineCacheStore.isFileURL(insideURL, containedIn: cacheDirectory))
        XCTAssertFalse(VideoOfflineCacheStore.isFileURL(siblingPrefixURL, containedIn: cacheDirectory))
        XCTAssertFalse(VideoOfflineCacheStore.isFileURL(traversalURL, containedIn: cacheDirectory))
    }

    func testUpsertRejectsOutOfScopeLocalPath() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let outsideURL = environment.root
            .appendingPathComponent("Outside", isDirectory: true)
            .appendingPathComponent("external.mp4")
        try FileManager.default.createDirectory(at: outsideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x09]).write(to: outsideURL)

        do {
            try await store.upsertAsync(makeEntry(itemID: "outside", localPath: outsideURL.path, fileSize: 1))
            XCTFail("Expected out-of-scope video cache entry to be rejected")
        } catch VideoOfflineCacheStoreError.invalidCacheDirectory {
            // Expected.
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        let entries = await store.allEntriesAsync()
        XCTAssertTrue(entries.isEmpty)
    }

    func testRefreshPruningMissingFilesDropsOutOfScopeManifestEntryWithoutDeletingFile() async throws {
        let environment = try makeEnvironment()
        let outsideURL = environment.root
            .appendingPathComponent("Outside", isDirectory: true)
            .appendingPathComponent("manifest-external.mp4")
        try FileManager.default.createDirectory(at: outsideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x0A]).write(to: outsideURL)
        let recorder = RecordingManifestIO(initialEntries: [
            "outside": makeEntry(itemID: "outside", localPath: outsideURL.path, fileSize: 1)
        ])
        let store = try makeStore(in: environment, manifestIO: recorder.io())

        let entries = try await store.refreshEntriesPruningMissingFilesAsync()

        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        XCTAssertEqual(recorder.writeSnapshots.last?.keys.sorted(), [])
    }

    func testRemoveAsyncDropsOutOfScopeManifestEntryWithoutDeletingExternalFile() async throws {
        let environment = try makeEnvironment()
        let outsideURL = environment.root
            .appendingPathComponent("Outside", isDirectory: true)
            .appendingPathComponent("remove-external.mp4")
        try FileManager.default.createDirectory(at: outsideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x0B]).write(to: outsideURL)
        let recorder = RecordingManifestIO(initialEntries: [
            "outside": makeEntry(itemID: "outside", localPath: outsideURL.path, fileSize: 1)
        ])
        let store = try makeStore(in: environment, manifestIO: recorder.io())

        let removed = try await store.removeAsync(itemIDs: ["outside"])

        XCTAssertEqual(removed.map(\.itemID), ["outside"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        let entries = await store.allEntriesAsync()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(recorder.writeSnapshots.last?.keys.sorted(), [])
    }

    func testRunMaintenanceAsyncPrunesUntrackedFilesAndOverLimitEntries() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let cacheDirectory = store.currentCacheDirectory
        let watchedURL = cacheDirectory.appendingPathComponent("watched.mp4")
        let recentURL = cacheDirectory.appendingPathComponent("recent.mp4")
        let untrackedURL = cacheDirectory.appendingPathComponent("orphan.tmp")
        try Data(repeating: 0x01, count: 10).write(to: watchedURL)
        try Data(repeating: 0x02, count: 10).write(to: recentURL)
        try Data(repeating: 0x03, count: 4).write(to: untrackedURL)

        try await store.upsertAsync(makeEntry(itemID: "watched", localPath: watchedURL.path, fileSize: 10))
        try await store.upsertAsync(makeEntry(itemID: "recent", localPath: recentURL.path, fileSize: 10))

        let result = try await store.runMaintenanceAsync(
            validItemIDs: ["watched", "recent"],
            byteLimit: 15,
            cleanupHint: VideoCacheCleanupHint(
                watchedItemIDs: ["watched"],
                recentlyPlayedItemIDs: ["recent"]
            )
        )

        XCTAssertEqual(result.untrackedFiles, 1)
        XCTAssertEqual(result.overLimitEntries, 1)
        XCTAssertGreaterThanOrEqual(result.bytesBeforeCleanup, 20)
        XCTAssertLessThanOrEqual(result.bytesAfterCleanup, 15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: watchedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untrackedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
        let entries = await store.allEntriesAsync()
        XCTAssertEqual(Set(entries.keys), ["recent"])
    }

    func testSetCustomCacheDirectoryPathAsyncCreatesAndRestoresCacheDirectory() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let customRoot = environment.root.appendingPathComponent("CustomCacheRoot", isDirectory: true)
        let expectedCustomCache = customRoot.appendingPathComponent("VideoCache", isDirectory: true)

        try await store.setCustomCacheDirectoryPathAsync(customRoot.path)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedCustomCache.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(store.currentCacheDirectory.path, expectedCustomCache.path)

        try await store.setCustomCacheDirectoryPathAsync("   ")
        XCTAssertEqual(
            store.currentCacheDirectory.path,
            environment.cache.appendingPathComponent("VideoCache", isDirectory: true).path
        )
    }

    func testMarkAccessedAsyncPersistsLastAccessedDate() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let videoURL = store.currentCacheDirectory.appendingPathComponent("accessed.mp4")
        let accessedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try Data([0x01]).write(to: videoURL)

        try await store.upsertAsync(makeEntry(itemID: "accessed", localPath: videoURL.path, fileSize: 1))
        try await store.markAccessedAsync(itemID: "accessed", at: accessedAt)

        let entries = await store.allEntriesAsync()
        XCTAssertEqual(entries["accessed"]?.lastAccessedAt, accessedAt)

        let reloaded = try makeStore(in: environment)
        let reloadedEntries = await reloaded.allEntriesAsync()
        XCTAssertEqual(reloadedEntries["accessed"]?.lastAccessedAt, accessedAt)
    }

    func testEntryAsyncReturnsExistingEntryAndNilForMissingLocalFile() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        let existingURL = store.currentCacheDirectory.appendingPathComponent("existing.mp4")
        let missingURL = store.currentCacheDirectory.appendingPathComponent("missing.mp4")
        try Data([0x01, 0x02]).write(to: existingURL)
        try Data([0x03]).write(to: missingURL)

        let existingEntry = makeEntry(itemID: "existing", localPath: existingURL.path, fileSize: 2)
        let missingEntry = makeEntry(itemID: "missing", localPath: missingURL.path, fileSize: 1)
        try await store.upsertAsync(existingEntry)
        try await store.upsertAsync(missingEntry)
        try FileManager.default.removeItem(at: missingURL)

        let loadedExisting = await store.entryAsync(for: "existing")
        let loadedMissing = await store.entryAsync(for: "missing")

        XCTAssertEqual(loadedExisting, existingEntry)
        XCTAssertNil(loadedMissing)

        let manifestEntries = await store.allEntriesAsync()
        XCTAssertEqual(manifestEntries["missing"], missingEntry)
    }

    func testConcurrentEntryAsyncChecksRemainStable() async throws {
        let environment = try makeEnvironment()
        let store = try makeStore(in: environment)
        var expected: [String: Bool] = [:]

        for index in 0..<40 {
            let itemID = "item-\(index)"
            let videoURL = store.currentCacheDirectory.appendingPathComponent("\(itemID).mp4")
            try Data([UInt8(index)]).write(to: videoURL)
            try await store.upsertAsync(makeEntry(itemID: itemID, localPath: videoURL.path, fileSize: 1))
            if index.isMultiple(of: 2) {
                expected[itemID] = true
            } else {
                try FileManager.default.removeItem(at: videoURL)
                expected[itemID] = false
            }
        }

        await withTaskGroup(of: (String, Bool).self) { group in
            for itemID in expected.keys {
                group.addTask {
                    (itemID, await store.entryAsync(for: itemID) != nil)
                }
            }
            for await (itemID, exists) in group {
                XCTAssertEqual(exists, expected[itemID])
            }
        }
    }

    func testAsyncManifestWritesRunOnBlockingIOQueue() async throws {
        let environment = try makeEnvironment()
        let videoURL = environment.cache
            .appendingPathComponent("VideoCache", isDirectory: true)
            .appendingPathComponent("blocking-write.mp4")
        try FileManager.default.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: videoURL)
        let recorder = RecordingManifestIO()
        let store = try makeStore(in: environment, manifestIO: recorder.io())

        try await store.upsertAsync(makeEntry(itemID: "blocking-write", localPath: videoURL.path, fileSize: 1))

        XCTAssertEqual(recorder.writeSnapshots.last?.keys.sorted(), ["blocking-write"])
        XCTAssertTrue(recorder.didObserveBlockingIOWrite)
        XCTAssertTrue(recorder.allWritesObservedOnBlockingIOQueue)
    }

    func testRefreshPruningMissingFilesAsyncWritesPrunedManifestOnBlockingIOQueue() async throws {
        let environment = try makeEnvironment()
        let existingURL = environment.cache
            .appendingPathComponent("VideoCache", isDirectory: true)
            .appendingPathComponent("existing.mp4")
        try FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: existingURL)
        let recorder = RecordingManifestIO(initialEntries: [
            "existing": makeEntry(itemID: "existing", localPath: existingURL.path, fileSize: 1),
            "missing": makeEntry(itemID: "missing", localPath: existingURL.deletingLastPathComponent().appendingPathComponent("missing.mp4").path, fileSize: 1)
        ])
        let store = try makeStore(in: environment, manifestIO: recorder.io())

        let entries = try await store.refreshEntriesPruningMissingFilesAsync()

        XCTAssertEqual(Set(entries.keys), ["existing"])
        XCTAssertEqual(recorder.writeSnapshots.last?.keys.sorted(), ["existing"])
        XCTAssertTrue(recorder.didObserveBlockingIOWrite)
        XCTAssertTrue(recorder.allWritesObservedOnBlockingIOQueue)
    }

    func testPruneOnInitPersistsPrunedManifestThroughInjectedWriter() throws {
        let environment = try makeEnvironment()
        let existingURL = environment.cache
            .appendingPathComponent("VideoCache", isDirectory: true)
            .appendingPathComponent("init-existing.mp4")
        try FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: existingURL)
        let recorder = RecordingManifestIO(initialEntries: [
            "existing": makeEntry(itemID: "existing", localPath: existingURL.path, fileSize: 1),
            "missing": makeEntry(itemID: "missing", localPath: existingURL.deletingLastPathComponent().appendingPathComponent("init-missing.mp4").path, fileSize: 1)
        ])

        let store = try VideoOfflineCacheStore(
            applicationSupportDirectory: environment.applicationSupport,
            defaultCacheDirectory: environment.cache,
            customCacheDirectoryPath: nil,
            pruneOnInit: true,
            manifestIO: recorder.io()
        )

        XCTAssertEqual(Set(store.allEntries().keys), ["existing"])
        XCTAssertEqual(recorder.writeSnapshots.last?.keys.sorted(), ["existing"])
    }

    func testFileSystemManifestIOWritesSortedJSONAndRoundTrips() throws {
        let environment = try makeEnvironment()
        let manifestURL = environment.applicationSupport.appendingPathComponent("VideoCacheManifest.json")
        let cacheDirectory = environment.cache.appendingPathComponent("VideoCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let zURL = cacheDirectory.appendingPathComponent("z.mp4")
        let aURL = cacheDirectory.appendingPathComponent("a.mp4")
        try Data([0x01]).write(to: zURL)
        try Data([0x02]).write(to: aURL)
        let io = VideoOfflineCacheManifestIO.fileSystem(fileManager: .default)
        let entries = [
            "z": makeEntry(itemID: "z", localPath: zURL.path, fileSize: 1),
            "a": makeEntry(itemID: "a", localPath: aURL.path, fileSize: 1)
        ]

        try io.write(entries, manifestURL)
        let raw = try String(contentsOf: manifestURL, encoding: .utf8)
        let firstA = try XCTUnwrap(raw.range(of: "\"a\""))
        let firstZ = try XCTUnwrap(raw.range(of: "\"z\""))
        let roundTripped = try io.read(manifestURL)

        XCTAssertLessThan(firstA.lowerBound, firstZ.lowerBound)
        XCTAssertEqual(roundTripped, entries)
    }

    func testFileSystemManifestIOThrowsForCorruptedManifest() throws {
        let environment = try makeEnvironment()
        let manifestURL = environment.applicationSupport.appendingPathComponent("VideoCacheManifest.json")
        try Data("{bad json".utf8).write(to: manifestURL)

        XCTAssertThrowsError(try VideoOfflineCacheManifestIO.fileSystem(fileManager: .default).read(manifestURL))
    }

    private func makeEnvironment() throws -> StoreEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoOfflineCacheStoreTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectory = root
        let applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return StoreEnvironment(root: root, applicationSupport: applicationSupport, cache: cache)
    }

    private func makeStore(
        in environment: StoreEnvironment,
        manifestIO: VideoOfflineCacheManifestIO? = nil
    ) throws -> VideoOfflineCacheStore {
        try VideoOfflineCacheStore(
            applicationSupportDirectory: environment.applicationSupport,
            defaultCacheDirectory: environment.cache,
            customCacheDirectoryPath: nil,
            pruneOnInit: false,
            manifestIO: manifestIO
        )
    }

    private func makeEntry(
        itemID: String,
        localPath: String,
        qualityID: String = "height-1080",
        fileSize: Int64? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> VideoCacheEntry {
        VideoCacheEntry(
            itemID: itemID,
            parentID: nil,
            title: "Movie \(itemID)",
            localPath: localPath,
            qualityID: qualityID,
            qualityLabel: "1080p",
            resolution: "1920x1080",
            videoBitrate: 5_000_000,
            fileSize: fileSize,
            createdAt: createdAt
        )
    }
}

private final class RecordingManifestIO: @unchecked Sendable {
    private let lock = NSLock()
    private let initialEntries: [String: VideoCacheEntry]
    private var readRecords: [Bool] = []
    private var writeRecords: [(onBlockingIOQueue: Bool, entries: [String: VideoCacheEntry])] = []

    init(initialEntries: [String: VideoCacheEntry] = [:]) {
        self.initialEntries = initialEntries
    }

    var writeSnapshots: [[String: VideoCacheEntry]] {
        lock.lock()
        defer { lock.unlock() }
        return writeRecords.map(\.entries)
    }

    var didObserveBlockingIOWrite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeRecords.contains { $0.onBlockingIOQueue }
    }

    var allWritesObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !writeRecords.isEmpty && writeRecords.allSatisfy(\.onBlockingIOQueue)
    }

    func io() -> VideoOfflineCacheManifestIO {
        VideoOfflineCacheManifestIO(
            read: { [weak self] _ in
                guard let self else { return [:] }
                lock.lock()
                readRecords.append(BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue())
                let entries = initialEntries
                lock.unlock()
                return entries
            },
            write: { [weak self] entries, _ in
                guard let self else { return }
                lock.lock()
                writeRecords.append((BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue(), entries))
                lock.unlock()
            }
        )
    }
}
