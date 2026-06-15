import AppKit
import MediaLibCore
import SwiftUI

enum VideoLibrarySection: String, CaseIterable, Identifiable, Sendable {
    case movies
    case tvShows
    case anime
    case documentaries
    case variety
    case homeVideos
    case other
    case privacy
    case watching
    case watchlist
    case favorites
    case unwatched
    case watched

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "电影"
        case .tvShows: return "电视剧"
        case .anime: return "动漫"
        case .documentaries: return "纪录片"
        case .variety: return "综艺"
        case .homeVideos: return "家庭录像"
        case .other: return "其他"
        case .privacy: return "保险库"
        case .watching: return "正在观看"
        case .watchlist: return "想看"
        case .favorites: return "喜欢"
        case .unwatched: return "未观看"
        case .watched: return "已观看"
        }
    }

    var systemImage: String {
        switch self {
        case .movies: return "film"
        case .tvShows: return "tv"
        case .anime: return "sparkles.tv"
        case .documentaries: return "books.vertical"
        case .variety: return "music.mic"
        case .homeVideos: return "video"
        case .other: return "tray"
        case .privacy: return "lock.rectangle.stack"
        case .watching: return "play.circle"
        case .watchlist: return "bookmark"
        case .favorites: return "heart"
        case .unwatched: return "eye"
        case .watched: return "checkmark.circle"
        }
    }
}

enum MusicLibrarySection: String, CaseIterable, Identifiable, Sendable {
    case songs
    case albums
    case artists
    case playlists
    case recent
    case favorites
    case unmatched

    var id: String { rawValue }

    static var sidebarCases: [MusicLibrarySection] {
        allCases.filter { $0 != .favorites && $0 != .unmatched }
    }

    var title: String {
        switch self {
        case .songs: return "歌曲"
        case .albums: return "专辑"
        case .artists: return "艺术家"
        case .playlists: return "歌单"
        case .recent: return "最近播放"
        case .favorites: return "收藏"
        case .unmatched: return "未匹配歌曲"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .artists: return "person.2"
        case .playlists: return "music.note.list"
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "heart"
        case .unmatched: return "questionmark.circle"
        }
    }
}

enum EmbyLibrarySection: String, CaseIterable, Identifiable, Sendable {
    case videos
    case music
    case recent
    case watchlist
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return "视频"
        case .music: return "音乐"
        case .recent: return "最近播放"
        case .watchlist: return "想看"
        case .favorites: return "收藏"
        }
    }

    var systemImage: String {
        switch self {
        case .videos: return "play.tv"
        case .music: return "music.note"
        case .recent: return "clock.arrow.circlepath"
        case .watchlist: return "bookmark"
        case .favorites: return "heart"
        }
    }
}

struct EmbyRenameRequest: Identifiable {
    let sourceID: String
    var name: String
    var id: String { sourceID }
}

enum SidebarDestination: Hashable, Identifiable, Sendable {
    case home
    case video(VideoLibrarySection)
    case music(MusicLibrarySection)
    case embySection(String, EmbyLibrarySection)
    case embyLibrary(String)
    case smartCollection(String)
    case manualCollection(String)
    case musicSmartPlaylist(String)
    case health
    case tasks
    case sources
    case settings

    var id: String {
        switch self {
        case .home: return "home"
        case .video(let section): return "video-\(section.rawValue)"
        case .music(let section): return "music-\(section.rawValue)"
        case .embySection(let sourceID, let section): return "emby-section-\(sourceID)__\(section.rawValue)"
        case .embyLibrary(let libraryID): return "emby-library-\(libraryID)"
        case .smartCollection(let collectionID): return "smart-collection-\(collectionID)"
        case .manualCollection(let collectionID): return "manual-collection-\(collectionID)"
        case .musicSmartPlaylist(let playlistID): return "music-smart-playlist-\(playlistID)"
        case .health: return "health"
        case .tasks: return "tasks"
        case .sources: return "sources"
        case .settings: return "settings"
        }
    }

    init?(storedID: String) {
        if storedID == "home" {
            self = .home
        } else if storedID == "sources" {
            self = .sources
        } else if storedID == "health" {
            self = .health
        } else if storedID == "tasks" {
            self = .tasks
        } else if storedID == "settings" {
            self = .settings
        } else if storedID.hasPrefix("video-") {
            let raw = String(storedID.dropFirst("video-".count))
            if raw == "recent" {
                self = .video(.watching)
                return
            }
            guard let section = VideoLibrarySection(rawValue: raw) else { return nil }
            self = .video(section)
        } else if storedID.hasPrefix("music-smart-playlist-") {
            let playlistID = String(storedID.dropFirst("music-smart-playlist-".count))
            guard !playlistID.isEmpty else { return nil }
            self = .musicSmartPlaylist(playlistID)
        } else if storedID.hasPrefix("music-") {
            let raw = String(storedID.dropFirst("music-".count))
            if raw == MusicLibrarySection.favorites.rawValue {
                self = .music(.playlists)
                return
            }
            if raw == MusicLibrarySection.unmatched.rawValue {
                self = .music(.songs)
                return
            }
            guard let section = MusicLibrarySection(rawValue: raw) else { return nil }
            self = .music(section)
        } else if storedID.hasPrefix("emby-") {
            let raw = String(storedID.dropFirst("emby-".count))
            if raw.hasPrefix("library-") {
                let libraryID = String(raw.dropFirst("library-".count))
                guard !libraryID.isEmpty else { return nil }
                self = .embyLibrary(libraryID)
                return
            }
            if raw.hasPrefix("section-") {
                let rest = String(raw.dropFirst("section-".count))
                let parts = rest.components(separatedBy: "__")
                guard parts.count == 2, !parts[0].isEmpty,
                      let section = EmbyLibrarySection(rawValue: parts[1]) else { return nil }
                self = .embySection(parts[0], section)
                return
            }
            return nil
        } else if storedID.hasPrefix("smart-collection-") {
            let collectionID = String(storedID.dropFirst("smart-collection-".count))
            guard !collectionID.isEmpty else { return nil }
            self = .smartCollection(collectionID)
        } else if storedID.hasPrefix("manual-collection-") {
            let collectionID = String(storedID.dropFirst("manual-collection-".count))
            guard !collectionID.isEmpty else { return nil }
            self = .manualCollection(collectionID)
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .home: return "首页"
        case .video(let section): return section.title
        case .music(let section): return section.title
        case .embySection(_, let section): return section.title
        case .embyLibrary: return "远程分类"
        case .smartCollection: return "智能集合"
        case .manualCollection: return "集合"
        case .musicSmartPlaylist: return "智能歌单"
        case .health: return "片库健康"
        case .tasks: return "任务中心"
        case .sources: return "媒体源"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .video(let section): return section.systemImage
        case .music(let section): return section.systemImage
        case .embySection(_, let section): return section.systemImage
        case .embyLibrary: return "rectangle.stack"
        case .smartCollection: return "sparkles.rectangle.stack"
        case .manualCollection: return "rectangle.stack"
        case .musicSmartPlaylist: return "music.note.list"
        case .health: return "stethoscope"
        case .tasks: return "checklist"
        case .sources: return "externaldrive"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: SidebarDestination? = .home
    @State private var isVideoExpanded = true
    @State private var isMusicExpanded = true
    /// 已折叠的 Emby 来源（默认全部展开；只记录被用户折叠的）。
    @State private var collapsedEmbySourceIDs: Set<String> = []
    @State private var embyRenameRequest: EmbyRenameRequest?
    @State private var musicPlayerExpanded = true
    // 沉浸式 chrome（隐藏标题/侧栏按钮、透明标题栏、内容延伸到标题栏下）只在全屏播放器
    // 已完全覆盖窗口时开启/关闭，使 chrome 切换引起的 navigationRoot 重排被覆盖层遮挡。
    @State private var musicImmersive = false
    @State private var musicController = MpvPlayerController()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var musicTransitionTask: Task<Void, Never>?
    @State private var musicTransitionSuppressesBackground = false
    @State private var musicTransitionShieldActive = false
    @State private var musicBackgroundRootSuspended = false
    @State private var hadActiveMusic = false
    @State private var musicMiniPlayerCollapsed = false
    @State private var musicWindowPalette = AlbumColorPalette.fallback
    @State private var musicWindowPaletteTask: Task<Void, Never>?
    @State private var mainLayoutTransitionActive = false
    @State private var mainLayoutTransitionResetTask: Task<Void, Never>?
    @State private var smartCollectionEditor: VideoSmartCollectionEditorRequest?
    @State private var manualCollectionEditor: VideoManualCollectionEditorRequest?
    @State private var musicSmartPlaylistEditor: MusicSmartPlaylistEditorRequest?
    @State private var showOnboarding = false
    @State private var didRunPostOnboardingStartupTasks = false
    @State private var postOnboardingStartupTask: Task<Void, Never>?
    @State private var themeSwitching = false
    @State private var themeSwitchTask: Task<Void, Never>?
    @Namespace private var musicPlayerNamespace
    @AppStorage("MediaLib.sidebar.selection") private var storedSelectionID = "home"
    @AppStorage("MediaLib.music.albumGlowPerformanceNoticeShown") private var albumGlowPerformanceNoticeShown = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if musicBackgroundRootSuspended {
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    navigationRoot
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        // 用主题高亮色作为全局 tint：开关、滑块、Picker、默认按钮、进度条、列表选中高亮等
                        // 系统控件都会跟随配色方案（音乐展开页是单独的 overlay，不在此分支内，不受影响）。
                        .tint(AppColors.selectedGlassTint)
                        .allowsHitTesting(!musicExpandedOverlayActive)
                        .environment(\.suppressPointerHoverDuringScroll, musicExpandedOverlayActive)
                        .environment(\.mainLayoutTransitionActive, mainLayoutTransitionActive)
                        .glassPerformanceMode(backgroundGlassPerformanceMode)
                        // 全屏音乐播放器已完全盖住窗口时，把背后的整库界面从树上卸掉，
                        // 释放列表、海报墙和筛选结果的视图资源；收起时重新挂回。
                        .id(musicBackgroundRootSuspended ? "music-root-suspended" : "music-root-active")
                }

                if let musicItem = musicPlayerBinding.wrappedValue {
                    MusicPlaybackHost(item: musicItem, controller: musicController)
                        .environmentObject(appState)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)

                    if !musicPlayerExpanded {
                        MusicMiniPlayerBar(
                            item: musicItem,
                            controller: musicController,
                            leadingInset: musicMiniPlayerLeadingInset,
                            transitionNamespace: musicPlayerNamespace,
                            isCollapsed: musicMiniPlayerCollapsed,
                            onRequestReveal: revealMusicMiniPlayer,
                            onRequestExpand: expandMusicPlayer,
                            onRequestClose: closeMusicPlayer
                        )
                        .environmentObject(appState)
                        .frame(width: musicMiniPlayerFrameWidth(for: geometry.size.width), alignment: .bottomLeading)
                        .padding(.leading, musicMiniPlayerCollapsed ? 0 : musicMiniPlayerLeadingInset + musicMiniPlayerOuterInset)
                        .padding(.trailing, musicMiniPlayerCollapsed ? musicMiniPlayerOuterInset : 0)
                        .padding(.bottom, 18)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: musicMiniPlayerCollapsed ? .bottomTrailing : .bottomLeading)
                        .transition(AppMotion.floatingBar)
                        .animation(AppMotion.musicPlayer, value: musicMiniPlayerCollapsed)
                        .zIndex(21)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .background {
            AppPageBackground(includeDirectionalLight: false)
        }
        .background {
            MainLayoutActivityMonitor { active in
                if active {
                    beginMainLayoutTransition()
                } else {
                    finishMainLayoutTransition(after: 160_000_000)
                }
            }
            .frame(width: 0, height: 0)
        }
        .background {
            if appState.activePlayerItem?.type == .music && !musicPlayerExpanded {
                MusicMiniPlayerCollapseScrollMonitor { direction in
                    handleMusicMiniPlayerScroll(direction)
                }
                .frame(width: 0, height: 0)
            }
        }
        // 全屏播放器作为忽略安全区的整窗覆盖层：尺寸恒为整窗（不随窗口 chrome safe area 改变），
        // 因此 chrome 切换不会让它跳动，也始终盖住标题栏区域（展开过程顶部不再露白、不再抽搐）。
        .overlay {
            ZStack {
                if musicTransitionShieldActive {
                    Color(nsColor: musicWindowPalette.backdropBaseNSColor(for: colorScheme))
                        .ignoresSafeArea()
                        .transition(.identity)
                        .zIndex(18)
                }

                if let musicItem = musicPlayerBinding.wrappedValue, musicPlayerExpanded {
                    MusicPlayerView(
                        item: musicItem,
                        controller: musicController,
                        transitionNamespace: musicPlayerNamespace,
                        onRequestMinimize: minimizeMusicPlayer
                    )
                    .environmentObject(appState)
                    .transition(AppMotion.musicPlayerExpansion)
                    .ignoresSafeArea()
                    .zIndex(20)
                }
            }
        }
        .overlay {
            if appState.sakuraEasterEggActive {
                SakuraFallView()
                    .allowsHitTesting(false)
                    .zIndex(60)
            }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { noticeGeometry in
                let leadingInset = floatingNoticeContentLeadingInset(for: noticeGeometry.size.width)
                let contentWidth = max(noticeGeometry.size.width - leadingInset, 0)
                FloatingNoticeStack(
                    availableWidth: contentWidth,
                    notices: appState.floatingNotices,
                    onDismiss: { appState.dismissFloatingNotice(id: $0) }
                )
                .frame(width: contentWidth, alignment: .top)
                .padding(.leading, leadingInset)
                .padding(.top, 14)
                .zIndex(90)
            }
            .allowsHitTesting(!appState.floatingNotices.isEmpty)
        }
        .animation(.easeOut(duration: 0.4), value: appState.sakuraEasterEggActive)
        .background {
            VideoPlayerWindowPresenter(item: videoPlayerBinding)
                .frame(width: 0, height: 0)
        }
        .sheet(item: $appState.quickPreviewItem) { item in
            QuickPreviewView(item: item)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingNetworkStreamPrompt) {
            NetworkStreamPromptSheet()
                .environmentObject(appState)
        }
        .sheet(item: $appState.availableUpdate) { update in
            AppUpdatePromptSheet(update: update)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingSponsorPrompt) {
            SponsorInviteSheet()
                .environmentObject(appState)
        }
        .sheet(item: $smartCollectionEditor) { request in
            VideoSmartCollectionSheet(
                request: request,
                onSave: { collection in
                    smartCollectionEditor = nil
                    Task { @MainActor in
                        await Task.yield()
                        if let saved = appState.saveVideoSmartCollection(collection) {
                            selection = .smartCollection(saved.id)
                        }
                    }
                },
                onCancel: {
                    smartCollectionEditor = nil
                }
            )
        }
        .sheet(item: $manualCollectionEditor) { request in
            VideoManualCollectionSheet(
                request: request,
                onSave: { collection in
                    manualCollectionEditor = nil
                    Task { @MainActor in
                        await Task.yield()
                        if let saved = appState.saveVideoManualCollection(collection) {
                            selection = .manualCollection(saved.id)
                        }
                    }
                },
                onCancel: {
                    manualCollectionEditor = nil
                }
            )
        }
        .sheet(item: $appState.videoManualCollectionCreationRequest) { request in
            VideoManualCollectionSheet(
                request: .create(),
                onSave: { draft in
                    appState.videoManualCollectionCreationRequest = nil
                    Task { @MainActor in
                        await Task.yield()
                        if let collection = appState.createVideoManualCollectionAndNotify(
                            name: draft.name,
                            itemIDs: request.itemIDs,
                            successTitle: "已创建集合并加入"
                        ) {
                            selection = .manualCollection(collection.id)
                        }
                    }
                },
                onCancel: {
                    appState.cancelVideoManualCollectionCreation(request)
                }
            )
        }
        .sheet(item: $appState.videoOfflineSubscriptionLimitRequest) { request in
            VideoOfflineSubscriptionLimitSheet(
                request: request,
                onSave: { limit in
                    appState.saveCustomVideoOfflineSubscriptionLimit(request, episodeLimit: limit)
                },
                onCancel: {
                    appState.videoOfflineSubscriptionLimitRequest = nil
                }
            )
        }
        .sheet(item: $embyRenameRequest) { request in
            EmbySourceRenameSheet(
                request: request,
                onSave: { newName in
                    if var source = appState.sources.first(where: { $0.id == request.sourceID }) {
                        source.name = newName
                        appState.updateSource(source)
                    }
                    embyRenameRequest = nil
                },
                onCancel: { embyRenameRequest = nil }
            )
        }
        .sheet(item: $musicSmartPlaylistEditor) { request in
            MusicSmartPlaylistSheet(
                request: request,
                onSave: { playlist in
                    musicSmartPlaylistEditor = nil
                    Task { @MainActor in
                        await Task.yield()
                        if let saved = appState.saveMusicSmartPlaylist(playlist) {
                            selection = .musicSmartPlaylist(saved.id)
                        }
                    }
                },
                onCancel: {
                    musicSmartPlaylistEditor = nil
                }
            )
        }
        // 已移除纯告知模态弹窗：所有 appState.alert 经其 didSet 统一只走浮窗通知，
        // 避免"检查更新已是最新版本"等场景同时弹窗 + 浮窗的双重打扰。需要用户操作的提示
        // 走各自专用 sheet（如 embyRestrictionNotice），不在此通用 alert 通道内。
        .sheet(item: $appState.embyRestrictionNotice) { notice in
            EmbyRestrictionSheet(notice: notice) {
                appState.embyRestrictionNotice = nil
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { goToSources in
                appState.completeOnboarding()
                showOnboarding = false
                runPostOnboardingStartupTasksIfNeeded()
                if goToSources {
                    selection = .sources
                }
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            if !appState.settings.hasCompletedOnboarding {
                showOnboarding = true
            } else {
                runPostOnboardingStartupTasksIfNeeded()
            }
        }
        .onChange(of: appState.onboardingReplayRequested) { requested in
            if requested {
                showOnboarding = true
                appState.onboardingReplayRequested = false
            }
        }
        .background {
            MainWindowToolbarVisibilityGuard(
                // R5-3：标题栏 chrome 在播放器一展开就隐藏（覆盖层此刻已盖住整窗），
                // 不再等到 musicImmersive 延迟置位——否则展开后到沉浸前的这段时间，
                // 顶部 AppKit 标题栏会露出一条白色横条。
                hiddenForMusicOverlay: musicChromeShouldBeHidden,
                hideSidebarToggleForMusicOverlay: musicChromeShouldBeHidden,
                shouldApplyInitialPlacement: !appState.settings.hasCompletedOnboarding
            )
            .frame(width: 0, height: 0)
        }
        .background {
            MusicExpansionWindowBackdropGuard(
                active: musicWindowBackdropShouldBeActive,
                color: musicWindowPalette.backdropBaseNSColor(for: colorScheme)
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            loadMusicWindowPalette()
        }
        .onChange(of: appState.activePlayerItem?.id) { _ in
            let activeMusic = appState.activePlayerItem?.type == .music
            loadMusicWindowPalette()
            if activeMusic {
                musicMiniPlayerCollapsed = false
                if !hadActiveMusic {
                    hadActiveMusic = true
                    presentMusicMiniPlayer()
                }
            } else {
                hadActiveMusic = false
                restoreSidebarAfterMusic()
            }
        }
        .onChange(of: appState.activePlayerItem?.posterPath) { _ in
            loadMusicWindowPalette()
        }
        .onChange(of: appState.playbackCommandRequest?.id) { _ in
            handlePlaybackCommand()
        }
        // 配色切换：极短遮罩让下层在同一轮状态刷新中换到新配色，避免逐控件滞后。
        .overlay {
            if themeSwitching {
                ZStack {
                    AppColors.pageBackground.opacity(0.98)
                    ProgressView()
                        .controlSize(.large)
                        .tint(AppColors.selectedGlassTint)
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(1000)
                .allowsHitTesting(true)
            }
        }
        .onChange(of: appState.themeRevision) { _ in
            themeSwitchTask?.cancel()
            withAnimation(.easeOut(duration: 0.06)) { themeSwitching = true }
            themeSwitchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.10)) { themeSwitching = false }
            }
        }
        .onChange(of: columnVisibility) { _ in
            markMainLayoutTransition()
        }
        .onDisappear {
            musicWindowPaletteTask?.cancel()
            themeSwitchTask?.cancel()
            mainLayoutTransitionResetTask?.cancel()
        }
    }

    private func markMainLayoutTransition(after nanoseconds: UInt64 = 520_000_000) {
        beginMainLayoutTransition()
        finishMainLayoutTransition(after: nanoseconds)
    }

    private func beginMainLayoutTransition() {
        mainLayoutTransitionResetTask?.cancel()
        mainLayoutTransitionResetTask = nil
        if !mainLayoutTransitionActive {
            mainLayoutTransitionActive = true
        }
    }

    private func finishMainLayoutTransition(after nanoseconds: UInt64) {
        mainLayoutTransitionResetTask?.cancel()
        mainLayoutTransitionResetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            mainLayoutTransitionActive = false
            mainLayoutTransitionResetTask = nil
        }
    }

    private var navigationRoot: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section(appState.localized("媒体库")) {
                    sidebarRow(.home)

                    sidebarGroupSpacer

                    DisclosureGroup(isExpanded: $isVideoExpanded) {
                        // 「正在观看」「未观看」「已观看」都不再作为左侧栏分类，
                        // 仅保留各分类页面内的同名子页面（筛选标签）。
                        let sections = appState.visibleVideoSections.filter {
                            $0 != .watching && $0 != .unwatched && $0 != .watched
                        }
                        if sections.isEmpty {
                            Label(appState.localized("暂无视频"), systemImage: "film")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sections) { section in
                                sidebarRow(.video(section))
                            }
                        }
                        ForEach(appState.videoSmartCollections) { collection in
                            smartCollectionSidebarRow(collection)
                        }
                        if !appState.videoManualCollections.isEmpty {
                            let previewItemsByCollectionID = appState.videoManualCollectionPreviewItemsByCollectionID(limit: 1)
                            ForEach(appState.videoManualCollections) { collection in
                                manualCollectionSidebarRow(collection, previewItems: previewItemsByCollectionID[collection.id] ?? [])
                            }
                        }
                        Button {
                            smartCollectionEditor = .create()
                        } label: {
                            HStack(spacing: 10) {
                                PlayfulSymbolIcon(systemImage: "plus", size: 22)
                                Text(appState.localized("新建智能集合"))
                                    // 与其它目录行字体保持一致。
                                    .font(.body)
                            }
                        }
                        .buttonStyle(SidebarInlineActionButtonStyle())
                        Button {
                            manualCollectionEditor = .create()
                        } label: {
                            HStack(spacing: 10) {
                                PlayfulSymbolIcon(systemImage: "rectangle.stack.badge.plus", size: 22)
                                Text(appState.localized("新建集合"))
                                    .font(.body)
                            }
                        }
                        .buttonStyle(SidebarInlineActionButtonStyle())
                    } label: {
                        Button {
                            withAnimation(AppMotion.sidebar) {
                                isVideoExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                PlayfulSymbolIcon(systemImage: "film", size: 22)
                                Text(appState.localized("视频"))
                                Spacer(minLength: 0)
                            }
                            .font(.callout.weight(.semibold))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    sidebarGroupSpacer

                    DisclosureGroup(isExpanded: $isMusicExpanded) {
                        ForEach(MusicLibrarySection.sidebarCases) { section in
                            sidebarRow(.music(section))
                        }
                        // 仅在有智能歌单时才显示分隔线 + 列表；空列表下不再多出一条分割线，
                        // 否则会让「音乐↔远程媒体库」的间距大于「视频↔音乐」，造成不统一。
                        if !appState.musicSmartPlaylists.isEmpty {
                            Divider()
                            ForEach(appState.musicSmartPlaylists) { playlist in
                                musicSmartPlaylistSidebarRow(playlist)
                            }
                        }
                    } label: {
                        Button {
                            withAnimation(AppMotion.sidebar) {
                                isMusicExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                PlayfulSymbolIcon(systemImage: "music.note", size: 22)
                                Text(appState.localized("音乐"))
                                Spacer(minLength: 0)
                            }
                            .font(.callout.weight(.semibold))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // 每个远程媒体库来源各自一个一级目录（可重命名），内含该源的分区与媒体库。
                    ForEach(appState.embySources) { source in
                        sidebarGroupSpacer
                        embySourceGroup(for: source)
                    }
                }

                Section(appState.localized("管理")) {
                    sidebarRow(.sources)
                    sidebarRow(.health)
                    sidebarRow(.tasks)
                    sidebarRow(.settings)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SidebarGlassBackground())
            .listStyle(.sidebar)
            .tint(AppColors.selectedGlassTint)
            .id(appState.themeRevision)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .onAppear {
                selection = SidebarDestination(storedID: storedSelectionID) ?? .home
            }
            .onChange(of: selection) { _ in
                storedSelectionID = selection?.id ?? "home"
                appState.selectedItem = nil
                appState.selectedItemReturnAnchorID = nil
            }
        } detail: {
            ZStack {
                if let startupError = appState.startupError {
                    StartupErrorView(message: startupError)
                } else if let selectedItem = appState.selectedItem {
                    let destination = selection ?? .home
                    DetailView(
                        item: selectedItem,
                        sourceTitle: title(for: destination),
                        sourceSystemImage: destination.systemImage
                    )
                } else {
                    detailView(for: selection ?? .home)
                }
            }
        }
    }

    private var musicMiniPlayerLeadingInset: CGFloat {
        musicMiniReservesSidebar ? 252 : 0
    }

    private var musicMiniPlayerOuterInset: CGFloat {
        24
    }

    private func musicMiniPlayerWidth(for windowWidth: CGFloat) -> CGFloat {
        let available = max(320, windowWidth - musicMiniPlayerLeadingInset - musicMiniPlayerOuterInset * 2)
        return available
    }

    private func musicMiniPlayerFrameWidth(for windowWidth: CGFloat) -> CGFloat {
        musicMiniPlayerWidth(for: windowWidth)
    }

    private var musicMiniReservesSidebar: Bool {
        appState.activePlayerItem?.type == .music &&
        !musicPlayerExpanded &&
        columnVisibility != .detailOnly
    }

    private var musicExpandedOverlayActive: Bool {
        appState.activePlayerItem?.type == .music && musicPlayerExpanded
    }

    private var musicWindowChromeHidden: Bool {
        appState.activePlayerItem?.type == .music && musicImmersive
    }

    private var musicChromeShouldBeHidden: Bool {
        appState.activePlayerItem?.type == .music && musicImmersive
    }

    private var musicWindowBackdropShouldBeActive: Bool {
        appState.activePlayerItem?.type == .music &&
        (musicTransitionShieldActive || musicPlayerExpanded || musicImmersive || musicTransitionSuppressesBackground)
    }

    private var backgroundGlassPerformanceMode: GlassPerformanceMode {
        if musicExpandedOverlayActive || musicTransitionSuppressesBackground || musicBackgroundRootSuspended {
            return .minimal
        }
        if appState.activePlayerItem?.type == .music {
            return .balanced
        }
        return .full
    }

    private func floatingNoticeContentLeadingInset(for width: CGFloat) -> CGFloat {
        guard !musicExpandedOverlayActive, width >= 900, columnVisibility != .detailOnly else {
            return 0
        }
        return 240
    }

    private func handleMusicMiniPlayerScroll(_ direction: MusicMiniPlayerScrollDirection) {
        guard appState.activePlayerItem?.type == .music, !musicPlayerExpanded else { return }
        if !musicMiniPlayerCollapsed {
            withAnimation(AppMotion.musicPlayer) {
                musicMiniPlayerCollapsed = true
            }
        }
    }

    private func revealMusicMiniPlayer() {
        guard musicMiniPlayerCollapsed else { return }
        withAnimation(AppMotion.musicPlayer) {
            musicMiniPlayerCollapsed = false
        }
    }

    private func runPostOnboardingStartupTasksIfNeeded() {
        guard appState.settings.hasCompletedOnboarding,
              !didRunPostOnboardingStartupTasks else { return }
        didRunPostOnboardingStartupTasks = true
        postOnboardingStartupTask?.cancel()
        postOnboardingStartupTask = Task { @MainActor in
            // 刚退出引导时先让首页落位，避免浮窗/弹窗抢在用户看清主界面前出现。
            do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
            appState.releaseDeferredFloatingNoticesIfNeeded()

            // 更新检查可能弹出更新日志，放在普通浮窗之后，减少首次进入首页的打扰。
            do { try await Task.sleep(nanoseconds: 2_800_000_000) } catch { return }
            appState.checkForUpdatesDailyIfNeeded()

            // 赞助邀请是更低优先级的提示，继续后移，避免和更新提示同一时间段出现。
            do { try await Task.sleep(nanoseconds: 7_000_000_000) } catch { return }
            appState.registerLaunchAndMaybeInvite()
        }
    }

    // 音乐展开/收起：全屏播放器是覆盖层，不改窗口大小、不挤压底层界面。
    // chrome 隐藏在覆盖层挂上后再执行，恢复则等覆盖层收起后执行，避免中间帧露出系统白底。
    private func expandMusicPlayer() {
        musicTransitionTask?.cancel()
        showAlbumGlowPerformanceNoticeIfNeeded()
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            musicBackgroundRootSuspended = false
            musicTransitionShieldActive = true
            musicTransitionSuppressesBackground = true
            musicMiniPlayerCollapsed = false
        }
        withAnimation(AppMotion.musicPlayer) {
            musicPlayerExpanded = true
        }
        musicTransitionTask = Task { @MainActor in
            await Task.yield()
            guard appState.activePlayerItem?.type == .music, musicPlayerExpanded else {
                finishInterruptedMusicTransition(expanded: false)
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                musicImmersive = true
            }
            // 等展开动画完全稳定后，再卸载背后的 NavigationSplitView。
            // 过早卸载会改变 SwiftUI/NSWindow 内容树的 safe-area 与 titlebar 组合，正是展开末段白条的高风险点。
            // 性能：musicPlayer 弹簧（response 0.40 / damping 0.90）约 0.55–0.7s 即视觉稳定，沉浸 chrome 已在
            // 上方 Task.yield 后立即置位；原 1.15s 让背后整库（含海报墙 NSImage 显存）与全屏播放器的
            // 两套离屏合成缓冲在 M 系列无风扇 GPU 上多并存约 0.35s，正是展开瞬间 WindowServer 内存冲高、
            // 系统掉帧的高峰窗口。收紧到 0.80s（仍在稳定点之后留 ~0.1–0.25s 安全余量，不触发白条），
            // 把双挂载峰值时长压掉约 30%，更早释放背后海报显存。
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            guard appState.activePlayerItem?.type == .music, musicPlayerExpanded, musicImmersive else {
                finishInterruptedMusicTransition(expanded: appState.activePlayerItem?.type == .music && musicPlayerExpanded)
                return
            }
            withTransaction(transaction) {
                musicBackgroundRootSuspended = true
                musicTransitionShieldActive = false
            }
            musicTransitionSuppressesBackground = false
        }
    }

    private func showAlbumGlowPerformanceNoticeIfNeeded() {
        guard !albumGlowPerformanceNoticeShown,
              appState.settings.musicAlbumCoverGlowEnabled else { return }
        albumGlowPerformanceNoticeShown = true
        appState.showFloatingNotice(
            title: "封面发光已开启",
            message: "这项效果会增加渲染开销；如果展开播放器时卡顿，可在设置中关闭封面发光。",
            kind: .tip,
            duration: 7.2
        )
    }

    private func presentMusicMiniPlayer() {
        musicTransitionTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            musicBackgroundRootSuspended = false
            musicPlayerExpanded = false
            musicImmersive = false
            musicMiniPlayerCollapsed = false
            musicTransitionShieldActive = false
        }
        musicTransitionSuppressesBackground = false
    }

    private func minimizeMusicPlayer() {
        musicTransitionTask?.cancel()
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            musicTransitionShieldActive = true
            musicTransitionSuppressesBackground = true
            musicMiniPlayerCollapsed = false
        }
        musicTransitionTask = Task { @MainActor in
            if musicBackgroundRootSuspended {
                var restoreTransaction = Transaction()
                restoreTransaction.disablesAnimations = true
                withTransaction(restoreTransaction) {
                    musicBackgroundRootSuspended = false
                }
                // 先给背后的列表/海报墙一小段预热时间，再让全屏播放器退场。
                do { try await Task.sleep(nanoseconds: 70_000_000) } catch { return }
            }
            guard appState.activePlayerItem?.type == .music, musicPlayerExpanded else {
                finishInterruptedMusicTransition(expanded: false)
                return
            }
            withAnimation(AppMotion.musicPlayer) {
                musicPlayerExpanded = false
            }
            // 配合更紧凑的 musicPlayer 弹簧，缩短收起时 overlay 与 chrome 恢复的重合窗口。
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            guard appState.activePlayerItem?.type == .music, !musicPlayerExpanded else {
                finishInterruptedMusicTransition(expanded: appState.activePlayerItem?.type == .music && musicPlayerExpanded)
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                musicImmersive = false
                musicTransitionShieldActive = false
            }
            musicTransitionSuppressesBackground = false
        }
    }

    private func finishInterruptedMusicTransition(expanded: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            musicBackgroundRootSuspended = expanded
            musicPlayerExpanded = expanded
            musicImmersive = expanded
            musicTransitionShieldActive = false
            musicMiniPlayerCollapsed = false
        }
        musicTransitionSuppressesBackground = false
    }

    private func restoreSidebarAfterMusic() {
        musicTransitionTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            musicBackgroundRootSuspended = false
            musicPlayerExpanded = false
            musicImmersive = false
            musicMiniPlayerCollapsed = false
            musicTransitionShieldActive = false
        }
        musicTransitionSuppressesBackground = false
    }

    private func closeMusicPlayer() {
        musicTransitionTask?.cancel()
        withAnimation(AppMotion.fast) {
            musicPlayerExpanded = false
            musicMiniPlayerCollapsed = false
            appState.activePlayerItem = nil
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            musicBackgroundRootSuspended = false
            musicImmersive = false
            musicTransitionShieldActive = false
        }
        musicTransitionSuppressesBackground = false
    }

    private func loadMusicWindowPalette() {
        musicWindowPaletteTask?.cancel()
        guard let item = appState.activePlayerItem, item.type == .music else {
            musicWindowPalette = .fallback
            return
        }
        let targetItemID = item.id
        let targetPath = item.posterPath
        musicWindowPaletteTask = Task {
            let palette = await AlbumPaletteCache.palette(for: targetPath)
            await MainActor.run {
                guard !Task.isCancelled,
                      appState.activePlayerItem?.id == targetItemID else { return }
                musicWindowPalette = palette
            }
        }
    }

    private func handlePlaybackCommand() {
        guard let request = appState.playbackCommandRequest else { return }
        if request.command == .toggleShuffle {
            appState.toggleMusicShuffle()
            return
        }
        if request.command == .cycleRepeat {
            appState.cycleMusicRepeatMode()
            return
        }
        guard let item = appState.activePlayerItem, item.type == .music else { return }
        switch request.command {
        case .play:
            if musicController.canControl, !musicController.isPlaying {
                musicController.togglePlay()
            }
        case .pause:
            if musicController.canControl, musicController.isPlaying {
                musicController.togglePlay()
            }
        case .togglePlay:
            if musicController.canControl {
                musicController.togglePlay()
            }
        case .previous:
            if shouldRestartCurrentMusicForAdjacentCommand {
                musicController.restartFromBeginning()
            } else {
                appState.playAdjacent(to: item, direction: -1)
            }
        case .next:
            if shouldRestartCurrentMusicForAdjacentCommand {
                musicController.restartFromBeginning()
            } else {
                appState.playAdjacent(to: item, direction: 1)
            }
        case .seekBackward:
            musicController.seek(by: -15)
        case .seekForward:
            musicController.seek(by: 15)
        case .toggleShuffle, .cycleRepeat:
            break
        }
    }

    private var shouldRestartCurrentMusicForAdjacentCommand: Bool {
        appState.musicRepeatMode == .repeatOne ||
            (appState.musicRepeatMode == .repeatAll && appState.musicQueue.count <= 1)
    }

    private func sidebarRow(_ destination: SidebarDestination) -> some View {
        let selected = selection == destination
        return HStack(spacing: 10) {
            PlayfulSymbolIcon(systemImage: destination.systemImage, size: 22, selected: selected)
                .id(appState.themeRevision)
            Text(appState.localized(title(for: destination)))
        }
            .tag(destination)
            .transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
    }

    /// 一级目录之间的小间距占位行（首页/视频/音乐/各远程来源之间统一留白）。
    /// 无 tag 故不可选中，隐藏分隔线，背景透明。
    private var sidebarGroupSpacer: some View {
        Color.clear
            .frame(height: 7)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .allowsHitTesting(false)
    }

    private func smartCollectionSidebarRow(_ collection: VideoSmartCollection) -> some View {
        HStack(spacing: 10) {
            PlayfulSymbolIcon(systemImage: "sparkles.rectangle.stack", size: 22)
            Text(collection.name)
        }
        .tag(SidebarDestination.smartCollection(collection.id))
        .contextMenu {
            Button {
                smartCollectionEditor = .edit(collection)
            } label: {
                Label(appState.localized("编辑"), systemImage: "pencil")
            }
            Button {
                appState.setVideoSmartCollectionHomeVisibility(collection, showOnHome: !collection.showOnHome)
            } label: {
                Label(appState.localized(collection.showOnHome ? "从首页移除" : "发布到首页"), systemImage: collection.showOnHome ? "house.slash" : "house")
            }
            Button(role: .destructive) {
                if selection == .smartCollection(collection.id) {
                    selection = .home
                }
                appState.deleteVideoSmartCollection(collection)
            } label: {
                Label(appState.localized("删除"), systemImage: "trash")
            }
        }
    }

    private func manualCollectionSidebarRow(_ collection: VideoManualCollection, previewItems: [MediaItem]) -> some View {
        let selected = selection == .manualCollection(collection.id)
        return HStack(spacing: 10) {
            VideoManualCollectionCoverView(
                items: previewItems,
                title: collection.name,
                size: 22,
                cornerRadius: 6,
                maxTiles: 1,
                selected: selected
            )
            Text(collection.name)
        }
        .tag(SidebarDestination.manualCollection(collection.id))
        .contextMenu {
            Button {
                manualCollectionEditor = .edit(collection)
            } label: {
                Label(appState.localized("重命名"), systemImage: "pencil")
            }
            Button {
                appState.setVideoManualCollectionHomeVisibility(collection, showOnHome: !collection.showOnHome)
            } label: {
                Label(appState.localized(collection.showOnHome ? "从首页移除" : "发布到首页"), systemImage: collection.showOnHome ? "house.slash" : "house")
            }
            Button(role: .destructive) {
                if selection == .manualCollection(collection.id) {
                    selection = .home
                }
                appState.deleteVideoManualCollection(collection)
            } label: {
                Label(appState.localized("删除"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func embySourceGroup(for source: MediaSource) -> some View {
        let libraries = appState.embyLibraries.filter { $0.sourceID == source.id }
        DisclosureGroup(isExpanded: embyExpansionBinding(source.id)) {
            ForEach(EmbyLibrarySection.allCases) { section in
                if appState.hasEmbyItems(for: section, sourceID: source.id) {
                    sidebarRow(.embySection(source.id, section))
                }
            }
            // 同一来源内：视频/收藏与各媒体库目录之间不再插入分隔线与额外间距，保持紧凑一致。
            ForEach(libraries) { library in
                sidebarRow(.embyLibrary(library.id))
            }
        } label: {
            Button {
                let binding = embyExpansionBinding(source.id)
                withAnimation(AppMotion.sidebar) {
                    binding.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    PlayfulSymbolIcon(systemImage: "server.rack", size: 22)
                    Text(source.name)
                    Spacer(minLength: 0)
                }
                .font(.callout.weight(.semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    embyRenameRequest = EmbyRenameRequest(sourceID: source.id, name: source.name)
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
            }
        }
    }

    private func embyExpansionBinding(_ sourceID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedEmbySourceIDs.contains(sourceID) },
            set: { expanded in
                if expanded {
                    collapsedEmbySourceIDs.remove(sourceID)
                } else {
                    collapsedEmbySourceIDs.insert(sourceID)
                }
            }
        )
    }

    private func musicSmartPlaylistSidebarRow(_ playlist: MusicSmartPlaylist) -> some View {
        HStack(spacing: 10) {
            PlayfulSymbolIcon(systemImage: "music.note.list", size: 22)
            Text(playlist.name)
        }
        .tag(SidebarDestination.musicSmartPlaylist(playlist.id))
        .contextMenu {
            Button {
                musicSmartPlaylistEditor = .edit(playlist)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                if selection == .musicSmartPlaylist(playlist.id) {
                    selection = .home
                }
                appState.deleteMusicSmartPlaylist(playlist)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func title(for destination: SidebarDestination) -> String {
        if destination == .video(.privacy) {
            return appState.settings.privacyVaultName
        }
        if case .embyLibrary(let libraryID) = destination {
            return appState.embyLibraryTitle(libraryID)
        }
        if case .smartCollection(let collectionID) = destination {
            return appState.videoSmartCollection(id: collectionID)?.name ?? "智能集合"
        }
        if case .manualCollection(let collectionID) = destination {
            return appState.videoManualCollection(id: collectionID)?.name ?? "集合"
        }
        if case .musicSmartPlaylist(let playlistID) = destination {
            return appState.musicSmartPlaylist(id: playlistID)?.name ?? "智能歌单"
        }
        return destination.title
    }

    private var musicPlayerBinding: Binding<MediaItem?> {
        Binding {
            appState.activePlayerItem?.type == .music ? appState.activePlayerItem : nil
        } set: { newValue in
            appState.activePlayerItem = newValue
        }
    }

    private var videoPlayerBinding: Binding<MediaItem?> {
        Binding {
            guard let item = appState.activePlayerItem, item.type != .music else { return nil }
            return item
        } set: { newValue in
            appState.activePlayerItem = newValue
        }
    }

    @ViewBuilder
    private func detailView(for destination: SidebarDestination) -> some View {
        switch destination {
        case .home:
            HomeView(
                onOpenHealthCenter: {
                    selection = .health
                },
                onOpenSources: {
                    selection = .sources
                }
            )
        case .video(.privacy):
            if appState.canDisplayPrivateItems {
                LibraryView(destination: destination)
            } else {
                PrivacyLockView()
            }
        case .video:
            LibraryView(destination: destination)
        case .music(let section):
            MusicLibraryView(section: section) {
                musicSmartPlaylistEditor = .create()
            }
        case .musicSmartPlaylist(let playlistID):
            if let playlist = appState.musicSmartPlaylist(id: playlistID) {
                MusicSmartPlaylistDetailView(playlist: playlist) {
                    musicSmartPlaylistEditor = .edit(playlist)
                }
            } else {
                EmptyStateView(title: "智能歌单不存在", systemImage: "music.note.list", message: "该智能歌单可能已被删除。")
            }
        case .embySection, .embyLibrary, .smartCollection, .manualCollection:
            LibraryView(destination: destination)
        case .health:
            LibraryHealthCenterView()
        case .tasks:
            BackgroundTaskCenterView()
        case .sources:
            SourcesView()
        case .settings:
            SettingsView()
        }
    }
}

private struct SidebarInlineActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 文字强度与其它目录行一致（满色），仅按下时变暗作为反馈。
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.55 : 1.0))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : AppMotion.fast, value: configuration.isPressed)
    }
}

struct StartupErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("MediaLIB 启动失败")
                .font(.title.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }
}

private enum MusicMiniPlayerScrollDirection {
    case down
    case up
}

private struct MainLayoutActivityMonitor: NSViewRepresentable {
    let onActivityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onActivityChanged = onActivityChanged
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onActivityChanged = onActivityChanged
        nsView.refreshObservation()
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class MonitorView: NSView {
        var onActivityChanged: ((Bool) -> Void)?
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshObservation()
        }

        func refreshObservation() {
            guard observedWindow !== window else { return }
            stopObserving()
            guard let window else { return }
            observedWindow = window
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSWindow.willStartLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onActivityChanged?(true)
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onActivityChanged?(false)
                }
            )
        }

        func stopObserving() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            observedWindow = nil
        }

        deinit {
            stopObserving()
        }
    }
}

private struct MusicMiniPlayerCollapseScrollMonitor: NSViewRepresentable {
    let onScroll: (MusicMiniPlayerScrollDirection) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onScroll: ((MusicMiniPlayerScrollDirection) -> Void)?
        private var monitor: Any?
        private var lastFire = Date.distantPast

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window,
                      event.window === window,
                      abs(event.scrollingDeltaY) > 0.15 else {
                    return event
                }
                let now = Date()
                guard now.timeIntervalSince(lastFire) > 0.08 else { return event }
                lastFire = now
                let delta = event.scrollingDeltaY
                let scrollsDown = event.isDirectionInvertedFromDevice ? delta > 0 : delta < 0
                onScroll?(scrollsDown ? .down : .up)
                return event
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

private struct MusicExpansionWindowBackdropGuard: NSViewRepresentable {
    let active: Bool
    let color: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(active: active, color: color, hostView: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var windowState: WindowState?
        private var layerStates: [ObjectIdentifier: LayerBackedViewState] = [:]
        private var lastAppliedSignature: String?

        func update(active: Bool, color: NSColor, hostView: NSView) {
            guard let nextWindow = hostView.window else {
                if active {
                    DispatchQueue.main.async { [weak self, weak hostView] in
                        guard let hostView else { return }
                        self?.update(active: active, color: color, hostView: hostView)
                    }
                } else {
                    restore()
                }
                return
            }

            if !active {
                restore()
                return
            }

            if window !== nextWindow {
                restore()
                window = nextWindow
            }

            let signature = Self.signature(active: active, color: color, window: nextWindow)
            if signature == lastAppliedSignature {
                return
            }
            lastAppliedSignature = signature

            if windowState == nil {
                windowState = WindowState(window: nextWindow)
            }

            nextWindow.isOpaque = false
            nextWindow.backgroundColor = color
            nextWindow.titleVisibility = .hidden
            nextWindow.titlebarAppearsTransparent = true
            if #available(macOS 11.0, *) {
                nextWindow.titlebarSeparatorStyle = .none
            }

            // contentView 及其 superview 仍铺不透明取色底——这是“展开/切歌时露白条”的安全网。
            applyLayerBackground(color, to: nextWindow.contentView)
            applyLayerBackground(color, to: nextWindow.contentView?.superview)
            // 标题栏容器改为透明：本 guard 仅在展开/过渡态生效，此时 SwiftUI 覆盖层（含整窗取色+多彩渐变 backdrop，
            // ignoresSafeArea）已经盖住标题栏区域。原本给标题栏铺“扁平基色”会比下方带多彩渐变的 backdrop 更浅，
            // 切歌后表现为顶部一条更浅的“未沉浸”色带。改为透明后，标题栏直接透出真实 backdrop，与正文同色、真正沉浸；
            // 露白条仍由上面的 contentView 不透明底兜底。
            applyLayerBackground(.clear, to: nextWindow.standardWindowButton(.closeButton)?.superview?.superview)
        }

        func restore() {
            if let windowState, let window = windowState.window {
                window.isOpaque = windowState.isOpaque
                window.backgroundColor = windowState.backgroundColor
                window.titleVisibility = windowState.titleVisibility
                window.titlebarAppearsTransparent = windowState.titlebarAppearsTransparent
                if #available(macOS 11.0, *),
                   let separatorStyle = windowState.titlebarSeparatorStyle as? NSTitlebarSeparatorStyle {
                    window.titlebarSeparatorStyle = separatorStyle
                }
            }

            for state in layerStates.values {
                guard let view = state.view else { continue }
                view.wantsLayer = state.wantsLayer
                view.layer?.backgroundColor = state.backgroundColor
            }

            window = nil
            windowState = nil
            layerStates.removeAll()
            lastAppliedSignature = nil
        }

        private func applyLayerBackground(_ color: NSColor, to view: NSView?) {
            guard let view else { return }
            let id = ObjectIdentifier(view)
            if layerStates[id] == nil {
                layerStates[id] = LayerBackedViewState(view: view)
            }
            view.wantsLayer = true
            view.layer?.backgroundColor = color.cgColor
        }

        private static func signature(active: Bool, color: NSColor, window: NSWindow) -> String {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return [
                active ? "1" : "0",
                String(ObjectIdentifier(window).hashValue),
                String(format: "%.4f", Double(rgb.redComponent)),
                String(format: "%.4f", Double(rgb.greenComponent)),
                String(format: "%.4f", Double(rgb.blueComponent)),
                String(format: "%.4f", Double(rgb.alphaComponent))
            ].joined(separator: ":")
        }

        private struct WindowState {
            weak var window: NSWindow?
            let isOpaque: Bool
            let backgroundColor: NSColor
            let titleVisibility: NSWindow.TitleVisibility
            let titlebarAppearsTransparent: Bool
            let titlebarSeparatorStyle: Any?

            init(window: NSWindow) {
                self.window = window
                isOpaque = window.isOpaque
                backgroundColor = window.backgroundColor
                titleVisibility = window.titleVisibility
                titlebarAppearsTransparent = window.titlebarAppearsTransparent
                if #available(macOS 11.0, *) {
                    titlebarSeparatorStyle = window.titlebarSeparatorStyle
                } else {
                    titlebarSeparatorStyle = nil
                }
            }
        }

        private struct LayerBackedViewState {
            weak var view: NSView?
            let wantsLayer: Bool
            let backgroundColor: CGColor?

            init(view: NSView) {
                self.view = view
                wantsLayer = view.wantsLayer
                backgroundColor = view.layer?.backgroundColor
            }
        }
    }
}

private struct MainWindowToolbarVisibilityGuard: NSViewRepresentable {
    let hiddenForMusicOverlay: Bool
    let hideSidebarToggleForMusicOverlay: Bool
    let shouldApplyInitialPlacement: Bool
    private static let minimumContentSize = NSSize(width: 1088, height: 720)
    private static let initialContentSize = NSSize(width: 1088, height: 840)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hiddenForMusicOverlay = hiddenForMusicOverlay
        context.coordinator.hideSidebarToggleForMusicOverlay = hideSidebarToggleForMusicOverlay
        context.coordinator.shouldApplyInitialPlacement = shouldApplyInitialPlacement
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hiddenForMusicOverlay = hiddenForMusicOverlay
        context.coordinator.hideSidebarToggleForMusicOverlay = hideSidebarToggleForMusicOverlay
        context.coordinator.shouldApplyInitialPlacement = shouldApplyInitialPlacement
        context.coordinator.attach(to: nsView)
        context.coordinator.refreshTransientChrome()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        var hiddenForMusicOverlay = false
        var hideSidebarToggleForMusicOverlay = false
        var shouldApplyInitialPlacement = false
        private weak var window: NSWindow?
        private var originalTitleVisibility: NSWindow.TitleVisibility?
        private var originalTitlebarAppearsTransparent: Bool?
        private var originalTitle: String?
        private var originalIsOpaque: Bool?
        private var originalBackgroundColor: NSColor?
        private var originalIsMovableByWindowBackground: Bool?
        private var originalContentMinSize: NSSize?
        private var originalMinSize: NSSize?
        private var resizeObserver: NSObjectProtocol?
        private var didEnableFullSizeContent = false
        @available(macOS 11.0, *)
        private var originalTitlebarSeparatorStyle: NSTitlebarSeparatorStyle? {
            get { storedTitlebarSeparatorStyle as? NSTitlebarSeparatorStyle }
            set { storedTitlebarSeparatorStyle = newValue }
        }
        private var storedTitlebarSeparatorStyle: Any?
        private var lastAppliedHiddenState: Bool?
        private var lastAppliedSidebarToggleState: Bool?
        private var didApplyInitialPlacement = false
        private var titlebarChromeOriginalAlpha: [ObjectIdentifier: (view: NSView, alpha: CGFloat)] = [:]
        private var titlebarBackgroundOriginalState: [ObjectIdentifier: TitlebarBackgroundState] = [:]

        func attach(to view: NSView) {
            guard let nextWindow = view.window else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let view else { return }
                    self?.attach(to: view)
                }
                return
            }

            if window !== nextWindow {
                restore()
                window = nextWindow
                originalTitleVisibility = nextWindow.titleVisibility
                originalTitlebarAppearsTransparent = nextWindow.titlebarAppearsTransparent
                originalTitle = nextWindow.title
                originalIsOpaque = nextWindow.isOpaque
                originalBackgroundColor = nextWindow.backgroundColor
                originalIsMovableByWindowBackground = nextWindow.isMovableByWindowBackground
                originalContentMinSize = nextWindow.contentMinSize
                originalMinSize = nextWindow.minSize
                if #available(macOS 11.0, *) {
                    originalTitlebarSeparatorStyle = nextWindow.titlebarSeparatorStyle
                }
                installResizeClamp(for: nextWindow)
                // 关键修复：fullSizeContentView 一次性常驻开启，之后再也不切换 styleMask。
                // 这样音乐展开/收起只切换"标题栏透明度 + 侧栏按钮可见性"，不会触发窗口 frame 重算，
                // 底层界面也不会因 styleMask 反复切换而抽搐（覆盖层只是盖在上面，不挤压任何东西）。
                if !nextWindow.styleMask.contains(.fullSizeContentView) {
                    nextWindow.styleMask.insert(.fullSizeContentView)
                    didEnableFullSizeContent = true
                }
                // #1 主窗口固定最小内容尺寸：侧栏最小 220 + 主内容安全宽度约 848，取 1088 留出余量；
                // 高度按详情页最小高 620 + 工具栏/页边距取 720。低于此尺寸时各组件（侧栏/海报墙/详情 hero）
                // 会发生错位或挤压，因此设为硬下限。fullSizeContentView 已常驻、styleMask 不再切换，
                // 设固定下限不会再触发以往"反复展开收起撑大窗口"的问题。
                applyMinimumWindowSize(to: nextWindow)
                applyInitialWindowPlacementIfNeeded(to: nextWindow)
                lastAppliedHiddenState = nil
                lastAppliedSidebarToggleState = nil
            }
            applyInitialWindowPlacementIfNeeded(to: nextWindow)
            applyIfNeeded()
        }

        func restore() {
            guard let window else { return }
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
            window.isOpaque = originalIsOpaque ?? true
            window.backgroundColor = originalBackgroundColor ?? NSColor.windowBackgroundColor
            window.title = originalTitle ?? "MediaLIB"
            window.titleVisibility = originalTitleVisibility ?? .visible
            window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent ?? false
            window.isMovableByWindowBackground = originalIsMovableByWindowBackground ?? false
            if let originalContentMinSize {
                window.contentMinSize = originalContentMinSize
            }
            if let originalMinSize {
                window.minSize = originalMinSize
            }
            if #available(macOS 11.0, *), let originalTitlebarSeparatorStyle {
                window.titlebarSeparatorStyle = originalTitlebarSeparatorStyle
            }
            if didEnableFullSizeContent {
                window.styleMask.remove(.fullSizeContentView)
            }
            restoreTitlebarBackground()
            restoreTitlebarChrome()
            unhideTrafficLights(in: window)
            setSidebarToggleHidden(false, in: window)
            self.window = nil
            originalTitleVisibility = nil
            originalTitlebarAppearsTransparent = nil
            originalTitle = nil
            originalIsOpaque = nil
            originalBackgroundColor = nil
            originalIsMovableByWindowBackground = nil
            originalContentMinSize = nil
            originalMinSize = nil
            didEnableFullSizeContent = false
            if #available(macOS 11.0, *) {
                originalTitlebarSeparatorStyle = nil
            }
            lastAppliedHiddenState = nil
            lastAppliedSidebarToggleState = nil
            didApplyInitialPlacement = false
            titlebarChromeOriginalAlpha.removeAll()
            titlebarBackgroundOriginalState.removeAll()
        }

        private func installResizeClamp(for window: NSWindow) {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.applyMinimumWindowSize(to: window)
            }
        }

        private func applyMinimumWindowSize(to window: NSWindow) {
            let firmMinSize = MainWindowToolbarVisibilityGuard.minimumContentSize
            window.contentMinSize = firmMinSize
            window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: firmMinSize)).size
            clampWindowFrameIfNeeded(window)
        }

        private func clampWindowFrameIfNeeded(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            let firmMinSize = MainWindowToolbarVisibilityGuard.minimumContentSize
            let currentContent = window.contentRect(forFrameRect: window.frame).size
            guard currentContent.width < firmMinSize.width || currentContent.height < firmMinSize.height else { return }

            let targetContent = NSSize(
                width: max(currentContent.width, firmMinSize.width),
                height: max(currentContent.height, firmMinSize.height)
            )
            var frameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContent))
            frameRect.origin.x = window.frame.origin.x
            frameRect.origin.y = window.frame.maxY - frameRect.height
            window.setFrame(frameRect, display: true)
        }

        private func applyInitialWindowPlacementIfNeeded(to window: NSWindow) {
            guard shouldApplyInitialPlacement,
                  !didApplyInitialPlacement,
                  !window.styleMask.contains(.fullScreen) else { return }
            didApplyInitialPlacement = true

            let screen = window.screen ?? NSScreen.main
            guard let visibleFrame = screen?.visibleFrame else {
                window.center()
                return
            }

            let currentContent = window.contentRect(forFrameRect: window.frame).size
            let maxContent = NSSize(
                width: max(360, visibleFrame.width - 56),
                height: max(320, visibleFrame.height - 72)
            )
            let targetContent = NSSize(
                width: min(max(currentContent.width, MainWindowToolbarVisibilityGuard.initialContentSize.width), maxContent.width),
                height: min(max(currentContent.height, MainWindowToolbarVisibilityGuard.initialContentSize.height), maxContent.height)
            )
            var frameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContent))
            frameRect.origin = NSPoint(
                x: visibleFrame.midX - frameRect.width / 2,
                y: visibleFrame.midY - frameRect.height / 2
            )
            window.setFrame(frameRect, display: true, animate: false)
        }

        private func applyIfNeeded() {
            guard lastAppliedHiddenState != hiddenForMusicOverlay ||
                    lastAppliedSidebarToggleState != hideSidebarToggleForMusicOverlay else { return }
            lastAppliedHiddenState = hiddenForMusicOverlay
            lastAppliedSidebarToggleState = hideSidebarToggleForMusicOverlay
            apply()
            // 单次异步重试，确保窗口就绪时也能套用，但不再有多次 setFrame 的抖动循环。
            DispatchQueue.main.async { [weak self] in
                self?.apply()
            }
        }

        func refreshTransientChrome() {
            guard hiddenForMusicOverlay || hideSidebarToggleForMusicOverlay,
                  let window else { return }
            if hiddenForMusicOverlay {
                window.title = ""
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            }
            setTitlebarChromeHidden(hiddenForMusicOverlay, in: window)
            setSidebarToggleHidden(hideSidebarToggleForMusicOverlay, in: window)
        }

        private func apply() {
            guard let window else { return }
            // 安全网：在改 chrome 前后同步快照/还原窗口 frame，杜绝任何"撑大窗口"。单次同步 setFrame，
            // 不做以往的多次延迟还原（那会造成抖动）。
            let savedFrame: NSRect? = window.styleMask.contains(.fullScreen) ? nil : window.frame
            // AppKit 的标题文本有时不跟随标题栏容器 alpha，同步清空可以避免顶部标题常驻。
            window.title = ""
            window.isOpaque = false
            window.backgroundColor = .clear
            if hiddenForMusicOverlay {
                // 音乐展开页需要沉浸到标题栏下方，但不能切 NSToolbar.isVisible：
                // SwiftUI NavigationSplitView 的统一工具栏会在 safe area 更新时触发约束断言闪退。
                // 保持 toolbar 结构稳定，只隐藏标题与侧栏按钮，并让播放器覆盖层接管顶部视觉。
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = false
                if #available(macOS 11.0, *) {
                    window.titlebarSeparatorStyle = .none
                }
            } else {
                // 主窗口常驻透明 titlebar 背景：如果普通态保留系统白底，展开播放器时那一层会先闪出来，
                // 再被后续 AppKit chrome 清理动作擦掉。让普通态也没有白底，展开就不再需要抢救。
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = originalIsMovableByWindowBackground ?? false
                if #available(macOS 11.0, *) {
                    window.titlebarSeparatorStyle = .none
                }
            }
            unhideTrafficLights(in: window)
            setTitlebarChromeHidden(hiddenForMusicOverlay, in: window)
            // 音乐展开时隐藏工具栏里的侧栏切换按钮（隐藏其视图不改变 frame，不会撑大窗口）。
            setSidebarToggleHidden(hideSidebarToggleForMusicOverlay, in: window)
            // 同步还原 frame：若上面任何属性意外触发了窗口尺寸变化，立即还原（单次、无延迟、无抖动）。
            if let savedFrame, !window.styleMask.contains(.fullScreen), window.frame != savedFrame {
                window.setFrame(savedFrame, display: false)
            }
        }

        /// 隐藏/显示工具栏中的侧栏切换按钮视图（不动 toolbar.isVisible，因此不触发窗口 frame 重算）。
        private func setSidebarToggleHidden(_ hidden: Bool, in window: NSWindow) {
            for item in window.toolbar?.items ?? [] {
                let id = item.itemIdentifier.rawValue.lowercased()
                let labelHints = [item.label, item.paletteLabel, item.toolTip].compactMap { $0 }.joined(separator: " ").lowercased()
                if id.contains("sidebar") || id.contains("toggle") || labelHints.contains("sidebar") || labelHints.contains("边栏") || labelHints.contains("側邊欄") {
                    item.view?.isHidden = hidden
                }
            }
            if let titlebarRoot = window.standardWindowButton(.closeButton)?.superview?.superview {
                setSidebarToggleButtonsHidden(hidden, in: titlebarRoot, window: window)
            }
            if let contentRoot = window.contentView?.superview {
                setSidebarToggleButtonsHidden(hidden, in: contentRoot, window: window)
            }
            unhideTrafficLights(in: window)
        }

        private func setTitlebarChromeHidden(_ hidden: Bool, in window: NSWindow) {
            guard let titlebarRoot = window.standardWindowButton(.closeButton)?.superview?.superview else { return }
            // titlebar/toolbar 背景常驻透明，白条不再作为普通态底色存在；展开时只额外隐藏 chrome 内容。
            clearTitlebarBackground(in: titlebarRoot, window: window)
            if let contentFrameRoot = window.contentView?.superview {
                clearTitlebarBackground(in: contentFrameRoot, window: window)
            }

            guard hidden else {
                restoreTitlebarChrome()
                unhideTrafficLights(in: window)
                return
            }
            fadeTitlebarChrome(in: titlebarRoot, window: window)
            unhideTrafficLights(in: window)
        }

        private func fadeTitlebarChrome(in view: NSView, window: NSWindow) {
            if containsTrafficLight(in: view, window: window) {
                for subview in view.subviews {
                    fadeTitlebarChrome(in: subview, window: window)
                }
                return
            }

            if shouldFadeTitlebarChromeView(view) {
                let id = ObjectIdentifier(view)
                if titlebarChromeOriginalAlpha[id] == nil {
                    titlebarChromeOriginalAlpha[id] = (view, view.alphaValue)
                }
                view.alphaValue = 0
                return
            }

            for subview in view.subviews {
                fadeTitlebarChrome(in: subview, window: window)
            }
        }

        private func restoreTitlebarChrome() {
            for state in titlebarChromeOriginalAlpha.values {
                state.view.alphaValue = state.alpha
            }
            titlebarChromeOriginalAlpha.removeAll()
        }

        private func clearTitlebarBackground(in view: NSView, window: NSWindow) {
            if shouldClearTitlebarBackgroundView(view, window: window) {
                let id = ObjectIdentifier(view)
                if titlebarBackgroundOriginalState[id] == nil {
                    titlebarBackgroundOriginalState[id] = TitlebarBackgroundState(view: view)
                }
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
                if let visualEffectView = view as? NSVisualEffectView {
                    visualEffectView.isEmphasized = false
                    visualEffectView.blendingMode = .withinWindow
                }
            }

            for subview in view.subviews {
                clearTitlebarBackground(in: subview, window: window)
            }
        }

        private func restoreTitlebarBackground() {
            for state in titlebarBackgroundOriginalState.values {
                guard let view = state.view else { continue }
                if let visualEffectView = view as? NSVisualEffectView,
                   let visualEffectState = state.visualEffectState {
                    visualEffectView.material = visualEffectState.material
                    visualEffectView.blendingMode = visualEffectState.blendingMode
                    visualEffectView.state = visualEffectState.state
                    visualEffectView.isEmphasized = visualEffectState.isEmphasized
                }
                view.wantsLayer = state.wantsLayer
                view.layer?.backgroundColor = state.backgroundColor
            }
            titlebarBackgroundOriginalState.removeAll()
        }

        private func containsTrafficLight(in view: NSView, window: NSWindow) -> Bool {
            [window.standardWindowButton(.closeButton),
             window.standardWindowButton(.miniaturizeButton),
             window.standardWindowButton(.zoomButton)]
                .compactMap { $0 }
                .contains { button in
                    button === view || viewContainsAncestor(view, of: button)
                }
        }

        private func viewContainsAncestor(_ ancestor: NSView, of descendant: NSView) -> Bool {
            var current: NSView? = descendant
            while let view = current {
                if view === ancestor { return true }
                current = view.superview
            }
            return false
        }

        private func shouldFadeTitlebarChromeView(_ view: NSView) -> Bool {
            if view is NSButton { return false }
            let className = NSStringFromClass(type(of: view)).lowercased()
            return className.contains("toolbar") ||
                className.contains("titlebar") ||
                className.contains("visualeffect") ||
                className.contains("separator") ||
                className.contains("decoration") ||
                className.contains("background") ||
                className.contains("text") ||
                className.contains("label") ||
                className.contains("field")
        }

        private func shouldClearTitlebarBackgroundView(_ view: NSView, window: NSWindow) -> Bool {
            if view is NSButton { return false }
            let className = NSStringFromClass(type(of: view)).lowercased()
            if containsTrafficLight(in: view, window: window) {
                return className.contains("titlebar") ||
                    className.contains("toolbar") ||
                    className.contains("visualeffect") ||
                    className.contains("themeframe")
            }
            return className.contains("titlebar") ||
                className.contains("toolbar") ||
                className.contains("visualeffect") ||
                className.contains("separator") ||
                className.contains("decoration") ||
                className.contains("background")
        }

        private func setSidebarToggleButtonsHidden(_ hidden: Bool, in view: NSView, window: NSWindow) {
            if let button = view as? NSButton,
               !isTrafficLight(button, in: window),
               looksLikeSidebarToggle(button) {
                button.isHidden = hidden
            }
            for subview in view.subviews {
                setSidebarToggleButtonsHidden(hidden, in: subview, window: window)
            }
        }

        private func isTrafficLight(_ button: NSButton, in window: NSWindow) -> Bool {
            button === window.standardWindowButton(.closeButton) ||
            button === window.standardWindowButton(.miniaturizeButton) ||
            button === window.standardWindowButton(.zoomButton)
        }

        private func looksLikeSidebarToggle(_ button: NSButton) -> Bool {
            let action = button.action.map { NSStringFromSelector($0) }
            let hints = [
                button.identifier?.rawValue,
                button.toolTip,
                button.accessibilityLabel(),
                action,
                String(describing: button.cell)
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

            return hints.contains("sidebar") ||
                hints.contains("side bar") ||
                hints.contains("togglesidebar") ||
                hints.contains("边栏") ||
                hints.contains("側邊欄")
        }

        private func unhideTrafficLights(in window: NSWindow) {
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.standardWindowButton(.closeButton)?.superview?.isHidden = false
        }

        private struct TitlebarBackgroundState {
            weak var view: NSView?
            let wantsLayer: Bool
            let backgroundColor: CGColor?
            let visualEffectState: TitlebarVisualEffectState?

            init(view: NSView) {
                self.view = view
                wantsLayer = view.wantsLayer
                backgroundColor = view.layer?.backgroundColor
                if let visualEffectView = view as? NSVisualEffectView {
                    visualEffectState = TitlebarVisualEffectState(
                        material: visualEffectView.material,
                        blendingMode: visualEffectView.blendingMode,
                        state: visualEffectView.state,
                        isEmphasized: visualEffectView.isEmphasized
                    )
                } else {
                    visualEffectState = nil
                }
            }
        }

        private struct TitlebarVisualEffectState {
            let material: NSVisualEffectView.Material
            let blendingMode: NSVisualEffectView.BlendingMode
            let state: NSVisualEffectView.State
            let isEmphasized: Bool
        }
    }
}

struct EmbySourceRenameSheet: View {
    let request: EmbyRenameRequest
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(request: EmbyRenameRequest, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: request.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "重命名远程来源",
                subtitle: "新名称会同步显示在侧边栏和媒体源列表中。",
                systemImage: "pencil"
            )

            VStack(spacing: 14) {
                SettingsRow(title: "名称", systemImage: "pencil.line") {
                    TextField("远程来源名称", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .glassFormField()
                        .frame(width: 220, alignment: .trailing)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: AppRadius.card)

            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                Button {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .appSheetChrome(width: 460)
    }
}

private struct FloatingNoticeStack: View {
    let availableWidth: CGFloat
    let notices: [AppFloatingNotice]
    let onDismiss: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stackHorizontalPadding: CGFloat = 20
        let capsuleMaxWidth = min(max(availableWidth - stackHorizontalPadding * 2, 180), 560)
        VStack(spacing: 8) {
            ForEach(notices) { notice in
                FloatingNoticeCapsule(
                    notice: notice,
                    maxWidth: capsuleMaxWidth
                ) {
                    onDismiss(notice.id)
                }
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.96, anchor: .top))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, stackHorizontalPadding)
        .animation(reduceMotion ? nil : AppMotion.notice, value: notices)
        .allowsHitTesting(!notices.isEmpty)
    }
}

private struct FloatingNoticeCapsule: View {
    let notice: AppFloatingNotice
    let maxWidth: CGFloat
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        let active = isHovering
        let capsuleWidth = resolvedWidth
        let textWidth = max(capsuleWidth - Self.horizontalChromeWidth, Self.minimumTextWidth)
        HStack(spacing: 10) {
            Image(systemName: notice.kind.systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(kindTint.opacity(colorScheme == .dark ? 0.98 : 0.94))
                .symbolRenderingMode(.monochrome)
                .frame(width: Self.sideSlotWidth, height: Self.sideSlotWidth)

            VStack(alignment: .center, spacing: 1) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(notice.message == nil ? 2 : 1)
                    .truncationMode(.middle)
                if let message = notice.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: textWidth, alignment: .center)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: Self.sideSlotWidth, height: Self.sideSlotWidth)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭")
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, notice.message == nil ? 8 : 9)
        .frame(width: capsuleWidth, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        }
        .background {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.20 : 0.70),
                            AppColors.cleanPanelFill.opacity(colorScheme == .dark ? 0.62 : 0.84),
                            kindTint.opacity(colorScheme == .dark ? 0.16 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.42 : 0.92),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.18 : 0.28),
                            kindTint.opacity(colorScheme == .dark ? 0.26 : 0.20),
                            Color.black.opacity(colorScheme == .dark ? 0.12 : 0.045)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        }
        .shadow(color: kindTint.opacity(colorScheme == .dark ? 0.18 : 0.12), radius: active ? 18 : 12, x: 0, y: active ? 9 : 6)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: active ? 20 : 14, x: 0, y: active ? 12 : 8)
        .scaleEffect(active ? 1.012 : 1)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
    }

    private static let sideSlotWidth: CGFloat = 24
    private static let horizontalPadding: CGFloat = 8
    private static let textSpacing: CGFloat = 20
    private static let horizontalChromeWidth = sideSlotWidth * 2 + horizontalPadding * 2 + textSpacing
    private static let minimumTextWidth: CGFloat = 48
    private static let minimumWidth: CGFloat = horizontalChromeWidth + minimumTextWidth

    private var resolvedWidth: CGFloat {
        let titleWidth = measuredTextWidth(for: notice.title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        let messageWidth = measuredTextWidth(for: notice.message ?? "", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular))
        let maximumTextWidth = max(maxWidth - Self.horizontalChromeWidth, Self.minimumTextWidth)
        let contentWidth = min(max(titleWidth, messageWidth), maximumTextWidth)
        return min(max(ceil(contentWidth) + Self.horizontalChromeWidth, Self.minimumWidth), maxWidth)
    }

    private func measuredTextWidth(for text: String, font: NSFont) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return (trimmed as NSString).size(withAttributes: [.font: font]).width
    }

    private var kindTint: Color {
        AppColors.selectedGlassTint
    }
}

/// 「打开网络串流」输入弹窗：粘贴 http(s)/rtsp/rtmp 等地址直接用内置播放器播放，不写入媒体库。
struct NetworkStreamPromptSheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var urlText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("打开网络串流", systemImage: "globe.desk")
                .font(.headline)

            TextField("https://example.com/stream.m3u8", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit(play)

            Text("支持 http / https / rtsp / rtmp 等 mpv 原生协议，仅本次播放，不会加入媒体库。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    appState.showingNetworkStreamPrompt = false
                }
                .keyboardShortcut(.cancelAction)

                Button("播放") {
                    play()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func play() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.playNetworkStream(text)
    }
}

/// 发现新版本的提示弹窗：展示版本与更新内容，提供跳过/永不提醒/前往更新。
struct AppUpdatePromptSheet: View {
    @EnvironmentObject private var appState: AppState
    let update: AppUpdateInfo
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appState.settings.appLanguage.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSheetHeader(
                title: "\(appState.localized("发现新版本")) \(update.version)",
                subtitle: "\(appState.localized("当前版本")) \(AppVersion.current)。\(releaseMetaText)",
                systemImage: "sparkles",
                subtitleLineLimit: 2
            )

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.82))
                    .frame(width: 18, height: 18)
                Text(appState.localized("后台更新检查只读取 GitHub Releases 元数据；跳过当前版本后，静默检查不会再提示这一版，手动检查仍可看到结果。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)

            releaseNotesView

            updateActionFooter
        }
        .appSheetChrome(width: 560, maxHeight: 640)
    }

    private var updateActionFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.45)
                .padding(.bottom, 12)
            HStack(spacing: 10) {
                Button(appState.localized("跳过此版")) {
                    appState.settings.updateSkippedVersion = update.tagName
                    appState.saveSettings()
                    appState.availableUpdate = nil
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 32)

                Button(appState.localized("不再自动提醒")) {
                    appState.settings.updateRemindersDisabled = true
                    appState.saveSettings()
                    appState.availableUpdate = nil
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 32)

                Spacer(minLength: 12)

                Button(appState.localized(update.downloadURL == nil ? "打开 Release" : "下载更新")) {
                    NSWorkspace.shared.open(update.downloadURL ?? update.releaseURL)
                    appState.availableUpdate = nil
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 18, minHeight: 34, prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var releaseMetaText: String {
        var parts = [update.title]
        if let publishedAt = update.publishedAt {
            parts.append(dateFormatter.string(from: publishedAt))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var releaseNotesView: some View {
        let sections = AppUpdateNoteSection.parse(update.releaseNotes)
        if sections.isEmpty {
            AppInfoNote(text: appState.localized("此版本未提供更新日志，可前往 Release 页面查看详情。"), systemImage: "doc.text")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(appState.localized("更新内容"))
                    .font(.headline)
                    .foregroundStyle(.primary.opacity(0.88))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(appState.localized(section.title))
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary.opacity(0.86))
                                ForEach(section.items, id: \.self) { item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Circle()
                                            .fill(AppColors.selectedGlassTint.opacity(0.66))
                                            .frame(width: 4, height: 4)
                                            .padding(.top, 1)
                                        Text(item)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineSpacing(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 292)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.34))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.58), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.045), radius: 14, y: 7)
                }
            }
        }
    }
}

private struct AppUpdateNoteSection: Identifiable {
    let id = UUID()
    var title: String
    var items: [String]

    static func parse(_ raw: String) -> [AppUpdateNoteSection] {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var sections: [AppUpdateNoteSection] = []
        var current = AppUpdateNoteSection(title: "更新内容", items: [])

        func flush() {
            guard !current.items.isEmpty else { return }
            sections.append(current)
        }

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#") {
                flush()
                let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespacesAndNewlines)
                current = AppUpdateNoteSection(title: title.isEmpty ? "更新内容" : title, items: [])
                continue
            }
            let item = line
                .replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty {
                current.items.append(item)
            }
        }
        flush()
        return sections
    }
}

/// 第三次启动时的赞赏邀请。
struct SponsorInviteSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 18) {
            PlayfulSymbolIcon(systemImage: "cup.and.saucer.fill", size: 60)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(appState.localized("觉得软件不错？投喂我！"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(appState.localized("MediaLIB 由我一个人利用业余时间打磨。如果它帮到了你，一杯咖啡的鼓励能让它走得更远。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button(appState.localized("下次一定")) {
                    appState.showingSponsorPrompt = false
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 12, horizontalPadding: 16, minHeight: 36, thickness: 0.94))

                Button(appState.localized("现在就去！")) {
                    NSWorkspace.shared.open(appState.sponsorURL)
                    appState.showingSponsorPrompt = false
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 18, minHeight: 36, prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
