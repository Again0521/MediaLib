import Foundation

/// Cancellation is carried across the Task -> GCD boundary explicitly. A
/// DispatchQueue closure does not inherit the waiting Task's cancellation.
public final class BlockingIOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let enqueuedAt = DispatchTime.now().uptimeNanoseconds
    private var startedAt: UInt64?

    fileprivate func markStarted() {
        lock.lock()
        startedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    /// Time spent waiting for the GCD closure to start. Zero until it starts.
    public var queueWaitNanoseconds: UInt64 {
        lock.lock()
        let startedAt = startedAt
        lock.unlock()
        guard let startedAt else { return 0 }
        return startedAt >= enqueuedAt ? startedAt - enqueuedAt : 0
    }

    fileprivate func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
    }
}

/// 阻塞式 I/O 的专用执行器。
///
/// Swift 并发的全局协作线程池宽度只有 CPU 核数，且被阻塞的线程无法被抢占。
/// 全库文件存在性检查（数万次 stat）、SQLite 全量读取、NAS 可达性探测这类
/// **长时间同步阻塞**的工作如果用 `Task.detached` 丢进协作池，会把池线程占死，
/// 让同池排队的轻量任务（如音乐列表快照构建、首页看板计算）等待数秒才能开跑——
/// 这正是"音乐子页面长时间载入"的根因。此类工作必须改经这里的 GCD 队列执行，
/// 协作池只留给真正的 CPU 计算与 async 挂起点。
public enum BlockingIOExecutor {
    private static let queueSpecificKey = DispatchSpecificKey<String>()
    private static let queueSpecificValue = "MediaLib.blockingIO"

    /// 并发队列：互不相关的阻塞 I/O（健康检查、封面清点、可达性探测）可以并行，
    /// 单个慢 NAS 探测不会卡住其他 I/O。此底层桥接器本身不提供并发上限；面向网络
    /// 或其它无界输入的调用方必须先经过自己的异步许可门，不能把排队工作直接提交到 GCD。
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(
            label: queueSpecificValue,
            qos: .utility,
            attributes: .concurrent
        )
        queue.setSpecific(key: queueSpecificKey, value: queueSpecificValue)
        return queue
    }()

    static func isCurrentExecutionOnBlockingIOQueue() -> Bool {
        DispatchQueue.getSpecific(key: queueSpecificKey) == queueSpecificValue
    }

    /// 在专用队列上执行阻塞工作并 await 结果；调用方所在执行器（含 MainActor）
    /// 只是挂起等待，不占任何协作池线程。
    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// 可抛错版本。
    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Cancellation before the GCD work starts prevents it from running. Once
    /// started, synchronous work is cooperative: call `checkCancellation()`
    /// between bounded operations before publishing a result or side effect.
    public static func runCancellable<T: Sendable>(
        _ work: @escaping @Sendable (BlockingIOCancellation) throws -> T
    ) async throws -> T {
        try await runCancellable(on: queue, work)
    }

    static func runCancellable<T: Sendable>(
        on executionQueue: DispatchQueue,
        _ work: @escaping @Sendable (BlockingIOCancellation) throws -> T
    ) async throws -> T {
        let cancellation = BlockingIOCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                executionQueue.async {
                    continuation.resume(with: Result {
                        cancellation.markStarted()
                        try cancellation.checkCancellation()
                        return try work(cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
