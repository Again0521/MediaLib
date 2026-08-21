import Foundation
import MediaLibCore

// 音乐歌单（智能 + 普通 + M3U 导入导出）相关方法从 AppState.swift 拆到本文件，直接缩小那个超大文件
// （R1-ARCH-001 头号债务＝超大文件）。这些方法是「视图可调的编排层」：数据 CRUD 已在
// MusicPlaylistStore，本扩展只保留依赖实时音乐库缓存的查询与副作用（提示/错误/库版本号）。
// 纯文件搬运，方法体逐字不变（仅 `libraryRevision += 1` 改为等价的 `bumpLibraryRevision()`，
// 以保留 libraryRevision 的 private(set) 封装）。
extension AppState {
    // MARK: - 音乐智能歌单

    func musicSmartPlaylist(id: String) -> MusicSmartPlaylist? {
        musicPlaylistStore.smartPlaylist(id: id)
    }

    @discardableResult
    func saveMusicSmartPlaylist(_ playlist: MusicSmartPlaylist, notify: Bool = true) -> MusicSmartPlaylist? {
        do {
            guard let result = try musicPlaylistStore.saveSmart(playlist) else { return nil }
            cachedMusicSmartTracksByPlaylistID.removeValue(forKey: result.saved.id)
            bumpLibraryRevision()
            if notify {
                let title = result.isNew ? "智能歌单已创建" : "智能歌单已保存"
                deliverTaskNotice(
                    title: title,
                    message: result.saved.name,
                    kind: .success,
                    systemTitle: title,
                    systemBody: "\(result.saved.name) 已保存。"
                )
            }
            return result.saved
        } catch {
            deliverTaskNotice(
                title: "智能歌单保存失败",
                message: error.localizedDescription,
                kind: .error,
                systemTitle: "智能歌单保存失败",
                systemBody: error.localizedDescription
            )
            return nil
        }
    }

    func deleteMusicSmartPlaylist(_ playlist: MusicSmartPlaylist) {
        do {
            if try musicPlaylistStore.deleteSmart(id: playlist.id) {
                cachedMusicSmartTracksByPlaylistID.removeValue(forKey: playlist.id)
                bumpLibraryRevision()
            }
        } catch {
            showError("智能歌单删除失败", error)
        }
    }

    /// 按规则实时求值：从全部音乐里筛选 → 排序 → 截断数量。曲目随库状态自动更新。
    ///
    /// 规则本身住在 `MusicSmartPlaylistPolicy`（MediaLibCore），服务端用同一份——
    /// 从前它只在这里，网页端因此完全给不出智能歌单。这里只负责喂候选集和缓存。
    func musicTracks(inSmart playlist: MusicSmartPlaylist) -> [MediaItem] {
        if let cached = cachedMusicSmartTracksByPlaylistID[playlist.id] {
            return cached
        }
        let tracks = MusicSmartPlaylistPolicy.tracks(in: playlist, from: musicTracks)
        cachedMusicSmartTracksByPlaylistID[playlist.id] = tracks
        return tracks
    }

    // MARK: - 普通歌单

    func musicTracks(in playlist: MusicPlaylist) -> [MediaItem] {
        playlist.itemIDs.compactMap { cachedMusicTracksByID[$0] }
    }

    @discardableResult
    func createMusicPlaylist(name: String, tracks: [MediaItem] = []) -> MusicPlaylist? {
        do {
            return try musicPlaylistStore.create(name: name, itemIDs: uniqueMusicTracks(tracks).map(\.id))
        } catch {
            showError("创建歌单失败", error)
            return nil
        }
    }

    // MARK: - 歌单 M3U 导入 / 导出

    /// 生成 M3U 文本（含 #EXTINF 时长与"艺人 - 标题"）。
    func musicPlaylistM3UContent(_ playlist: MusicPlaylist) -> String {
        MusicPlaylistM3UPolicy.m3uContent(for: musicTracks(in: playlist))
    }

    /// 从 M3U 文件导入：按文件路径（绝对/相对）匹配库内曲目，匹配不到再按文件名兜底，创建新歌单。返回匹配数量。
    @discardableResult
    func importMusicPlaylist(fromM3U url: URL, name: String) -> Int {
        do {
            return importMusicPlaylist(
                m3uContent: try MusicPlaylistM3UFileLoader.loadContentSynchronously(from: url),
                sourceURL: url,
                name: name
            )
        } catch {
            alert = AppAlert(title: "导入失败", message: "无法读取该 M3U 文件。")
            return 0
        }
    }

    @discardableResult
    func importMusicPlaylistAsync(fromM3U url: URL, name: String) async -> Int {
        do {
            return importMusicPlaylist(
                m3uContent: try await MusicPlaylistM3UFileLoader.loadContent(from: url),
                sourceURL: url,
                name: name
            )
        } catch {
            alert = AppAlert(title: "导入失败", message: "无法读取该 M3U 文件。")
            return 0
        }
    }

    @discardableResult
    private func importMusicPlaylist(m3uContent content: String, sourceURL url: URL, name: String) -> Int {
        let rawPaths = MusicPlaylistM3UPolicy.candidatePaths(
            from: content,
            baseDirectory: url.deletingLastPathComponent()
        )
        let matched = MusicPlaylistM3UPolicy.matchedTracks(
            for: rawPaths,
            in: cachedMusicTracks
        )

        guard !matched.isEmpty else {
            alert = AppAlert(title: "未匹配到歌曲", message: "M3U 里的文件都不在当前音乐库中。请先扫描包含这些文件的音乐媒体源。")
            return 0
        }
        _ = createMusicPlaylist(name: name, tracks: matched)
        return matched.count
    }

    func addMusicTracks(_ tracks: [MediaItem], to playlist: MusicPlaylist) {
        do {
            try musicPlaylistStore.addTracks(itemIDs: uniqueMusicTracks(tracks).map(\.id), toPlaylistID: playlist.id)
        } catch {
            showError("添加到歌单失败", error)
        }
    }

    func renameMusicPlaylist(_ playlist: MusicPlaylist, name: String) {
        do {
            try musicPlaylistStore.rename(id: playlist.id, name: name)
        } catch {
            showError("重命名歌单失败", error)
        }
    }

    func deleteMusicPlaylist(_ playlist: MusicPlaylist) {
        do {
            try musicPlaylistStore.delete(id: playlist.id)
        } catch {
            showError("删除歌单失败", error)
        }
    }

    func removeMusicTracks(_ tracks: [MediaItem], from playlist: MusicPlaylist) {
        do {
            try musicPlaylistStore.removeTracks(itemIDs: uniqueMusicTracks(tracks).map(\.id), fromPlaylistID: playlist.id)
        } catch {
            showError("移出歌单失败", error)
        }
    }

    func moveMusicPlaylistItems(in playlist: MusicPlaylist, fromOffsets: IndexSet, toOffset: Int) {
        do {
            try musicPlaylistStore.moveItems(inPlaylistID: playlist.id, fromOffsets: fromOffsets, toOffset: toOffset)
        } catch {
            showError("调整歌单顺序失败", error)
        }
    }

    func replaceMusicPlaylistItems(in playlist: MusicPlaylist, with tracks: [MediaItem]) {
        do {
            try musicPlaylistStore.replaceItems(uniqueMusicTracks(tracks).map(\.id), inPlaylistID: playlist.id)
        } catch {
            showError("保存歌单顺序失败", error)
        }
    }
}
