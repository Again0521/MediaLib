import XCTest
import MediaLibCore
@testable import MediaLib

/// MusicPlaylistStore 集成测试：用临时 SQLite 库（DatabaseManager 初始化即跑迁移建表）+
/// 真实 repository 驱动，覆盖普通/智能歌单 CRUD 与内存排序、以及 repository 缺失时的降级路径。
@MainActor
final class MusicPlaylistStoreTests: XCTestCase {
    private var dbURL: URL!
    private var store: MusicPlaylistStore!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("playlist-store-\(UUID().uuidString).sqlite")
        let database = try DatabaseManager(url: dbURL)
        store = MusicPlaylistStore(
            repository: MusicPlaylistRepository(database: database),
            smartRepository: MusicSmartPlaylistRepository(database: database)
        )
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - 普通歌单

    func testCreateAddRemoveAndDeletePlaylist() throws {
        let created = try store.create(name: "夜跑", itemIDs: ["a", "b"])
        let playlist = try XCTUnwrap(created)
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.playlists.first?.itemIDs, ["a", "b"])

        try store.addTracks(itemIDs: ["c"], toPlaylistID: playlist.id)
        XCTAssertEqual(store.playlists.first?.itemIDs, ["a", "b", "c"])

        try store.removeTracks(itemIDs: ["b"], fromPlaylistID: playlist.id)
        XCTAssertEqual(store.playlists.first?.itemIDs, ["a", "c"])

        try store.delete(id: playlist.id)
        XCTAssertTrue(store.playlists.isEmpty)
    }

    func testRenameAndReplaceItems() throws {
        let playlist = try XCTUnwrap(try store.create(name: "旧名", itemIDs: ["x"]))

        try store.rename(id: playlist.id, name: "新名")
        XCTAssertEqual(store.playlists.first?.name, "新名")

        try store.replaceItems(["m", "n"], inPlaylistID: playlist.id)
        XCTAssertEqual(store.playlists.first?.itemIDs, ["m", "n"])
    }

    func testMoveItemsReordersWithinPlaylist() throws {
        let playlist = try XCTUnwrap(try store.create(name: "顺序", itemIDs: ["1", "2", "3"]))
        try store.moveItems(inPlaylistID: playlist.id, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.playlists.first?.itemIDs, ["2", "3", "1"])
    }

    func testReloadPlaylistsReadsBackFromDatabase() throws {
        _ = try store.create(name: "持久化", itemIDs: ["a"])
        try store.reloadPlaylists()
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.playlists.first?.name, "持久化")
    }

    // MARK: - 智能歌单

    func testSaveSmartReportsIsNewThenUpdate() throws {
        var playlist = MusicSmartPlaylist(name: "最近添加")
        let first = try XCTUnwrap(try store.saveSmart(playlist))
        XCTAssertTrue(first.isNew)
        XCTAssertEqual(store.smartPlaylists.count, 1)

        playlist = first.saved
        playlist.name = "改名"
        let second = try XCTUnwrap(try store.saveSmart(playlist))
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(store.smartPlaylists.count, 1)
        XCTAssertEqual(store.smartPlaylists.first?.name, "改名")
    }

    func testDeleteSmartReturnsTrueAndRemoves() throws {
        let saved = try XCTUnwrap(try store.saveSmart(MusicSmartPlaylist(name: "待删")))
        let removed = try store.deleteSmart(id: saved.saved.id)
        XCTAssertTrue(removed)
        XCTAssertTrue(store.smartPlaylists.isEmpty)
    }

    // MARK: - repository 缺失降级（与原 guard let ... else 行为一致）

    func testNilRepositoryDegradesGracefully() throws {
        let bare = MusicPlaylistStore(repository: nil, smartRepository: nil)
        XCTAssertNil(try bare.create(name: "无库", itemIDs: ["a"]))
        XCTAssertNil(try bare.saveSmart(MusicSmartPlaylist(name: "无库")))
        XCTAssertFalse(try bare.deleteSmart(id: "x"))
        // 无 repository 时载入应得到空数组、不抛错
        try bare.reloadPlaylists()
        try bare.reloadSmartPlaylists()
        XCTAssertTrue(bare.playlists.isEmpty)
        XCTAssertTrue(bare.smartPlaylists.isEmpty)
    }
}
