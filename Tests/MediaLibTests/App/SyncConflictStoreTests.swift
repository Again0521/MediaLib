import XCTest
import MediaLibCore
@testable import MediaLib

/// SyncConflictStore 集成测试：用临时 SQLite 库 + 真实 SyncConflictRepository 驱动，覆盖
/// 载入 / 保存 / 持久化解决·忽略 / 内存反映，以及 repository 缺失时的降级路径。
@MainActor
final class SyncConflictStoreTests: XCTestCase {
    private var dbURL: URL!
    private var store: SyncConflictStore!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-conflict-store-\(UUID().uuidString).sqlite")
        let database = try DatabaseManager(url: dbURL)
        store = SyncConflictStore(repository: SyncConflictRepository(database: database))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func makeConflict(_ id: String, field: String = "watched") -> SyncConflict {
        // media_id 为可空外键（→ media_items）；本 Store 测试只关心列表/持久化，置 nil 避免建 media。
        SyncConflict(
            id: id,
            mediaID: nil,
            provider: .trakt,
            accountID: nil,
            fieldName: field,
            localValue: "true",
            remoteValue: "false",
            localUpdatedAt: Date(),
            remoteUpdatedAt: Date()
        )
    }

    func testSaveAndReloadSurfacesPendingConflicts() throws {
        _ = try store.save(makeConflict("a"))
        _ = try store.save(makeConflict("b"))
        try store.reload()
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertEqual(Set(store.pendingConflicts.map(\.id)), ["a", "b"])
    }

    func testPersistResolutionThenForgetPending() throws {
        _ = try store.save(makeConflict("a"))
        _ = try store.save(makeConflict("b"))
        try store.reload()

        // 模拟 AppState：先持久化解决，再反映到内存列表。
        try store.persistResolution(id: "a", resolution: .useRemote)
        store.forgetPending(id: "a")
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.pendingConflicts.map(\.id), ["b"])

        // 重新载入应确认 "a" 已不在待处理集合（已 resolved 落库）。
        try store.reload()
        XCTAssertEqual(store.pendingConflicts.map(\.id), ["b"])
    }

    func testPersistIgnoreRemovesFromPendingOnReload() throws {
        _ = try store.save(makeConflict("a"))
        try store.reload()
        XCTAssertEqual(store.pendingCount, 1)

        try store.persistIgnore(id: "a")
        store.forgetPending(id: "a")
        XCTAssertEqual(store.pendingCount, 0)

        try store.reload()
        XCTAssertTrue(store.pendingConflicts.isEmpty)
    }

    func testForgetPendingClampsCountAtZero() {
        store.forgetPending(id: "nonexistent")
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testRefreshFromRepositoryUpdatesBoth() throws {
        _ = try store.save(makeConflict("a"))
        try store.refreshFromRepository()
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.pendingConflicts.map(\.id), ["a"])
    }

    func testNilRepositoryDegradesGracefully() throws {
        let bare = SyncConflictStore(repository: nil)
        XCTAssertFalse(bare.isAvailable)
        XCTAssertNil(try bare.save(makeConflict("a")))
        // reload 归零、refresh 保持原值、persist 为 no-op，均不抛错。
        try bare.reload()
        try bare.refreshFromRepository()
        try bare.persistResolution(id: "a", resolution: .useLocal)
        try bare.persistIgnore(id: "a")
        XCTAssertEqual(bare.pendingCount, 0)
        XCTAssertTrue(bare.pendingConflicts.isEmpty)
    }
}

