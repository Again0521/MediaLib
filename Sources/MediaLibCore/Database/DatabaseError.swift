import Foundation

public enum DatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case invalidColumn(String)
    case backupFailed(String)
    case integrityCheckFailed(String)
    case incompatibleSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "数据库打开失败：\(message)"
        case .prepareFailed(let message): return "SQL 编译失败：\(message)"
        case .stepFailed(let message): return "SQL 执行失败：\(message)"
        case .bindFailed(let message): return "SQL 参数绑定失败：\(message)"
        case .invalidColumn(let name): return "数据库字段无效：\(name)"
        case .backupFailed(let message): return "数据库备份或恢复失败：\(message)"
        case .integrityCheckFailed(let message): return "数据库完整性检查失败：\(message)"
        case .incompatibleSchema(let found, let supported):
            return "备份数据库版本 \(found) 高于当前软件支持的版本 \(supported)，无法恢复。"
        }
    }
}
