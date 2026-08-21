import CryptoKit
import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 服务端资料库读取边界。它在映射安全 DTO 或文件引用之前同时执行保险库排除、
/// 用户角色与逐资料库授权，路由层永远不会接触未授权的 `MediaItem` 或本地路径。
final class ServerLibraryCatalog {
    private struct CategoryCacheEntry {
        let response: ServerLibraryCategoriesResponse
        let expiresAt: Date
    }

    private let mediaRepository: MediaRepository
    private let mediaDetailRepository: MediaDetailRepository
    private let sourceRepository: SourceRepository
    private let userMediaStateRepository: ServerUserMediaStateRepository
    private let userMediaPreferenceRepository: ServerUserMediaPreferenceRepository
    private let userQueueRepository: ServerUserQueueRepository
    private let smartCollectionRepository: VideoSmartCollectionRepository
    private let smartPlaylistRepository: MusicSmartPlaylistRepository
    private let categoryCacheLock = NSLock()
    private var categoryCache: [String: CategoryCacheEntry] = [:]
    // The authenticated shell asks for these counts on every route render.
    // A short cache causes consecutive sidebar clicks to repeatedly aggregate
    // the whole permitted library, even though an index refresh is naturally
    // much slower than a few seconds. Keep this per-principal cache brief
    // enough for count changes to settle quickly, but long enough to cover a
    // real browsing session.
    private static let categoryCacheLifetime: TimeInterval = 15
    private static let maximumCategoryCacheEntries = 16

    /// - Parameters:
    ///   - vaultUnlockProvider: 保险库是否在这台机器上解锁。默认**锁定**，
    ///     所以任何没有显式接线的调用方都拿不到保险库内容。
    ///   - homeRecommendationProvider: 桌面 App 发布的首页推荐名单（只有条目 ID）。
    ///     默认**没有**，于是没有接线的调用方（测试、纯服务端部署）走服务端自己的推导。
    init(
        database: DatabaseManager,
        vaultUnlockProvider: @escaping () -> Bool = { false },
        homeRecommendationProvider: @escaping () -> HomeRecommendationSnapshot? = { nil },
        trackCatalog: ServerMediaTrackCatalog = ServerMediaTrackCatalog(),
        remoteAssetFetcher: ServerRemoteAssetFetcher = ServerRemoteAssetFetcher()
    ) {
        self.vaultUnlockProvider = vaultUnlockProvider
        self.homeRecommendationProvider = homeRecommendationProvider
        self.trackCatalog = trackCatalog
        self.remoteAssetFetcher = remoteAssetFetcher
        self.mediaRepository = MediaRepository(database: database)
        self.mediaDetailRepository = MediaDetailRepository(database: database)
        self.sourceRepository = SourceRepository(database: database)
        self.userMediaStateRepository = ServerUserMediaStateRepository(database: database)
        self.userMediaPreferenceRepository = ServerUserMediaPreferenceRepository(database: database)
        self.userQueueRepository = ServerUserQueueRepository(database: database)
        self.smartCollectionRepository = VideoSmartCollectionRepository(database: database)
        self.smartPlaylistRepository = MusicSmartPlaylistRepository(database: database)
    }

    /// 保险库当前是否在这台机器上解锁。
    ///
    /// 由 `MediaLibServerEntry` 接到 `VaultUnlockSessionStore` 上；默认**锁定**，
    /// 于是任何没有显式接线的调用方（测试、内嵌路由）都拿不到保险库内容。
    private let vaultUnlockProvider: () -> Bool

    /// 客户端首页发布的推荐名单。每次请求都重新读一次（与保险库解锁状态同样的理由）：
    /// 名单每天会换，缓存它省不下什么，却会让网页比 App 慢一整天。
    private let homeRecommendationProvider: () -> HomeRecommendationSnapshot?

    /// 容器内部的音轨与内嵌字幕轨事实源（ffprobe）。
    private let trackCatalog: ServerMediaTrackCatalog

    /// 远程来源的字幕轨要向 Emby/Jellyfin/Plex 现问，用的是与封面同一组受限上游读取。
    private let remoteAssetFetcher: ServerRemoteAssetFetcher

    /// 首页卡片样本的三个上限。
    ///
    /// 本地那一份保持原来的 60；远程另取一份而不是把两边合到一次查询里，是因为
    /// 两侧的"排除在线来源"判断正好相反。合并后再截断，于是首页拿到的是**跨来源
    /// 按最近更新排的前 96 条**——远程库同步一次就把本地内容整批挤出首页的情况
    /// 不会发生（那会让本地音乐、照片这些栏目凭空消失）。
    static let homeLocalCardLimit = 60
    static let homeRemoteCardLimit = 36
    static let homeMergedCardLimit = 96

    func snapshot(for principal: ServerRequestPrincipal) throws -> ServerLibrarySnapshot {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerLibrarySnapshot(
                summary: ServerLibrarySummary(totalItemCount: 0, countsByType: [:]),
                items: ServerLibraryItemsResponse(totalItemCount: 0, items: [])
            )
        }
        // 首页 = 本地 + 远程，与客户端 `cachedHomeVideoItems` 同一条规则：
        // `cachedTopLevelItems + cachedEmbyTopLevelItems.filter { $0.type != .music }`
        // 按 `updatedAt` 倒序。Emby/Jellyfin/Plex/Mlink 的内容在客户端首页上一直
        // 都在，网页却把它们整批挡在外面——读者接了一台 Emby，首页仍然只有本地。
        //
        // 但这**只**是首页看板。一级分类（侧栏的电影／剧集／动漫及其计数）仍然只
        // 数本地，由 `categories(for:)` 单独出，远程内容在侧栏各自的来源分组里
        // 单列——两者是两件事，混在一起正是上一轮的那个 bug：同一个「电影」，
        // 首页说 812、其它页面说 300，而只存在于远程的类型还会长出一个
        // `/category/<type>` 校验不过的死入口。
        //
        // 两次有界查询而不是一次：本地那次必须继续排除"看着就来自在线服务器"的
        // 条目（`excludesOnlineSourceItems`），远程那次要的正是它们。
        let localHome = try mediaRepository.fetchServerLibraryHome(
            allowedSourcePaths: try localPublicSourcePaths(for: principal, requiring: .viewMedia),
            cardLimit: Self.homeLocalCardLimit,
            excludesOnlineSourceItems: true
        )
        let remotePaths = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
            .filter { RemoteLibraryPathPolicy.isMediaServerSourcePath($0) }
        let remoteHome = remotePaths.isEmpty
            ? nil
            : try mediaRepository.fetchServerLibraryHome(
                allowedSourcePaths: remotePaths,
                cardLimit: Self.homeRemoteCardLimit,
                excludesOnlineSourceItems: false
            )
        // 远程音乐不进首页：客户端的看板同样把它滤掉（音乐栏目讲的是本地曲库），
        // 远程曲目在侧栏各自来源的音乐页里。
        let remoteItems = (remoteHome?.items ?? []).filter { $0.type != .music }
        let homeItems = Array(
            (localHome.items + remoteItems)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.homeMergedCardLimit)
        )
        // 概览格子数的是整个资料库，所以计数也要合。客户端首页的统计同样把远程
        // 条目算进去（见 `recomputeDerivedCollections` 里的 isEmby 分支）。
        //
        // 音乐是唯一的例外，而且必须是例外：`/music/*` 与客户端一样只服务本地
        // 曲库，把远程曲目算进「音乐」那一格，就又回到了"首页的数字点不进去"
        // ——上一轮修掉的正是这种数字与页面各说各话。
        let remoteCountsByType = (remoteHome?.countsByType ?? [:])
            .filter { $0.key != MediaType.music.rawValue }
        let homeCountsByType = localHome.countsByType.merging(remoteCountsByType) { $0 + $1 }
        let homeTotalItemCount = localHome.totalItemCount
            + remoteCountsByType.values.reduce(0, +)
        // 卡片映射（含"痕迹是谁的"这个问题）只有 `libraryItems` 一份实现。
        let cards = try libraryItems(homeItems, for: principal)
        return ServerLibrarySnapshot(
            summary: ServerLibrarySummary(
                totalItemCount: homeTotalItemCount,
                countsByType: homeCountsByType
            ),
            items: ServerLibraryItemsResponse(totalItemCount: cards.count, items: cards)
        )
    }

    func categories(for principal: ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse {
        guard principal.permissions.contains(.viewMedia) else { return ServerLibraryCategoriesResponse(categories: []) }
        let cacheKey = Self.categoryCacheKey(for: principal)
        let now = Date()
        categoryCacheLock.lock()
        if let cached = categoryCache[cacheKey], cached.expiresAt > now {
            categoryCacheLock.unlock()
            return cached.response
        }
        categoryCache.removeValue(forKey: cacheKey)
        categoryCacheLock.unlock()

        // 一级分类的计数只覆盖本地来源；远程内容在各自的来源分组里单列，
        // 与客户端一致。
        let summary = try mediaRepository.fetchServerLibraryHome(
            allowedSourcePaths: try localPublicSourcePaths(for: principal, requiring: .viewMedia),
            cardLimit: 1,
            excludesOnlineSourceItems: true
        )
        let categories = MediaType.allCases.compactMap { type -> ServerLibraryCategory? in
            guard type != .privateCollection,
                  type != .auto,
                  let count = summary.countsByType[type.rawValue],
                  count > 0
            else { return nil }
            return ServerLibraryCategory(id: type.rawValue, title: type.displayName, itemCount: count)
        }
        // 「视频」组的徽标不能是各分类计数之和：那是按类型的全部行数，而
        // `/category/video` 列的是顶层非分集条目。一个有剧集的库里，侧栏写着 3000、
        // 页面显示 120。用与那一页逐字相同的查询算一次，页大小取 1 只要总数。
        let videoGroupTotal = try mediaRepository.fetchServerLibraryPage(
            allowedSourcePaths: try localPublicSourcePaths(for: principal, requiring: .viewMedia),
            type: nil,
            topLevelOnly: true,
            searchText: nil,
            offset: 0,
            limit: 1,
            sort: databaseSort(.recentlyUpdated),
            userID: principal.userID,
            playbackFilter: nil,
            excludedTypes: [.music, .photo, .episode, .homeVideo],
            excludesOnlineSourceItems: true
        ).totalItemCount
        let response = ServerLibraryCategoriesResponse(
            categories: categories, videoGroupItemCount: videoGroupTotal
        )
        categoryCacheLock.lock()
        categoryCache = categoryCache.filter { $0.value.expiresAt > now }
        if categoryCache.count >= Self.maximumCategoryCacheEntries,
           let oldestKey = categoryCache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            categoryCache.removeValue(forKey: oldestKey)
        }
        categoryCache[cacheKey] = CategoryCacheEntry(
            response: response,
            expiresAt: now.addingTimeInterval(Self.categoryCacheLifetime)
        )
        categoryCacheLock.unlock()
        return response
    }

    func browse(_ query: ServerLibraryQuery, for principal: ServerRequestPrincipal) throws -> ServerLibraryItemsPage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerLibraryItemsPage(totalItemCount: 0, offset: query.offset, limit: query.limit, items: [])
        }
        let type = query.type.flatMap(MediaType.init(rawValue:))
        // "视频" 是一个固定服务端集合：保留可直接在资料库中浏览的顶层影视，
        // 不让单曲、相册或剧集明细混入。剧集仍从系列详情页进入。
        let excludedTypes: Set<MediaType> = switch query.mediaGroup {
        // 录像归「相册」，与侧栏一致：它在客户端属于相册来源，网页侧栏里也只挂在
        // 相册下面。留在这里会让「视频」的徽标比它自己列出的分类之和还大一截。
        case .video: [.music, .photo, .episode, .homeVideo]
        // 相册只收照片与录像，其余全部排除——它是一个"什么进得来"的白名单，
        // 用排除表达时必须把新出现的类型也挡住，所以这里逐项列出补集。
        case .album: [.music, .episode, .movie, .tvShow, .anime, .documentary, .variety, .other, .privateCollection]
        case nil: []
        }
        let playbackFilter: ServerLibraryUserStateFilter? = switch query.playbackFilter {
        case .inProgress: .inProgress
        case .watched: .watched
        case .unwatched: .unwatched
        case .history: .history
        case nil: nil
        }
        let preferenceFilter: ServerLibraryUserPreferenceFilter? = switch query.preferenceFilter {
        case .favorite: .favorite
        case .watchlist: .watchlist
        case .rated: .rated
        case nil: nil
        }
        // 仓储层现在按排序键自己决定是否连接按用户分表的状态/偏好表，所以这里不再
        // 需要"只有 history 才允许按最近播放排序"那条降级——它当初存在只是因为
        // 连接是有条件的，按最近播放排序会引用一个不存在的 SQL 别名。
        let databasePage = try mediaRepository.fetchServerLibraryPage(
            // 无远程作用域时只浏览本地来源；带作用域时收窄到该远程来源／资料库；
            // 首页看板那两栏跨全部来源；保险库作用域只给保险库来源。
            allowedSourcePaths: try browseSourcePaths(
                remoteScopeID: query.remoteScopeID,
                includesRemoteSources: query.includesRemoteSources,
                vaultScope: query.vaultScope,
                for: principal, requiring: .viewMedia
            ),
            type: type,
            topLevelOnly: type == nil && playbackFilter == nil && preferenceFilter == nil,
            searchText: query.searchText,
            offset: query.offset,
            limit: query.limit,
            sort: databaseSort(query.sort),
            sortOrder: databaseSortOrder(query.sortOrder),
            genre: Self.boundedText(query.genre, maximumLength: 64),
            userID: principal.userID,
            playbackFilter: playbackFilter,
            preferenceFilter: preferenceFilter,
            excludedTypes: excludedTypes,
            // 只有本地浏览才排除"明显来自在线服务器"的条目；带远程作用域时
            // 浏览的正是那些条目，排除掉会让远程分组变成空页，首页看板同理。
            excludesOnlineSourceItems: query.remoteScopeID == nil
                && !query.includesRemoteSources && !query.vaultScope,
            // 保险库的顶层条目本身就是 `privateCollection` 类型的容器（客户端的
            // `privateTopLevelItems` 就是它们）。默认那条 `type != privateCollection`
            // 是保险库对其它所有页面的兜底屏障，唯独保险库自己这一页要看见它们。
            includesPrivateCollectionType: query.vaultScope
        )
        let cards = try libraryItems(databasePage.items, for: principal)
        return ServerLibraryItemsPage(
            totalItemCount: databasePage.totalItemCount,
            offset: query.offset,
            limit: query.limit,
            items: cards
        )
    }

    /// 网页首页几条推荐栏目的内容：**顺序来自客户端，可见性与痕迹来自这个账号自己**。
    ///
    /// 客户端首页已经把「剧集推荐」「音乐推荐」「最近添加剧集」「高分精选」和 banner
    /// 轮播算过一遍（题材相似度、每日稳定随机值、横版剧照可用性……），并把结果作为
    /// 一串条目 ID 发布到应用支持目录。服务端这里做的事只有三件：
    ///
    /// 1. 把名单里的 ID 交给**与其它每一页相同**的授权查询。名单不是可见性凭证：
    ///    机主看得到的东西，只有在这个账号也被授权了那个资料库时才会查得出来，
    ///    保险库与 `privateCollection` 类型两道排除照旧。
    /// 2. 保住客户端给的顺序（数据库返回的顺序无意义）。
    /// 3. 挂上**请求者自己**的播放痕迹与偏好，而不是机主的——痕迹永远来自
    ///    `server_user_media_state` / `server_user_media_preferences`。
    ///
    /// 名单读不到（App 没运行、过期、纯服务端部署）就返回空，首页据此回落到服务端
    /// 自己的推导；这条回落路径不能删，Docker 部署里根本没有客户端。
    func homeRecommendations(for principal: ServerRequestPrincipal) throws -> ServerHomeRecommendations {
        guard principal.permissions.contains(.viewMedia),
              let snapshot = homeRecommendationProvider()
        else { return .empty }

        // 每一栏取到网页上真正会显示的条数为止。六栏加起来的上界（71）刻意留在
        // 逐条目查询的 100 项上界之内：一次查询查完，不必分批。
        let sectionLimits: [(HomeRecommendationSection, Int)] = [
            (.banner, Self.homeRecommendationBannerLimit),
            (.seriesRecommendation, Self.homeRecommendationShelfLimit),
            (.recentSeries, Self.homeRecommendationShelfLimit),
            (.highRated, Self.homeRecommendationShelfLimit),
            (.musicRecommendation, Self.homeRecommendationMusicLimit),
            (.photoWall, Self.homeRecommendationShelfLimit)
        ]
        var idsBySection: [HomeRecommendationSection: [String]] = [:]
        var requestedIDs: [String] = []
        var seen = Set<String>()
        for (section, limit) in sectionLimits {
            let ids = Array(snapshot.itemIDs(for: section).prefix(limit))
            guard !ids.isEmpty else { continue }
            idsBySection[section] = ids
            for id in ids where seen.insert(id).inserted { requestedIDs.append(id) }
        }
        guard !requestedIDs.isEmpty else { return .empty }

        let items = try mediaRepository.fetchServerMediaItems(
            ids: Array(requestedIDs.prefix(100)),
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        )
        guard !items.isEmpty else { return .empty }
        let cards = try libraryItems(items, for: principal)
        let cardsByID = Dictionary(cards.map { ($0.id, $0) }) { first, _ in first }
        func section(_ section: HomeRecommendationSection) -> [ServerLibraryItem] {
            (idsBySection[section] ?? []).compactMap { cardsByID[$0] }
        }
        return ServerHomeRecommendations(
            generatedAt: snapshot.generatedAt,
            banner: section(.banner),
            series: section(.seriesRecommendation),
            recentSeries: section(.recentSeries),
            highRated: section(.highRated),
            music: section(.musicRecommendation),
            photos: section(.photoWall)
        )
    }

    /// 首页 banner 轮播最多七张，与客户端 `overviewFeaturedItems` 的上限一致。
    static let homeRecommendationBannerLimit = 7
    /// 一条货架 12 张卡片，与首页其它每一栏相同。
    static let homeRecommendationShelfLimit = 12
    /// 音乐榜单 16 首。
    static let homeRecommendationMusicLimit = 16

    /// 音乐专题页只接收当前账号可查看的歌曲 DTO。聚合发生在本层，因而不会让
    /// 未授权来源的艺术家、专辑名或封面进入网页，即使它们与公开歌曲同名。
    func musicItems(for principal: ServerRequestPrincipal) throws -> [ServerLibraryItem] {
        guard principal.permissions.contains(.viewMedia) else { return [] }
        // 音乐页与客户端一致：只服务本地音乐。远程音乐属于各自的来源分组，
        // 混进来会让同一批曲目在侧栏出现两次。
        let tracks = try mediaRepository.fetchServerMusicItems(
            allowedSourcePaths: try localPublicSourcePaths(for: principal, requiring: .viewMedia),
            excludesOnlineSourceItems: true
        )
        // 音乐页的痕迹同样是**这个账号自己的**。
        //
        // 这里从前一律给 `nil` / `.empty`，理由是"批量读取一次最多 100 项，而音乐库
        // 可能几千首"。代价是页面上那两件真实存在的功能一直是坏的：「收藏」筛选对
        // 每个人都筛出空，「播放次数」排序对每个人都是全 0——不是隔离，是没有数据。
        //
        // 正确的界限不在"多少张卡片"，而在"这个人标过多少东西"：后者随他自己的操作
        // 增长，不随资料库增长，所以整份读回来一次即可（`fetchAll` 自带上限）。
        let states = try userMediaStateRepository.fetchAll(userID: principal.userID)
        let preferences = try userMediaPreferenceRepository.fetchAll(userID: principal.userID)
        return tracks.map { item in
            ServerLibraryItem(
                id: item.id,
                type: item.type.rawValue,
                title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名音乐",
                year: item.year,
                artist: Self.boundedText(item.artist, maximumLength: 256),
                album: Self.boundedText(item.album, maximumLength: 256),
                durationSeconds: item.duration,
                hasLyrics: item.hasLyrics,
                artworkAvailable: item.posterPath?.isEmpty == false,
                backdropAvailable: item.backdropPath?.isEmpty == false,
                isSeries: false,
                isRemoteSource: Self.approvedRemoteAssetURL(for: item) != nil,
                remoteSourceKind: ServerRemoteSourceKind(sourcePath: item.sourcePath),
                userState: states[item.id].map(Self.protocolState),
                userPreference: preferences[item.id].map(Self.protocolPreference) ?? .empty
            )
        }
    }

    func publicDetail(id: String, for principal: ServerRequestPrincipal) throws -> ServerMediaItemDetail? {
        guard let item = try publicItem(id: id, for: principal, requiring: .viewMedia) else {
            return nil
        }
        let readableAssetURL = item.filePath.flatMap(Self.localReadableFileURL(from:))
        let remoteAssetURL = Self.approvedRemoteAssetURL(for: item)
        let playableAssetURL = readableAssetURL ?? remoteAssetURL
        let hasReadableAsset = playableAssetURL != nil
        let isPlayable: Bool
        let canDownload: Bool
        if hasReadableAsset {
            isPlayable = try publicItem(id: id, for: principal, requiring: .playMedia) != nil
            canDownload = try publicItem(id: id, for: principal, requiring: .downloadMedia) != nil
        } else {
            isPlayable = false
            canDownload = false
        }
        let canDirectPlay = hasReadableAsset && isPlayable
        // 网页端只拿到经过权限检查的同源字节流，并由浏览器完成解码。
        // 不允许客户端进程或 HTTP 服务端替网页执行 ffmpeg 转码；不兼容的
        // 容器/编码由浏览器明确反馈，避免播放链路悄然回退为服务端解码。
        let canTranscode = false
        let episodeNavigation = try authorizedEpisodeNavigation(for: item, principal: principal)
        let detailExtras = try authorizedDetailExtras(for: item, principal: principal)
        let userState = try userMediaStateRepository.fetch(userID: principal.userID, mediaID: item.id)
        let userPreference = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaID: item.id)
        // 单集自己通常只有编号和文件信息：简介、题材、评分、海报都挂在系列上。
        // 不回退的话，每一集的详情都会显示「片长未知 · 暂无评分 · 暂无简介」，
        // 而那些资料明明就在它的父级里。
        let parent: MediaItem? = {
            guard item.type == .episode, let parentID = item.parentID else { return nil }
            return try? publicItem(id: parentID, for: principal, requiring: .viewMedia)
        }()
        let runtimeSeconds: Double? = {
            if let duration = item.duration, duration.isFinite, duration >= 0 { return duration }
            if let runtime = item.runtime, runtime >= 0 { return Double(runtime) * 60 }
            // 回退到系列声明的单集时长。
            if let parentRuntime = parent?.runtime, parentRuntime >= 0 { return Double(parentRuntime) * 60 }
            return nil
        }()
        // 某些上游（特别是 Plex 的部分 stream 路由）没有扩展名。此时让浏览器
        // 尝试嗅探比将它误标成 application/octet-stream 并禁用播放更可靠。
        let browserContentType: String? = playableAssetURL.flatMap { assetURL in
            let contentType = ServerMediaAsset(id: item.id, fileURL: assetURL, byteLength: 0).contentType
            return contentType == "application/octet-stream" ? nil : contentType
        }
        // 剧集页需要完整的、已授权的系列导航，而不是从 DOM 或路径推断父级。
        // 若系列摘要暂时不可用，单集仍可安全播放，只是退化为普通媒体详情。
        let episodeContext: ServerEpisodePlaybackContext?
        if item.type == .episode,
           let parentID = item.parentID,
           let series = try? seriesDetail(id: parentID, for: principal)
        {
            episodeContext = ServerEpisodePlaybackContext(
                seriesID: series.id,
                seriesTitle: series.title,
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber,
                seasons: series.seasons
            )
        } else {
            episodeContext = nil
        }
        return ServerMediaItemDetail(
            id: item.id,
            type: item.type.rawValue,
            title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名媒体",
            originalTitle: Self.boundedText(item.originalTitle, maximumLength: 512),
            year: item.year,
            overview: Self.boundedText(item.overview, maximumLength: 8_000)
                ?? Self.boundedText(parent?.overview, maximumLength: 8_000),
            genres: Self.genres(item.genre).isEmpty ? Self.genres(parent?.genre) : Self.genres(item.genre),
            communityRating: item.rating ?? parent?.rating,
            runtimeSeconds: runtimeSeconds,
            videoCodec: Self.boundedText(item.videoCodec, maximumLength: 64),
            audioCodec: Self.boundedText(item.audioCodec, maximumLength: 64),
            resolution: Self.boundedText(item.resolution, maximumLength: 64),
            artworkAvailable: item.posterPath?.isEmpty == false || parent?.posterPath?.isEmpty == false,
            backdropAvailable: item.backdropPath?.isEmpty == false || parent?.backdropPath?.isEmpty == false,
            browserContentType: browserContentType,
            canDirectPlay: canDirectPlay,
            canTranscode: canTranscode,
            // 当前发布版本只配置授权 Range Direct Play。以显式层级发布该
            // 事实，后续 Remux/音频转码/全转码只有在对应端点、资源限制与缓存
            // 策略完整落地后才会进入此列表，绝不因探测到 ffmpeg 而误承诺。
            playbackModes: canDirectPlay ? [.directPlay] : [],
            canDownload: canDownload,
            previousEpisode: episodeNavigation.previous,
            nextEpisode: episodeNavigation.next,
            episodeContext: episodeContext,
            detailExtras: detailExtras,
            userState: userState.map(Self.protocolState),
            userPreference: userPreference.map(Self.protocolPreference) ?? .empty
        )
    }

    /// 将桌面端已经缓存的详情映射成最小网页视图；关联条目必须再次经过当前
    /// principal 的资料库过滤，外部海报/人物 URL 永远不会越过服务端边界。
    private func authorizedDetailExtras(
        for item: MediaItem,
        principal: ServerRequestPrincipal
    ) throws -> ServerMediaDetailExtras? {
        let lookupID = item.parentID ?? item.id
        guard let snapshot = try mediaDetailRepository.fetch(mediaID: lookupID) else { return nil }
        let allowedSourcePaths = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        // A person can legitimately have several cached credits.  Keep the
        // last sanitized record instead of using Dictionary's trap-on-duplicate
        // initializer on data imported from external metadata.
        var creditsByPerson: [String: MediaPerson] = [:]
        for person in snapshot.people {
            creditsByPerson[person.id] = person
        }
        // 头像序号必须与 `detailImageAsset(.portrait,)` 读的是同一个序列，
        // 否则第 3 个人会顶着第 7 个人的脸。两处都按 credit.order 排序。
        let orderedCredits = snapshot.credits.sorted { $0.order < $1.order }
        let mappedCredits = orderedCredits.enumerated().compactMap { index, credit -> ServerMediaDetailCredit? in
            guard let person = creditsByPerson[credit.personID] else { return nil }
            let personID = Self.boundedText(person.id, maximumLength: 512)
            let name = Self.boundedText(person.name, maximumLength: 512)
            guard let personID, let name else { return nil }
            return ServerMediaDetailCredit(
                id: personID,
                name: name,
                role: Self.boundedText(credit.role, maximumLength: 256) ?? "",
                category: Self.boundedText(credit.category, maximumLength: 64) ?? "cast",
                portraitIndex: Self.approvedDetailImageURL(person.profileURL, for: item) != nil ? index : nil
            )
        }
        // 推荐分成两半，和客户端一样：能在本库打开的进「库中相似作品」，
        // 打不开的进「更多推荐」。此前只保留了前者，后者被整条丢弃。
        let orderedRelated = snapshot.relatedTitles.sorted { $0.order < $1.order }.prefix(24)
        var related: [ServerMediaDetailRelated] = []
        var discovery: [ServerMediaDetailDiscovery] = []
        for (index, value) in orderedRelated.enumerated() {
            if let localID = value.localMediaID,
               let relatedItem = try mediaRepository.fetchServerMediaItem(
                id: localID,
                allowedSourcePaths: allowedSourcePaths
               ) {
                related.append(ServerMediaDetailRelated(
                    id: relatedItem.id,
                    type: relatedItem.type.rawValue,
                    title: Self.boundedText(relatedItem.cardTitle, maximumLength: 512) ?? "未命名媒体",
                    year: relatedItem.year,
                    artworkAvailable: relatedItem.posterPath?.isEmpty == false,
                    isSeries: Self.isSeriesContainer(relatedItem)
                ))
                continue
            }
            guard let title = Self.boundedText(value.title, maximumLength: 512) else { continue }
            discovery.append(ServerMediaDetailDiscovery(
                id: "\(lookupID)-discovery-\(index)",
                index: index,
                title: title,
                year: value.year,
                // 海报只走同源代理，序号是网页拿到的全部信息。
                artworkAvailable: Self.approvedDetailImageURL(value.posterURL, for: item) != nil
            ))
        }
        let artwork = snapshot.artwork
            .sorted { $0.order < $1.order }
            .prefix(24)
            .enumerated()
            .compactMap { index, value -> ServerMediaDetailArtwork? in
                guard Self.approvedDetailImageURL(value.thumbURL, for: item) != nil
                        || Self.localReadableFileURL(from: value.localPath ?? "") != nil
                else { return nil }
                return ServerMediaDetailArtwork(
                    id: "\(lookupID)-still-\(index)",
                    index: index,
                    kind: Self.boundedText(value.kind, maximumLength: 32) ?? "backdrop",
                    aspectRatio: value.aspectRatio
                )
            }
        let links = Self.detailLinks(title: item.cardTitle, externalIDs: snapshot.externalIDs)
        let metadata = snapshot.metadata
        let crew = mappedCredits.filter { $0.category.lowercased() != "cast" }.prefix(12)
        let cast = mappedCredits.filter { $0.category.lowercased() == "cast" }.prefix(16)
        return ServerMediaDetailExtras(
            status: Self.boundedText(metadata.status, maximumLength: 128),
            contentRating: Self.boundedText(metadata.contentRating, maximumLength: 64),
            originalLanguage: Self.boundedText(metadata.originalLanguage, maximumLength: 64),
            countries: metadata.countries.compactMap { Self.boundedText($0, maximumLength: 128) }.prefix(8).map { $0 },
            productionCompanies: metadata.productionCompanies.compactMap { Self.boundedText($0, maximumLength: 256) }.prefix(8).map { $0 },
            networks: metadata.networks.compactMap { Self.boundedText($0, maximumLength: 256) }.prefix(8).map { $0 },
            crew: Array(crew), cast: Array(cast), related: related,
            discovery: Array(discovery.prefix(12)), artwork: Array(artwork), links: links
        )
    }

    /// 详情页底部的外部链接。
    ///
    /// URL 全部由服务端构造：要么是一条搜索查询，要么来自已经缓存的外部 ID。
    /// 上游响应从不回显，浏览器也不会在页面加载时向这些站点发出任何请求——
    /// 它们只有在读者主动点击时才被打开。
    static func detailLinks(title: String, externalIDs: [MediaExternalID]) -> [ServerMediaDetailLink] {
        var values: [ServerMediaDetailLink] = []
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if !query.isEmpty {
            values.append(ServerMediaDetailLink(
                id: "douban", title: "豆瓣",
                url: "https://search.douban.com/movie/subject_search?search_text=\(query)"
            ))
        }
        for value in externalIDs {
            let identifier = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
            // 外部 ID 直接进 URL 路径，所以它必须先被限制成一个真正的标识符，
            // 而不是任何可以带出路径段的文本。
            switch value.provider.lowercased() {
            case "imdb":
                guard identifier.count <= 32,
                      identifier.allSatisfy({ $0.isLetter || $0.isNumber })
                else { continue }
                values.append(ServerMediaDetailLink(
                    id: "imdb", title: "IMDb", url: "https://www.imdb.com/title/\(identifier)/"
                ))
            case "tmdb":
                let parts = identifier.split(separator: ":")
                guard parts.count == 2,
                      ["movie", "tv", "person"].contains(String(parts[0])),
                      parts[1].count <= 16,
                      parts[1].allSatisfy(\.isNumber)
                else { continue }
                values.append(ServerMediaDetailLink(
                    id: "tmdb", title: "TMDB",
                    url: "https://www.themoviedb.org/\(parts[0])/\(parts[1])"
                ))
            default:
                continue
            }
        }
        if !query.isEmpty {
            values.append(ServerMediaDetailLink(
                id: "wikipedia", title: "维基百科",
                url: "https://zh.wikipedia.org/w/index.php?search=\(query)"
            ))
        }
        return values
    }

    func seriesDetail(id: String, for principal: ServerRequestPrincipal) throws -> ServerSeriesDetail? {
        guard principal.permissions.contains(.viewMedia),
              let overview = try mediaRepository.fetchServerSeriesOverview(
                allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
                seriesID: id,
                userID: principal.userID
              )
        else { return nil }
        let item = overview.series
        let preference = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaID: item.id)
        let seasons = overview.seasons.map { season in
            let title: String
            let seasonID: String
            if let number = season.seasonNumber {
                title = number == 0 ? "特别篇" : "第 \(number) 季"
                seasonID = "season-\(number)"
            } else {
                title = "未分季"
                seasonID = "unspecified"
            }
            return ServerSeriesSeason(
                id: seasonID,
                seasonNumber: season.seasonNumber,
                title: title,
                episodeCount: season.episodeCount,
                watchedCount: season.watchedCount,
                inProgressCount: season.inProgressCount
            )
        }
        return ServerSeriesDetail(
            id: item.id,
            type: item.type.rawValue,
            title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名系列",
            originalTitle: Self.boundedText(item.originalTitle, maximumLength: 512),
            year: item.year,
            overview: Self.boundedText(item.overview, maximumLength: 8_000),
            genres: Self.genres(item.genre),
            communityRating: item.rating,
            artworkAvailable: item.posterPath?.isEmpty == false,
            backdropAvailable: item.backdropPath?.isEmpty == false,
            totalEpisodeCount: overview.totalEpisodeCount,
            seasons: seasons,
            userPreference: preference.map(Self.protocolPreference) ?? .empty
        )
    }

    func seriesEpisodes(
        id: String,
        season: ServerSeriesSeasonSelector,
        offset: Int,
        limit: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerSeriesEpisodesPage? {
        guard principal.permissions.contains(.viewMedia) else { return nil }
        let allowedSourcePaths = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        guard
              try mediaRepository.fetchServerSeriesOverview(
                allowedSourcePaths: allowedSourcePaths,
                seriesID: id,
                userID: principal.userID
              ) != nil
        else { return nil }
        let page = try mediaRepository.fetchServerSeriesEpisodePage(
            allowedSourcePaths: allowedSourcePaths,
            seriesID: id,
            season: season,
            offset: offset,
            limit: limit
        )
        let states = try userMediaStateRepository.fetch(userID: principal.userID, mediaIDs: page.items.map(\.id))
        let items = page.items.map { item in
            let runtimeSeconds: Double? = {
                if let duration = item.duration, duration.isFinite, duration >= 0 { return duration }
                if let runtime = item.runtime, runtime >= 0 { return Double(runtime) * 60 }
                return nil
            }()
            return ServerSeriesEpisode(
                id: item.id,
                title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名剧集",
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber,
                runtimeSeconds: runtimeSeconds,
                artworkAvailable: item.posterPath?.isEmpty == false,
                isRemoteSource: Self.approvedRemoteAssetURL(for: item) != nil,
                userState: states[item.id].map(Self.protocolState)
            )
        }
        return ServerSeriesEpisodesPage(
            totalItemCount: page.totalItemCount,
            offset: offset,
            limit: min(max(limit, 1), 100),
            items: items
        )
    }

    func people(searchText: String?, offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerPeoplePage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerPeoplePage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        }
        let page = try mediaRepository.fetchServerPeoplePage(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            searchText: searchText,
            offset: offset,
            limit: limit
        )
        return ServerPeoplePage(
            totalItemCount: page.totalItemCount,
            offset: offset,
            limit: min(max(limit, 1), 100),
            items: page.items.map {
                ServerPersonCard(
                    id: $0.id,
                    name: Self.boundedText($0.name, maximumLength: 512) ?? "未命名人物",
                    department: Self.boundedText($0.department, maximumLength: 128),
                    mediaCount: $0.mediaCount
                )
            }
        )
    }

    func personDetail(id: String, offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerPersonDetail? {
        guard principal.permissions.contains(.viewMedia) else { return nil }
        let allowedSourcePaths = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        guard let profile = try mediaRepository.fetchServerPersonProfile(
            allowedSourcePaths: allowedSourcePaths,
            personID: id
        ) else { return nil }
        let credits = try mediaRepository.fetchServerPersonCreditsPage(
            allowedSourcePaths: allowedSourcePaths,
            personID: id,
            offset: offset,
            limit: limit
        )
        return ServerPersonDetail(
            id: profile.id,
            name: Self.boundedText(profile.name, maximumLength: 512) ?? "未命名人物",
            biography: Self.boundedText(profile.biography, maximumLength: 8_000),
            birthday: Self.boundedText(profile.birthday, maximumLength: 64),
            deathday: Self.boundedText(profile.deathday, maximumLength: 64),
            placeOfBirth: Self.boundedText(profile.placeOfBirth, maximumLength: 256),
            department: Self.boundedText(profile.department, maximumLength: 128),
            credits: ServerPeopleCreditsPage(
                totalItemCount: credits.totalItemCount,
                offset: offset,
                limit: min(max(limit, 1), 100),
                items: credits.items.map { credit in
                    ServerPersonCredit(
                        id: credit.media.id,
                        type: credit.media.type.rawValue,
                        title: Self.boundedText(credit.media.cardTitle, maximumLength: 512) ?? "未命名媒体",
                        year: credit.media.year,
                        artworkAvailable: credit.media.posterPath?.isEmpty == false,
                        isSeries: Self.isSeriesContainer(credit.media),
                        isRemoteSource: Self.approvedRemoteAssetURL(for: credit.media) != nil,
                        remoteSourceKind: ServerRemoteSourceKind(sourcePath: credit.media.sourcePath),
                        category: Self.boundedText(credit.category, maximumLength: 64) ?? "cast",
                        role: Self.boundedText(credit.role, maximumLength: 256)
                    )
                }
            )
        )
    }

    func collections(offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerCollectionsPage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        }
        let page = try mediaRepository.fetchServerManualCollectionsPage(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            offset: offset, limit: limit
        )
        return ServerCollectionsPage(
            totalItemCount: page.totalItemCount, offset: offset, limit: min(max(limit, 1), 100),
            items: page.items.map {
                ServerCollectionCard(id: $0.id, name: Self.boundedText($0.name, maximumLength: 512) ?? "未命名合集", mediaCount: $0.mediaCount)
            }
        )
    }

    func collectionDetail(id: String, offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerCollectionDetail? {
        guard principal.permissions.contains(.viewMedia),
              let detail = try mediaRepository.fetchServerManualCollectionDetail(
                allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
                collectionID: id, offset: offset, limit: limit
              ) else { return nil }
        return ServerCollectionDetail(
            id: detail.id, name: Self.boundedText(detail.name, maximumLength: 512) ?? "未命名合集",
            items: ServerCollectionItemsPage(
                totalItemCount: detail.totalItemCount, offset: offset, limit: min(max(limit, 1), 100),
                items: detail.items.map {
                    ServerCollectionMedia(
                        id: $0.id, type: $0.type.rawValue,
                        title: Self.boundedText($0.cardTitle, maximumLength: 512) ?? "未命名媒体",
                        year: $0.year, artworkAvailable: $0.posterPath?.isEmpty == false,
                        isSeries: Self.isSeriesContainer($0),
                        isRemoteSource: Self.approvedRemoteAssetURL(for: $0) != nil,
                        remoteSourceKind: ServerRemoteSourceKind(sourcePath: $0.sourcePath)
                    )
                }
            )
        )
    }

    // MARK: - 智能集合与歌单

    /// 智能集合列表。名字与数量，不含规则。
    ///
    /// 数量按**请求者**的可见集合与**请求者**的观看状态算：规则里有"已看/未看"
    /// 这类条件，拿桌面机主的状态求值会让每个用户看到机主的观看历史被折算成的数
    /// 字。求值本身用客户端那份 `VideoSmartCollection.matches`，两端同一套规则。
    func smartCollections(offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerSmartCollectionsPage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerSmartCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        }
        let collections = try smartCollectionRepository.fetchAll()
        guard !collections.isEmpty else {
            return ServerSmartCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        }
        let candidates = try authorizedSmartCollectionCandidates(for: principal)
        let cards = collections.compactMap { collection -> ServerSmartCollectionCard? in
            let count = candidates.lazy.filter { collection.matches($0, watchedThreshold: Self.watchedThreshold) }.count
            // 一条都匹配不到的集合不出现——空集合比没有更让人困惑，而且它的存在
            // 本身也是一条关于"机主建了什么集合"的信息。
            guard count > 0 else { return nil }
            return ServerSmartCollectionCard(
                id: collection.id,
                name: Self.boundedText(collection.name, maximumLength: 512) ?? "未命名集合",
                mediaCount: count
            )
        }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return ServerSmartCollectionsPage(
            totalItemCount: cards.count,
            offset: safeOffset,
            limit: safeLimit,
            items: Array(cards.dropFirst(safeOffset).prefix(safeLimit))
        )
    }

    func smartCollectionDetail(
        id: String,
        offset: Int,
        limit: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerSmartCollectionDetail? {
        guard principal.permissions.contains(.viewMedia),
              let collection = try smartCollectionRepository.fetchAll().first(where: { $0.id == id })
        else { return nil }
        let candidates = try authorizedSmartCollectionCandidates(for: principal)
        let matched = candidates.filter { collection.matches($0, watchedThreshold: Self.watchedThreshold) }
        guard !matched.isEmpty else { return nil }
        return ServerSmartCollectionDetail(
            id: collection.id,
            name: Self.boundedText(collection.name, maximumLength: 512) ?? "未命名集合",
            items: try page(of: matched, offset: offset, limit: limit, for: principal)
        )
    }

    /// 手动歌单与智能歌单合成一份列表，与客户端「歌单」页一致。
    func musicPlaylists(offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerMusicPlaylistsPage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerMusicPlaylistsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        }
        let allowed = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        let manual = try mediaRepository.fetchServerMusicPlaylistsPage(
            allowedSourcePaths: allowed, offset: 0, limit: 100
        ).items.map {
            ServerMusicPlaylistCard(
                id: $0.id,
                name: Self.boundedText($0.name, maximumLength: 512) ?? "未命名歌单",
                trackCount: $0.trackCount,
                isSmart: false
            )
        }
        let tracks = try authorizedMusicCandidates(for: principal)
        let smart = try smartPlaylistRepository.fetchAll().compactMap { playlist -> ServerMusicPlaylistCard? in
            let count = MusicSmartPlaylistPolicy.tracks(in: playlist, from: tracks).count
            guard count > 0 else { return nil }
            return ServerMusicPlaylistCard(
                id: playlist.id,
                name: Self.boundedText(playlist.name, maximumLength: 512) ?? "智能歌单",
                trackCount: count,
                isSmart: true,
                ruleSummary: Self.boundedText(playlist.ruleSummary, maximumLength: 256)
            )
        }
        let combined = smart + manual
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return ServerMusicPlaylistsPage(
            totalItemCount: combined.count,
            offset: safeOffset,
            limit: safeLimit,
            items: Array(combined.dropFirst(safeOffset).prefix(safeLimit))
        )
    }

    func musicPlaylistDetail(
        id: String,
        offset: Int,
        limit: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMusicPlaylistDetail? {
        guard principal.permissions.contains(.viewMedia) else { return nil }
        if let smart = try smartPlaylistRepository.fetchAll().first(where: { $0.id == id }) {
            let matched = MusicSmartPlaylistPolicy.tracks(
                in: smart, from: try authorizedMusicCandidates(for: principal)
            )
            guard !matched.isEmpty else { return nil }
            return ServerMusicPlaylistDetail(
                id: smart.id,
                name: Self.boundedText(smart.name, maximumLength: 512) ?? "智能歌单",
                isSmart: true,
                items: try page(of: matched, offset: offset, limit: limit, for: principal)
            )
        }
        guard let detail = try mediaRepository.fetchServerMusicPlaylistDetail(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            playlistID: id, offset: offset, limit: limit
        ) else { return nil }
        return ServerMusicPlaylistDetail(
            id: detail.id,
            name: Self.boundedText(detail.name, maximumLength: 512) ?? "未命名歌单",
            isSmart: false,
            items: try cards(for: detail.items, totalItemCount: detail.totalItemCount, offset: offset, limit: limit, principal: principal)
        )
    }

    /// 客户端把 90% 当作"看完"的门槛，规则求值必须用同一个数，否则同一个
    /// "已看完"集合在两端会给出不同的成员。
    private static let watchedThreshold: Double = 0.9

    /// 智能集合的候选集：请求者有权看到的影视条目，且已叠加请求者自己的观看状态。
    private func authorizedSmartCollectionCandidates(for principal: ServerRequestPrincipal) throws -> [MediaItem] {
        let items = try mediaRepository.fetchServerAuthorizedCandidates(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            type: nil
        )
        return try overlayingPrincipalState(items, for: principal)
    }

    private func authorizedMusicCandidates(for principal: ServerRequestPrincipal) throws -> [MediaItem] {
        let items = try mediaRepository.fetchServerAuthorizedCandidates(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            type: .music
        )
        return try overlayingPrincipalState(items, for: principal)
    }

    /// 把请求者自己的播放状态与偏好盖到条目上，再交给规则求值。
    ///
    /// `media_items` 上的 `watched` / `favorite` / `play_count` 是桌面机主的痕迹。
    /// 智能集合的规则会读这些字段，所以不换成请求者的，"我收藏的"这类歌单会直接
    /// 把机主收藏了什么摆给每一个登录用户看。
    private func overlayingPrincipalState(
        _ items: [MediaItem],
        for principal: ServerRequestPrincipal
    ) throws -> [MediaItem] {
        guard !items.isEmpty else { return [] }
        let ids = items.map(\.id)
        let states = try userMediaStateRepository.fetch(userID: principal.userID, mediaIDs: ids)
        let preferences = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaIDs: ids)
        return items.map { item in
            var copy = item
            let state = states[item.id]
            copy.watched = state?.isWatched ?? false
            copy.playCount = state?.playCount ?? 0
            copy.playProgress = state?.playProgress ?? 0
            copy.playPosition = state?.playPosition ?? 0
            copy.lastPlayedAt = state?.lastPlayedAt
            let preference = preferences[item.id]
            copy.favorite = preference?.isFavorite ?? false
            copy.watchlist = preference?.isWatchlist ?? false
            copy.userRating = preference?.userRating
            return copy
        }
    }

    /// 已经在内存里筛好的一组条目 → 一页 DTO。
    private func page(
        of items: [MediaItem],
        offset: Int,
        limit: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerLibraryItemsPage {
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        let slice = Array(items.dropFirst(safeOffset).prefix(safeLimit))
        return try cards(for: slice, totalItemCount: items.count, offset: safeOffset, limit: safeLimit, principal: principal)
    }

    private func cards(
        for items: [MediaItem],
        totalItemCount: Int,
        offset: Int,
        limit: Int,
        principal: ServerRequestPrincipal
    ) throws -> ServerLibraryItemsPage {
        ServerLibraryItemsPage(
            totalItemCount: totalItemCount,
            offset: offset,
            limit: limit,
            items: try libraryItems(items, for: principal)
        )
    }

    /// 一组已授权条目 → 一组卡片 DTO，挂着**请求者自己**的播放痕迹与偏好。
    ///
    /// 这是卡片映射唯一的一份实现。痕迹只能从这里进入 DTO，所以"网页显示的是谁的
    /// 观看进度"这个问题在整个服务端只有一个答案：`principal.userID` 的那一份。
    /// `media_items` 上的 `watched` / `favorite` / `play_progress` 是桌面机主的痕迹，
    /// 一个字段都不会被读到这里来。
    ///
    /// - Note: 逐用户仓库的批量读取一次最多 100 项，与分页上限一致；调用方传入更多
    ///   条目属于编程错误，会在仓库边界上抛出。
    private func libraryItems(
        _ items: [MediaItem],
        for principal: ServerRequestPrincipal
    ) throws -> [ServerLibraryItem] {
        guard !items.isEmpty else { return [] }
        let identifiers = items.map(\.id)
        let states = try userMediaStateRepository.fetch(userID: principal.userID, mediaIDs: identifiers)
        let preferences = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaIDs: identifiers)
        return items.map { item in
            ServerLibraryItem(
                id: item.id,
                type: item.type.rawValue,
                title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名媒体",
                year: item.year,
                artist: Self.boundedText(item.artist, maximumLength: 256),
                album: Self.boundedText(item.album, maximumLength: 256),
                durationSeconds: item.duration,
                hasLyrics: item.hasLyrics,
                artworkAvailable: item.posterPath?.isEmpty == false,
                backdropAvailable: item.backdropPath?.isEmpty == false,
                isSeries: Self.isSeriesContainer(item),
                isRemoteSource: Self.approvedRemoteAssetURL(for: item) != nil,
                remoteSourceKind: ServerRemoteSourceKind(sourcePath: item.sourcePath),
                userState: states[item.id].map(Self.protocolState),
                userPreference: preferences[item.id].map(Self.protocolPreference) ?? .empty
            )
        }
    }

    func queue(for principal: ServerRequestPrincipal) throws -> ServerQueueResponse {
        guard principal.permissions.contains(.viewMedia) else { return ServerQueueResponse(repeatMode: "sequential", shuffleEnabled: false, currentPosition: 0, items: []) }
        let snapshot = try userQueueRepository.fetch(userID: principal.userID)
        let authorized = try mediaRepository.fetchServerMediaItems(
            ids: snapshot.itemIDs,
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        )
        let byID = Dictionary(uniqueKeysWithValues: authorized.map { ($0.id, $0) })
        let items = snapshot.itemIDs.compactMap { id -> ServerQueueItem? in
            guard let item = byID[id] else { return nil }
            return ServerQueueItem(id: item.id, type: item.type.rawValue, title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名媒体", year: item.year, artworkAvailable: item.posterPath?.isEmpty == false, isSeries: Self.isSeriesContainer(item), isRemoteSource: Self.approvedRemoteAssetURL(for: item) != nil, remoteSourceKind: ServerRemoteSourceKind(sourcePath: item.sourcePath))
        }
        return ServerQueueResponse(repeatMode: snapshot.repeatMode.rawValue, shuffleEnabled: snapshot.shuffleEnabled, currentPosition: min(snapshot.currentPosition, max(items.count - 1, 0)), items: items)
    }

    func mutateQueue(request: ServerQueueMutationRequest, for principal: ServerRequestPrincipal) throws -> ServerQueueResponse? {
        guard request.isValid, principal.permissions.contains(.viewMedia), let action = ServerQueueMutationAction(rawValue: request.action) else { return nil }
        if action == .add {
            guard let mediaID = request.mediaID,
                  try publicItem(id: mediaID, for: principal, requiring: .playMedia) != nil else { return nil }
        }
        let repeatMode = request.repeatMode.flatMap(ServerQueueRepeatMode.init(rawValue:))
        guard request.repeatMode == nil || repeatMode != nil else { return nil }
        _ = try userQueueRepository.mutate(userID: principal.userID, action: action, mediaID: request.mediaID, fromIndex: request.fromIndex, toIndex: request.toIndex, repeatMode: repeatMode, shuffleEnabled: request.shuffleEnabled, currentPosition: request.currentPosition)
        return try queue(for: principal)
    }

    func updatePlaybackState(
        id: String,
        request: ServerPlaybackStateUpdateRequest,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaUserState? {
        guard request.isValid,
              try publicItem(id: id, for: principal, requiring: .playMedia) != nil
        else {
            return nil
        }
        let event: MediaLibCore.ServerPlaybackStateEvent
        switch request.event {
        case .started: event = .started
        case .progress: event = .progress
        case .stopped: event = .stopped
        case .completed: event = .completed
        case .reset: event = .reset
        }
        let state = try userMediaStateRepository.update(
            userID: principal.userID,
            mediaID: id,
            event: event,
            position: request.positionSeconds,
            duration: request.durationSeconds
        )
        return Self.protocolState(state)
    }

    func updatePreference(
        id: String,
        preference: ServerUserMediaPreferenceUpdate,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaUserPreference? {
        guard try publicItem(id: id, for: principal, requiring: .viewMedia) != nil else {
            return nil
        }
        let record = try userMediaPreferenceRepository.update(
            userID: principal.userID,
            mediaID: id,
            preference: preference
        )
        return Self.protocolPreference(record)
    }

    /// 将媒体 ID 映射为可读取的本地文件，但绝不将这个路径交给 DTO 或路由以外的调用者。
    /// 调用前已经通过用户、资料库、能力和会话授权；未知与无权 ID 统一返回 nil。
    func publicAsset(
        id: String,
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission = .playMedia
    ) throws -> ServerMediaAsset? {
        guard let item = try publicItem(id: id, for: principal, requiring: permission),
              let filePath = item.filePath
        else { return nil }
        if let url = Self.localReadableFileURL(from: filePath) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size >= 0
            else { return nil }
            return ServerMediaAsset(id: item.id, fileURL: url, byteLength: size)
        }
        // 远程资源不交给网页，仍先经过该条目、资料库与播放权限检查。部分 Emby
        // 音乐条目没有同步 Size；路由会以受限的单字节 Range 探测总长度，不能在
        // 此处因为元数据缺失就把可播放条目错误置灰。
        guard let remoteURL = Self.approvedRemoteAssetURL(for: item) else { return nil }
        return ServerMediaAsset(id: item.id, remoteURL: remoteURL, byteLength: max(0, item.fileSize ?? 0))
    }

    /// 这个条目在网页上能选的**全部**字幕轨，按稳定顺序排列。
    ///
    /// 三种来源接在同一条名单上，因为对读者来说它们就是同一件事：
    ///
    /// 1. 同目录、同基名的外挂文件（vtt / srt / ass / ssa）；
    /// 2. 封装在容器里的文本字幕轨（ffprobe 看得见，浏览器看不见）；
    /// 3. 远程来源（Emby/Jellyfin/Plex）服务器上的字幕轨。
    ///
    /// 浏览器拿到的永远只是这份名单里的**序号**，从来没有文件名、容器流号或上游
    /// 地址。序号的含义由本函数唯一定义，取轨道内容时走同一份枚举。
    func subtitleTracks(
        id: String,
        for principal: ServerRequestPrincipal
    ) throws -> [ServerSubtitleTrackReference]? {
        guard let asset = try publicAsset(id: id, for: principal, requiring: .playMedia) else {
            return nil
        }
        var references: [ServerSubtitleTrackReference] = []
        let mediaStem = asset.fileURL.deletingPathExtension().lastPathComponent
        for (index, subtitle) in try Self.webVTTSubtitleAssets(for: asset).enumerated() {
            let descriptor = ServerSubtitleSidecar.descriptor(
                mediaStem: mediaStem,
                subtitleFileName: subtitle.fileURL.lastPathComponent,
                fallbackIndex: index
            )
            references.append(
                ServerSubtitleTrackReference(
                    label: descriptor.label,
                    language: descriptor.language,
                    origin: .sidecar,
                    source: .sidecar(subtitle)
                )
            )
        }
        for stream in trackCatalog.embeddedSubtitleStreams(for: asset) {
            references.append(
                ServerSubtitleTrackReference(
                    label: Self.embeddedSubtitleLabel(stream),
                    language: Self.normalizedSubtitleLanguage(stream.language),
                    origin: .embedded,
                    source: .embedded(asset: asset, streamIndex: stream.index)
                )
            )
        }
        if let remoteURL = asset.remoteURL,
           let item = try publicItem(id: id, for: principal, requiring: .playMedia) {
            for track in ServerRemoteSubtitleCatalog.tracks(
                for: item, streamURL: remoteURL, fetcher: remoteAssetFetcher
            ) {
                references.append(
                    ServerSubtitleTrackReference(
                        label: track.label,
                        language: track.language,
                        origin: .remote,
                        source: .remote(track)
                    )
                )
            }
        }
        return Array(references.prefix(ServerWebVTTSubtitleTrack.maximumTrackCount))
    }

    func webVTTSubtitleTracks(
        id: String,
        for principal: ServerRequestPrincipal
    ) throws -> [ServerWebVTTSubtitleTrack]? {
        try subtitleTracks(id: id, for: principal)?.enumerated().map { index, reference in
            reference.descriptor(id: index)
        }
    }

    /// 序号 → 具体来源。越界与无权都是 nil，绝不回退到"别的那条字幕"。
    func subtitleTrack(
        id: String,
        trackID: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerSubtitleTrackReference? {
        guard (0..<ServerWebVTTSubtitleTrack.maximumTrackCount).contains(trackID),
              let tracks = try subtitleTracks(id: id, for: principal),
              tracks.indices.contains(trackID)
        else { return nil }
        return tracks[trackID]
    }

    /// 网页播放器一次问全：音轨、字幕轨，以及"直放能不能出声"。
    ///
    /// 这三件事必须一起回答。只回答字幕的话，网页仍然要靠浏览器自己去发现音轨，
    /// 而 Chrome 与 Firefox 根本没有那个 API——音轨菜单于是永远不出现。
    func playbackTracks(
        id: String,
        for principal: ServerRequestPrincipal
    ) throws -> ServerWebPlaybackTrackSet? {
        guard let asset = try publicAsset(id: id, for: principal, requiring: .playMedia) else {
            return nil
        }
        let subtitles = (try subtitleTracks(id: id, for: principal) ?? [])
            .enumerated()
            .map { index, reference in reference.descriptor(id: index) }
        // 远程条目探不了容器：字节在别人家的服务器上，ffprobe 够不着。它们的音轨
        // 由来源服务器自己决定，网页这一侧只呈现字幕。
        let audio = trackCatalog.audioTracks(for: asset)
        return ServerWebPlaybackTrackSet(
            audio: audio?.tracks ?? [],
            subtitles: subtitles,
            remuxable: audio?.remuxable ?? false,
            remuxUnavailableReason: audio?.remuxUnavailableReason
        )
    }

    /// 跳转落点解析：给一个想去的秒数，回一个**关键帧对齐后**的秒数。
    ///
    /// 播放器拿这个值去起重封装流，于是 ffmpeg 的关键帧吸附成了空操作，画面与
    /// 时间轴从第一帧起就是对上的。解析不出来时回退到原值——那时的表现和从前
    /// 一样（最多偏一个 GOP），而不是拒绝播放。
    func remuxStartSeconds(
        id: String,
        at seconds: Double,
        for principal: ServerRequestPrincipal
    ) throws -> Double? {
        guard let asset = try publicAsset(id: id, for: principal, requiring: .playMedia) else {
            return nil
        }
        return trackCatalog.keyframeStart(for: asset, at: seconds) ?? seconds
    }

    /// 重封装流的构造入口。授权与本地可读性都在这里判完，路由只负责把字节写出去。
    func audioRemuxStream(
        id: String,
        audioTrackID: Int,
        startSeconds: Double,
        for principal: ServerRequestPrincipal
    ) throws -> ServerAudioRemuxStream? {
        guard let asset = try publicAsset(id: id, for: principal, requiring: .playMedia),
              let audio = trackCatalog.audioTracks(for: asset),
              audio.remuxable,
              audio.tracks.contains(where: { $0.id == audioTrackID })
        else { return nil }
        return ServerAudioRemuxStream.make(
            asset: asset, audioTrackID: audioTrackID, startSeconds: startSeconds
        )
    }

    private static func embeddedSubtitleLabel(
        _ stream: FFprobeMediaInspector.ProbedStream
    ) -> String {
        var pieces: [String] = []
        if let title = stream.title { pieces.append(title) }
        if let language = stream.language,
           !pieces.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            pieces.append(language)
        }
        if stream.isForced { pieces.append("强制") }
        let label = pieces.joined(separator: " · ")
        return label.isEmpty ? "内封字幕 \(stream.typeOrdinal + 1)" : String(label.prefix(80))
    }

    /// 容器里的语言标记是 ISO 639-2（`chi`/`jpn`）。复用外挂字幕那份映射把它归一成
    /// BCP-47；映射不到就不声明，理由与外挂字幕一致。
    private static func normalizedSubtitleLanguage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return ServerSubtitleSidecar.descriptor(
            mediaStem: "media", subtitleFileName: "media.\(raw).srt", fallbackIndex: 0
        ).language
    }

    /// 海报/背景图使用与详情相同的逐条目授权，不接受客户端路径。SVG 等可执行图片格式
    /// 和超大文件被排除，避免图片端点退化为任意文件读取或响应放大器。
    func publicArtwork(
        id: String,
        kind: ServerArtworkKind,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaAsset? {
        guard let item = try publicItem(id: id, for: principal, requiring: .viewMedia) else {
            return nil
        }
        // 单集自己一般没有海报，海报挂在系列上。详情把 `artworkAvailable` 回退到
        // 了父级，这里必须跟着回退，否则那张图会稳定 404。
        let parent: MediaItem? = {
            guard item.type == .episode, let parentID = item.parentID else { return nil }
            return try? publicItem(id: parentID, for: principal, requiring: .viewMedia)
        }()
        let rawPath: String?
        switch kind {
        case .poster: rawPath = item.posterPath ?? parent?.posterPath
        case .backdrop: rawPath = item.backdropPath ?? parent?.backdropPath
        }
        guard let rawPath, !rawPath.isEmpty else { return nil }
        // 授权归属跟着实际提供图片的那个条目走。
        let artworkOwner = (item.posterPath ?? item.backdropPath) == nil ? (parent ?? item) : item
        if let url = Self.localReadableFileURL(from: rawPath),
           ServerArtworkKind.allowedExtensions.contains(url.pathExtension.lowercased()) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  size <= ServerArtworkKind.maximumByteLength
            else { return nil }
            return ServerMediaAsset(id: item.id, fileURL: url, byteLength: Int64(size))
        }
        // 远程封面地址**没有扩展名**，不能拿本地那份白名单去卡它。
        //
        // Emby/Jellyfin 的海报是 `/Items/<id>/Images/Primary?…`，Plex 是
        // `/photo/:/transcode?…`，两者的 `pathExtension` 都是空串。这里从前和本地
        // 文件共用同一条扩展名判断，于是**每一个**远程条目的封面都在这里返回 nil、
        // 路由回 404——网页上整台 Emby 一张封面都不显示。
        //
        // 扩展名白名单守的是"要不要打开这个本地文件"（见上面那条分支）。远程这一侧
        // 的边界由另外两件事保证：`approvedRemoteURL` 只放行**已连接的远程媒体
        // 服务器**的 http(s) 地址，而路由拿到字节后一律由 `ServerArtworkThumbnailer`
        // 派生成 JPEG 再发出——不能解码成图片的字节根本出不去。
        guard let remoteURL = Self.approvedRemoteArtworkURL(rawPath, for: artworkOwner) else {
            return nil
        }
        // 图片端点使用独立的有界上游读取，不信任远端声明的 Content-Length。
        return ServerMediaAsset(id: item.id, remoteURL: remoteURL, byteLength: 0)
    }

    private func publicItem(
        id: String,
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> MediaItem? {
        guard principal.permissions.contains(permission) else { return nil }
        let vaultPaths = try vaultSourcePaths(for: principal, requiring: permission)
        return try mediaRepository.fetchServerMediaItem(
            id: id,
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: permission)
                .union(vaultPaths),
            // 只有在这个账号此刻真的能读保险库时，才让 `privateCollection` 容器行
            // 通过——保险库的顶层条目正是这类行。它拿不到授权路径时这个开关毫无
            // 作用（授权集合里没有保险库路径），但把两件事绑在一起，日后谁也无法
            // 只放开其中一件。
            includesPrivateCollectionType: !vaultPaths.isEmpty
        )
    }

    private func publicItems(
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> [MediaItem] {
        guard principal.permissions.contains(permission) else { return [] }
        let allowedSourcePaths = try allowedPublicSourcePaths(for: principal, requiring: permission)
        return try mediaRepository.fetchAll().filter { item in
            guard item.type != .privateCollection,
                  let sourcePath = item.sourcePath,
                  !sourcePath.isEmpty
            else {
                return false
            }
            return allowedSourcePaths.contains(sourcePath)
        }
    }

    /// 授权集合 = 授权来源自身的路径 + 远程来源根下真实存在的逐资料库子路径。
    ///
    /// 展开必须发生在这里而不是 SQL 里：服务端十几处查询共用一张等值连接的授权
    /// 临时表，改成前缀匹配会让 `(source_path, type, parent_id, …)` 复合索引全部
    /// 失效。归属与护栏见 `ServerSourceAuthorizationResolver`。
    private func allowedPublicSourcePaths(
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> Set<String> {
        guard principal.permissions.contains(permission) else { return [] }
        // 归属判定要看到**全部**来源（含保险库），否则嵌套在公开来源之下的私密
        // 来源会被公开来源顺手授权。授权判定本身仍只放行非私密来源。
        let allSources = try sourceRepository.fetchAll()
        let concretePaths = allSources.contains(where: { ServerSourceAuthorizationResolver.isExpandableRoot($0.path) })
            ? try mediaRepository.distinctSourcePaths()
            : []
        return ServerSourceAuthorizationResolver.authorizedSourcePaths(
            sources: allSources,
            concreteSourcePaths: concretePaths,
            isAuthorized: { source in
                principal.canManageServer || principal.allows(permission, libraryID: source.id)
            }
        )
    }

    /// 保险库来源的授权路径。
    ///
    /// 两个条件缺一不可：
    ///
    /// 1. **这台机器上的桌面 App 正解锁着**。保险库的口令与 Touch ID 只存在于
    ///    App 里，服务端从不接收口令；它读到的只是一个会过期的解锁会话文件。
    /// 2. **这个账号被授权了那个保险库资料库**。授权是逐库的，与其它资料库同一
    ///    套机制——所以"给某个成员开放保险库"是一个明确的动作，而不是副作用。
    ///
    /// 任何一条不成立就得到空集合，而空集合会让所有分页查询直接返回空页——
    /// 失败即关闭，和其它作用域一样。
    func vaultSourcePaths(
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> Set<String> {
        guard principal.permissions.contains(permission), vaultUnlockProvider() else { return [] }
        return Set(
            try sourceRepository.fetchAll()
                .filter { $0.mediaType == .privateCollection }
                .filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .filter { principal.allows(permission, libraryID: $0.id) }
                .map(\.path)
        )
    }

    /// 逐条目读取（详情、封面、字节流）的授权集合：公开来源 + 已解锁且已授权的保险库。
    ///
    /// 列表类查询**不用**它——首页、一级分类、搜索仍然只看公开来源，与客户端一致：
    /// 保险库在客户端也不是混进电影、剧集里，而是它自己的一个入口。这里放宽的只是
    /// "拿着一个保险库条目的 id 能不能打开它"，而那正是保险库页面点进去要做的事。
    private func readableSourcePaths(
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> Set<String> {
        try allowedPublicSourcePaths(for: principal, requiring: permission)
            .union(try vaultSourcePaths(for: principal, requiring: permission))
    }

    /// 网页保险库页面要显示的状态。页面据此决定画锁屏还是画内容，而**内容永远
    /// 来自同一套授权查询**——这个枚举只决定措辞，不决定可见性。
    enum VaultAccess: Equatable {
        /// 这个账号没有任何保险库资料库的授权。
        case notGranted
        /// 有授权，但机器上的 App 现在是锁着的。
        case locked
        case unlocked
    }

    func vaultAccess(for principal: ServerRequestPrincipal) throws -> VaultAccess {
        guard principal.permissions.contains(.viewMedia) else { return .notGranted }
        let vaultSources = try sourceRepository.fetchAll()
            .filter { $0.mediaType == .privateCollection }
            .filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard vaultSources.contains(where: { principal.allows(.viewMedia, libraryID: $0.id) }) else {
            return .notGranted
        }
        return vaultUnlockProvider() ? .unlocked : .locked
    }

    /// 一级分类（电影／剧集／动漫／音乐／相册……）只覆盖**本地与网络挂载**来源。
    ///
    /// 这与客户端逐字一致：`AppState.rebuildDerivedItemCaches` 在把条目放进
    /// `topLevelRaw`／`musicTracksRaw`／`albumRaw` 之前会对远程条目 `continue`，
    /// 远程内容只出现在各自的来源分组里（`ContentView.embySourceGroup`）。把两者
    /// 混进同一个"电影"目录会让同一份资料库在两端呈现出不同的结构。
    private func localPublicSourcePaths(
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> Set<String> {
        try allowedPublicSourcePaths(for: principal, requiring: permission)
            .filter { !RemoteLibraryPathPolicy.isMediaServerSourcePath($0) }
    }

    /// 浏览作用域：无远程作用域时只给本地路径；给定作用域时收窄到该来源或该资料库。
    ///
    /// 用"收窄授权集合"而不是加 WHERE 条件，是为了让授权与筛选是同一套机制并
    /// **失败即关闭**——未知或越权的作用域得到空集合，分页查询对空集合直接返回空页。
    private func browseSourcePaths(
        remoteScopeID: String?,
        includesRemoteSources: Bool = false,
        vaultScope: Bool = false,
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> Set<String> {
        // 保险库是一个独立的目的地，不与任何其它作用域叠加：它要么是这一次浏览的
        // 全部范围，要么完全不在范围里。
        if vaultScope { return try vaultSourcePaths(for: principal, requiring: permission) }
        let authorized = try allowedPublicSourcePaths(for: principal, requiring: permission)
        guard let remoteScopeID, !remoteScopeID.isEmpty else {
            // 首页看板要的是"这个账号能看到的一切"，本地与远程一视同仁。
            return includesRemoteSources
                ? authorized
                : authorized.filter { !RemoteLibraryPathPolicy.isMediaServerSourcePath($0) }
        }
        let scoped = authorized.filter { path in
            guard RemoteLibraryPathPolicy.isMediaServerSourcePath(path) else { return false }
            if Self.opaqueScopeID(for: path) == remoteScopeID { return true }
            // 作用域也可以是整台服务器：此时它下面的每个资料库路径都算命中。
            guard let root = RemoteLibraryPathPolicy.sourceRootPath(from: path) else { return false }
            return Self.opaqueScopeID(for: root) == remoteScopeID
        }
        return scoped
    }

    /// 已连接远程服务器及其资料库，镜像客户端每台服务器一个侧栏分组的结构。
    func remoteSourceGroups(for principal: ServerRequestPrincipal) throws -> [ServerRemoteSourceGroup] {
        let authorized = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
            .filter { RemoteLibraryPathPolicy.isMediaServerSourcePath($0) }
        guard !authorized.isEmpty else { return [] }
        let sources = try sourceRepository.fetchAll()
        // 徽标必须和点进去看到的条数相等：作用域浏览页只列顶层非分集条目，所以
        // 这里也只数它们。数全部行时，一个 1200 集的剧集库徽标写 1200、页面 30 部剧。
        let counts = try mediaRepository.itemCountsBySourcePath(
            allowedSourcePaths: authorized, topLevelOnly: true
        )

        var groups: [String: (root: String, name: String, kind: ServerRemoteSourceKind, libraries: [ServerRemoteLibraryEntry], total: Int)] = [:]
        for path in authorized.sorted() {
            guard let rawRoot = RemoteLibraryPathPolicy.sourceRootPath(from: path),
                  let kind = ServerRemoteSourceKind(sourcePath: rawRoot)
            else { continue }
            // 按归一化键分组。同一台服务器在库里可能以 `EMBY://Host/x`、
            // `emby://host/x/` 等写法出现；用原始字符串分组会让它在侧栏裂成
            // 几个同名分组，看上去就是"目录不稳定"。
            let root = SourcePathPolicy.canonicalKey(for: rawRoot)
            let count = counts[path] ?? 0
            let sourceName = sources.first {
                SourcePathPolicy.canonicalKey(for: $0.path) == root
            }?.name ?? kind.displayName
            var entry = groups[root] ?? (root: root, name: sourceName, kind: kind, libraries: [], total: 0)
            entry.total += count
            // 根路径自身不是一个资料库入口；只有 `/library/...` 子路径才成行。
            if let info = RemoteLibraryPathPolicy.libraryInfo(from: path), count > 0 {
                // 音乐类资料库不单独成行，与客户端一致：它们由分组内的音乐入口承载，
                // 否则同一批远程音乐会被拆成两个没有上下文的入口。
                if !RemoteLibraryPathPolicy.isMusicLibrary(collectionType: info.collectionType) {
                    entry.libraries.append(ServerRemoteLibraryEntry(
                        id: Self.opaqueScopeID(for: path),
                        title: Self.boundedText(info.name, maximumLength: 128) ?? "远程分类",
                        itemCount: count
                    ))
                }
            }
            groups[root] = entry
        }
        return groups
            .filter { $0.value.total > 0 }
            .map { _, entry in
                ServerRemoteSourceGroup(
                    id: Self.opaqueScopeID(for: entry.root),
                    title: Self.boundedText(entry.name, maximumLength: 128) ?? entry.kind.displayName,
                    kind: entry.kind,
                    itemCount: entry.total,
                    libraries: entry.libraries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 作用域的不透明 ID。
    ///
    /// 绝不能把 `source_path` 直接放进 URL：它含主机名与百分号编码的资料库名，
    /// 安全基线禁止这类信息出现在浏览器可见的地址里。这里用来源路径的 SHA-256
    /// 前缀——不可逆，且解析只在**已授权**集合内做匹配，因此即使有人猜中某个
    /// 路径的哈希也拿不到越权结果。不用带进程密钥的 HMAC 是为了让书签在服务
    /// 重启后依然有效。
    ///
    /// **摘要前必须先归一化。** 分组曾经按 `canonicalKey` 聚合、却直接对原始路径
    /// 取摘要来解析作用域，于是同一台服务器写成 `EMBY://Host/x` 的那些条目算出
    /// 的 ID 与侧栏发出的 ID 对不上：徽标数了 3 条，点「全部」只出来 2 条，写法
    /// 全不一致时甚至整页为空。分组、资料库行、作用域解析三处必须共用这一个函数。
    static func opaqueScopeID(for sourcePath: String) -> String {
        let digest = SHA256.hash(data: Data(SourcePathPolicy.canonicalKey(for: sourcePath).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func categoryCacheKey(for principal: ServerRequestPrincipal) -> String {
        let permissions = principal.permissions.map(\.rawValue).sorted().joined(separator: ",")
        let grants = principal.libraryGrants.values
            .sorted { $0.libraryID < $1.libraryID }
            .map { grant in
                "\(grant.libraryID):\(grant.canView ? 1 : 0):\(grant.canPlay ? 1 : 0):\(grant.canDownload ? 1 : 0)"
            }
            .joined(separator: ",")
        return "\(principal.userID)|\(permissions)|\(grants)"
    }

    private func authorizedEpisodeNavigation(
        for item: MediaItem,
        principal: ServerRequestPrincipal
    ) throws -> (previous: ServerEpisodeNavigation?, next: ServerEpisodeNavigation?) {
        guard item.type == .episode, let parentID = item.parentID, !parentID.isEmpty else {
            return (nil, nil)
        }
        let episodes = try mediaRepository.fetchServerSeriesEpisodes(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .playMedia),
            seriesID: parentID
        ).filter(Self.hasPlayableAsset)
        guard let index = episodes.firstIndex(where: { $0.id == item.id }) else { return (nil, nil) }
        func navigation(_ episode: MediaItem?) -> ServerEpisodeNavigation? {
            guard let episode else { return nil }
            return ServerEpisodeNavigation(
                id: episode.id,
                title: Self.boundedText(episode.cardTitle, maximumLength: 512) ?? "未命名剧集"
            )
        }
        return (
            navigation(index > episodes.startIndex ? episodes[index - 1] : nil),
            navigation(index + 1 < episodes.endIndex ? episodes[index + 1] : nil)
        )
    }

    /// 协议枚举 → 仓储枚举。一一对应且没有降级分支：两侧的词汇现在是同一套。
    private func databaseSort(_ sort: ServerLibrarySort) -> ServerLibraryDatabaseSort {
        switch sort {
        case .recentlyUpdated: return .recentlyUpdated
        case .dateAdded: return .dateAdded
        case .title: return .title
        case .year: return .year
        case .runtime: return .runtime
        case .progress: return .progress
        case .score: return .score
        case .rating: return .rating
        case .lastPlayed: return .lastPlayed
        }
    }

    private func databaseSortOrder(_ order: ServerLibrarySortOrder) -> ServerLibraryDatabaseSortOrder {
        switch order {
        case .primary: return .primary
        case .reverse: return .reverse
        }
    }

    /// 一个作用域内实际可用的题材与排序键。
    ///
    /// 题材在数据库里是 `", "` 分隔的组合串，这里按客户端的规则展开：拆分、去空白、
    /// 去重、`localizedStandardCompare` 排序。上限 64 个——一个装了几百项的下拉
    /// 已经不是筛选器了。
    func facets(
        type: String?,
        group: ServerLibraryMediaGroup?,
        for principal: ServerRequestPrincipal
    ) throws -> ServerLibraryFacetsResponse {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerLibraryFacetsResponse(genres: [], availableSorts: Self.alwaysAvailableSorts)
        }
        let mediaType = type.flatMap(MediaType.init(rawValue:))
        let excludedTypes: Set<MediaType> = group == .video ? [.music, .photo, .episode] : []
        // 题材与排序键必须和它们要筛的那个网格同口径。这里从前用的是**含远程**的
        // 授权集合且没有在线条目排除，于是本地分类页的「类型」下拉里会出现只存在
        // 于 Emby 条目的题材——一个选中之后必然筛出空网格的选项。
        // 远程作用域页当前不提供题材筛选（路由传的是空 facets），所以这里只服务本地。
        let facets = try mediaRepository.fetchServerLibraryFacets(
            allowedSourcePaths: try localPublicSourcePaths(for: principal, requiring: .viewMedia),
            type: mediaType,
            topLevelOnly: mediaType == nil,
            userID: principal.userID,
            excludedTypes: excludedTypes,
            excludesOnlineSourceItems: true
        )
        var seen = Set<String>()
        var genres: [String] = []
        for combined in facets.genreValues {
            for raw in combined.components(separatedBy: ", ") {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 48, seen.insert(name).inserted else { continue }
                genres.append(name)
            }
        }
        genres.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        var sorts = Self.alwaysAvailableSorts
        if facets.hasRuntime { sorts.append(.runtime) }
        if facets.hasProviderRating { sorts.append(.score) }
        if facets.hasUserRating { sorts.append(.rating) }
        return ServerLibraryFacetsResponse(genres: Array(genres.prefix(64)), availableSorts: sorts)
    }

    /// 与客户端一致：这四个键任何资料库都成立，其余三个按数据存在与否追加。
    /// `lastPlayed` 不在这里——它是历史页自己的排序，不是通用键。
    private static let alwaysAvailableSorts: [ServerLibrarySort] = [
        .recentlyUpdated, .dateAdded, .title, .year, .progress
    ]

    private static func isSeriesContainer(_ item: MediaItem) -> Bool {
        switch item.type {
        case .tvShow, .anime, .variety:
            return true
        case .documentary:
            return item.filePath?.isEmpty != false
        default:
            return false
        }
    }

    private static func localReadableFileURL(from rawPath: String) -> URL? {
        // 空串会被 `URL(fileURLWithPath:)` 解析成**当前工作目录**，而目录是存在的
        // ——于是"没有本地文件"会被当成"有一个可读文件"。
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let url: URL
        if let parsedURL = URL(string: rawPath), parsedURL.scheme != nil {
            guard parsedURL.isFileURL else { return nil }
            url = parsedURL
        } else {
            url = URL(fileURLWithPath: rawPath)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 远程同步条目允许被代理的条件刻意比“任意 http URL”更严格：必须来自已知
    /// 媒体服务器来源，且 URL 本身没有 userinfo、fragment 或非 HTTP(S) scheme。
    /// 这样普通 URL 媒体源不能利用已登录的 Web 服务探测内网地址。
    private static func approvedRemoteAssetURL(for item: MediaItem) -> URL? {
        guard let rawPath = item.filePath else { return nil }
        return approvedRemoteURL(rawPath, item: item)
    }

    private static func approvedRemoteArtworkURL(_ rawPath: String, for item: MediaItem) -> URL? {
        approvedRemoteURL(rawPath, item: item)
    }

    /// 元数据提供方缓存下来的图片地址（剧照、人物头像、推荐海报）。
    ///
    /// 这些地址属于本地条目，因此不能走 `approvedRemoteURL` 那条"必须来自已连接的
    /// 远程媒体服务"的规则。取而代之的是一份主机白名单：只代理**扫描阶段确实会
    /// 写入**的那个图片 CDN。它同时是一道 SSRF 边界——数据库里的任意一个字符串
    /// 都不能变成让服务端去访问的地址。
    private static let approvedMetadataImageHosts: Set<String> = ["image.tmdb.org"]

    /// 详情页三种图（人物头像、剧照、推荐海报）的取图授权。
    ///
    /// 本地条目的这些地址来自元数据刮削，只可能是 TMDB 的图片 CDN——那条主机
    /// 白名单继续守着它。但远程条目的同一批图**来自它自己那台媒体服务器**：
    /// Emby/Jellyfin 是 `/Items/<id>/Images/Primary?…`，Plex 是
    /// `/photo/:/transcode?…`，两者既不在 TMDB 白名单里，也没有扩展名。于是
    /// 整个 Emby 库在网页上一张演员头像、一张剧照都没有——不是没同步，是全被
    /// 这道判断挡在授权层。
    ///
    /// 远程这一侧走的是与该条目封面**完全相同**的那条规则（见
    /// `approvedRemoteArtworkURL`）：只放行已连接远程媒体服务器上的条目所携带的
    /// http(s) 地址，而路由拿到字节后一律由 `ServerArtworkThumbnailer` 派生成
    /// JPEG 再发出——不能解码成图片的字节根本出不去。封面早就这样发了，同一个
    /// 条目的剧照没有理由适用另一套边界。
    static func approvedDetailImageURL(_ rawPath: String?, for item: MediaItem) -> URL? {
        if let approved = approvedRemoteImageURL(rawPath) { return approved }
        guard let rawPath, !rawPath.isEmpty else { return nil }
        return approvedRemoteURL(rawPath, item: item)
    }

    static func approvedRemoteImageURL(_ rawPath: String?) -> URL? {
        guard let rawPath, rawPath.utf8.count <= 4_096,
              let url = URL(string: rawPath),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased(),
              approvedMetadataImageHosts.contains(host),
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.port == nil,
              !url.path.isEmpty,
              ServerArtworkKind.allowedExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    /// 详情页剧照 / 推荐海报 / 人物头像的同源代理来源。
    ///
    /// 逐条目授权先于任何取图发生：调用方给的是一个媒体 ID 和一个序号，
    /// 拿不到授权就没有 URL。序号越界同样是 nil，而不是回退到别的图。
    func detailImageAsset(
        itemID: String,
        kind: ServerDetailImageKind,
        index: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaAsset? {
        guard index >= 0, index < 64,
              let item = try publicItem(id: itemID, for: principal, requiring: .viewMedia),
              let snapshot = try mediaDetailRepository.fetch(mediaID: item.parentID ?? item.id)
        else { return nil }
        switch kind {
        case .still:
            let artwork = snapshot.artwork.sorted { $0.order < $1.order }
            guard index < artwork.count else { return nil }
            let value = artwork[index]
            if let localPath = value.localPath,
               let url = Self.localReadableFileURL(from: localPath),
               ServerArtworkKind.allowedExtensions.contains(url.pathExtension.lowercased()),
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0, size <= ServerArtworkKind.maximumByteLength {
                return ServerMediaAsset(id: value.id, fileURL: url, byteLength: Int64(size))
            }
            guard let remoteURL = Self.approvedDetailImageURL(value.thumbURL, for: item) else { return nil }
            return ServerMediaAsset(id: value.id, remoteURL: remoteURL, byteLength: 0)
        case .discovery:
            let ordered = snapshot.relatedTitles.sorted { $0.order < $1.order }.prefix(24)
            guard index < ordered.count,
                  let remoteURL = Self.approvedDetailImageURL(Array(ordered)[index].posterURL, for: item)
            else { return nil }
            return ServerMediaAsset(id: "\(item.id)-discovery-\(index)", remoteURL: remoteURL, byteLength: 0)
        case .portrait:
            // 与 `authorizedDetailExtras` 中的 `portraitIndex` 同一个序列。
            let ordered = snapshot.credits.sorted { $0.order < $1.order }
            guard index < ordered.count,
                  let person = snapshot.people.first(where: { $0.id == ordered[index].personID }),
                  let remoteURL = Self.approvedDetailImageURL(person.profileURL, for: item)
            else { return nil }
            return ServerMediaAsset(id: "\(item.id)-portrait-\(index)", remoteURL: remoteURL, byteLength: 0)
        }
    }

    private static func approvedRemoteURL(_ rawPath: String, item: MediaItem) -> URL? {
        guard rawPath.utf8.count <= 4_096,
              let url = URL(string: rawPath),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              !url.path.isEmpty,
              isTrustedRemoteItem(item)
        else { return nil }
        return url
    }

    /// 这个条目的 http(s) 地址是否可以经服务端代理。
    ///
    /// scheme 判断走 `RemoteLibraryPathPolicy` 而不是内联字面量：这里原本是仓库里
    /// 第三份手抄的 scheme 列表，而且**漏了 `mlink://`** ——Mlink 条目于是既拿不到
    /// 封面代理地址，也不会被标成远程来源，在网页上表现为一整台服务器的内容没有
    /// 封面。provider 白名单同步补上。
    private static func isTrustedRemoteItem(_ item: MediaItem) -> Bool {
        guard RemoteLibraryPathPolicy.isMediaServerSourcePath(item.sourcePath) else { return false }
        guard let provider = item.metadataProvider?.lowercased() else { return true }
        return ServerRemoteSourceKind.allCases.contains { $0.rawValue == provider }
    }

    private static func hasPlayableAsset(_ item: MediaItem) -> Bool {
        item.filePath.flatMap(localReadableFileURL(from:)) != nil || approvedRemoteAssetURL(for: item) != nil
    }

    private static func webVTTSubtitleAssets(for asset: ServerMediaAsset) throws -> [ServerMediaAsset] {
        guard asset.remoteURL == nil else { return [] }
        let fileManager = FileManager.default
        let resolvedMediaURL = asset.fileURL.resolvingSymlinksInPath().standardizedFileURL
        let directory = resolvedMediaURL.deletingLastPathComponent()
        let stem = resolvedMediaURL.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [] }
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return try candidates.compactMap { candidate -> ServerMediaAsset? in
            guard ServerSubtitleSidecar.supportedExtensions.contains(
                candidate.pathExtension.lowercased()
            ) else { return nil }
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedCandidate.deletingLastPathComponent() == directory else { return nil }
            let candidateStem = resolvedCandidate.deletingPathExtension().lastPathComponent
            guard candidateStem == stem || candidateStem.hasPrefix(stem + ".") else { return nil }
            let values = try resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  size <= ServerWebVTTSubtitleTrack.maximumByteLength
            else { return nil }
            return ServerMediaAsset(id: asset.id, fileURL: resolvedCandidate, byteLength: Int64(size))
        }
        .sorted { $0.fileURL.lastPathComponent.localizedStandardCompare($1.fileURL.lastPathComponent) == .orderedAscending }
        .prefix(ServerWebVTTSubtitleTrack.maximumTrackCount)
        .map { $0 }
    }

    private static func boundedText(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }

    private static func genres(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { boundedText(String($0), maximumLength: 128) }
            .prefix(24)
            .map { $0 }
    }

    private static func protocolState(_ state: ServerUserMediaStateRecord) -> ServerMediaUserState {
        ServerMediaUserState(
            itemID: state.mediaID,
            positionSeconds: state.playPosition,
            progress: state.playProgress,
            isWatched: state.isWatched,
            playCount: state.playCount,
            lastPlayedAt: state.lastPlayedAt,
            updatedAt: state.updatedAt
        )
    }

    private static func protocolPreference(_ preference: ServerUserMediaPreferenceRecord) -> ServerMediaUserPreference {
        ServerMediaUserPreference(
            isFavorite: preference.isFavorite,
            isWatchlist: preference.isWatchlist,
            rating: preference.userRating
        )
    }
}

struct ServerLibrarySnapshot {
    let summary: ServerLibrarySummary
    let items: ServerLibraryItemsResponse
}

/// Web 专用的字幕轨引用。ID 只是稳定排序后的有界序号，绝不携带文件名、容器流号
/// 或上游地址。
struct ServerWebVTTSubtitleTrack: Codable, Equatable {
    static let maximumTrackCount = 16
    static let maximumByteLength = 8 * 1024 * 1024

    let id: Int
    let label: String
    /// BCP-47 语言标记，从文件名或轨道标签解析而来；解析不出就是 nil。
    /// 播放器靠它按浏览器语言挑默认轨——声明一个错的语言比不声明更糟。
    let language: String?
    /// 这条轨来自哪里。菜单要靠它分组（外挂 / 内封 / 来源服务器），读者才知道
    /// 为什么同一部片子会同时有好几条"简体中文"。
    let origin: ServerSubtitleTrackOrigin

    init(id: Int, label: String, language: String? = nil, origin: ServerSubtitleTrackOrigin = .sidecar) {
        self.id = id
        self.label = label
        self.language = language
        self.origin = origin
    }
}

enum ServerSubtitleTrackOrigin: String, Codable, Equatable {
    /// 同目录、同基名的外挂字幕文件。
    case sidecar
    /// 封装在媒体容器里的文本字幕流。
    case embedded
    /// Emby / Jellyfin / Plex 上的字幕轨。
    case remote
}

/// 一条字幕轨在服务端的真实来源。它**不出服务端**：路由拿它去取字节，网页只见序号。
struct ServerSubtitleTrackReference {
    enum Source {
        case sidecar(ServerMediaAsset)
        /// `streamIndex` 是容器里的全局流序号（ffmpeg `-map 0:<index>`）。
        case embedded(asset: ServerMediaAsset, streamIndex: Int)
        case remote(ServerRemoteSubtitleCatalog.Track)
    }

    let label: String
    let language: String?
    let origin: ServerSubtitleTrackOrigin
    let source: Source

    func descriptor(id: Int) -> ServerWebVTTSubtitleTrack {
        ServerWebVTTSubtitleTrack(id: id, label: label, language: language, origin: origin)
    }
}

/// 网页播放器一次拿到的全部可选轨道。
struct ServerWebPlaybackTrackSet: Codable, Equatable {
    let audio: [ServerWebAudioTrack]
    let subtitles: [ServerWebVTTSubtitleTrack]
    /// 能不能提供"重新封装音轨"这条通路。为假时网页不显示换轨入口——一个按下去
    /// 什么都不会发生的菜单比没有菜单更糟。
    let remuxable: Bool
    /// 不能的时候卡在哪一步。这句话会原样显示给读者。
    let remuxUnavailableReason: String?
}

/// 保持在 Server target 内部的已授权媒体文件引用。任何协议响应都只携带媒体 ID，
/// 从不包含 `fileURL` 或文件大小以外的本地文件信息。
struct ServerMediaAsset {
    let id: String
    let fileURL: URL
    let byteLength: Int64
    /// `nil` 表示真正的本地文件；非 nil 时 fileURL 仅作为稳定的 MIME 名称来源，
    /// 实际字节必须由受限远程代理读取，不能交给 FileManager 或网页。
    let remoteURL: URL?

    init(id: String, fileURL: URL, byteLength: Int64) {
        self.id = id
        self.fileURL = fileURL
        self.byteLength = byteLength
        self.remoteURL = nil
    }

    init(id: String, remoteURL: URL, byteLength: Int64) {
        self.id = id
        self.fileURL = remoteURL
        self.byteLength = byteLength
        self.remoteURL = remoteURL
    }

    var localFileURL: URL? { remoteURL == nil ? fileURL : nil }

    var contentType: String {
        switch fileURL.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "vtt": return "text/vtt; charset=utf-8"
        case "jpg", "jpeg", "jfif": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "avif": return "image/avif"
        default: return "application/octet-stream"
        }
    }
}

/// 详情页里三类同源代理图片。它们共用逐条目授权与有界远程读取。
enum ServerDetailImageKind: String, Sendable {
    case still
    case discovery
    case portrait
}

enum ServerArtworkKind: String, Sendable {
    case poster
    case backdrop

    static let maximumByteLength = 32 * 1024 * 1024
    static let allowedExtensions: Set<String> = ["jpg", "jpeg", "jfif", "png", "webp", "gif", "avif"]
}
