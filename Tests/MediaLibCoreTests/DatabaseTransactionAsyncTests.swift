import XCTest
@testable import MediaLibCore

final class DatabaseTransactionAsyncTests: XCTestCase {
    private var dbURL: URL!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-async-\(UUID().uuidString).sqlite")
        database = try DatabaseManager(url: dbURL)
        try database.execute("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v TEXT)")
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func rowCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM t") { $0.int(0) ?? 0 }.first ?? 0
    }

    func testTransactionAsyncCommitsWrites() async throws {
        try await database.transactionAsync {
            try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("a")])
            try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("b")])
        }
        let count = try rowCount()
        XCTAssertEqual(count, 2)
    }

    func testTransactionAsyncRollsBackOnThrow() async throws {
        struct Boom: Error {}
        do {
            try await database.transactionAsync {
                try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("x")])
                throw Boom()
            }
            XCTFail("expected throw")
        } catch is Boom {
            // 预期
        }
        // 抛错应回滚，不留下任何行
        let count = try rowCount()
        XCTAssertEqual(count, 0)
    }

    func testTransactionAsyncReturnsValue() async throws {
        let inserted = try await database.transactionAsync { () -> Int in
            try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("z")])
            return 42
        }
        XCTAssertEqual(inserted, 42)
        let count = try rowCount()
        XCTAssertEqual(count, 1)
    }
}
