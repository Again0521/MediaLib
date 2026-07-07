import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级视频手动集合管理与去重排序专项】
/// 审计目标：验证 `VideoManualCollectionRepository` 在进行集合保存 (`save`)、
/// 添加影片及重排序时，能够自动进行 ID 去重并保证 position 顺序索引的连续性与原子性。
/// 对应报告问题 ID：TC-DB-001 / RISK-08
final class VideoManualCollectionAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-ManualCol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("manual_collection_audit.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    private func seedMediaItems(db: DatabaseManager, ids: [String]) throws {
        for id in ids {
            try db.execute("INSERT OR IGNORE INTO media_items (id, type, title) VALUES (?, ?, ?)", bindings: [.text(id), .text("movie"), .text("Title \(id)")])
        }
    }

    /// 测试手动集合创建与修改时，重复视频 ID 的去重以及更新时间戳维护
    func testManualCollectionSaveDeduplicatesItemsAndUpdatesTimestamp() throws {
        let db = try DatabaseManager(url: dbURL)
        try seedMediaItems(db: db, ids: ["mov-1", "mov-2", "mov-3", "mov-4"])
        let repo = VideoManualCollectionRepository(database: db)

        let initialTime = Date(timeIntervalSince1970: 1000000)
        var col = VideoManualCollection(
            id: "col-1",
            name: "科幻神作",
            itemIDs: ["mov-1", "mov-2", "mov-3", "mov-2", "mov-1", "mov-4"],
            showOnHome: true,
            createdAt: initialTime,
            updatedAt: initialTime
        )

        let saved = try repo.save(col)
        XCTAssertEqual(saved.itemIDs, ["mov-1", "mov-2", "mov-3", "mov-4"], "保存手动集合时必须自动去重")
        XCTAssertGreaterThan(saved.updatedAt.timeIntervalSince1970, initialTime.timeIntervalSince1970, "修改集合后 updatedAt 必须自动刷新")

        // 查询持久化结果
        let fetched = try repo.fetch(id: "col-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.itemIDs, ["mov-1", "mov-2", "mov-3", "mov-4"])
        XCTAssertEqual(fetched?.showOnHome, true)
    }

    /// 测试集合重命名与顺序调整后，列表加载能保持严格顺序
    func testManualCollectionReorderingPersistsExactSequence() throws {
        let db = try DatabaseManager(url: dbURL)
        try seedMediaItems(db: db, ids: ["a", "b", "c", "d"])
        let repo = VideoManualCollectionRepository(database: db)

        var col = VideoManualCollection(id: "col-2", name: "周末片单", itemIDs: ["a", "b", "c", "d"])
        _ = try repo.save(col)

        // 用户将尾部的 "d" 拖拽排序到最前面，并将 "b" 移到末尾
        col.itemIDs = ["d", "a", "c", "b"]
        _ = try repo.save(col)

        let reloaded = try repo.fetch(id: "col-2")
        XCTAssertEqual(reloaded?.itemIDs, ["d", "a", "c", "b"], "手动集合在重新排序保存后，必须准确还原用户自定义的先后顺序")
    }
}
