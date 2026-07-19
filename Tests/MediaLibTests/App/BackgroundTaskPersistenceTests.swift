import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class BackgroundTaskPersistenceTests: XCTestCase {
    private actor WriteRecorder {
        private(set) var calls: [[String]] = []
        private(set) var errorCount = 0

        func record(_ tasks: [BackgroundTaskSnapshot]) {
            calls.append(tasks.map(\.title))
        }

        func recordError() {
            errorCount += 1
        }

        func recordedCalls() -> [[String]] {
            calls
        }

        func recordedErrorCount() -> Int {
            errorCount
        }
    }

    private func task(
        title: String,
        state: BackgroundTaskState = .running,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> BackgroundTaskSnapshot {
        BackgroundTaskSnapshot(
            kind: .cleanup,
            state: state,
            title: title,
            detail: nil,
            progress: nil,
            startedAt: startedAt,
            isCancellable: true
        )
    }

    func testPersistedSnapshotKeepsNewestSixtyTasks() {
        let tasks = (0..<75).map { task(title: "task-\($0)") }

        let persisted = BackgroundTaskPersistence.persistedSnapshot(from: tasks)

        XCTAssertEqual(persisted.count, 60)
        XCTAssertEqual(persisted.first?.title, "task-0")
        XCTAssertEqual(persisted.last?.title, "task-59")
    }

    func testEncodedDataRoundTripsAndUsesPersistedLimit() throws {
        let tasks = (0..<62).map { task(title: "task-\($0)") }

        let data = try BackgroundTaskPersistence.encodedData(for: tasks)
        let decoded = try BackgroundTaskPersistence.decodedTasks(from: data)

        XCTAssertEqual(decoded.count, 60)
        XCTAssertEqual(decoded.map(\.title), (0..<60).map { "task-\($0)" })
    }

    func testWriteAndLoadRunThroughSharedPersistencePath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-persistence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let tasks = [task(title: "cleanup", state: .completed)]

        try await BackgroundTaskPersistence.write(tasks, to: url)
        let loadedResult = await BackgroundTaskPersistence.load(from: url)
        let loaded = try XCTUnwrap(loadedResult)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "cleanup")
        XCTAssertEqual(loaded[0].state, .completed)
    }

    func testAsyncReadWriteRunThroughInjectedIOOnBlockingIOQueue() async throws {
        let recorder = RecordingBackgroundTaskPersistenceIO()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-persistence-io-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let tasks = [task(title: "blocking-io", state: .completed)]

        try await BackgroundTaskPersistence.write(tasks, to: url, io: recorder.io())
        let loadedResult = await BackgroundTaskPersistence.load(from: url, io: recorder.io())
        let loaded = try XCTUnwrap(loadedResult)

        XCTAssertEqual(loaded.map(\.title), ["blocking-io"])
        XCTAssertEqual(recorder.operationNames, ["write", "read"])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    func testLoadResultDistinguishesMissingURLReadFailureAndCorruptJSON() async throws {
        struct TestReadError: Error {}

        let missingResult = await BackgroundTaskPersistence.loadResult(
            from: nil,
            io: BackgroundTaskPersistence.IO(
                read: { _ in Data() },
                write: { _, _ in }
            )
        )
        if case .missingURL = missingResult {
        } else {
            XCTFail("Expected nil persistence URL to be reported as missingURL")
        }

        let failingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-read-failure-\(UUID().uuidString).json")
        let failingIO = BackgroundTaskPersistence.IO(
            read: { _ in throw TestReadError() },
            write: { _, _ in }
        )
        let readFailure = await BackgroundTaskPersistence.loadResult(from: failingURL, io: failingIO)
        guard case let .failed(readError) = readFailure else {
            return XCTFail("Expected read failure to be observable")
        }
        XCTAssertEqual(readError.operation, "read")
        XCTAssertEqual(readError.path, failingURL.path)
        XCTAssertFalse(readError.message.isEmpty)

        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-corrupt-\(UUID().uuidString).json")
        let corruptIO = BackgroundTaskPersistence.IO(
            read: { _ in Data("{not-json".utf8) },
            write: { _, _ in }
        )
        let corruptResult = await BackgroundTaskPersistence.loadResult(from: corruptURL, io: corruptIO)
        guard case let .failed(decodeError) = corruptResult else {
            return XCTFail("Expected corrupt JSON to be observable")
        }
        XCTAssertEqual(decodeError.operation, "decode")
        XCTAssertEqual(decodeError.path, corruptURL.path)
        XCTAssertFalse(decodeError.message.isEmpty)
        let compatibilityLoadResult = await BackgroundTaskPersistence.load(from: corruptURL, io: corruptIO)
        XCTAssertNil(compatibilityLoadResult)
    }

    func testWriteToDirectoryReportsFailure() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-persistence-dir-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try await BackgroundTaskPersistence.write([task(title: "bad-path")], to: directory)
            XCTFail("Expected writing JSON to a directory URL to fail")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func testSchedulerDebouncesAndWritesOnlyLatestSnapshot() async throws {
        let recorder = WriteRecorder()
        let scheduler = BackgroundTaskPersistenceScheduler(
            debounceNanoseconds: 50_000_000,
            writer: { tasks, _ in
                await recorder.record(tasks)
            }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-scheduler-\(UUID().uuidString).json")

        scheduler.schedule([task(title: "first")], to: url)
        scheduler.schedule([task(title: "second")], to: url)

        // 轮询而非单次固定 sleep：CI 共享 runner 的调度抖动可能让 50ms 防抖窗口
        // 之上的固定 140ms 余量不够，导致断言时写入还没发生（非真实回归）。
        var calls: [[String]] = []
        for _ in 0..<50 {
            calls = await recorder.recordedCalls()
            if !calls.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(calls, [["second"]])
    }

    func testSchedulerImmediateFlushDoesNotWaitForDebounceWindow() async throws {
        let recorder = WriteRecorder()
        let scheduler = BackgroundTaskPersistenceScheduler(
            debounceNanoseconds: 5_000_000_000,
            writer: { tasks, _ in
                await recorder.record(tasks)
            }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-immediate-\(UUID().uuidString).json")

        scheduler.schedule([task(title: "done", state: .completed)], to: url, immediate: true)
        try await Task.sleep(nanoseconds: 80_000_000)

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls, [["done"]])
    }

    func testSchedulerReportsWriterFailure() async throws {
        struct TestWriteError: Error {}

        let recorder = WriteRecorder()
        let scheduler = BackgroundTaskPersistenceScheduler(
            debounceNanoseconds: 0,
            writer: { _, _ in
                throw TestWriteError()
            },
            onError: { _ in
                Task {
                    await recorder.recordError()
                }
            }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-task-error-\(UUID().uuidString).json")

        scheduler.schedule([task(title: "will-fail")], to: url, immediate: true)
        try await Task.sleep(nanoseconds: 80_000_000)

        let errorCount = await recorder.recordedErrorCount()
        XCTAssertEqual(errorCount, 1)
    }
}

private final class RecordingBackgroundTaskPersistenceIO: @unchecked Sendable {
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

    func io() -> BackgroundTaskPersistence.IO {
        BackgroundTaskPersistence.IO(
            read: { [weak self] url in
                self?.record("read")
                return try Data(contentsOf: url)
            },
            write: { [weak self] data, url in
                self?.record("write")
                try data.write(to: url, options: [.atomic])
            }
        )
    }

    private func record(_ name: String) {
        lock.lock()
        records.append((name, BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()))
        lock.unlock()
    }
}
