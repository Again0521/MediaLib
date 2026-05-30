import Foundation

public enum DatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case invalidColumn(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "数据库打开失败：\(message)"
        case .prepareFailed(let message): return "SQL 编译失败：\(message)"
        case .stepFailed(let message): return "SQL 执行失败：\(message)"
        case .bindFailed(let message): return "SQL 参数绑定失败：\(message)"
        case .invalidColumn(let name): return "数据库字段无效：\(name)"
        }
    }
}
