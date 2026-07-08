import XCTest
@testable import MediaLibCore

final class FileAccessServiceAsyncTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testReachableDirectoryAsyncReturnsTrueForExistingDirectory() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let reachable = await FileAccessService.isReachableDirectoryAsync(directory.path)

        XCTAssertTrue(reachable)
    }

    func testReachableDirectoryAsyncReturnsFalseForMissingPathAndRegularFile() async throws {
        let root = try temporaryDirectory()
        let fileURL = root.appendingPathComponent("not-a-directory.txt")
        let missingURL = root.appendingPathComponent("missing", isDirectory: true)
        try Data("file".utf8).write(to: fileURL)

        let fileReachable = await FileAccessService.isReachableDirectoryAsync(fileURL.path)
        let missingReachable = await FileAccessService.isReachableDirectoryAsync(missingURL.path)

        XCTAssertFalse(fileReachable)
        XCTAssertFalse(missingReachable)
    }

    func testConcurrentReachableDirectoryAsyncChecksRemainStable() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Concurrent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await FileAccessService.isReachableDirectoryAsync(directory.path)
                }
            }

            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, 64)
        XCTAssertTrue(results.allSatisfy { $0 })
    }

    func testAppDirectoriesCreatesExpectedHierarchyThroughInjectedIO() throws {
        let root = try temporaryDirectory()
        let supportBase = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let cacheBase = root.appendingPathComponent("Caches", isDirectory: true)
        let io = AppDirectoryIO(
            urlForDirectory: { directory in
                switch directory {
                case .applicationSupportDirectory:
                    return supportBase
                case .cachesDirectory:
                    return cacheBase
                default:
                    XCTFail("Unexpected app directory lookup: \(directory)")
                    return root
                }
            },
            createDirectory: { directory in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        )

        let directories = try FileAccessService.appDirectories(io: io)

        XCTAssertEqual(directories.applicationSupport.path, supportBase.appendingPathComponent("MediaLib", isDirectory: true).path)
        XCTAssertEqual(directories.cache.path, cacheBase.appendingPathComponent("MediaLib", isDirectory: true).path)
        XCTAssertEqual(directories.database.path, directories.applicationSupport.appendingPathComponent("MediaLib.sqlite").path)
        XCTAssertEqual(directories.databaseBackups.path, directories.applicationSupport.appendingPathComponent("DatabaseBackups", isDirectory: true).path)
        XCTAssertEqual(directories.thumbnails.path, directories.cache.appendingPathComponent("Thumbnails", isDirectory: true).path)
        XCTAssertEqual(directories.previewFrames.path, directories.cache.appendingPathComponent("PreviewFrames", isDirectory: true).path)
        XCTAssertEqual(directories.logs.path, directories.applicationSupport.appendingPathComponent("Logs", isDirectory: true).path)
        for directory in [
            directories.applicationSupport,
            directories.cache,
            directories.databaseBackups,
            directories.thumbnails,
            directories.previewFrames,
            directories.logs
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Expected \(directory.path) to be created")
        }
    }

    func testAppDirectoriesAsyncRunsLookupAndCreationOnBlockingIOQueue() async throws {
        let recorder = RecordingAppDirectoryIO(root: try temporaryDirectory())

        let directories = try await FileAccessService.appDirectoriesAsync(io: recorder.io())

        XCTAssertEqual(directories.applicationSupport.path, recorder.expectedApplicationSupport.path)
        XCTAssertEqual(directories.cache.path, recorder.expectedCache.path)
        XCTAssertEqual(recorder.urlLookupCount, 2)
        XCTAssertEqual(recorder.createdPaths, [
            recorder.expectedApplicationSupport.path,
            recorder.expectedCache.path,
            recorder.expectedThumbnails.path,
            recorder.expectedPreviewFrames.path,
            recorder.expectedLogs.path,
            recorder.expectedDatabaseBackups.path
        ])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    func testAppDirectoriesAsyncPropagatesDirectoryLookupErrors() async throws {
        struct TestDirectoryLookupError: Error, Equatable {}
        let root = try temporaryDirectory()
        let io = AppDirectoryIO(
            urlForDirectory: { directory in
                if directory == .cachesDirectory {
                    throw TestDirectoryLookupError()
                }
                return root
            },
            createDirectory: { _ in }
        )

        do {
            _ = try await FileAccessService.appDirectoriesAsync(io: io)
            XCTFail("Expected async app directory lookup to throw")
        } catch let error as TestDirectoryLookupError {
            XCTAssertEqual(error, TestDirectoryLookupError())
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func temporaryDirectory() throws -> URL {
        if let tempDirectory {
            return tempDirectory
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileAccessServiceAsyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectory = root
        return root
    }
}

private final class RecordingAppDirectoryIO: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var records: [(operation: String, onBlockingIOQueue: Bool)] = []
    private var created: [String] = []

    init(root: URL) {
        self.root = root
    }

    var expectedApplicationSupport: URL {
        root
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent("MediaLib", isDirectory: true)
    }

    var expectedCache: URL {
        root
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("MediaLib", isDirectory: true)
    }

    var expectedThumbnails: URL {
        expectedCache.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    var expectedPreviewFrames: URL {
        expectedCache.appendingPathComponent("PreviewFrames", isDirectory: true)
    }

    var expectedLogs: URL {
        expectedApplicationSupport.appendingPathComponent("Logs", isDirectory: true)
    }

    var expectedDatabaseBackups: URL {
        expectedApplicationSupport.appendingPathComponent("DatabaseBackups", isDirectory: true)
    }

    var urlLookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.operation.hasPrefix("url:") }.count
    }

    var createdPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return created
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

    func io() -> AppDirectoryIO {
        AppDirectoryIO(
            urlForDirectory: { [weak self] directory in
                guard let self else { return URL(fileURLWithPath: "/tmp", isDirectory: true) }
                record("url:\(directory)")
                switch directory {
                case .applicationSupportDirectory:
                    return root.appendingPathComponent("ApplicationSupport", isDirectory: true)
                case .cachesDirectory:
                    return root.appendingPathComponent("Caches", isDirectory: true)
                default:
                    XCTFail("Unexpected app directory lookup: \(directory)")
                    return root
                }
            },
            createDirectory: { [weak self] directory in
                guard let self else { return }
                record("create:\(directory.path)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                lock.lock()
                created.append(directory.path)
                lock.unlock()
            }
        )
    }

    private func record(_ operation: String) {
        lock.lock()
        records.append((operation, BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()))
        lock.unlock()
    }
}
