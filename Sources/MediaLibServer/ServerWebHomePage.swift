import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 认证 Web 首页。首页按内容消费方式分区：影视使用横向封面架，音乐使用紧凑榜单，
/// 照片使用独立方形预览；不同媒体类型不会再进入同一个自适应卡片网格。
enum ServerWebHomePage {
    static func render(
        serverName: String,
        snapshot: ServerLibrarySnapshot,
        csrfToken: String,
        showAdministration: Bool = false,
        recentlyAdded: [ServerLibraryItem] = [],
        highRated: [ServerLibraryItem] = [],
        // 推荐栏目的顺序来自客户端首页（`HomeRecommendationSnapshotStore`）。
        //
        // 这里没有默认值，和 `sidebarExtras` 同样的理由：漏传就该是编译错误，而不是
        // 悄悄回到"网页自己再推导一遍"——那正是两端片单对不上的来源。名单为空是
        // 一个**运行时**事实（App 没运行 / 名单过期 / 纯服务端部署），每一栏各自回落。
        recommendations: ServerHomeRecommendations,
        // 分类由路由从 `libraryCategoriesProvider` 取来，首页**不再**自己推导。
        //
        // 从前这里从 `snapshot.summary.countsByType` 现搭一份，而那份快照当时是
        // 含远程的：Emby 条目被算进电影／剧集／动漫，首页侧栏的数字比其它页面大；
        // 只存在于远程的类型还会长出一个本地并不存在的分类入口，而
        // `/category/<type>` 是拿本地分类列表校验的——点进去就是 404。
        // 一级分类只能有一个真相来源。
        categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras
    ) -> String {
        let items = snapshot.items.items
        // 客户端给了名单就用它，没给才回落到快照推导。逐栏判断而不是整页判断：
        // 客户端首页可以只发布其中几栏（比如库里根本没有照片）。
        func preferring(_ clientItems: [ServerLibraryItem], else fallback: @autoclosure () -> [ServerLibraryItem]) -> [ServerLibraryItem] {
            clientItems.isEmpty ? fallback() : clientItems
        }
        let continueWatching = items.filter {
            !$0.isMusic && !$0.isPhoto && ($0.userState?.progress ?? 0) > 0 && !($0.userState?.isWatched ?? false)
        }
        let continuingIDs = Set(continueWatching.map(\.id))
        let series = preferring(
            recommendations.series.filter { !continuingIDs.contains($0.id) },
            else: items.filter { $0.isSeries && !continuingIDs.contains($0.id) }
        )
        let videos = items.filter {
            !$0.isMusic && !$0.isPhoto && !$0.isSeries && !continuingIDs.contains($0.id)
        }
        let music = items.filter(\.isMusic)
        let photos = items.filter(\.isPhoto)
        let musicShelf = preferring(recommendations.music, else: music)
        let photoShelf = preferring(recommendations.photos, else: photos)
        // Banner 轮播是客户端的「每日推荐」，不是"手边第一批卡片"。
        //
        // 网页此前把继续观看 + 剧集 + 视频接起来取前七条当 hero，于是首页最大的那块
        // 画面讲的是"最近更新过的条目"，而客户端同一个位置讲的是当日精选。同一个
        // 首页的同一个位置不该有两种含义。
        let featuredCandidates: [ServerLibraryItem] = preferring(
            recommendations.banner,
            else: {
                var seen = Set<String>()
                return (continueWatching + series + videos).filter { seen.insert($0.id).inserted }.prefix(7).map { $0 }
            }()
        )
        let featured = featuredCandidates.first
        // Hero already owns the largest first-paint artwork request. Do not make
        // the first shelf ask for a second rendition of that same poster when
        // another recommendation is available; it wastes the cold thumbnail
        // workers and reduces the useful variety on the home page.
        let featuredID = featured?.id
        func shelfItems(_ candidates: [ServerLibraryItem]) -> [ServerLibraryItem] {
            guard let featuredID else { return candidates }
            let withoutFeatured = candidates.filter { $0.id != featuredID }
            return withoutFeatured.isEmpty ? candidates : withoutFeatured
        }

        // 栏目与顺序逐条对齐客户端 `HomeModuleKind.defaultOrder`。
        //
        // 网页从前多两个客户端没有的栏目：「电影与视频」（和「最近添加」讲的是同
        // 一批内容）和「资料库构成」（和统计四格 + 运行状态重复），顺序也各排各
        // 的。两端说的是同一个首页时，不该有两套编排。
        //
        // 每一栏都只在真的有内容时出现——一个空的「想看」比没有这一栏更糟，这也
        // 是客户端 `isHomeModuleVisible` 的规则。
        let recentlyPlayed = MediaPlaybackRecencyPolicy.recentNonMusicItems(items, limit: 12)
        let watchlist = items.filter(\.userPreference.isWatchlist)
        let favorites = items.filter(\.userPreference.isFavorite)
        let continueListening = music.filter { ($0.userState?.progress ?? 0) > 0 && !($0.userState?.isWatched ?? false) }

        var contentSections: [String] = []
        var eagerBudget = 3
        func shelf(
            _ title: String,
            _ subtitle: String,
            _ source: [ServerLibraryItem],
            kind: String,
            limit: Int = 12,
            moreTitle: String? = nil,
            morePath: String? = nil
        ) {
            let picked = Array(shelfItems(source).prefix(limit))
            guard !picked.isEmpty else { return }
            // 只有首屏那一排值得抢解码队列，后面的交给浏览器自己排。
            let eager = eagerBudget
            eagerBudget = 0
            contentSections.append(videoSection(
                title: title, subtitle: subtitle, items: picked, kind: kind,
                eagerArtworkCount: eager, moreTitle: moreTitle, morePath: morePath
            ))
        }

        // 每一栏都要有出口，一条不落。「剧集推荐」与「继续观看」此前是仅有的两条
        // 死胡同：看完这一排就只能回侧栏重新找。
        shelf(
            "剧集推荐", "适合追下去的几部", series, kind: "series",
            moreTitle: "全部剧集", morePath: "/category/\(ServerWebLibraryPage.Scope.videoGroupID)"
        )
        shelf(
            "继续观看 · 剧集", "从上次停下的地方接着看", continueWatching, kind: "continue", limit: 8,
            moreTitle: "正在观看", morePath: "/watching"
        )
        shelf("最近播放", "你最近看过的", recentlyPlayed, kind: "recent", moreTitle: "播放历史", morePath: "/history")
        shelf("想看", "先收着，等你有空", watchlist, kind: "watchlist", moreTitle: "想看清单", morePath: "/watchlist")
        shelf("收藏", "你喜欢的那些", favorites, kind: "favorites", moreTitle: "我的收藏", morePath: "/favorites")
        if !musicShelf.isEmpty {
            contentSections.append(musicSection(items: Array(musicShelf.prefix(16))))
        }
        shelf("继续听", "还没听完的", continueListening, kind: "listening", moreTitle: "进入音乐", morePath: "/music/songs")
        shelf(
            "最近添加 · 剧集", "刚加进来的新内容", recentlyAdded, kind: "added",
            moreTitle: "全部视频", morePath: "/category/\(ServerWebLibraryPage.Scope.videoGroupID)"
        )
        shelf(
            "高分精选", "评价最好的几部", highRated, kind: "rated",
            moreTitle: "全部视频", morePath: "/category/\(ServerWebLibraryPage.Scope.videoGroupID)"
        )
        if !photoShelf.isEmpty {
            contentSections.append(photoSection(items: Array(photoShelf.prefix(12))))
        }
        // 「运行状态」不再是页尾单独一栏：它和页首那条四格讲的是同一件事，现在
        // 合成开头的一块概览（见 `overviewSection`）。
        // 空库首页此前只剩一个页头和一块全 0 的概览：没有一栏会渲染（`shelf()` 在
        // 无内容时直接 return），也没有任何一句话告诉读者下一步该做什么。刚装好
        // 服务端的人第一次打开看到的正是这一屏。
        let pageContent = contentSections.isEmpty
            ? ServerWebUI.emptyState(
                icon: .source,
                title: "资料库还是空的",
                message: "添加一个媒体源，扫描完成后你的影片、剧集和音乐就会出现在这里。",
                action: "去添加媒体源",
                actionHref: "/sources"
            )
            : contentSections.joined(separator: "\n")
        let featuredContent = featuredHero(featuredCandidates)
        // 概览三格数的是**整个资料库**，不是这一页的卡片样本。
        //
        // 它们从前数的是 `snapshot.items.items`，而那是一份最多 60 条的首屏卡片
        // 样本：五千条视频的库在「资料库概览」里显示「视频 42」，紧挨着的「媒体
        // 总数」却是五千——同一块里两个数字互相打脸。计数只能来自 `countsByType`。
        let countsByType = snapshot.summary.countsByType
        let videoCount = countsByType.reduce(0) { total, entry in
            // 与「视频」分组同口径：音乐、照片、分集、保险库不算，录像归相册。
            guard entry.key != MediaType.music.rawValue,
                  entry.key != MediaType.photo.rawValue,
                  entry.key != MediaType.episode.rawValue,
                  entry.key != MediaType.homeVideo.rawValue,
                  entry.key != MediaType.privateCollection.rawValue
            else { return total }
            return total + entry.value
        }
        let overview = overviewSection(
            snapshot: snapshot,
            videoCount: videoCount,
            musicCount: countsByType[MediaType.music.rawValue] ?? 0,
            photoCount: countsByType[MediaType.photo.rawValue] ?? 0,
            showAdministration: showAdministration
        )
        let sidebar = ServerWebNavigation.render(
            active: .home,
            showAdministration: showAdministration,
            note: .library,
            categories: categories,
            extras: sidebarExtras
        )

        let content = """
        \(ServerWebPageHeader.render(
            icon: .home,
            eyebrow: "Welcome back",
            // 服务端不知道读者在哪个时区，所以这里只给一句与时段无关的兜底；
            // `home.js` 拿浏览器本地时间把它换成「早上好」这一族（时段划分与客户端
            // `HomeView.greeting` 逐字一致）。服务端按自己的时钟写死"今晚"，对时差
            // 另一头的人就是错的，而且这一句还会被缓存给所有人。
            title: "为你精选了一份片单",
            subtitle: "新加进来的、看到一半的，还有你收藏的。",
            countID: "home-count",
            initialCount: snapshot.summary.totalItemCount,
            // 搜索框与其它页面同一个构件，而不是首页独有的一颗"搜索全部媒体"按钮。
            // 页头尾槽是搜索固定的位置，读者不该在首页先点一颗按钮、跳到另一页、
            // 再在那里找到输入框——同一个动作在同一个位置就该长同一个样子。
            search: ServerWebUI.searchField(
                id: "home-query",
                label: "搜索全部媒体",
                placeholder: "搜索全部媒体",
                action: "/search"
            ),
            titleID: "home-title"
        ))
        \(featuredContent)
        \(overview)
        <div class="home-sections">\(pageContent)</div>
        
        """
        return ServerWebDocument.render(
            title: "首页",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/home.css"],
            pageScripts: ["/assets/overlays.js", "/assets/home.js"],
            bodyClass: "home-document",
            tint: .editorial
        )
    }


    // MARK: - Sections

    private static func videoSection(
        title: String,
        subtitle: String,
        items: [ServerLibraryItem],
        kind: String,
        eagerArtworkCount: Int = 0,
        moreTitle: String? = nil,
        morePath: String? = nil
    ) -> String {
        // 卡片保持它自己的形状，一排放不满就放不满。
        //
        // 这里曾经在"少于四条"时切到一种撑满整行的宽卡。那是把空白当成需要填上
        // 的洞——可读者看到的是一张为了占满一行而变形的封面，比留白更糟。客户端
        // 从来不这么做：它的每一栏都是固定尺寸的卡片左对齐排开，剩下的就是剩下的。
        //
        // 真正该分情况的是**卡片的形状**，不是要不要拉伸：
        //   继续观看 → 横版剧集截图（16:9），文案压在画面上
        //   音乐     → 方形专辑封面
        //   其余     → 2:3 海报墙
        let variant = shelfVariant(for: kind)
        let cards = items.enumerated().map { index, item in
            streamCard(item, kind: kind, variant: variant, prioritizeArtwork: index < eagerArtworkCount)
        }.joined()
        let track = #"<div class="ui-shelf \#(variant.shelfClass)">\#(cards)</div>"#
        // 每一栏都指向它自己的完整列表：一排 12 张卡片之后必须有路可走，
        // 否则读者只能回到侧栏重新找。出口挂在标题上（`href:`），不再是行尾那条
        // 独立的文本链接——`moreTitle` 现在只作为链接的可访问补充说明存在。
        let head = ServerWebUI.sectionHeader(
            title,
            subtitle: subtitle,
            icon: sectionIcon(for: kind),
            titleID: "home-\(kind)-title",
            href: morePath
        )
        return """
        <section class="ui-section" aria-labelledby="home-\(kind)-title"\(sectionTint(for: kind).attribute)>
          \(head)
          \(track)
        </section>
        """
    }

    /// 一栏货架里卡片的形状。
    ///
    /// 客户端按内容类型给不同的形状：正在看的剧集用横版截图（一眼看出演到哪儿），
    /// 音乐用方形专辑封面，其余用竖版海报墙。三种形状只影响画框比例与列宽，
    /// 排布规则（固定列宽、左对齐、横向滚动）是同一套。
    fileprivate enum ShelfVariant {
        case poster
        case landscape
        case square

        var shelfClass: String {
            switch self {
            case .poster: return "home-shelf-poster"
            case .landscape: return "home-shelf-landscape"
            case .square: return "home-shelf-square"
            }
        }

        var posterClass: String {
            switch self {
            case .poster: return "ui-poster"
            case .landscape: return "ui-poster ui-poster-wide"
            case .square: return "ui-poster ui-poster-square"
            }
        }
    }

    private static func shelfVariant(for kind: String) -> ShelfVariant {
        switch kind {
        case "continue": return .landscape
        case "listening": return .square
        default: return .poster
        }
    }

    /// 区块头的图标。
    ///
    /// 九个货架此前只有标题和副标题在区分它们——同样的字号、同样的间距、同样一排
    /// 海报，滚过去像是同一栏重复了六遍。一枚小底板给每一栏一个可以扫到的锚点。
    /// 区块头的识别色。
    ///
    /// 十条货架此前只有图标在区分它们，而图标底板全站同一个淡蓝——滚下去仍然是
    /// 同一个颜色重复十遍。色相按内容语义分派：视频类留给蓝、音乐紫、"编辑口径"
    /// 的几栏（最近添加、高分精选）走琥珀、收藏与想看走玫红。
    ///
    /// 只作用在底板与胶囊这类非交互面上；这一栏里的按钮和链接仍然是强调蓝。
    private static func sectionTint(for kind: String) -> ServerWebIcon.Tint {
        switch kind {
        case "listening": return .music
        case "watchlist", "favorites": return .vault
        case "added", "rated": return .editorial
        case "recent": return .admin
        default: return .video
        }
    }

    private static func sectionIcon(for kind: String) -> ServerWebIcon {
        switch kind {
        case "series": return .series
        case "continue": return .play
        case "recent": return .history
        case "watchlist": return .bookmark
        case "favorites": return .heart
        case "listening": return .music
        case "added": return .sparkles
        case "rated": return .star
        default: return .film
        }
    }

    private static func streamCard(
        _ item: ServerLibraryItem,
        kind: String,
        variant: ShelfVariant = .poster,
        prioritizeArtwork: Bool = false
    ) -> String {
        let year = item.year.map(String.init) ?? item.type
        // Resume progress is part of what makes a "continue watching" shelf
        // useful, so it stays on the card rather than being hidden by a global
        // metadata rule the way the previous shell did it.
        let playbackState: String = {
            // 「继续听」不报进度。
            //
            // 听歌听到一半是常态，不是一件待办；把"继续观看 · 37%"套到曲目上，读
            // 起来像在催人听完。客户端那一栏也只给封面和曲名。
            guard kind != "listening" else { return "" }
            guard let state = item.userState else { return "" }
            if state.isWatched { return #"<span class="ui-media-meta">已看完</span>"# }
            guard state.progress > 0 else { return "" }
            let percent = Int((state.progress * 100).rounded())
            return #"""
            <span class="ui-media-meta">继续观看 · \#(percent)%</span>
            <span class="ui-progress home-card-progress"><span class="home-card-progress-fill" data-progress="\#(percent)"></span></span>
            """#
        }()
        // 专辑封面本来就是方的。把它塞进 2:3 的竖版海报框里，只能中心裁切成一条
        // 窄带——上下各切掉四分之一，正好是封面上放标题和艺术家名的地方。音乐一
        // 律用方形框，无论它出现在哪一排。
        let shape: ShelfVariant = item.isMusic ? .square : variant
        let art = shape == .landscape
            ? landscapeArtwork(item, prioritize: prioritizeArtwork)
            : artwork(
                item,
                cssClass: shape.posterClass,
                size: shape == .square ? 320 : 640,
                prioritize: prioritizeArtwork
            )
        // 海报下面只写片名和这张卡自己的状态：分类与年份对每张卡都一样，在海报墙
        // 上区分不了任何东西。
        let copy = """
        <span class="ui-media-title" title="\(escape(item.title))">\(escape(item.title))</span>\(playbackState)
        """
        guard let encodedID = ServerWebURL.pathSegment(item.id) else {
            return #"<article class="ui-media-card">\#(art)\#(copy)</article>"#
        }
        // 封面就是"播放"。音乐交给常驻底栏（`data-music-play`，外壳在捕获阶段
        // 接管点击，`href` 只是无脚本时的退路）；影视直接进播放页。
        if item.isMusic {
            let musicAttributes = #" data-music-play="\#(encodedID)" data-music-title="\#(escape(item.title))" data-music-subtitle="\#(escape(year))""#
            return """
            <article class="ui-media-card">
              <a href="/play/\(encodedID)#play"\(musicAttributes) aria-label="播放音乐 \(escape(item.title))">\(art)</a>
              \(copy)
            </article>
            """
        }
        let destination = item.isSeries ? "/series/\(encodedID)/play" : "/item/\(encodedID)#play"
        let action = item.isSeries ? "播放剧集" : "播放"
        // 横版卡的文案压在剧照上（和 banner 同一种读法），所以它排在链接**内部**、
        // 画面之上；海报墙的文案在框外，排在链接后面。
        if shape == .landscape {
            return """
            <article class="ui-media-card">
              <a href="\(destination)" aria-label="\(action) \(escape(item.title))">\(art)\
              <span class="home-landscape-copy">\(copy)</span></a>
            </article>
            """
        }
        return """
        <article class="ui-media-card">
          <a href="\(destination)" aria-label="\(action) \(escape(item.title))">\(art)</a>
          \(copy)
        </article>
        """
    }

    /// 横版剧集截图。
    ///
    /// 「继续观看」用的是画面而不是海报：读者要认的是"我看到哪儿了"，一张剧照
    /// 比一张宣传海报更接近那件事，客户端也是这么做的。
    ///
    /// 取图顺序：横版剧照 → 竖版海报（裁切上移，居中裁会稳定地切掉主体的头）
    /// → 取色兜底图。`?size=640` 是横版框在货架尺寸下够用的桶。
    private static func landscapeArtwork(_ item: ServerLibraryItem, prioritize: Bool) -> String {
        let palette = ServerWebArtworkPalette.token(for: item.id, context: .poster)
        let cssClass = "ui-poster ui-poster-wide"
        guard let encodedID = ServerWebURL.pathSegment(item.id),
              item.artworkAvailable || item.backdropAvailable
        else {
            return """
            <span class="\(cssClass) placeholder" data-artwork-palette="\(palette)" role="img" \
            aria-label="\(escape(item.type)) 占位封面"><span class="artwork-fallback" aria-hidden="true"></span></span>
            """
        }
        let kindPath = item.backdropAvailable ? "backdrop" : "poster"
        let orientation = item.backdropAvailable ? "landscape" : "portrait"
        let loading = prioritize ? "eager" : "lazy"
        let priority = prioritize ? #" fetchpriority="high""# : ""
        return """
        <span class="\(cssClass)" data-artwork-palette="\(palette)" data-artwork-fallback="true" \
        data-artwork-orientation="\(orientation)">\
        <span class="artwork-fallback" aria-hidden="true"></span>\
        <img src="/api/v1/images/\(encodedID)/\(kindPath)?size=640" alt="" loading="\(loading)" \
        decoding="async"\(priority)></span>
        """
    }

    /// The front page's hero.
    ///
    /// Built to the same recipe the App Store's Discover page uses: a 16:9 card
    /// with a 17px radius, a directional scrim, the copy set bottom-left, dots
    /// underneath — and, behind all of it, an out-of-frame ambient wash made from
    /// the slide's own artwork, blurred and scaled until it is pure colour and
    /// fading into the page background.  That wash is what makes the banner feel
    /// lit rather than pasted on.
    ///
    /// One deliberate difference: the App Store passes each slide's image through
    /// an inline `style="--background-image: url(…)"`.  The page CSP here forbids
    /// inline styles outright, so the wash is a real `<img>` positioned and
    /// blurred by a class instead. It requests the smallest thumbnail bucket —
    /// a 20px blur destroys the detail anyway.
    ///
    /// Every slide ships a real `src`: an earlier version emitted `data-src` for
    /// slides two and up and nothing ever read it, so those slides rendered
    /// permanently empty.  Slides past the first are `loading="lazy"`, which gets
    /// the same deferral from the browser for free.
    /// 拉长的翻页箭头。
    ///
    /// 常规图标是 24×24 的方格，装进一个 420px 高的按钮里，看得见的仍然只有中间那
    /// 个 20px 的小尖角——把按钮加高完全不改变观感。这里换成一个瘦长 viewBox 的
    /// 路径，笔画用 `vector-effect` 保持不随拉伸变粗。
    private static func tallChevron(pointsLeft: Bool) -> String {
        let path = pointsLeft ? "M17 6 6 32l11 26" : "M7 6l11 26L7 58"
        return """
        <svg class="hero-arrow-glyph" viewBox="0 0 24 64" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="\(path)" vector-effect="non-scaling-stroke"></path></svg>
        """
    }

    private static func featuredHero(_ items: [ServerLibraryItem]) -> String {
        guard !items.isEmpty else { return "" }
        let renderable = items.compactMap { item -> (item: ServerLibraryItem, id: String)? in
            ServerWebURL.pathSegment(item.id).map { (item, $0) }
        }
        guard !renderable.isEmpty else { return "" }

        let ambient = renderable.enumerated().map { index, entry -> String in
            let palette = ServerWebArtworkPalette.token(for: entry.item.id, context: .poster)
            let current = index == 0 ? " is-current" : ""
            guard entry.item.artworkAvailable || entry.item.backdropAvailable else {
                return #"<span class="hero-ambient-layer\#(current)" data-artwork-palette="\#(palette)" aria-hidden="true"></span>"#
            }
            let kind = entry.item.backdropAvailable ? "backdrop" : "poster"
            return """
            <span class="hero-ambient-layer\(current)" data-artwork-palette="\(palette)" aria-hidden="true">\
            <img src="/api/v1/images/\(entry.id)/\(kind)?size=160" alt="" loading="\(index == 0 ? "eager" : "lazy")" decoding="async"></span>
            """
        }.joined()

        let slides = renderable.enumerated().map { index, entry -> String in
            let item = entry.item
            let playable = item.isSeries ? "/series/\(entry.id)/play" : "/play/\(entry.id)#play"
            // 客户端的 meta 行是「★ 评分 · 类型 · 年份」。服务端的卡片模型没有
            // 评分字段，所以这里只说得出类型和年份——宁可少一节，也不要为了凑
            // 满一行去编一个数字出来。看过一半的条目改说进度，那是比"2026 ·
            // movie"更有用的一句话。
            let progressPercent = item.userState.map { Int(($0.progress * 100).rounded()) } ?? 0
            var metaParts = [item.type, item.year.map(String.init)].compactMap { $0 }
            if progressPercent > 0, item.userState?.isWatched != true {
                metaParts.append("已看 \(min(progressPercent, 99))%")
            }
            let isWatchlist = item.userPreference.isWatchlist
            let watchlistLabel = isWatchlist ? "已想看" : "加入想看"
            let watchlistIcon = isWatchlist ? ServerWebIcon.bookmarkFilled : ServerWebIcon.bookmark
            return """
            <article class="hero-slide" id="hero-panel-\(index)" role="tabpanel" aria-label="\(escape(item.title))"\(index == 0 ? "" : " aria-hidden=\"true\"")>
              \(featuredArtwork(item, prioritize: index == 0))
              <span class="hero-veil" aria-hidden="true"></span>
              <div class="hero-copy">
                <p class="hero-badge">\(ServerWebIcon.starFilled.html(size: .xs))<span>今日精选</span></p>
                <h2 class="hero-title">\(escape(item.title))</h2>
                <p class="hero-meta">\(escape(metaParts.joined(separator: " · ")))</p>
                <div class="hero-actions">
                  <a class="ui-btn ui-btn-on-media-strong" href="\(playable)">\(ServerWebIcon.play.html(size: .sm))<span>立即播放</span></a>
                  <button class="ui-btn ui-btn-on-media" type="button" data-hero-watchlist="\(entry.id)" \
            aria-pressed="\(isWatchlist)">\(watchlistIcon.html(size: .sm))<span>\(watchlistLabel)</span></button>
                </div>
              </div>
              <a class="hero-mobile-play-link" href="\(playable)" aria-label="播放 \(escape(item.title))"></a>
            </article>
            """
        }.joined()

        let dots = renderable.enumerated().map { index, _ in
            let selected = index == 0
            return """
            <li class="hero-dot\(selected ? " is-current" : "")" role="tab" aria-selected="\(selected)" \
            aria-controls="hero-panel-\(index)" aria-label="第 \(index + 1) 张" tabindex="\(selected ? 0 : -1)" \
            data-hero-dot="\(index)"><span class="visually-hidden">第 \(index + 1) 张</span></li>
            """
        }.joined()
        let pagination = renderable.count > 1
            ? #"""
            <nav class="hero-pagination" aria-label="精选分页">\#
            <ol class="hero-dots" role="tablist">\#(dots)</ol></nav>
            """#
            : ""
        let arrows = renderable.count > 1
            ? """
            <button class="hero-arrow hero-arrow-previous" type="button" data-hero-previous aria-label="上一张推荐">\(tallChevron(pointsLeft: true))</button>
            <button class="hero-arrow hero-arrow-next" type="button" data-hero-next aria-label="下一张推荐">\(tallChevron(pointsLeft: false))</button>
            """
            : ""

        return """
        <section class="hero-region app-bleed" aria-label="为你精选" data-hero-carousel data-hero-count="\(renderable.count)">
          <div class="hero-ambient" aria-hidden="true">\(ambient)</div>
          <div class="hero-frame">
            <div class="hero-viewport">
              <div class="hero-track" data-hero-track>\(slides)</div>
              \(pagination)
            </div>
            \(arrows)
          </div>
        </section>
        """
    }

    /// 一块概览，不是两条一样的四格。
    ///
    /// 首页此前在同一屏里画了两遍四格指标条：顶部的「资料库概览」（总数/视频/
    /// 音乐/照片）和页尾的「运行状态」（分类/正在观看/已看完/已标记）。两者的
    /// 版式、图标底板、字号完全一致，只有数字不同——滚到页尾会以为自己滚回了
    /// 页首。而且它们各自只有四个子项却用 `auto-fit` 铺满 1440px，每一格里有
    /// 250px 是空的。
    ///
    /// 合成一块 bento：媒体总数占大格（它是这一屏真正的头条数字），其余七项填
    /// 小格。栏目数量因此比客户端的 `HomeModuleKind.defaultOrder` 少一个——这是
    /// 有意的偏离，记在 `doc/MediaLIB_Web设计系统.md` §9.4。
    ///
    /// 它只汇总当前账号**看得见**的东西。这里不放服务器负载或磁盘信息——首页是
    /// 内容页，运维细节在 `/status`。
    private static func overviewSection(
        snapshot: ServerLibrarySnapshot,
        videoCount: Int,
        musicCount: Int,
        photoCount: Int,
        showAdministration: Bool
    ) -> String {
        let items = snapshot.items.items
        let inProgress = items.filter { ($0.userState?.progress ?? 0) > 0 && !($0.userState?.isWatched ?? false) }.count
        let watched = items.filter { $0.userState?.isWatched == true }.count
        let marked = items.filter { $0.userPreference.isFavorite || $0.userPreference.isWatchlist }.count

        // 每一格都通往它代表的那批内容。此前两条指标条上的八个数字全是死的——
        // 一个写着「已看完 12」却点不动的格子，比不写这个数字更让人别扭。
        // 每一格自带识别色。六个格子此前是六个一模一样的白盒配同一枚灰图标——
        // 这是全首页唯一一块拿不到封面颜色的区域，因此也是"素"感最集中的地方。
        let cells: [(title: String, value: Int, icon: ServerWebIcon, tint: ServerWebIcon.Tint, href: String?)] = [
            ("视频", videoCount, .film, .video, "/category/\(ServerWebLibraryPage.Scope.videoGroupID)"),
            ("音乐", musicCount, .music, .music, "/music/songs"),
            ("照片", photoCount, .photos, .photo, "/photos"),
            ("正在观看", inProgress, .play, .editorial, "/watching"),
            ("已看完", watched, .checkCircle, .admin, "/watched"),
            ("已标记", marked, .heart, .vault, "/favorites")
        ]
        let tiles = cells.map { cell -> String in
            let inner = ServerWebIcon.tile(cell.icon, size: .sm, tone: .tint, extraClass: "home-overview-icon")
                + #"<span class="home-overview-copy"><small>\#(escape(cell.title))</small>"#
                + #"<strong class="t-numeric">\#(max(cell.value, 0))</strong></span>"#
            guard let href = cell.href else {
                return #"<div class="home-overview-cell"\#(cell.tint.attribute)>\#(inner)</div>"#
            }
            return #"<a class="home-overview-cell home-overview-link" href="\#(href)" data-native-navigation="true"\#(cell.tint.attribute)>\#(inner)</a>"#
        }.joined()

        return """
        <section class="ui-section home-overview-section" aria-labelledby="home-overview-title" data-tint="editorial">
          \(ServerWebUI.sectionHeader(
            "资料库概览",
            subtitle: "你的资料库里有些什么",
            icon: .library,
            titleID: "home-overview-title",
            moreLabel: showAdministration ? "仪表盘" : nil,
            moreHref: showAdministration ? "/status" : nil
          ))
          <div class="home-overview">
            <div class="home-overview-lead" data-tint="editorial">
              <small>媒体总数</small>
              <strong class="t-numeric">\(max(snapshot.summary.totalItemCount, 0))</strong>
              <span class="home-overview-lead-note">条可访问媒体</span>
            </div>
            <div class="home-overview-grid">\(tiles)</div>
          </div>
        </section>
        """
    }

    /// A compact read on what the server currently holds.
    ///
    /// It is intentionally aggregate-only: counts by category, no item titles, no
    /// paths, nothing that would put library contents into a shared surface.
    // 「资料库构成」（分类占比条形图）已删除：客户端首页没有这一栏，而它说的事
    // 已经被统计四格和「运行状态」讲过两遍了。

    private static func musicSection(items: [ServerLibraryItem]) -> String {
        let recommendationItems = Array(items.prefix(12))
        let rows = recommendationItems.enumerated().map { index, item in
            let art = artwork(item, cssClass: "track-art", size: 160)
            let year = item.year.map(String.init) ?? "音乐"
            let details: String
            if let encodedID = ServerWebURL.pathSegment(item.id) {
                // 整行都是"播放"，包括封面。以前封面链到详情页，于是点封面会
                // 离开首页去看一个只用来说"播放在底栏进行"的页面。
                let musicAttributes = #" data-music-play="\#(encodedID)" data-music-title="\#(escape(item.title))" data-music-subtitle="\#(escape(year))""#
                details = """
                <a class="track-main" href="/play/\(encodedID)#play"\(musicAttributes) aria-label="播放音乐 \(escape(item.title))">\(art)<span class="track-copy"><strong>\(escape(item.title))</strong><small>\(escape(year))</small></span></a>
                <span class="track-play" aria-hidden="true">\(ServerWebIcon.play.html(size: .sm))</span>
                """
            } else {
                details = #"<div class="track-main">\#(art)<span class="track-copy"><strong>\#(escape(item.title))</strong><small>\#(escape(year))</small></span></div>"#
            }
            return #"<article class="track-row"><span class="track-index t-numeric">\#(index + 1)</span>\#(details)</article>"#
        }.joined()
        let playlistCards = [
            ("今日推荐", "根据资料库最近内容整理", Array(recommendationItems.prefix(4))),
            ("深夜循环", "适合连续聆听的单曲", Array(recommendationItems.dropFirst(4).prefix(4)))
        ].map { title, subtitle, covers in
            let ids = covers.compactMap { ServerWebURL.pathSegment($0.id) }
            let action = ids.first.map { "/play/\($0)#play" } ?? "/music/songs"
            // 歌单封面不是任何一首歌的封面——用四张真封面拼一个马赛克，会让人以为
            // 点进去就是那四首。这里改用客户端那套确定性取色兜底图：同一个歌单
            // 永远是同一组颜色，和它装着什么无关。
            let palette = ServerWebArtworkPalette.token(for: title, context: .music)
            let musicAttributes = ids.first.map {
                #" data-music-play="\#($0)" data-music-title="\#(escape(title))" data-music-subtitle="\#(escape(subtitle))""#
            } ?? ""
            return """
            <a class="home-playlist-card" href="\(action)"\(musicAttributes) aria-label="播放\(escape(title))">
              <span class="home-playlist-art" data-artwork-palette="\(palette)" aria-hidden="true">\(ServerWebIcon.music.html(size: .xl))</span>
              <span class="home-playlist-copy"><strong>\(escape(title))</strong><small>\(escape(subtitle))</small><em class="t-numeric">\(covers.count) 首</em></span>
            </a>
            """
        }.joined()
        return """
        <section class="ui-section" aria-labelledby="home-music-title" data-tint="music">
          \(ServerWebUI.sectionHeader(
            "音乐推荐", subtitle: "今天听点什么", icon: .music,
            titleID: "home-music-title", href: "/music/songs"
          ))
          <div class="home-music-layout">
            <div class="music-chart">\(rows)</div>
            <div class="home-playlist-stack">\(playlistCards)</div>
          </div>
        </section>
        """
    }

    private static func photoSection(items: [ServerLibraryItem]) -> String {
        let cards = items.map { item in
            let art = artwork(item, cssClass: "photo-art", size: 320)
            guard let encodedID = ServerWebURL.pathSegment(item.id) else {
                return #"<article class="photo-tile">\#(art)<strong>\#(escape(item.title))</strong></article>"#
            }
            return #"<a class="photo-tile" href="/photo/\#(encodedID)" aria-label="查看照片 \#(escape(item.title))">\#(art)<strong>\#(escape(item.title))</strong></a>"#
        }.joined()
        return """
        <section class="ui-section" aria-labelledby="home-photo-title" data-tint="photo">
          \(ServerWebUI.sectionHeader(
            "最近照片", subtitle: "你最近拍的", icon: .photos,
            titleID: "home-photo-title", href: "/photos"
          ))
          <div class="photo-shelf">\(cards)</div>
        </section>
        """
    }

    /// Hero art for the featured banner.
    ///
    /// A banner is a landscape frame, so it asks for the landscape asset first:
    /// `backdropAvailable` means the item has an authorised wide still, which
    /// fills the frame as shot.  Only when there is none does it fall back to the
    /// portrait poster, and that one is marked so the crop can be biased upward —
    /// centre-cropping a 2:3 poster into a banner reliably cuts off the subject's
    /// head.  Both go through the same per-item authorised image endpoint.
    private static func featuredArtwork(_ item: ServerLibraryItem, prioritize: Bool) -> String {
        let palette = ServerWebArtworkPalette.token(for: item.id, context: .poster)
        guard let encodedID = ServerWebURL.pathSegment(item.id), item.artworkAvailable || item.backdropAvailable else {
            return #"<span class="hero-art placeholder" data-artwork-palette="\#(palette)" role="img" aria-label="\#(escape(item.type)) 占位封面"><span class="artwork-fallback" aria-hidden="true"></span></span>"#
        }
        let kind = item.backdropAvailable ? "backdrop" : "poster"
        let orientation = item.backdropAvailable ? "landscape" : "portrait"
        let loading = prioritize ? "eager" : "lazy"
        let priority = prioritize ? #" fetchpriority="high""# : ""
        return """
        <span class="hero-art" data-artwork-palette="\(palette)" data-artwork-fallback="true" data-artwork-orientation="\(orientation)">\
        <span class="artwork-fallback" aria-hidden="true"></span>\
        <img src="/api/v1/images/\(encodedID)/\(kind)?size=1024" alt="" loading="\(loading)" decoding="async"\(priority)></span>
        """
    }

    private static func artwork(_ item: ServerLibraryItem, cssClass: String, size: Int, prioritize: Bool = false) -> String {
        let palette = ServerWebArtworkPalette.token(
            for: item.id,
            context: item.type.lowercased() == "music" ? .music : .poster
        )
        if item.artworkAvailable, let encodedID = ServerWebURL.pathSegment(item.id) {
            let loading = prioritize ? "eager" : "lazy"
            let priority = prioritize ? #" fetchpriority="high""# : ""
            // 角标按真实来源类型标注。旧实现把"有远程可播放地址"一律标成 Mlink，
            // 于是 Emby/Jellyfin/Plex 顶着 Mlink 的名字，而真正的 Mlink 条目
            // （它们没有媒体 URL）反而没有角标。
            let sourceBadge = item.remoteSourceKind.map { kind in
                #"<span class="ui-poster-corner"><span class="ui-media-badge">\#(escape(kind.displayName))</span></span>"#
            } ?? ""
            // Before the image decodes the card shows derived material only —
            // never the title's first character, which reads as real cover art.
            return """
            <span class="\(cssClass)" data-artwork-palette="\(palette)" data-artwork-fallback="true">\
            <span class="artwork-fallback" aria-hidden="true"></span>\
            <img src="/api/v1/images/\(encodedID)/poster?size=\(size)" alt="" loading="\(loading)" decoding="async"\(priority)>\(sourceBadge)</span>
            """
        }
        return """
        <span class="\(cssClass) placeholder" data-artwork-palette="\(palette)" role="img" aria-label="\(escape(item.type)) 占位封面">\
        <span class="artwork-fallback" aria-hidden="true"></span></span>
        """
    }

    /// Fixed homepage presentation only. Runtime media and account information
    /// must remain in the authenticated HTML/API response rather than this
    /// cacheable sheet.
    static let style = #"""
    /* Home used to hand-roll `.home-header` / `.home-title`, which is why the
       front page was the one screen without the product's identity tile and
       subtitle.  It now renders through `ServerWebPageHeader` like everything
       else; the gradient that used to sit on a `<span>` inside the title moved
       to the whole heading, because the shared builder escapes its title and
       cannot carry markup. */
    .home-document .app-page-head h1 {
      background: linear-gradient(115deg, var(--text-primary) 30%, var(--accent) 78%, #d9569b);
      -webkit-background-clip: text;
      background-clip: text;
      -webkit-text-fill-color: transparent;
      white-space: nowrap;
    }
    /* One rhythm for the whole page, matching `.ui-section + .ui-section`
       everywhere else in the product.  Each section used to carry its own
       margin — 48px under the banner, 48px under the stats, nothing at all
       between the composition card and the first shelf, 64px inside the shelf
       stack — so two sections collided while others drifted apart.  The gap is
       declared once, on the flow, and every block inherits it. */
    .home-document .app-main,
    .home-sections { display: flex; flex-direction: column; gap: var(--space-9); }
    /* Two rhythms were stacking: the flex `gap` above *and* the shared
       `.ui-section + .ui-section` top margin, so consecutive shelves sat 96px
       apart while everything else sat 48px apart.  The gap owns the rhythm here. */
    .home-document .app-main .ui-section + .ui-section { margin-top: 0; }
    /* 页头到 banner 之间那一条留白收到三分之一（48px → 16px）。
       其余栏目之间仍是 48px：页头和 banner 讲的是同一件事（"今晚为你精选"就是下面
       这张图），中间隔着大半屏的空白会让它们读起来像两块不相干的内容。 */
    .home-document .app-main > .app-page-head + .hero-region { margin-top: calc(var(--space-9) / 3 - var(--space-9)); }
    /* Positioned, so the hero's wash (a stacking context) cannot paint over
       them — see the note on `.hero-region`. */
    .home-document .app-main > * { position: relative; }

    /* ---- Hero banner ------------------------------------------------------
       Built to the App Store Discover recipe, measured from the real page:
       a 16/9 card at radius 17px, a 55° scrim, copy inset 40px from the bottom
       left, dots underneath — plus the ambient wash that page paints behind the
       card from the slide's own artwork.

       The wash is the part that does the work.  It is the same image, scaled
       past the frame and blurred until it is only colour, then faded into the
       canvas so the banner appears to light the page rather than sit on it. */
    /* `isolation: isolate` used to live here.  It made the whole region a
       stacking context, and because a positioned stacking context paints *after*
       ordinary block siblings, the wash — which is taller than the card — covered
       the four summary cards below it entirely.  The fix is the painting phase,
       not a bigger z-index: every home block is positioned (see
       `.home-document .app-main > *`), so they all paint in DOM order. */
    .hero-region {
      position: relative;
      padding-inline: var(--page-gutter);
    }
    .hero-ambient {
      position: absolute;
      z-index: -1;
      top: calc((var(--page-top) + 96px) * -1);
      right: 0;
      left: 0;
      height: calc(100% + 96px + 46%);
      overflow: hidden;
      pointer-events: none;
      /* The wash has to *end*, not be *cut*.  Clipping it at the top left a hard
         horizontal edge across the page that read as a screenshot seam. */
      -webkit-mask-image: linear-gradient(to bottom, transparent 0%, #000 22%, #000 68%, transparent 100%);
      mask-image: linear-gradient(to bottom, transparent 0%, #000 22%, #000 68%, transparent 100%);
    }
    .hero-ambient-layer {
      position: absolute;
      inset: 0;
      opacity: 0;
      /* Long and asymmetric on purpose: the wash should arrive after the slide
         it belongs to, the way a room's light settles. */
      transition: opacity 1.32s var(--ease-out);
    }
    .hero-ambient-layer.is-current { opacity: 1; }
    .hero-ambient-layer::after {
      /* Two stacked passes, exactly as measured: a flat wash that pulls the
         saturation back toward the page, then a fade into the canvas colour so
         the wash has no edge of its own. */
      content: "";
      position: absolute;
      inset: 0;
      background:
        linear-gradient(to bottom, transparent 46%, var(--bg-canvas) 92%),
        linear-gradient(to bottom, var(--hero-ambient-veil), var(--hero-ambient-veil));
    }
    .hero-ambient-layer img,
    .hero-ambient-layer:not(:has(img))::before {
      position: absolute;
      inset: -10%;
      width: 120%;
      height: 120%;
      object-fit: cover;
      filter: blur(20px) saturate(1.3);
      transform: scale(1.2);
    }
    /* No artwork: the item's deterministic palette stands in, so the wash still
       has the item's colour instead of collapsing to grey. */
    .hero-ambient-layer:not(:has(img))::before {
      content: "";
      background: linear-gradient(150deg, var(--artwork-g1, var(--accent)), var(--artwork-g2, var(--accent-hover)));
    }

    .hero-frame { position: relative; display: grid; }
    .hero-viewport {
      position: relative;
      overflow: hidden;
      border-radius: 17px;
      box-shadow: var(--shadow-3);
      touch-action: pan-y;
    }
    /* 位移写在自定义属性上，而不是直接写 inline transform：全局的
       `prefers-reduced-motion` 策略会强制 `transform: none` 抹掉一切位移，
       而这里的 transform 是**布局位置**不是动效——被抹掉的话每张幻灯片都会
       叠在零点，分页点和箭头就全都点不动了。放行规则写在 base.css 的同一条
       媒体查询里（页面样式表不允许提权）；真正被关掉的是脚本里的弹簧行程。 */
    .hero-track {
      display: flex;
      transform: translate3d(calc(var(--hero-offset, 0px) * -1), 0, 0);
      will-change: transform;
    }
    .hero-slide {
      position: relative;
      display: flex;
      width: 100%;
      flex: 0 0 100%;
      aspect-ratio: 16 / 9;
      max-height: 420px;
      /* 文案按 **banner 自己的宽度** 缩放，不是按视口。
         二者不是一回事：≥1280px 时侧栏吃掉 248px，banner 比视口窄一大截，
         而 `vw` 不知道这件事。手机上更糟——所有 `clamp()` 的下限都是照桌面挑的
         （标题 34px、按钮 46px、药丸 32px），于是 350×197 的 slide 里塞进一个
         221px 高的文案块：**文案比它所在的画面还高**，banner 上一寸剧照都看不见。
         定成容器之后，下面那几条 `cqi` 一套值管所有宽度，不必逐断点打补丁。 */
      container-type: inline-size;
      /* 文案居中，标题落在 banner 的中间高度。
         贴底排会让标题掉到画面下缘，和分页点挤在一起；居中之后标题正对画面中线，
         也和客户端一致。 */
      align-items: center;
      overflow: hidden;
    }
    /* Scoped to the slide so it outranks the generic `[data-artwork-fallback]`
       rule further down, which is the same specificity and would otherwise win
       by order and drop the art back into flow — where a real 16:9 still sizes
       itself to its own dimensions and shoves the copy out of the banner. */
    .hero-slide .hero-art { position: absolute; inset: 0; display: block; }
    .hero-art img { width: 100%; height: 100%; object-fit: cover; }
    /* No landscape still for this item, so a 2:3 poster is being cropped into a
       16:9 frame.  Centre-cropping one takes a band across the middle and cuts
       the subject's head off; biasing upward keeps the part that carries the
       artwork. */
    .hero-art[data-artwork-orientation="portrait"] img { object-position: center 28%; }
    /* 两层遮罩，不是一层。
       从前只有一条 55° 的斜向渐变：它在左上角最浓，可是文案是贴着左下角排的，
       于是最需要压暗的那一块反而只剩三成不到的浓度——碰上底部偏亮的剧照，标题
       和白色的按钮就一起糊进画面里了。现在斜向那层负责把右侧画面让出来，另加
       一层自下而上的，专门托住文案和分页点所在的那条带子。
       两层都取自共用的停靠色，浅色深色各自定义，不再写死 rgba(0,0,0,…)。 */
    .hero-slide::after {
      content: "";
      position: absolute;
      inset: 0;
      background:
        linear-gradient(to top, var(--hero-scrim-strong) 0%, var(--hero-scrim-mid) 26%, var(--hero-scrim-clear) 58%),
        linear-gradient(75deg, var(--hero-scrim-strong) 0%, var(--hero-scrim-mid) 38%, var(--hero-scrim-clear) 72%);
    }
    /* 三级字阶按 apple-design 的"成套选取"来定：字号、行高、字距一起变。
       标题越大越需要负字距——同样的间隙在大字上读起来更远；副标题反过来，
       小字要一点正字距才不糊。三行都压在一个 46ch 的测度内，长片名不会横穿
       整张海报。 */
    /* 文案区不再靠阴影撑可读性，改为按画面亮度反色。
       阴影是"无论底下是什么都硬描一圈边"的做法：亮画面上它把白字勾成脏边，暗画
       面上又是多余的。这里改成量出文案那一块底下到底是亮是暗，然后连同遮罩一起
       翻过来——亮画面配深字浅遮罩，暗画面配浅字深遮罩。
       亮度由 `home.js` 采样封面得出，写成 `.is-light-art`；采样失败或还没算完时
       保持深色那一套（绝大多数剧照偏暗），所以它是渐进增强，不是必需品。 */
    .hero-slide {
      --hero-ink: var(--text-on-media);
      --hero-ink-secondary: var(--text-on-media-secondary);
      --hero-scrim-strong: var(--on-media-scrim-strong);
      --hero-scrim-mid: var(--on-media-scrim-mid);
      --hero-scrim-clear: var(--on-media-scrim-clear);
      --hero-chip-fill: var(--btn-on-media-fill);
      --hero-chip-border: var(--btn-on-media-border);
    }
    .hero-slide.is-light-art {
      --hero-ink: #12161d;
      --hero-ink-secondary: rgba(18, 22, 29, 0.74);
      --hero-scrim-strong: rgba(255, 255, 255, 0.9);
      --hero-scrim-mid: rgba(255, 255, 255, 0.52);
      --hero-scrim-clear: rgba(255, 255, 255, 0);
      --hero-chip-fill: rgba(18, 22, 29, 0.1);
      --hero-chip-border: rgba(18, 22, 29, 0.18);
    }
    .hero-copy {
      position: relative;
      z-index: 2;
      display: grid;
      /* `ch` 是"0"字的宽度，对中日韩标题是错的度量：46ch 在这里只有 382px，
         而一个 7 字标题在 54px 字号下就要 380px——「继续观看的剧集」于是稳定地
         断成「…的剧 / 集」。改按 banner 自身宽度收（`.hero-slide` 是
         `container-type: inline-size`），并保留 `ch` 上限管住西文长标题。
         58cqi ≈ App Store 那张 banner 上文案块占的比例。 */
      max-width: min(58cqi, 68ch);
      gap: 10px;
      gap: clamp(4px, 0.8cqi, 10px);
      padding: clamp(24px, 3.2vw, 44px);
      padding: clamp(16px, 3.2cqi, 44px);
      color: var(--hero-ink);
    }
    /* 文案那条带子底下再糊一层。
       遮罩压暗了亮度，但压不掉高频细节——霓虹招牌、树叶、字幕这类纹理会和字绞在
       一起。一层带蒙版的模糊把底下化成色块，字才真正浮起来。蒙版让它向上淡出，
       画面中间不会出现一条硬边。 */
    /* 文案底下那层磨砂，铺满整张画面、再用蒙版收出形状。
       它从前挂在 `.hero-copy::before` 上，靠负 inset 往外扩。那样做蒙版的透明端会
       落在盒子之外——渐变在盒子里始终没降到 0，元素自己的矩形边界就成了硬边，于是
       文字区周围能看到一个清清楚楚的模糊方块。
       改成铺满整张 slide 之后，蒙版的透明端在盒子内部就到达了，四周自然羽化；左下
       角保持不透明，一直贴到画面边缘收尾，那里本来就是 banner 的尽头。 */
    .hero-veil {
      position: absolute;
      z-index: 1;
      inset: 0;
      -webkit-backdrop-filter: blur(13px) saturate(118%);
      backdrop-filter: blur(13px) saturate(118%);
      /* 只罩住文案和按钮那一小块，不要糊掉半张画面：椭圆压到 44%×52%，中心落在
         文案重心上，透明端仍在盒子内部收敛，四周自然羽化。 */
      -webkit-mask-image: radial-gradient(44% 52% at 17% 62%, #000 0%, rgba(0, 0, 0, 0.8) 46%, rgba(0, 0, 0, 0.3) 72%, transparent 92%);
      mask-image: radial-gradient(44% 52% at 17% 62%, #000 0%, rgba(0, 0, 0, 0.8) 46%, rgba(0, 0, 0, 0.3) 72%, transparent 92%);
      pointer-events: none;
    }
    /* 客户端在这里放的是一枚「★ 今日精选」药丸，而不是一行全大写的 eyebrow。
       药丸自带一块底，在任何一张剧照上都读得出来；纯文字的 eyebrow 在亮画面上
       只能靠字重硬撑。 */
    .hero-badge {
      display: inline-flex;
      align-items: center;
      justify-self: start;
      gap: 5px;
      height: var(--control-height-sm);
      height: clamp(24px, 2.8cqi, var(--control-height-sm));
      padding-inline: var(--space-3);
      padding-inline: clamp(var(--space-2), 1.1cqi, var(--space-3));
      border: var(--hairline) solid var(--hero-chip-border);
      border-radius: var(--radius-pill);
      background: var(--hero-chip-fill);
      -webkit-backdrop-filter: var(--btn-on-media-blur);
      backdrop-filter: var(--btn-on-media-blur);
      color: var(--hero-ink);
      font-size: var(--type-caption-size);
      font-weight: var(--weight-semibold);
      letter-spacing: 0.04em;
    }
    .hero-badge svg { width: var(--icon-xs); height: var(--icon-xs); color: var(--warning); }
    /* 字号往上提了一档。这一块是整页唯一的展示位，46px 的上限在 1440 宽的窗口
       里只占到画面高度的十分之一，读起来更像一个小标题而不是主角；对齐客户端
       28pt black 在其窗宽下的视觉重量，上限给到 56px。
       字距随字号加负——大字上同样的间隙看着更松，这是成套定的，不是一个固定值
       套所有尺寸。 */
    .hero-title {
      /* 两条 `font-size` 是刻意的：不认识 `cqi` 的浏览器会丢掉第二条，
         回落到第一条的视口版本，而不是掉进继承字号。 */
      font-size: clamp(34px, 4.4vw, 56px);
      font-size: clamp(21px, 4.9cqi, 56px);
      font-weight: var(--weight-black);
      line-height: 1.06;
      letter-spacing: -0.032em;
      /* 最多两行：第三行开始，海报上的字就变成了一段说明文。 */
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      overflow: hidden;
    }
    .hero-meta {
      color: var(--hero-ink-secondary);
      font-size: clamp(13px, 1.1vw, 15px);
      font-size: clamp(12px, 1.25cqi, 15px);
      font-weight: var(--weight-medium);
      line-height: 1.45;
      letter-spacing: 0.012em;
    }
    .hero-actions {
      display: flex;
      flex-wrap: wrap;
      gap: clamp(var(--space-2), 1.1cqi, var(--space-3));
      margin-top: var(--space-4);
      margin-top: clamp(var(--space-2), 1.3cqi, var(--space-4));
    }
    .hero-actions .ui-btn { height: 46px; padding-inline: var(--space-6); font-size: var(--type-body-size); border-radius: var(--radius-pill); }
    .hero-actions .ui-btn {
      height: clamp(36px, 4cqi, 46px);
      padding-inline: clamp(var(--space-4), 2.2cqi, var(--space-6));
      font-size: clamp(var(--type-subhead-size), 1.35cqi, var(--type-body-size));
    }
    .hero-actions .ui-btn > svg { width: var(--icon-md); height: var(--icon-md); }
    .hero-actions .ui-btn > svg {
      width: clamp(var(--icon-sm), 1.8cqi, var(--icon-md));
      height: clamp(var(--icon-sm), 1.8cqi, var(--icon-md));
    }
    /* The full-banner play affordance is a mobile-only semantic link.  Keeping
       it as a real anchor preserves open-in-new-tab and browser navigation
       behavior while desktop retains its two explicit actions. */
    .hero-mobile-play-link { display: none; }
    /* 亮画面上白色实心按钮等于消失，半透明白也糊成一片：两颗都要跟着翻过来。 */
    .hero-slide.is-light-art .ui-btn-on-media-strong {
      color: #ffffff;
      background: rgba(18, 22, 29, 0.92);
    }
    .hero-slide.is-light-art .ui-btn-on-media-strong:hover { background: #12161d; }
    .hero-slide.is-light-art .ui-btn-on-media {
      color: var(--hero-ink);
      border-color: var(--hero-chip-border);
      background: var(--hero-chip-fill);
      text-shadow: none;
    }
    .hero-slide.is-light-art .ui-btn-on-media:hover { background: rgba(18, 22, 29, 0.16); }

    /* 分页点收进画面里，做成 App Store「探索」那种药丸。
       它从前挂在 banner 下面，于是 banner 和下方内容之间多出一条只为几个小圆点
       存在的空带；收进来之后 banner 是一个完整的方块，点也就近说明"这是第几张"。 */
    .hero-pagination {
      position: absolute;
      z-index: 3;
      right: 0;
      bottom: var(--space-4);
      left: 0;
      display: flex;
      justify-content: center;
      pointer-events: none;
    }
    .hero-dots {
      display: flex;
      align-items: center;
      gap: 2px;
      padding: 3px var(--space-2);
      border-radius: var(--radius-pill);
      background: rgba(18, 22, 29, 0.34);
      -webkit-backdrop-filter: blur(12px) saturate(140%);
      backdrop-filter: blur(12px) saturate(140%);
      pointer-events: auto;
    }
    /* 20px 的点击区里画一个 7px 的点：可按，但不画成一个 20px 的圆。 */
    .hero-dot {
      position: relative;
      width: 20px;
      height: 20px;
      cursor: pointer;
    }
    .hero-dot::after {
      content: "";
      position: absolute;
      inset: 0;
      border-radius: 50%;
      background: #ffffff;
      opacity: 0.42;
      transform: scale(0.35);
      transition: transform 0.1s var(--ease-out), opacity 0.3s var(--ease-out);
    }
    .hero-dot:hover::after { opacity: 0.7; }
    .hero-dot.is-current::after { opacity: 1; }
    .hero-dot:focus-visible { outline: none; }
    .hero-dot:focus-visible::after { box-shadow: var(--focus-ring); transform: scale(0.5); }

    /* 翻页键只在指针落在 banner 的高度范围内时出现（`home.js` 挂
       `.is-pointer-within`），而不是靠 `:hover` —— 指针在页面别处上下移动时，
       banner 两侧不该反复闪出两个按钮。 */
    /* 翻页键落在 banner **之外**，做成和其它横向列表一样的细线箭头。
       压在画面上的圆形按钮会挡住海报，而海报正是这一块要给人看的东西；客户端也
       是把它们放在卡片外侧的留白里。 */
    .hero-arrow {
      position: absolute;
      top: 50%;
      z-index: 3;
      display: grid;
      width: 28px;
      /* 加高不加宽：细长的一条比一个方块更像"翻到下一页"，也更好瞄准。
         跟随 banner 的高度，不再是一个固定的小方块。 */
      height: 100%;
      max-height: 512px;
      place-items: center;
      transform: translateY(-50%);
      border: 0;
      border-radius: var(--radius-sm);
      color: var(--text-tertiary);
      background: transparent;
      box-shadow: none;
      opacity: 0;
      transition: opacity 0.2s var(--ease-out), color var(--duration-fast) var(--ease-out);
    }
    .hero-arrow:hover { color: var(--text-primary); background: transparent; }
    .hero-arrow-glyph { width: 22px; height: 58px; }
    .hero-region.is-pointer-within .hero-arrow,
    .hero-viewport:focus-within .hero-arrow { opacity: 1; }
    .hero-arrow-previous { right: calc(100% + 2px); }
    .hero-arrow-next { left: calc(100% + 2px); }
    @media (hover: none), (pointer: coarse) { .hero-arrow { display: none; } }

    /* Reduced motion keeps the crossfade — a fade is not vestibular — but drops
       the horizontal travel and the auto-advance (the script checks the same
       query before it starts its timer). */
    @media (prefers-reduced-motion: reduce) {
      .hero-slide { transition: opacity 180ms linear; }
      .hero-dot::after { transition: opacity 180ms linear, background-color 180ms linear; }
    }
    /* A full-width 20px blur is the most expensive thing on this page.  Where
       the viewer has asked for less transparency, or the viewport is small
       enough that the wash is barely visible, it steps down. */
    @media (prefers-reduced-transparency: reduce) {
      .hero-ambient { display: none; }
    }

    /* ---- 概览 bento --------------------------------------------------------
       两条四格指标条合成一块。左边是这一屏真正的头条数字（媒体总数），右边七
       个小格分别通往它们代表的那批内容。

       右列写 `minmax(0, 2fr)` 而不是 `2fr`：网格项的自动最小尺寸是 min-content，
       漏掉 `minmax(0, …)` 的话七个格子的固有宽度会把左边那格挤没。 */
    .home-overview {
      display: grid;
      grid-template-columns: minmax(200px, 0.62fr) minmax(0, 2fr);
      gap: var(--space-4);
    }
    .home-overview-lead {
      display: grid;
      align-content: center;
      gap: 2px;
      padding: var(--space-5) var(--space-6);
      border: var(--hairline) solid transparent;
      border-radius: var(--card-radius);
      /* 整屏唯一一块实心色。首页此前从上到下是白卡配灰字，读者的眼睛没有落点；
         头条数字本来就该是头条。这里刻意**不用**识别色淡底——那一族是"认得出
         是哪个域"，不是"看我"；淡底放大到这个尺寸只会糊成一块土色。
         阴影保持中性：彩色高程按设计文档只给强调色**实心控件**，一块卡片投自己
         的颜色会读成发光的贴纸。 */
      color: var(--text-on-accent);
      background-color: var(--accent);
      background-image: var(--fill-raise);
      box-shadow: var(--inner-highlight-strong), var(--shadow-2);
    }
    .home-overview-lead small {
      font-size: var(--type-footnote-size);
      font-weight: var(--weight-semibold);
      letter-spacing: 0.04em;
    }
    .home-overview-lead strong {
      font-size: var(--type-display-size);
      font-weight: var(--weight-black);
      line-height: 1.04;
      letter-spacing: var(--type-display-track);
    }
    /* 说明行不降透明度：白字在 `--accent` 上只有 4.71:1，再压一档就掉到 4.5
       以下。层级改由字号和字重承担。 */
    .home-overview-lead-note { color: var(--text-on-accent); font-size: var(--type-footnote-size); }

    /* 六格排成三列两行，不是 `auto-fit`。上排是**有什么**（视频/音乐/照片），
       下排是**看过什么**（正在观看/已看完/已标记）——这两行本来就是两组，让
       `auto-fit` 按可用宽度决定断在哪里，会把它们切成 5+1 这种没有意义的形状。 */
    .home-overview-grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: var(--space-3);
    }
    @media (max-width: 1279px) {
      .home-overview { grid-template-columns: minmax(0, 1fr); }
      .home-overview-lead { padding: var(--space-4) var(--space-5); }
    }
    @media (max-width: 599px) {
      .home-overview-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    }
    .home-overview-cell {
      display: flex;
      min-width: 0;
      align-items: center;
      gap: var(--space-3);
      padding: var(--space-3) var(--space-4);
      border: var(--hairline) solid var(--tint-border, var(--border));
      border-radius: var(--radius-md);
      color: inherit;
      background-color: var(--surface);
      /* 六格此前是六个一模一样的白盒。淡淡一层各自的识别色斜洗，让「视频/音乐/
         照片」在扫视里就分得开——不是给卡片上色，是给它一个可以认的角。 */
      background-image:
        linear-gradient(145deg, var(--tint-fill-a, transparent), transparent 62%),
        var(--fill-raise-soft);
      box-shadow: var(--shadow-1);
      transition:
        border-color var(--duration-fast) var(--ease-out),
        background-color var(--duration-fast) var(--ease-out),
        box-shadow var(--duration-fast) var(--ease-out);
    }
    /* 只有真能点开的格子给 hover 与按下反馈。「分类」没有对应的目的地，所以它
       是一个 div 而不是链接，也就不会假装自己可以点。 */
    .home-overview-link:hover {
      border-color: var(--border-strong);
      background-color: var(--surface-hover);
      box-shadow: var(--shadow-2);
    }
    .home-overview-link:active { transform: scale(0.985); }
    .home-overview-copy { display: grid; min-width: 0; gap: 1px; }
    .home-overview-copy small {
      overflow: hidden;
      color: var(--text-tertiary);
      font-size: var(--type-footnote-size);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .home-overview-copy strong {
      font-size: var(--type-title3-size);
      font-weight: var(--weight-bold);
      letter-spacing: -0.01em;
    }

    /* ---- Shelves ---------------------------------------------------------- */

    /* ---- 货架的三种形状 ------------------------------------------------
       列宽是固定的，卡片不会为了占满一行而变形——一排放不满就放不满。客户端
       也是这样：固定尺寸的卡片左对齐排开，剩下的就是剩下的。

       这里曾经在"少于四条"时切到一种撑满整行的宽卡。那是把空白当成需要填上的
       洞，可读者看到的是一张被拉变形的封面，比留白更糟。 */
    .home-shelf-poster { --grid-min: 168px; }
    .home-shelf-square { --grid-min: 168px; }
    /* 横版剧照要更宽的列才看得清画面里在发生什么。 */
    .home-shelf-landscape { --grid-min: 320px; }

    /* 「继续观看」的卡片：文案压在剧照上，和 banner 是同一种读法。
       进度条贴着画面下沿——它说的是这张图里的事，不是卡片下面那行字的事。 */
    .home-shelf-landscape .ui-media-card { position: relative; }
    .home-shelf-landscape .ui-media-title,
    .home-shelf-landscape .ui-media-meta {
      position: relative;
      z-index: 2;
      color: var(--text-on-media);
    }
    .home-shelf-landscape .ui-media-card > a { position: relative; display: block; }
    .home-shelf-landscape .ui-poster::after {
      content: "";
      position: absolute;
      right: 0;
      bottom: 0;
      left: 0;
      z-index: 1;
      height: 62%;
      background: linear-gradient(
        to top,
        var(--on-media-scrim-strong) 0%,
        var(--on-media-scrim-mid) 52%,
        var(--on-media-scrim-clear) 100%
      );
      pointer-events: none;
    }
    .home-shelf-landscape .home-landscape-copy {
      position: absolute;
      right: 0;
      bottom: 0;
      left: 0;
      z-index: 2;
      display: grid;
      gap: 2px;
      padding: var(--space-4) var(--space-3) var(--space-3);
      color: var(--text-on-media);
    }
    .home-shelf-landscape .home-landscape-copy .ui-media-title { font-weight: var(--weight-semibold); }
    .home-shelf-landscape .home-landscape-copy .ui-media-meta { color: var(--text-on-media-secondary); }
    .home-shelf-landscape .home-card-progress { background: var(--track-on-media); }

    .home-card-progress { height: 3px; margin-top: var(--space-1); }
    .home-card-progress-fill { display: block; height: 100%; border-radius: inherit; background: var(--accent); }

    /* ---- Music ------------------------------------------------------------ */
    .home-music-layout { display: grid; grid-template-columns: minmax(0, 1.78fr) minmax(248px, 0.82fr); gap: var(--space-6); }
    /* Rows stack from the top.  Without this the chart centres itself against
       the taller playlist column beside it, so a short list floats in the middle
       of a block of empty space instead of lining up with its heading. */
    .music-chart { display: grid; align-content: start; }
    .track-row {
      display: grid;
      grid-template-columns: 24px minmax(0, 1fr) auto;
      align-items: center;
      gap: var(--space-3);
      min-height: 52px;
      padding: 0 var(--space-2);
      border-radius: var(--radius-sm);
      transition: background-color var(--duration-fast) var(--ease-out);
    }
    .track-row:hover { background: var(--surface-hover); }
    .track-row + .track-row { box-shadow: inset 0 1px 0 var(--divider); }
    .track-index { color: var(--text-tertiary); font-size: var(--type-footnote-size); text-align: center; }
    .track-main { display: flex; min-width: 0; align-items: center; gap: var(--space-3); color: inherit; }
    .track-art { display: grid; width: 40px; height: 40px; flex: none; overflow: hidden; place-items: center; border-radius: var(--radius-xs); }
    .track-copy { display: grid; min-width: 0; gap: 1px; }
    .track-copy strong { overflow: hidden; font-size: var(--type-callout-size); font-weight: var(--weight-medium); text-overflow: ellipsis; white-space: nowrap; }
    .track-copy small { color: var(--text-tertiary); font-size: var(--type-footnote-size); }
    .track-play {
      display: grid;
      width: 32px;
      height: 32px;
      place-items: center;
      border-radius: 50%;
      color: var(--accent-text);
      background: var(--accent-subtle);
      opacity: 0;
      transition: opacity var(--duration-fast) var(--ease-out);
    }
    .track-row:hover .track-play, .track-row:focus-within .track-play { opacity: 1; }
    @media (hover: none), (pointer: coarse) { .track-play { opacity: 1; } }

    /* 左右两列同底：把两列都交给同一行网格，行高由内容较高的一列决定，另一列
       拉伸填满。歌单卡片的高度必须是**列宽的函数**而不是封面的函数——否则
       图片的固有尺寸会顶开右列，两列就再也对不齐了。 */
    /* 卡片按内容高度排，从顶部开始——不再被拉长去配平旁边那张 12 行的曲目表。
       `stretch` + `1fr` 的那一版会把封面拉成 270px 高的色块，中间孤零零一个
       34px 的音符：一张为了占满一行而变形的"封面"。 */
    .home-playlist-stack {
      display: grid;
      align-content: start;
      gap: var(--space-3);
      min-height: 0;
    }
    .home-playlist-card {
      display: flex;
      min-height: 0;
      flex-direction: row;
      align-items: center;
      gap: var(--space-3);
      padding: var(--space-3);
      overflow: hidden;
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-md);
      color: inherit;
      background: var(--surface);
      box-shadow: var(--shadow-1);
      transition:
        border-color var(--duration-base) var(--ease-out),
        box-shadow var(--duration-base) var(--ease-out),
        transform var(--duration-base) var(--ease-out);
    }
    .home-playlist-card:hover {
      border-color: var(--border-strong);
      box-shadow: var(--shadow-3);
      transform: translateY(-2px);
    }
    /* 客户端那套确定性取色兜底图：同一个歌单永远是同一组颜色。 */
    /* **封面始终是圆角方形，永远不拉伸。**
       它此前写着 `flex: 1 1 auto`，而外层网格是 `stretch` + `1fr`，于是这块
       "封面"会一路长到和旁边 12 行的曲目表一样高（实测约 270px），中间孤零零
       一个 34px 的音符。专辑封面是方的，让它为了占满一行而变形，比留一点空白
       难看得多。`aspect-ratio: 1` + `flex: none` 把这件事彻底钉死。 */
    .home-playlist-art {
      display: grid;
      width: 64px;
      flex: none;
      aspect-ratio: 1;
      place-items: center;
      border-radius: var(--radius-sm);
      color: rgba(255, 255, 255, 0.92);
      background: linear-gradient(150deg, var(--artwork-g1, var(--accent)), var(--artwork-g2, var(--accent-hover)));
      box-shadow: var(--inner-highlight), var(--shadow-1);
    }
    .home-playlist-art > svg {
      width: var(--icon-lg);
      height: var(--icon-lg);
      filter: drop-shadow(0 1px 3px rgba(0, 0, 0, 0.35));
    }
    .home-playlist-copy {
      display: grid;
      min-width: 0;
      flex: 1 1 auto;
      gap: 2px;
    }
    .home-playlist-copy strong { font-size: var(--type-title3-size); letter-spacing: var(--type-title3-track); font-weight: var(--weight-semibold); }
    .home-playlist-copy small, .home-playlist-copy em { color: var(--text-tertiary); font-size: var(--type-footnote-size); font-style: normal; }

    /* ---- Photos ----------------------------------------------------------- */
    .photo-shelf {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(148px, 1fr));
      gap: var(--space-3);
    }
    .photo-tile { position: relative; display: block; overflow: hidden; aspect-ratio: 1 / 1; border-radius: var(--radius-md); color: var(--text-on-media); }
    .photo-tile .photo-art { position: absolute; inset: 0; display: block; }
    .photo-tile img { width: 100%; height: 100%; object-fit: cover; }
    .photo-tile strong {
      position: absolute;
      right: 0;
      bottom: 0;
      left: 0;
      z-index: 2;
      overflow: hidden;
      padding: var(--space-7) var(--space-3) var(--space-2);
      background: var(--media-scrim);
      font-size: var(--type-footnote-size);
      font-weight: var(--weight-semibold);
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    /* ---- Artwork ---------------------------------------------------------- */
    [data-artwork-fallback] { position: relative; }
    .artwork-fallback {
      position: absolute;
      inset: 0;
      display: block;
      background: linear-gradient(145deg, var(--artwork-g1, var(--artwork-fallback-a)), var(--artwork-g2, var(--artwork-fallback-b)));
    }
    /* `transform` has to stay in this list: home.css loads after primitives.css,
       so restating `transition` here with opacity alone would silently cancel the
       poster hover zoom on every shelf. */
    [data-artwork-fallback] img {
      position: relative;
      z-index: 1;
      opacity: 0;
      transition: opacity var(--duration-slow) var(--ease-out), transform var(--duration-slow) var(--ease-out);
    }
    [data-artwork-fallback] img[data-ready="true"] { opacity: 1; }
    .placeholder { position: relative; }


    @media (max-width: 1023px) {
      .home-music-layout { grid-template-columns: minmax(0, 1fr); }
    }
    @media (max-width: 719px) {
      /* 问候语始终是一句话。用连续的视口比例在可用空间不足时缩小，而不是折成
         两行后把搜索与 banner 一并向下推；15px 下限仍只用于标题，不降低正文。 */
      .home-document .app-page-identity > div { min-width: 0; }
      .home-document .app-page-head h1 {
        font-size: clamp(15px, 4.5vw, var(--type-display-size));
        line-height: 1.12;
      }
      .hero-viewport { border-radius: var(--radius-md); }
      /* 旧移动端是 5:4（高度 = 0.8 × 宽度）。改为 5:3 后高度 = 0.6 × 宽度，
         正好是旧高度的 3/4；对应的 340px 上限也按同一比例收至 255px。 */
      .hero-slide { aspect-ratio: 5 / 3; max-height: 255px; }
      /* 移动端整张 banner 就是播放入口，不再让两个按钮挤占内容高度。文案仍贴底，
         并为画面内分页点留出命中空间。 */
      .hero-slide { align-items: flex-end; }
      .hero-copy { padding: var(--space-5); padding-bottom: calc(var(--space-5) + 24px); gap: 4px; }
      .hero-actions { display: none; }
      .hero-mobile-play-link {
        position: absolute;
        z-index: 2;
        inset: 0;
        display: block;
        border-radius: inherit;
        touch-action: manipulation;
        -webkit-tap-highlight-color: transparent;
      }
      .hero-mobile-play-link:focus-visible {
        outline: 3px solid var(--accent);
        outline-offset: -3px;
      }
      /* A 20px blur across a phone viewport buys very little and costs a full
         screen of compositing every frame the wash cross-fades. */
      .hero-ambient-layer img, .hero-ambient-layer:not(:has(img))::before { filter: blur(12px) saturate(1.2); }
    }
    """#

    static let script = #"""
    (() => {
      'use strict';

      // ---- 问候语跟随读者自己的时钟 ----------------------------------------
      // 时段划分与客户端 `HomeView.greeting` 逐字一致。服务端渲染的是一句不带时段
      // 的兜底，因为它既不知道读者的时区，那句话还会被缓存后发给所有人——按服务器
      // 的钟写死"今晚"，对时差另一头的人就是错的。
      const homeTitle = document.getElementById('home-title');
      if (homeTitle) {
        const hour = new Date().getHours();
        const greeting = hour >= 5 && hour < 12 ? '早上好'
          : hour >= 12 && hour < 14 ? '中午好'
          : hour >= 14 && hour < 18 ? '下午好'
          : hour >= 18 && hour < 23 ? '晚上好'
          : '夜深了';
        homeTitle.textContent = `${greeting}，为你精选了一份片单`;
      }

      // Artwork cross-fades in over its derived placeholder, so a slow image
      // never leaves an empty rectangle and never pops.
      document.querySelectorAll('[data-artwork-fallback]').forEach(host => {
        const image = host.querySelector('img');
        if (!image) return;
        const reveal = () => { image.dataset.ready = 'true'; };
        image.addEventListener('load', reveal, { once: true });
        image.addEventListener('error', () => image.remove(), { once: true });
        if (image.complete && image.naturalWidth > 0) reveal();
      });

      // Progress widths come from a data attribute rather than a server-rendered
      // style attribute, which the page CSP blocks outright.
      document.querySelectorAll('[data-progress]').forEach(node => {
        const value = Number(node.getAttribute('data-progress'));
        if (Number.isFinite(value)) node.style.width = Math.max(0, Math.min(100, value)) + '%';
      });
      document.querySelectorAll('[data-fill]').forEach(node => {
        const value = Number(node.getAttribute('data-fill'));
        if (Number.isFinite(value)) node.style.width = Math.max(2, Math.min(100, value)) + '%';
      });

      // ---- Hero carousel --------------------------------------------------
      // Transform-driven rather than scroll-driven, because a gesture has to be
      // able to grab a slide mid-flight and throw it back the other way — which
      // a `scroll-behavior: smooth` animation cannot do.  The motion is a spring
      // (critically damped by default, a little bounce only after a flick), so
      // a new target never restarts from a stale value: it re-targets from
      // wherever the slide currently is, carrying its current velocity.
      const region = document.querySelector('[data-hero-carousel]');
      if (!region) return;
      const track = region.querySelector('[data-hero-track]');
      const slides = [...region.querySelectorAll('.hero-slide')];
      const dots = [...region.querySelectorAll('[data-hero-dot]')];
      const ambientLayers = [...region.querySelectorAll('.hero-ambient-layer')];
      const previous = region.querySelector('[data-hero-previous]');
      const next = region.querySelector('[data-hero-next]');
      if (!track || slides.length === 0) return;

      // ---- 按画面亮度反色 --------------------------------------------------
      // 采样每张封面文案那一角的平均亮度，亮就给这张 slide 挂 `.is-light-art`，
      // 文字、遮罩、徽章和两颗按钮一起翻过来。
      //
      // 只取 16×16：这一步要的是"整体偏亮还是偏暗"，不是细节，缩到 16 像素宽由
      // GPU 顺手做掉，比逐像素读原图便宜几个数量级。图片同源，canvas 不会被污染。
      const measureArtwork = (slide) => {
        const image = slide.querySelector('.hero-art img');
        if (!image || !image.naturalWidth) return;
        try {
          const canvas = document.createElement('canvas');
          canvas.width = 16;
          canvas.height = 16;
          const context = canvas.getContext('2d', { willReadFrequently: true });
          if (!context) return;
          // 只画文案压着的那一块：左下角约四成宽、四成高。
          const sourceWidth = Math.max(1, Math.round(image.naturalWidth * 0.45));
          const sourceHeight = Math.max(1, Math.round(image.naturalHeight * 0.45));
          context.drawImage(
            image, 0, image.naturalHeight - sourceHeight, sourceWidth, sourceHeight, 0, 0, 16, 16
          );
          const { data } = context.getImageData(0, 0, 16, 16);
          var total = 0;
          for (var i = 0; i < data.length; i += 4) {
            // Rec. 709 相对亮度，够用且比转 sRGB 线性空间便宜。
            total += (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) / 255;
          }
          const mean = total / (data.length / 4);
          slide.classList.toggle('is-light-art', mean > 0.62);
        } catch (_) {
          // 取不到就维持深色那一套：绝大多数剧照偏暗，这是安全的默认。
        }
      };
      slides.forEach(slide => {
        const image = slide.querySelector('.hero-art img');
        if (!image) return;
        if (image.complete && image.naturalWidth > 0) measureArtwork(slide);
        else image.addEventListener('load', () => measureArtwork(slide), { once: true });
      });

      // ---- 翻页键的出现条件 ------------------------------------------------
      // 指针纵向落在 banner 的高度范围内才显示，而不是 `:hover`：读者在页面别处
      // 上下移动时，banner 两侧不该反复闪出两个按钮。
      const updatePointerWithin = (event) => {
        const bounds = region.getBoundingClientRect();
        const within = event.clientY >= bounds.top && event.clientY <= bounds.bottom;
        region.classList.toggle('is-pointer-within', within);
      };
      document.addEventListener('pointermove', updatePointerWithin, { passive: true });
      document.addEventListener('pointerleave', () => region.classList.remove('is-pointer-within'));

      const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)');
      var index = 0;
      var offset = 0;           // current translate, in px
      var velocity = 0;         // px/s, carried across re-targets
      var target = 0;
      var frame = null;
      var lastFrameTime = 0;
      var bounce = 0;

      const width = () => region.querySelector('.hero-viewport')?.clientWidth || 1;
      const paint = () => { track.style.setProperty('--hero-offset', `${offset}px`); };

      // Apple's two designer-facing parameters rather than mass/stiffness/damping:
      // `response` is how quickly the value reaches the target in seconds, and
      // `bounce` is the overshoot.  Bounce is only ever non-zero when the motion
      // was started by a flick, because overshoot on a tapped arrow feels wrong.
      const step = now => {
        frame = null;
        const dt = Math.min(0.064, Math.max(0.001, (now - lastFrameTime) / 1000));
        lastFrameTime = now;
        const response = 0.32;
        const stiffness = (2 * Math.PI / response) ** 2;
        const dampingRatio = 1 - bounce;
        const damping = 2 * dampingRatio * (2 * Math.PI / response);
        const displacement = offset - target;
        const acceleration = -stiffness * displacement - damping * velocity;
        velocity += acceleration * dt;
        offset += velocity * dt;
        paint();
        if (Math.abs(offset - target) < 0.4 && Math.abs(velocity) < 12) {
          offset = target;
          velocity = 0;
          paint();
          return;
        }
        frame = window.requestAnimationFrame(step);
      };

      const animate = () => {
        if (frame !== null) return;
        lastFrameTime = performance.now();
        frame = window.requestAnimationFrame(step);
      };

      const syncSelection = () => {
        slides.forEach((slide, position) => {
          if (position === index) slide.removeAttribute('aria-hidden');
          else slide.setAttribute('aria-hidden', 'true');
        });
        dots.forEach((dot, position) => {
          const current = position === index;
          dot.classList.toggle('is-current', current);
          dot.setAttribute('aria-selected', current ? 'true' : 'false');
          dot.tabIndex = current ? 0 : -1;
        });
        ambientLayers.forEach((layer, position) => layer.classList.toggle('is-current', position === index));
        if (previous) previous.disabled = index === 0;
        if (next) next.disabled = index === slides.length - 1;
      };

      const goTo = (position, options = {}) => {
        index = Math.max(0, Math.min(slides.length - 1, position));
        target = index * width();
        bounce = options.bounce || 0;
        if (typeof options.velocity === 'number') velocity = options.velocity;
        syncSelection();
        if (reduceMotion?.matches) {
          // Reduced motion swaps the travel for an immediate placement; the
          // ambient wash still cross-fades, which is not a vestibular effect.
          offset = target;
          velocity = 0;
          paint();
          return;
        }
        animate();
      };

      syncSelection();
      paint();

      previous?.addEventListener('click', () => goTo(index - 1));
      next?.addEventListener('click', () => goTo(index + 1));
      for (const dot of dots) {
        dot.addEventListener('click', () => goTo(Number(dot.dataset.heroDot) || 0));
        dot.addEventListener('keydown', event => {
          if (event.key === 'ArrowRight') { event.preventDefault(); goTo(index + 1); dots[Math.min(index, dots.length - 1)]?.focus(); }
          else if (event.key === 'ArrowLeft') { event.preventDefault(); goTo(index - 1); dots[Math.max(index, 0)]?.focus(); }
          else if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); goTo(Number(dot.dataset.heroDot) || 0); }
        });
      }

      // Auto-advance, paused whenever the reader is plausibly engaged: pointer
      // over the banner, keyboard focus inside it, or the tab in the background.
      var timer = null;
      // 与客户端 HomeVividHeroCarousel 同步：5 秒。
      const autoAdvanceInterval = 5000;
      const stopTimer = () => { if (timer !== null) { window.clearInterval(timer); timer = null; } };
      const startTimer = () => {
        stopTimer();
        if (slides.length < 2 || reduceMotion?.matches || document.hidden) return;
        timer = window.setInterval(() => goTo(index + 1 >= slides.length ? 0 : index + 1), autoAdvanceInterval);
      };
      region.addEventListener('pointerenter', stopTimer);
      region.addEventListener('pointerleave', startTimer);
      region.addEventListener('focusin', stopTimer);
      region.addEventListener('focusout', event => { if (!region.contains(event.relatedTarget)) startTimer(); });
      document.addEventListener('visibilitychange', () => (document.hidden ? stopTimer() : startTimer()));
      window.addEventListener('medialib:pagewillunload', stopTimer, { once: true });
      startTimer();

      window.addEventListener('resize', () => {
        // Width changed, so the resting position for this index did too. Jump
        // rather than animate: nothing about a resize is a gesture.
        offset = index * width();
        target = offset;
        velocity = 0;
        paint();
      }, { passive: true });

      // ---- Drag ------------------------------------------------------------
      // 1:1 with the pointer, respecting where the reader grabbed, with
      // progressive resistance past the ends instead of a hard stop.  On release
      // the resting point is *projected* from the velocity — the same
      // exponential-decay model scrolling uses — and the spring is handed that
      // velocity so there is no seam between dragging and animating.
      const project = (initialVelocity, decelerationRate = 0.998) =>
        (initialVelocity / 1000) * decelerationRate / (1 - decelerationRate);
      const rubberband = (overshoot, dimension, constant = 0.55) =>
        (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));

      var drag = null;
      var suppressClickUntil = 0;
      track.addEventListener('pointerdown', event => {
        if (event.button !== 0 || slides.length < 2) return;
        stopTimer();
        if (frame !== null) { window.cancelAnimationFrame(frame); frame = null; }
        drag = {
          id: event.pointerId,
          startX: event.clientX,
          startY: event.clientY,
          startOffset: offset,
          axis: null,
          samples: [{ x: event.clientX, t: performance.now() }]
        };
      });
      track.addEventListener('pointermove', event => {
        if (!drag || drag.id !== event.pointerId) return;
        const dx = event.clientX - drag.startX;
        const dy = event.clientY - drag.startY;
        // ~10px of hysteresis before committing to an axis, so a vertical page
        // scroll that starts on the banner is never stolen.
        if (drag.axis === null) {
          if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
          drag.axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y';
          if (drag.axis === 'x') track.setPointerCapture(event.pointerId);
        }
        if (drag.axis !== 'x') return;
        event.preventDefault();
        const span = width();
        var next = drag.startOffset - dx;
        const maximum = (slides.length - 1) * span;
        if (next < 0) next = -rubberband(-next, span);
        else if (next > maximum) next = maximum + rubberband(next - maximum, span);
        offset = next;
        paint();
        drag.samples.push({ x: event.clientX, t: performance.now() });
        if (drag.samples.length > 5) drag.samples.shift();
      });
      const endDrag = event => {
        if (!drag || drag.id !== event.pointerId) return;
        const wasHorizontal = drag.axis === 'x';
        const samples = drag.samples;
        drag = null;
        startTimer();
        if (!wasHorizontal) return;
        // Velocity from the last few samples, not from the whole gesture: a
        // long slow drag that ends in a flick should throw.
        const first = samples[0];
        const last = samples[samples.length - 1];
        const elapsed = Math.max(1, last.t - first.t);
        const pointerVelocity = ((last.x - first.x) / elapsed) * 1000;
        const projected = offset - project(pointerVelocity);
        const span = width();
        const landing = Math.round(projected / span);
        suppressClickUntil = Date.now() + 320;
        goTo(landing, { velocity: -pointerVelocity, bounce: Math.abs(pointerVelocity) > 120 ? 0.2 : 0 });
      };
      track.addEventListener('pointerup', endDrag);
      track.addEventListener('pointercancel', event => { if (drag && drag.id === event.pointerId) { drag = null; startTimer(); } });
      // A drag that ends over a card must not also open it.
      track.addEventListener('click', event => {
        if (Date.now() >= suppressClickUntil) return;
        event.preventDefault();
        event.stopPropagation();
      }, { capture: true });

      // ---- 精选位的「加入想看」---------------------------------------------
      // 和详情页 `#toggle-watchlist` 走同一条接口，不新开路由。放在这里而不是让
      // 读者先进详情页再回来，是因为这块位置的用途就是"现在决定看不看"。
      const csrfToken = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
      document.querySelectorAll('[data-hero-watchlist]').forEach(button => {
        button.addEventListener('click', async () => {
          const mediaID = button.getAttribute('data-hero-watchlist');
          if (!mediaID) return;
          const next = button.getAttribute('aria-pressed') !== 'true';
          button.disabled = true;
          try {
            const response = await fetch('/api/v1/user-media/preferences/' + mediaID, {
              method: 'POST', credentials: 'same-origin',
              headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken },
              body: JSON.stringify({ watchlist: next })
            });
            if (response.status === 401) { window.location.assign('/login'); return; }
            if (!response.ok) throw new Error('unavailable');
            // 请求体的键是 `watchlist`，回来的却是 `ServerMediaUserPreference`
            // 的 `isWatchlist`——两边不是同一个名字。
            const preference = await response.json();
            const active = preference?.isWatchlist === true;
            button.setAttribute('aria-pressed', active ? 'true' : 'false');
            const label = button.querySelector('span');
            if (label) label.textContent = active ? '已想看' : '加入想看';
          } catch (_) {
            // 状态没改成就别谎报：按钮留在原来的样子。
          } finally {
            button.disabled = false;
          }
        });
      });
    })();
    """#

    /// Delegates to the shared implementation in `ServerWebHTML`.
    private static func escape(_ value: String) -> String { ServerWebHTML.escape(value) }
}

private extension ServerLibraryItem {
    var isMusic: Bool { type.caseInsensitiveCompare("music") == .orderedSame }
    var isPhoto: Bool { type.caseInsensitiveCompare("photo") == .orderedSame }
}

/// 让网页卡片也能走客户端那条「最近播放」规则。
///
/// `ServerLibraryItem` 住在没有任何依赖的 DTO target 里，`MediaItem` 住在
/// `MediaLibCore`，两边互相看不见；`MediaLibServer` 是唯一同时看得见两者的地
/// 方，所以认领写在这里。
extension ServerLibraryItem: PlaybackRecencyRepresentable {
    public var isMusicMedia: Bool { type.caseInsensitiveCompare("music") == .orderedSame }
    public var hasRecencyTrace: Bool { (userState?.playCount ?? 0) > 0 || userState?.lastPlayedAt != nil }
    public var recencyDate: Date { userState?.lastPlayedAt ?? userState?.updatedAt ?? .distantPast }
}
