import Foundation
import MediaLibServerProtocol

/// 认证资料库浏览页。页面只包含同源静态脚本，所有服务器返回文本均通过
/// `textContent` 写入 DOM，避免把媒体元数据变成 HTML 注入面。
enum ServerWebLibraryPage {
    /// What a browse page is scoped to.
    ///
    /// `/library` used to render an unscoped grid of everything the account could
    /// see — every episode, track and photo in one list. It was nobody's
    /// destination and it was where `返回` stranded readers, so it is gone.  A
    /// browse page now always names its scope in its own path.
    struct Scope: Equatable {
        /// The reserved id meaning "all video types", used by the sidebar's 视频
        /// group when it has no single category selected.
        static let videoGroupID = "video"

        let categoryID: String?
        let title: String
        let path: String
        /// 远程来源作用域的不透明 ID。为 nil 时页面浏览的是本地一级分类。
        let remoteScopeID: String?

        /// 远程来源／资料库的浏览作用域，与客户端的远程分组一一对应。
        /// 保险库作用域。它没有分类 id、也没有远程作用域 id——范围完全由服务端
        /// 按"已解锁 + 已授权"决定，页面这一侧只是声明"这一页要的是保险库"。
        let isVault: Bool

        init(vaultTitle: String) {
            self.categoryID = nil
            self.title = vaultTitle
            self.path = "/vault"
            self.remoteScopeID = nil
            self.isVault = true
        }

        init(remoteScopeID: String, title: String) {
            self.categoryID = nil
            self.title = title
            self.path = "/remote/\(remoteScopeID)"
            self.remoteScopeID = remoteScopeID
            self.isVault = false
        }

        init?(path: String, allowedCategories: [ServerLibraryCategory]) {
            self.remoteScopeID = nil
            self.isVault = false
            guard path.hasPrefix("/category/") else { return nil }
            let rawID = String(path.dropFirst("/category/".count))
            guard !rawID.isEmpty, !rawID.contains("/") else { return nil }
            let identifier = rawID.removingPercentEncoding ?? rawID
            if identifier == Self.videoGroupID {
                self.categoryID = nil
                self.title = "视频"
                self.path = "/category/\(Self.videoGroupID)"
                return
            }
            // Only a category this principal is actually allowed to see resolves;
            // anything else is a 404 rather than a silently unscoped page.
            guard let category = allowedCategories.first(where: { $0.id == identifier }),
                  let encoded = ServerWebURL.pathSegment(category.id)
            else { return nil }
            self.categoryID = category.id
            self.title = category.title
            self.path = "/category/\(encoded)"
        }
    }

    enum Page {
        case library
        case vault
        case search
        case queue
        case continuing
        case history
        case favorites
        case watchlist
        case ratings
        case watched
        case unwatched

        var path: String {
            switch self {
            case .library: return "/category/\(Scope.videoGroupID)"
            case .vault: return "/vault"
            case .search: return "/search"
            case .queue: return "/queue"
            case .continuing: return "/watching"
            case .history: return "/history"
            case .favorites: return "/favorites"
            case .watchlist: return "/watchlist"
            case .ratings: return "/ratings"
            case .watched: return "/watched"
            case .unwatched: return "/unwatched"
            }
        }

        var title: String {
            switch self {
            case .library: return "浏览资料库"
            case .vault: return "保险库"
            case .search: return "全局搜索"
            case .queue: return "播放队列"
            case .continuing: return "继续观看"
            case .history: return "播放历史"
            case .favorites: return "我的收藏"
            case .watchlist: return "想看清单"
            case .ratings: return "我的评分"
            case .watched: return "已看内容"
            case .unwatched: return "未看内容"
            }
        }

        var eyebrow: String {
            switch self {
            case .library: return "Mlink Library"
            case .vault: return "Vault"
            case .search: return "MediaLIB Search"
            case .queue: return "Web Queue"
            case .continuing: return "Continue Watching"
            case .history: return "Playback History"
            case .favorites: return "My Favorites"
            case .watchlist: return "My Watchlist"
            case .ratings: return "My Ratings"
            case .watched: return "Watched"
            case .unwatched: return "Unwatched"
            }
        }

        var subtitle: String {
            switch self {
            case .library: return "你的影片、剧集和更多内容，都在这里。"
            case .vault: return "已在这台 Mac 上解锁。离开 App 时它会重新上锁。"
            case .search: return "片名、人物、专辑——想找什么都可以搜。"
            case .queue: return "接下来要看的内容，都排好了。"
            case .continuing: return "从上次停下的地方，接着看。"
            case .history: return "你最近看过的内容，最新的排在前面。"
            case .favorites: return "你标记喜欢的一切。"
            case .watchlist: return "先收着，等你有空再看。"
            case .ratings: return "你打过分的内容。"
            case .watched: return "你已经看完的内容。"
            case .unwatched: return "还没开始，或者还没看完的内容。"
            }
        }

        var playbackFilter: String? {
            switch self {
            case .queue, .continuing: return ServerLibraryPlaybackFilter.inProgress.rawValue
            case .history: return ServerLibraryPlaybackFilter.history.rawValue
            case .watched: return ServerLibraryPlaybackFilter.watched.rawValue
            case .unwatched: return ServerLibraryPlaybackFilter.unwatched.rawValue
            case .library, .vault, .search, .favorites, .watchlist, .ratings: return nil
            }
        }

        var preferenceFilter: String? {
            switch self {
            case .favorites: return ServerLibraryPreferenceFilter.favorite.rawValue
            case .watchlist: return ServerLibraryPreferenceFilter.watchlist.rawValue
            case .ratings: return ServerLibraryPreferenceFilter.rated.rawValue
            default: return nil
            }
        }

        var defaultSort: ServerLibrarySort {
            self == .history ? .lastPlayed : .recentlyUpdated
        }
    }

    /// 排序键的中文名，与 macOS 客户端 `LibrarySortMode.title` 逐字一致。
    /// 两端说的是同一件事时，就不该有两套说法。
    private static func sortLabel(_ sort: ServerLibrarySort) -> String {
        switch sort {
        case .recentlyUpdated: return "最近更新"
        case .dateAdded: return "最近添加"
        case .title: return "标题"
        case .year: return "年份"
        case .runtime: return "时长"
        case .progress: return "观看进度"
        case .score: return "评分"
        case .rating: return "评级"
        case .lastPlayed: return "最近播放"
        }
    }

    static func render(
        serverName: String,
        csrfToken: String,
        showAdministration: Bool,
        page: Page = .library,
        categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras,
        selectedCategoryID: String? = nil,
        scope: Scope? = nil,
        searchQuery: String = "",
        facets: ServerLibraryFacetsResponse = ServerLibraryFacetsResponse(genres: [], availableSorts: [])
    ) -> String {
        let activeNavigation: ServerWebNavigation.Active = {
            switch page {
            case .library: return .library
            case .vault: return .vault
            case .search: return .search
            case .queue: return .queue
            case .continuing: return .watching
            case .history: return .history
            case .favorites: return .favorites
            case .watchlist: return .watchlist
            case .ratings: return .ratings
            case .watched: return .watched
            case .unwatched: return .unwatched
            }
        }()
        let sidebar = ServerWebNavigation.render(
            active: activeNavigation,
            showAdministration: showAdministration,
            note: .library,
            categories: categories,
            activeCategoryID: page == .library ? selectedCategoryID : nil,
            extras: sidebarExtras
        )
        let playbackFilter = page.playbackFilter ?? ""
        let preferenceFilter = page.preferenceFilter ?? ""
        let headerIcon = headerIcon(for: page, scope: scope)
        let pageTitle = scope?.title ?? page.title
        let pagePath = scope?.path ?? page.path
        // 有作用域时用客户端逐字相同的那句；无作用域的几个视图各自解释了它们的
        // 隐私语义，那些句子比通用句更有信息量，所以保留。
        let pageSubtitle = scope.map { _ in "浏览、筛选和管理当前内容" } ?? page.subtitle

        // 分类下拉只在没有作用域时出现。`/category/*` 的作用域已经由侧栏表达，
        // 页面里再放一个分类下拉不但重复，还正是从前那段"改下拉就改标题"的
        // 客户端脚本存在的原因。
        let categorySelect = scope == nil
            ? ServerWebUI.select(
                id: "type",
                name: "type",
                label: "分类",
                options: [(value: "", label: "全部分类", selected: true)]
                    + categories.prefix(32).compactMap { category -> (String, String, Bool)? in
                        guard ServerWebURL.queryValue(category.id) != nil else { return nil }
                        return (category.id, "\(category.title)（\(max(category.itemCount, 0))）", false)
                    }
            )
            : ""
        // 题材来自数据本身。一个空的"全部类型"下拉是一个永远筛不出东西的控件，
        // 所以没有题材时整个控件不出现。
        let genreSelect = facets.genres.isEmpty
            ? ""
            : ServerWebUI.select(
                id: "genre",
                name: "genre",
                label: "类型",
                options: [(value: "", label: "全部类型", selected: true)]
                    + facets.genres.map { (value: $0, label: $0, selected: false) }
            )
        // 历史页的"最近播放"是它自己的默认键，其余键按数据存在与否由服务端裁剪。
        let availableSorts: [ServerLibrarySort] = {
            var sorts = facets.availableSorts.isEmpty
                ? [ServerLibrarySort.recentlyUpdated, .dateAdded, .title, .year, .progress]
                : facets.availableSorts
            if page == .history { sorts.insert(.lastPlayed, at: 0) }
            return sorts
        }()
        let sortControl = ServerWebUI.sortControl(
            selectID: "sort",
            orderButtonID: "sort-order",
            options: availableSorts.map {
                (value: $0.rawValue, label: sortLabel($0), selected: $0 == page.defaultSort)
            },
            isReversed: false
        )
        let content = """
        \(ServerWebPageHeader.render(
            icon: headerIcon,
            eyebrow: page.eyebrow,
            title: pageTitle,
            subtitle: pageSubtitle,
            countID: "count",
            search: ServerWebUI.searchField(
                id: "query",
                label: "搜索\(pageTitle)",
                placeholder: "搜索\(pageTitle)",
                action: "/search",
                value: page == .search ? searchQuery : ""
            ),
            titleID: "heading-title",
            iconID: "heading-icon"
        ))
        \(ServerWebUI.controlBar(
            label: "筛选与排序",
            chipsLabel: "观看状态",
            chips: [
                .init(label: "全部", value: "", selected: true),
                .init(label: "正在观看", value: "inProgress"),
                .init(label: "未观看", value: "unwatched"),
                .init(label: "已观看", value: "watched"),
                .init(label: "想看", value: "watchlist"),
                .init(label: "喜欢", value: "favorite")
            ],
            chipsName: "state_tab",
            chipsGroupID: "playback-filter-tabs",
            mobileDisclosureLabel: "高级筛选",
            trailing: categorySelect + genreSelect + sortControl
                + #"<button id="submit" type="submit" hidden>应用筛选</button>"#,
            trailingID: "advanced-filters",
            formID: "filters"
        ))
        <p class="ui-state-line library-status t-footnote t-tertiary" id="status" role="status" aria-live="polite">正在载入资料库…</p>
        <div class="ui-media-grid" id="grid" aria-busy="true"></div>
        \(ServerWebUI.emptyState(
            icon: headerIcon.emptyStateGlyph,
            title: "没有可显示的内容",
            message: "换个筛选条件试试。",
            id: "library-empty",
            hidden: true
        ))
        <nav class="ui-pager" id="pager" aria-label="资料库分页">
          \(ServerWebUI.button("上一页", variant: .secondary, icon: .chevronLeft, id: "previous", disabled: true))
          <span class="ui-pager-label" id="page-label">第 1 页</span>
          \(ServerWebUI.button("下一页", variant: .secondary, icon: .chevronRight, id: "next", disabled: true))
        </nav>
        """
        return ServerWebDocument.render(
            title: pageTitle,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/library.css"],
            pageScripts: ["/assets/overlays.js", "/assets/library.js"],
            bodyAttributes: #" data-search-landing="\#(page == .search && searchQuery.isEmpty ? "true" : "")" data-page-route="\#(escape(pagePath))" data-scope-type="\#(escape(scope?.categoryID ?? ""))" data-scope-group="\#(scope != nil && scope?.categoryID == nil && scope?.remoteScopeID == nil && scope?.isVault != true ? "video" : "")" data-remote-scope="\#(escape(scope?.remoteScopeID ?? ""))" data-vault-scope="\#(scope?.isVault == true || page == .vault ? "true" : "")" data-playback-filter="\#(playbackFilter)" data-preference-filter="\#(preferenceFilter)" data-default-sort="\#(page.defaultSort.rawValue)""#,
            tint: .video
        )
    }

    /// Each of the nine views gets its own header glyph so the page identifies
    /// itself at a glance instead of reusing one generic library mark.
    ///
    /// A scoped category names its own medium, so it gets that medium's glyph
    /// straight from the shared family.  This used to happen in the browser: the
    /// page script kept a private map of five SVG paths and picked one by
    /// substring-matching the Chinese title, which was a second icon vocabulary
    /// living outside `ServerWebIcon` and silently fell back to a folder for
    /// every category it did not recognise.
    private static func headerIcon(for page: Page, scope: Scope?) -> ServerWebPageHeader.Icon {
        // 分类 id 就是 MediaType 的 rawValue；这里按字符串匹配，免得展示层为了
        // 一个图标去依赖 Core 的媒体模型。
        switch scope?.categoryID {
        case "movie": return .movie
        case "tvShow": return .series
        case "anime": return .anime
        case "documentary": return .documentary
        case "variety": return .variety
        case "homeVideo", "other": return .otherVideo
        case "music": return .music
        case "photo": return .photos
        case .some: return .library
        case nil: break
        }
        switch page {
        case .library: return .library
        case .vault: return .vault
        case .search: return .search
        case .queue: return .queue
        case .continuing: return .home
        case .history: return .history
        case .favorites: return .favorites
        case .watchlist: return .watchlist
        case .ratings: return .ratings
        case .watched, .unwatched: return .library
        }
    }

    /// 四个资料库视图共用的页面样式。以同源静态资源交付，避免每次切换
    /// 浏览/搜索/续播/历史页都重新传输和解析同一套布局规则。
    static let style = #"""
    /* 筛选条本身来自 primitives 的 .ui-control-bar；页面样式只负责它与结果之间
       的距离。这里曾经是一整套私有的 .library-filters 布局规则。 */
    #filters { margin-bottom: var(--space-6); }
    .library-status { padding-bottom: var(--space-4); }

    /* 曲目行的全部规则来自 primitives 的 `.ui-track-*`。这一页此前带着一份与
       音乐目录页逐字相同的拷贝，外加一条拼错的死规则（`.music-faverite`，全仓
       没有任何元素用这个名字）。列表本身只需要声明"结果区改成单列"。 */
    #grid.music-layout { display: grid; grid-template-columns: minmax(0, 1fr); gap: 0; }

    """#

    static let script = #"""
    (() => {
      'use strict';
      // A 24-card page covers the visible desktop grid while avoiding an
      // initial burst of 48 JSON records and poster decodes. Subsequent pages
      // remain available through the normal pager.
      const pageSize = 24;
      const form = document.getElementById('filters');
      const query = document.getElementById('query');
      // 分类下拉只在无作用域的视图上渲染，题材下拉只在该作用域确实有题材时渲染，
      // 所以两者都可能不存在。
      const type = document.getElementById('type');
      const genre = document.getElementById('genre');
      const sort = document.getElementById('sort');
      const sortOrder = document.getElementById('sort-order');
      const submit = document.getElementById('submit');
      const grid = document.getElementById('grid');
      const status = document.getElementById('status');
      const count = document.getElementById('count');
      const previous = document.getElementById('previous');
      const next = document.getElementById('next');
      const pageLabel = document.getElementById('page-label');
      const emptyState = document.getElementById('library-empty');
      const pager = document.getElementById('pager');
      const csrfToken = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
      // 浏览页的路径是 `/category/{id}`，不是 `/library`——后者不是一个路由。
      // 这个白名单从前漏了分类页，于是每次筛选都把地址栏重写成 `/library?…`，
      // 刷新就 404。
      // `/search` 没有查询词时不发请求：一个"全部内容"的结果页不是任何人的目的地，
      // 而且它会把最贵的一次浏览查询花在没人要的结果上。落地状态是一句提示。
      const searchLanding = document.body.dataset.searchLanding === 'true';
      // 远程来源页 `/remote/{scopeID}` 也漏过一次，症状是同一种：`history.replaceState`
      // 把地址栏改写成 `/search?…&remoteScope=…`，刷新就落到那个什么都不显示的
      // 搜索落地页——看起来就是"Emby 目录点得进去、刷新就没了"。
      const routeAllowList = ['/search', '/queue', '/watching', '/history', '/favorites', '/watchlist', '/ratings', '/watched', '/unwatched', '/vault'];
      const declaredRoute = document.body.dataset.pageRoute || '';
      const pageRoute = routeAllowList.includes(declaredRoute)
        || /^\/category\/[^/?#]+$/.test(declaredRoute)
        || /^\/remote\/[0-9a-f]{1,64}$/.test(declaredRoute)
        ? declaredRoute
        : '/search';
      // 分类页的作用域来自路径，不来自查询串。以前它只看 `?type=`，于是
      // `/category/movie` 加载的是整个资料库。
      const scopeTypes = new Set(['movie', 'tvShow', 'anime', 'documentary', 'variety', 'homeVideo', 'music', 'other', 'episode', 'photo']);
      const scopeType = scopeTypes.has(document.body.dataset.scopeType || '') ? document.body.dataset.scopeType : '';
      const scopeGroup = document.body.dataset.scopeGroup === 'video' ? 'video' : '';
      // 远程来源作用域：只允许十六进制的不透明 ID，避免把任意串拼进查询。
      const rawRemoteScope = document.body.dataset.remoteScope || '';
      const remoteScope = /^[0-9a-f]{1,64}$/.test(rawRemoteScope) ? rawRemoteScope : '';
      // 保险库作用域。范围由服务端按"已解锁 + 已授权"决定，这里只是把这一页的
      // 身份带上；没有这个标记时服务端不会返回任何保险库条目。
      const vaultScope = document.body.dataset.vaultScope === 'true';
      var playbackFilter = ['inProgress', 'history', 'watched', 'unwatched'].includes(document.body.dataset.playbackFilter) ? document.body.dataset.playbackFilter : '';
      var preferenceFilter = ['favorite', 'watchlist', 'rated'].includes(document.body.dataset.preferenceFilter) ? document.body.dataset.preferenceFilter : '';
      const sortKeys = ['recentlyUpdated', 'dateAdded', 'title', 'year', 'runtime', 'progress', 'score', 'rating', 'lastPlayed'];
      // 旧的四个值仍然出现在用户收藏的链接和地址栏历史里，所以深链继续被认。
      const legacySorts = { updatedDescending: 'recentlyUpdated', titleAscending: 'title', yearDescending: 'year', lastPlayedDescending: 'lastPlayed' };
      const defaultSort = document.body.dataset.defaultSort === 'lastPlayed' ? 'lastPlayed' : 'recentlyUpdated';
      var reversed = false;
      // The shell may have already fetched this exact first page on pointerdown.
      // Keep the response only in the current document realm (never storage),
      // with a very short lifetime; successful personal mutations clear it in
      // the shared fetch boundary before a collection can be revisited.
      const browseCache = (() => {
        const existing = window.__medialibLibraryBrowseCache;
        if (existing && typeof existing.get === 'function' && typeof existing.set === 'function' && typeof existing.clear === 'function') return existing;
        const created = new Map();
        window.__medialibLibraryBrowseCache = created;
        return created;
      })();
      const browseCacheLifetime = 8_000;
      const maximumBrowseCacheEntries = 12;
      var offset = 0;
      var total = 0;
      var controller = null;

      const element = (name, className, text) => {
        const node = document.createElement(name);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
      };

      const safeInitialState = () => {
        const params = new URLSearchParams(window.location.search);
        const q = params.get('q') || '';
        query.value = q.slice(0, 128);
        const rawSort = params.get('sort') || '';
        const resolvedSort = legacySorts[rawSort] || rawSort;
        sort.value = defaultSort;
        if (sortKeys.includes(resolvedSort) && Array.from(sort.options).some(option => option.value === resolvedSort)) sort.value = resolvedSort;
        // 旧的 sort 值各自代表一个完整状态，所以它们隐含正序，不读 order。
        reversed = !legacySorts[rawSort] && params.get('order') === 'reverse';
        if (sortOrder) syncSortOrder();
        const initialGenre = params.get('genre') || '';
        if (genre && Array.from(genre.options).some(option => option.value === initialGenre)) genre.value = initialGenre;
        const parsedOffset = Number(params.get('offset') || '0');
        offset = Number.isSafeInteger(parsedOffset) && parsedOffset >= 0 && parsedOffset <= 1000000 ? parsedOffset : 0;
        return { type: params.get('type') || '', group: params.get('group') === 'video' ? 'video' : '' };
      };

      function syncSortOrder() {
        const label = reversed ? '倒序' : '正序';
        sortOrder.setAttribute('aria-pressed', reversed ? 'true' : 'false');
        sortOrder.setAttribute('aria-label', label);
        sortOrder.setAttribute('title', label);
        // 一个箭头两种朝向，而不是两个图标：方向本身就是这个控件表达的全部内容。
        sortOrder.classList.toggle('is-reversed', reversed);
      }

      // Keep a valid deep-linked category even when its current count is zero
      // and therefore it is not present in the compact <select>. Otherwise the
      // first load rewrites a scoped URL to an unfiltered one, making a
      // successful sidebar transition look like a no-op to the user.
      const initialState = safeInitialState();
      var requestedType = scopeType || initialState.type;
      var requestedGroup = scopeType ? '' : (scopeGroup || initialState.group);
      if (type && Array.from(type.options).some(option => option.value === requestedType)) type.value = requestedType;

      const reload = () => { offset = 0; void loadPage(); };
      if (type) type.addEventListener('change', () => { requestedType = ''; requestedGroup = ''; reload(); });
      if (genre) genre.addEventListener('change', reload);
      sort.addEventListener('change', reload);
      if (sortOrder) {
        sortOrder.addEventListener('click', () => { reversed = !reversed; syncSortOrder(); reload(); });
      }

      const stateTabs = document.querySelectorAll('input[name="state_tab"]');
      let currentTabVal = playbackFilter || preferenceFilter || '';
      for (const tab of stateTabs) {
        if (tab.value === currentTabVal) tab.checked = true;
        tab.addEventListener('change', () => {
          if (tab.checked) {
            playbackFilter = '';
            preferenceFilter = '';
            if (['inProgress', 'history', 'watched', 'unwatched'].includes(tab.value)) playbackFilter = tab.value;
            if (['watchlist', 'favorite', 'rated'].includes(tab.value)) preferenceFilter = tab.value;
            offset = 0;
            form.dispatchEvent(new Event('submit', { cancelable: true }));
          }
        });
      }

      async function fetchJSON(path, signal) {
        const response = await fetch(path, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal });
        if (!response.ok) throw new Error(response.status === 401 ? '登录已失效，请重新登录。' : `服务暂时不可用（${response.status}）。`);
        return response.json();
      }

      function fetchBrowsePage(path, signal) {
        const now = Date.now();
        const cached = browseCache.get(path);
        if (cached && cached.expiresAt > now) return cached.promise;
        browseCache.delete(path);
        const promise = fetchJSON(path, signal);
        const entry = { expiresAt: now + browseCacheLifetime, promise };
        browseCache.set(path, entry);
        promise.catch(() => {
          if (browseCache.get(path) === entry) browseCache.delete(path);
        });
        while (browseCache.size > maximumBrowseCacheEntries) {
          const oldest = browseCache.keys().next().value;
          if (oldest === undefined) break;
          browseCache.delete(oldest);
        }
        return promise;
      }

      async function addToQueue(mediaID) {
        const controller = new AbortController();
        const timer = window.setTimeout(() => controller.abort(), 10000);
        try {
          const response = await fetch('/api/v1/queue', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken },
            body: JSON.stringify({ action: 'add', mediaID }),
            signal: controller.signal
          });
          if (response.status === 401) { window.location.assign('/login'); return false; }
          if (!response.ok) throw new Error();
          await response.json();
          return true;
        } finally { window.clearTimeout(timer); }
      }

      function formatMusicDuration(value) {
        const seconds = Number(value);
        if (!Number.isFinite(seconds) || seconds < 0) return '—';
        const total = Math.round(seconds);
        return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
      }

      function renderMusicHeader() {
        const head = element('div', 'ui-track-head');
        for (const title of ['歌曲', '艺术家', '专辑', '歌词', '时长', '']) head.append(element('span', '', title));
        return head;
      }

      // 图标由 Swift 从 `ServerWebIcon` 插值下来。此前这里既有一个自建的
      // `svgGlyph(d, …)`，又在唯一的调用点把 `.play` 的路径**再抄了一遍**——
      // 一份路径改了，另一份不会跟着改。
      \#(ServerWebIcon.scriptHelper(for: [.play, .star]))
      // 取色由 Swift 从 `ServerWebArtworkPalette` 插值下来。此前这里抄了一份
      // 桶数写死为 13/8 的版本，而服务端真正的桶数不是这两个数——同一个条目，
      // 服务端渲染的卡片和脚本补进来的卡片会落到两种颜色上。
      \#(ServerWebArtworkPalette.scriptHelper)
      const artworkPaletteToken = (seed, context) => medialibArtworkPalette(seed, context || 'poster');

      function setArtworkPalette(node, seed, context) {
        node.dataset.artworkPalette = artworkPaletteToken(seed, context);
      }

      function renderMusicRow(item, index) {
        const itemID = String(item?.id || '');
        const title = String(item?.title || '未命名音乐');
        const artist = String(item?.artist || '未知艺术家');
        const album = String(item?.album || '未归档专辑');
        const row = element('a', 'ui-track-row');
        row.href = `/play/${encodeURIComponent(itemID)}#play`;
        row.dataset.musicPlay = itemID;
        row.dataset.musicTitle = title;
        row.dataset.musicSubtitle = artist;
        row.setAttribute('aria-label', `播放音乐 ${title}`);
        const link = element('span', 'ui-track-main');
        const cover = element('span', 'ui-track-art', title.slice(0, 1).toUpperCase());
        setArtworkPalette(cover, itemID || title, 'music');
        if (item?.artworkAvailable === true && itemID) {
          const image = document.createElement('img');
          image.alt = '';
          image.loading = index < 8 ? 'eager' : 'lazy';
          image.decoding = 'async';
          if (index < 8) image.fetchPriority = 'high';
          image.addEventListener('error', () => {
            if (cover.contains(image)) cover.replaceChildren(title.slice(0, 1).toUpperCase());
          }, { once: true });
          cover.replaceChildren(image);
          image.src = `/api/v1/images/${encodeURIComponent(itemID)}/poster?size=160`;
        }
        const copy = element('span', 'ui-track-copy');
        const name = element('strong', '', title); name.title = title;
        copy.append(name, element('small', '', artist));
        link.append(cover, copy);
        const lyrics = element('span', 'ui-track-meta ui-track-lyrics', '—');
        lyrics.setAttribute('aria-label', '暂无歌词');
        const duration = element('span', 'ui-track-duration', formatMusicDuration(item?.durationSeconds));
        const favorite = element('span', 'ui-track-favorite');
        favorite.setAttribute('aria-hidden', 'true');
        favorite.append(medialibIcon('star', 'icon icon-sm'));
        row.append(link, element('span', 'ui-track-meta ui-track-artist', artist), element('span', 'ui-track-meta ui-track-album', album), lyrics, duration, favorite);
        return row;
      }

      // A track only becomes a table row when the whole result set is music.
      // In a mixed result it stays a card, because dropping a six-column row
      // into a poster grid leaves the cell misaligned and the row unreadable.
      function renderItem(item, index, asMusicList) {
        if (asMusicList && String(item?.type || '').toLowerCase() === 'music') return renderMusicRow(item, index);
        const article = element('article', 'ui-media-card');
        const mediaType = String(item.type || '').toLowerCase();
        const link = element('a');
        const isSeries = item.isSeries === true;
        const itemID = String(item.id || '');
        const title = String(item.title || '未命名媒体');
        link.href = isSeries ? `/series/${encodeURIComponent(itemID)}/play` : `/item/${encodeURIComponent(itemID)}#play`;
        link.setAttribute('aria-label', `查看详情并播放 ${title}`);
        const posterFallback = String(item.type || 'M').slice(0, 1).toUpperCase();
        const poster = element('div', 'ui-poster');
        setArtworkPalette(article, itemID || posterFallback, 'poster');
        // The fallback carries the title, so a card without artwork is still
        // identifiable rather than an anonymous coloured rectangle.
        const glyph = element('span', 'ui-poster-fallback', title);
        poster.append(glyph);
        if (item.artworkAvailable === true) {
          const image = document.createElement('img');
          image.alt = '';
          // 首行不能是 lazy：懒加载要等布局判定完才发请求，而 `fetchPriority=high`
          // 只能作用在一个已经被推迟的请求上，两者放一起等于自相抵消。音乐行与
          // 首页的货架早就是 eager，这里是唯一还没跟上的。
          image.loading = index < 6 ? 'eager' : 'lazy';
          image.decoding = 'async';
          if (index < 6) image.fetchPriority = 'high';
          image.addEventListener('load', () => {
            image.dataset.ready = 'true';
            if (poster.contains(glyph)) glyph.remove();
          }, { once: true });
          // 失败不在这里处理：外壳会重试三次，把 <img> 从文档里摘掉等于让它
          // 连一次重试的机会都没有。兜底那一层本来就压在下面，图取不回来时读者
          // 看到的就是它。

          poster.append(image);
          image.src = `/api/v1/images/${encodeURIComponent(String(item.id || ''))}/poster?size=320`;
        }

        const corner = element('span', 'ui-poster-corner');
        const sourceLabel = ({emby:'Emby',jellyfin:'Jellyfin',plex:'Plex',mlink:'Mlink'})[item.remoteSourceKind]; if (sourceLabel) corner.append(element('span', 'ui-media-badge', sourceLabel));
        if (corner.childElementCount) poster.append(corner);

        link.append(poster);

        const isPhoto = mediaType === 'photo';
        if (!isSeries && !isPhoto && itemID) {
          const quickPlay = element('a', 'ui-play-affordance');
          const isMusic = mediaType === 'music';
          quickPlay.href = `/play/${encodeURIComponent(itemID)}#play`;
          quickPlay.setAttribute('aria-label', `${isMusic ? '播放音乐' : '播放视频'} ${title}`);
          const playMark = element('span');
          playMark.append(medialibIcon('play', 'icon icon-md'));
          quickPlay.append(playMark);
          if (isMusic) {
            quickPlay.dataset.musicPlay = itemID;
            quickPlay.dataset.musicTitle = title;
            quickPlay.dataset.musicSubtitle = String(item.year || 'MediaLIB 音乐');
          }
          poster.append(quickPlay);
        }

        const caption = element('span', 'ui-media-title', title);
        caption.title = title;
        // 海报下面不再重复分类和年份。
        //
        // 一整墙卡片里每一张都写着「anime · 2025」，那两个字段既不区分相邻的卡片，
        // 也不是读者在海报墙上找片子的依据——封面和片名才是。留下的是**这一张**
        // 才有的东西：观看进度，以及历史页里的上次观看时间。
        const metaParts = [];
        const state = item.userState;
        if (pageRoute === '/history' && state && state.lastPlayedAt) {
          const played = new Date(state.lastPlayedAt);
          if (!Number.isNaN(played.getTime())) metaParts.push(played.toLocaleDateString());
        } else if (state && Number(state.progress) > 0 && state.isWatched !== true) {
          metaParts.push(`已看 ${Math.round(Math.max(0, Math.min(1, Number(state.progress))) * 100)}%`);
        }
        const meta = element('span', 'ui-media-meta', metaParts.join(' · '));
        article.append(link, caption, meta);
        return article;
      }

      function renderLoadingCards() {
        grid.classList.remove('music-layout');
        const fragment = document.createDocumentFragment();
        // Skeletons reserve the real card's footprint so arriving content does
        // not shove the grid around.
        for (let index = 0; index < 8; index += 1) {
          const card = element('article', 'ui-media-card');
          card.setAttribute('aria-hidden', 'true');
          card.append(element('div', 'ui-skeleton ui-skeleton-poster'));
          card.append(element('span', 'ui-skeleton ui-skeleton-line'));
          card.append(element('span', 'ui-skeleton ui-skeleton-line-sm'));
          fragment.append(card);
        }
        grid.replaceChildren(fragment);
      }

      async function loadPage(updateHistory = true) {
        if (controller) controller.abort();
        controller = new AbortController();
        const timeout = window.setTimeout(() => controller.abort(), 10000);
        submit.disabled = true;
        previous.disabled = true;
        next.disabled = true;
        grid.setAttribute('aria-busy', 'true');
        renderLoadingCards();
        status.hidden = false;
        status.classList.remove('error');
        status.textContent = '正在载入资料库…';
        if (emptyState) emptyState.hidden = true;
        const params = new URLSearchParams({ offset: String(offset), limit: String(pageSize), sort: sort.value });
        // 只在非默认时写入，外壳的预取键才会与这里逐字相同。多写一个 `order=primary`
        // 不会报错，只是预取从此永远落空——而且没有任何迹象。
        if (reversed) params.set('order', 'reverse');
        const normalizedQuery = query.value.trim();
        if (normalizedQuery) params.set('q', normalizedQuery);
        if (genre && genre.value) params.set('genre', genre.value);
        const activeType = (type ? type.value : '') || requestedType;
        if (activeType) params.set('type', activeType);
        if (requestedGroup && !activeType) params.set('group', requestedGroup);
        if (remoteScope) params.set('remoteScope', remoteScope);
        if (vaultScope) params.set('vault', '1');
        if (playbackFilter) params.set('state', playbackFilter);
        if (preferenceFilter) params.set('preference', preferenceFilter);
        try {
          const data = await fetchBrowsePage(`/api/v1/library/browse?${params.toString()}`, controller.signal);
          total = Math.max(0, Number(data.totalItemCount) || 0);
          const items = Array.isArray(data.items) ? data.items : [];
          const musicOnly = items.length > 0 && items.every(item => String(item?.type || '').toLowerCase() === 'music');
          grid.classList.toggle('music-layout', musicOnly);
          const fragment = document.createDocumentFragment();
          if (musicOnly) fragment.append(renderMusicHeader());
          for (const [index, item] of items.entries()) fragment.append(renderItem(item, index, musicOnly));
          grid.replaceChildren(fragment);
          if (count) count.textContent = ` · ${total.toLocaleString()} 项`;
          const currentPage = Math.floor(offset / pageSize) + 1;
          const pageCount = Math.max(1, Math.ceil(total / pageSize));
          pageLabel.textContent = `第 ${currentPage} / ${pageCount} 页`;
          previous.disabled = offset === 0;
          next.disabled = !Boolean(data.hasMore);
          if (items.length === 0) {
            // A bare sentence under an empty grid reads like a failure. The same
            // copy goes into the shared empty state the rest of the product uses,
            // and the pager is hidden rather than offering "第 1 / 1 页" of nothing.
            const [emptyTitle, emptyBody] = playbackFilter === 'inProgress' ? ['没有未完成的内容', '开始播放后，未看完的内容会出现在这里。']
              : (playbackFilter === 'history' ? ['还没有播放历史', '播放过的内容会按最近播放时间出现在这里。']
              : (playbackFilter === 'watched' ? ['还没有已看内容', '标记为已看或播完的内容会出现在这里。']
              : (playbackFilter === 'unwatched' ? ['当前分类中没有未看内容', '换一个分类，或清除筛选条件后再试。']
              : (preferenceFilter === 'favorite' ? ['还没有收藏内容', '在媒体详情页点击收藏，之后就会出现在这里。']
              : (preferenceFilter === 'watchlist' ? ['想看清单还是空的', '在媒体详情页加入想看，之后就会出现在这里。']
              : (preferenceFilter === 'rated' ? ['还没有评分内容', '在媒体详情页给媒体评分，之后就会出现在这里。']
              : ['没有符合条件的媒体', '尝试清除关键词，或切换到其它分类。']))))));
            if (emptyState) {
              const titleNode = emptyState.querySelector('.ui-empty-title');
              const bodyNode = emptyState.querySelector('.ui-empty-body');
              if (titleNode) titleNode.textContent = emptyTitle;
              if (bodyNode) bodyNode.textContent = emptyBody;
              emptyState.hidden = false;
            }
            status.hidden = true;
            if (pager) pager.hidden = true;
          } else {
            status.hidden = true;
            if (emptyState) emptyState.hidden = true;
            if (pager) pager.hidden = false;
          }
          if (updateHistory) history.replaceState(null, '', `${pageRoute}?${params.toString()}`);
        } catch (error) {
          if (error && error.name === 'AbortError') status.textContent = '请求超时。请检查服务状态后重试。';
          else status.textContent = error instanceof Error ? error.message : '资料库载入失败，请重试。';
          status.classList.add('error');
          status.hidden = false;
          // A failure is not an empty library: show the error alone.
          if (emptyState) emptyState.hidden = true;
          if (pager) pager.hidden = true;
          grid.replaceChildren();
          if (count) count.textContent = ' · 载入失败';
        } finally {
          window.clearTimeout(timeout);
          submit.disabled = false;
          grid.setAttribute('aria-busy', 'false');
        }
      }

      form.addEventListener('submit', event => { event.preventDefault(); offset = 0; loadPage(); });
      // 页头的搜索框是一个真表单（GET /search）。在搜索结果页上它改为原地重查，
      // 于是连续修改关键词不会每次都换一份文档。
      const headerSearchForm = query?.closest('form');
      if (headerSearchForm && pageRoute === '/search') {
        headerSearchForm.addEventListener('submit', event => {
          event.preventDefault();
          offset = 0;
          const params = new URLSearchParams(window.location.search);
          const value = query.value.trim();
          if (value) params.set('q', value); else params.delete('q');
          history.replaceState(null, '', value ? `/search?${params.toString()}` : '/search');
          void loadPage();
        });
      }
      previous.addEventListener('click', () => { offset = Math.max(0, offset - pageSize); loadPage(); document.getElementById('main').focus(); });
      next.addEventListener('click', () => { if (offset + pageSize < total) offset += pageSize; loadPage(); document.getElementById('main').focus(); });

      if (searchLanding && !query.value.trim()) {
        // Prompt, not results.
        grid.replaceChildren();
        grid.setAttribute('aria-busy', 'false');
        status.hidden = true;
        if (pager) pager.hidden = true;
        if (count) count.textContent = '';
        if (emptyState) {
          const titleNode = emptyState.querySelector('.ui-empty-title');
          const bodyNode = emptyState.querySelector('.ui-empty-body');
          if (titleNode) titleNode.textContent = '搜索资料库';
          if (bodyNode) bodyNode.textContent = '输入片名、艺术家或专辑，按回车开始搜索。';
          emptyState.hidden = false;
        }
        query.focus();
      } else {
        void loadPage();
      }
    })();
    """#

    /// Delegates to the shared implementation in `ServerWebHTML`.
    ///
    /// Every page used to carry a private copy of this function — eighteen of
    /// them — which meant eighteen places to audit and eighteen chances for one
    /// to drift.  The local name is kept so the hundreds of call sites in this
    /// file stay readable.
    private static func escape(_ value: String) -> String { ServerWebHTML.escape(value) }
}
