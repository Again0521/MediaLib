import Combine
import Foundation
import MediaLibCore

/// 音乐歌单（普通 + 智能）的存储与 CRUD，从 AppState 抽出（R1-ARCH-001 第 3 步）。
///
/// 职责边界：本 Store 只负责**歌单数据本身**——持有两份 `@Published` 数组、两个 repository，
/// 以及增删改/排序/内存 upsert。所有副作用（完成通知、`libraryRevision` 自增、错误弹窗、
/// M3U 导入提示）与**依赖实时音乐库缓存的查询**（`musicTracks(in:)` / `musicTracks(inSmart:)`
/// 等）仍留在 AppState：CRUD 方法以 `throws` 上抛 repository 错误，由 AppState 的薄封装捕获并
/// 决定提示/自增，保持外部行为逐字不变。
///
/// 行为逐字搬自原 AppState 的歌单方法；`playlists` / `smartPlaylists` 用 `private(set)`
/// 收紧写入入口，逻辑纯（repository 可注入）便于确定性单测。
@MainActor
final class MusicPlaylistStore: ObservableObject {
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var smartPlaylists: [MusicSmartPlaylist] = []

    private let repository: MusicPlaylistRepository?
    private let smartRepository: MusicSmartPlaylistRepository?

    init(repository: MusicPlaylistRepository?, smartRepository: MusicSmartPlaylistRepository?) {
        self.repository = repository
        self.smartRepository = smartRepository
    }

    // MARK: - 载入（reload 编排时调用）

    func reloadPlaylists() throws {
        playlists = try repository?.fetchAll() ?? []
    }

    func reloadSmartPlaylists() throws {
        smartPlaylists = try smartRepository?.fetchAll() ?? []
    }

    func replaceLoaded(playlists: [MusicPlaylist], smartPlaylists: [MusicSmartPlaylist]) {
        self.playlists = playlists
        self.smartPlaylists = smartPlaylists
    }

    // MARK: - 智能歌单

    func smartPlaylist(id: String) -> MusicSmartPlaylist? {
        smartPlaylists.first { $0.id == id }
    }

    /// 保存（新建或更新）智能歌单。返回保存结果与 `isNew`（供 AppState 决定提示文案/自增），
    /// repository 缺失时返回 nil（与原 `guard let ... else { return nil }` 一致）。
    @discardableResult
    func saveSmart(_ playlist: MusicSmartPlaylist) throws -> (saved: MusicSmartPlaylist, isNew: Bool)? {
        guard let smartRepository else { return nil }
        let isNew = !smartPlaylists.contains { $0.id == playlist.id }
        let saved = try smartRepository.save(playlist)
        if let index = smartPlaylists.firstIndex(where: { $0.id == saved.id }) {
            smartPlaylists[index] = saved
        } else {
            smartPlaylists.insert(saved, at: 0)
        }
        smartPlaylists.sort { $0.updatedAt > $1.updatedAt }
        return (saved, isNew)
    }

    /// 删除智能歌单。返回是否实际执行（repository 缺失返回 false，与原行为一致：不自增 revision）。
    @discardableResult
    func deleteSmart(id: String) throws -> Bool {
        guard let smartRepository else { return false }
        try smartRepository.delete(id: id)
        smartPlaylists.removeAll { $0.id == id }
        return true
    }

    // MARK: - 普通歌单

    @discardableResult
    func create(name: String, itemIDs: [String]) throws -> MusicPlaylist? {
        guard let repository else { return nil }
        let playlist = try repository.create(name: name, itemIDs: itemIDs)
        upsertInMemory(playlist)
        return playlist
    }

    func addTracks(itemIDs: [String], toPlaylistID playlistID: String) throws {
        guard let repository else { return }
        guard let updated = try repository.add(itemIDs: itemIDs, toPlaylistID: playlistID) else { return }
        upsertInMemory(updated)
    }

    func rename(id playlistID: String, name: String) throws {
        guard let repository else { return }
        guard let updated = try repository.rename(id: playlistID, name: name) else { return }
        upsertInMemory(updated)
    }

    func delete(id playlistID: String) throws {
        guard let repository else { return }
        try repository.delete(id: playlistID)
        playlists.removeAll { $0.id == playlistID }
    }

    func removeTracks(itemIDs: [String], fromPlaylistID playlistID: String) throws {
        guard let repository else { return }
        guard let updated = try repository.remove(itemIDs: itemIDs, fromPlaylistID: playlistID) else { return }
        upsertInMemory(updated)
    }

    func moveItems(inPlaylistID playlistID: String, fromOffsets: IndexSet, toOffset: Int) throws {
        guard let repository,
              let current = playlists.first(where: { $0.id == playlistID }) else { return }
        var itemIDs = current.itemIDs
        itemIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard let updated = try repository.replaceItems(itemIDs, inPlaylistID: playlistID) else { return }
        upsertInMemory(updated)
    }

    func replaceItems(_ itemIDs: [String], inPlaylistID playlistID: String) throws {
        guard let repository else { return }
        guard let updated = try repository.replaceItems(itemIDs, inPlaylistID: playlistID) else { return }
        upsertInMemory(updated)
    }

    private func upsertInMemory(_ playlist: MusicPlaylist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
        } else {
            playlists.insert(playlist, at: 0)
        }
        playlists.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
