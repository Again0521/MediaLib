import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P2级 SQLite 数据类型绑定与编解码边界专项】
/// 审计目标：验证 `SQLiteValue` 在处理极端整数（Int64 最大/最小值）、
/// 浮点数边界（包括 0.0 与负数）、超长多字集 Unicode 文本及 NULL 时的类型转换与内存绑定安全。
/// 对应报告问题 ID：TC-DB-002 / RISK-03
final class SQLiteValueAuditTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteValueAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("sqlite_value_test.sqlite")
        db = try DatabaseManager(url: dbURL)
        
        try db.execute("CREATE TABLE IF NOT EXISTS val_audit (id TEXT PRIMARY KEY, num INTEGER, flt REAL, txt TEXT, bl INTEGER);")
    }

    override func tearDownWithError() throws {
        if let dbURL {
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }
    }

    /// 测试极值整数与特殊浮点数的完美持久化与精确无损读出
    func testExtremeNumericValuesPersistenceAndPrecision() throws {
        let maxInt = Int.max
        let minInt = Int.min
        let pi = 3.14159265358979323846
        
        try db.execute("INSERT INTO val_audit (id, num, flt) VALUES (?, ?, ?)", bindings: [.text("max-row"), .int(Int64(maxInt)), .double(pi)])
        try db.execute("INSERT INTO val_audit (id, num, flt) VALUES (?, ?, ?)", bindings: [.text("min-row"), .int(Int64(minInt)), .double(-pi)])
        
        let maxRow = try db.query("SELECT num, flt FROM val_audit WHERE id = ?", bindings: [.text("max-row")]) { row in
            (row.int(0), row.double(1))
        }.first
        
        let minRow = try db.query("SELECT num, flt FROM val_audit WHERE id = ?", bindings: [.text("min-row")]) { row in
            (row.int(0), row.double(1))
        }.first
        
        XCTAssertEqual(maxRow?.0, maxInt, "Int 最大值必须在 SQLite 底层存取中保持精确，无溢出")
        XCTAssertEqual(maxRow?.1 ?? 0.0, pi, accuracy: 1e-15, "双精度浮点数必须无损读出")
        
        XCTAssertEqual(minRow?.0, minInt, "Int 最小值必须准确绑定")
        XCTAssertEqual(minRow?.1 ?? 0.0, -pi, accuracy: 1e-15)
    }

    /// 测试超复杂多语言混合及特殊字符在 SQL 绑定中不发生断裂或注入
    func testComplexUnicodeAndSpecialCharacterBinding() throws {
        let complexText = "🎥 《进击的巨人》\nLine 2 \t \"Quotes\" 'Single Quotes' \\ Backslash \0 NullChar Test"
        try db.execute("INSERT INTO val_audit (id, txt) VALUES (?, ?)", bindings: [.text("unicode-row"), .text(complexText)])
        
        let fetched = try db.query("SELECT txt FROM val_audit WHERE id = ?", bindings: [.text("unicode-row")]) { $0.string(0) }.first
        
        XCTAssertEqual(fetched, complexText, "所有特殊控制字符、多语言 Emoji 与转义符号必须通过绑定安全存储与还原")
    }

    /// 测试 NULL 与布尔值在 SQLite 底层的正确转化
    func testNullAndBooleanBinding() throws {
        try db.execute("INSERT INTO val_audit (id, txt, bl) VALUES (?, ?, ?)", bindings: [.text("null-row"), .null, .bool(true)])
        
        let row = try db.query("SELECT txt, bl FROM val_audit WHERE id = ?", bindings: [.text("null-row")]) { row in
            (row.string(0), row.int(1))
        }.first
        
        XCTAssertNil(row?.0, "绑定 .null 时必须在数据库中表达为真正 NULL")
        XCTAssertEqual(row?.1, 1, "布尔值 true 应该被正确转化为整数 1")
    }

    func testOptionalDoubleTreatsNonFiniteValuesAsNull() {
        guard case .double(let finite) = SQLiteValue.optionalDouble(1.25) else {
            return XCTFail("有限 Double 应保留为 REAL 绑定值")
        }
        XCTAssertEqual(finite, 1.25)

        if case .null = SQLiteValue.optionalDouble(.nan) {} else {
            XCTFail("NaN 可选浮点值必须清洗为 NULL")
        }
        if case .null = SQLiteValue.optionalDouble(.infinity) {} else {
            XCTFail("正无穷可选浮点值必须清洗为 NULL")
        }
        if case .null = SQLiteValue.optionalDouble(-.infinity) {} else {
            XCTFail("负无穷可选浮点值必须清洗为 NULL")
        }
    }

    func testNonFiniteDoubleBindingsPersistAsSQLiteNull() throws {
        try db.execute(
            "INSERT INTO val_audit (id, flt) VALUES (?, ?), (?, ?), (?, ?)",
            bindings: [
                .text("nan-row"), .double(.nan),
                .text("inf-row"), .double(.infinity),
                .text("neg-inf-row"), .double(-.infinity)
            ]
        )

        let nullFlags = try db.query(
            "SELECT flt IS NULL FROM val_audit WHERE id IN (?, ?, ?) ORDER BY id",
            bindings: [.text("inf-row"), .text("nan-row"), .text("neg-inf-row")]
        ) { row in
            row.int(0)
        }

        XCTAssertEqual(nullFlags, [1, 1, 1])
    }
}
