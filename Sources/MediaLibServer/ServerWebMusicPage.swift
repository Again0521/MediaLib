import Foundation
import MediaLibServerProtocol

/// 系统页面中的歌曲、专辑、艺术家、歌单和最近播放页面。
/// 所有文本来自已经按当前用户授权过滤的 DTO，并在这里再次 HTML 转义；封面只通过
/// 同源、权限校验后的图片端点加载，页面从不接触本地文件路径。
enum ServerWebMusicPage {
    enum Page {
        case songs, albums, artists, playlists, recent

        var title: String {
            switch self {
            case .songs: return "歌曲"
            case .albums: return "专辑"
            case .artists: return "艺术家"
            case .playlists: return "歌单"
            case .recent: return "最近播放"
            }
        }

        /// Each view says what *it* is.  The five pages used to share one generic
        /// sentence in the shared header and then repeat a second heading block
        /// of their own inside the content — two `<h1>`s and two descriptions on
        /// every music page.  The specific copy moves up into the one header.
        var subtitle: String {
            switch self {
            case .songs: return "所有曲目。按歌名、艺术家或专辑浏览都行。"
            case .albums: return "按专辑收好的音乐。挑一张，听整张。"
            case .artists: return "按艺术家收好的音乐。"
            case .playlists: return "为不同心情准备的歌单。"
            case .recent: return "你最近听过的曲子。"
            }
        }

        /// 计数的量词，与客户端逐字一致（"… · 128 首"）。
        var countUnit: String {
            switch self {
            case .songs, .recent: return "首"
            case .albums: return "张"
            case .artists: return "位"
            case .playlists: return "个"
            }
        }

        var activeNavigation: ServerWebNavigation.Active {
            switch self {
            case .songs: return .musicSongs
            case .albums: return .musicAlbums
            case .artists: return .musicArtists
            case .playlists: return .musicPlaylists
            case .recent: return .musicRecent
            }
        }
    }

    static func render(
        page: Page,
        serverName: String,
        csrfToken: String,
        showAdministration: Bool,
        categories: [ServerLibraryCategory],
        sidebarExtras: ServerWebSidebarExtras,
        tracks: [ServerLibraryItem],
        playlists playlistCards: [ServerMusicPlaylistCard] = []
    ) -> String {
        let sidebar = ServerWebNavigation.render(
            active: page.activeNavigation,
            showAdministration: showAdministration,
            note: .library,
            categories: categories,
            activeCategoryID: "music",
            extras: sidebarExtras
        )
        let content: String
        switch page {
        case .songs: content = songs(tracks)
        case .albums: content = albums(tracks)
        case .artists: content = artists(tracks)
        case .playlists: content = playlists(playlistCards)
        case .recent: content = recent(tracks)
        }
        let body = """
        \(ServerWebPageHeader.render(
            icon: .music,
            eyebrow: "Music",
            title: page.title,
            subtitle: page.subtitle,
            countID: "music-result-count",
            countUnit: page.countUnit,
            search: ServerWebUI.searchField(
                id: "music-query",
                label: "搜索音乐",
                placeholder: "搜索音乐",
                action: "/search",
                hiddenFields: [(name: "type", value: "music")]
            ),
            titleID: "music-title"
        ))
        \(content)
        <p class="t-footnote t-tertiary music-footnote">MediaLIB Server · 当前账号的已授权音乐</p>
        """
        return ServerWebDocument.render(
            title: page.title,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: body,
            pageStylesheets: ["/assets/music.css"],
            pageScripts: ["/assets/overlays.js", "/assets/music.js"],
            bodyClass: "music-system-page",
            bodyAttributes: ServerWebHTML.attribute("data-page", page.title)
                + ServerWebHTML.attribute("data-count-unit", page.countUnit),
            tint: .music
        )
    }

    /// 单个歌单的曲目页。手动与智能共用，两者对读者是同一种东西。
    static func playlistDetail(
        serverName: String,
        detail: ServerMusicPlaylistDetail,
        csrfToken: String,
        showAdministration: Bool,
        categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras,
        back: ServerWebBackNavigation.Target = .init(label: "返回歌单", href: "/music/playlists")
    ) -> String {
        let body = """
        \(ServerWebPageHeader.render(
            icon: .playlist,
            eyebrow: detail.isSmart ? "Smart Playlist" : "Playlist",
            title: detail.name,
            subtitle: detail.isSmart ? "会随你的资料库自动更新" : "你自己整理的歌单",
            countID: "music-result-count",
            countUnit: "首",
            initialCount: detail.items.totalItemCount,
            breadcrumb: [("歌单", "/music/playlists"), (detail.name, nil)],
            back: (back.label, back.href),
            titleID: "music-title"
        ))
        <section class="music-page-content" aria-label="\(escape(detail.name))">\
        \(songs(detail.items.items))</section>
        <p class="t-footnote t-tertiary music-footnote">MediaLIB Server · 当前账号的已授权音乐</p>
        """
        return ServerWebDocument.render(
            title: detail.name,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: ServerWebNavigation.render(
                active: .musicPlaylists, showAdministration: showAdministration, note: .library,
                categories: categories, activeCategoryID: "music", extras: sidebarExtras
            ),
            content: body,
            pageStylesheets: ["/assets/music.css"],
            pageScripts: ["/assets/overlays.js", "/assets/music.js"],
            bodyClass: "music-system-page",
            bodyAttributes: ServerWebHTML.attribute("data-page", "歌单") + ServerWebHTML.attribute("data-count-unit", "首"),
            tint: .music
        )
    }

    /// Filter capsules, mirroring `MusicFilterMode` in the macOS client.
    ///
    /// 四项与客户端逐字一致。「有歌词」从前是缺席的——歌词存在性只活在客户端的
    /// 一个内存缓存里，服务端没有这个字段，放一个永远筛不出东西的控件比不放更
    /// 糟。schema 29 把 `has_lyrics` 落库之后，两端读的是同一个值。
    private enum Filter: String, CaseIterable {
        case all, favorites, withLyrics, unmatched

        var title: String {
            switch self {
            case .all: return "全部"
            case .favorites: return "收藏"
            case .withLyrics: return "有歌词"
            case .unmatched: return "未匹配"
            }
        }
    }

    /// Sort modes, and which sections offer which, mirroring the client's
    /// `availableSortModes(for:)`.
    private enum Sort: String {
        case title, artist, album, recent, duration, mostPlayed, workCount

        func label(for page: Page) -> String {
            switch self {
            case .title: return page == .albums ? "专辑名" : (page == .artists ? "按名称" : "歌曲名")
            case .artist: return "艺术家"
            case .album: return "专辑"
            case .recent: return "最近更新"
            case .duration: return "时长"
            case .mostPlayed: return page == .artists ? "按播放次数" : "最多播放"
            case .workCount: return "按作品数量"
            }
        }
    }

    private static func sortModes(for page: Page) -> [Sort] {
        switch page {
        case .artists: return [.title, .workCount, .mostPlayed]
        case .albums: return [.title, .artist, .recent, .mostPlayed]
        case .songs, .recent: return [.title, .artist, .album, .mostPlayed, .recent, .duration]
        case .playlists: return [.title]
        }
    }

    private static func filters(for page: Page) -> [Filter] {
        page == .artists ? [.all] : Filter.allCases
    }

    /// 这一条筛选栏与其它页面是同一个构件。
    ///
    /// 走 `ServerWebUI.controlBar`，不再自己拼 markup——单靠 CSS 拦不住漂移，
    /// 各页面照样会写出略有差别的类名、图标位置与 ARIA。
    private static func toolbar(selected: Page) -> String {
        let chips = filters(for: selected).enumerated().map { index, filter in
            ServerWebUI.ControlChip(
                label: filter.title,
                value: filter.rawValue,
                selected: index == 0
            )
        }
        let modes = sortModes(for: selected)
        // A single control that both picks the key and, pressed again, flips the
        // direction is how the client behaves; on the web the key is a select and
        // the direction is its own toggle so both stay reachable by keyboard.
        // 一个控件，不是"下拉 + 方向按钮"两个。
        //
        // 客户端这里是单独一颗写着「歌曲名 · 正序」的菜单：排序键与方向是同一个决
        // 定的两半，拆成两个控件就要读者自己把它们拼起来。原生 `<select>` 没法让
        // 显示文本与选项文本不同，所以把方向直接编进选项——标签与客户端逐字一致，
        // 值形如 `title:asc`。
        let sortControls = modes.count > 1
            ? ServerWebUI.select(
                id: "music-sort",
                name: "music_sort",
                label: "排序方式",
                options: modes.flatMap { mode in
                    [("asc", "正序"), ("desc", "倒序")].map { direction, suffix in
                        (
                            value: "\(mode.rawValue):\(direction)",
                            label: "\(mode.label(for: selected)) · \(suffix)",
                            selected: mode == modes[0] && direction == "asc"
                        )
                    }
                }
            )
            : ""
        // 控制栏里放的是**这一页**的筛选与排序，不是页面之间的切换。
        //
        // 「歌曲/专辑/艺术家/歌单/最近播放」曾经挤在托盘左边：那是五个不同的
        // 页面，属于侧栏的事（设计文档 §9.5 的音乐分组里就有这五条）。把它们混进
        // 筛选栏，等于把"我在哪"和"我要看哪一部分"塞进同一条控件；而且那排锚点
        // 全仓**没有任何 CSS 命中**——`.music-section-link` 一条规则都没写过，
        // 于是它们以零间距的纯文本渲染成「歌曲专辑艺术家歌单最近播放」一长串。
        //
        // 窄屏也不会因此少一个入口：侧栏收成抽屉之后，抽屉里装的就是完整侧栏，
        // 那五条仍然在里面，和其它每一页的次级导航走的是同一条路。
        return ServerWebUI.controlBar(
            label: "筛选与排序",
            chipsLabel: "筛选",
            chips: chips,
            chipsName: "music_filter",
            chipsGroupID: "music-filter",
            mobileDisclosureLabel: "高级筛选",
            trailing: sortControls,
            trailingID: "music-advanced-filters",
            extraClass: "music-controls"
        )
    }

    /// Sort and filter keys carried on the row itself.
    ///
    /// The music sections are rendered whole, so the toolbar reorders and hides
    /// what is already in the document rather than issuing another query. These
    /// attributes are the sort keys; they hold no path, no source and nothing the
    /// row does not already display. (Authenticated HTML is `no-store`, so they
    /// are never cached.)
    private static func sortKeys(
        _ item: ServerLibraryItem,
        artist: String,
        album: String,
        works: Int? = nil,
        title: String? = nil,
        hasLyrics: Bool? = nil
    ) -> String {
        let unmatched: Bool = (item.artist?.isEmpty ?? true) || (item.album?.isEmpty ?? true)
        let duration: Int = Int(item.durationSeconds ?? 0)
        let playCount: Int = item.userState?.playCount ?? 0
        let recent: Int = Int(item.userState?.updatedAt.timeIntervalSince1970 ?? 0)
        var pairs: [(String, String)] = [
            // An album card sorts by its album name and an artist card by the
            // artist's, not by whichever track happened to represent it.
            ("data-sort-title", escape((title ?? item.title).lowercased())),
            ("data-sort-artist", escape(artist.lowercased())),
            ("data-sort-album", escape(album.lowercased())),
            ("data-sort-duration", String(duration)),
            ("data-sort-play-count", String(playCount)),
            ("data-sort-recent", String(recent)),
            ("data-filter-favorite", item.userPreference.isFavorite ? "true" : "false"),
            ("data-filter-unmatched", unmatched ? "true" : "false"),
            // 专辑/艺术家卡片代表的是一组曲目：只要组里有一首带歌词，这张卡就该
            // 留在「有歌词」筛选里，而不是只看代表曲目那一首。
            ("data-filter-lyrics", (hasLyrics ?? item.hasLyrics) ? "true" : "false")
        ]
        if let works { pairs.append(("data-sort-work-count", String(works))) }
        return pairs.map { " \($0.0)=\"\($0.1)\"" }.joined()
    }

    private static func songs(_ tracks: [ServerLibraryItem]) -> String {
        // 全部曲目都渲染出来，不再截断。
        //
        // 从前这里 `.prefix(50)`，注释写着"其余内容由后续分页入口继续获取"——但
        // 那个入口从来没有存在过：300 首的曲库永远只显示前 50 首，剩下的没有任何
        // 办法看到。更糟的是筛选与排序都是在已渲染的行上做的，于是「有歌词」「收藏」
        // 也只在这 50 行里找，结果是错的。
        //
        // 当初担心的开销来自封面：行本身只是文本加一张 38px 的图，而那些图早已是
        // `loading="lazy"`，屏外的根本不会解码。
        let visible = tracks
        let rows = visible.enumerated().map { index, track in
            let artist = display(track.artist, fallback: "未知艺术家")
            let album = display(track.album, fallback: "未归档专辑")
            let duration = durationText(track.durationSeconds)
            return """
            <a class="ui-track-row" href="/play/\(escapePath(track.id))#play" data-music-play="\(escape(track.id))" data-music-title="\(escape(track.title))" data-music-subtitle="\(escape(artist))" aria-label="播放 \(escape(track.title))"\(sortKeys(track, artist: artist, album: album))>
              <span class="ui-track-main">\(artwork(track, size: 160, eager: index < 4))<span class="ui-track-copy"><strong>\(escape(track.title))</strong><small>\(escape(artist))</small></span></span>
              <span class="ui-track-meta ui-track-artist">\(escape(artist))</span>
              <span class="ui-track-meta ui-track-album">\(escape(album))</span>
              <span class="ui-track-meta ui-track-lyrics" aria-label="暂无歌词">—</span>
              <span class="ui-track-duration">\(duration)</span>
              <span class="ui-track-favorite" aria-label="收藏">\(ServerWebIcon.star.html(size: .sm))</span>
            </a>
            """
        }.joined(separator: "\n")
        let empty = visible.isEmpty ? "<p class=\"music-empty\">这里还没有音乐。</p>" : ""
        return """
        <section class="music-page-content" aria-labelledby="music-title">
          \(toolbar(selected: .songs))
          <div class="songs-table">
            <div class="ui-track-head"><span>歌曲</span><span>艺术家</span><span>专辑</span><span>歌词</span><span>时长</span><span></span></div>
            \(rows)\(empty)
          </div>
        </section>
        """
    }

    private static func albums(_ tracks: [ServerLibraryItem]) -> String {
        struct Album { let title: String; let artist: String; let track: ServerLibraryItem; let count: Int; let hasLyrics: Bool }
        let grouped = Dictionary(grouping: tracks) { "\(display($0.album, fallback: "未归档专辑"))\u{1F}\(display($0.artist, fallback: "未知艺术家"))" }
        let items = grouped.values.compactMap { group -> Album? in
            guard let representative = group.first else { return nil }
            return Album(title: display(representative.album, fallback: "未归档专辑"), artist: display(representative.artist, fallback: "未知艺术家"), track: representative, count: group.count, hasLyrics: group.contains { $0.hasLyrics })
        // 首屏只输出一页专辑。此前一次性把 80 张 480px 封面交给浏览器和
        // 缩略图派生器，会让真正可见的四张卡与屏外内容争抢解码队列。
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let cards = items.enumerated().map { index, album in
            """
            <a class="album-card" href="/category/music?q=\(query(album.title))" data-native-navigation="true" aria-label="浏览专辑 \(escape(album.title))"\(sortKeys(album.track, artist: album.artist, album: album.title, works: album.count, title: album.title, hasLyrics: album.hasLyrics))>
              \(albumArtwork(album.track, eager: index < 4))
              <strong>\(escape(album.title))</strong>
              <span class="album-card-meta"><span>\(escape(album.artist)) · \(album.count) 首</span><span class="album-play"><i></i>播放</span></span>
            </a>
            """
        }.joined(separator: "\n")
        return "<section class=\"music-page-content\">\(toolbar(selected: .albums))<div class=\"album-grid\">\(cards)</div></section>"
    }

    private static func artists(_ tracks: [ServerLibraryItem]) -> String {
        let grouped = Dictionary(grouping: tracks) { display($0.artist, fallback: "未知艺术家") }
        // 艺术家卡片均含正方形封面；上限与四列首屏相匹配，避免 120 张
        // 浏览器外图片仍占据网格布局与解码调度。
        let items = grouped.map { (name: $0.key, tracks: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let cards = items.enumerated().map { index, artist in
            let representative = artist.tracks.first!
            return """
            <a class="artist-card" href="/category/music?q=\(query(artist.name))" data-native-navigation="true" aria-label="浏览艺术家 \(escape(artist.name))"\(sortKeys(representative, artist: artist.name, album: artist.name, works: artist.tracks.count, title: artist.name, hasLyrics: artist.tracks.contains { $0.hasLyrics }))>
              \(artistArtwork(representative, eager: index < 4))
              <strong>\(escape(artist.name))</strong>
              <small>\(artist.tracks.count) 首</small>
            </a>
            """
        }.joined(separator: "\n")
        return "<section class=\"music-page-content\">\(toolbar(selected: .artists))<div class=\"artist-grid\">\(cards)</div></section>"
    }

    /// 真实歌单：手动歌单与智能歌单。
    ///
    /// 这里从前是四张伪造的卡片——「全部歌曲」「最近加入」「按艺术家浏览」
    /// 「未归档专辑」，名字是写死的，曲目数是 `tracks.count / (index + 2)` 算出来
    /// 的假数字，四张卡还全都链回 `/music/songs`。它看起来像歌单，但点进去哪张都
    /// 一样，而用户自己建的歌单一个也看不到。
    private static func playlists(_ playlists: [ServerMusicPlaylistCard]) -> String {
        let toolbarMarkup = toolbar(selected: .playlists)
        guard !playlists.isEmpty else {
            return """
            <section class="music-page-content" aria-label="歌单">\(toolbarMarkup)\
            \(ServerWebUI.emptyState(
                icon: .playlist,
                title: "还没有歌单",
                message: "在 Mac 上新建一个歌单，这里就能看到。"
            ))</section>
            """
        }
        let cards = playlists.compactMap { playlist -> String? in
            guard let encoded = ServerWebURL.pathSegment(playlist.id) else { return nil }
            let caption = playlist.ruleSummary ?? (playlist.isSmart ? "智能歌单" : "手动歌单")
            let badge = playlist.isSmart
                ? #"<span class="ui-badge playlist-smart-badge">智能</span>"#
                : ""
            return """
            <a class="playlist-card" href="/music/playlists/\(encoded)" data-native-navigation="true" \
            aria-label="打开歌单 \(escape(playlist.name))">\
            <span class="playlist-art"><span class="playlist-fallback" aria-hidden="true">\
            \(ServerWebIcon.playlist.html(size: .lg))</span></span>\
            <span class="playlist-copy"><strong>\(escape(playlist.name))\(badge)</strong>\
            <small>\(escape(caption))</small><em>\(playlist.trackCount) 首</em></span>\
            <span class="playlist-play" aria-hidden="true">\(ServerWebIcon.play.html(size: .sm))</span></a>
            """
        }.joined(separator: "\n")
        return "<section class=\"music-page-content\" aria-label=\"歌单\">\(toolbarMarkup)<div class=\"playlist-grid\">\(cards)</div></section>"
    }

    private static func recent(_ tracks: [ServerLibraryItem]) -> String {
        let rows = tracks.enumerated().map { index, track in
            let artist = display(track.artist, fallback: "未知艺术家")
            return "<a class=\"recent-row\" href=\"/play/\(escapePath(track.id))#play\" data-music-play=\"\(escape(track.id))\" data-music-title=\"\(escape(track.title))\" data-music-subtitle=\"\(escape(artist))\"\(sortKeys(track, artist: artist, album: display(track.album, fallback: "未归档专辑")))><span class=\"recent-number\">\(index + 1)</span>\(artwork(track, size: 160, eager: index < 4))<span class=\"recent-copy\"><strong>\(escape(track.title))</strong><small>\(escape(artist))</small></span><span class=\"recent-time\">资料库中</span><span class=\"recent-duration\">\(durationText(track.durationSeconds))</span></a>"
        }.joined(separator: "\n")
        let toolbarMarkup = toolbar(selected: .recent)
        let content = rows.isEmpty ? "<p class=\"music-empty\">暂无播放记录。</p>" : rows
        return "<section class=\"music-page-content\" aria-label=\"最近播放\">\(toolbarMarkup)<div class=\"recent-table\">\(content)</div></section>"
    }

    private static func artwork(_ item: ServerLibraryItem, size: Int, eager: Bool) -> String {
        let palette = ServerWebArtworkPalette.token(for: item.id, context: .music)
        // 客户端的无封面状态是派生色材质，不以首字母冒充专辑封面。图片
        // 尚未完成解码时也保持这一底图，成功后才把真实封面淡入。
        guard item.artworkAvailable else { return "<span class=\"ui-track-art music-artwork music-artwork-fallback\" data-artwork-palette=\"\(palette)\" role=\"img\" aria-label=\"\(escape(item.title)) 的默认封面\"><span class=\"music-artwork-glyph\" aria-hidden=\"true\">\(ServerWebIcon.music.html(size: .md))</span></span>" }
        let loading = eager ? "eager" : "lazy"
        let priority = eager ? " fetchpriority=\"high\"" : ""
        // CSP 下不使用 inline onerror；同源脚本只在 load 后显示图片，失败时
        // 移除图片节点，浏览器不会暴露裂图图标。
        return "<span class=\"ui-track-art music-artwork\" data-artwork-palette=\"\(palette)\" data-artwork-state=\"pending\"><span class=\"music-artwork-glyph\" aria-hidden=\"true\">\(ServerWebIcon.music.html(size: .md))</span><img src=\"/api/v1/images/\(escapePath(item.id))/poster?size=\(size)\" alt=\"\" loading=\"\(loading)\" decoding=\"async\"\(priority)></span>"
    }

    private static func albumArtwork(_ item: ServerLibraryItem, eager: Bool) -> String {
        "<span class=\"album-artwork\">\(artwork(item, size: 320, eager: eager))</span>"
    }

    private static func artistArtwork(_ item: ServerLibraryItem, eager: Bool) -> String {
        "<span class=\"artist-artwork\">\(artwork(item, size: 320, eager: eager))</span>"
    }

    private static func display(_ value: String?, fallback: String) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return fallback }
        return String(value.prefix(256))
    }

    private static func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func query(_ value: String) -> String { ServerWebURL.queryValue(value) ?? "" }
    private static func escapePath(_ value: String) -> String { ServerWebURL.pathSegment(value) ?? "" }
    /// Delegates to the shared implementation in `ServerWebHTML`.
    ///
    /// Every page used to carry a private copy of this function — eighteen of
    /// them — which meant eighteen places to audit and eighteen chances for one
    /// to drift.  The local name is kept so the hundreds of call sites in this
    /// file stay readable.
    private static func escape(_ value: String) -> String { ServerWebHTML.escape(value) }

    static let style = #"""
    /* The section tabs are anchors inside the shared `.ui-segmented`, which now
       styles `> a` alongside `> label`.  This file used to carry a line-for-line
       copy of those rules purely because the segments were links. */
    .music-controls { margin-bottom: var(--space-6); }

    /* 曲目行的全部规则来自 primitives 的 `.ui-track-*`；这一页不再自带一份。 */

    /* 尺寸、圆角、取色兜底、淡入全部来自 `.ui-track-art`。这一页只保留占位字形
       的定位，以及下面把同一段封面标记塞进大卡时的尺寸覆盖。 */
    .music-artwork-glyph { display: grid; place-items: center; place-self: center; }

    /* 筛选胶囊在尾槽里，坐的是白卡而不是灰托盘，所以它必须保留自己的凹槽轨道：
       选中态是一枚白色药丸，白底压白底等于看不见选中了哪一个。 */
    .music-artwork-glyph > svg { width: var(--icon-md); height: var(--icon-md); }

    /* The 38px above is the *row* thumbnail size.  Album, artist and playlist
       cards wrap the very same artwork markup, so without this they rendered a
       320px cover inside a 38px box in the corner of a 168px card.  The wrapper
       sets the size; the artwork fills it. */
    .album-artwork, .artist-artwork, .playlist-art { display: block; min-width: 0; }
    .album-artwork .music-artwork,
    .playlist-art .music-artwork {
      width: 100%;
      height: auto;
      aspect-ratio: 1 / 1;
      border-radius: var(--radius-md);
      box-shadow: var(--shadow-1);
    }
    .artist-artwork .music-artwork {
      width: 96px;
      height: 96px;
      border-radius: 50%;
    }
    .album-artwork .music-artwork-glyph > svg,
    .artist-artwork .music-artwork-glyph > svg,
    .playlist-art .music-artwork-glyph > svg { width: var(--icon-xl); height: var(--icon-xl); }

    .album-grid, .artist-grid, .playlist-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(168px, 1fr));
      gap: var(--space-5);
    }
    .artist-grid { grid-template-columns: repeat(auto-fill, minmax(132px, 1fr)); }
    .album-card, .artist-card, .playlist-card { display: grid; gap: var(--space-2); min-width: 0; color: inherit; }
    .artist-card { justify-items: center; text-align: center; }
    .album-card img, .artist-card img, .playlist-card img { width: 100%; height: 100%; object-fit: cover; }
    .album-card strong, .artist-card strong, .playlist-card strong {
      overflow: hidden;
      font-size: var(--type-callout-size);
      font-weight: var(--weight-semibold);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .album-card small, .artist-card small, .playlist-card small, .album-card-meta {
      overflow: hidden;
      color: var(--text-tertiary);
      font-size: var(--type-footnote-size);
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    /* Playlist cards render `.playlist-art`, `.playlist-copy` and
       `.playlist-play`, none of which had any rule at all — the three text lines
       ran together on one line, playlists without a cover showed a bare 16px
       glyph where a tile belonged, and the play affordance sat orphaned on its
       own row. */
    .playlist-card {
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      gap: var(--space-2) var(--space-3);
    }
    .playlist-art { grid-column: 1 / -1; }
    .playlist-copy { display: grid; min-width: 0; gap: 2px; }
    .playlist-copy em {
      color: var(--text-tertiary);
      font-size: var(--type-caption-size);
      font-style: normal;
      font-variant-numeric: tabular-nums;
    }
    .playlist-fallback {
      display: grid;
      aspect-ratio: 1 / 1;
      place-items: center;
      border-radius: var(--radius-md);
      color: rgba(255, 255, 255, 0.9);
      background: linear-gradient(145deg, var(--artwork-g1, var(--artwork-fallback-a)), var(--artwork-g2, var(--artwork-fallback-b)));
      box-shadow: var(--shadow-1);
    }
    .playlist-fallback > svg { width: var(--icon-xl); height: var(--icon-xl); }
    .playlist-play {
      display: grid;
      width: var(--control-height-sm);
      height: var(--control-height-sm);
      place-items: center;
      border-radius: var(--radius-pill);
      color: var(--accent-text);
      background: var(--accent-subtle);
      transition: background-color var(--duration-fast) var(--ease-out);
    }
    .playlist-card:hover .playlist-play { background: var(--accent); color: var(--text-on-accent); }

    .recent-table { display: grid; }
    /* index · artwork · title+artist · when · duration.  The artwork column used
       to be `2fr`, which handed a 38px thumbnail a third of the row and squeezed
       the title beside it; the copy also had no rule, so title and artist ran
       together on one line. */
    .recent-row {
      display: grid;
      grid-template-columns: 36px auto minmax(0, 2fr) minmax(0, 1fr) 64px;
      align-items: center;
      gap: var(--space-3);
      min-height: 52px;
      padding: var(--space-1) var(--space-3);
      border-radius: var(--radius-sm);
      color: inherit;
    }
    .recent-row:hover { background: var(--surface-hover); }
    .recent-row + .recent-row { box-shadow: inset 0 1px 0 var(--divider); }
    .recent-number { color: var(--text-tertiary); font-size: var(--type-footnote-size); font-variant-numeric: tabular-nums; text-align: center; }
    .recent-copy { display: grid; min-width: 0; gap: 1px; }
    .recent-copy strong {
      overflow: hidden;
      font-size: var(--type-callout-size);
      font-weight: var(--weight-medium);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .recent-copy small { overflow: hidden; color: var(--text-tertiary); font-size: var(--type-footnote-size); text-overflow: ellipsis; white-space: nowrap; }
    .recent-time { color: var(--text-tertiary); font-size: var(--type-footnote-size); }
    .recent-duration { color: var(--text-tertiary); font-size: var(--type-footnote-size); font-variant-numeric: tabular-nums; text-align: right; }

    .music-empty { padding: var(--space-10); color: var(--text-tertiary); text-align: center; }
    .music-footnote { padding-top: var(--space-8); }

    @media (max-width: 1023px) {
      .ui-track-head, .ui-track-row { grid-template-columns: minmax(0, 2fr) minmax(0, 1.2fr) 64px 40px; }
      .ui-track-head > span:nth-child(3), .ui-track-head > span:nth-child(4),
      .ui-track-meta ui-track-album, .ui-track-meta ui-track-lyrics { display: none; }
    }
    @media (max-width: 719px) {
      .ui-track-head, .ui-track-row { grid-template-columns: minmax(0, 1fr) 60px; }
      .ui-track-head > span:not(:first-child):not(:nth-child(5)),
      .ui-track-meta ui-track-artist, .ui-track-favorite { display: none; }
      .recent-row { grid-template-columns: 28px auto minmax(0, 1fr) 60px; }
      .recent-time { display: none; }
    }
    """#

    static let script = #"""
    (() => {
      'use strict';
      // 就绪标记全产品只有一个：`img[data-ready="true"]`。此前这里挂在宿主
      // 元素上（`.is-artwork-ready`），首页挂第三种，primitives 又认第四种，
      // 于是同一张封面在不同页面上淡入与否取决于是哪段脚本先跑。
      document.querySelectorAll('.ui-track-art img').forEach(image => {
        const reveal = () => { image.dataset.ready = 'true'; };
        image.addEventListener('load', reveal, { once: true });
        if (image.complete && image.naturalWidth > 0) reveal();
      });

      // Filter and sort act on what the page already delivered rather than
      // issuing another query: a music section is rendered whole, so reordering
      // is a DOM operation, not a round trip.
      const list = document.querySelector('.songs-table, .album-grid, .artist-grid, .recent-table');
      const filterGroup = document.getElementById('music-filter');
      const sortSelect = document.getElementById('music-sort');
      const resultCount = document.getElementById('music-result-count');
      const countUnit = document.body.dataset.countUnit || '项';
      if (list) {
        const rowSelector = '.ui-track-row, .album-card, .artist-card, .recent-row';
        const rows = Array.from(list.querySelectorAll(rowSelector));

        const key = (row, mode) => {
          switch (mode) {
            case 'artist': return row.dataset.sortArtist || '';
            case 'album': return row.dataset.sortAlbum || '';
            case 'duration': return Number(row.dataset.sortDuration || 0);
            case 'mostPlayed': return Number(row.dataset.sortPlayCount || 0);
            case 'recent': return Number(row.dataset.sortRecent || 0);
            case 'workCount': return Number(row.dataset.sortWorkCount || 0);
            default: return row.dataset.sortTitle || '';
          }
        };

        const apply = () => {
          const filter = filterGroup?.querySelector('input[name="music_filter"]:checked')?.value || 'all';
          var visible = 0;
          for (const row of rows) {
            const matches = filter === 'all'
              || (filter === 'favorites' && row.dataset.filterFavorite === 'true')
              || (filter === 'withLyrics' && row.dataset.filterLyrics === 'true')
              || (filter === 'unmatched' && row.dataset.filterUnmatched === 'true');
            row.hidden = !matches;
            if (matches) visible += 1;
          }
          if (sortSelect) {
            // 值形如 `title:asc`：排序键与方向来自同一个选择。
            const [mode, direction] = sortSelect.value.split(':');
            const descending = direction === 'desc';
            // Numeric keys default to "most first"; text keys to A–Z. The toggle
            // flips whichever of those is natural for the key, so the button
            // always means the same thing to the reader.
            const numeric = ['duration', 'mostPlayed', 'recent', 'workCount'].includes(mode);
            const sorted = rows.slice().sort((a, b) => {
              const left = key(a, mode);
              const right = key(b, mode);
              let result;
              if (numeric) result = Number(right) - Number(left);
              else result = String(left).localeCompare(String(right), 'zh-Hans');
              return descending ? -result : result;
            });
            // Appending in order moves rows without disturbing the table head,
            // which is not part of `rows` and therefore stays first.
            for (const row of sorted) list.append(row);
          }
          // 计数落在页头副标题里，与客户端的 "… · N 首" 是同一句话。
          if (resultCount) resultCount.textContent = ` · ${visible} ${countUnit}`;
        };

        filterGroup?.addEventListener('change', apply);
        sortSelect?.addEventListener('change', apply);
        apply();
      }
    })();
    """#
}
