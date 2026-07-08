import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class ArtworkWarmupProgressStoreTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testPersistLoadAndRecordRoundTripsSortedCompletedURLs() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ArtworkWarmupProgress.json")

        try await ArtworkWarmupProgressStore.persist(
            sourceID: "emby-source",
            completedURLs: [
                "https://media.example.test/posters/b.jpg",
                "https://media.example.test/posters/a.jpg"
            ],
            totalCount: 4,
            to: fileURL
        )

        let records = await ArtworkWarmupProgressStore.load(from: fileURL)
        let record = try XCTUnwrap(records["emby-source"])
        XCTAssertEqual(record.sourceID, "emby-source")
        XCTAssertEqual(
            record.completedURLs,
            [
                "https://media.example.test/posters/a.jpg",
                "https://media.example.test/posters/b.jpg"
            ]
        )
        XCTAssertEqual(record.totalCount, 4)
        XCTAssertNotNil(record.updatedAt)

        let directRecord = await ArtworkWarmupProgressStore.record(for: "emby-source", from: fileURL)
        XCTAssertEqual(directRecord, record)
    }

    func testLoadReturnsEmptyDictionaryForMissingOrCorruptedFile() async throws {
        let directory = try makeTemporaryDirectory()
        let missingURL = directory.appendingPathComponent("missing.json")

        let missingRecords = await ArtworkWarmupProgressStore.load(from: missingURL)

        XCTAssertTrue(missingRecords.isEmpty)

        let corruptedURL = directory.appendingPathComponent("corrupted.json")
        try "{\"source\":".write(to: corruptedURL, atomically: true, encoding: .utf8)

        let corruptedRecords = await ArtworkWarmupProgressStore.load(from: corruptedURL)

        XCTAssertTrue(corruptedRecords.isEmpty)
    }

    func testClearRemovesOnlyRequestedRecordAndDeletesEmptyFile() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ArtworkWarmupProgress.json")
        try await ArtworkWarmupProgressStore.persist(
            sourceID: "source-a",
            completedURLs: ["a"],
            totalCount: 2,
            to: fileURL
        )
        try await ArtworkWarmupProgressStore.persist(
            sourceID: "source-b",
            completedURLs: ["b"],
            totalCount: 3,
            to: fileURL
        )

        let removedA = try await ArtworkWarmupProgressStore.clear(sourceID: "source-a", from: fileURL)

        XCTAssertTrue(removedA)
        var records = await ArtworkWarmupProgressStore.load(from: fileURL)
        XCTAssertNil(records["source-a"])
        XCTAssertEqual(records["source-b"]?.completedURLs, ["b"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let missingRemoved = try await ArtworkWarmupProgressStore.clear(sourceID: "missing", from: fileURL)
        XCTAssertFalse(missingRemoved)

        let removedB = try await ArtworkWarmupProgressStore.clear(sourceID: "source-b", from: fileURL)

        XCTAssertTrue(removedB)
        records = await ArtworkWarmupProgressStore.load(from: fileURL)
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveEmptyRecordsDeletesExistingFile() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ArtworkWarmupProgress.json")
        try await ArtworkWarmupProgressStore.persist(
            sourceID: "source",
            completedURLs: ["done"],
            totalCount: 1,
            to: fileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try await ArtworkWarmupProgressStore.save([:], to: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveEmptyRecordsPropagatesExistingFileRemoveFailure() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ArtworkWarmupProgress.json")
        try await ArtworkWarmupProgressStore.persist(
            sourceID: "source",
            completedURLs: ["done"],
            totalCount: 1,
            to: fileURL
        )
        let failingIO = removeFailingIO(existingURL: fileURL)

        do {
            try await ArtworkWarmupProgressStore.save([:], to: fileURL, io: failingIO)
            XCTFail("Expected removing an existing progress file to fail")
        } catch TestIOError.removeFailed {
        } catch {
            XCTFail("Expected TestIOError.removeFailed, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let records = await ArtworkWarmupProgressStore.load(from: fileURL)
        XCTAssertEqual(records["source"]?.completedURLs, ["done"])
    }

    func testClearPropagatesRemoveFailureForLastRecord() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ArtworkWarmupProgress.json")
        try await ArtworkWarmupProgressStore.persist(
            sourceID: "source",
            completedURLs: ["done"],
            totalCount: 1,
            to: fileURL
        )
        let failingIO = removeFailingIO(existingURL: fileURL)

        do {
            _ = try await ArtworkWarmupProgressStore.clear(sourceID: "source", from: fileURL, io: failingIO)
            XCTFail("Expected clearing the last record to fail when the progress file cannot be removed")
        } catch TestIOError.removeFailed {
        } catch {
            XCTFail("Expected TestIOError.removeFailed, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let records = await ArtworkWarmupProgressStore.load(from: fileURL)
        XCTAssertEqual(records["source"]?.completedURLs, ["done"])
    }

    func testRemoveFileReportsMissingSuccessAndRemoveFailure() async throws {
        let directory = try makeTemporaryDirectory()
        let missingURL = directory.appendingPathComponent("missing.json")
        let existingURL = directory.appendingPathComponent("ArtworkWarmupProgress.json")
        try Data("{}".utf8).write(to: existingURL)
        let failingIO = removeFailingIO(existingURL: existingURL)

        let missingRemoved = await ArtworkWarmupProgressStore.removeFile(at: missingURL, io: failingIO)
        let existingRemoved = await ArtworkWarmupProgressStore.removeFile(at: existingURL, io: failingIO)
        let nilRemoved = await ArtworkWarmupProgressStore.removeFile(at: nil, io: failingIO)

        XCTAssertTrue(missingRemoved)
        XCTAssertFalse(existingRemoved)
        XCTAssertFalse(nilRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingURL.path))
    }

    func testAsyncPersistenceOperationsRunThroughInjectedIOOnBlockingIOQueue() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ArtworkWarmupProgress.json")
        let recorder = RecordingArtworkWarmupProgressIO()

        try await ArtworkWarmupProgressStore.persist(
            sourceID: "source",
            completedURLs: ["b", "a"],
            totalCount: 2,
            to: fileURL,
            io: recorder.io()
        )
        let records = await ArtworkWarmupProgressStore.load(from: fileURL, io: recorder.io())
        let removed = try await ArtworkWarmupProgressStore.clear(sourceID: "source", from: fileURL, io: recorder.io())

        XCTAssertEqual(records["source"]?.completedURLs, ["a", "b"])
        XCTAssertTrue(removed)
        XCTAssertEqual(recorder.operationNames, ["read", "write", "read", "read", "remove"])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkWarmupProgressStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }

    private func removeFailingIO(existingURL: URL) -> ArtworkWarmupProgressStore.IO {
        ArtworkWarmupProgressStore.IO(
            read: { url in
                try Data(contentsOf: url)
            },
            write: { data, url in
                try data.write(to: url, options: [.atomic])
            },
            remove: { _ in
                throw TestIOError.removeFailed
            },
            exists: { url in
                url == existingURL
            }
        )
    }
}

private enum TestIOError: Error {
    case removeFailed
}

private final class RecordingArtworkWarmupProgressIO: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(name: String, onBlockingIOQueue: Bool)] = []

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

    func io() -> ArtworkWarmupProgressStore.IO {
        ArtworkWarmupProgressStore.IO(
            read: { [weak self] url in
                self?.record("read")
                return try Data(contentsOf: url)
            },
            write: { [weak self] data, url in
                self?.record("write")
                try data.write(to: url, options: [.atomic])
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
