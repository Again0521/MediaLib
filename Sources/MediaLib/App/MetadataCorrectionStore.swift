import Combine
import Foundation
import MediaLibCore

/// 元数据校正记录的统计与撤销账本，从 AppState 抽出（R1-ARCH-001 第 6 步）。
///
/// 职责边界：本 Store 只负责**校正计数 / 记录数 / 可撤销批次列表的存储**与对 repository 的薄封装。
/// 撤销的**实际逆向写库**（`mediaRepository.restoreMetadataValues` 与 `markBatchUndone` 在同一
/// `database.transaction` 内，保原子性）仍留在 AppState；故把「持久化」与「内存反映」拆两步暴露：
/// AppState 在自己的事务内调用 `persistBatchUndone` / `persistRecord`，再用 `noteRecorded` 反映计数。
///
/// 行为逐字搬自原 AppState 的 metadataCorrection 相关方法。
@MainActor
final class MetadataCorrectionStore: ObservableObject {
    @Published private(set) var countsByMediaID: [String: Int] = [:]
    @Published private(set) var recordCount: Int = 0
    @Published private(set) var batches: [MetadataCorrectionBatchSummary] = []

    private let repository: MetadataCorrectionRepository?

    init(repository: MetadataCorrectionRepository?) {
        self.repository = repository
    }

    /// repository 是否可用——供 AppState 复刻原 `guard let metadataCorrectionRepository else { return }`。
    var isAvailable: Bool { repository != nil }

    // MARK: - 载入

    /// 全量重载（repository 缺失时归零，与原 `?? [:]` / `?? 0` / `?? []` 一致）。
    func reload() throws {
        countsByMediaID = try repository?.activeCountsByMediaID() ?? [:]
        recordCount = try repository?.activeRecordCount() ?? 0
        batches = try repository?.fetchActiveBatches(limit: 120) ?? []
    }

    func replaceLoaded(
        countsByMediaID: [String: Int],
        recordCount: Int,
        batches: [MetadataCorrectionBatchSummary]
    ) {
        self.countsByMediaID = countsByMediaID
        self.recordCount = recordCount
        self.batches = batches
    }

    func correctionCount(forMediaID id: String) -> Int {
        countsByMediaID[id] ?? 0
    }

    // MARK: - 读透传（供 AppState 撤销流程取批次记录）

    func latestUndoableBatch(mediaID: String) throws -> [MetadataCorrectionRecord] {
        try repository?.latestUndoableBatch(mediaID: mediaID) ?? []
    }

    func records(batchID: String, mediaID: String) throws -> [MetadataCorrectionRecord] {
        try repository?.records(batchID: batchID, mediaID: mediaID) ?? []
    }

    // MARK: - 持久化（薄封装，不动内存计数）

    /// 仅标记批次已撤销——供 AppState 在自己的事务内调用以保持原子性。
    func persistBatchUndone(batchID: String) throws {
        try repository?.markBatchUndone(batchID: batchID)
    }

    /// 仅落库新校正记录（与原 `metadataCorrectionRepository?.record(...)` 的 optional 行为一致）。
    func persistRecord(mediaID: String, changes: [MetadataCorrectionFieldChange], source: String) throws {
        _ = try repository?.record(mediaID: mediaID, changes: changes, source: source)
    }

    // MARK: - 内存反映

    /// 记录新增后递增计数（与原 `countsByMediaID[id] += n` + `recordCount += n` 一致）。
    func noteRecorded(mediaID: String, changeCount: Int) {
        countsByMediaID[mediaID] = (countsByMediaID[mediaID] ?? 0) + changeCount
        recordCount += changeCount
    }
}
