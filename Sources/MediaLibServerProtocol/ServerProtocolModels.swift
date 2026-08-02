import Foundation

/// 稳定的 Mlink 协议版本。服务端和客户端必须通过 capabilities 协商可选能力，
/// 不能只根据应用版本推断行为。
public enum MlinkProtocol {
    public static let currentAPIVersion = "v1"
}

/// 服务健康检查响应；不包含目录、用户、token 或其它敏感信息。
public struct ServerHealth: Codable, Equatable, Sendable {
    public let status: String
    public let apiVersion: String
    public let serverID: String
    public let serverName: String
    public let timestamp: Date

    public init(
        status: String = "ok",
        apiVersion: String = MlinkProtocol.currentAPIVersion,
        serverID: String,
        serverName: String,
        timestamp: Date = Date()
    ) {
        self.status = status
        self.apiVersion = apiVersion
        self.serverID = serverID
        self.serverName = serverName
        self.timestamp = timestamp
    }
}

/// 当前认证主体自己的最小账户视图。它不包含会话 ID、设备 ID、Cookie、token、
/// 凭据、资料库路径或其他用户资料；权限仅用于网页安全地说明当前账号可见范围。
public struct ServerCurrentUserProfile: Codable, Equatable, Sendable {
    public let username: String
    public let displayName: String
    public let roleIDs: [String]
    public let permissionIDs: [String]

    public init(
        username: String,
        displayName: String,
        roleIDs: [String],
        permissionIDs: [String]
    ) {
        self.username = username
        self.displayName = displayName
        self.roleIDs = roleIDs.sorted()
        self.permissionIDs = permissionIDs.sorted()
    }
}

/// `/.well-known/mlink` 的公开描述。此阶段仅声明可安全探测的能力；认证、库列表
/// 和任何媒体路径将在后续 API 中单独授权后返回。
public struct MlinkServerDescriptor: Codable, Equatable, Sendable {
    public let serverID: String
    public let serverName: String
    public let apiVersion: String
    public let capabilities: [String]

    public init(
        serverID: String,
        serverName: String,
        apiVersion: String = MlinkProtocol.currentAPIVersion,
        capabilities: [String]
    ) {
        self.serverID = serverID
        self.serverName = serverName
        self.apiVersion = apiVersion
        self.capabilities = capabilities.sorted()
    }
}

/// 不含本地路径、播放痕迹或用户数据的服务端资料库概览。
/// 该 DTO 同时是 Web 首页和 Mlink 客户端资料库入口的最小共同契约。
public struct ServerLibrarySummary: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let countsByType: [String: Int]

    public init(totalItemCount: Int, countsByType: [String: Int]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.countsByType = countsByType
    }
}

/// Web/Mlink 海报墙所需的最小卡片字段。绝不传输文件路径、来源路径或 token；
/// `userState` 如果存在，也只属于当前已认证用户。
public struct ServerLibraryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let title: String
    public let year: Int?
    public let artworkAvailable: Bool
    /// 为 true 时该卡片是系列容器，应进入 `/series/{id}` 而不是播放器详情。
    /// 它不包含父级 ID、路径或来源信息。
    public let isSeries: Bool
    public let userState: ServerMediaUserState?
    public let userPreference: ServerMediaUserPreference

    public init(
        id: String,
        type: String,
        title: String,
        year: Int?,
        artworkAvailable: Bool,
        isSeries: Bool = false,
        userState: ServerMediaUserState? = nil,
        userPreference: ServerMediaUserPreference = .empty
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.artworkAvailable = artworkAvailable
        self.isSeries = isSeries
        self.userState = userState
        self.userPreference = userPreference
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, year, artworkAvailable, isSeries, userState, userPreference
    }

    /// 允许新版客户端连接仍未发送偏好字段的服务端；缺失字段绝不能放大为
    /// 桌面端全局状态，而是收敛为当前用户的空偏好。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.type = try values.decode(String.self, forKey: .type)
        self.title = try values.decode(String.self, forKey: .title)
        self.year = try values.decodeIfPresent(Int.self, forKey: .year)
        self.artworkAvailable = try values.decode(Bool.self, forKey: .artworkAvailable)
        self.isSeries = try values.decodeIfPresent(Bool.self, forKey: .isSeries) ?? false
        self.userState = try values.decodeIfPresent(ServerMediaUserState.self, forKey: .userState)
        self.userPreference = try values.decodeIfPresent(ServerMediaUserPreference.self, forKey: .userPreference) ?? .empty
    }
}

/// 系列详情页的季摘要。`seasonNumber == nil` 代表扫描来源没有提供季信息；
/// `id` 是服务端生成的展示键，不是数据库主键或路径。
public struct ServerSeriesSeason: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let seasonNumber: Int?
    public let title: String
    public let episodeCount: Int
    public let watchedCount: Int
    public let inProgressCount: Int

    public init(
        id: String,
        seasonNumber: Int?,
        title: String,
        episodeCount: Int,
        watchedCount: Int,
        inProgressCount: Int
    ) {
        self.id = id
        self.seasonNumber = seasonNumber
        self.title = title
        self.episodeCount = max(episodeCount, 0)
        self.watchedCount = min(max(watchedCount, 0), self.episodeCount)
        self.inProgressCount = min(max(inProgressCount, 0), self.episodeCount)
    }
}

/// 已授权系列的首屏详情。只含页面展示字段与当前用户偏好，不包含媒体路径、
/// 来源、外部提供商 ID、子项父键或其他用户状态。
public struct ServerSeriesDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let title: String
    public let originalTitle: String?
    public let year: Int?
    public let overview: String?
    public let genres: [String]
    public let communityRating: Double?
    public let artworkAvailable: Bool
    public let backdropAvailable: Bool
    public let totalEpisodeCount: Int
    public let seasons: [ServerSeriesSeason]
    public let userPreference: ServerMediaUserPreference

    public init(
        id: String,
        type: String,
        title: String,
        originalTitle: String?,
        year: Int?,
        overview: String?,
        genres: [String],
        communityRating: Double?,
        artworkAvailable: Bool,
        backdropAvailable: Bool,
        totalEpisodeCount: Int,
        seasons: [ServerSeriesSeason],
        userPreference: ServerMediaUserPreference = .empty
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.overview = overview
        self.genres = genres
        self.communityRating = communityRating.flatMap { $0.isFinite ? min(max($0, 0), 10) : nil }
        self.artworkAvailable = artworkAvailable
        self.backdropAvailable = backdropAvailable
        self.totalEpisodeCount = max(totalEpisodeCount, 0)
        self.seasons = seasons
        self.userPreference = userPreference
    }
}

/// 系列页按需加载的单集卡片。具体播放仍跳转到受权 `/item/{id}`，由网页播放器解码。
public struct ServerSeriesEpisode: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let runtimeSeconds: Double?
    public let artworkAvailable: Bool
    public let userState: ServerMediaUserState?

    public init(
        id: String,
        title: String,
        seasonNumber: Int?,
        episodeNumber: Int?,
        runtimeSeconds: Double?,
        artworkAvailable: Bool,
        userState: ServerMediaUserState? = nil
    ) {
        self.id = id
        self.title = title
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.runtimeSeconds = runtimeSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.artworkAvailable = artworkAvailable
        self.userState = userState
    }
}

public struct ServerSeriesEpisodesPage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerSeriesEpisode]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerSeriesEpisode]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.hasMore = self.offset + items.count < self.totalItemCount
        self.items = items
    }
}

/// 人物目录的最小卡片。人物头像 URL 可能来自第三方元数据服务，因此不会下发到
/// 网页；页面以服务端生成的姓名首字母头像显示，避免浏览人物页时泄露客户端地址。
public struct ServerPersonCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let department: String?
    public let mediaCount: Int

    public init(id: String, name: String, department: String?, mediaCount: Int) {
        self.id = id
        self.name = name
        self.department = department
        self.mediaCount = max(mediaCount, 0)
    }
}

/// 授权人物目录的有界分页结果。它只统计当前用户看得到的作品。
public struct ServerPeoplePage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerPersonCard]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerPersonCard]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.hasMore = self.offset + items.count < self.totalItemCount
        self.items = items
    }
}

/// 人物作品中的安全媒体卡。作品可播放时仍进入已有的 `/item` 或 `/series` 授权页；
/// 绝不携带文件路径、来源路径、元数据提供方 ID 或其它用户状态。
public struct ServerPersonCredit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let title: String
    public let year: Int?
    public let artworkAvailable: Bool
    public let isSeries: Bool
    public let category: String
    public let role: String?

    public init(
        id: String, type: String, title: String, year: Int?, artworkAvailable: Bool,
        isSeries: Bool, category: String, role: String?
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.artworkAvailable = artworkAvailable
        self.isSeries = isSeries
        self.category = category
        self.role = role
    }
}

/// 人物页首屏及其有界作品分页。出生地、简介等公开元数据均为展示字段；没有
/// 任一授权作品的人物不会得到此 DTO，避免据此枚举其它资料库的元数据。
public struct ServerPersonDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let biography: String?
    public let birthday: String?
    public let deathday: String?
    public let placeOfBirth: String?
    public let department: String?
    public let credits: ServerPeopleCreditsPage

    public init(
        id: String, name: String, biography: String?, birthday: String?, deathday: String?,
        placeOfBirth: String?, department: String?, credits: ServerPeopleCreditsPage
    ) {
        self.id = id
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.placeOfBirth = placeOfBirth
        self.department = department
        self.credits = credits
    }
}

public struct ServerPeopleCreditsPage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerPersonCredit]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerPersonCredit]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.hasMore = self.offset + items.count < self.totalItemCount
        self.items = items
    }
}

/// 服务器手动合集的目录卡。计数已经按当前账号的资料库授权过滤，不能用于推断
/// 合集中其它不可见项目的数量。
public struct ServerCollectionCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let mediaCount: Int

    public init(id: String, name: String, mediaCount: Int) {
        self.id = id
        self.name = name
        self.mediaCount = max(mediaCount, 0)
    }
}

public struct ServerCollectionsPage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerCollectionCard]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerCollectionCard]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.hasMore = self.offset + items.count < self.totalItemCount
        self.items = items
    }
}

/// 合集内项目的只读网页卡。它不暴露本机路径、媒体源、桌面端状态或其它用户数据。
public struct ServerCollectionMedia: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let title: String
    public let year: Int?
    public let artworkAvailable: Bool
    public let isSeries: Bool

    public init(id: String, type: String, title: String, year: Int?, artworkAvailable: Bool, isSeries: Bool) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.artworkAvailable = artworkAvailable
        self.isSeries = isSeries
    }
}

public struct ServerCollectionItemsPage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerCollectionMedia]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerCollectionMedia]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.hasMore = self.offset + items.count < self.totalItemCount
        self.items = items
    }
}

public struct ServerCollectionDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let items: ServerCollectionItemsPage

    public init(id: String, name: String, items: ServerCollectionItemsPage) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public enum ServerLibrarySort: String, Codable, CaseIterable, Equatable, Sendable {
    case updatedDescending
    case titleAscending
    case yearDescending
    case lastPlayedDescending
}

/// 资料库查询允许的当前用户播放状态筛选。该值只能由服务端 SQL 映射，
/// 不能表达任意列名、其他用户或桌面端全局播放痕迹。
public enum ServerLibraryPlaybackFilter: String, Codable, CaseIterable, Equatable, Sendable {
    case inProgress
    case watched
    case unwatched
    case history
}

/// 当前用户自己的媒体清单筛选。查询方只能选择固定语义，不能指定偏好表字段。
public enum ServerLibraryPreferenceFilter: String, Codable, CaseIterable, Equatable, Sendable {
    case favorite
    case watchlist
    case rated
}

/// 已通过服务端边界校验的资料库分页查询。路由限制查询长度、分类白名单及页大小，
/// 客户端不能用它表达数据库字段名或任意排序语句。
public struct ServerLibraryQuery: Equatable, Sendable {
    public let searchText: String?
    public let type: String?
    public let offset: Int
    public let limit: Int
    public let sort: ServerLibrarySort
    public let playbackFilter: ServerLibraryPlaybackFilter?
    public let preferenceFilter: ServerLibraryPreferenceFilter?

    public init(
        searchText: String? = nil,
        type: String? = nil,
        offset: Int = 0,
        limit: Int = 48,
        sort: ServerLibrarySort = .updatedDescending,
        playbackFilter: ServerLibraryPlaybackFilter? = nil,
        preferenceFilter: ServerLibraryPreferenceFilter? = nil
    ) {
        self.searchText = searchText
        self.type = type
        self.offset = offset
        self.limit = limit
        self.sort = sort
        self.playbackFilter = playbackFilter
        self.preferenceFilter = preferenceFilter
    }
}

public struct ServerLibraryItemsPage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerLibraryItem]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerLibraryItem]) {
        let total = max(totalItemCount, 0)
        let safeOffset = max(offset, 0)
        let safeLimit = max(limit, 1)
        self.totalItemCount = total
        self.offset = safeOffset
        self.limit = safeLimit
        self.hasMore = safeOffset + items.count < total
        self.items = items
    }
}

public struct ServerLibraryCategory: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let itemCount: Int

    public init(id: String, title: String, itemCount: Int) {
        self.id = id
        self.title = title
        self.itemCount = max(itemCount, 0)
    }
}

public struct ServerLibraryCategoriesResponse: Codable, Equatable, Sendable {
    public let categories: [ServerLibraryCategory]

    public init(categories: [ServerLibraryCategory]) {
        self.categories = categories
    }
}

public struct ServerLibraryItemsResponse: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let items: [ServerLibraryItem]

    public init(totalItemCount: Int, items: [ServerLibraryItem]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.items = items
    }
}

/// 相邻剧集的最小导航 DTO。只允许服务端从已经授权的剧集顺序派生，不能携带
/// 路径、来源、文件名或任意集合查询条件。
public struct ServerEpisodeNavigation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Web/Mlink 媒体详情所需的安全字段。`userState` 只来自服务端逐用户状态表，
/// 不读取桌面端全局播放痕迹；本地文件/封面路径、来源路径和外部提供商标识永不传输。
public struct ServerMediaItemDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let title: String
    public let originalTitle: String?
    public let year: Int?
    public let overview: String?
    public let genres: [String]
    public let communityRating: Double?
    public let runtimeSeconds: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let resolution: String?
    public let artworkAvailable: Bool
    public let backdropAvailable: Bool
    /// Browser-facing MIME hint used only to explain native decoder support.
    /// It is never a path, URL, token, or authorization decision.
    public let browserContentType: String?
    public let canDirectPlay: Bool
    public let canTranscode: Bool
    /// 当前 principal 是否可将该条目作为附件下载；下载能力与播放能力严格分离。
    public let canDownload: Bool
    public let previousEpisode: ServerEpisodeNavigation?
    public let nextEpisode: ServerEpisodeNavigation?
    public let userState: ServerMediaUserState?
    public let userPreference: ServerMediaUserPreference

    public init(
        id: String,
        type: String,
        title: String,
        originalTitle: String?,
        year: Int?,
        overview: String?,
        genres: [String],
        communityRating: Double?,
        runtimeSeconds: Double?,
        videoCodec: String?,
        audioCodec: String?,
        resolution: String?,
        artworkAvailable: Bool,
        backdropAvailable: Bool,
        browserContentType: String? = nil,
        canDirectPlay: Bool,
        canTranscode: Bool,
        canDownload: Bool = false,
        previousEpisode: ServerEpisodeNavigation? = nil,
        nextEpisode: ServerEpisodeNavigation? = nil,
        userState: ServerMediaUserState? = nil,
        userPreference: ServerMediaUserPreference = .empty
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.overview = overview
        self.genres = genres
        self.communityRating = communityRating.flatMap { $0.isFinite ? min(max($0, 0), 10) : nil }
        self.runtimeSeconds = runtimeSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.resolution = resolution
        self.artworkAvailable = artworkAvailable
        self.backdropAvailable = backdropAvailable
        self.browserContentType = browserContentType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.canDirectPlay = canDirectPlay
        self.canTranscode = canTranscode
        self.canDownload = canDownload
        self.previousEpisode = previousEpisode
        self.nextEpisode = nextEpisode
        self.userState = userState
        self.userPreference = userPreference
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, originalTitle, year, overview, genres, communityRating, runtimeSeconds
        case videoCodec, audioCodec, resolution, artworkAvailable, backdropAvailable, browserContentType, canDirectPlay
        case canTranscode, canDownload, previousEpisode, nextEpisode, userState, userPreference
    }

    /// 与资料库卡片相同，旧服务端未包含该字段时使用空偏好，保证渐进升级。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            type: try values.decode(String.self, forKey: .type),
            title: try values.decode(String.self, forKey: .title),
            originalTitle: try values.decodeIfPresent(String.self, forKey: .originalTitle),
            year: try values.decodeIfPresent(Int.self, forKey: .year),
            overview: try values.decodeIfPresent(String.self, forKey: .overview),
            genres: try values.decode([String].self, forKey: .genres),
            communityRating: try values.decodeIfPresent(Double.self, forKey: .communityRating),
            runtimeSeconds: try values.decodeIfPresent(Double.self, forKey: .runtimeSeconds),
            videoCodec: try values.decodeIfPresent(String.self, forKey: .videoCodec),
            audioCodec: try values.decodeIfPresent(String.self, forKey: .audioCodec),
            resolution: try values.decodeIfPresent(String.self, forKey: .resolution),
            artworkAvailable: try values.decode(Bool.self, forKey: .artworkAvailable),
            backdropAvailable: try values.decode(Bool.self, forKey: .backdropAvailable),
            browserContentType: try values.decodeIfPresent(String.self, forKey: .browserContentType),
            canDirectPlay: try values.decode(Bool.self, forKey: .canDirectPlay),
            canTranscode: try values.decode(Bool.self, forKey: .canTranscode),
            canDownload: try values.decodeIfPresent(Bool.self, forKey: .canDownload) ?? false,
            previousEpisode: try values.decodeIfPresent(ServerEpisodeNavigation.self, forKey: .previousEpisode),
            nextEpisode: try values.decodeIfPresent(ServerEpisodeNavigation.self, forKey: .nextEpisode),
            userState: try values.decodeIfPresent(ServerMediaUserState.self, forKey: .userState),
            userPreference: try values.decodeIfPresent(ServerMediaUserPreference.self, forKey: .userPreference) ?? .empty
        )
    }
}

/// 当前已认证用户对单个媒体的服务端状态。该 DTO 不包含 userID、deviceID 或 sessionID，
/// 客户端无法指定或读取其他用户的状态主键。
public struct ServerMediaUserState: Codable, Equatable, Sendable {
    public let itemID: String
    public let positionSeconds: Double
    public let progress: Double
    public let isWatched: Bool
    public let playCount: Int
    public let lastPlayedAt: Date?
    public let updatedAt: Date

    public init(
        itemID: String,
        positionSeconds: Double,
        progress: Double,
        isWatched: Bool,
        playCount: Int,
        lastPlayedAt: Date?,
        updatedAt: Date
    ) {
        self.itemID = itemID
        self.positionSeconds = positionSeconds.isFinite ? max(positionSeconds, 0) : 0
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        self.isWatched = isWatched
        self.playCount = max(playCount, 0)
        self.lastPlayedAt = lastPlayedAt
        self.updatedAt = updatedAt
    }
}

public struct ServerQueueItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let title: String
    public let year: Int?
    public let artworkAvailable: Bool
    public let isSeries: Bool

    public init(id: String, type: String, title: String, year: Int?, artworkAvailable: Bool, isSeries: Bool) {
        self.id = id; self.type = type; self.title = title; self.year = year
        self.artworkAvailable = artworkAvailable; self.isSeries = isSeries
    }
}

public struct ServerQueueResponse: Codable, Equatable, Sendable {
    public let repeatMode: String
    public let shuffleEnabled: Bool
    public let currentPosition: Int
    public let items: [ServerQueueItem]

    public init(repeatMode: String, shuffleEnabled: Bool, currentPosition: Int, items: [ServerQueueItem]) {
        self.repeatMode = repeatMode; self.shuffleEnabled = shuffleEnabled
        self.currentPosition = max(currentPosition, 0); self.items = items
    }
}

/// 队列写入只接受固定动作与有界索引；用户和媒体源授权来自认证/目录层。
public struct ServerQueueMutationRequest: Codable, Equatable, Sendable {
    public let action: String
    public let mediaID: String?
    public let fromIndex: Int?
    public let toIndex: Int?
    public let repeatMode: String?
    public let shuffleEnabled: Bool?
    public let currentPosition: Int?

    public init(action: String, mediaID: String? = nil, fromIndex: Int? = nil, toIndex: Int? = nil, repeatMode: String? = nil, shuffleEnabled: Bool? = nil, currentPosition: Int? = nil) {
        self.action = action; self.mediaID = mediaID; self.fromIndex = fromIndex; self.toIndex = toIndex
        self.repeatMode = repeatMode; self.shuffleEnabled = shuffleEnabled; self.currentPosition = currentPosition
    }

    public var isValid: Bool {
        ["add", "remove", "clear", "move", "settings"].contains(action) &&
        (mediaID == nil || (mediaID!.utf8.count <= 512 && !mediaID!.contains("/") && !mediaID!.contains("\\") && !mediaID!.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }))) &&
        [fromIndex, toIndex, currentPosition].compactMap { $0 }.allSatisfy { (0...100).contains($0) } &&
        (repeatMode == nil || ["sequential", "repeatOne", "repeatAll"].contains(repeatMode!))
    }
}

/// 当前认证用户对媒体的收藏、想看和评分。该 DTO 永不包含 userID、路径、
/// 桌面端全局偏好或其他用户状态；没有偏好记录时显式使用安全默认值。
public struct ServerMediaUserPreference: Codable, Equatable, Sendable {
    public let isFavorite: Bool
    public let isWatchlist: Bool
    public let rating: Double?

    public static let empty = ServerMediaUserPreference(isFavorite: false, isWatchlist: false, rating: nil)

    public init(isFavorite: Bool, isWatchlist: Bool, rating: Double?) {
        self.isFavorite = isFavorite
        self.isWatchlist = isWatchlist
        self.rating = rating.flatMap { $0.isFinite && $0 > 0 && $0 <= 5 ? $0 : nil }
    }
}

public enum ServerPlaybackStateEvent: String, Codable, Equatable, Sendable {
    case started
    case progress
    case stopped
    case completed
    case reset
}

/// 播放器上报的严格小请求；用户身份只取认证 principal，正文不能携带 userID。
public struct ServerPlaybackStateUpdateRequest: Codable, Equatable, Sendable {
    public let event: ServerPlaybackStateEvent
    public let positionSeconds: Double
    public let durationSeconds: Double?

    public init(event: ServerPlaybackStateEvent, positionSeconds: Double, durationSeconds: Double?) {
        self.event = event
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }

    public var isValid: Bool {
        positionSeconds.isFinite && positionSeconds >= 0 && positionSeconds <= 31_536_000 &&
            (durationSeconds == nil || (
                durationSeconds!.isFinite && durationSeconds! > 0 && durationSeconds! <= 31_536_000
            )) &&
            (durationSeconds == nil || positionSeconds <= durationSeconds! + 300)
    }
}

/// 服务端从 ffprobe 归一化出的媒体信息。它是播放决策的输入契约，而不是数据库实体；
/// 不包含文件路径、来源路径、token、用户状态或 FFmpeg 原始诊断。
public struct ServerMediaPlaybackInfo: Codable, Equatable, Sendable {
    public let itemID: String
    public let durationSeconds: Double?
    public let container: String?
    public let bitrate: Int?
    public let streams: [ServerMediaStreamInfo]

    public init(
        itemID: String,
        durationSeconds: Double?,
        container: String?,
        bitrate: Int?,
        streams: [ServerMediaStreamInfo]
    ) {
        self.itemID = itemID
        self.durationSeconds = durationSeconds.map { max($0, 0) }
        self.container = container?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.bitrate = bitrate.map { max($0, 0) }
        self.streams = streams
    }
}

/// 一个视频、音频或字幕流的播放协商信息。未知 ffprobe 字段保持为 `nil`，
/// 客户端不得把缺失字段误判为兼容。
public struct ServerMediaStreamInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let type: String
    public let codec: String?
    public let profile: String?
    public let language: String?
    public let width: Int?
    public let height: Int?
    public let channels: Int?

    public init(
        id: Int,
        type: String,
        codec: String?,
        profile: String?,
        language: String?,
        width: Int?,
        height: Int?,
        channels: Int?
    ) {
        self.id = id
        self.type = type
        self.codec = codec?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.language = language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.width = width.flatMap { $0 > 0 ? $0 : nil }
        self.height = height.flatMap { $0 > 0 ? $0 : nil }
        self.channels = channels.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// 远程管理用户清单中的最小安全视图。它刻意不包含凭据、登录失败详情、
/// token/摘要、客户端地址或任何本地媒体路径。
public struct ServerManagedUserSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let displayName: String
    public let isBuiltInAdministrator: Bool
    public let isDisabled: Bool
    public let requiresInitialPassword: Bool
    public let roleIDs: [String]
    /// 仅返回资料库不透明 ID，不返回路径、来源配置或逐库连接信息。
    public let libraryIDs: [String]
    public let libraryGrantCount: Int
    public let activeDeviceCount: Int
    public let activeSessionCount: Int

    public init(
        id: String,
        username: String,
        displayName: String,
        isBuiltInAdministrator: Bool,
        isDisabled: Bool,
        requiresInitialPassword: Bool,
        roleIDs: [String],
        libraryIDs: [String] = [],
        libraryGrantCount: Int,
        activeDeviceCount: Int,
        activeSessionCount: Int
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.isBuiltInAdministrator = isBuiltInAdministrator
        self.isDisabled = isDisabled
        self.requiresInitialPassword = requiresInitialPassword
        self.roleIDs = roleIDs.sorted()
        self.libraryIDs = Array(Set(libraryIDs)).sorted()
        self.libraryGrantCount = max(libraryGrantCount, 0)
        self.activeDeviceCount = max(activeDeviceCount, 0)
        self.activeSessionCount = max(activeSessionCount, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case id, username, displayName, isBuiltInAdministrator, isDisabled
        case requiresInitialPassword, roleIDs, libraryIDs, libraryGrantCount
        case activeDeviceCount, activeSessionCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            username: try values.decode(String.self, forKey: .username),
            displayName: try values.decode(String.self, forKey: .displayName),
            isBuiltInAdministrator: try values.decode(Bool.self, forKey: .isBuiltInAdministrator),
            isDisabled: try values.decode(Bool.self, forKey: .isDisabled),
            requiresInitialPassword: try values.decode(Bool.self, forKey: .requiresInitialPassword),
            roleIDs: try values.decodeIfPresent([String].self, forKey: .roleIDs) ?? [],
            libraryIDs: try values.decodeIfPresent([String].self, forKey: .libraryIDs) ?? [],
            libraryGrantCount: try values.decodeIfPresent(Int.self, forKey: .libraryGrantCount) ?? 0,
            activeDeviceCount: try values.decodeIfPresent(Int.self, forKey: .activeDeviceCount) ?? 0,
            activeSessionCount: try values.decodeIfPresent(Int.self, forKey: .activeSessionCount) ?? 0
        )
    }
}

public struct ServerManagedUsersResponse: Codable, Equatable, Sendable {
    public let totalCount: Int
    public let isTruncated: Bool
    public let users: [ServerManagedUserSummary]

    public init(totalCount: Int, isTruncated: Bool, users: [ServerManagedUserSummary]) {
        self.totalCount = max(totalCount, 0)
        self.isTruncated = isTruncated
        self.users = users
    }
}

/// Web 服务管理中媒体源的最小安全视图。它不包含本地路径、远程地址、账号、密码、
/// token、Cookie 或任何可用于重新连接来源的配置。
public struct ServerManagedSourceSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let mediaType: String
    public let sourceKind: String
    public let autoScan: Bool
    public let includeInMetadataFetch: Bool
    public let includeInHealthCheck: Bool
    public let updatedAt: Date

    public init(
        id: String,
        name: String,
        mediaType: String,
        sourceKind: String,
        autoScan: Bool,
        includeInMetadataFetch: Bool,
        includeInHealthCheck: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.sourceKind = sourceKind
        self.autoScan = autoScan
        self.includeInMetadataFetch = includeInMetadataFetch
        self.includeInHealthCheck = includeInHealthCheck
        self.updatedAt = updatedAt
    }
}

public struct ServerManagedSourcesResponse: Codable, Equatable, Sendable {
    public let totalCount: Int
    public let isTruncated: Bool
    public let sources: [ServerManagedSourceSummary]

    public init(totalCount: Int, isTruncated: Bool, sources: [ServerManagedSourceSummary]) {
        self.totalCount = max(totalCount, 0)
        self.isTruncated = isTruncated
        self.sources = sources
    }
}

/// Web 成员创建时可选择的最小资料库视图。它刻意不包含来源路径、URL、连接设置或
/// 任何磁盘可达性信息；保险库来源绝不出现在此契约中。
public struct ServerManagedLibrarySummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let mediaType: String

    public init(id: String, name: String, mediaType: String) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
    }
}

public struct ServerManagedLibrariesResponse: Codable, Equatable, Sendable {
    public let totalCount: Int
    public let isTruncated: Bool
    public let libraries: [ServerManagedLibrarySummary]

    public init(totalCount: Int, isTruncated: Bool, libraries: [ServerManagedLibrarySummary]) {
        self.totalCount = max(totalCount, 0)
        self.isTruncated = isTruncated
        self.libraries = libraries
    }
}

/// 活动设备视图不包含 IP、User-Agent、Cookie 或令牌信息。
public struct ServerManagedDeviceSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let userID: String
    public let name: String
    public let platform: String
    public let createdAt: Date
    public let lastSeenAt: Date

    public init(
        id: String,
        userID: String,
        name: String,
        platform: String,
        createdAt: Date,
        lastSeenAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

/// 活动会话视图只暴露撤销操作未来所需的随机标识和期限；不包含原始令牌或摘要。
public struct ServerManagedSessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let userID: String
    public let deviceID: String
    public let accessExpiresAt: Date
    public let refreshExpiresAt: Date
    public let createdAt: Date
    public let lastUsedAt: Date

    public init(
        id: String,
        userID: String,
        deviceID: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date,
        createdAt: Date,
        lastUsedAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.deviceID = deviceID
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct ServerManagedSessionsResponse: Codable, Equatable, Sendable {
    public let isTruncated: Bool
    public let devices: [ServerManagedDeviceSummary]
    public let sessions: [ServerManagedSessionSummary]

    public init(
        isTruncated: Bool,
        devices: [ServerManagedDeviceSummary],
        sessions: [ServerManagedSessionSummary]
    ) {
        self.isTruncated = isTruncated
        self.devices = devices
        self.sessions = sessions
    }
}

/// 管理 Web/API 使用的结构化安全事件。字段集合与持久化审计的脱敏边界一致。
public struct ServerSecurityEventSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let occurredAt: Date
    public let category: String
    public let action: String
    public let outcome: String
    public let actorUserID: String?
    public let targetUserID: String?
    public let sessionID: String?
    public let deviceID: String?
    public let detailCode: String?

    public init(
        id: String,
        occurredAt: Date,
        category: String,
        action: String,
        outcome: String,
        actorUserID: String?,
        targetUserID: String?,
        sessionID: String?,
        deviceID: String?,
        detailCode: String?
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.category = category
        self.action = action
        self.outcome = outcome
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.detailCode = detailCode
    }
}

public struct ServerSecurityEventsResponse: Codable, Equatable, Sendable {
    public let isTruncated: Bool
    public let events: [ServerSecurityEventSummary]

    public init(isTruncated: Bool, events: [ServerSecurityEventSummary]) {
        self.isTruncated = isTruncated
        self.events = events
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
