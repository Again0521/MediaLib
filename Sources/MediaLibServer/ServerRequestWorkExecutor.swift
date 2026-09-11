import Foundation
import MediaLibCore

/// Synchronous router work is split into independent budgets so memory-hard
/// password operations cannot occupy every blocking worker needed by light
/// requests. The permits are actor-managed: queued callers suspend without
/// blocking a Swift cooperative thread or creating one GCD waiter per request.
enum ServerRequestWorkKind: String, Sendable {
    case password
    case general
    case fileRead
    case mediaStream

    static func classify(method: String, target: String) -> Self {
        guard method.uppercased() == "POST" else { return .general }
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if path == "/login" ||
            path == "/api/v1/auth/login" ||
            path == "/api/v1/auth/password" ||
            path == "/api/v1/admin/runtime/apply" ||
            path == "/api/v1/admin/users" ||
            (path.hasPrefix("/api/v1/admin/backups/") && path.hasSuffix("/restore")) ||
            (path.hasPrefix("/api/v1/admin/users/") && path.hasSuffix("/password")) {
            return .password
        }
        return .general
    }
}

struct ServerRequestWorkLaneSnapshot: Equatable, Sendable {
    let limit: Int
    let active: Int
    let queued: Int
    let peakActive: Int
    let peakQueued: Int
    let completed: Int
    let cancelledWhileQueued: Int
    let waitP50Milliseconds: Int
    let waitP95Milliseconds: Int
    let maximumWaitMilliseconds: Int
}

struct ServerRequestWorkSnapshot: Equatable, Sendable {
    let password: ServerRequestWorkLaneSnapshot
    let general: ServerRequestWorkLaneSnapshot
    let fileRead: ServerRequestWorkLaneSnapshot
    let mediaStream: ServerRequestWorkLaneSnapshot
}

/// Process-wide budgets are intentionally below the TLS connection cap. Two
/// default Argon2id jobs bound their nominal working memory near 128 MiB, while
/// eight general handlers leave room for response streaming and other service
/// work. Limits are injectable so tests can prove queueing and cancellation.
final class ServerRequestWorkExecutor: @unchecked Sendable {
    static let shared = ServerRequestWorkExecutor()

    private let passwordGate: ServerAsyncWorkGate
    private let generalGate: ServerAsyncWorkGate
    private let fileReadGate: ServerAsyncWorkGate
    private let mediaStreamGate: ServerAsyncWorkGate

    init(
        passwordLimit: Int = 2,
        generalLimit: Int = 8,
        fileReadLimit: Int = 4,
        mediaStreamLimit: Int = 8
    ) {
        precondition(passwordLimit > 0 && generalLimit > 0 && fileReadLimit > 0 && mediaStreamLimit > 0)
        passwordGate = ServerAsyncWorkGate(limit: passwordLimit)
        generalGate = ServerAsyncWorkGate(limit: generalLimit)
        fileReadGate = ServerAsyncWorkGate(limit: fileReadLimit)
        mediaStreamGate = ServerAsyncWorkGate(limit: mediaStreamLimit)
    }

    func run<T: Sendable>(
        kind: ServerRequestWorkKind,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let gate = gate(for: kind)
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await gate.acquire(waiterID: waiterID)
        } onCancel: {
            Task { await gate.cancel(waiterID: waiterID) }
        }
        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            await gate.release()
            throw CancellationError()
        }
        let result: Result<T, Error>
        do {
            result = .success(try await BlockingIOExecutor.run(work))
        } catch {
            result = .failure(error)
        }
        // A synchronous operation already dispatched to GCD cannot be preempted.
        // Release its permit as soon as it returns, but preserve its result so a
        // caller can close any resource it just acquired. Callers observe active
        // cancellation at their next async/cancellation boundary; work still
        // waiting for a permit is cancelled immediately and never executes.
        await gate.release()
        return try result.get()
    }

    func snapshot() async -> ServerRequestWorkSnapshot {
        async let password = passwordGate.snapshot()
        async let general = generalGate.snapshot()
        async let fileRead = fileReadGate.snapshot()
        async let mediaStream = mediaStreamGate.snapshot()
        return await ServerRequestWorkSnapshot(
            password: password,
            general: general,
            fileRead: fileRead,
            mediaStream: mediaStream
        )
    }

    private func gate(for kind: ServerRequestWorkKind) -> ServerAsyncWorkGate {
        switch kind {
        case .password: passwordGate
        case .general: generalGate
        case .fileRead: fileReadGate
        case .mediaStream: mediaStreamGate
        }
    }
}

private actor ServerAsyncWorkGate {
    private struct Waiter {
        let enqueuedAt: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = 0
    private var order: [UUID] = []
    private var waiters: [UUID: Waiter] = [:]
    private var peakActive = 0
    private var peakQueued = 0
    private var completed = 0
    private var cancelledWhileQueued = 0
    private var waitSamplesNanoseconds: [UInt64] = []
    private static let maximumWaitSamples = 256

    init(limit: Int) {
        self.limit = limit
    }

    func acquire(waiterID: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            peakActive = max(peakActive, active)
            recordWait(0)
            return true
        }
        peakQueued = max(peakQueued, waiters.count + 1)
        return await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(returning: false)
                return
            }
            order.append(waiterID)
            waiters[waiterID] = Waiter(
                enqueuedAt: DispatchTime.now().uptimeNanoseconds,
                continuation: continuation
            )
        }
    }

    func cancel(waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        order.removeAll { $0 == waiterID }
        cancelledWhileQueued += 1
        waiter.continuation.resume(returning: false)
    }

    func release() {
        completed += 1
        while !order.isEmpty {
            let waiterID = order.removeFirst()
            guard let waiter = waiters.removeValue(forKey: waiterID) else { continue }
            let now = DispatchTime.now().uptimeNanoseconds
            recordWait(now >= waiter.enqueuedAt ? now - waiter.enqueuedAt : 0)
            // The released permit is transferred directly to this waiter, so
            // `active` does not change and can never exceed the configured cap.
            waiter.continuation.resume(returning: true)
            return
        }
        active = max(0, active - 1)
    }

    func snapshot() -> ServerRequestWorkLaneSnapshot {
        let sorted = waitSamplesNanoseconds.sorted()
        return ServerRequestWorkLaneSnapshot(
            limit: limit,
            active: active,
            queued: waiters.count,
            peakActive: peakActive,
            peakQueued: peakQueued,
            completed: completed,
            cancelledWhileQueued: cancelledWhileQueued,
            waitP50Milliseconds: percentile(sorted, 0.50),
            waitP95Milliseconds: percentile(sorted, 0.95),
            maximumWaitMilliseconds: Int((sorted.last ?? 0) / 1_000_000)
        )
    }

    private func recordWait(_ nanoseconds: UInt64) {
        if waitSamplesNanoseconds.count == Self.maximumWaitSamples {
            waitSamplesNanoseconds.removeFirst()
        }
        waitSamplesNanoseconds.append(nanoseconds)
    }

    private func percentile(_ sorted: [UInt64], _ percentile: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
        return Int(sorted[index] / 1_000_000)
    }
}
