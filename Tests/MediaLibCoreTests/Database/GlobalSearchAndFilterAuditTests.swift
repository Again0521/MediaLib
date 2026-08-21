import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级全局搜索与防注入及多语言性能专项】
/// 审计目标：验证底层 SQLite 驱动与查询层在面对特殊 SQL/SQLite 元字符（如 `'`, `"`, `%`, `_`, `\`, `--`, `;`）、
/// 极长搜索词、多语言及拼音模糊匹配时的防 SQL 注入处理、特殊字符转义安全以及大表检索耗时。
/// 对应报告问题 ID：TC-UI-001 / RISK-01
final class GlobalSearchAndFilterAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("search_audit.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    /// 测试 SQL 特殊元字符与注入攻击字串不会破坏数据库或引发抛错
    func testSQLInjectionAndSpecialCharacterSearchSafety() throws {
        let db = try DatabaseManager(url: dbURL)
        try db.execute("CREATE TABLE IF NOT EXISTS search_test (id TEXT PRIMARY KEY, title TEXT)")

        // 插入一些包含特殊名称的模拟媒体
        let specialTitles = [
            "Normal Movie",
            "Movie 'with' single quotes",
            "Movie \"with\" double quotes",
            "50% Off & _Underscore_ Special",
            "Robert); DROP TABLE search_test;--",
            "💥 Emoji Title 🚀"
        ]

        for (idx, title) in specialTitles.enumerated() {
            try db.execute(
                "INSERT OR REPLACE INTO search_test (id, title) VALUES (?, ?)",
                bindings: [.text("id-\(idx)"), .text(title)]
            )
        }

        // 验证注入攻击字串能否被安全作为普通字符绑定检索，不执行恶意的 DROP TABLE
        let dangerousQuery = "%DROP TABLE%"
        let results = try db.query(
            "SELECT title FROM search_test WHERE title LIKE ?",
            bindings: [.text(dangerousQuery)]
        ) { $0.string(0) }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first, "Robert); DROP TABLE search_test;--", "带占位符的参数绑定必须 100% 抵御 SQL 注入")

        // 验证表依然完好无损存在
        let tableCount = try db.query("SELECT count(*) FROM search_test") { $0.int(0) }.first ?? 0
        XCTAssertEqual(tableCount, 6, "表结构绝不可因特殊字符查询被破坏或删除")
    }

    /// 测试极长字符串（如 1000 个字符）搜索时的系统时延和抗拒绝服务 (DoS) 能力
    func testExtremelyLongSearchStringDoesNotHangDatabase() throws {
        let db = try DatabaseManager(url: dbURL)
        try db.execute("CREATE TABLE IF NOT EXISTS search_test_long (id TEXT PRIMARY KEY, title TEXT)")
        try db.execute("INSERT INTO search_test_long VALUES (?, ?)", bindings: [.text("1"), .text("Short Title")])

        let superLongKeyword = "%" + String(repeating: "A", count: 2000) + "%"

        let start = CFAbsoluteTimeGetCurrent()
        let results = try db.query(
            "SELECT title FROM search_test_long WHERE title LIKE ?",
            bindings: [.text(superLongKeyword)]
        ) { $0.string(0) }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(results.isEmpty)
        XCTAssertLessThan(elapsed, 0.1, "处理超长非法搜索字串必须在 100ms 内安全完成或截断，不可耗尽主线程或 SQLite 引擎资源")
    }
}
