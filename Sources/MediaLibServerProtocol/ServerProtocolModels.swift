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
    public let userState: ServerMediaUserState?

    public init(
        id: String,
        type: String,
        title: String,
        year: Int?,
        artworkAvailable: Bool,
        userState: ServerMediaUserState? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.artworkAvailable = artworkAvailable
        self.userState = userState
    }
}

public enum ServerLibrarySort: String, Codable, CaseIterable, Equatable, Sendable {
    case updatedDescending
    case titleAscending
    case yearDescending
}

/// 已通过服务端边界校验的资料库分页查询。路由限制查询长度、分类白名单及页大小，
/// 客户端不能用它表达数据库字段名或任意排序语句。
public struct ServerLibraryQuery: Equatable, Sendable {
    public let searchText: String?
    public let type: String?
    public let offset: Int
    public let limit: Int
    public let sort: ServerLibrarySort

    public init(
        searchText: String? = nil,
        type: String? = nil,
        offset: Int = 0,
        limit: Int = 48,
        sort: ServerLibrarySort = .updatedDescending
    ) {
        self.searchText = searchText
        self.type = type
        self.offset = offset
        self.limit = limit
        self.sort = sort
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
    public let canDirectPlay: Bool
    public let canTranscode: Bool
    public let userState: ServerMediaUserState?

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
        canDirectPlay: Bool,
        canTranscode: Bool,
        userState: ServerMediaUserState? = nil
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
        self.canDirectPlay = canDirectPlay
        self.canTranscode = canTranscode
        self.userState = userState
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

/// 一次 HLS 转码会话的安全描述。`manifestPath` 是服务端 API 路径而不是文件系统路径，
/// 其后续访问仍必须落在同一用户、资料库和会话授权边界内。
public struct ServerHLSPlaybackSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let itemID: String
    public let manifestPath: String

    public init(id: String, itemID: String, manifestPath: String) {
        self.id = id
        self.itemID = itemID
        self.manifestPath = manifestPath
    }
}

/// 远程管理用户清单中的最小安全视图。它刻意不包含凭据、登录失败详情、
/// token/摘要、客户端地址或任何本地媒体路径。
public struct ServerManagedUserSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let displayName: String
    public let isDisabled: Bool
    public let requiresInitialPassword: Bool
    public let roleIDs: [String]
    public let libraryGrantCount: Int
    public let activeDeviceCount: Int
    public let activeSessionCount: Int

    public init(
        id: String,
        username: String,
        displayName: String,
        isDisabled: Bool,
        requiresInitialPassword: Bool,
        roleIDs: [String],
        libraryGrantCount: Int,
        activeDeviceCount: Int,
        activeSessionCount: Int
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.isDisabled = isDisabled
        self.requiresInitialPassword = requiresInitialPassword
        self.roleIDs = roleIDs.sorted()
        self.libraryGrantCount = max(libraryGrantCount, 0)
        self.activeDeviceCount = max(activeDeviceCount, 0)
        self.activeSessionCount = max(activeSessionCount, 0)
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
