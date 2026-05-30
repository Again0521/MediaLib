import Foundation
import MediaLibCore
import SwiftUI
import UniformTypeIdentifiers

private enum MusicLyricsPresenceCache {
    private static var values: [String: Bool] = [:]
    private static var accessOrder: [String] = []
    private static var cacheRevision = 0
    private static let maxValues = 4096
    private static let lock = NSLock()

    static var revision: Int {
        lock.lock()
        defer { lock.unlock() }
        return cacheRevision
    }

    static func cachedHasLyrics(filePath: String?, includeGenericNames: Bool) -> Bool? {
        guard let filePath else { return false }
        let cacheKey = key(filePath: filePath, includeGenericNames: includeGenericNames)
        lock.lock()
        defer { lock.unlock() }
        guard let cached = values[cacheKey] else { return nil }
        markRecentlyUsed(cacheKey)
        return cached
    }

    static func hasLyrics(filePath: String?, includeGenericNames: Bool) -> Bool {
        guard let filePath else { return false }
        let cacheKey = key(filePath: filePath, includeGenericNames: includeGenericNames)
        lock.lock()
        if let cached = values[cacheKey] {
            markRecentlyUsed(cacheKey)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let exists = lyricsExist(filePath: filePath)
        lock.lock()
        values[cacheKey] = exists
        markRecentlyUsed(cacheKey)
        trimIfNeeded()
        cacheRevision += 1
        lock.unlock()
        return exists
    }

    static func warmCache(filePaths: [String?], includeGenericNames: Bool) async -> Bool {
        let paths = Array(Set(filePaths.compactMap { $0 }))
        let missing = missingEntries(for: paths, includeGenericNames: includeGenericNames)
        guard !missing.isEmpty else { return false }

        let results = await Task.detached(priority: .utility) {
            missing.map { entry in
                (cacheKey: entry.cacheKey, exists: lyricsExist(filePath: entry.path))
            }
        }.value

        return store(results)
    }

    private static func missingEntries(for paths: [String], includeGenericNames: Bool) -> [(path: String, cacheKey: String)] {
        lock.lock()
        defer { lock.unlock() }
        return paths
            .map { (path: $0, cacheKey: key(filePath: $0, includeGenericNames: includeGenericNames)) }
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

    private static func key(filePath: String, includeGenericNames: Bool) -> String {
        "\(filePath)#\(includeGenericNames)"
    }

    private static func markRecentlyUsed(_ cacheKey: String) {
        accessOrder.removeAll { $0 == cacheKey }
        accessOrder.append(cacheKey)
    }

    private static func trimIfNeeded() {
        guard values.count > maxValues else { return }
        while values.count > maxValues, let oldestKey = accessOrder.first {
            accessOrder.removeFirst()
            values.removeValue(forKey: oldestKey)
        }
    }

    private static func lyricsExist(filePath: String) -> Bool {
        let url = URL(fileURLWithPath: filePath)
        let directory = url.deletingLastPathComponent()
        let basename = url.deletingPathExtension().lastPathComponent
        let candidates = [
            directory.appendingPathComponent("\(basename).lrc"),
            directory.appendingPathComponent("\(basename).txt")
        ]

        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private enum MusicLibrarySnapshotCache {
    struct Key: Hashable, Sendable {
        let section: MusicLibrarySection
        let searchText: String
        let sortMode: MusicSortMode
        let filterMode: MusicFilterMode
        let revision: Int
        let lyricsRevision: Int
    }

    struct Snapshot: Sendable {
        let rows: [MusicTrackRowModel]
        let albums: [MusicAlbumGroup]
        let artists: [MusicArtistGroup]
    }

    private static var values: [Key: Snapshot] = [:]
    private static var accessOrder: [Key] = []

    static func snapshot(for key: Key) -> Snapshot? {
        guard let snapshot = values[key] else { return nil }
        markRecentlyUsed(key)
        return snapshot
    }

    static func store(_ snapshot: Snapshot, for key: Key) {
        values[key] = snapshot
        markRecentlyUsed(key)
        if values.count > 16 {
            while values.count > 16, let oldestKey = accessOrder.first {
                accessOrder.removeFirst()
                values.removeValue(forKey: oldestKey)
            }
        }
    }

    private static func markRecentlyUsed(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

private struct MusicLibrarySnapshotBuildInput: Sendable {
    let tracks: [MediaItem]
    let searchText: String
    let sortMode: MusicSortMode
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

private enum MusicLibrarySnapshotBuilder {
    static func snapshot(from input: MusicLibrarySnapshotBuildInput) -> MusicLibrarySnapshotCache.Snapshot {
        let tracks = resolvedTracks(from: input.tracks, input: input)
        return MusicLibrarySnapshotCache.Snapshot(
            rows: rowModels(from: tracks),
            albums: albumGroups(from: tracks),
            artists: artistGroups(from: tracks)
        )
    }

    static func resolvedTracks(from tracks: [MediaItem], input: MusicLibrarySnapshotBuildInput) -> [MediaItem] {
        let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched: [MediaItem]
        if query.isEmpty {
            searched = tracks
        } else {
            searched = tracks.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                ($0.originalTitle?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.artist?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.album?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        let filtered = searched.filter { track in
            switch input.filterMode {
            case .all: return true
            case .favorites: return track.favorite
            case .withLyrics:
                return MusicLyricsPresenceCache.cachedHasLyrics(filePath: track.filePath, includeGenericNames: false) ?? false
            case .unmatched:
                return (track.artist?.isEmpty ?? true) || (track.album?.isEmpty ?? true) || track.metadataProvider == nil
            }
        }

        return filtered.sorted { lhs, rhs in
            switch input.sortMode {
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .artist:
                return (lhs.artist ?? "").localizedStandardCompare(rhs.artist ?? "") == .orderedAscending
            case .album:
                return (lhs.album ?? "").localizedStandardCompare(rhs.album ?? "") == .orderedAscending
            case .recent:
                return lhs.updatedAt > rhs.updatedAt
            case .duration:
                return (lhs.duration ?? 0) > (rhs.duration ?? 0)
            }
        }
    }

    static func rowModels(from tracks: [MediaItem]) -> [MusicTrackRowModel] {
        tracks.map { track in
            MusicTrackRowModel(
                track: track,
                titleText: displayNameWithoutKnownExtension(track.title),
                fileName: track.filePath.map { displayNameWithoutKnownExtension(URL(fileURLWithPath: $0).lastPathComponent) },
                artistText: track.artist?.isEmpty == false ? track.artist! : "未知艺术家",
                albumText: track.album?.isEmpty == false ? track.album! : "未知专辑",
                hasLocalLyrics: MusicLyricsPresenceCache.cachedHasLyrics(filePath: track.filePath, includeGenericNames: false) ?? false,
                durationText: durationText(track.duration)
            )
        }
    }

    static func albumGroups(from tracks: [MediaItem]) -> [MusicAlbumGroup] {
        let grouped = Dictionary(grouping: tracks) { item in
            MusicAlbumKey(title: item.album?.isEmpty == false ? item.album! : "未知专辑", artist: item.artist?.isEmpty == false ? item.artist! : "未知艺术家")
        }
        return grouped.map { key, items in
            MusicAlbumGroup(key: key, tracks: items.sorted { ($0.trackNumber ?? 0, $0.title) < ($1.trackNumber ?? 0, $1.title) })
        }
        .sorted { $0.key.title.localizedStandardCompare($1.key.title) == .orderedAscending }
    }

    static func artistGroups(from tracks: [MediaItem]) -> [MusicArtistGroup] {
        let grouped = Dictionary(grouping: tracks) { item in
            item.artist?.isEmpty == false ? item.artist! : "未知艺术家"
        }
        return grouped.map { name, items in
            MusicArtistGroup(name: name, tracks: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func displayNameWithoutKnownExtension(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: trimmed)
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty,
              ["mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac"].contains(ext) else {
            return trimmed
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

struct MusicLibraryView: View {
    @EnvironmentObject private var appState: AppState
    let section: MusicLibrarySection
    @State private var searchText = ""
    @State private var metadataItem: MediaItem?
    @State private var sortMode: MusicSortMode = .title
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

    var body: some View {
        Group {
            if usesStandaloneLongList {
                standaloneLongListBody
            } else {
                scrollingBody
            }
        }
        .suppressListHighlight()
        .background(AppPageBackground())
        .navigationTitle(section.title)
        .onAppear {
            loadViewState(for: section)
            refreshVisibleContent(for: section)
        }
        .onChange(of: searchText) { _ in
            drilldown = nil
            scheduleSearchRefresh()
        }
        .onChange(of: section.id) { newSectionID in
            guard let newSection = MusicLibrarySection(rawValue: newSectionID) else { return }
            searchRefreshTask?.cancel()
            lyricsRefreshTask?.cancel()
            drilldown = nil
            loadViewState(for: newSection, reset: true)
            refreshVisibleContent(for: newSection, deferred: true)
        }
        .onChange(of: sortMode) { _ in
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
            Text("歌单会从 MediaLIB 索引中删除，歌曲文件不会被移动、删除或改名。")
        }
        .onChange(of: appState.musicPlaylists) { _ in
            refreshActivePlaylistDrilldown()
        }
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

    private var pageHeader: some View {
        PageHeader(title: section.title, subtitle: subtitle, systemImage: section.systemImage) {
            GlassSearchField(placeholder: "搜索音乐", text: $searchText)
            if section == .playlists {
                Button {
                    presentPlaylistCreation(tracks: [], suggestedName: "新歌单")
                } label: {
                    Label("新建歌单", systemImage: "plus")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 13, horizontalPadding: 12, minHeight: 34, prominent: true))
            } else {
                Button {
                    appState.scanSources(for: .music(section))
                } label: {
                    Label("扫描", systemImage: "arrow.clockwise")
                }
                .disabled(appState.sources.isEmpty || appState.isScanning)
            }
            if showsPlaybackHistoryAction {
                Button {
                    appState.clearPlaybackHistory(playbackTraceTracks)
                } label: {
                    Label("清除记录", systemImage: "clock.badge.xmark")
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
        .buttonStyle(.plain)
        .liquidGlass(cornerRadius: 19)
        .padding(.trailing, 22)
        .padding(.bottom, scrollTopButtonBottomPadding)
        .help("返回顶部")
    }

    private var usesStandaloneLongList: Bool {
        if drilldown != nil {
            return true
        }
        switch section {
        case .songs, .albums, .artists, .recent, .favorites, .unmatched:
            return true
        case .playlists:
            return false
        }
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
            filterMode: filterMode,
            revision: appState.libraryRevision,
            lyricsRevision: MusicLyricsPresenceCache.revision
        )
    }

    private var visibleContentIsOutOfDate: Bool {
        visibleContentSectionID != section.id &&
        MusicLibrarySnapshotCache.snapshot(for: snapshotKey(for: section)) == nil
    }

    private func refreshVisibleContent(for targetSection: MusicLibrarySection, deferred: Bool = false) {
        contentRefreshTask?.cancel()
        let baseTracks = appState.items(for: .music(targetSection), searchText: "")
        scheduleLyricsPresenceRefresh(for: baseTracks, section: targetSection)

        let key = snapshotKey(for: targetSection)
        if let snapshot = MusicLibrarySnapshotCache.snapshot(for: key) {
            visibleTrackRows = snapshot.rows
            visibleAlbumGroups = snapshot.albums
            visibleArtistGroups = snapshot.artists
            visibleContentSectionID = targetSection.id
            isPreparingVisibleContent = false
            return
        }

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
            await computeVisibleContent(for: targetSection, baseTracks: baseTracks, key: key)
        }
    }

    private func computeVisibleContent(
        for targetSection: MusicLibrarySection,
        baseTracks: [MediaItem],
        key: MusicLibrarySnapshotCache.Key
    ) async {
        guard !Task.isCancelled else { return }
        guard key == snapshotKey(for: targetSection) else { return }

        let input = MusicLibrarySnapshotBuildInput(
            tracks: baseTracks,
            searchText: key.searchText,
            sortMode: key.sortMode,
            filterMode: key.filterMode
        )
        let snapshot = await Task.detached(priority: .userInitiated) {
            MusicLibrarySnapshotBuilder.snapshot(from: input)
        }.value

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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                MusicFilterModeCapsules(selection: $filterMode)

                Spacer(minLength: 18)

                sortModeMenu
            }

            VStack(alignment: .leading, spacing: 10) {
                MusicFilterModeCapsules(selection: $filterMode)

                HStack {
                    Spacer(minLength: 0)
                    sortModeMenu
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 1.04)
    }

    private var sortModeMenu: some View {
        GlassMenuButton(title: sortMode.title, width: 156) {
            ForEach(MusicSortMode.allCases) { mode in
                Button {
                    sortMode = mode
                } label: {
                    Label(mode.title, systemImage: sortMode == mode ? "checkmark" : "circle")
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
            let changed = await MusicLyricsPresenceCache.warmCache(filePaths: filePaths, includeGenericNames: false)
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
            filterMode = .all
        }
        guard !didLoadViewState else { return }
        didLoadViewState = true
        let stateKeyPrefix = stateKeyPrefix(for: targetSection)
        sortMode = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).sort")
            .flatMap(MusicSortMode.init(rawValue:)) ?? .title
        filterMode = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).filter")
            .flatMap(MusicFilterMode.init(rawValue:)) ?? .all
    }

    private func saveViewState(for targetSection: MusicLibrarySection) {
        guard didLoadViewState else { return }
        let stateKeyPrefix = stateKeyPrefix(for: targetSection)
        UserDefaults.standard.set(sortMode.rawValue, forKey: "\(stateKeyPrefix).sort")
        UserDefaults.standard.set(filterMode.rawValue, forKey: "\(stateKeyPrefix).filter")
    }

    private var subtitle: String {
        switch section {
        case .songs: return "这里是你所有的歌曲。"
        case .albums: return "歌曲按专辑分组，方便整张听。"
        case .artists: return "歌曲按歌手分组。"
        case .playlists: return "管理你的歌单"
        case .recent: return "你最近听过的歌。"
        case .favorites: return "你点过红心的歌都在这里。"
        case .unmatched: return "缺少歌手或专辑信息、没匹配上封面歌词的歌。"
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
                    EmptyStateView(title: "暂无\(section.title)", systemImage: section.systemImage, message: "添加音乐媒体源并扫描后，这里会显示歌曲。")
                        .staticSurfaceBackground(cornerRadius: 22)
                } else {
                    MusicSongListView(
                        rows: displayedTrackRows,
                        showsHistoryAction: section == .recent,
                        onSearchMetadata: { metadataItem = $0 },
                        onCreatePlaylist: { playlistCreationRequest = $0 }
                    )
                }
            case .albums:
                if displayedAlbumGroups.isEmpty {
                    EmptyStateView(title: "暂无专辑", systemImage: "square.stack", message: "扫描音乐目录后，MediaLIB 会按专辑字段自动聚合。")
                        .staticSurfaceBackground(cornerRadius: 22)
                } else {
                    ProgressiveMusicAlbumGrid(albums: displayedAlbumGroups) { album in
                        drilldown = .album(album)
                    } onPlay: { album in
                        appState.replaceMusicQueueAndPlay(album.tracks)
                    } onCreatePlaylist: { request in
                        playlistCreationRequest = request
                    }
                }
            case .artists:
                if displayedArtistGroups.isEmpty {
                    EmptyStateView(title: "暂无艺术家", systemImage: "person.2", message: "扫描音乐目录后，MediaLIB 会按艺术家字段自动聚合。")
                        .staticSurfaceBackground(cornerRadius: 22)
                } else {
                    ProgressiveMusicArtistList(artists: displayedArtistGroups) { artist in
                        drilldown = .artist(artist)
                    } onPlay: { artist in
                        appState.replaceMusicQueueAndPlay(artist.tracks)
                    } onCreatePlaylist: { request in
                        playlistCreationRequest = request
                    }
                }
            case .playlists:
                if filteredPlaylists.isEmpty {
                    EmptyStateView(title: "没有匹配的歌单", systemImage: "magnifyingglass", message: "换个关键词试试。")
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
            playlist.name.localizedCaseInsensitiveContains(query)
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

    private func rowModels(from tracks: [MediaItem]) -> [MusicTrackRowModel] {
        MusicLibrarySnapshotBuilder.rowModels(from: tracks)
    }
}

private struct MusicSongListView: View {
    @EnvironmentObject private var appState: AppState
    let rows: [MusicTrackRowModel]
    var showsHistoryAction: Bool = false
    let onSearchMetadata: (MediaItem) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void

    var body: some View {
        // 用 ScrollView + LazyVStack 取代原生 List：彻底避开 NSTableView 整行蓝色高亮，
        // 右键能精确命中单首歌。LazyVStack 仍懒加载行，支持上千首歌。
        ScrollView {
            LazyVStack(spacing: 0) {
                MusicSongHeader()
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)

                ForEach(rows) { row in
                    MusicSongRow(
                        row: row,
                        showsHistoryAction: showsHistoryAction,
                        onSearchMetadata: onSearchMetadata,
                        onCreatePlaylist: onCreatePlaylist
                    )
                    .id(row.id)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }

                Color.clear.frame(height: listBottomInset)
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
}

private struct MusicSongListSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        LiquidGlassSurfaceLayer(
            cornerRadius: cornerRadius,
            thickness: 1.02,
            respondsToPointer: false,
            renderMode: .efficient
        )
    }
}

private extension View {
    /// 列表外层玻璃卡片：上方圆角，下方为直角并延伸到窗口底部外，
    /// 视觉上像列表直接连接到软件下边界，而不是被装在一个有限长度的卡片里。
    func bleedingListCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .background(alignment: .top) {
                // 向下负内边距使卡片底部圆角被推到窗口下边界之外（被窗口裁剪），
                // 只保留上方圆角，下方呈直角紧贴窗口底部。
                MusicSongListSurface(cornerRadius: cornerRadius)
                    .padding(.bottom, -200)
            }
    }
}

private enum MusicCollectionDrilldown: Identifiable {
    case album(MusicAlbumGroup)
    case artist(MusicArtistGroup)
    case playlist(MusicPlaylist, [MediaItem])

    var id: String {
        switch self {
        case .album(let album): return "album-\(album.id)"
        case .artist(let artist): return "artist-\(artist.id)"
        case .playlist(let playlist, _): return "playlist-\(playlist.id)"
        }
    }

    var title: String {
        switch self {
        case .album(let album): return album.key.title
        case .artist(let artist): return artist.name
        case .playlist(let playlist, _): return playlist.name
        }
    }

    var subtitle: String {
        switch self {
        case .album(let album): return "\(album.key.artist) · \(album.tracks.count) 首歌曲"
        case .artist(let artist): return "\(artist.tracks.count) 首歌曲 · \(artist.albumCount) 张专辑"
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
        case .album(let album): return album.tracks
        case .artist(let artist): return artist.tracks
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

    var body: some View {
        let tracks = rows.map(\.track)
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
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 8, minHeight: 30))
                .help("返回")

                PlayfulSymbolIcon(systemImage: collection.systemImage, size: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(collection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if let playlist, !isFavoritePlaylist {
                    Button {
                        onRenamePlaylist(playlist)
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))

                    Button(role: .destructive) {
                        onDeletePlaylist(playlist)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))
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
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .staticSurfaceBackground(cornerRadius: 18)

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
    @State private var rowsSignature = ""

    var body: some View {
        List {
            MusicSongHeader()
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
        .onChange(of: rows.map(\.id).joined(separator: "|")) { _ in
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
        let signature = rows.map(\.id).joined(separator: "|")
        guard force || rowsSignature != signature else { return }
        rowsSignature = signature
        orderedRows = rows
    }

    private func commitOrder() {
        onCommitOrder(orderedRows.map(\.track))
        rowsSignature = orderedRows.map(\.id).joined(separator: "|")
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

    var id: String { rawValue }
    var title: String {
        switch self {
        case .title: return "歌曲名"
        case .artist: return "艺术家"
        case .album: return "专辑"
        case .recent: return "最近更新"
        case .duration: return "时长"
        }
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

    var body: some View {
        HStack(spacing: 7) {
            ForEach(MusicFilterMode.allCases) { mode in
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

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 42)
            Text("歌曲")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("艺术家")
                .frame(width: 150, alignment: .leading)
            Text("专辑")
                .frame(width: 170, alignment: .leading)
            Text("歌词")
                .frame(width: 48, alignment: .center)
            Text("时长")
                .frame(width: 58, alignment: .trailing)
            Color.clear.frame(width: 30)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                .frame(height: 0.5)
                .padding(.horizontal, 4)
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
    let onSearchMetadata: (MediaItem) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    var onRemoveFromPlaylist: ((MediaItem) -> Void)?
    @State private var isHovering = false

    var body: some View {
        let hoverActive = isHovering && !suppressHoverDuringScroll
        let rowShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        HStack(spacing: 12) {
            MusicRowArtwork(path: row.track.posterPath, title: row.track.title)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(!reduceMotion && hoverActive ? 1.035 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.titleText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let fileName = row.fileName {
                    Text(fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.artistText)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Text(row.albumText)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            Image(systemName: row.hasLocalLyrics ? "text.quote" : "minus")
                .foregroundStyle(row.hasLocalLyrics ? AppColors.selectedGlassTint.opacity(0.82) : Color.secondary)
                .frame(width: 48)

            Text(row.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)

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
            .help("立即获取音乐信息")

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
                .help("从歌单移出")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(height: 58)
        .background {
            if hoverActive {
                LiquidGlassSurfaceLayer(
                    selected: true,
                    cornerRadius: 12,
                    thickness: 0.98,
                    respondsToPointer: false,
                    renderMode: .efficient
                )
            } else {
                rowShape.fill(Color.clear)
            }
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(AppColors.solarEdgeTint.opacity(hoverActive ? (colorScheme == .dark ? 0.22 : 0.28) : 0))
                .frame(width: 3, height: 28)
                .padding(.leading, 2)
        }
        .scaleEffect(!reduceMotion && hoverActive ? 1.002 : 1)
        .contentShape(rowShape)
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
            appState.play(row.track)
        }
        .contextMenu {
            Button("播放") { appState.play(row.track) }
            Button("加入播放队列") { appState.addToMusicQueue(row.track) }
            Button("下一首播放") { appState.playNextInMusicQueue(row.track) }
            MusicPlaylistActionsMenu(
                tracks: [row.track],
                suggestedName: row.track.title,
                onCreateNew: onCreatePlaylist
            )
            if showsHistoryAction && row.track.hasPlaybackTrace {
                Button("删除播放记录") { appState.clearPlaybackHistory(row.track) }
            }
            if let onRemoveFromPlaylist {
                Button("从歌单移出", role: .destructive) {
                    onRemoveFromPlaylist(row.track)
                }
            }
            Button("获取音乐信息") { onSearchMetadata(row.track) }
            Button(row.track.favorite ? "取消收藏" : "收藏") { appState.toggleFavorite(row.track) }
            Menu("重新分类") {
                ForEach([MediaType.movie, .tvShow, .anime, .documentary, .variety, .other, .privateCollection], id: \.self) { type in
                    Button(type.displayName) {
                        appState.reclassify(row.track, as: type)
                    }
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
            PosterImage(path: path, title: title, mediaType: .music)
        }
    }

    private var usesDefaultArtwork: Bool {
        guard let path else { return true }
        return path.hasSuffix("-default.jpg")
    }
}

private struct MusicAlbumCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let album: MusicAlbumGroup
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    @State private var isHovering = false
    private static let coverCacheTargetSize = CGSize(width: 180, height: 180)

    var body: some View {
        let hoverActive = isHovering && !suppressHoverDuringScroll

        VStack(alignment: .leading, spacing: 10) {
            PosterImage(path: album.coverPath, title: album.key.title, mediaType: .music, cacheTargetSize: Self.coverCacheTargetSize)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(hoverActive ? 0.58 : 0.28), lineWidth: hoverActive ? 1.1 : 0.8)
                }
                .pointerInspectTilt(enabled: true, cornerRadius: 16)

            MarqueeText(text: album.key.title, font: .headline)
                .frame(height: 20)
            MarqueeText(text: "\(album.key.artist) · \(album.tracks.count) 首", font: .caption)
                .frame(height: 15)
                .foregroundStyle(.secondary)

            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))
        }
        .padding(14)
        .staticSurfaceBackground(cornerRadius: 18)
        .repeatedSurfaceHover(hoverActive, cornerRadius: 18, tint: AppColors.pointerLightTint, intensity: 0.82)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Button("查看歌曲") { onOpen() }
            Button("播放") { onPlay() }
            MusicPlaylistActionsMenu(
                tracks: album.tracks,
                suggestedName: album.key.title,
                onCreateNew: onCreatePlaylist
            )
        }
    }
}

private struct MusicArtistRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let artist: MusicArtistGroup
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void
    @State private var isHovering = false

    var body: some View {
        let hoverActive = isHovering && !suppressHoverDuringScroll
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.accentGradient)
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.headline)
                Text("\(artist.tracks.count) 首歌曲 · \(artist.albumCount) 张专辑")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))
        }
        .padding(14)
        .background {
            LiquidGlassSurfaceLayer(
                selected: hoverActive,
                cornerRadius: 18,
                thickness: hoverActive ? 1.08 : 1.0,
                respondsToPointer: false,
                renderMode: GlassSurfaceRole.repeatedHover.renderMode
            )
        }
        .repeatedSurfaceHover(hoverActive, cornerRadius: 18, tint: AppColors.pointerLightTint, intensity: 0.92)
        .contentShape(shape)
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
            Button("查看歌曲") { onOpen() }
            Button("播放") { onPlay() }
            MusicPlaylistActionsMenu(
                tracks: artist.tracks,
                suggestedName: artist.name,
                onCreateNew: onCreatePlaylist
            )
        }
    }
}

private struct ProgressiveMusicAlbumGrid: View {
    @EnvironmentObject private var appState: AppState
    let albums: [MusicAlbumGroup]
    let onOpen: (MusicAlbumGroup) -> Void
    let onPlay: (MusicAlbumGroup) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void

    var body: some View {
        GeometryReader { proxy in
            let columns = columnCount(for: proxy.size.width)
            let rows = rowCount(for: columns)

            List {
                ForEach(0..<rows, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(0..<columns, id: \.self) { columnIndex in
                            let index = rowIndex * columns + columnIndex
                            if index < albums.count {
                                let album = albums[index]
                                MusicAlbumCard(
                                    album: album,
                                    onOpen: { onOpen(album) },
                                    onPlay: { onPlay(album) },
                                    onCreatePlaylist: onCreatePlaylist
                                )
                                .frame(maxWidth: .infinity, alignment: .top)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
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
            .bleedingListCard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
    }

    private func columnCount(for width: CGFloat) -> Int {
        let spacing: CGFloat = 16
        let minimumCardWidth: CGFloat = 220
        let availableWidth = max(width - 20, minimumCardWidth)
        return max(1, Int((availableWidth + spacing) / (minimumCardWidth + spacing)))
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
    let onOpen: (MusicArtistGroup) -> Void
    let onPlay: (MusicArtistGroup) -> Void
    let onCreatePlaylist: (MusicPlaylistCreationRequest) -> Void

    var body: some View {
        List {
            ForEach(artists) { artist in
                MusicArtistRow(
                    artist: artist,
                    onOpen: { onOpen(artist) },
                    onPlay: { onPlay(artist) },
                    onCreatePlaylist: onCreatePlaylist
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 10, trailing: 0))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
        .bleedingListCard()
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

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.accentGradient)
                Image(systemName: isPinnedFavorite ? "heart.fill" : "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(tracks.count) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))
            .disabled(tracks.isEmpty)

            if !isPinnedFavorite {
                Menu {
                    Button("重命名") { onRename() }
                    Button("删除", role: .destructive) { onDelete() }
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
        .padding(14)
        .staticSurfaceBackground(cornerRadius: 18)
        .repeatedSurfaceHover(hoverActive, cornerRadius: 18, tint: AppColors.pointerLightTint, intensity: 0.82)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Button("查看歌曲") { onOpen() }
            Button("播放") { onPlay() }
                .disabled(tracks.isEmpty)
            if !isPinnedFavorite {
                Button("重命名") { onRename() }
                Button("删除", role: .destructive) { onDelete() }
            }
        }
    }
}

private struct MusicAlbumKey: Hashable, Sendable {
    let title: String
    let artist: String
}

private struct MusicAlbumGroup: Identifiable, Sendable {
    let key: MusicAlbumKey
    let tracks: [MediaItem]

    var id: String { "\(key.artist)-\(key.title)" }
    var coverPath: String? { tracks.first?.posterPath }
}

private struct MusicArtistGroup: Identifiable, Sendable {
    let name: String
    let tracks: [MediaItem]

    var id: String { name }
    var albumCount: Int {
        Set(tracks.map { $0.album?.isEmpty == false ? $0.album! : "未知专辑" }).count
    }
}
