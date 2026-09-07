import Foundation

public struct DatabaseContentionConfiguration: Equatable, Sendable {
    public static let `default` = Self()

    public let lockWaitMilliseconds: Int32
    public let backupStepWaitMilliseconds: Int32
    public let retrySleepMilliseconds: Int32

    public init(
        lockWaitMilliseconds: Int = 1_000,
        backupStepWaitMilliseconds: Int = 1_000,
        retrySleepMilliseconds: Int = 10
    ) {
        self.lockWaitMilliseconds = Int32(min(max(lockWaitMilliseconds, 0), 60_000))
        self.backupStepWaitMilliseconds = Int32(min(max(backupStepWaitMilliseconds, 0), 60_000))
        self.retrySleepMilliseconds = Int32(min(max(retrySleepMilliseconds, 1), 100))
    }
}

public struct DatabaseContentionMetrics: Equatable, Sendable {
    public let contentionCount: Int
    public let waitedMilliseconds: Int64
    public let timeoutCount: Int
}

public enum DatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case invalidColumn(String)
    case backupFailed(String)
    case integrityCheckFailed(String)
    /// SQLite 写锁竞争。operation 只能是代码内固定标签，不包含 SQL 或文件路径。
    case contention(operation: String, code: Int32, extendedCode: Int32)
    case incompatibleSchema(found: Int, supported: Int)
    /// 启动时打开的主数据库版本高于当前应用支持的版本（通常是 App 比数据旧）。
    /// 数据未受影响，更新到最新版应用即可打开——区别于备份恢复的 incompatibleSchema。
    case databaseNewerThanApp(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "数据库打开失败：\(message)"
        case .prepareFailed(let message): return "SQL 编译失败：\(message)"
        case .stepFailed(let message): return "SQL 执行失败：\(message)"
        case .bindFailed(let message): return "SQL 参数绑定失败：\(message)"
        case .invalidColumn(let name): return "数据库字段无效：\(name)"
        case .backupFailed(let message): return "数据库备份或恢复失败：\(message)"
        case .integrityCheckFailed(let message): return "数据库完整性检查失败：\(message)"
        case .contention:
            return "数据库正忙，请稍后重试。"
        case .incompatibleSchema(let found, let supported):
            return "备份数据库版本 \(found) 高于当前软件支持的版本 \(supported)，无法恢复。"
        case .databaseNewerThanApp(let found, let supported):
            return "数据库版本 \(found) 由更新版本的 MediaLIB 创建，高于当前应用支持的版本 \(supported)。"
                + "你的数据未受影响，请更新到最新版 MediaLIB 后再打开（可能是启动了旧版本应用）。"
        }
    }

    public var isRetryableContention: Bool {
        guard case .contention = self else { return false }
        return true
    }
}
