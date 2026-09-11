import Darwin
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

final class ServerRequestWorkExecutorTests: XCTestCase {
    func testPasswordClassifierCoversEveryHashingMutationWithoutCapturingReads() {
        let passwordTargets = [
            "/login?next=%2Fadmin",
            "/api/v1/auth/login",
            "/api/v1/auth/password",
            "/api/v1/admin/runtime/apply",
            "/api/v1/admin/users",
            "/api/v1/admin/users/member-1/password",
            "/api/v1/admin/backups/backup-1/restore"
        ]
        for target in passwordTargets {
            XCTAssertEqual(ServerRequestWorkKind.classify(method: "POST", target: target), .password, target)
        }
        XCTAssertEqual(
            ServerRequestWorkKind.classify(method: "GET", target: "/api/v1/admin/users"),
            .general
        )
        XCTAssertEqual(
            ServerRequestWorkKind.classify(method: "POST", target: "/api/v1/admin/users/member-1/access"),
            .general
        )
        XCTAssertEqual(
            ServerRequestWorkKind.classify(method: "POST", target: "/api/v1/auth/refresh"),
            .general
        )
    }

    /// This is an explanatory same-process load comparison, not a production p95 claim.
    /// The direct branch reproduces the old LAN path; the bounded branch uses the new
    /// password lane with the same Argon2 parameters and task count.
    func testMeasuredPasswordLoadBoundsConcurrencyAndReportsEnvironment() async throws {
        let taskCount = 12
        let hasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 16_384,
            parallelism: 1,
            randomBytes: { Array(repeating: 0x5a, count: $0) }
        )
        let encoded = try hasher.hash(password: "correct horse battery staple")

        let oldMeter = ConcurrentWorkMeter()
        let oldResources = ProcessResourceSampler()
        let oldStartedAt = ContinuousClock.now
        oldResources.start()
        let oldLatencies = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    _ = await BlockingIOExecutor.run {
                        oldMeter.withWork {
                            hasher.verify(password: "correct horse battery staple", encodedHash: encoded)
                        }
                    }
                    return DispatchTime.now().uptimeNanoseconds - startedAt
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        oldResources.stop()
        let oldElapsed = oldStartedAt.duration(to: ContinuousClock.now)

        let executor = ServerRequestWorkExecutor(passwordLimit: 2, generalLimit: 4)
        let newMeter = ConcurrentWorkMeter()
        let newResources = ProcessResourceSampler()
        let newStartedAt = ContinuousClock.now
        newResources.start()
        let newLatencies = try await withThrowingTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    _ = try await executor.run(kind: .password) {
                        newMeter.withWork {
                            hasher.verify(password: "correct horse battery staple", encodedHash: encoded)
                        }
                    }
                    return DispatchTime.now().uptimeNanoseconds - startedAt
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        newResources.stop()
        let newElapsed = newStartedAt.duration(to: ContinuousClock.now)
        let snapshot = await executor.snapshot()

        XCTAssertEqual(snapshot.password.completed, taskCount)
        XCTAssertEqual(snapshot.password.active, 0)
        XCTAssertEqual(snapshot.password.queued, 0)
        XCTAssertLessThanOrEqual(newMeter.peak, 2)
        XCTAssertLessThanOrEqual(snapshot.password.peakActive, 2)
        XCTAssertGreaterThan(snapshot.password.peakQueued, 0)
        XCTAssertEqual(oldMeter.completed, taskCount)

        let oldPercentiles = latencyPercentiles(oldLatencies)
        let newPercentiles = latencyPercentiles(newLatencies)
        let oldSample = oldResources.snapshot
        let newSample = newResources.snapshot
        print(
            "[B12] env os=\(ProcessInfo.processInfo.operatingSystemVersionString) " +
            "cpus=\(ProcessInfo.processInfo.processorCount) physicalMiB=\(ProcessInfo.processInfo.physicalMemory / 1_048_576)"
        )
        print(
            "[B12] old-direct tasks=\(taskCount) argon2MiB=16 peak=\(oldMeter.peak) " +
            "elapsed=\(format(oldElapsed)) response_p50=\(oldPercentiles.p50)ms " +
            "response_p95=\(oldPercentiles.p95)ms rss_peak_mib=\(oldSample.residentBytes / 1_048_576) " +
            "threads_peak=\(oldSample.threads)"
        )
        print(
            "[B12] new-bounded tasks=\(taskCount) limit=2 peak=\(newMeter.peak) " +
            "elapsed=\(format(newElapsed)) response_p50=\(newPercentiles.p50)ms " +
            "response_p95=\(newPercentiles.p95)ms queue_p50=\(snapshot.password.waitP50Milliseconds)ms " +
            "queue_p95=\(snapshot.password.waitP95Milliseconds)ms rss_peak_mib=\(newSample.residentBytes / 1_048_576) " +
            "threads_peak=\(newSample.threads)"
        )
    }

    func testPasswordQueueDoesNotStarveGeneralLane() async throws {
        let executor = ServerRequestWorkExecutor(passwordLimit: 1, generalLimit: 1)
        let blocker = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let password = Task {
            try await executor.run(kind: .password) {
                entered.signal()
                blocker.wait()
                return true
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let queuedPassword = Task {
            try await executor.run(kind: .password) { true }
        }
        try await waitUntil { (await executor.snapshot()).password.queued == 1 }

        let general = try await executor.run(kind: .general) { 42 }
        XCTAssertEqual(general, 42)
        let during = await executor.snapshot()
        XCTAssertEqual(during.password.active, 1)
        XCTAssertEqual(during.password.queued, 1)
        XCTAssertEqual(during.general.completed, 1)

        blocker.signal()
        let firstValue = try await password.value
        let queuedValue = try await queuedPassword.value
        XCTAssertTrue(firstValue)
        XCTAssertTrue(queuedValue)
    }

    func testCancellingQueuedWorkRemovesWaiterAndNeverRunsClosure() async throws {
        let executor = ServerRequestWorkExecutor(passwordLimit: 1, generalLimit: 1)
        let blocker = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let invocation = ConcurrentWorkMeter()
        let first = Task {
            try await executor.run(kind: .password) {
                entered.signal()
                blocker.wait()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let cancelled = Task {
            try await executor.run(kind: .password) {
                invocation.withWork {}
            }
        }
        try await waitUntil { (await executor.snapshot()).password.queued == 1 }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Queued work should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { (await executor.snapshot()).password.queued == 0 }
        XCTAssertEqual(invocation.completed, 0)

        blocker.signal()
        try await first.value
        let final = await executor.snapshot().password
        XCTAssertEqual(final.active, 0)
        XCTAssertEqual(final.queued, 0)
        XCTAssertEqual(final.completed, 1)
        XCTAssertEqual(final.cancelledWhileQueued, 1)
    }

    func testCancellationDuringActiveAcquisitionReturnsResourceForCallerCleanup() async throws {
        let executor = ServerRequestWorkExecutor(passwordLimit: 1, generalLimit: 1)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let resource = CloseTrackingResource()
        let task = Task {
            let acquired = try await executor.run(kind: .fileRead) {
                entered.signal()
                proceed.wait()
                return resource
            }
            acquired.close()
            try Task.checkCancellation()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        proceed.signal()
        do {
            try await task.value
            XCTFail("Caller should observe cancellation after closing the acquired resource")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(resource.isClosed)
        let snapshot = await executor.snapshot().fileRead
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.completed, 1)
    }

    func testThrownWorkReleasesPermit() async throws {
        enum Expected: Error { case failure }
        let executor = ServerRequestWorkExecutor(passwordLimit: 1, generalLimit: 1)
        do {
            _ = try await executor.run(kind: .general) { () -> Int in throw Expected.failure }
            XCTFail("Expected failure")
        } catch is Expected {
            // Expected.
        }
        let recoveredValue = try await executor.run(kind: .general) { 7 }
        XCTAssertEqual(recoveredValue, 7)
        let snapshot = await executor.snapshot().general
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.completed, 2)
    }

    func testFileAndLongStreamLanesEnforceIndependentCaps() async throws {
        let executor = ServerRequestWorkExecutor(
            passwordLimit: 1,
            generalLimit: 1,
            fileReadLimit: 1,
            mediaStreamLimit: 2
        )
        let fileMeter = ConcurrentWorkMeter()
        let streamMeter = ConcurrentWorkMeter()

        async let files: Void = runBatch(
            count: 5,
            kind: .fileRead,
            executor: executor,
            meter: fileMeter
        )
        async let streams: Void = runBatch(
            count: 6,
            kind: .mediaStream,
            executor: executor,
            meter: streamMeter
        )
        _ = try await (files, streams)

        let snapshot = await executor.snapshot()
        XCTAssertLessThanOrEqual(fileMeter.peak, 1)
        XCTAssertLessThanOrEqual(streamMeter.peak, 2)
        XCTAssertEqual(snapshot.fileRead.completed, 5)
        XCTAssertEqual(snapshot.mediaStream.completed, 6)
        XCTAssertEqual(snapshot.fileRead.active, 0)
        XCTAssertEqual(snapshot.mediaStream.active, 0)
        XCTAssertGreaterThan(snapshot.fileRead.peakQueued, 0)
        XCTAssertGreaterThan(snapshot.mediaStream.peakQueued, 0)
        print(
            "[B12] slow-io file_tasks=5 delay=15ms limit=1 peak=\(fileMeter.peak) " +
            "queue_p50=\(snapshot.fileRead.waitP50Milliseconds)ms " +
            "queue_p95=\(snapshot.fileRead.waitP95Milliseconds)ms; " +
            "stream_tasks=6 delay=15ms limit=2 peak=\(streamMeter.peak) " +
            "queue_p50=\(snapshot.mediaStream.waitP50Milliseconds)ms " +
            "queue_p95=\(snapshot.mediaStream.waitP95Milliseconds)ms"
        )
    }

    private func runBatch(
        count: Int,
        kind: ServerRequestWorkKind,
        executor: ServerRequestWorkExecutor,
        meter: ConcurrentWorkMeter
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await executor.run(kind: kind) {
                        meter.withWork { Thread.sleep(forTimeInterval: 0.015) }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !(await condition()) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("Timed out waiting for executor state")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func latencyPercentiles(_ values: [UInt64]) -> (p50: Int, p95: Int) {
        let sorted = values.sorted()
        func value(_ percentile: Double) -> Int {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
            return Int(sorted[index] / 1_000_000)
        }
        return (value(0.50), value(0.95))
    }

    private func format(_ duration: Duration) -> String {
        let components = duration.components
        return String(format: "%.3fs", Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}

private final class ConcurrentWorkMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var activeStorage = 0
    private var peakStorage = 0
    private var completedStorage = 0

    var peak: Int { lock.withLock { peakStorage } }
    var completed: Int { lock.withLock { completedStorage } }

    func withWork<T>(_ work: () throws -> T) rethrows -> T {
        lock.withLock {
            activeStorage += 1
            peakStorage = max(peakStorage, activeStorage)
        }
        defer {
            lock.withLock {
                activeStorage -= 1
                completedStorage += 1
            }
        }
        return try work()
    }
}

private final class CloseTrackingResource: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool { lock.withLock { closed } }

    func close() {
        lock.withLock { closed = true }
    }
}

private final class ProcessResourceSampler: @unchecked Sendable {
    struct Snapshot {
        let residentBytes: UInt64
        let threads: Int
    }

    private let lock = NSLock()
    private var running = false
    private var peakResidentBytes: UInt64 = 0
    private var peakThreads = 0
    private var task: Task<Void, Never>?

    var snapshot: Snapshot {
        lock.withLock { Snapshot(residentBytes: peakResidentBytes, threads: peakThreads) }
    }

    func start() {
        lock.withLock { running = true }
        task = Task.detached(priority: .utility) { [self] in
            while lock.withLock({ running }) {
                sample()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            sample()
        }
    }

    func stop() {
        lock.withLock { running = false }
        task?.cancel()
        sample()
    }

    private func sample() {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(size)) == Int32(size) else { return }
        lock.withLock {
            peakResidentBytes = max(peakResidentBytes, info.pti_resident_size)
            peakThreads = max(peakThreads, Int(info.pti_threadnum))
        }
    }
}
