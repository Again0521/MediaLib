import Foundation
import MediaLibServerProtocol

/// Authenticated Web navigation shared by every server-rendered page.
///
/// Keeping this markup in one place prevents pages from silently drifting into
/// different link orders, active states, mobile behavior, or management exposure.
///
/// The structure changed in the 2026-08 redesign for three reasons:
///
/// * **The personal views were unreachable.** `/favorites`, `/watchlist`,
///   `/ratings`, `/watching` and `/history` were routed and styled but appeared in
///   no sidebar group, so the only way to reach them was to type the URL.  They
///   now have a home.
/// * **Mobile navigation was a dropdown.** Nine destinations behind a `<summary>`
///   is a menu, not navigation.  Phones get a bottom tab bar for the five places
///   people actually move between, plus a drawer for everything else.
/// * **The fake macOS traffic lights are gone.** They were decoration imitating a
///   window frame the browser does not have, and their inline `<style>` block was
///   blocked by the page CSP, so they had been rendering unstyled on every page.
/// 侧栏里那些由数据决定的条目：智能集合与智能歌单。
///
/// 它们和分类一样，条数随资料库变化，所以必须每次请求现取。单独打成一个包，是为了
/// 让十三个页面的渲染函数各加一个参数就够——否则每加一种动态条目，十七个调用点都
/// 要再改一遍签名。
///
/// 取不到某一类条目时它就是空数组：少画一行，而不是让整页渲染失败。
///
/// 但**这个类型本身不再有默认值**。`extras: … = .empty` 曾经是所有渲染函数的默认
/// 参数，于是「忘记传」和「确实没有」在编译期长得一模一样：`/`、`/category/*`、
/// `/search` 等 15 个渲染点漏传了它，远程来源分组一行都不画，既不报错也不打日志，
/// 而 `swift test` 全绿——测试只断言侧栏的结构性存在，空侧栏同样满足。
/// 现在漏传是编译错误。`.empty` 保留给测试与确实不需要的场合**显式**写出来。
struct ServerWebSidebarExtras {
    let smartCollections: [ServerSmartCollectionCard]
    let smartPlaylists: [ServerMusicPlaylistCard]
    /// 已连接的远程媒体服务器，每台一个分组——与客户端 `embySourceGroup` 同构。
    /// 远程内容绝不并入电影／剧集／音乐这些一级目录。
    let remoteSources: [ServerRemoteSourceGroup]
    /// 「视频」组徽标要显示的条数，由服务端用与 `/category/video` 逐字相同的谓词
    /// 算出。放在这里而不是新加一个参数，正是这个包存在的理由。
    let videoGroupItemCount: Int
    let activeCollectionID: String?
    let activePlaylistID: String?
    let activeRemoteScopeID: String?

    static let empty = ServerWebSidebarExtras(
        smartCollections: [], smartPlaylists: [], remoteSources: [],
        videoGroupItemCount: 0,
        activeCollectionID: nil, activePlaylistID: nil, activeRemoteScopeID: nil
    )

    init(
        smartCollections: [ServerSmartCollectionCard] = [],
        smartPlaylists: [ServerMusicPlaylistCard] = [],
        remoteSources: [ServerRemoteSourceGroup] = [],
        videoGroupItemCount: Int = 0,
        activeCollectionID: String? = nil,
        activePlaylistID: String? = nil,
        activeRemoteScopeID: String? = nil
    ) {
        self.smartCollections = smartCollections
        self.smartPlaylists = smartPlaylists
        self.remoteSources = remoteSources
        self.videoGroupItemCount = max(videoGroupItemCount, 0)
        self.activeCollectionID = activeCollectionID
        self.activePlaylistID = activePlaylistID
        self.activeRemoteScopeID = activeRemoteScopeID
    }
}

enum ServerWebNavigation {
    enum Active: String {
        case home, library, musicSongs, musicAlbums, musicArtists, musicPlaylists, musicRecent, people, collections, photos, albums, queue, watching, history, search, favorites, watchlist, ratings, watched, unwatched
        case sources, status, administration, account, vault

        var title: String {
            switch self {
            case .home: return "首页"
            case .library: return "浏览资料库"
            case .musicSongs: return "歌曲"
            case .musicAlbums: return "专辑"
            case .musicArtists: return "艺术家"
            case .musicPlaylists: return "歌单"
            case .musicRecent: return "最近播放"
            case .people: return "人物"
            case .collections: return "合集"
            case .photos: return "照片"
            case .albums: return "全部"
            case .queue: return "播放队列"
            case .watching: return "继续观看"
            case .history: return "播放历史"
            case .search: return "全局搜索"
            case .favorites: return "我的收藏"
            case .watchlist: return "想看清单"
            case .ratings: return "我的评分"
            case .watched: return "已看内容"
            case .unwatched: return "未看内容"
            case .sources: return "媒体源"
            case .status: return "仪表盘"
            case .administration: return "服务管理"
            case .account: return "设置"
            case .vault: return "保险库"
            }
        }

        /// Which bottom tab is highlighted on a phone.  Every destination maps to
        /// one, so the tab bar never shows a page as "nowhere".
        /// Which of the five phone tabs, if any, contains this destination.
        ///
        /// Spelled out rather than defaulted: a `default: "you"` catch-all marked
        /// 我的 as the current tab while the reader was on 服务管理, 媒体源, 仪表盘
        /// or 保险库 — pages the tab bar does not cover at all. Returning a group
        /// that matches no tab is the honest answer, and leaves no tab
        /// highlighted.
        fileprivate var tabGroup: String {
            switch self {
            case .home: return "home"
            case .library, .people, .collections, .photos, .albums, .watched, .unwatched: return "library"
            case .musicSongs, .musicAlbums, .musicArtists, .musicPlaylists, .musicRecent: return "music"
            case .search: return "search"
            case .account, .queue, .watching, .history, .favorites, .watchlist, .ratings: return "you"
            case .sources, .status, .administration, .vault: return "none"
            }
        }
    }

    enum Note: Equatable {
        case library, playback, security, none

        var html: String {
            switch self {
            case .library:
                return "<strong>只属于你</strong>你在这里看到的内容，都是这个账号可以访问的。"
            case .playback:
                return "<strong>就在浏览器里播</strong>影片直接在这个页面播放，文件始终留在你的 Mac 上。"
            case .security:
                return "<strong>放心</strong>密码、地址这些敏感信息不会显示在这里。"
            case .none:
                return ""
            }
        }
    }

    private struct Item {
        let active: Active
        let path: String
        let icon: ServerWebIcon
        let managementOnly: Bool
    }

    /// 搜索不在这里。
    ///
    /// 侧栏的「全局搜索」指向的是一个没有查询词的空结果页——一个永远先给你看
    /// 「没有符合条件的媒体」的目的地。搜索是**动作**不是地点：它的入口是每个
    /// 页头尾槽里那个固定位置的搜索框，提交后才落到结果页。客户端也是这样。
    private static let discoverItems: [Item] = [
        Item(active: .home, path: "/", icon: .home, managementOnly: false)
    ]

    // 「我的」分组已经取消，与客户端一致：侧栏只有「媒体库」和「管理」。
    //
    // 那一组里的路由都还在，只是入口换了地方，因为浏览器没有客户端那些弹层：
    //   /queue    音乐底栏的队列按钮
    //   /history  首页「最近播放」栏目的"更多"
    //   /watching /watched /unwatched  视频库控制栏的观看状态胶囊
    //   /favorites /watchlist          「视频」分组下的「喜欢」「想看」
    //   /ratings  账号页的个人数据入口
    //   /people   详情页「演员」区块的"查看全部"
    // 删掉一个入口而不给它接上新的，等于把页面做成了只能靠手输地址才进得去。

    private static let managementItems: [Item] = [
        Item(active: .sources, path: "/sources", icon: .source, managementOnly: true),
        Item(active: .status, path: "/status", icon: .dashboard, managementOnly: false),
        Item(active: .administration, path: "/admin", icon: .users, managementOnly: true),
        Item(active: .account, path: "/account", icon: .settings, managementOnly: false)
    ]

    private static let musicItems: [(active: Active, title: String, path: String)] = [
        (.musicSongs, "歌曲", "/music/songs"),
        (.musicAlbums, "专辑", "/music/albums"),
        (.musicArtists, "艺术家", "/music/artists"),
        (.musicPlaylists, "歌单", "/music/playlists"),
        (.musicRecent, "最近播放", "/music/recent")
    ]

    static func render(
        active: Active,
        showAdministration: Bool,
        note: Note,
        categories: [ServerLibraryCategory] = [],
        activeCategoryID: String? = nil,
        extras: ServerWebSidebarExtras
    ) -> String {
        let noteMarkup = note == .none ? "" : #"<p class="app-sidebar-note">\#(note.html)</p>"#
        let navigation = navigationMarkup(
            active: active,
            showAdministration: showAdministration,
            categories: categories,
            activeCategoryID: activeCategoryID,
            extras: extras
        )

        // Ordering matters: the drawer checkbox must precede the sidebar and the
        // scrim so the sibling selectors in `app-shell.css` can reach them.
        return """
        <input class="app-drawer-state" id="app-drawer-state" type="checkbox" aria-hidden="true" tabindex="-1">
        \(mobileBar(active: active))
        <aside class="app-sidebar" id="app-sidebar">
          <a class="app-brand" href="/" data-native-navigation="true">
            <span class="ui-icon-tile ui-icon-tile-sm ui-icon-tile-brand app-brand-mark" aria-hidden="true">\(ServerWebIcon.play.html(size: .sm))</span>
            <span class="app-brand-copy"><strong>MediaLIB</strong><span>家庭影音库</span></span>
          </a>
          \(navigation)
          <div class="app-sidebar-foot">
            \(appearanceControl())
            <a class="app-status-card" href="/status" data-native-navigation="true">
              <span class="ui-icon-tile ui-icon-tile-sm ui-icon-tile-tint app-status-icon" aria-hidden="true">\(ServerWebIcon.render(.activity, size: .sm, variant: .duotone))</span>
              <span class="app-status-copy"><strong>服务状态</strong><span>查看运行详情</span></span>
              \(ServerWebIcon.chevronRight.html(size: .xs, extraClass: "icon-muted"))
            </a>
            \(noteMarkup)
          </div>
        </aside>
        <label class="app-drawer-scrim" for="app-drawer-state" aria-hidden="true"></label>
        \(tabBar(active: active))
        """
    }

    /// The phone header: drawer toggle, current location, and a direct route to
    /// search.  It repeats the page title because on a phone the sidebar that
    /// would otherwise say where you are is off-screen.
    private static func mobileBar(active: Active) -> String {
        """
        <div class="app-mobile-bar">
          <label class="app-drawer-toggle ui-btn ui-btn-icon ui-btn-ghost" for="app-drawer-state" role="button" tabindex="0" aria-controls="app-sidebar" aria-label="打开导航">\(ServerWebIcon.menu.html(size: .md))</label>
          <span class="app-mobile-title">\(ServerWebHTML.escape(active.title))</span>
          <a class="ui-btn ui-btn-icon ui-btn-ghost" href="/search" aria-label="搜索" data-native-navigation="true">\(ServerWebIcon.search.html(size: .md))</a>
        </div>
        """
    }

    private static func tabBar(active: Active) -> String {
        let group = active.tabGroup
        func tab(_ id: String, _ title: String, _ path: String, _ icon: ServerWebIcon) -> String {
            let current = group == id ? #" aria-current="page""# : ""
            return #"<a class="app-tab" href="\#(path)" data-native-navigation="true"\#(current)>\#(icon.html(size: .md))<span>\#(title)</span></a>"#
        }
        return """
        <nav class="app-tabbar" aria-label="主导航">
          \(tab("home", "首页", "/", .home))
          \(tab("library", "资料库", "/category/\(ServerWebLibraryPage.Scope.videoGroupID)", .library))
          \(tab("music", "音乐", "/music/songs", .music))
          \(tab("search", "搜索", "/search", .search))
          \(tab("you", "我的", "/account", .account))
        </nav>
        """
    }

    private static func appearanceControl() -> String {
        ServerWebUI.appearanceSwitcher(compact: true)
    }

    private static func navigationMarkup(
        active: Active,
        showAdministration: Bool,
        categories: [ServerLibraryCategory],
        activeCategoryID: String?,
        extras: ServerWebSidebarExtras
    ) -> String {
        // `homeVideo`（录像）归「相册」，不再同时出现在「视频」里。它此前两边都
        // 在：侧栏里同一个分类有两个入口，而它的条数也被「视频」和「相册」各加了
        // 一遍——两个徽标加起来比库里真实的条目还多。
        let videoCategories = categories.filter {
            $0.id != "music" && $0.id != "photo" && $0.id != "episode" && $0.id != "homeVideo"
        }
        let musicCategories = categories.filter { $0.id == "music" }
        let videoActive = active == .library
            && (activeCategoryID == nil || videoCategories.contains { $0.id == activeCategoryID })
        let musicActive = musicCategories.contains { $0.id == activeCategoryID }
            || musicItems.contains { $0.active == active }
        let photoCount = categories.first(where: { $0.id == "photo" })?.itemCount ?? 0
        let homeVideoCount = categories.first(where: { $0.id == "homeVideo" })?.itemCount ?? 0

        let video = disclosure(
            icon: .film,
            title: "视频",
            open: videoActive || activeCategoryID != nil,
            // 徽标 = `/category/video` 真正会列出的条数（服务端算的顶层非分集数），
            // 不是各分类计数之和——后者按类型数全部行，有剧集的库里差一个数量级。
            count: extras.videoGroupItemCount,
            content: categoryMarkup(
                videoCategories,
                activeCategoryID: activeCategoryID,
                emptyTitle: "浏览视频",
                emptyPath: "/category/\(ServerWebLibraryPage.Scope.videoGroupID)"
            )
            // 客户端把想看、喜欢、保险库和集合都挂在「视频」下面，而不是另立一个
            // 「我的」分组。它们是同一批内容的不同切法，放在一起才说得通。
            + subItem(title: "想看", path: "/watchlist", isActive: active == .watchlist)
            + subItem(title: "喜欢", path: "/favorites", isActive: active == .favorites)
            + subItem(title: "保险库", path: "/vault", isActive: active == .vault)
            + smartCollectionMarkup(extras.smartCollections, activeID: extras.activeCollectionID)
            + subItem(title: "集合", path: "/collections", isActive: active == .collections)
        )
        let music = disclosure(
            icon: .music,
            title: "音乐",
            open: musicActive,
            count: musicCategories.reduce(0) { $0 + $1.itemCount },
            content: musicItems.map { entry in
                subItem(title: entry.title, path: entry.path, isActive: active == entry.active)
            }.joined()
            + smartPlaylistMarkup(extras.smartPlaylists, activeID: extras.activePlaylistID)
        )

        // 相册：与客户端一样分「全部 / 照片 / 录像」。网页从前只有一个纯照片页，
        // 录像得绕到「其他视频」分类里才找得到。
        let album = disclosure(
            icon: .photos,
            title: "相册",
            open: active == .photos || active == .albums,
            count: photoCount + homeVideoCount,
            content: [
                subItem(title: "全部", path: "/albums", isActive: active == .albums),
                photoCount > 0 || active == .photos
                    ? subItem(title: "照片", path: "/photos", isActive: active == .photos)
                    : "",
                homeVideoCount > 0 || activeCategoryID == "homeVideo"
                    ? subItem(title: "录像", path: "/category/homeVideo", isActive: activeCategoryID == "homeVideo")
                    : ""
            ].joined()
        )

        // 每台已连接的远程服务器一个分组，与客户端 `ContentView.embySourceGroup`
        // 同构：先是「全部」，再是该服务器下的各资料库。远程内容不进上面三个
        // 一级分组——两端的"一级分类"含义必须是同一个。
        let remoteGroups = extras.remoteSources.map { source in
            disclosure(
                icon: .server,
                title: source.title,
                open: extras.activeRemoteScopeID.map { scope in
                    scope == source.id || source.libraries.contains { $0.id == scope }
                } ?? false,
                count: source.itemCount,
                content: subItem(
                    title: "全部",
                    path: "/remote/\(source.id)",
                    isActive: extras.activeRemoteScopeID == source.id
                )
                + source.libraries.map { library in
                    subItem(
                        title: library.title,
                        path: "/remote/\(library.id)",
                        isActive: extras.activeRemoteScopeID == library.id
                    )
                }.joined()
            )
        }.joined()

        return """
        <nav class="app-nav" aria-label="主导航">
          <div class="app-nav-group">
            <p class="app-nav-title">媒体库</p>
            \(links(discoverItems, active: active, showAdministration: showAdministration))
            \(video)
            \(music)
            \(album)
            \(remoteGroups)
          </div>
          <div class="app-nav-group">
            <p class="app-nav-title">管理</p>
            \(links(managementItems, active: active, showAdministration: showAdministration))
          </div>
        </nav>
        """
    }

    private static func links(_ items: [Item], active: Active, showAdministration: Bool) -> String {
        items.compactMap { entry in
            guard showAdministration || !entry.managementOnly else { return nil }
            return item(
                active: entry.active,
                path: entry.path,
                icon: entry.icon,
                current: entry.active == active,
                count: nil
            )
        }.joined()
    }

    private static func item(active: Active, path: String, icon: ServerWebIcon, current: Bool, count: Int?) -> String {
        let currentAttribute = current ? #" aria-current="page""# : ""
        let badge = count.map { #"<span class="nav-count">\#(max($0, 0))</span>"# } ?? ""
        return #"<a class="nav-item" href="\#(path)" data-native-navigation="true"\#(currentAttribute)>\#(icon.html(size: .md))<span>\#(ServerWebHTML.escape(active.title))</span>\#(badge)</a>"#
    }

    private static func subItem(title: String, path: String, isActive: Bool, count: Int? = nil) -> String {
        let currentAttribute = isActive ? #" aria-current="page""# : ""
        let badge = count.map { #"<span class="nav-count">\#(max($0, 0))</span>"# } ?? ""
        return #"<a class="nav-subitem" href="\#(path)" data-native-navigation="true"\#(currentAttribute)><span class="nav-dot" aria-hidden="true"></span><span>\#(ServerWebHTML.escape(title))</span>\#(badge)</a>"#
    }

    /// 智能集合与智能歌单在侧栏里是动态子项，和分类一样由数据决定有几条。
    /// 只渲染名字和数量——规则留在桌面端。
    private static func smartCollectionMarkup(_ collections: [ServerSmartCollectionCard], activeID: String?) -> String {
        collections.prefix(24).compactMap { collection -> String? in
            guard let encoded = ServerWebURL.pathSegment(collection.id) else { return nil }
            return subItem(
                title: collection.name,
                path: "/smart-collections/\(encoded)",
                isActive: collection.id == activeID,
                count: collection.mediaCount
            )
        }.joined()
    }

    private static func smartPlaylistMarkup(_ playlists: [ServerMusicPlaylistCard], activeID: String?) -> String {
        playlists.prefix(24).compactMap { playlist -> String? in
            guard playlist.isSmart, let encoded = ServerWebURL.pathSegment(playlist.id) else { return nil }
            return subItem(
                title: playlist.name,
                path: "/music/playlists/\(encoded)",
                isActive: playlist.id == activeID,
                count: playlist.trackCount
            )
        }.joined()
    }

    /// Groups open when they contain the current page and stay collapsed
    /// otherwise, so the rail shows where you are without listing every category
    /// in the library at all times.
    private static func disclosure(icon: ServerWebIcon, title: String, open: Bool, count: Int, content: String) -> String {
        """
        <details class="nav-disclosure"\(open ? " open" : "")>
          <summary>\(icon.html(size: .md))<span>\(ServerWebHTML.escape(title))</span><span class="nav-count">\(max(count, 0))</span>\(ServerWebIcon.chevronRight.html(size: .xs, extraClass: "nav-chevron"))</summary>
          <div class="nav-subitems">\(content)</div>
        </details>
        """
    }

    private static func categoryMarkup(
        _ categories: [ServerLibraryCategory],
        activeCategoryID: String?,
        emptyTitle: String = "暂无分类",
        emptyPath: String? = nil
    ) -> String {
        let rendered = categories.prefix(32).compactMap { category -> String? in
            // 空分类不出现，与客户端一致。
            //
            // 一个「纪录片 0」点进去只会看到"没有可显示的内容"，它在侧栏里唯一的
            // 作用是让人白跑一趟；分类是资料库里真的有什么，不是这个产品支持哪些
            // 类型的清单。当前所在的分类例外——正看着它的时候把它从侧栏抹掉，会
            // 让人以为自己走丢了。
            guard category.itemCount > 0 || category.id == activeCategoryID else { return nil }
            guard let encodedID = ServerWebURL.queryValue(category.id) else { return nil }
            return subItem(
                title: category.title,
                path: "/category/\(encodedID)",
                isActive: category.id == activeCategoryID,
                count: category.itemCount
            )
        }.joined()
        guard rendered.isEmpty else { return rendered }
        guard let emptyPath else {
            return #"<span class="nav-subitem" aria-disabled="true">\#(ServerWebHTML.escape(emptyTitle))</span>"#
        }
        return subItem(title: emptyTitle, path: emptyPath, isActive: false)
    }
}
