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
    /// 音乐页面所需的公开元数据。它们只来自已授权媒体条目，不包含文件路径。
    public let artist: String?
    public let album: String?
    public let durationSeconds: Double?
    /// 这首曲目有没有歌词（内嵌标签或同目录外挂文件）。只对音乐有意义，其余恒为
    /// false；用于音乐页的「有歌词」筛选，与客户端读的是同一个落库值。
    public let hasLyrics: Bool
    public let artworkAvailable: Bool
    /// 只暴露是否存在已授权横版背景图；真实路径仍由同源图片端点与逐条目授权保护。
    public let backdropAvailable: Bool
    /// 为 true 时该卡片是系列容器，应进入 `/series/{id}` 而不是播放器详情。
    /// 它不包含父级 ID、路径或来源信息。
    public let isSeries: Bool
    /// 仅表示卡片由已连接的远程媒体服务提供；不携带服务地址、媒体路径、
    /// 来源名称或 token。具体是哪一类服务见 `remoteSourceKind`。
    public let isRemoteSource: Bool
    /// 来源角标要显示的服务类型。为 nil 表示本地或网络挂载来源。
    public let remoteSourceKind: ServerRemoteSourceKind?
    public let userState: ServerMediaUserState?
    public let userPreference: ServerMediaUserPreference

    public init(
        id: String,
        type: String,
        title: String,
        year: Int?,
        artist: String? = nil,
        album: String? = nil,
        durationSeconds: Double? = nil,
        hasLyrics: Bool = false,
        artworkAvailable: Bool,
        backdropAvailable: Bool = false,
        isSeries: Bool = false,
        isRemoteSource: Bool = false,
        remoteSourceKind: ServerRemoteSourceKind? = nil,
        userState: ServerMediaUserState? = nil,
        userPreference: ServerMediaUserPreference = .empty
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.hasLyrics = hasLyrics
        self.artworkAvailable = artworkAvailable
        self.backdropAvailable = backdropAvailable
        self.isSeries = isSeries
        self.isRemoteSource = isRemoteSource
        self.remoteSourceKind = remoteSourceKind
        self.userState = userState
        self.userPreference = userPreference
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, year, artist, album, durationSeconds, hasLyrics, artworkAvailable, backdropAvailable, isSeries, isRemoteSource, remoteSourceKind, userState, userPreference
    }

    /// 允许新版客户端连接仍未发送偏好字段的服务端；缺失字段绝不能放大为
    /// 桌面端全局状态，而是收敛为当前用户的空偏好。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.type = try values.decode(String.self, forKey: .type)
        self.title = try values.decode(String.self, forKey: .title)
        self.year = try values.decodeIfPresent(Int.self, forKey: .year)
        self.artist = try values.decodeIfPresent(String.self, forKey: .artist)
        self.album = try values.decodeIfPresent(String.self, forKey: .album)
        self.durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        // 老客户端发来的载荷里没有这个键，缺失即视为"没有歌词"。
        self.hasLyrics = try values.decodeIfPresent(Bool.self, forKey: .hasLyrics) ?? false
        self.artworkAvailable = try values.decode(Bool.self, forKey: .artworkAvailable)
        self.backdropAvailable = try values.decodeIfPresent(Bool.self, forKey: .backdropAvailable) ?? false
        self.isSeries = try values.decodeIfPresent(Bool.self, forKey: .isSeries) ?? false
        self.isRemoteSource = try values.decodeIfPresent(Bool.self, forKey: .isRemoteSource) ?? false
        self.remoteSourceKind = try values.decodeIfPresent(
            ServerRemoteSourceKind.self, forKey: .remoteSourceKind
        )
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

/// 剧集播放页使用的已授权系列上下文。它只给出界面导航所需的系列名、季/集号
/// 和季摘要；剧集本身仍必须通过受限的系列分页 API 取得，不能由页面推测路径或
/// 枚举未授权媒体。
public struct ServerEpisodePlaybackContext: Codable, Equatable, Sendable {
    public let seriesID: String
    public let seriesTitle: String
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let seasons: [ServerSeriesSeason]

    public init(
        seriesID: String,
        seriesTitle: String,
        seasonNumber: Int?,
        episodeNumber: Int?,
        seasons: [ServerSeriesSeason]
    ) {
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.seasons = seasons
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
    public let isRemoteSource: Bool
    public let userState: ServerMediaUserState?

    public init(
        id: String,
        title: String,
        seasonNumber: Int?,
        episodeNumber: Int?,
        runtimeSeconds: Double?,
        artworkAvailable: Bool,
        isRemoteSource: Bool = false,
        userState: ServerMediaUserState? = nil
    ) {
        self.id = id
        self.title = title
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.runtimeSeconds = runtimeSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.artworkAvailable = artworkAvailable
        self.isRemoteSource = isRemoteSource
        self.userState = userState
    }

    private enum CodingKeys: String, CodingKey { case id, title, seasonNumber, episodeNumber, runtimeSeconds, artworkAvailable, isRemoteSource, userState }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.title = try values.decode(String.self, forKey: .title)
        self.seasonNumber = try values.decodeIfPresent(Int.self, forKey: .seasonNumber)
        self.episodeNumber = try values.decodeIfPresent(Int.self, forKey: .episodeNumber)
        self.runtimeSeconds = try values.decodeIfPresent(Double.self, forKey: .runtimeSeconds).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.artworkAvailable = try values.decode(Bool.self, forKey: .artworkAvailable)
        self.isRemoteSource = try values.decodeIfPresent(Bool.self, forKey: .isRemoteSource) ?? false
        self.userState = try values.decodeIfPresent(ServerMediaUserState.self, forKey: .userState)
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
    public let isRemoteSource: Bool
    /// 来源角标要显示的服务类型；为 nil 表示本地或网络挂载来源。
    public let remoteSourceKind: ServerRemoteSourceKind?
    public let category: String
    public let role: String?

    public init(
        id: String, type: String, title: String, year: Int?, artworkAvailable: Bool,
        isSeries: Bool, isRemoteSource: Bool = false,
        remoteSourceKind: ServerRemoteSourceKind? = nil, category: String, role: String?
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.artworkAvailable = artworkAvailable
        self.isSeries = isSeries
        self.isRemoteSource = isRemoteSource
        self.remoteSourceKind = remoteSourceKind
        self.category = category
        self.role = role
    }

    private enum CodingKeys: String, CodingKey { case id, type, title, year, artworkAvailable, isSeries, isRemoteSource, remoteSourceKind, category, role }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.type = try values.decode(String.self, forKey: .type)
        self.title = try values.decode(String.self, forKey: .title)
        self.year = try values.decodeIfPresent(Int.self, forKey: .year)
        self.artworkAvailable = try values.decode(Bool.self, forKey: .artworkAvailable)
        self.isSeries = try values.decode(Bool.self, forKey: .isSeries)
        self.isRemoteSource = try values.decodeIfPresent(Bool.self, forKey: .isRemoteSource) ?? false
        self.remoteSourceKind = try values.decodeIfPresent(
            ServerRemoteSourceKind.self, forKey: .remoteSourceKind
        )
        self.category = try values.decode(String.self, forKey: .category)
        self.role = try values.decodeIfPresent(String.self, forKey: .role)
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
    public let isRemoteSource: Bool

    /// 来源角标要显示的服务类型；为 nil 表示本地或网络挂载来源。
    public let remoteSourceKind: ServerRemoteSourceKind?

    public init(id: String, type: String, title: String, year: Int?, artworkAvailable: Bool, isSeries: Bool, isRemoteSource: Bool = false, remoteSourceKind: ServerRemoteSourceKind? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.artworkAvailable = artworkAvailable
        self.isSeries = isSeries
        self.isRemoteSource = isRemoteSource
        self.remoteSourceKind = remoteSourceKind
    }

    private enum CodingKeys: String, CodingKey { case id, type, title, year, artworkAvailable, isSeries, isRemoteSource, remoteSourceKind }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.type = try values.decode(String.self, forKey: .type)
        self.title = try values.decode(String.self, forKey: .title)
        self.year = try values.decodeIfPresent(Int.self, forKey: .year)
        self.artworkAvailable = try values.decode(Bool.self, forKey: .artworkAvailable)
        self.isSeries = try values.decode(Bool.self, forKey: .isSeries)
        self.isRemoteSource = try values.decodeIfPresent(Bool.self, forKey: .isRemoteSource) ?? false
        self.remoteSourceKind = try values.decodeIfPresent(
            ServerRemoteSourceKind.self, forKey: .remoteSourceKind
        )
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

/// 智能集合的只读卡片。
///
/// 只给名字和数量。`VideoSmartCollectionRules` 里带着用户自己写的题材关键词，
/// `VideoSmartCollectionSourceRule` 更是直接点名媒体源——两者都不能出网页。读者
/// 需要知道的是"这个集合叫什么、里面有多少东西"，规则属于桌面端。
///
/// 数量按**请求者能看到的**条目算，不是集合的真实规模：否则一个数字就能告诉别人
/// 保险库里有几部片子。
public struct ServerSmartCollectionCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let mediaCount: Int

    public init(id: String, name: String, mediaCount: Int) {
        self.id = id
        self.name = name
        self.mediaCount = max(mediaCount, 0)
    }
}

public struct ServerSmartCollectionsPage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerSmartCollectionCard]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerSmartCollectionCard]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.hasMore = self.offset + items.count < self.totalItemCount
        self.items = items
    }
}

public struct ServerSmartCollectionDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// 集合成员就是普通的资料库条目，直接复用既有分页形状。
    public let items: ServerLibraryItemsPage

    public init(id: String, name: String, items: ServerLibraryItemsPage) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// 歌单卡片。手动歌单与智能歌单共用一个类型，靠 `isSmart` 区分。
///
/// 两者在侧栏和页面上是同一种东西——一个有名字、有曲目数、点进去看列表的容器。
/// 拆成两个 DTO 会让每个消费点都长出一条平行分支，而它们唯一的差别只是"曲目从哪
/// 来"，那是服务端的事。
public struct ServerMusicPlaylistCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let isSmart: Bool
    /// 智能歌单的规则摘要（如"最近添加 · 按播放次数"）。它由枚举拼装，不含用户
    /// 自由文本，也不含任何路径或媒体源名，所以可以出网页。手动歌单为 nil。
    public let ruleSummary: String?

    public init(id: String, name: String, trackCount: Int, isSmart: Bool, ruleSummary: String? = nil) {
        self.id = id
        self.name = name
        self.trackCount = max(trackCount, 0)
        self.isSmart = isSmart
        self.ruleSummary = isSmart ? ruleSummary : nil
    }
}

public struct ServerMusicPlaylistsPage: Codable, Equatable, Sendable {
    public let totalItemCount: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let items: [ServerMusicPlaylistCard]

    public init(totalItemCount: Int, offset: Int, limit: Int, items: [ServerMusicPlaylistCard]) {
        self.totalItemCount = max(totalItemCount, 0)
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.hasMore = self.offset + items.count < self.totalItemCount
        self.items = items
    }
}

public struct ServerMusicPlaylistDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isSmart: Bool
    public let items: ServerLibraryItemsPage

    public init(id: String, name: String, isSmart: Bool, items: ServerLibraryItemsPage) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.items = items
    }
}

/// 排序键。与 macOS 客户端 `LibrarySortMode` 同词汇，方向由
/// `ServerLibrarySortOrder` 单独表达——把方向并进键会得到 18 个线上值，
/// 而且"倒序的 runtimeDescending"这种名字会说谎。
///
/// 每个键都只映射到服务端固定的 ORDER BY 片段，网页不能借它表达列名。
public enum ServerLibrarySort: String, Codable, CaseIterable, Equatable, Sendable {
    case recentlyUpdated
    case dateAdded
    case title
    case year
    case runtime
    case progress
    case score
    case rating
    case lastPlayed

    /// 旧的四个值。地址栏里已经写着 `?sort=updatedDescending`，既有 Mlink 客户端
    /// 也仍在发，所以它们永远被接受；但只出现在解析入口，不进 SQL，服务端也不再生成。
    public static func legacy(_ rawValue: String) -> (ServerLibrarySort, ServerLibrarySortOrder)? {
        switch rawValue {
        case "updatedDescending": return (.recentlyUpdated, .primary)
        case "titleAscending": return (.title, .primary)
        case "yearDescending": return (.year, .primary)
        case "lastPlayedDescending": return (.lastPlayed, .primary)
        default: return nil
        }
    }

    /// 需要与当前用户绑定的 `server_user_media_state` 连接。
    public var requiresUserState: Bool { self == .progress || self == .lastPlayed }

    /// 需要与当前用户绑定的 `server_user_media_preferences` 连接。
    /// `media_items.user_rating` 是桌面端全局评级，拿它排序会让一个用户的页面
    /// 按另一个用户的数据排列。
    public var requiresUserPreference: Bool { self == .rating }
}

/// 排序方向。"正序"是**该键的自然方向**（最近更新 = 由新到旧，标题 = A→Z），
/// 自然方向只在服务端的 ORDER BY 映射里定义一次，调用方不需要知道每个键的默认朝向。
public enum ServerLibrarySortOrder: String, Codable, CaseIterable, Equatable, Sendable {
    case primary
    case reverse
}

/// 一个作用域内实际可用的筛选面。
///
/// 排序键按数据存在与否裁剪（客户端同规则：没有任何条目带时长就不提供"时长"），
/// 且"评级"只在**当前用户**评过分时出现——它读的是绑定用户的偏好表。
public struct ServerLibraryFacetsResponse: Codable, Equatable, Sendable {
    public let genres: [String]
    public let availableSorts: [ServerLibrarySort]

    public init(genres: [String], availableSorts: [ServerLibrarySort]) {
        self.genres = genres
        self.availableSorts = availableSorts
    }
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

/// 资料库的受限聚合视图。它不是任意标签表达式；每个值均由服务端映射为
/// 固定的媒体类型集合，避免网页将分类条件变成可注入的数据库查询。
public enum ServerLibraryMediaGroup: String, Codable, CaseIterable, Equatable, Sendable {
    case video
    /// 相册：照片与录像。客户端「相册 · 全部」就是这两类合在一起，网页从前只有
    /// 一个纯照片页，录像得绕到「其他视频」分类里去找。
    case album
}

/// 已通过服务端边界校验的资料库分页查询。路由限制查询长度、分类白名单及页大小，
/// 客户端不能用它表达数据库字段名或任意排序语句。
public struct ServerLibraryQuery: Equatable, Sendable {
    public let searchText: String?
    public let type: String?
    public let offset: Int
    public let limit: Int
    public let sort: ServerLibrarySort
    public let sortOrder: ServerLibrarySortOrder
    public let genre: String?
    public let playbackFilter: ServerLibraryPlaybackFilter?
    public let preferenceFilter: ServerLibraryPreferenceFilter?
    public let mediaGroup: ServerLibraryMediaGroup?
    /// 远程来源作用域的不透明 ID。为 nil 时浏览**只覆盖本地来源**——一级分类与
    /// 客户端一致，不把 Emby/Jellyfin/Plex 内容混进电影、剧集、音乐等目录。
    public let remoteScopeID: String?
    /// 首页看板专用：一次跨越本地与全部已连接远程来源。
    ///
    /// 它**不是**一个查询串参数——`/api/v1/library/browse` 的解析器不认识它，
    /// 浏览器也就无从把一级分类页扩成含远程。只有服务端自己构造首页那两栏
    /// （最近添加、高分精选）时才会打开，与首页快照同口径。
    public let includesRemoteSources: Bool
    /// 保险库作用域。为 true 时这次浏览**只**覆盖保险库来源，而且服务端要求
    /// 两个条件同时成立：机器上的桌面 App 正解锁着，且这个账号被授权了那个
    /// 保险库资料库。任何一条不成立都得到空集合，而不是退回公开来源。
    public let vaultScope: Bool

    public init(
        searchText: String? = nil,
        type: String? = nil,
        offset: Int = 0,
        limit: Int = 48,
        sort: ServerLibrarySort = .recentlyUpdated,
        sortOrder: ServerLibrarySortOrder = .primary,
        genre: String? = nil,
        playbackFilter: ServerLibraryPlaybackFilter? = nil,
        preferenceFilter: ServerLibraryPreferenceFilter? = nil,
        mediaGroup: ServerLibraryMediaGroup? = nil,
        remoteScopeID: String? = nil,
        includesRemoteSources: Bool = false,
        vaultScope: Bool = false
    ) {
        self.searchText = searchText
        self.type = type
        self.offset = offset
        self.limit = limit
        self.sort = sort
        self.sortOrder = sortOrder
        self.genre = genre
        self.playbackFilter = playbackFilter
        self.preferenceFilter = preferenceFilter
        self.mediaGroup = mediaGroup
        self.remoteScopeID = remoteScopeID
        self.includesRemoteSources = includesRemoteSources
        self.vaultScope = vaultScope
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
    /// 「视频」这个保留组里可浏览的条目数。
    ///
    /// 不能用各分类计数之和代替：分类计数是**按类型的全部行数**，而 `/category/video`
    /// 列的是顶层非分集条目，两者在有剧集的库里差着整整一个数量级。侧栏徽标必须
    /// 和点进去看到的条数相等，所以它由服务端用与浏览逐字相同的谓词算出。
    public let videoGroupItemCount: Int

    public init(categories: [ServerLibraryCategory], videoGroupItemCount: Int = 0) {
        self.categories = categories
        self.videoGroupItemCount = max(videoGroupItemCount, 0)
    }
}

/// 首页各推荐栏目的内容，**由客户端排好序**、由服务端按请求者的授权重新查出。
///
/// 每一栏的顺序来自桌面 App 首页（见 `HomeRecommendationSnapshotStore`），条目本身
/// 和其它任何一页一样，是这个账号自己的授权查询结果，并挂着**这个账号自己的**
/// 播放痕迹。名单为空（App 没运行、名单过期、纯服务端部署）时每一栏都是空数组，
/// 首页据此回落到服务端自己的推导。
public struct ServerHomeRecommendations: Codable, Equatable, Sendable {
    /// 客户端算出这份名单的时刻；服务端自己推导时为 nil。
    public let generatedAt: Date?
    public let banner: [ServerLibraryItem]
    public let series: [ServerLibraryItem]
    public let recentSeries: [ServerLibraryItem]
    public let highRated: [ServerLibraryItem]
    public let music: [ServerLibraryItem]
    public let photos: [ServerLibraryItem]

    public init(
        generatedAt: Date? = nil,
        banner: [ServerLibraryItem] = [],
        series: [ServerLibraryItem] = [],
        recentSeries: [ServerLibraryItem] = [],
        highRated: [ServerLibraryItem] = [],
        music: [ServerLibraryItem] = [],
        photos: [ServerLibraryItem] = []
    ) {
        self.generatedAt = generatedAt
        self.banner = banner
        self.series = series
        self.recentSeries = recentSeries
        self.highRated = highRated
        self.music = music
        self.photos = photos
    }

    public static let empty = ServerHomeRecommendations()

    public var isEmpty: Bool {
        banner.isEmpty && series.isEmpty && recentSeries.isEmpty
            && highRated.isEmpty && music.isEmpty && photos.isEmpty
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

/// 客户端已缓存详情的网页安全投影。它刻意不携带海报/人物的外部 URL、提供商 ID、
/// 本机文件路径或任何其它用户状态；网页只能跳转回同源、授权过的人物和媒体页面。
public struct ServerMediaDetailCredit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let role: String
    public let category: String
    /// 头像在 `/api/v1/images/{item}/portrait/{index}` 里的序号。
    /// `nil` 表示这个人没有已缓存的头像，界面用姓名首字母代替——而不是去
    /// 请求一张不存在的图。
    public let portraitIndex: Int?

    public init(id: String, name: String, role: String, category: String, portraitIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.category = category
        self.portraitIndex = portraitIndex
    }
}

public struct ServerMediaDetailRelated: Codable, Equatable, Sendable, Identifiable {
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

/// 一张已缓存的剧照 / 海报。
///
/// 这里**只有序号**，没有上游 URL：网页按 `/api/v1/images/{item}/still/{index}`
/// 取图，由服务端代读。把 TMDB 的原始地址写进 HTML 会让每一个访问者的 IP 直接
/// 暴露给元数据提供方，这是设计文档明令禁止的。
public struct ServerMediaDetailArtwork: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let index: Int
    public let kind: String
    public let aspectRatio: Double

    public init(id: String, index: Int, kind: String, aspectRatio: Double) {
        self.id = id
        self.index = index
        self.kind = kind
        self.aspectRatio = max(aspectRatio, 0.1)
    }
}

/// 详情页底部的外部链接。URL 由服务端构造（搜索链接或已缓存的外部 ID），
/// 不回显任何上游响应。
public struct ServerMediaDetailLink: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let url: String

    public init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public struct ServerMediaDetailExtras: Codable, Equatable, Sendable {
    public let status: String?
    public let contentRating: String?
    public let originalLanguage: String?
    public let countries: [String]
    public let productionCompanies: [String]
    public let networks: [String]
    public let crew: [ServerMediaDetailCredit]
    public let cast: [ServerMediaDetailCredit]
    /// 库中相似作品：推荐里当前账号**确实有权访问**的那些，可以直接打开。
    public let related: [ServerMediaDetailRelated]
    /// 更多推荐：资料库里还没有的作品。它们没有本地 id，因而不可点开播放，
    /// 只作为"这部之后还能看什么"的线索。
    public let discovery: [ServerMediaDetailDiscovery]
    public let artwork: [ServerMediaDetailArtwork]
    public let links: [ServerMediaDetailLink]

    public init(
        status: String? = nil,
        contentRating: String? = nil,
        originalLanguage: String? = nil,
        countries: [String] = [],
        productionCompanies: [String] = [],
        networks: [String] = [],
        crew: [ServerMediaDetailCredit] = [],
        cast: [ServerMediaDetailCredit] = [],
        related: [ServerMediaDetailRelated] = [],
        discovery: [ServerMediaDetailDiscovery] = [],
        artwork: [ServerMediaDetailArtwork] = [],
        links: [ServerMediaDetailLink] = []
    ) {
        self.status = status
        self.contentRating = contentRating
        self.originalLanguage = originalLanguage
        self.countries = countries
        self.productionCompanies = productionCompanies
        self.networks = networks
        self.crew = crew
        self.cast = cast
        self.related = related
        self.discovery = discovery
        self.artwork = artwork
        self.links = links
    }
}

/// 资料库里还没有的推荐条目。同样只带序号，海报走
/// `/api/v1/images/{item}/discovery/{index}` 代理。
public struct ServerMediaDetailDiscovery: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let index: Int
    public let title: String
    public let year: Int?
    public let artworkAvailable: Bool

    public init(id: String, index: Int, title: String, year: Int?, artworkAvailable: Bool) {
        self.id = id
        self.index = index
        self.title = title
        self.year = year
        self.artworkAvailable = artworkAvailable
    }
}

/// 网页播放的有序转换层级。该字段描述服务端能提供的方式，而不是要求浏览器
/// 解码的方式；客户端必须从第一个可用层级开始，且只在更优层级不兼容时降级。
public enum ServerPlaybackMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// 授权 Range 字节流原样送达，由当前设备的原生解码器播放。
    case directPlay
    /// 仅重封装为浏览器可接受的容器，音视频码流保持原样。
    case directStream
    /// 视频码流保持原样，仅把不支持的音频转换为兼容音频。
    case audioTranscode
    /// 最后兜底：服务端重编码视频（以及必要时烧录字幕）。
    case fullTranscode
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
    /// 按成本升序排列的、当前服务端已经实际配置好的播放层级。
    /// `canTranscode` 保留给旧客户端；新客户端必须以此列表协商，不得假定有
    /// ffmpeg 就能安全使用任意转码方式。
    public let playbackModes: [ServerPlaybackMode]
    /// 当前 principal 是否可将该条目作为附件下载；下载能力与播放能力严格分离。
    public let canDownload: Bool
    public let previousEpisode: ServerEpisodeNavigation?
    public let nextEpisode: ServerEpisodeNavigation?
    /// 仅剧集拥有的系列导航数据；其它媒体为 nil。
    public let episodeContext: ServerEpisodePlaybackContext?
    public let detailExtras: ServerMediaDetailExtras?
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
        playbackModes: [ServerPlaybackMode] = [],
        canDownload: Bool = false,
        previousEpisode: ServerEpisodeNavigation? = nil,
        nextEpisode: ServerEpisodeNavigation? = nil,
        episodeContext: ServerEpisodePlaybackContext? = nil,
        detailExtras: ServerMediaDetailExtras? = nil,
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
        let requestedModes = Set(playbackModes)
        self.playbackModes = ServerPlaybackMode.allCases.filter { mode in
            if mode == .directPlay { return canDirectPlay }
            return requestedModes.contains(mode)
        }
        self.canDownload = canDownload
        self.previousEpisode = previousEpisode
        self.nextEpisode = nextEpisode
        self.episodeContext = episodeContext
        self.detailExtras = detailExtras
        self.userState = userState
        self.userPreference = userPreference
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, originalTitle, year, overview, genres, communityRating, runtimeSeconds
        case videoCodec, audioCodec, resolution, artworkAvailable, backdropAvailable, browserContentType, canDirectPlay
        case canTranscode, playbackModes, canDownload, previousEpisode, nextEpisode, episodeContext, detailExtras, userState, userPreference
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
            playbackModes: try values.decodeIfPresent([ServerPlaybackMode].self, forKey: .playbackModes) ?? [],
            canDownload: try values.decodeIfPresent(Bool.self, forKey: .canDownload) ?? false,
            previousEpisode: try values.decodeIfPresent(ServerEpisodeNavigation.self, forKey: .previousEpisode),
            nextEpisode: try values.decodeIfPresent(ServerEpisodeNavigation.self, forKey: .nextEpisode),
            episodeContext: try values.decodeIfPresent(ServerEpisodePlaybackContext.self, forKey: .episodeContext),
            detailExtras: try values.decodeIfPresent(ServerMediaDetailExtras.self, forKey: .detailExtras),
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
    public let isRemoteSource: Bool
    /// 来源角标要显示的服务类型；为 nil 表示本地或网络挂载来源。
    public let remoteSourceKind: ServerRemoteSourceKind?

    public init(id: String, type: String, title: String, year: Int?, artworkAvailable: Bool, isSeries: Bool, isRemoteSource: Bool = false, remoteSourceKind: ServerRemoteSourceKind? = nil) {
        self.id = id; self.type = type; self.title = title; self.year = year
        self.artworkAvailable = artworkAvailable; self.isSeries = isSeries; self.isRemoteSource = isRemoteSource
        self.remoteSourceKind = remoteSourceKind
    }

    private enum CodingKeys: String, CodingKey { case id, type, title, year, artworkAvailable, isSeries, isRemoteSource, remoteSourceKind }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.type = try values.decode(String.self, forKey: .type)
        self.title = try values.decode(String.self, forKey: .title)
        self.year = try values.decodeIfPresent(Int.self, forKey: .year)
        self.artworkAvailable = try values.decode(Bool.self, forKey: .artworkAvailable)
        self.isSeries = try values.decode(Bool.self, forKey: .isSeries)
        self.isRemoteSource = try values.decodeIfPresent(Bool.self, forKey: .isRemoteSource) ?? false
        self.remoteSourceKind = try values.decodeIfPresent(
            ServerRemoteSourceKind.self, forKey: .remoteSourceKind
        )
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
    public let username: String?
    public let displayName: String?

    public init(
        id: String,
        userID: String,
        deviceID: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date,
        createdAt: Date,
        lastUsedAt: Date,
        username: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.deviceID = deviceID
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.username = username
        self.displayName = displayName
    }
}

public struct ServerManagedSessionsResponse: Codable, Equatable, Sendable {
    /// New servers always include the filtered total. Optional keeps a current
    /// client able to decode responses from the previous unpaged endpoint.
    public let totalCount: Int?
    public let isTruncated: Bool
    public let devices: [ServerManagedDeviceSummary]
    public let sessions: [ServerManagedSessionSummary]

    public init(
        totalCount: Int? = nil,
        isTruncated: Bool,
        devices: [ServerManagedDeviceSummary],
        sessions: [ServerManagedSessionSummary]
    ) {
        self.totalCount = totalCount.map { max($0, 0) }
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
    public let totalCount: Int?
    public let isTruncated: Bool
    public let events: [ServerSecurityEventSummary]

    public init(totalCount: Int? = nil, isTruncated: Bool, events: [ServerSecurityEventSummary]) {
        self.totalCount = totalCount
        self.isTruncated = isTruncated
        self.events = events
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
