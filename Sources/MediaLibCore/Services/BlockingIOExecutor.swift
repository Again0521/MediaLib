import Foundation

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
    /// 单个慢 NAS 探测不会卡住其他 I/O。使用方数量有限，不会触发线程爆炸。
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
}
