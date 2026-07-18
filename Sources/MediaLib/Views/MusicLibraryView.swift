import Foundation
import MediaLibCore
import SwiftUI
import UniformTypeIdentifiers

private enum MusicLyricsPresenceCache {
    private static var values: [String: Bool] = [:]
    private static var accessTick: [String: Int] = [:]
    private static var tickCounter = 0
    private static var cacheRevision = 0
    private static let maxValues = 4096
    private static let lock = NSLock()

    static var revision: Int {
        lock.lock()
        defer { lock.unlock() }
        return cacheRevision
    }

    static func cachedHasLyrics(filePath: String?) -> Bool? {
        guard let filePath else { return false }
        let cacheKey = key(filePath: filePath)
        lock.lock()
        defer { lock.unlock() }
        guard let cached = values[cacheKey] else { return nil }
        markRecentlyUsed(cacheKey)
        return cached
    }

    static func warmCache(filePaths: [String?]) async -> Bool {
        let paths = Array(Set(filePaths.compactMap { $0 }))
        let missing = missingEntries(for: paths)
        guard !missing.isEmpty else { return false }

        // 歌词文件探测是磁盘/NAS stat：走阻塞 I/O 专用队列，不占协作池。
        let results = await BlockingIOExecutor.run {
            missing.map { entry in
                (cacheKey: entry.cacheKey, exists: lyricsExist(filePath: entry.path))
            }
        }

        return store(results)
    }

    private static func missingEntries(for paths: [String]) -> [(path: String, cacheKey: String)] {
        lock.lock()
        defer { lock.unlock() }
        return paths
            .map { (path: $0, cacheKey: key(filePath: $0)) }
            .filter { values[$0.cacheKey] == nil }
    }

    private static func store(_ results: [(cacheKey: String, exists: Bool)]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for result in results where values[result.cacheKey] == nil {
            values[result.cacheKey] = result.exists
            markRecentlyUsed(result.cacheKey)
            changed = true
        }
        if changed {
            trimIfNeeded()
            cacheRevision += 1
        }
        return changed
    }

    private static func key(filePath: String) -> String {
        filePath
    }

    private static func markRecentlyUsed(_ cacheKey: String) {
        tickCounter &+= 1
        accessTick[cacheKey] = tickCounter
    }

    private static func trimIfNeeded() {
        guard values.count > maxValues else { return }
        while values.count > maxValues,
              let oldestKey = accessTick.min(by: { $0.value < $1.value })?.key {
            values.removeValue(forKey: oldestKey)
            accessTick.removeValue(forKey: oldestKey)
        }
    }

    private static func lyricsExist(filePath: String) -> Bool {
        // 词法拼路径（NSString 无 I/O），只让 fileExists 这两次探测真正touching NAS。
        let ns = filePath as NSString
        let directory = ns.deletingLastPathComponent as NSString
        let basename = (ns.lastPathComponent as NSString).deletingPathExtension
        return ["lrc", "txt"].contains { ext in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(basename).\(ext)"))
        }
    }
}

// 静态缓存字典只允许主线程访问：resolve 此前是 nonisolated async（跑在并发池上），
// 与主线程 body 里的 snapshot(for:) 存在数据竞争。整个类型收敛到 MainActor，
// 仅真正的快照构建仍在 detached 任务里进行。
@MainActor
private enum MusicLibrarySnapshotCache {
    struct Key: Hashable, Sendable {
        let section: MusicLibrarySection
        let searchText: String
        let sortMode: MusicSortMode
        let sortOrder: MusicSortOrder
        let filterMode: MusicFilterMode
        let revision: Int
        let projectionRevision: Int
        let lyricsRevision: Int
    }

    struct Snapshot: Sendable {
        let rows: [MusicTrackRowModel]
        let albums: [MusicAlbumGroup]
        let artists: [MusicArtistGroup]
    }

    private static var values: [Key: Snapshot] = [:]
    private static var inFlight: [Key: Task<Snapshot, Never>] = [:]
    // 用单调递增时间戳替代线性扫描的 accessOrder 数组：O(1) 读写，淘汰时排序一次。
    private static var accessTick: [Key: Int] = [:]
    private static var tickCounter = 0

    static func snapshot(for key: Key) -> Snapshot? {
        guard let snapshot = values[key] else { return nil }
        markRecentlyUsed(key)
        return snapshot
    }

    static func store(_ snapshot: Snapshot, for key: Key) {
        values[key] = snapshot
        inFlight[key] = nil
        markRecentlyUsed(key)
        if values.count > 48 {
            // 只在超出上限时排序一次，正常命中路径零开销。
            let oldest = accessTick.min { $0.value < $1.value }?.key
            if let oldest {
                values.removeValue(forKey: oldest)
                accessTick.removeValue(forKey: oldest)
            }
        }
    }

    /// 快照构建的专用队列。此前用 Task.detached 丢进全局协作线程池：库重载、
    /// 全库健康检查等长阻塞任务会把池占满，几毫秒的构建排队 2 秒以上才开跑
    /// （实测 315 首歌 resolve 2400ms），表现为音乐页长时间「正在载入」。
    private static let buildQueue = DispatchQueue(label: "MediaLib.musicSnapshotBuild", qos: .userInitiated)

    static func resolve(
        for key: Key,
        build: @escaping @Sendable () -> Snapshot
    ) async -> Snapshot {
        if let snapshot = snapshot(for: key) {
            return snapshot
        }
        let task: Task<Snapshot, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            task = Task {
                await withCheckedContinuation { (continuation: CheckedContinuation<Snapshot, Never>) in
                    buildQueue.async {
                        continuation.resume(returning: build())
                    }
                }
            }
            inFlight[key] = task
        }
        let snapshot = await task.value
        store(snapshot, for: key)
        return snapshot
    }

    private static func markRecentlyUsed(_ key: Key) {
        tickCounter += 1
        accessTick[key] = tickCounter
    }
}

/// 音乐库列表预热器：库加载完成或音乐内容变化后，在后台按各分区上次保存的
/// 排序/筛选预构建列表快照。用户点进音乐子页面时直接命中缓存，不再经历
/// 长时间的「正在载入」骨架（此前每次启动/内容变化后的首次进入都要现场
/// 全量排序 + 重建行模型）。
@MainActor
enum MusicLibraryContentPrewarmer {
    private static var scheduleTask: Task<Void, Never>?

    static func schedule(appState: AppState) {
        scheduleTask?.cancel()
        scheduleTask = Task { @MainActor [weak appState] in
            // 防抖：等库加载后的连续修订收敛后再预热一次。
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let appState else { return }
            await prewarm(appState: appState)
        }
    }

    private static func prewarm(appState: AppState) async {
        guard !appState.musicTracks.isEmpty else { return }
        let sections: [MusicLibrarySection] = [.songs, .albums, .artists, .recent, .favorites, .unmatched]
        let defaults = UserDefaults.standard
        for section in sections {
            guard !Task.isCancelled else { return }
            // 与 MusicLibraryView.loadViewState 相同的持久化键与合法性回退。
            let prefix = "MediaLib.musicState.\(section.rawValue)"
            var sortMode = defaults.string(forKey: "\(prefix).sort")
                .flatMap(MusicSortMode.init(rawValue:)) ?? .title
            let sortOrder = defaults.string(forKey: "\(prefix).sortOrder")
                .flatMap(MusicSortOrder.init(rawValue:)) ?? .primary
            var filterMode = defaults.string(forKey: "\(prefix).filter")
                .flatMap(MusicFilterMode.init(rawValue:)) ?? .all
            let availableSorts: [MusicSortMode]
            switch section {
            case .artists: availableSorts = [.title, .workCount, .mostPlayed]
            case .albums: availableSorts = [.title, .artist, .recent, .mostPlayed]
            default: availableSorts = [.title, .artist, .album, .mostPlayed, .recent, .duration]
            }
            if !availableSorts.contains(sortMode) { sortMode = .title }
            if section == .artists { filterMode = .all }
            // 「有歌词」筛选依赖歌词存在性缓存的暖度、键会随缓存修订漂移，交给页面自身处理。
            if filterMode == .withLyrics { continue }

            let key = MusicLibrarySnapshotCache.Key(
                section: section,
                searchText: "",
                sortMode: sortMode,
                sortOrder: sortOrder,
                filterMode: filterMode,
                revision: appState.musicContentRevision,
                projectionRevision: appState.musicProjectionRevision,
                lyricsRevision: 0
            )
            guard MusicLibrarySnapshotCache.snapshot(for: key) == nil else { continue }
            let needsTrackInput = section != .albums && section != .artists || filterMode == .unmatched
            let input = MusicLibrarySnapshotBuildInput(
                section: section,
                tracks: needsTrackInput ? appState.items(for: .music(section), searchText: "") : [],
                tracksByID: needsTrackInput ? appState.cachedMusicTracksByID : [:],
                albums: appState.musicAlbumSummaries,
                artists: appState.musicArtistSummaries,
                searchText: "",
                sortMode: sortMode,
                sortOrder: sortOrder,
                filterMode: filterMode
            )
            _ = await MusicLibrarySnapshotCache.resolve(for: key) {
                MusicLibrarySnapshotBuilder.snapshot(from: input)
            }
        }
    }
}

private struct MusicLibrarySnapshotBuildInput: Sendable {
    let section: MusicLibrarySection
    let tracks: [MediaItem]
    let tracksByID: [String: MediaItem]
    let albums: [MusicAlbumSummary]
    let artists: [MusicArtistSummary]
    let searchText: String
    let sortMode: MusicSortMode
    let sortOrder: MusicSortOrder
    let filterMode: MusicFilterMode
}

private enum MusicFavoritePlaylist {
    static let id = "MediaLIB.synthetic.favoriteMusicPlaylist"

    static func make(from tracks: [MediaItem]) -> MusicPlaylist {
        MusicPlaylist(
            id: id,
            name: "收藏",
            itemIDs: tracks.filter(\.favorite).map(\.id),
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func isFavorite(_ playlist: MusicPlaylist) -> Bool {
        playlist.id == id
    }
}

private func musicDisplayArtist(_ value: String?) -> String {
    MusicLibraryProjectionRepository.displayArtist(value)
}

private func musicDisplayAlbum(_ value: String?) -> String {
    MusicLibraryProjectionRepository.displayAlbum(value)
}

private enum MusicLibrarySnapshotBuilder {
    static func snapshot(from input: MusicLibrarySnapshotBuildInput) -> MusicLibrarySnapshotCache.Snapshot {
        switch input.section {
        case .albums:
            return MusicLibrarySnapshotCache.Snapshot(
                rows: [],
                albums: albumGroups(from: input.albums, input: input),
                artists: []
            )
        case .artists:
            return MusicLibrarySnapshotCache.Snapshot(
                rows: [],
                albums: [],
                artists: artistGroups(from: input.artists, input: input)
            )
        case .playlists:
            return MusicLibrarySnapshotCache.Snapshot(rows: [], albums: [], artists: [])
        case .songs, .recent, .favorites, .unmatched:
            let tracks = resolvedTracks(from: input.tracks, input: input)
            return MusicLibrarySnapshotCache.Snapshot(
                rows: rowModels(from: tracks),
                albums: [],
                artists: []
            )
        }
    }

    static func completeSnapshot(from input: MusicLibrarySnapshotBuildInput) -> MusicLibrarySnapshotCache.Snapshot {
        let tracks = resolvedTracks(from: input.tracks, input: input)
        return MusicLibrarySnapshotCache.Snapshot(
            rows: rowModels(from: tracks),
            albums: albumGroups(from: input.albums, input: input),
            artists: artistGroups(from: input.artists, input: input)
        )
    }

    static func resolvedTracks(from tracks: [MediaItem], input: MusicLibrarySnapshotBuildInput) -> [MediaItem] {
        let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched: [MediaItem]
        if query.isEmpty {
            searched = tracks
        } else {
            searched = tracks.filter {
                PinyinSearchMatcher.matches(
                    query: query,
                    in: [$0.title, $0.originalTitle, $0.artist, $0.album, $0.genre, $0.collectionTitle, $0.externalID]
                )
            }
        }

        let filtered = searched.filter { track in
            switch input.filterMode {
            case .all: return true
            case .favorites: return track.favorite
            case .withLyrics:
                return MusicLyricsPresenceCache.cachedHasLyrics(filePath: track.filePath) ?? false
            case .unmatched:
                return (track.artist?.isEmpty ?? true) || (track.album?.isEmpty ?? true) || track.metadataProvider == nil
            }
        }

        return filtered.sorted { lhs, rhs in
            switch input.sortMode {
            case .title:
                return sortedText(lhs.title, rhs.title, order: input.sortOrder) ?? true
            case .artist:
                return sortedText(lhs.artist ?? "", rhs.artist ?? "", order: input.sortOrder) ??
                    sortedText(lhs.title, rhs.title, order: .primary) ?? true
            case .album:
                return sortedText(lhs.album ?? "", rhs.album ?? "", order: input.sortOrder) ??
                    sortedText(lhs.title, rhs.title, order: .primary) ?? true
            case .recent:
                return sortedDate(lhs.updatedAt, rhs.updatedAt, order: input.sortOrder) ??
                    sortedText(lhs.title, rhs.title, order: .primary) ?? true
            case .duration:
                return sortedDouble(lhs.duration ?? 0, rhs.duration ?? 0, order: input.sortOrder) ??
                    sortedText(lhs.title, rhs.title, order: .primary) ?? true
            case .mostPlayed:
                return sortedNumber(lhs.playCountValue, rhs.playCountValue, order: input.sortOrder) ??
                    sortedText(lhs.title, rhs.title, order: .primary) ?? true
            case .workCount:
                return sortedText(lhs.title, rhs.title, order: input.sortOrder) ?? true
            }
        }
    }

    static func rowModels(from tracks: [MediaItem]) -> [MusicTrackRowModel] {
        tracks.map { track in
            MusicTrackRowModel(
                track: track,
                titleText: displayNameWithoutKnownExtension(track.title),
                // NSString 路径操作是纯词法运算。此处绝不能用 URL(fileURLWithPath:)：
                // 它初始化时会对路径 stat（判断目录性），歌曲在 NAS 上时一次就是一个
                // 网络往返——实测 315 首 × 每首 2 次 ≈ 2.1 秒，NAS 睡眠时更以数十秒计，
                // 正是音乐列表长期「正在载入」的元凶。
                // 远程条目的 filePath 是流地址（stream.mp3?Static=true&DeviceId=…），拿来当副标题很难看；
                // 远程音乐一律不显示文件名副标题（本地音乐照旧显示真实文件名）。
                fileName: track.isRemoteResource
                    ? nil
                    : track.filePath.map { displayNameWithoutKnownExtension(($0 as NSString).lastPathComponent) },
                artistText: musicDisplayArtist(track.artist),
                albumText: musicDisplayAlbum(track.album),
                hasLocalLyrics: MusicLyricsPresenceCache.cachedHasLyrics(filePath: track.filePath) ?? false,
                durationText: durationText(track.duration)
            )
        }
    }

    static func albumGroups(from albums: [MusicAlbumSummary], input: MusicLibrarySnapshotBuildInput) -> [MusicAlbumGroup] {
        let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = albums.compactMap { album -> MusicAlbumGroup? in
            if !query.isEmpty,
               !PinyinSearchMatcher.matches(query: query, in: [album.title, album.artist]) {
                return nil
            }
            switch input.filterMode {
            case .all:
                break
            case .favorites:
                guard album.favoriteCount > 0 else { return nil }
            case .withLyrics:
                guard input.tracks.contains(where: { track in
                    trackMatchesAlbum(track, album: album) &&
                    (MusicLyricsPresenceCache.cachedHasLyrics(filePath: track.filePath) ?? false)
                }) else { return nil }
            case .unmatched:
                guard input.tracks.contains(where: { track in
                    guard trackMatchesAlbum(track, album: album) else { return false }
                    return (track.artist?.isEmpty ?? true) || (track.album?.isEmpty ?? true) || track.metadataProvider == nil
                }) else { return nil }
            }
            return MusicAlbumGroup(summary: album)
        }
        return groups.sorted { lhs, rhs in
            switch input.sortMode {
            case .artist:
                return sortedText(lhs.key.artist, rhs.key.artist, order: input.sortOrder) ??
                    sortedText(lhs.key.title, rhs.key.title, order: .primary) ?? true
            case .recent:
                return sortedDate(lhs.latestUpdatedAt, rhs.latestUpdatedAt, order: input.sortOrder) ??
                    sortedText(lhs.key.title, rhs.key.title, order: .primary) ?? true
            case .mostPlayed:
                return sortedNumber(lhs.playCount, rhs.playCount, order: input.sortOrder) ??
                    sortedText(lhs.key.title, rhs.key.title, order: .primary) ?? true
            case .workCount:
                return sortedNumber(lhs.trackCount, rhs.trackCount, order: input.sortOrder) ??
                    sortedText(lhs.key.title, rhs.key.title, order: .primary) ?? true
            default:
                return sortedText(lhs.key.title, rhs.key.title, order: input.sortOrder) ?? true
            }
        }
    }

    static func artistGroups(from artists: [MusicArtistSummary], input: MusicLibrarySnapshotBuildInput) -> [MusicArtistGroup] {
        let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = artists.compactMap { artist -> MusicArtistGroup? in
            if !query.isEmpty,
               !PinyinSearchMatcher.matches(query: query, in: [artist.name]) {
                return nil
            }
            return MusicArtistGroup(summary: artist)
        }
        return groups.sorted { lhs, rhs in
            switch input.sortMode {
            case .workCount:
                return sortedNumber(lhs.trackCount, rhs.trackCount, order: input.sortOrder) ??
                    sortedText(lhs.name, rhs.name, order: .primary) ?? true
            case .mostPlayed:
                return sortedNumber(lhs.playCount, rhs.playCount, order: input.sortOrder) ??
                    sortedText(lhs.name, rhs.name, order: .primary) ?? true
            default:
                return sortedText(lhs.name, rhs.name, order: input.sortOrder) ?? true
            }
        }
    }

    private static func trackMatchesAlbum(_ track: MediaItem, album: MusicAlbumSummary) -> Bool {
        normalizedKey(musicDisplayAlbum(track.album)) == album.titleKey &&
        normalizedKey(musicDisplayArtist(track.artist)) == album.artistKey
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private static func sortedText(_ lhs: String, _ rhs: String, order: MusicSortOrder) -> Bool? {
        let result = lhs.localizedStandardCompare(rhs)
        guard result != .orderedSame else { return nil }
        return order == .primary ? result == .orderedAscending : result == .orderedDescending
    }

    private static func sortedNumber(_ lhs: Int, _ rhs: Int, order: MusicSortOrder) -> Bool? {
        guard lhs != rhs else { return nil }
        return order == .primary ? lhs > rhs : lhs < rhs
    }

    private static func sortedDouble(_ lhs: Double, _ rhs: Double, order: MusicSortOrder) -> Bool? {
        guard abs(lhs - rhs) > 0.000_1 else { return nil }
        return order == .primary ? lhs > rhs : lhs < rhs
    }

    private static func sortedDate(_ lhs: Date, _ rhs: Date, order: MusicSortOrder) -> Bool? {
        guard lhs != rhs else { return nil }
        return order == .primary ? lhs > rhs : lhs < rhs
    }

    private static func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let knownAudioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac"
    ]

    private static func displayNameWithoutKnownExtension(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用 NSString 的词法路径操作替代 URL(fileURLWithPath:)：后者初始化会 stat 路径，
        // 值为 NAS 路径/文件名时产生网络或磁盘往返（每行数毫秒，是列表构建慢的根源）。
        let ns = trimmed as NSString
        let ext = ns.pathExtension.lowercased()
        guard !ext.isEmpty, knownAudioExtensions.contains(ext) else {
            return trimmed
        }
        return (ns.deletingPathExtension as NSString).lastPathComponent
    }
}

private struct MusicCollectionGridMetrics {
    let minimumItemWidth: CGFloat
    let minimumColumns: Int
    let maximumColumns: Int
    let columnSpacing: CGFloat
    let firstRowTopInset: CGFloat
    let rowBottomInset: CGFloat

    static let album = MusicCollectionGridMetrics(
        minimumItemWidth: 220,
        minimumColumns: 1,
        maximumColumns: 4,
        columnSpacing: 20,
        firstRowTopInset: 6,
        rowBottomInset: 22
    )

    static let artist = MusicCollectionGridMetrics(
        minimumItemWidth: 128,
        minimumColumns: 2,
        maximumColumns: 6,
        columnSpacing: 18,
        firstRowTopInset: 2,
        rowBottomInset: 24
    )
}

struct MusicLibraryView: View {
    @EnvironmentObject private var appState: AppState
    let section: MusicLibrarySection
    var onCreateSmartPlaylist: () -> Void = {}
    @State private var searchText = ""
    @State private var metadataItem: MediaItem?
    @State private var sortMode: MusicSortMode = .title
    @State private var sortOrder: MusicSortOrder = .primary
    @State private var filterMode: MusicFilterMode = .all
    @State private var didLoadViewState = false
    @State private var visibleTrackRows: [MusicTrackRowModel] = []
    @State private var visibleAlbumGroups: [MusicAlbumGroup] = []
    @State private var visibleArtistGroups: [MusicArtistGroup] = []
    @State private var visibleContentSectionID = ""
    @State private var isPreparingVisibleContent = false
    @State private var drilldown: MusicCollectionDrilldown?
    @State private var playlistCreationRequest: MusicPlaylistCreationRequest?
    @State private var playlistRenameRequest: MusicPlaylistRenameRequest?
    @State private var playlistPendingDeletion: MusicPlaylist?
    @State private var isConfirmingPlaylistDeletion = false
    @State private var contentRefreshTask: Task<Void, Never>?
    @State private var searchRefreshTask: Task<Void, Never>?
    @State private var lyricsRefreshTask: Task<Void, Never>?
    @State private var collectionReturnAnchorID: String?
    @State private var collectionAnchorRestoreTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 内容“呼吸”透明度：与片库页同一节奏（见 LibraryView.contentBreathOpacity）。
    @State private var contentBreathOpacity: Double = 1

    /// 内容口径键：排序/筛选/分区/进出专辑与艺术家 drilldown 变化时驱动统一渐入。
    /// 不含逐字变化的 searchText，避免输入过程闪烁。
    private var contentRevisionKey: String {
        "\(section.id)|\(sortMode.rawValue)|\(sortOrder.rawValue)|\(filterMode.rawValue)|\(drilldown?.id ?? "-")"
    }

    var body: some View {
        Group {
            if usesScrollableCollectionList {
                scrollableCollectionListBody
            } else if usesStandaloneLongList {
                standaloneLongListBody
            } else if section == .playlists {
                fixedHeaderScrollableBody
            } else {
                scrollingBody
            }
        }
        .opacity(contentBreathOpacity)
        .onChange(of: contentRevisionKey) { _ in
            guard !reduceMotion else { return }
            withAnimation(nil) { contentBreathOpacity = 0.34 }
            DispatchQueue.main.async {
                withAnimation(AppMotion.standard) { contentBreathOpacity = 1 }
            }
        }
        .suppressListHighlight()
        .background(AppPageBackground())
        .navigationTitle(section.title)
        .onAppear {
            logMusicPerf("onAppear[\(section.rawValue)]")
            loadViewState(for: section)
            refreshVisibleContent(for: section)
            presentSectionTipIfNeeded(section)
        }
        .onChange(of: searchText) { _ in
            drilldown = nil
            scheduleSearchRefresh()
        }
        .onChange(of: section.id) { newSectionID in
            // 关键修复：MusicLibrarySection.id 是 "music-\(rawValue)"（如 "music-albums"），
            // 旧代码用 MusicLibrarySection(rawValue: newSectionID) 解析必然得到 nil，
            // guard 直接 return —— 切换分区时 loadViewState / refreshVisibleContent /
            // drilldown 清理从未执行过。页面只能等后续无关的 libraryRevision 变化
            // 兜底触发刷新才显示内容，表现为「切到另一个分区后长时间载入/难以载入」。
            // 注意 onChange 闭包执行时 self.section 仍是旧值，必须从 newSectionID 解析
            // 新分区（按 id 匹配，别再用 rawValue）。
            guard let newSection = MusicLibrarySection.allCases.first(where: { $0.id == newSectionID }) else { return }
            logMusicPerf("sectionChange -> \(newSectionID)")
            searchRefreshTask?.cancel()
            lyricsRefreshTask?.cancel()
            drilldown = nil
            loadViewState(for: newSection, reset: true)
            refreshVisibleContent(for: newSection, deferred: true)
            presentSectionTipIfNeeded(newSection)
        }
        .onChange(of: sortMode) { _ in
            saveViewState(for: section)
            searchRefreshTask?.cancel()
            drilldown = nil
            refreshVisibleContent(for: section, deferred: true)
        }
        .onChange(of: sortOrder) { _ in
            saveViewState(for: section)
            searchRefreshTask?.cancel()
            drilldown = nil
            refreshVisibleContent(for: section, deferred: true)
        }
        .onChange(of: filterMode) { _ in
            saveViewState(for: section)
            searchRefreshTask?.cancel()
            drilldown = nil
            refreshVisibleContent(for: section, deferred: true)
        }
        .onChange(of: appState.libraryRevision) { _ in
            searchRefreshTask?.cancel()
            if drilldown == nil {
                refreshVisibleContent(for: section, deferred: true)
            } else {
                refreshActivePlaylistDrilldown()
            }
        }
        // 喜欢/评级等乐观更新只改音乐内容修订号（不 bump libraryRevision），
        // 列表行内的「喜欢」徽标等需据此重建快照刷新。
        .onChange(of: appState.musicContentRevision) { _ in
            searchRefreshTask?.cancel()
            if drilldown == nil {
                refreshVisibleContent(for: section, deferred: true)
            } else {
                refreshActivePlaylistDrilldown()
            }
        }
        .onChange(of: appState.musicProjectionRevision) { _ in
            guard section == .albums || section == .artists else { return }
            searchRefreshTask?.cancel()
            if drilldown == nil {
                refreshVisibleContent(for: section, deferred: true)
            }
        }
        .onChange(of: appState.favoriteRevision) { _ in
            // Refresh only when viewing the favorites filter or the favorites drilldown.
            if filterMode == .favorites || section == .favorites {
                searchRefreshTask?.cancel()
                if drilldown == nil {
                    refreshVisibleContent(for: section, deferred: true)
                } else {
                    refreshActivePlaylistDrilldown()
                }
            }
        }
        .onDisappear {
            contentRefreshTask?.cancel()
            searchRefreshTask?.cancel()
            lyricsRefreshTask?.cancel()
        }
        .sheet(item: $metadataItem) { item in
            MetadataSearchView(item: item)
                .environmentObject(appState)
        }
        .sheet(item: $playlistCreationRequest) { request in
            MusicPlaylistCreationSheet(
                request: request,
                onCreate: { name in
                    appState.createMusicPlaylist(name: name, tracks: request.tracks)
                    playlistCreationRequest = nil
                },
                onCancel: {
                    playlistCreationRequest = nil
                }
            )
            .environmentObject(appState)
        }
        .sheet(item: $playlistRenameRequest) { request in
            MusicPlaylistRenameSheet(
                request: request,
                onRename: { name in
                    appState.renameMusicPlaylist(request.playlist, name: name)
                    if let updated = appState.musicPlaylists.first(where: { $0.id == request.playlist.id }) {
                        drilldown = .playlist(updated, appState.musicTracks(in: updated))
                    }
                    playlistRenameRequest = nil
                },
                onCancel: {
                    playlistRenameRequest = nil
                }
            )
            .environmentObject(appState)
        }
        .confirmationDialog(
            "删除歌单？",
            isPresented: $isConfirmingPlaylistDeletion,
            presenting: playlistPendingDeletion
        ) { playlist in
            Button("删除“\(playlist.name)”", role: .destructive) {
                appState.deleteMusicPlaylist(playlist)
                if case .playlist(let activePlaylist, _) = drilldown,
                   activePlaylist.id == playlist.id {
                    drilldown = nil
                }
                playlistPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                playlistPendingDeletion = nil
            }
        } message: { playlist in
            Text("只会删掉这个歌单，你电脑里的歌曲文件不会被移动、删除或改名。")
        }
        .onChange(of: appState.musicPlaylists) { _ in
            refreshActivePlaylistDrilldown()
        }
    }

    private func presentSectionTipIfNeeded(_ targetSection: MusicLibrarySection) {
        guard targetSection == .songs else { return }
        appState.showInterfaceTipOnce(
            key: "music.songs.headerTop",
            message: "歌曲很多时，轻点列名行就可以回到顶部。"
        )
    }

    private var scrollingBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                    Color.clear.frame(height: 0).id("top")
                    pageHeader
                    if section != .playlists {
                        musicControls
                    }
                    content
                }
                .pageContainer()
            }
            .suppressHoverEffectsDuringScroll()
            .overlay(alignment: .bottomTrailing) {
                scrollTopButton {
                    withAnimation(AppMotion.fast) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
        }
    }

    private var standaloneLongListBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                pageHeader
                if section != .playlists, drilldown == nil {
                    musicControls
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.pageVertical)
            .padding(.bottom, AppSpacing.headerToControls)

            content
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fixedHeaderScrollableBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.top, AppSpacing.pageVertical)
                .padding(.bottom, AppSpacing.headerToControls)

            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("top")
                    content
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.bottom, AppSpacing.headerToControls)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .suppressHoverEffectsDuringScroll()
                .overlay(alignment: .bottomTrailing) {
                    scrollTopButton {
                        withAnimation(AppMotion.fast) {
                            proxy.scrollTo("top", anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var scrollableCollectionListBody: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width - AppSpacing.pageHorizontal * 2, 1)
            let albumColumns = musicCollectionColumnCount(for: availableWidth, metrics: .album)
            let artistColumns = musicCollectionColumnCount(for: availableWidth, metrics: .artist)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("top")

                        VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                            pageHeader
                            musicControls
                        }
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.top, AppSpacing.pageVertical)
                        .padding(.bottom, AppSpacing.headerToControls)

                        collectionListRows(albumColumns: albumColumns, artistColumns: artistColumns)

                        Color.clear
                            .frame(height: collectionListBottomInset)
                    }
                }
                .suppressHoverEffectsDuringScroll()
                .transaction { transaction in
                    transaction.animation = nil
                }
                .overlay(alignment: .bottomTrailing) {
                    scrollTopButton {
                        withAnimation(AppMotion.fast) {
                            scrollProxy.scrollTo("top", anchor: .top)
                        }
                    }
                }
                .onChange(of: drilldown?.id) { drilldownID in
                    guard drilldownID == nil, let anchorID = collectionReturnAnchorID else { return }
                    restoreCollectionAnchor(anchorID, scrollProxy: scrollProxy)
                }
                // ★根因：`usesScrollableCollectionList` 为 false 时（drilldown 非 nil），这整个
                // view（连同它的 ScrollViewReader/.onChange）会被 `if` 分支整个卸载；从专辑/艺术家
                // 详情"返回"那一刻，drilldown 变 nil 触发的正是 usesScrollableCollectionList 重新
                // 变 true、本 view 重新创建——但 .onChange 只能捕捉"自己已经挂载期间"发生的变化，
                // 这次变化恰好发生在它被卸载的空档，永远等不到，所以之前"返回"必定跳回顶部。
                // 改为在 view 重新出现时（.onAppear）主动检查有没有待恢复的锚点，不依赖"捕捉到变化"。
                .onAppear {
                    guard let anchorID = collectionReturnAnchorID else { return }
                    restoreCollectionAnchor(anchorID, scrollProxy: scrollProxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pageHeader: some View {
        PageHeader(title: section.title, subtitle: subtitle, systemImage: section.systemImage) {
            GlassSearchField(placeholder: "搜索音乐", text: $searchText, minWidth: 158, maxWidth: 226)
            if section == .playlists {
                Button {
                    onCreateSmartPlaylist()
                } label: {
                    Label("新建智能歌单", systemImage: "sparkles")
                }
                Button {
                    importM3UPlaylist()
                } label: {
                    Label("导入 M3U", systemImage: "square.and.arrow.down")
                }
                Button {
                    presentPlaylistCreation(tracks: [], suggestedName: "新歌单")
                } label: {
                    Label("新建歌单", systemImage: "plus")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 34, prominent: true))
            } else {
                Button {
                    appState.scanSources(for: .music(section))
                } label: {
                    Label("扫描", systemImage: "arrow.clockwise")
                }
                .disabled(appState.sources.isEmpty || appState.isScanning)

                if showsResetAllPlayCountAction {
                    Button {
                        appState.resetAllMusicPlayCounts()
                    } label: {
                        Label("重置播放次数", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(appState.musicTracks.allSatisfy { ($0.playCount ?? 0) == 0 })
                }
            }
            if showsPlaybackHistoryAction {
                Button(role: .destructive) {
                    appState.clearPlaybackHistory(playbackTraceTracks)
                } label: {
                    Label("清除记录", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.red)
                }
                .disabled(playbackTraceTracks.isEmpty)
            }
        }
    }

    private func scrollTopButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .frame(width: 38, height: 38)
        }
        .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 19, horizontalPadding: 0, minHeight: 38, thickness: 1.04))
        // 右边界与音乐底栏（含收起后的迷你栏）对齐：两者右缘都在 窗宽-24（musicMiniPlayerOuterInset=24）。
        .padding(.trailing, 24)
        .padding(.bottom, scrollTopButtonBottomPadding)
        .help("返回顶部")
    }

    private var usesScrollableCollectionList: Bool {
        drilldown == nil && (section == .albums || section == .artists)
    }

    private var usesStandaloneLongList: Bool {
        if drilldown != nil {
            return true
        }
        switch section {
        case .songs, .recent, .favorites, .unmatched:
            return true
        case .albums, .artists, .playlists:
            return false
        }
    }

    @ViewBuilder
    private func collectionListRows(albumColumns: Int, artistColumns: Int) -> some View {
        if isPreparingVisibleContent || visibleContentIsOutOfDate {
            AppLoadingView(title: "正在载入\(section.title)", systemImage: section.systemImage, rowCount: 5)
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.bottom, AppSpacing.headerToControls)
        } else {
            switch section {
            case .albums:
                if displayedAlbumGroups.isEmpty {
                    EmptyStateView(title: "暂无专辑", systemImage: "square.stack", message: "扫描音乐目录后，歌曲会按专辑信息归类。")
                        .staticSurfaceBackground(cornerRadius: 22)
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.bottom, AppSpacing.headerToControls)
                } else {
                    ForEach(0..<musicAlbumRowCount(columns: albumColumns), id: \.self) { rowIndex in
                        HStack(alignment: .top, spacing: MusicCollectionGridMetrics.album.columnSpacing) {
                            ForEach(0..<albumColumns, id: \.self) { columnIndex in
                                let index = rowIndex * albumColumns + columnIndex
                                if index < displayedAlbumGroups.count {
                                    let album = displayedAlbumGroups[index]
                                    MusicAlbumCard(
                                        album: album,
                                        showsResetPlayCountAction: sortMode == .mostPlayed,
                                        onOpen: {
                                            openAlbumDrilldown(album, anchorID: collectionRowAnchorID(prefix: "music-album-row", rowIndex: rowIndex))
                                        },
                                        onPlay: { appState.replaceMusicQueueAndPlay(tracks(for: album)) },
                                        onCreatePlaylist: { playlistCreationRequest = $0 },
                                        onResetPlayCounts: { appState.resetMusicPlayCounts(tracks(for: album)) },
                                        tracksProvider: { appState.musicTracks(inAlbum: album.summary) }
                                    )
                                    .frame(maxWidth: .infinity, alignment: .top)
                                    .id(collectionAnchorID(for: album))
                                } else {
                                    Color.clear
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.top, rowIndex == 0 ? MusicCollectionGridMetrics.album.firstRowTopInset : 0)
                        .padding(.bottom, MusicCollectionGridMetrics.album.rowBottomInset)
                        .id(collectionRowAnchorID(prefix: "music-album-row", rowIndex: rowIndex))
                    }
                }
            case .artists:
                if displayedArtistGroups.isEmpty {
                    EmptyStateView(title: "暂无艺术家", systemImage: "person.2", message: "扫描音乐目录后，歌曲会按艺术家信息归类。")
                        .staticSurfaceBackground(cornerRadius: 22)
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.bottom, AppSpacing.headerToControls)
                } else {
                    ForEach(0..<musicArtistRowCount(columns: artistColumns), id: \.self) { rowIndex in
                        HStack(alignment: .top, spacing: MusicCollectionGridMetrics.artist.columnSpacing) {
                            ForEach(0..<artistColumns, id: \.self) { columnIndex in
                                let index = rowIndex * artistColumns + columnIndex
                                if index < displayedArtistGroups.count {
                                    let artist = displayedArtistGroups[index]
                                    MusicArtistRow(
                                        artist: artist,
                                        showsResetPlayCountAction: sortMode == .mostPlayed,
                                        onOpen: {
                                            openArtistDrilldown(artist, anchorID: collectionRowAnchorID(prefix: "music-artist-row", rowIndex: rowIndex))
                                        },
                                        onPlay: { appState.replaceMusicQueueAndPlay(tracks(for: artist)) },
                                        onCreatePlaylist: { playlistCreationRequest = $0 },
                                        onResetPlayCounts: { appState.resetMusicPlayCounts(tracks(for: artist)) },
                                        tracksProvider: { appState.musicTracks(inArtist: artist.summary) }
                                    )
                                    .frame(maxWidth: .infinity, alignment: .top)
                                    .id(collectionAnchorID(for: artist))
                                } else {
                                    Color.clear
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.top, rowIndex == 0 ? MusicCollectionGridMetrics.artist.firstRowTopInset : 0)
                        .padding(.bottom, MusicCollectionGridMetrics.artist.rowBottomInset)
                        .id(collectionRowAnchorID(prefix: "music-artist-row", rowIndex: rowIndex))
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private func musicCollectionColumnCount(for width: CGFloat, metrics: MusicCollectionGridMetrics) -> Int {
        let availableWidth = max(width, metrics.minimumItemWidth)
        let rawCount = Int((availableWidth + metrics.columnSpacing) / (metrics.minimumItemWidth + metrics.columnSpacing))
        return min(metrics.maximumColumns, max(metrics.minimumColumns, rawCount))
    }

    private func musicAlbumRowCount(columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        return (displayedAlbumGroups.count + columns - 1) / columns
    }

    private func musicArtistRowCount(columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        return (displayedArtistGroups.count + columns - 1) / columns
    }

    private var collectionListBottomInset: CGFloat {
        appState.activePlayerItem?.type == .music ? 106 : 16
    }

    private var playbackTraceTracks: [MediaItem] {
        displayedTrackRows.map(\.track).filter(\.hasPlaybackTrace)
    }

    private var showsPlaybackHistoryAction: Bool {
        section == .recent
    }

    private var displayedTrackRows: [MusicTrackRowModel] {
        if visibleContentSectionID == section.id {
            return visibleTrackRows
        }
        return currentSnapshot?.rows ?? []
    }

    private var displayedAlbumGroups: [MusicAlbumGroup] {
        if visibleContentSectionID == section.id {
            return visibleAlbumGroups
        }
        return currentSnapshot?.albums ?? []
    }

    private var displayedArtistGroups: [MusicArtistGroup] {
        if visibleContentSectionID == section.id {
            return visibleArtistGroups
        }
        return currentSnapshot?.artists ?? []
    }

    private var currentSnapshot: MusicLibrarySnapshotCache.Snapshot? {
        guard visibleContentSectionID != section.id else { return nil }
        return MusicLibrarySnapshotCache.snapshot(for: snapshotKey(for: section))
    }

    private func snapshotKey(for targetSection: MusicLibrarySection) -> MusicLibrarySnapshotCache.Key {
        MusicLibrarySnapshotCache.Key(
            section: targetSection,
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            sortMode: sortMode,
            sortOrder: sortOrder,
            filterMode: filterMode,
            // 用音乐内容修订号而非全局 libraryRevision：视频入库/观看进度/健康检查等
            // 与音乐无关的修订不再打失效音乐页快照，切换子页面可以稳定命中缓存秒开。
            revision: appState.musicContentRevision,
            projectionRevision: appState.musicProjectionRevision,
            // 歌词存在性只影响「有歌词」筛选；其它页面不应因为后台扫完歌词文件而整页快照失效、
            // 重新分组专辑/艺术家或重建上千行歌曲模型。
            lyricsRevision: filterMode == .withLyrics ? MusicLyricsPresenceCache.revision : 0
        )
    }

    private var visibleContentIsOutOfDate: Bool {
        visibleContentSectionID != section.id &&
        MusicLibrarySnapshotCache.snapshot(for: snapshotKey(for: section)) == nil
    }

    private func logMusicPerf(_ message: String) {
        guard appState.settings.debugLoggingEnabled else { return }
        appState.logger?.log("[MusicPerf] \(message)")
    }

    private func refreshVisibleContent(for targetSection: MusicLibrarySection, deferred: Bool = false) {
        let refreshStart = Date()
        contentRefreshTask?.cancel()
        let needsTrackInput = targetSection != .albums && targetSection != .artists ||
            filterMode == .withLyrics ||
            filterMode == .unmatched
        let baseTracks = needsTrackInput ? appState.items(for: .music(targetSection), searchText: "") : []
        if filterMode == .withLyrics {
            scheduleLyricsPresenceRefresh(for: baseTracks, section: targetSection)
        } else {
            lyricsRefreshTask?.cancel()
        }

        let key = snapshotKey(for: targetSection)
        if let snapshot = MusicLibrarySnapshotCache.snapshot(for: key) {
            visibleTrackRows = snapshot.rows
            visibleAlbumGroups = snapshot.albums
            visibleArtistGroups = snapshot.artists
            visibleContentSectionID = targetSection.id
            isPreparingVisibleContent = false
            logMusicPerf("refresh[\(targetSection.rawValue)] cache-hit \(String(format: "%.1f", Date().timeIntervalSince(refreshStart) * 1000))ms rows=\(snapshot.rows.count)")
            return
        }
        logMusicPerf("refresh[\(targetSection.rawValue)] cache-miss deferred=\(deferred) tracks=\(baseTracks.count)")

        // Only clear section ID when section changes; keep old items visible during
        // filter/sort/revision updates so the page header doesn't jump or flash.
        if visibleContentSectionID != targetSection.id {
            visibleContentSectionID = ""
        }
        isPreparingVisibleContent = true
        contentRefreshTask = Task { @MainActor in
            if deferred {
                await Task.yield()
            }
            await computeVisibleContent(for: targetSection, baseTracks: baseTracks, key: key, refreshStart: refreshStart)
        }
    }

    private func computeVisibleContent(
        for targetSection: MusicLibrarySection,
        baseTracks: [MediaItem],
        key: MusicLibrarySnapshotCache.Key,
        refreshStart: Date = Date()
    ) async {
        guard !Task.isCancelled else { return }
        guard key == snapshotKey(for: targetSection) else {
            logMusicPerf("compute[\(targetSection.rawValue)] stale-key-abort \(String(format: "%.1f", Date().timeIntervalSince(refreshStart) * 1000))ms")
            return
        }
        let needsTrackInput = targetSection != .albums && targetSection != .artists ||
            key.filterMode == .withLyrics ||
            key.filterMode == .unmatched

        let input = MusicLibrarySnapshotBuildInput(
            section: targetSection,
            tracks: baseTracks,
            tracksByID: needsTrackInput ? appState.cachedMusicTracksByID : [:],
            albums: appState.musicAlbumSummaries,
            artists: appState.musicArtistSummaries,
            searchText: key.searchText,
            sortMode: key.sortMode,
            sortOrder: key.sortOrder,
            filterMode: key.filterMode
        )
        let buildStart = Date()
        let snapshot = await MusicLibrarySnapshotCache.resolve(for: key) {
            MusicLibrarySnapshotBuilder.snapshot(from: input)
        }
        logMusicPerf("compute[\(targetSection.rawValue)] resolve \(String(format: "%.1f", Date().timeIntervalSince(buildStart) * 1000))ms sinceRefresh \(String(format: "%.1f", Date().timeIntervalSince(refreshStart) * 1000))ms")

        guard !Task.isCancelled else { return }
        guard key == snapshotKey(for: targetSection) else { return }
        visibleTrackRows = snapshot.rows
        visibleAlbumGroups = snapshot.albums
        visibleArtistGroups = snapshot.artists
        visibleContentSectionID = targetSection.id
        isPreparingVisibleContent = false
        MusicLibrarySnapshotCache.store(snapshot, for: key)
    }

    private func scheduleSearchRefresh() {
        searchRefreshTask?.cancel()
        let targetSection = section
        searchRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            guard section.id == targetSection.id else { return }
            refreshVisibleContent(for: targetSection, deferred: true)
        }
    }

    private var musicControls: some View {
        AppAdaptiveControlBar {
            MusicFilterModeCapsules(selection: $filterMode, modes: availableFilterModes)
        } trailing: {
            sortModeMenu
        }
    }

    private var sortModeMenu: some View {
        GlassMenuButton(title: "\(sortMode.title(for: section)) · \(sortOrder.titleSuffix)") {
            ForEach(availableSortModes) { mode in
                Button {
                    selectSortMode(mode)
                } label: {
                    Label(mode.title(for: section), systemImage: sortMode == mode ? sortOrder.systemImage : "circle")
                }
            }
        }
    }

    private func presentPlaylistCreation(tracks: [MediaItem], suggestedName: String) {
        playlistCreationRequest = MusicPlaylistCreationRequest(
            tracks: tracks,
            suggestedName: suggestedName
        )
    }

    private func importM3UPlaylist() {
        let panel = NSOpenPanel()
        panel.title = "导入 M3U 歌单"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let baseName = url.deletingPathExtension().lastPathComponent
        let playlistName = baseName.isEmpty ? "导入歌单" : baseName
        Task { @MainActor in
            let count = await appState.importMusicPlaylistAsync(fromM3U: url, name: playlistName)
            if count > 0 {
                appState.alert = AppAlert(title: "导入完成", message: "已从 M3U 创建歌单，匹配到 \(count) 首库内歌曲。")
            }
        }
    }

    private func refreshActivePlaylistDrilldown() {
        guard case .playlist(let playlist, _) = drilldown else { return }
        if MusicFavoritePlaylist.isFavorite(playlist) {
            let updated = MusicFavoritePlaylist.make(from: appState.musicTracks)
            drilldown = .playlist(updated, tracks(for: updated))
            return
        }
        guard let updated = appState.musicPlaylists.first(where: { $0.id == playlist.id }) else {
            drilldown = nil
            return
        }
        drilldown = .playlist(updated, appState.musicTracks(in: updated))
    }

    private func scheduleLyricsPresenceRefresh(for tracks: [MediaItem], section targetSection: MusicLibrarySection) {
        lyricsRefreshTask?.cancel()
        let filePaths = tracks.map(\.filePath)
        lyricsRefreshTask = Task { @MainActor in
            let changed = await MusicLyricsPresenceCache.warmCache(filePaths: filePaths)
            guard changed, !Task.isCancelled, section.id == targetSection.id else { return }
            refreshVisibleContent(for: targetSection)
        }
    }

    private func stateKeyPrefix(for targetSection: MusicLibrarySection) -> String {
        "MediaLib.musicState.\(targetSection.rawValue)"
    }

    private func loadViewState(for targetSection: MusicLibrarySection, reset: Bool = false) {
        if reset {
            didLoadViewState = false
            sortMode = .title
            sortOrder = .primary
            filterMode = .all
        }
        guard !didLoadViewState else { return }
        didLoadViewState = true
        let stateKeyPrefix = stateKeyPrefix(for: targetSection)
        sortMode = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).sort")
            .flatMap(MusicSortMode.init(rawValue:)) ?? .title
        if !availableSortModes(for: targetSection).contains(sortMode) {
            sortMode = .title
        }
        sortOrder = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).sortOrder")
            .flatMap(MusicSortOrder.init(rawValue:)) ?? .primary
        filterMode = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).filter")
            .flatMap(MusicFilterMode.init(rawValue:)) ?? .all
        if !availableFilterModes(for: targetSection).contains(filterMode) {
            filterMode = .all
        }
    }

    private func saveViewState(for targetSection: MusicLibrarySection) {
        guard didLoadViewState else { return }
        let stateKeyPrefix = stateKeyPrefix(for: targetSection)
        UserDefaults.standard.set(sortMode.rawValue, forKey: "\(stateKeyPrefix).sort")
        UserDefaults.standard.set(sortOrder.rawValue, forKey: "\(stateKeyPrefix).sortOrder")
        UserDefaults.standard.set(filterMode.rawValue, forKey: "\(stateKeyPrefix).filter")
    }

    private var availableSortModes: [MusicSortMode] {
        availableSortModes(for: section)
    }

    private func availableSortModes(for targetSection: MusicLibrarySection) -> [MusicSortMode] {
        switch targetSection {
        case .artists:
            return [.title, .workCount, .mostPlayed]
        case .albums:
            return [.title, .artist, .recent, .mostPlayed]
        case .songs, .recent, .favorites, .unmatched:
            return [.title, .artist, .album, .mostPlayed, .recent, .duration]
        case .playlists:
            return [.title]
        }
    }

    private var availableFilterModes: [MusicFilterMode] {
        availableFilterModes(for: section)
    }

    private func availableFilterModes(for targetSection: MusicLibrarySection) -> [MusicFilterMode] {
        targetSection == .artists ? [.all] : MusicFilterMode.allCases
    }

    private var showsResetAllPlayCountAction: Bool {
        sortMode == .mostPlayed && (section == .songs || section == .albums || section == .artists)
    }

    private func selectSortMode(_ mode: MusicSortMode) {
        if sortMode == mode {
            sortOrder.toggle()
        } else {
            sortMode = mode
            sortOrder = .primary
        }
    }

    private var subtitle: String {
        switch section {
        case .songs: return "浏览音乐库中的全部歌曲 · \(displayedTrackRows.count) 首"
        case .albums: return "按专辑浏览歌曲 · \(displayedAlbumGroups.count) 张"
        case .artists: return "按艺术家浏览歌曲 · \(displayedArtistGroups.count) 位"
        case .playlists: return "管理手动歌单与智能歌单 · \(filteredPlaylists.count) 个"
        case .recent: return "查看最近播放的歌曲 · \(displayedTrackRows.count) 首"
        case .favorites: return "查看已喜欢的歌曲 · \(displayedTrackRows.count) 首"
        case .unmatched: return "查看信息或封面尚未补全的歌曲 · \(displayedTrackRows.count) 首"
        }
    }

    private var scrollTopButtonBottomPadding: CGFloat {
        appState.activePlayerItem?.type == .music ? 122 : 22
    }

    @ViewBuilder
    private var content: some View {
        if let drilldown {
            MusicCollectionTrackList(
                collection: drilldown,
                rows: rowModels(from: drilldown.tracks),
                onBack: { self.drilldown = nil },
                onPlayAll: { appState.replaceMusicQueueAndPlay(drilldown.tracks) },
                onSearchMetadata: { metadataItem = $0 },
                onCreatePlaylist: { playlistCreationRequest = $0 },
                onRenamePlaylist: { playlistRenameRequest = MusicPlaylistRenameRequest(playlist: $0) },
                onDeletePlaylist: { playlist in
                    playlistPendingDeletion = playlist
                    isConfirmingPlaylistDeletion = true
                },
                onRemoveFromPlaylist: { track, playlist in
                    if MusicFavoritePlaylist.isFavorite(playlist) {
                        if track.favorite {
                            appState.toggleFavorite(track)
                        }
                    } else {
                        appState.removeMusicTracks([track], from: playlist)
                    }
                },
                onReplacePlaylistItems: { playlist, tracks in
                    guard !MusicFavoritePlaylist.isFavorite(playlist) else { return }
                    appState.replaceMusicPlaylistItems(in: playlist, with: tracks)
                }
            )
        } else if isPreparingVisibleContent || visibleContentIsOutOfDate {
            AppLoadingView(title: "正在载入\(section.title)", systemImage: section.systemImage, rowCount: 5)
        } else {
            switch section {
            case .songs, .recent, .favorites, .unmatched:
                if displayedTrackRows.isEmpty {
                    EmptyStateView(title: "暂无\(section.title)", systemImage: section.systemImage, message: "接入音乐媒体源并完成扫描后，歌曲会自动归档。")
                        .staticSurfaceBackground(cornerRadius: 22)
                } else {
                    MusicSongListView(
                        rows: displayedTrackRows,
                        showsHistoryAction: section == .recent,
                        showsResetPlayCountAction: sortMode == .mostPlayed,
                        onSearchMetadata: { metadataItem = $0 },
                        onCreatePlaylist: { playlistCreationRequest = $0 }
                    )
                }
            case .albums:
                if displayedAlbumGroups.isEmpty {
                    EmptyStateView(title: "暂无专辑", systemImage: "square.stack", message: "扫描音乐目录后，歌曲会按专辑信息归类。")
                        .staticSurfaceBackground(cornerRadius: 22)
                } else {
                    ProgressiveMusicAlbumGrid(albums: displayedAlbumGroups, showsResetPlayCountAction: sortMode == .mostPlayed) { album in
                        openAlbumDrilldown(album)
                    } onPlay: { album in
                        appState.replaceMusicQueueAndPlay(tracks(for: album))
                    } onCreatePlaylist: { request in
                        playlistCreationRequest = request
                    } onResetPlayCounts: { album in
                        appState.resetMusicPlayCounts(tracks(for: album))
                    }
                }
            case .artists:
                if displayedArtistGroups.isEmpty {
                    EmptyStateView(title: "暂无艺术家", systemImage: "person.2", message: "扫描音乐目录后，歌曲会按艺术家信息归类。")
                        .staticSurfaceBackground(cornerRadius: 22)
                } else {
                    ProgressiveMusicArtistList(artists: displayedArtistGroups, showsResetPlayCountAction: sortMode == .mostPlayed) { artist in
                        openArtistDrilldown(artist)
                    } onPlay: { artist in
                        appState.replaceMusicQueueAndPlay(tracks(for: artist))
                    } onCreatePlaylist: { request in
                        playlistCreationRequest = request
                    } onResetPlayCounts: { artist in
                        appState.resetMusicPlayCounts(tracks(for: artist))
                    }
                }
            case .playlists:
                if filteredPlaylists.isEmpty {
                    EmptyStateView(title: "未找到匹配歌单", systemImage: "magnifyingglass", message: "可使用歌单名、艺术家或歌曲关键词继续筛选。")
                        .staticSurfaceBackground(cornerRadius: 22)
                } else {
                    MusicPlaylistsOverview(playlists: filteredPlaylists) { playlist in
                        drilldown = .playlist(playlist, tracks(for: playlist))
                    } onPlay: { playlist in
                        appState.replaceMusicQueueAndPlay(tracks(for: playlist))
                    } onRename: { playlist in
                        guard !MusicFavoritePlaylist.isFavorite(playlist) else { return }
                        playlistRenameRequest = MusicPlaylistRenameRequest(playlist: playlist)
                    } onDelete: { playlist in
                        guard !MusicFavoritePlaylist.isFavorite(playlist) else { return }
                        playlistPendingDeletion = playlist
                        isConfirmingPlaylistDeletion = true
                    }
                }
            }
        }
    }

    private var filteredPlaylists: [MusicPlaylist] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlists = displayPlaylists
        guard !query.isEmpty else { return playlists }
        return playlists.filter { playlist in
            PinyinSearchMatcher.matches(query: query, in: [playlist.name])
        }
    }

    private var displayPlaylists: [MusicPlaylist] {
        [MusicFavoritePlaylist.make(from: appState.musicTracks)] + appState.musicPlaylists
    }

    private func tracks(for playlist: MusicPlaylist) -> [MediaItem] {
        if MusicFavoritePlaylist.isFavorite(playlist) {
            return appState.musicTracks.filter(\.favorite)
        }
        return appState.musicTracks(in: playlist)
    }

    private func tracks(for album: MusicAlbumGroup) -> [MediaItem] {
        appState.musicTracks(inAlbum: album.summary)
    }

    private func tracks(for artist: MusicArtistGroup) -> [MediaItem] {
        appState.musicTracks(inArtist: artist.summary)
    }

    private func rowModels(from tracks: [MediaItem]) -> [MusicTrackRowModel] {
        MusicLibrarySnapshotBuilder.rowModels(from: tracks)
    }

    private func openAlbumDrilldown(_ album: MusicAlbumGroup, anchorID: String? = nil) {
        collectionReturnAnchorID = anchorID ?? collectionAnchorID(for: album)
        drilldown = .album(album, tracks(for: album))
    }

    private func openArtistDrilldown(_ artist: MusicArtistGroup, anchorID: String? = nil) {
        collectionReturnAnchorID = anchorID ?? collectionAnchorID(for: artist)
        drilldown = .artist(artist, tracks(for: artist))
    }

    private func collectionRowAnchorID(prefix: String, rowIndex: Int) -> String {
        "\(prefix)-\(rowIndex)"
    }

    private func collectionAnchorID(for album: MusicAlbumGroup) -> String {
        "music-album-\(album.id)"
    }

    private func collectionAnchorID(for artist: MusicArtistGroup) -> String {
        "music-artist-\(artist.id)"
    }

    private func restoreCollectionAnchor(_ anchorID: String, scrollProxy: ScrollViewProxy) {
        // ★为什么上一版 onAppear + 单次 Task.yield 仍然跳回顶部：目标专辑/艺术家卡片在 LazyVStack
        // 里是懒加载的，返回那一刻列表刚重建、只渲染了顶部几行，`scrollTo` 找不到还没被创建的目标
        // 行就被丢弃了。改为连续多帧重试：每一帧都发一次 scrollTo，直到 LazyVStack 逐步把目标行
        // 排布出来、滚动真正落位。重试期间正好是用户刚点「返回」、不会立刻手动滚动的窗口，安全。
        collectionAnchorRestoreTask?.cancel()
        collectionAnchorRestoreTask = Task { @MainActor in
            for _ in 0..<16 {
                if Task.isCancelled { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                transaction.animation = nil
                withTransaction(transaction) {
                    scrollProxy.scrollTo(anchorID, anchor: .center)
                }
                try? await Task.sleep(nanoseconds: 32_000_000)
            }
            // 恢复完成后清掉锚点：collectionReturnAnchorID 每次进入 drilldown 都会重设，
            // 清掉可避免后续无关的 onAppear（切窗口/主题刷新等）又把列表拽回旧位置。
            collectionReturnAnchorID = nil
        }
    }
}

private struct MusicSongListView: View {
    @EnvironmentObject private var appState: AppState
    let rows: [MusicTrackRowModel]
    var showsHistoryAction: Bool = false
    var showsResetPlayCountAction: Bool = false
    var showsMetadataActions: Bool = true
    // 设置后：在该列表里播放某首歌会把队列替换为这些歌曲（用于专辑/艺术家详情页）。
    var queueContext: [MediaItem]? = nil
    let onSearchMetadata: (MediaItem) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            // 用 ScrollView + LazyVStack 取代原生 List：彻底避开 NSTableView 整行蓝色高亮，
            // 右键能精确命中单首歌。LazyVStack 仍懒加载行，支持上千首歌。
            // 列名行冻结：用 LazyVStack 原生的 pinnedViews(.sectionHeaders) 把 Section 的 header 钉在顶部，
            // 滚动行从它下方穿过（header 加与卡片同色的 cleanPanelFill 底以干净遮挡）。这是最稳的固定表头方式，
            // ScrollView 仍是 reader 的唯一子视图、照常撑满高度，不会出现之前 VStack / safeAreaInset 的高度异常。
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // 锚点位于吸顶 Section 之前，回顶后表头和真正第一行都会回到初始位置。
                    Color.clear.frame(height: 0).id("song-list-top")

                    Section {
                        ForEach(rows) { row in
                            MusicSongRow(
                                row: row,
                                showsHistoryAction: showsHistoryAction,
                                showsResetPlayCountAction: showsResetPlayCountAction,
                                showsMetadataActions: showsMetadataActions,
                                queueContext: queueContext,
                                onSearchMetadata: onSearchMetadata,
                                onCreatePlaylist: onCreatePlaylist
                            )
                            .id(row.id)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }

                        Color.clear.frame(height: listBottomInset)
                    } header: {
                        // 点击列名行即回到顶部（取代原右下角的返回顶部按钮）。
                        MusicSongHeader(trailingActionColumns: trailingActionColumns)
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                            .padding(.bottom, 6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(AppMotion.fast) {
                                    proxy.scrollTo("song-list-top", anchor: .top)
                                }
                            }
                            .help("点击列名行回到顶部")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
        .bleedingListCard()
    }

    private var listBottomInset: CGFloat {
        appState.activePlayerItem?.type == .music ? 106 : 16
    }

    private var trailingActionColumns: Int {
        showsMetadataActions ? 1 : 0
    }
}

private struct MusicSongListSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        ReferenceCardSurface(cornerRadius: cornerRadius)
    }
}

private extension View {
    /// 列表外层卡片遵守首页小组件标准：完整圆角、白底细描边、常态无投影。
    func bleedingListCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .background(alignment: .top) {
                MusicSongListSurface(cornerRadius: cornerRadius)
            }
    }
}

private enum MusicCollectionDrilldown: Identifiable {
    case album(MusicAlbumGroup, [MediaItem])
    case artist(MusicArtistGroup, [MediaItem])
    case playlist(MusicPlaylist, [MediaItem])

    var id: String {
        switch self {
        case .album(let album, _): return "album-\(album.id)"
        case .artist(let artist, _): return "artist-\(artist.id)"
        case .playlist(let playlist, _): return "playlist-\(playlist.id)"
        }
    }

    var title: String {
        switch self {
        case .album(let album, _): return album.key.title
        case .artist(let artist, _): return artist.name
        case .playlist(let playlist, _): return playlist.name
        }
    }

    var subtitle: String {
        switch self {
        case .album(let album, let tracks): return "\(album.key.artist) · \(tracks.count) 首歌曲"
        case .artist(let artist, let tracks): return "\(tracks.count) 首歌曲 · \(artist.albumCount) 张专辑"
        case .playlist(_, let tracks): return "\(tracks.count) 首歌曲"
        }
    }

    var systemImage: String {
        switch self {
        case .album: return "square.stack"
        case .artist: return "person.2"
        case .playlist: return "music.note.list"
        }
    }

    var tracks: [MediaItem] {
        switch self {
        case .album(_, let tracks): return tracks
        case .artist(_, let tracks): return tracks
        case .playlist(_, let tracks): return tracks
        }
    }

    var playlist: MusicPlaylist? {
        if case .playlist(let playlist, _) = self {
            return playlist
        }
        return nil
    }

}

private struct MusicCollectionTrackList: View {
    @EnvironmentObject private var appState: AppState
    let collection: MusicCollectionDrilldown
    let rows: [MusicTrackRowModel]
    let onBack: () -> Void
    let onPlayAll: () -> Void
    let onSearchMetadata: (MediaItem) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    let onRenamePlaylist: (MusicPlaylist) -> Void
    let onDeletePlaylist: (MusicPlaylist) -> Void
    let onRemoveFromPlaylist: (MediaItem, MusicPlaylist) -> Void
    let onReplacePlaylistItems: (MusicPlaylist, [MediaItem]) -> Void

    private func exportM3U(_ playlist: MusicPlaylist) {
        let panel = NSSavePanel()
        panel.title = "导出歌单为 M3U"
        panel.nameFieldStringValue = "\(playlist.name).m3u"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await MusicPlaylistM3UFileWriter.writeContent(appState.musicPlaylistM3UContent(playlist), to: url)
            } catch {
                appState.alert = AppAlert(title: "导出失败", message: error.localizedDescription)
            }
        }
    }

    var body: some View {
        let tracks = collection.tracks
        let playlist = collection.playlist
        let isFavoritePlaylist = playlist.map(MusicFavoritePlaylist.isFavorite) ?? false

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 8, minHeight: 30))
                .help("返回")

                PlayfulSymbolIcon(systemImage: collection.systemImage, size: 30)

                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: collection.title, font: .title3.weight(.semibold))
                        .frame(height: 25, alignment: .leading)
                    Text(collection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if let playlist {
                    Button {
                        exportM3U(playlist)
                    } label: {
                        Label("导出 M3U", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: AppControlMetrics.defaultButtonHeight))
                    .disabled(tracks.isEmpty)
                }

                if let playlist, !isFavoritePlaylist {
                    Button {
                        onRenamePlaylist(playlist)
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: AppControlMetrics.defaultButtonHeight))

                    Button(role: .destructive) {
                        onDeletePlaylist(playlist)
                    } label: {
                        Label("删除", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: AppControlMetrics.defaultButtonHeight))
                }

                if playlist == nil {
                    MusicPlaylistActionsMenu(
                        tracks: tracks,
                        title: "存入歌单",
                        newPlaylistName: "新建歌单",
                        suggestedName: collection.title,
                        onCreateNew: onCreatePlaylist
                    )
                }

                Button {
                    onPlayAll()
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: AppControlMetrics.defaultButtonHeight, prominent: true))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .staticSurfaceBackground(cornerRadius: AppRadius.card)

            if let playlist {
                MusicPlaylistTrackListView(
                    playlist: playlist,
                    rows: rows,
                    onSearchMetadata: onSearchMetadata,
                    onCreatePlaylist: onCreatePlaylist,
                    onRemoveFromPlaylist: { track in
                        onRemoveFromPlaylist(track, playlist)
                    },
                    allowsReordering: !isFavoritePlaylist,
                    onCommitOrder: { tracks in
                        onReplacePlaylistItems(playlist, tracks)
                    }
                )
            } else {
                MusicSongListView(
                    rows: rows,
                    showsResetPlayCountAction: false,
                    // 专辑/艺术家详情页：点歌播放时把队列替换为该集合的全部歌曲。
                    queueContext: tracks,
                    onSearchMetadata: onSearchMetadata,
                    onCreatePlaylist: onCreatePlaylist
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MusicTrackRowModel: Identifiable, Sendable {
    let track: MediaItem
    let titleText: String
    let fileName: String?
    let artistText: String
    let albumText: String
    let hasLocalLyrics: Bool
    let durationText: String

    var id: String { track.id }
}

struct MusicCompactStatusBadge: View {
    let title: String
    let systemImage: String
    var tint: Color = AppColors.selectedGlassTint

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(AppColors.cleanFieldFill.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.18), lineWidth: 0.65)
            }
            .fixedSize()
    }
}

private struct MusicPlaylistTrackListView: View {
    @EnvironmentObject private var appState: AppState
    let playlist: MusicPlaylist
    let rows: [MusicTrackRowModel]
    let onSearchMetadata: (MediaItem) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    let onRemoveFromPlaylist: (MediaItem) -> Void
    var allowsReordering = true
    let onCommitOrder: ([MediaItem]) -> Void

    @State private var orderedRows: [MusicTrackRowModel] = []
    @State private var draggedRowID: String?
    @State private var rowsSignature: [String] = []

    var body: some View {
        List {
            MusicSongHeader(trailingActionColumns: 2)
                .padding(.horizontal, 6)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(orderedRows) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Color.clear
                .frame(height: listBottomInset)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
        .bleedingListCard()
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear {
            syncRowsIfNeeded(force: true)
        }
        .onChange(of: rowIDs(from: rows)) { _ in
            syncRowsIfNeeded(force: false)
        }
        .onDisappear {
            draggedRowID = nil
        }
    }

    @ViewBuilder
    private func rowView(_ row: MusicTrackRowModel) -> some View {
        let base = MusicSongRow(
            row: row,
            onSearchMetadata: onSearchMetadata,
            onCreatePlaylist: onCreatePlaylist,
            onRemoveFromPlaylist: onRemoveFromPlaylist
        )

        if allowsReordering {
            // 去掉拖动手柄（小横条）显示，整行仍可拖动排序。
            base
                .padding(.horizontal, 6)
                .opacity(draggedRowID == row.id ? 0.55 : 1)
                .contentShape(Rectangle())
                .onDrag {
                    draggedRowID = row.id
                    return NSItemProvider(object: row.id as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: MusicPlaylistTrackDropDelegate(
                        targetRowID: row.id,
                        orderedRows: $orderedRows,
                        draggedRowID: $draggedRowID,
                        commitOrder: commitOrder
                    )
                )
        } else {
            base.padding(.horizontal, 6)
        }
    }

    private var listBottomInset: CGFloat {
        appState.activePlayerItem?.type == .music ? 106 : 16
    }

    private func syncRowsIfNeeded(force: Bool) {
        let signature = rowIDs(from: rows)
        guard force || rowsSignature != signature else { return }
        rowsSignature = signature
        orderedRows = rows
    }

    private func commitOrder() {
        onCommitOrder(orderedRows.map(\.track))
        rowsSignature = rowIDs(from: orderedRows)
    }

    private func rowIDs(from rows: [MusicTrackRowModel]) -> [String] {
        rows.map(\.id)
    }
}

private struct MusicPlaylistTrackDropDelegate: DropDelegate {
    let targetRowID: String
    @Binding var orderedRows: [MusicTrackRowModel]
    @Binding var draggedRowID: String?
    let commitOrder: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedRowID,
              draggedRowID != targetRowID,
              let sourceIndex = orderedRows.firstIndex(where: { $0.id == draggedRowID }),
              let targetIndex = orderedRows.firstIndex(where: { $0.id == targetRowID }) else {
            return
        }
        withAnimation(AppMotion.fast) {
            orderedRows.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggedRowID != nil else { return false }
        commitOrder()
        draggedRowID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private enum MusicSortMode: String, CaseIterable, Identifiable, Sendable {
    case title
    case artist
    case album
    case recent
    case duration
    case mostPlayed
    case workCount

    var id: String { rawValue }
    func title(for section: MusicLibrarySection) -> String {
        if section == .artists {
            switch self {
            case .title: return "按名称"
            case .workCount: return "按作品数量"
            case .mostPlayed: return "按播放次数"
            default: break
            }
        }
        switch self {
        case .title: return section == .albums ? "专辑名" : "歌曲名"
        case .artist: return "艺术家"
        case .album: return "专辑"
        case .recent: return "最近更新"
        case .duration: return "时长"
        case .mostPlayed: return "最多播放"
        case .workCount: return "作品数量"
        }
    }
}

private enum MusicSortOrder: String, Sendable {
    case primary
    case reverse

    mutating func toggle() {
        self = self == .primary ? .reverse : .primary
    }

    var titleSuffix: String {
        self == .primary ? "正序" : "倒序"
    }

    var systemImage: String {
        self == .primary ? "arrow.down" : "arrow.up"
    }
}

private enum MusicFilterMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case favorites
    case withLyrics
    case unmatched

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        case .withLyrics: return "有歌词"
        case .unmatched: return "未匹配"
        }
    }
}

private struct MusicFilterModeCapsules: View {
    @Binding var selection: MusicFilterMode
    let modes: [MusicFilterMode]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(modes) { mode in
                Button {
                    withAnimation(AppMotion.fast) {
                        selection = mode
                    }
                } label: {
                    GlassCapsuleControl(isSelected: selection == mode, enablePointerEdge: false) {
                        Text(mode.title)
                    }
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .fixedSize()
    }
}

private struct MusicSongHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 行尾动作按钮列数：普通歌曲列表 1（获取信息），歌单明细 2（获取信息 + 移出歌单）。
    /// 列头按同宽预留，保证「时长」列与行内完全对齐。
    var trailingActionColumns: Int = 1

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 42)
            headerLabel("歌曲", systemImage: "music.note")
                .frame(maxWidth: .infinity, alignment: .leading)
            headerLabel("艺术家", systemImage: "person.wave.2")
                .frame(width: 150, alignment: .leading)
            headerLabel("专辑", systemImage: "record.circle")
                .frame(width: 170, alignment: .leading)
            headerLabel("歌词", systemImage: "quote.bubble")
                .frame(width: 48, alignment: .center)
            headerLabel("时长", systemImage: "clock")
                .frame(width: 58, alignment: .trailing)
            Color.clear.frame(width: CGFloat(trailingActionColumns) * 30 + CGFloat(max(0, trailingActionColumns - 1)) * 12)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(AppColors.textSecondary)
        // 与 MusicSongRow 的 .padding(.horizontal, 8) 对齐，列头与行内容零偏移。
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background {
            // 与设置页固定标题完全同源的材质：列表内容从列名下穿过时保留同样的
            // 高斯模糊与白度，不再混用 underWindowBackground 形成两种“玻璃”。
            AppPageTitleMaterialSurface()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.refCardBorder.opacity(colorScheme == .dark ? 0.82 : 0.95), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.30),
                            AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.035 : 0.075),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
    }

    private func headerLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppColors.refIconGlyph.opacity(colorScheme == .dark ? 0.82 : 0.74))
            Text(title)
                .lineLimit(1)
        }
    }
}

private struct MusicSongRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let row: MusicTrackRowModel
    var showsHistoryAction: Bool = false
    var showsResetPlayCountAction: Bool = false
    /// 远程媒体服务器（Emby/Jellyfin/Plex）音乐传 false：隐藏「获取音乐信息 / 重新分类」等
    /// 本地元数据补充/分类操作——这些对远程条目不适用，右键里也不该出现。
    var showsMetadataActions: Bool = true
    var queueContext: [MediaItem]? = nil
    let onSearchMetadata: (MediaItem) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    var onRemoveFromPlaylist: ((MediaItem) -> Void)?
    @State private var isHovering = false

    // 在专辑/艺术家详情页播放：把队列替换为该集合的歌曲，从点击的这首开始；否则走默认整库队列。
    private func playRow() {
        if let queueContext, !queueContext.isEmpty {
            appState.replaceMusicQueueAndPlay(queueContext, startingAt: row.track)
        } else {
            appState.play(row.track)
        }
    }

    var body: some View {
        let hoverActive = isHovering && !suppressHoverDuringScroll
        let isCurrent = appState.activePlayerItem?.id == row.track.id
        let rowShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        HStack(spacing: 12) {
            MusicRowArtwork(path: row.track.posterPath, title: row.track.title)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: AppCardMetrics.compactArtworkCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AppCardMetrics.compactArtworkCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(hoverActive ? 0.42 : 0.20), lineWidth: 0.8)
                }
                .scaleEffect(!reduceMotion && hoverActive ? 1.035 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.titleText)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    if isCurrent {
                        MusicCompactStatusBadge(
                            title: "播放中",
                            systemImage: "speaker.wave.2.fill"
                        )
                    }
                }

                HStack(spacing: 5) {
                    if let fileName = row.fileName {
                        Text(fileName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if row.track.favorite {
                        MusicCompactStatusBadge(
                            title: "喜欢",
                            systemImage: "heart.fill",
                            tint: .red
                        )
                    }
                    if row.track.isRemoteResource {
                        MusicCompactStatusBadge(
                            title: "远程",
                            systemImage: "cloud"
                        )
                    }
                    if showsResetPlayCountAction, row.track.playCountValue > 0 {
                        MusicCompactStatusBadge(
                            title: "\(row.track.playCountValue) 次",
                            systemImage: "play.circle"
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 次要列用次级色，与标题列拉开层级（首页榜单同款主次结构）。
            Text(row.artistText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Text(row.albumText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            Image(systemName: row.hasLocalLyrics ? "text.quote" : "minus")
                .foregroundStyle(row.hasLocalLyrics ? AppColors.selectedGlassTint.opacity(0.82) : Color.secondary)
                .frame(width: 48)

            Text(row.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)

            if showsMetadataActions {
                Button {
                    onSearchMetadata(row.track)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(hoverActive ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
                .background {
                    Circle()
                        .fill(Color.white.opacity(hoverActive ? (colorScheme == .dark ? 0.12 : 0.46) : (colorScheme == .dark ? 0.06 : 0.16)))
                }
                .overlay {
                    Circle().stroke(
                        hoverActive ? AppColors.edgeLightStroke(colorScheme, depth: 1.0, intensity: 0.92) : LinearGradient(colors: [AppColors.cleanPanelBorder, AppColors.cleanPanelBorder], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                }
                // 首页风格：行内动作 hover 浮现，静态列表不铺满每行的按钮噪声（透明度渐显，不改布局）。
                .opacity(hoverActive ? 1 : 0)
                .help("立即获取音乐信息")
            }

            if let onRemoveFromPlaylist {
                Button {
                    onRemoveFromPlaylist(row.track)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(hoverActive ? Color.red.opacity(0.82) : Color.secondary.opacity(0.72))
                .background {
                    Circle()
                        .fill(Color.white.opacity(hoverActive ? (colorScheme == .dark ? 0.10 : 0.50) : (colorScheme == .dark ? 0.05 : 0.16)))
                }
                .overlay {
                    Circle().stroke(Color.red.opacity(hoverActive ? 0.28 : 0.12), lineWidth: 1)
                }
                .opacity(hoverActive ? 1 : 0)
                .help("从歌单移出")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(height: AppCardMetrics.musicRowHeight)
        // 「播放中」只用标题旁的徽标提示，行背景/描边/发光/左侧强调条不再随当前播放曲目
        // 常驻高亮（那是「选中」的视觉语言，容易被误读成多选/选中态）；只保留悬停反馈。
        .background {
            if hoverActive {
                ReferenceCardSurface(selected: true, cornerRadius: 12)
            } else {
                rowShape.fill(Color.clear)
            }
        }
        .repeatedCardChrome(hoverActive, cornerRadius: 12)
        .repeatedSurfaceHover(hoverActive, cornerRadius: 12, tint: AppColors.pointerLightTint, intensity: 0.62)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(AppColors.solarEdgeTint.opacity(hoverActive ? (colorScheme == .dark ? 0.22 : 0.28) : 0))
                .frame(width: 3, height: 28)
                .padding(.leading, 2)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, AppColors.cleanPanelBorder.opacity(0.54), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
        }
        .contentShape(rowShape)
        .scaleEffect(!reduceMotion && hoverActive ? 1.002 : 1, anchor: .center)
        .animation(reduceMotion ? nil : AppMotion.listHover, value: hoverActive)
        .onHover { hovering in
            guard !suppressHoverDuringScroll else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .onTapGesture(count: 2) {
            playRow()
        }
        .contextMenu {
            Button {
                playRow()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button {
                appState.startRadio(seed: row.track)
            } label: {
                Label("开始电台", systemImage: "dot.radiowaves.left.and.right")
            }
            Button {
                appState.addToMusicQueue(row.track)
            } label: {
                Label("加入播放队列", systemImage: "text.badge.plus")
            }
            Button {
                appState.playNextInMusicQueue(row.track)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            MusicPlaylistActionsMenu(
                tracks: [row.track],
                suggestedName: row.track.title,
                onCreateNew: onCreatePlaylist
            )
            if showsHistoryAction && row.track.hasPlaybackTrace {
                Button(role: .destructive) {
                    appState.clearPlaybackHistory(row.track)
                } label: {
                    Label("删除播放记录", systemImage: "clock.badge.xmark")
                }
            }
            if showsResetPlayCountAction, (row.track.playCount ?? 0) > 0 {
                Button {
                    appState.resetMusicPlayCount(row.track)
                } label: {
                    Label("重置播放次数", systemImage: "arrow.counterclockwise")
                }
            }
            if let onRemoveFromPlaylist {
                Button(role: .destructive) {
                    onRemoveFromPlaylist(row.track)
                } label: {
                    Label("从歌单移出", systemImage: "minus.circle")
                }
            }
            if showsMetadataActions {
                Button {
                    onSearchMetadata(row.track)
                } label: {
                    Label("获取音乐信息", systemImage: "tag.circle")
                }
            }
            Button {
                appState.toggleFavorite(row.track)
            } label: {
                Label(row.track.favorite ? "取消收藏" : "收藏", systemImage: row.track.favorite ? "heart.slash" : "heart")
            }
            if showsMetadataActions {
                Menu {
                    ForEach([MediaType.movie, .tvShow, .anime, .documentary, .variety, .homeVideo, .other, .privateCollection], id: \.self) { type in
                        Button {
                            appState.reclassify(row.track, as: type)
                        } label: {
                            Label(type.displayName, systemImage: type.systemImage)
                        }
                    }
                } label: {
                    Label("重新分类", systemImage: "tray.and.arrow.down")
                }
            }
        }
    }
}

private struct MusicRowArtwork: View {
    let path: String?
    let title: String

    var body: some View {
        if usesDefaultArtwork {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppColors.accentGradient)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.22))
                Image(systemName: "music.note")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        } else {
            // 非正方形封面缩放至完整显示（不裁切），四周留白填白。
            PosterImage(path: path, title: title, mediaType: .music, contentMode: .fit, fitBackground: .white)
        }
    }

    private var usesDefaultArtwork: Bool {
        guard let path else { return true }
        return path.hasSuffix("-default.jpg")
    }
}

private struct ReferenceMusicVisualSeed {
    let glyph: String
    let start: Color
    let end: Color

    static func make(title: String, secondary: String = "") -> ReferenceMusicVisualSeed {
        let palettes: [(Color, Color)] = [
            (Color(red: 0.63, green: 0.31, blue: 0.45), Color(red: 0.98, green: 0.66, blue: 0.83)),
            (Color(red: 0.16, green: 0.14, blue: 0.09), Color(red: 0.80, green: 0.71, blue: 0.52)),
            (Color(red: 0.05, green: 0.29, blue: 0.22), Color(red: 0.52, green: 0.80, blue: 0.09)),
            (Color(red: 0.29, green: 0.06, blue: 0.38), Color(red: 0.85, green: 0.27, blue: 0.94)),
            (Color(red: 0.05, green: 0.23, blue: 0.37), Color(red: 0.22, green: 0.74, blue: 0.97)),
            (Color(red: 0.11, green: 0.13, blue: 0.19), Color(red: 0.49, green: 0.54, blue: 0.63)),
            (AppColors.referenceBlue, Color(red: 0.36, green: 0.42, blue: 1.0)),
            (Color(red: 0.48, green: 0.06, blue: 0.13), Color(red: 0.94, green: 0.27, blue: 0.27))
        ]
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = raw.isEmpty ? secondary.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        var hash: UInt64 = 1469598103934665603
        for scalar in (display + secondary).unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1099511628211
        }
        let palette = palettes[Int(hash % UInt64(palettes.count))]
        let glyph = display.unicodeScalars.first.map { String($0) } ?? "音"
        return ReferenceMusicVisualSeed(glyph: glyph, start: palette.0, end: palette.1)
    }
}

private struct ReferenceMusicGradientArtwork: View {
    let title: String
    let subtitle: String
    let posterPath: String?
    var cornerRadius: CGFloat = 14
    var glyphSize: CGFloat = 42
    var cacheTargetSize: CGSize? = nil

    private var seed: ReferenceMusicVisualSeed {
        ReferenceMusicVisualSeed.make(title: title, secondary: subtitle)
    }

    var body: some View {
        Group {
            if usesDefaultArtwork {
                gradientArtwork
            } else {
                PosterImage(path: posterPath, title: title, mediaType: .music, cacheTargetSize: cacheTargetSize, contentMode: .fit, fitBackground: .white)
                    .overlay {
                        RadialGradient(
                            colors: [.white.opacity(0.20), .clear],
                            center: UnitPoint(x: 0.22, y: 0.16),
                            startRadius: 4,
                            endRadius: 140
                        )
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.055), radius: 7, x: 0, y: 3)
    }

    private var gradientArtwork: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [seed.start, seed.end], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [.white.opacity(0.28), .clear],
                center: UnitPoint(x: 0.25, y: 0.15),
                startRadius: 4,
                endRadius: 180
            )
            Text(seed.glyph)
                .font(.system(size: glyphSize, weight: .black))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 16)
                .padding(.bottom, 14)
        }
    }

    private var usesDefaultArtwork: Bool {
        guard let posterPath else { return true }
        return posterPath.hasSuffix("-default.jpg")
    }
}

private struct MusicAlbumCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let album: MusicAlbumGroup
    let showsResetPlayCountAction: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    let onResetPlayCounts: () -> Void
    let tracksProvider: () -> [MediaItem]
    @State private var isHovering = false
    private static let coverCacheTargetSize = CGSize(width: 180, height: 180)

    var body: some View {
        let hoverActive = isHovering && !suppressHoverDuringScroll
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            ReferenceMusicGradientArtwork(
                title: album.key.title,
                subtitle: album.key.artist,
                posterPath: album.coverPath,
                cornerRadius: 14,
                glyphSize: 42,
                cacheTargetSize: Self.coverCacheTargetSize
            )

            MarqueeText(text: album.key.title, font: .system(size: 14.5, weight: .heavy))
                .foregroundStyle(AppColors.refTitleText)
                .frame(height: 18, alignment: .leading)

            HStack(alignment: .center, spacing: 10) {
                Text("\(album.key.artist) · \(album.trackCount) 首")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.refTitleText.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    onPlay()
                } label: {
                    HStack(spacing: 6) {
                        MusicPlayTriangle()
                            .fill(AppColors.refSecondaryText)
                            .frame(width: 8, height: 10)
                        Text("播放")
                    }
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(AppColors.refSecondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            cardShape.fill(AppColors.refCardBg)
        }
        .overlay {
            cardShape.strokeBorder(AppColors.refOutlineBorder.opacity(0.82), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(hoverActive ? 0.070 : 0.035), radius: hoverActive ? 14 : 8, x: 0, y: hoverActive ? 6 : 3)
        .offset(y: !reduceMotion && hoverActive ? -5 : 0)
        .contentShape(cardShape)
        .zIndex(hoverActive ? 1 : 0)
        .animation(reduceMotion ? nil : AppMotion.listHover, value: hoverActive)
        .onHover { hovering in
            guard !suppressHoverDuringScroll else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("查看歌曲", systemImage: "music.note.list")
            }
            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            if showsResetPlayCountAction, album.playCount > 0 {
                Button {
                    onResetPlayCounts()
                } label: {
                    Label("重置播放次数", systemImage: "arrow.counterclockwise")
                }
            }
            MusicPlaylistActionsMenu(
                tracks: tracksProvider(),
                suggestedName: album.key.title,
                onCreateNew: onCreatePlaylist
            )
        }
    }
}

private struct MusicPlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MusicArtistRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let artist: MusicArtistGroup
    let showsResetPlayCountAction: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    let onResetPlayCounts: () -> Void
    let tracksProvider: () -> [MediaItem]
    @State private var isHovering = false

    var body: some View {
        let hoverActive = isHovering && !suppressHoverDuringScroll
        let seed = ReferenceMusicVisualSeed.make(title: artist.name)

        VStack(alignment: .center, spacing: 0) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [seed.start, seed.end], startPoint: .topLeading, endPoint: .bottomTrailing))
                RadialGradient(
                    colors: [.white.opacity(0.28), .clear],
                    center: UnitPoint(x: 0.25, y: 0.15),
                    startRadius: 4,
                    endRadius: 120
                )
                Text(seed.glyph)
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(Circle())
            .shadow(color: seed.end.opacity(0.34), radius: 15, x: 0, y: 8)

            MarqueeText(text: artist.name, font: .system(size: 13.5, weight: .heavy), alignment: .center)
                .foregroundStyle(AppColors.refTitleText)
                .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17, alignment: .center)
                .padding(.top, 11)

            Text("\(artist.trackCount) 首")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppColors.refTitleText.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)

        }
        .padding(8)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .offset(y: !reduceMotion && hoverActive ? -4 : 0)
        .animation(reduceMotion ? nil : AppMotion.listHover, value: hoverActive)
        .onHover { hovering in
            guard !suppressHoverDuringScroll else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("查看歌曲", systemImage: "music.note.list")
            }
            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            if showsResetPlayCountAction, artist.playCount > 0 {
                Button {
                    onResetPlayCounts()
                } label: {
                    Label("重置播放次数", systemImage: "arrow.counterclockwise")
                }
            }
            MusicPlaylistActionsMenu(
                tracks: tracksProvider(),
                suggestedName: artist.name,
                onCreateNew: onCreatePlaylist
            )
        }
    }
}

private struct ProgressiveMusicAlbumGrid: View {
    @EnvironmentObject private var appState: AppState
    let albums: [MusicAlbumGroup]
    let showsResetPlayCountAction: Bool
    let onOpen: (MusicAlbumGroup) -> Void
    let onPlay: (MusicAlbumGroup) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    let onResetPlayCounts: (MusicAlbumGroup) -> Void

    var body: some View {
        GeometryReader { proxy in
            let columns = columnCount(for: proxy.size.width)
            let rows = rowCount(for: columns)

            List {
                ForEach(0..<rows, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(0..<columns, id: \.self) { columnIndex in
                            let index = rowIndex * columns + columnIndex
                            if index < albums.count {
                                let album = albums[index]
                                MusicAlbumCard(
                                    album: album,
                                    showsResetPlayCountAction: showsResetPlayCountAction,
                                    onOpen: { onOpen(album) },
                                    onPlay: { onPlay(album) },
                                    onCreatePlaylist: onCreatePlaylist,
                                    onResetPlayCounts: { onResetPlayCounts(album) },
                                    tracksProvider: { appState.musicTracks(inAlbum: album.summary) }
                                )
                                .frame(maxWidth: .infinity, alignment: .top)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 22, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Color.clear
                    .frame(height: listBottomInset)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
    }

    private func columnCount(for width: CGFloat) -> Int {
        let spacing: CGFloat = 20
        let minimumCardWidth: CGFloat = 220
        let availableWidth = max(width - 20, minimumCardWidth)
        return min(4, max(1, Int((availableWidth + spacing) / (minimumCardWidth + spacing))))
    }

    private func rowCount(for columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        return (albums.count + columns - 1) / columns
    }

    private var listBottomInset: CGFloat {
        appState.activePlayerItem?.type == .music ? 106 : 16
    }
}

private struct ProgressiveMusicArtistList: View {
    @EnvironmentObject private var appState: AppState
    let artists: [MusicArtistGroup]
    let showsResetPlayCountAction: Bool
    let onOpen: (MusicArtistGroup) -> Void
    let onPlay: (MusicArtistGroup) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    let onResetPlayCounts: (MusicArtistGroup) -> Void

    var body: some View {
        GeometryReader { proxy in
            let columns = columnCount(for: proxy.size.width)
            let rows = rowCount(for: columns)

            List {
                ForEach(0..<rows, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(0..<columns, id: \.self) { columnIndex in
                            let index = rowIndex * columns + columnIndex
                            if index < artists.count {
                                let artist = artists[index]
                                MusicArtistRow(
                                    artist: artist,
                                    showsResetPlayCountAction: showsResetPlayCountAction,
                                    onOpen: { onOpen(artist) },
                                    onPlay: { onPlay(artist) },
                                    onCreatePlaylist: onCreatePlaylist,
                                    onResetPlayCounts: { onResetPlayCounts(artist) },
                                    tracksProvider: { appState.musicTracks(inArtist: artist.summary) }
                                )
                                .frame(maxWidth: .infinity, alignment: .top)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 24, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Color.clear
                    .frame(height: listBottomInset)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
    }

    private func columnCount(for width: CGFloat) -> Int {
        let spacing: CGFloat = 18
        let minimumCardWidth: CGFloat = 128
        let availableWidth = max(width - 20, minimumCardWidth)
        return min(6, max(2, Int((availableWidth + spacing) / (minimumCardWidth + spacing))))
    }

    private func rowCount(for columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        return (artists.count + columns - 1) / columns
    }

    private var listBottomInset: CGFloat {
        appState.activePlayerItem?.type == .music ? 106 : 16
    }
}

private struct MusicPlaylistsOverview: View {
    @EnvironmentObject private var appState: AppState
    let playlists: [MusicPlaylist]
    let onOpen: (MusicPlaylist) -> Void
    let onPlay: (MusicPlaylist) -> Void
    let onRename: (MusicPlaylist) -> Void
    let onDelete: (MusicPlaylist) -> Void

    var body: some View {
        let tracksByID = Dictionary(uniqueKeysWithValues: appState.musicTracks.map { ($0.id, $0) })

        LazyVStack(spacing: 12) {
            ForEach(playlists) { playlist in
                let tracks = playlist.itemIDs.compactMap { tracksByID[$0] }
                MusicPlaylistCard(
                    playlist: playlist,
                    tracks: tracks,
                    onOpen: { onOpen(playlist) },
                    onPlay: { onPlay(playlist) },
                    onRename: { onRename(playlist) },
                    onDelete: { onDelete(playlist) }
                )
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct MusicPlaylistCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.colorScheme) private var colorScheme
    let playlist: MusicPlaylist
    let tracks: [MediaItem]
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        let isPinnedFavorite = MusicFavoritePlaylist.isFavorite(playlist)
        let hoverActive = isHovering && !suppressHoverDuringScroll

        HStack(spacing: 16) {
            playlistIcon(isPinnedFavorite: isPinnedFavorite)

            VStack(alignment: .leading, spacing: 5) {
                MarqueeText(text: playlist.name, font: .headline)
                    .frame(height: 21, alignment: .leading)
                Text(playlistSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if isPinnedFavorite {
                        MusicCompactStatusBadge(
                            title: "喜欢歌曲",
                            systemImage: "heart.fill",
                            tint: .red
                        )
                    }
                    let remoteCount = tracks.filter(\.isRemoteResource).count
                    if remoteCount > 0 {
                        MusicCompactStatusBadge(
                            title: "\(remoteCount) 首远程",
                            systemImage: "cloud"
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: AppRadius.control, horizontalPadding: 12, minHeight: AppControlMetrics.defaultButtonHeight))
            .disabled(tracks.isEmpty)

            if !isPinnedFavorite {
                Menu {
                    Button {
                        onRename()
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("歌单管理")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .staticSurfaceBackground(selected: hoverActive, cornerRadius: AppRadius.card)
        .shadow(
            color: AppColors.refCardShadow.opacity(hoverActive ? 0.16 : 0),
            radius: hoverActive ? 20 : 0,
            x: 0,
            y: hoverActive ? 8 : 0
        )
        .offset(y: !reduceMotion && hoverActive ? -3 : 0)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .animation(reduceMotion ? nil : AppMotion.listHover, value: hoverActive)
        .onHover { hovering in
            guard !suppressHoverDuringScroll else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("查看歌曲", systemImage: "music.note.list")
            }
            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .disabled(tracks.isEmpty)
            if !isPinnedFavorite {
                Button {
                    onRename()
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func playlistIcon(isPinnedFavorite: Bool) -> some View {
        let accent = playlistAccent
        if isPinnedFavorite {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.76)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.24 : 0.42), lineWidth: 1)
                Image(systemName: "heart.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .compositingGroup()
            .shadow(color: accent.opacity(0.30), radius: 16, x: -5, y: 8)
            .shadow(color: AppColors.refCardShadow.opacity(0.10), radius: 10, x: 4, y: -3)
        } else if let latestTrack = tracks.last, latestTrack.posterPath != nil {
            PosterImage(
                path: latestTrack.posterPath,
                title: latestTrack.title,
                mediaType: .music,
                cacheTargetSize: CGSize(width: 104, height: 104),
                contentMode: .fit,
                fitBackground: .white
            )
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.20 : 0.42), lineWidth: 1)
            }
            .shadow(color: AppColors.refCardShadow.opacity(0.14), radius: 14, y: 6)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.96), accent.opacity(0.70)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                AppGlyph(systemImage: "music.note.list", size: 24)
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: accent.opacity(0.24), radius: 14, x: -4, y: 7)
        }
    }

    private var playlistSubtitle: String {
        if let latestTrack = tracks.last, !tracks.isEmpty {
            return "\(tracks.count) 首歌曲 · 最新添加 \(latestTrack.title)"
        }
        return "\(tracks.count) 首歌曲"
    }

    private var playlistAccent: Color {
        let seed = playlist.id.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        let hue = Double(seed % 360) / 360.0
        return Color(hue: hue, saturation: 0.66, brightness: 0.96)
    }
}

private struct MusicAlbumKey: Hashable, Sendable {
    let title: String
    let artist: String
}

private struct MusicAlbumGroup: Identifiable, Sendable {
    let summary: MusicAlbumSummary

    var id: String { summary.id }
    var key: MusicAlbumKey { MusicAlbumKey(title: summary.title, artist: summary.artist) }
    var coverPath: String? { summary.coverPath }
    var playCount: Int { summary.playCount }
    var favoriteCount: Int { summary.favoriteCount }
    var remoteCount: Int { summary.remoteCount }
    var trackCount: Int { summary.trackCount }
    var latestUpdatedAt: Date { summary.latestUpdatedAt }
}

private struct MusicArtistGroup: Identifiable, Sendable {
    let summary: MusicArtistSummary

    var id: String { summary.id }
    var name: String { summary.name }
    var playCount: Int { summary.playCount }
    var favoriteCount: Int { summary.favoriteCount }
    var remoteCount: Int { summary.remoteCount }
    var trackCount: Int { summary.trackCount }
    var albumCount: Int { summary.albumCount }
}

private extension MediaItem {
    var playCountValue: Int {
        playCount ?? 0
    }
}

// MARK: - 音乐智能歌单详情（复用 MusicSongListView，曲目按规则实时求值）

struct MusicSmartPlaylistDetailView: View {
    @EnvironmentObject private var appState: AppState
    let playlist: MusicSmartPlaylist
    let onEdit: () -> Void

    @State private var metadataItem: MediaItem?
    @State private var playlistCreationRequest: MusicPlaylistCreationRequest?

    private var tracks: [MediaItem] {
        appState.musicTracks(inSmart: playlist)
    }

    var body: some View {
        let tracks = tracks
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                PageHeader(
                    title: playlist.name,
                    subtitle: "\(tracks.count) 首 · \(playlist.ruleSummary)",
                    systemImage: "music.note.list"
                ) {
                    Button {
                        appState.replaceMusicQueueAndPlay(tracks)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 34, prominent: true))
                    .disabled(tracks.isEmpty)

                    Button {
                        onEdit()
                    } label: {
                        Label("编辑规则", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.pageVertical)
            .padding(.bottom, AppSpacing.headerToControls)

            content(tracks: tracks)
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPageBackground())
        .sheet(item: $metadataItem) { item in
            MetadataSearchView(item: item)
                .environmentObject(appState)
        }
        .sheet(item: $playlistCreationRequest) { request in
            MusicPlaylistCreationSheet(
                request: request,
                onCreate: { name in
                    appState.createMusicPlaylist(name: name, tracks: request.tracks)
                    playlistCreationRequest = nil
                },
                onCancel: {
                    playlistCreationRequest = nil
                }
            )
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func content(tracks: [MediaItem]) -> some View {
        if tracks.isEmpty {
            EmptyStateView(
                title: "暂无符合规则的歌曲",
                systemImage: "music.note.list",
                message: "调整筛选或加入时间规则，或先扫描音乐媒体源。"
            )
            .staticSurfaceBackground(cornerRadius: 22)
        } else {
            MusicSongListView(
                rows: MusicLibrarySnapshotBuilder.rowModels(from: tracks),
                queueContext: tracks,
                onSearchMetadata: { metadataItem = $0 },
                onCreatePlaylist: { playlistCreationRequest = $0 }
            )
        }
    }
}


// MARK: - 远程媒体服务器（Emby / Jellyfin / Plex）音乐库页面
//
// 排版与设计**完全复用本地音乐页面**：控制栏用同款 AppAdaptiveControlBar + 胶囊；专辑用 MusicAlbumCard、
// 艺术家用 MusicArtistRow（同一套网格 MusicCollectionGridMetrics）；歌曲/最近用 MusicSongListView；
// 专辑/艺术家下钻用 MusicCollectionTrackList。区别仅两点：① 用页内控制栏切「歌曲/专辑/艺术家/最近播放」
// 取代本地的侧栏分区导航；② 远程条目不提供元数据补充（MusicSongRow.showsMetadataActions = false）。

private enum RemoteMusicTab: String, CaseIterable, Identifiable {
    case songs, albums, artists, recent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: return "歌曲"
        case .albums: return "专辑"
        case .artists: return "艺术家"
        case .recent: return "最近播放"
        }
    }
    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .artists: return "person.2"
        case .recent: return "clock"
        }
    }
}

struct RemoteMusicLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sourceID: String

    @State private var tab: RemoteMusicTab = .songs
    @State private var searchText = ""
    @State private var sortMode: MusicSortMode = .title
    @State private var sortOrder: MusicSortOrder = .primary
    @State private var drilldown: MusicCollectionDrilldown?
    @State private var playlistCreationRequest: MusicPlaylistCreationRequest?
    /// 内容“呼吸”透明度：歌曲/专辑/艺术家/最近分区切换、进出 drilldown 时与本地音乐页同节奏渐入。
    @State private var contentBreathOpacity: Double = 1

    private var source: MediaSource? {
        appState.sources.first { $0.id == sourceID }
    }
    private var tracks: [MediaItem] {
        appState.embyItems(for: .music, sourceID: sourceID)
    }
    private var currentTracks: [MediaItem] {
        let scoped = tab == .recent ? tracks.filter(\.hasPlaybackTrace) : tracks
        return RemoteMusicOrdering.tracks(scoped, query: searchText, mode: sortMode, order: sortOrder)
    }
    private var albumGroups: [MusicAlbumGroup] {
        RemoteMusicOrdering.albums(
            RemoteMusicGrouping.albumGroups(sourceID: sourceID, tracks: tracks),
            query: searchText,
            mode: sortMode,
            order: sortOrder
        )
    }
    private var artistGroups: [MusicArtistGroup] {
        RemoteMusicOrdering.artists(
            RemoteMusicGrouping.artistGroups(sourceID: sourceID, tracks: tracks),
            query: searchText,
            mode: sortMode,
            order: sortOrder
        )
    }

    var body: some View {
        Group {
            if let drilldown {
                drilldownBody(drilldown)
            } else {
                mainBody
            }
        }
        .opacity(contentBreathOpacity)
        .onChange(of: "\(tab.rawValue)|\(drilldown?.id ?? "-")") { _ in
            guard !reduceMotion else { return }
            withAnimation(nil) { contentBreathOpacity = 0.34 }
            DispatchQueue.main.async {
                withAnimation(AppMotion.standard) { contentBreathOpacity = 1 }
            }
        }
        .onChange(of: tab) { _ in
            // 每个子页只暴露与自身数据模型兼容的排序项；切页时若沿用了上一页的
            // 专属排序（例如艺术家的“作品数量”），立即回退到名称，避免标题和数据脱节。
            if !availableSortModes.contains(sortMode) {
                sortMode = .title
                sortOrder = .primary
            }
        }
        .background(AppPageBackground())
        .navigationTitle("音乐")
        .sheet(item: $playlistCreationRequest) { request in
            MusicPlaylistCreationSheet(
                request: request,
                onCreate: { name in
                    appState.createMusicPlaylist(name: name, tracks: request.tracks)
                    playlistCreationRequest = nil
                },
                onCancel: { playlistCreationRequest = nil }
            )
            .environmentObject(appState)
        }
    }

    private var mainBody: some View {
        VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
            PageHeader(
                title: "音乐",
                subtitle: "\(source?.name ?? "远程媒体库") · \(currentItemCount) \(currentItemUnit)",
                systemImage: "emby.music"
            ) {
                GlassSearchField(placeholder: "搜索音乐", text: $searchText, minWidth: 158, maxWidth: 226)
                if let source {
                    Button {
                        appState.scan(source)
                    } label: {
                        Label("扫描", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isScanning)
                }
                if tab == .recent {
                    Button(role: .destructive) {
                        appState.clearPlaybackHistory(currentTracks)
                    } label: {
                        Label("清除记录", systemImage: "clock.badge.xmark")
                            .foregroundStyle(.red)
                    }
                    .disabled(currentTracks.isEmpty)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.pageVertical)

            // 远程音乐与本地同用一条控制栏：左侧控制当前展示的数据分区，右侧控制排序；
            // 页面不再提供本地没有的「播放全部」动作。
            AppAdaptiveControlBar {
                HStack(spacing: 8) {
                    ForEach(RemoteMusicTab.allCases) { item in
                        Button {
                            withAnimation(AppMotion.fast) { tab = item }
                        } label: {
                            GlassCapsuleControl(isSelected: tab == item, enablePointerEdge: false) {
                                Label(item.title, systemImage: item.systemImage)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } trailing: {
                GlassMenuButton(title: "\(sortMode.title(for: mappedLocalSection)) · \(sortOrder.titleSuffix)") {
                    ForEach(availableSortModes) { mode in
                        Button {
                            selectSortMode(mode)
                        } label: {
                            Label(mode.title(for: mappedLocalSection), systemImage: sortMode == mode ? sortOrder.systemImage : "circle")
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .songs:
            songList(for: currentTracks)
        case .recent:
            if currentTracks.isEmpty {
                emptyState("还没有播放记录", systemImage: "clock")
            } else {
                songList(for: currentTracks)
            }
        case .albums:
            if albumGroups.isEmpty {
                emptyState("暂无专辑", systemImage: "square.stack")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: MusicCollectionGridMetrics.album.minimumItemWidth), spacing: MusicCollectionGridMetrics.album.columnSpacing)],
                        alignment: .leading,
                        spacing: MusicCollectionGridMetrics.album.rowBottomInset
                    ) {
                        ForEach(albumGroups) { album in
                            MusicAlbumCard(
                                album: album,
                                showsResetPlayCountAction: false,
                                onOpen: { withAnimation(AppMotion.fast) { drilldown = .album(album, RemoteMusicGrouping.tracks(inAlbum: album, from: tracks)) } },
                                onPlay: { appState.replaceMusicQueueAndPlay(RemoteMusicGrouping.tracks(inAlbum: album, from: tracks)) },
                                onCreatePlaylist: { playlistCreationRequest = $0 },
                                onResetPlayCounts: {},
                                tracksProvider: { RemoteMusicGrouping.tracks(inAlbum: album, from: tracks) }
                            )
                        }
                    }
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.top, MusicCollectionGridMetrics.album.firstRowTopInset)
                    .padding(.bottom, 28)
                }
                .suppressHoverEffectsDuringScroll()
            }
        case .artists:
            if artistGroups.isEmpty {
                emptyState("暂无艺术家", systemImage: "person.2")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: MusicCollectionGridMetrics.artist.minimumItemWidth), spacing: MusicCollectionGridMetrics.artist.columnSpacing)],
                        alignment: .leading,
                        spacing: MusicCollectionGridMetrics.artist.rowBottomInset
                    ) {
                        ForEach(artistGroups) { artist in
                            MusicArtistRow(
                                artist: artist,
                                showsResetPlayCountAction: false,
                                onOpen: { withAnimation(AppMotion.fast) { drilldown = .artist(artist, RemoteMusicGrouping.tracks(inArtist: artist, from: tracks)) } },
                                onPlay: { appState.replaceMusicQueueAndPlay(RemoteMusicGrouping.tracks(inArtist: artist, from: tracks)) },
                                onCreatePlaylist: { playlistCreationRequest = $0 },
                                onResetPlayCounts: {},
                                tracksProvider: { RemoteMusicGrouping.tracks(inArtist: artist, from: tracks) }
                            )
                        }
                    }
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.top, MusicCollectionGridMetrics.artist.firstRowTopInset)
                    .padding(.bottom, 28)
                }
                .suppressHoverEffectsDuringScroll()
            }
        }
    }

    private func songList(for list: [MediaItem]) -> some View {
        MusicSongListView(
            rows: MusicLibrarySnapshotBuilder.rowModels(from: list),
            showsHistoryAction: tab == .recent,
            showsMetadataActions: false,     // 远程音乐不提供元数据补充
            queueContext: list,
            onSearchMetadata: { _ in },
            onCreatePlaylist: { playlistCreationRequest = $0 }
        )
        // 与本地音乐页 standaloneLongListBody 一致：歌曲列表内容左右缩进 pageHorizontal，
        // 否则远程页歌曲列表贴边、与上方专辑/艺术家网格及控制栏错位。
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // 专辑/艺术家下钻：复用本地同款 MusicCollectionTrackList（歌单相关回调对专辑/艺术家为空实现）。
    private func drilldownBody(_ drilldown: MusicCollectionDrilldown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCollectionTrackList(
                collection: drilldown,
                rows: MusicLibrarySnapshotBuilder.rowModels(from: drilldown.tracks),
                onBack: { withAnimation(AppMotion.fast) { self.drilldown = nil } },
                onPlayAll: { appState.replaceMusicQueueAndPlay(drilldown.tracks) },
                onSearchMetadata: { _ in },
                onCreatePlaylist: { playlistCreationRequest = $0 },
                onRenamePlaylist: { _ in },
                onDeletePlaylist: { _ in },
                onRemoveFromPlaylist: { _, _ in },
                onReplacePlaylistItems: { _, _ in }
            )
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.top, AppSpacing.pageVertical)
    }

    private func emptyState(_ text: String, systemImage: String) -> some View {
        EmptyStateView(title: text, systemImage: systemImage, message: "扫描后，该来源的音乐会归类到这里。")
            .staticSurfaceBackground(cornerRadius: 22)
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.bottom, AppSpacing.headerToControls)
    }

    private var mappedLocalSection: MusicLibrarySection {
        switch tab {
        case .songs: return .songs
        case .albums: return .albums
        case .artists: return .artists
        case .recent: return .recent
        }
    }

    private var availableSortModes: [MusicSortMode] {
        switch tab {
        case .songs, .recent:
            return [.title, .artist, .album, .mostPlayed, .recent, .duration]
        case .albums:
            return [.title, .artist, .recent, .mostPlayed]
        case .artists:
            return [.title, .workCount, .mostPlayed]
        }
    }

    private var currentItemCount: Int {
        switch tab {
        case .songs, .recent: return currentTracks.count
        case .albums: return albumGroups.count
        case .artists: return artistGroups.count
        }
    }

    private var currentItemUnit: String {
        switch tab {
        case .songs, .recent: return "首"
        case .albums: return "张"
        case .artists: return "位"
        }
    }

    private func selectSortMode(_ mode: MusicSortMode) {
        if sortMode == mode {
            sortOrder.toggle()
        } else {
            sortMode = mode
            sortOrder = .primary
        }
    }
}

private enum RemoteMusicOrdering {
    static func tracks(_ tracks: [MediaItem], query: String, mode: MusicSortMode, order: MusicSortOrder) -> [MediaItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = normalized.isEmpty ? tracks : tracks.filter {
            PinyinSearchMatcher.matches(query: normalized, in: [$0.title, $0.artist ?? "", $0.album ?? ""])
        }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch mode {
            case .artist:
                comparison = compare(lhs.artist ?? "", rhs.artist ?? "")
            case .album:
                comparison = compare(lhs.album ?? "", rhs.album ?? "")
            case .recent:
                comparison = compare(lhs.lastPlayedAt ?? lhs.updatedAt, rhs.lastPlayedAt ?? rhs.updatedAt)
            case .duration:
                comparison = compare(lhs.duration ?? 0, rhs.duration ?? 0)
            case .mostPlayed:
                comparison = compare(lhs.playCountValue, rhs.playCountValue)
            default:
                comparison = compare(lhs.title, rhs.title)
            }
            if comparison == .orderedSame {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return order == .primary ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    static func albums(_ albums: [MusicAlbumGroup], query: String, mode: MusicSortMode, order: MusicSortOrder) -> [MusicAlbumGroup] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = normalized.isEmpty ? albums : albums.filter {
            PinyinSearchMatcher.matches(query: normalized, in: [$0.summary.title, $0.summary.artist])
        }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch mode {
            case .artist: comparison = compare(lhs.summary.artist, rhs.summary.artist)
            case .recent: comparison = compare(lhs.latestUpdatedAt, rhs.latestUpdatedAt)
            case .mostPlayed: comparison = compare(lhs.playCount, rhs.playCount)
            default: comparison = compare(lhs.summary.title, rhs.summary.title)
            }
            return order == .primary ? comparison != .orderedDescending : comparison == .orderedDescending
        }
    }

    static func artists(_ artists: [MusicArtistGroup], query: String, mode: MusicSortMode, order: MusicSortOrder) -> [MusicArtistGroup] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = normalized.isEmpty ? artists : artists.filter { PinyinSearchMatcher.matches(query: normalized, in: [$0.name]) }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch mode {
            case .workCount: comparison = compare(lhs.trackCount, rhs.trackCount)
            case .mostPlayed: comparison = compare(lhs.playCount, rhs.playCount)
            default: comparison = compare(lhs.name, rhs.name)
            }
            return order == .primary ? comparison != .orderedDescending : comparison == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedCaseInsensitiveCompare(rhs)
    }
}

/// 从远程音乐条目在内存里就地构建与本地一致的 MusicAlbumGroup / MusicArtistGroup，
/// 让远程音乐页能直接复用 MusicAlbumCard / MusicArtistRow（远程音乐不进全局音乐索引，故本地投影里没有）。
private enum RemoteMusicGrouping {
    static func albumGroups(sourceID: String, tracks: [MediaItem]) -> [MusicAlbumGroup] {
        let grouped = Dictionary(grouping: tracks) { musicDisplayAlbum($0.album) }
        return grouped.map { title, groupTracks in
            let artist = musicDisplayArtist(groupTracks.first?.artist)
            let summary = MusicAlbumSummary(
                id: "emby-album|\(sourceID)|\(title)",
                title: title,
                artist: artist,
                titleKey: title.lowercased(),
                artistKey: artist.lowercased(),
                trackCount: groupTracks.count,
                favoriteCount: groupTracks.filter(\.favorite).count,
                remoteCount: groupTracks.count,
                playCount: groupTracks.reduce(0) { $0 + ($1.playCount ?? 0) },
                totalDuration: groupTracks.compactMap(\.duration).reduce(0, +),
                coverPath: cover(from: groupTracks),
                latestUpdatedAt: groupTracks.map(\.updatedAt).max() ?? .distantPast,
                trackIDs: groupTracks.map(\.id)
            )
            return MusicAlbumGroup(summary: summary)
        }
        .sorted { $0.summary.title.localizedStandardCompare($1.summary.title) == .orderedAscending }
    }

    static func artistGroups(sourceID: String, tracks: [MediaItem]) -> [MusicArtistGroup] {
        let grouped = Dictionary(grouping: tracks) { musicDisplayArtist($0.artist) }
        return grouped.map { name, groupTracks in
            let albumKeys = Set(groupTracks.map { musicDisplayAlbum($0.album).lowercased() })
            let summary = MusicArtistSummary(
                id: "emby-artist|\(sourceID)|\(name)",
                name: name,
                nameKey: name.lowercased(),
                trackCount: groupTracks.count,
                albumCount: albumKeys.count,
                favoriteCount: groupTracks.filter(\.favorite).count,
                remoteCount: groupTracks.count,
                playCount: groupTracks.reduce(0) { $0 + ($1.playCount ?? 0) },
                coverPath: cover(from: groupTracks),
                latestUpdatedAt: groupTracks.map(\.updatedAt).max() ?? .distantPast,
                trackIDs: groupTracks.map(\.id)
            )
            return MusicArtistGroup(summary: summary)
        }
        .sorted { $0.summary.name.localizedStandardCompare($1.summary.name) == .orderedAscending }
    }

    static func tracks(inAlbum album: MusicAlbumGroup, from tracks: [MediaItem]) -> [MediaItem] {
        let ids = Set(album.summary.trackIDs)
        return MusicTrackProjectionPolicy.sortedByAlbumTrackAndTitle(tracks.filter { ids.contains($0.id) })
    }

    static func tracks(inArtist artist: MusicArtistGroup, from tracks: [MediaItem]) -> [MediaItem] {
        let ids = Set(artist.summary.trackIDs)
        return MusicTrackProjectionPolicy.sortedByAlbumTrackAndTitle(tracks.filter { ids.contains($0.id) })
    }

    private static func cover(from tracks: [MediaItem]) -> String? {
        tracks.first { !($0.posterPath?.hasSuffix("-default.jpg") ?? true) }?.posterPath ?? tracks.first?.posterPath
    }
}
