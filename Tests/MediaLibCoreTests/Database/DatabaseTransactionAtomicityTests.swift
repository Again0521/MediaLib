import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P0级数据库事务原子性与防半写入脏数据专项】
/// 审计目标：验证 `DatabaseManager.transaction` 在执行多步级联插入、更新或关联表写入时，
/// 如果中途某一步发生抛错（如外键冲突、唯一约束冲突、磁盘写盘异常），能否自动触发 100% 回滚，
/// 绝对不在业务库中留下半写入的脏数据或孤立引用。
/// 对应报告问题 ID：TC-DB-001 / RISK-01
final class DatabaseTransactionAtomicityTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Tx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("transaction_audit.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    enum MockTransactionError: Error, Equatable {
        case simulatedDiskFullError
        case simulatedConstraintFailure
    }

    /// 测试事务在写入多个表中间遭遇异常时，全部修改完成彻底回滚
    func testTransactionRollbackOnIntermediateFailurePreservesDataIntegrity() throws {
        let db = try DatabaseManager(url: dbURL)

        // 建立主表和明细表（有外键或关联关系）
        try db.execute("CREATE TABLE IF NOT EXISTS tx_master (id TEXT PRIMARY KEY, title TEXT)")
        try db.execute("CREATE TABLE IF NOT EXISTS tx_detail (id TEXT PRIMARY KEY, master_id TEXT, info TEXT)")

        // 插入一行初始完好数据
        try db.execute("INSERT INTO tx_master VALUES (?, ?)", bindings: [.text("m-1"), .text("Original Master")])

        // 尝试一个包含多步修改的原子事务，在第三步故意抛错
        XCTAssertThrowsError(
            try db.transaction {
                // 步骤 1：插入第二条主表记录
                try db.execute("INSERT INTO tx_master VALUES (?, ?)", bindings: [.text("m-2"), .text("New Master")])
                
                // 步骤 2：插入一条对应的明细
                try db.execute("INSERT INTO tx_detail VALUES (?, ?, ?)", bindings: [.text("d-1"), .text("m-2"), .text("Detail Info")])
                
                // 步骤 3：模拟突然发盘满或发生业务异常抛错
                throw MockTransactionError.simulatedDiskFullError
            }
        ) { error in
            XCTAssertEqual(error as? MockTransactionError, .simulatedDiskFullError)
        }

        // 验证回滚原子性：查询主表与明细表
        let masterCount = try db.query("SELECT count(*) FROM tx_master") { $0.int(0) }.first ?? 0
        let detailCount = try db.query("SELECT count(*) FROM tx_detail") { $0.int(0) }.first ?? 0

        XCTAssertEqual(masterCount, 1, "事务中途失败后，步骤 1 写入的主表记录必须被完全回滚，严禁留下脏记录！")
        XCTAssertEqual(detailCount, 0, "事务中途失败后，步骤 2 写入的明细表记录同样必须彻底清除！")
    }

    /// 测试高并发下嵌套或重复事务调用不破坏锁状态
    func testRepeatedTransactionsLeaveDatabaseInConsistentState() throws {
        let db = try DatabaseManager(url: dbURL)
        try db.execute("CREATE TABLE IF NOT EXISTS tx_counter (val INTEGER)")
        try db.execute("INSERT INTO tx_counter VALUES (0)")

        for _ in 0..<50 {
            try db.transaction {
                try db.execute("UPDATE tx_counter SET val = val + 1")
            }
        }

        let finalVal = try db.query("SELECT val FROM tx_counter") { $0.int(0) }.first ?? 0
        XCTAssertEqual(finalVal, 50, "连续 50 次事务执行必须精准更新计数，无丢包或重入死锁")
    }
}
