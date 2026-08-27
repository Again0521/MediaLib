import Combine
import Foundation
import MediaLibCore

/// 同步冲突的待处理列表与持久化，从 AppState 抽出（R1-ARCH-001 第 5 步）。
///
/// 职责边界：本 Store 只负责**待处理冲突列表 + 计数的存储**与对 repository 的薄封装
/// （载入 / 保存 / 持久化解决·忽略 / 内存移除）。**冲突的实际处理逻辑**（采用远端时的库内
/// 变更、采用本地时向 Trakt 写回、构造 remote/local mutation、各种提示）仍留在 AppState：
/// 这些涉及 DB 事务原子性（解决的持久化要和库内变更在同一 `database.transaction` 内）与
/// Trakt 网络写回，无法在无运行时验证下安全外移。
///
/// 为此把「持久化」与「内存反映」拆成两步暴露：AppState 在自己的事务内调用
/// `persistResolution`，事务后再调用 `forgetPending` 反映到列表——与原内联代码逐字等价。
@MainActor
final class SyncConflictStore: ObservableObject {
    @Published private(set) var pendingConflicts: [SyncConflict] = []
    @Published private(set) var pendingCount: Int = 0

    private let repository: SyncConflictRepository?

    init(repository: SyncConflictRepository?) {
        self.repository = repository
    }

    /// repository 是否可用——供 AppState 复刻原 `guard let syncConflictRepository else { return }`。
    var isAvailable: Bool { repository != nil }

    // MARK: - 载入

    /// 全量重载（repository 缺失时归零，与原 `?? 0` / `?? []` 一致）。
    func reload() throws {
        pendingCount = try repository?.pendingCount() ?? 0
        pendingConflicts = try repository?.fetchPending(limit: 120) ?? []
    }

    func replaceLoaded(pendingCount: Int, pendingConflicts: [SyncConflict]) {
        self.pendingCount = pendingCount
        self.pendingConflicts = pendingConflicts
    }

    /// Trakt 导入后刷新：repository 缺失时保持原值（与原 `?? self.pendingX` 一致）。
    func refreshFromRepository() throws {
        guard let repository else { return }
        pendingCount = try repository.pendingCount()
        pendingConflicts = try repository.fetchPending(limit: 120)
    }

    // MARK: - 持久化（薄封装，不动内存列表）

    @discardableResult
    func save(_ conflict: SyncConflict) throws -> SyncConflict? {
        guard let repository else { return nil }
        return try repository.save(conflict)
    }

    /// 仅持久化「已解决」——供 AppState 在自己的 DB 事务内调用以保持原子性。
    func persistResolution(id: String, resolution: SyncConflictResolution) throws {
        try repository?.resolve(id: id, resolution: resolution)
    }

    /// 仅持久化「已忽略」。
    func persistIgnore(id: String) throws {
        try repository?.ignore(id: id)
    }

    // MARK: - 内存反映

    /// 从待处理列表移除并递减计数（与原 `removeAll` + `max(0, count - 1)` 一致）。
    func forgetPending(id: String) {
        pendingConflicts.removeAll { $0.id == id }
        pendingCount = max(0, pendingCount - 1)
    }
}
