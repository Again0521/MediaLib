import AppKit
import MediaLibCore
import SwiftUI

enum VideoLibrarySection: String, CaseIterable, Identifiable, Sendable {
    case movies
    case tvShows
    case anime
    case documentaries
    case variety
    case other
    case privacy
    case watching
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
        case .other: return "其他"
        case .privacy: return "保险库"
        case .watching: return "正在观看"
        case .favorites: return "收藏"
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
        case .other: return "tray"
        case .privacy: return "lock.rectangle.stack"
        case .watching: return "play.circle"
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
        allCases.filter { $0 != .favorites }
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
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return "视频"
        case .music: return "音乐"
        case .recent: return "最近播放"
        case .favorites: return "收藏"
        }
    }

    var systemImage: String {
        switch self {
        case .videos: return "play.tv"
        case .music: return "music.note"
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "heart"
        }
    }
}

private struct EmbySidebarCategory: Identifiable {
    enum Kind: Hashable {
        case section(EmbyLibrarySection)
        case library(EmbyLibrarySummary)
    }

    let id: String
    let title: String
    let systemImage: String
    let destination: SidebarDestination

    init(section: EmbyLibrarySection) {
        id = "section-\(section.id)"
        title = "EMBY \(section.title)"
        systemImage = section.systemImage
        destination = .emby(section)
    }

    init(library: EmbyLibrarySummary) {
        id = "library-\(library.id)"
        title = library.displayName
        systemImage = library.systemImage
        destination = .embyLibrary(library.id)
    }
}

enum SidebarDestination: Hashable, Identifiable, Sendable {
    case home
    case video(VideoLibrarySection)
    case music(MusicLibrarySection)
    case emby(EmbyLibrarySection)
    case embyLibrary(String)
    case sources
    case settings

    var id: String {
        switch self {
        case .home: return "home"
        case .video(let section): return "video-\(section.rawValue)"
        case .music(let section): return "music-\(section.rawValue)"
        case .emby(let section): return "emby-\(section.rawValue)"
        case .embyLibrary(let libraryID): return "emby-library-\(libraryID)"
        case .sources: return "sources"
        case .settings: return "settings"
        }
    }

    init?(storedID: String) {
        if storedID == "home" {
            self = .home
        } else if storedID == "sources" {
            self = .sources
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
        } else if storedID.hasPrefix("music-") {
            let raw = String(storedID.dropFirst("music-".count))
            if raw == MusicLibrarySection.favorites.rawValue {
                self = .music(.playlists)
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
            guard let section = EmbyLibrarySection(rawValue: raw) else { return nil }
            self = .emby(section)
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .home: return "首页"
        case .video(let section): return section.title
        case .music(let section): return section.title
        case .emby(let section): return section.title
        case .embyLibrary: return "EMBY 分类"
        case .sources: return "媒体源"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .video(let section): return section.systemImage
        case .music(let section): return section.systemImage
        case .emby(let section): return section.systemImage
        case .embyLibrary: return "rectangle.stack"
        case .sources: return "externaldrive"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SidebarDestination? = .home
    @State private var isVideoExpanded = true
    @State private var isMusicExpanded = true
    @State private var isEmbyExpanded = true
    @State private var musicPlayerExpanded = true
    // 沉浸式 chrome（隐藏工具栏/标题、透明标题栏、内容延伸到标题栏下）只在全屏播放器
    // 已完全覆盖窗口时开启/关闭，使 chrome 切换引起的 navigationRoot 重排被覆盖层遮挡。
    @State private var musicImmersive = false
    @State private var musicController = MpvPlayerController()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var musicTransitionTask: Task<Void, Never>?
    @State private var hadActiveMusic = false
    @Namespace private var musicPlayerNamespace
    @AppStorage("MediaLib.sidebar.selection") private var storedSelectionID = "home"

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                navigationRoot
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(!musicExpandedOverlayActive)
                    .environment(\.suppressPointerHoverDuringScroll, musicExpandedOverlayActive)
                    .glassPerformanceMode(backgroundGlassPerformanceMode)

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
                            onRequestExpand: expandMusicPlayer,
                            onRequestClose: closeMusicPlayer
                        )
                        .environmentObject(appState)
                        .frame(width: musicMiniPlayerWidth(for: geometry.size.width), alignment: .bottomLeading)
                        .padding(.leading, musicMiniPlayerLeadingInset + musicMiniPlayerOuterInset)
                        .padding(.bottom, 18)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                        .transition(AppMotion.floatingBar)
                        .zIndex(21)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .background {
            AppPageBackground(includeDirectionalLight: false)
        }
        // 全屏播放器作为忽略安全区的整窗覆盖层：尺寸恒为整窗（不随工具栏显隐变化的安全区而改变），
        // 因此 chrome 切换不会让它跳动，也始终盖住标题栏区域（展开过程顶部不再露白、不再抽搐）。
        .overlay {
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
        .background {
            VideoPlayerWindowPresenter(item: videoPlayerBinding)
                .frame(width: 0, height: 0)
        }
        .sheet(item: $appState.quickPreviewItem) { item in
            QuickPreviewView(item: item)
                .environmentObject(appState)
        }
        .alert(item: $appState.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
        .background {
            MainWindowToolbarVisibilityGuard(hiddenForMusicOverlay: musicWindowChromeHidden)
                .frame(width: 0, height: 0)
        }
        .onChange(of: appState.activePlayerItem?.id) { _ in
            let activeMusic = appState.activePlayerItem?.type == .music
            if activeMusic {
                if !hadActiveMusic {
                    hadActiveMusic = true
                    presentMusicMiniPlayer()
                }
            } else {
                hadActiveMusic = false
                restoreSidebarAfterMusic()
            }
        }
        .onChange(of: appState.playbackCommandRequest?.id) { _ in
            handlePlaybackCommand()
        }
    }

    private var navigationRoot: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section("媒体库") {
                    sidebarRow(.home)

                    DisclosureGroup(isExpanded: $isVideoExpanded) {
                        // 「正在观看」「未观看」不再作为左侧栏分类，仅保留各分类页面内的同名子页面（筛选标签）。
                        let sections = appState.visibleVideoSections.filter { $0 != .watching && $0 != .unwatched }
                        if sections.isEmpty {
                            Label("暂无视频", systemImage: "film")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sections) { section in
                                sidebarRow(.video(section))
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            PlayfulSymbolIcon(systemImage: "film", size: 22)
                            Text("视频")
                        }
                            .font(.callout.weight(.semibold))
                    }

                    DisclosureGroup(isExpanded: $isMusicExpanded) {
                        ForEach(MusicLibrarySection.sidebarCases) { section in
                            sidebarRow(.music(section))
                        }
                    } label: {
                        HStack(spacing: 10) {
                            PlayfulSymbolIcon(systemImage: "music.note", size: 22)
                            Text("音乐")
                        }
                            .font(.callout.weight(.semibold))
                    }

                    if !appState.embySources.isEmpty || appState.hasEmbyItems {
                        DisclosureGroup(isExpanded: $isEmbyExpanded) {
                            let categories = embySidebarCategories
                            if categories.isEmpty {
                                Label("暂无 EMBY 条目", systemImage: "server.rack")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(categories) { category in
                                    sidebarRow(category.destination)
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                PlayfulSymbolIcon(systemImage: "server.rack", size: 22)
                                Text("EMBY")
                            }
                                .font(.callout.weight(.semibold))
                        }
                    }
                }

                Section("管理") {
                    sidebarRow(.sources)
                    sidebarRow(.settings)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SidebarGlassBackground())
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .onAppear {
                selection = SidebarDestination(storedID: storedSelectionID) ?? .home
            }
            .onChange(of: selection) { _ in
                storedSelectionID = selection?.id ?? "home"
                appState.selectedItem = nil
            }
        } detail: {
            ZStack {
                if let startupError = appState.startupError {
                    StartupErrorView(message: startupError)
                } else if let selectedItem = appState.selectedItem {
                    DetailView(item: selectedItem)
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

    private var backgroundGlassPerformanceMode: GlassPerformanceMode {
        if musicExpandedOverlayActive {
            return .minimal
        }
        if appState.activePlayerItem?.type == .music {
            return .balanced
        }
        return .full
    }

    // 音乐展开/收起：全屏播放器是覆盖层，不改窗口大小、不挤压底层界面。
    // chrome 隐藏在覆盖层挂上后再执行，恢复则等覆盖层收起后执行，避免中间帧露出系统白底。
    private func expandMusicPlayer() {
        musicTransitionTask?.cancel()
        musicController.refreshMusicAirPlayRoute()
        withAnimation(AppMotion.musicPlayer) {
            musicPlayerExpanded = true
        }
        musicTransitionTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 18_000_000) } catch { return }
            guard appState.activePlayerItem?.type == .music, musicPlayerExpanded else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                musicImmersive = true
            }
        }
    }

    private func presentMusicMiniPlayer() {
        musicTransitionTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            musicPlayerExpanded = false
            musicImmersive = false
        }
        musicController.refreshMusicAirPlayRoute()
    }

    private func minimizeMusicPlayer() {
        musicTransitionTask?.cancel()
        musicController.refreshMusicAirPlayRoute()
        withAnimation(AppMotion.musicPlayer) {
            musicPlayerExpanded = false
        }
        musicTransitionTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 560_000_000) } catch { return }
            guard appState.activePlayerItem?.type == .music, !musicPlayerExpanded else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                musicImmersive = false
            }
        }
    }

    private func restoreSidebarAfterMusic() {
        musicTransitionTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            musicPlayerExpanded = false
            musicImmersive = false
        }
        musicController.refreshMusicAirPlayRoute()
    }

    private func closeMusicPlayer() {
        musicTransitionTask?.cancel()
        withAnimation(AppMotion.fast) {
            musicPlayerExpanded = false
            appState.activePlayerItem = nil
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            musicImmersive = false
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
            if appState.musicRepeatMode == .repeatOne {
                musicController.restartFromBeginning()
            } else {
                appState.playAdjacent(to: item, direction: -1)
            }
        case .next:
            if appState.musicRepeatMode == .repeatOne {
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

    private func sidebarRow(_ destination: SidebarDestination) -> some View {
        HStack(spacing: 10) {
            PlayfulSymbolIcon(systemImage: destination.systemImage, size: 22)
            Text(title(for: destination))
        }
            .tag(destination)
    }

    private var embySidebarCategories: [EmbySidebarCategory] {
        let sections = EmbyLibrarySection.allCases
            .filter(appState.hasEmbyItems(for:))
            .map(EmbySidebarCategory.init(section:))
        let libraries = appState.embyLibraries.map(EmbySidebarCategory.init(library:))
        return sections + libraries
    }

    private func title(for destination: SidebarDestination) -> String {
        if destination == .video(.privacy) {
            return appState.settings.privacyVaultName
        }
        if case .emby(let section) = destination {
            return section.title
        }
        if case .embyLibrary(let libraryID) = destination {
            return appState.embyLibraryTitle(libraryID)
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
            HomeView()
        case .video(.privacy):
            if appState.privacyPINConfigured && appState.privacyUnlocked {
                LibraryView(destination: destination)
            } else {
                PrivacyLockView()
            }
        case .video:
            LibraryView(destination: destination)
        case .music(let section):
            MusicLibraryView(section: section)
        case .emby, .embyLibrary:
            LibraryView(destination: destination)
        case .sources:
            SourcesView()
        case .settings:
            SettingsView()
        }
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

private struct MainWindowToolbarVisibilityGuard: NSViewRepresentable {
    let hiddenForMusicOverlay: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hiddenForMusicOverlay = hiddenForMusicOverlay
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hiddenForMusicOverlay = hiddenForMusicOverlay
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        var hiddenForMusicOverlay = false
        private weak var window: NSWindow?
        private var originalToolbarVisible: Bool?
        private var originalTitleVisibility: NSWindow.TitleVisibility?
        private var originalTitlebarAppearsTransparent: Bool?
        private var originalIsMovableByWindowBackground: Bool?
        private var originalContentMinSize: NSSize?
        private var didEnableFullSizeContent = false
        @available(macOS 11.0, *)
        private var originalTitlebarSeparatorStyle: NSTitlebarSeparatorStyle? {
            get { storedTitlebarSeparatorStyle as? NSTitlebarSeparatorStyle }
            set { storedTitlebarSeparatorStyle = newValue }
        }
        private var storedTitlebarSeparatorStyle: Any?
        private var lastAppliedHiddenState: Bool?

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
                originalToolbarVisible = nextWindow.toolbar?.isVisible
                originalTitleVisibility = nextWindow.titleVisibility
                originalTitlebarAppearsTransparent = nextWindow.titlebarAppearsTransparent
                originalIsMovableByWindowBackground = nextWindow.isMovableByWindowBackground
                originalContentMinSize = nextWindow.contentMinSize
                if #available(macOS 11.0, *) {
                    originalTitlebarSeparatorStyle = nextWindow.titlebarSeparatorStyle
                }
                // 关键修复：fullSizeContentView 一次性常驻开启，之后再也不切换 styleMask。
                // 这样音乐展开/收起只切换"工具栏可见性 + 标题栏透明度"，不会触发窗口 frame 重算，
                // 底层界面也不会因 styleMask 反复切换而抽搐（覆盖层只是盖在上面，不挤压任何东西）。
                if !nextWindow.styleMask.contains(.fullSizeContentView) {
                    nextWindow.styleMask.insert(.fullSizeContentView)
                    didEnableFullSizeContent = true
                }
                // AppKit 级最小内容尺寸（取代 SwiftUI 的 .frame(min...)），但不能大于当前内容尺寸，
                // 否则更新后首次打开或多次展开播放器会被系统强行撑高。
                let currentContentSize = nextWindow.contentView?.bounds.size ?? nextWindow.frame.size
                nextWindow.contentMinSize = NSSize(
                    width: min(1120, max(originalContentMinSize?.width ?? 0, min(currentContentSize.width, 960))),
                    height: min(720, max(originalContentMinSize?.height ?? 0, min(currentContentSize.height, 620)))
                )
                lastAppliedHiddenState = nil
            }
            applyIfNeeded()
        }

        func restore() {
            guard let window else { return }
            window.toolbar?.isVisible = originalToolbarVisible ?? true
            window.titleVisibility = originalTitleVisibility ?? .visible
            window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent ?? false
            window.isMovableByWindowBackground = originalIsMovableByWindowBackground ?? false
            if let originalContentMinSize {
                window.contentMinSize = originalContentMinSize
            }
            if #available(macOS 11.0, *), let originalTitlebarSeparatorStyle {
                window.titlebarSeparatorStyle = originalTitlebarSeparatorStyle
            }
            if didEnableFullSizeContent {
                window.styleMask.remove(.fullSizeContentView)
            }
            unhideTrafficLights(in: window)
            self.window = nil
            originalToolbarVisible = nil
            originalTitleVisibility = nil
            originalTitlebarAppearsTransparent = nil
            originalIsMovableByWindowBackground = nil
            originalContentMinSize = nil
            didEnableFullSizeContent = false
            if #available(macOS 11.0, *) {
                originalTitlebarSeparatorStyle = nil
            }
            lastAppliedHiddenState = nil
        }

        private func applyIfNeeded() {
            guard lastAppliedHiddenState != hiddenForMusicOverlay else { return }
            lastAppliedHiddenState = hiddenForMusicOverlay
            apply()
            // 单次异步重试，确保窗口就绪时也能套用，但不再有多次 setFrame 的抖动循环。
            DispatchQueue.main.async { [weak self] in
                self?.apply()
            }
        }

        private func apply() {
            guard let window else { return }
            // 安全网：在改 chrome 前后同步快照/还原窗口 frame，杜绝任何"撑大窗口"。单次同步 setFrame，
            // 不做以往的多次延迟还原（那会造成抖动）。
            let savedFrame: NSRect? = window.styleMask.contains(.fullScreen) ? nil : window.frame
            // 关键：绝不切换 window.toolbar?.isVisible —— 切换统一工具栏可见性会让 AppKit 重算窗口 frame
            // （这正是"反复展开收起把窗口撑大"的根因），且会改变安全区内边距导致底层重排。
            // 工具栏始终保持原样可见，仅切换"标题栏透明度 + 标题文字可见性"这类纯渲染属性（不改 frame、不改安全区）。
            if hiddenForMusicOverlay {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = false
                if #available(macOS 11.0, *) {
                    window.titlebarSeparatorStyle = .none
                }
            } else {
                window.titleVisibility = originalTitleVisibility ?? .visible
                // 主界面也保持透明标题栏，让 AppPageBackground 填满顶端，不再露出系统白条。
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = originalIsMovableByWindowBackground ?? false
                if #available(macOS 11.0, *) {
                    window.titlebarSeparatorStyle = .none
                }
            }
            unhideTrafficLights(in: window)
            // 音乐展开时隐藏工具栏里的侧栏切换按钮（隐藏其视图不改变 frame，不会撑大窗口）。
            setSidebarToggleHidden(hiddenForMusicOverlay, in: window)
            // 同步还原 frame：若上面任何属性意外触发了窗口尺寸变化，立即还原（单次、无延迟、无抖动）。
            if let savedFrame, !window.styleMask.contains(.fullScreen), window.frame != savedFrame {
                window.setFrame(savedFrame, display: false)
            }
        }

        /// 隐藏/显示工具栏中的侧栏切换按钮视图（不动 toolbar.isVisible，因此不触发窗口 frame 重算）。
        private func setSidebarToggleHidden(_ hidden: Bool, in window: NSWindow) {
            guard let items = window.toolbar?.items else { return }
            for item in items {
                let id = item.itemIdentifier.rawValue.lowercased()
                if id.contains("sidebar") || id.contains("toggle") {
                    item.view?.isHidden = hidden
                }
            }
        }

        private func unhideTrafficLights(in window: NSWindow) {
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.standardWindowButton(.closeButton)?.superview?.isHidden = false
        }
    }
}
