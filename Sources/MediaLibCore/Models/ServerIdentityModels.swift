import Foundation

public enum ServerPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case manageServer = "server.manage"
    case manageUsers = "users.manage"
    case manageLibraries = "libraries.manage"
    case manageSessions = "sessions.manage"
    case viewMedia = "media.view"
    case playMedia = "media.play"
    case downloadMedia = "media.download"
    case editMetadata = "metadata.edit"
    case deleteItems = "items.delete"
    case transcodePlayback = "playback.transcode"
}

public struct ServerUser: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var username: String
    public var displayName: String
    public var isDisabled: Bool
    public var requiresInitialPassword: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        username: String,
        displayName: String,
        isDisabled: Bool = false,
        requiresInitialPassword: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.isDisabled = isDisabled
        self.requiresInitialPassword = requiresInitialPassword
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ServerRole: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isSystem: Bool
    public var permissions: Set<ServerPermission>
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        isSystem: Bool,
        permissions: Set<ServerPermission>,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.isSystem = isSystem
        self.permissions = permissions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ServerLibraryGrant: Identifiable, Codable, Hashable, Sendable {
    public var userID: String
    public var libraryID: String
    public var canView: Bool
    public var canPlay: Bool
    public var canDownload: Bool
    public var canEditMetadata: Bool
    public var canDeleteItems: Bool
    public var updatedAt: Date

    public var id: String { "\(userID):\(libraryID)" }

    public init(
        userID: String,
        libraryID: String,
        canView: Bool,
        canPlay: Bool,
        canDownload: Bool,
        canEditMetadata: Bool = false,
        canDeleteItems: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.userID = userID
        self.libraryID = libraryID
        self.canView = canView
        self.canPlay = canPlay
        self.canDownload = canDownload
        self.canEditMetadata = canEditMetadata
        self.canDeleteItems = canDeleteItems
        self.updatedAt = updatedAt
    }
}

public struct ServerDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var userID: String
    public var name: String
    public var platform: String
    public var createdAt: Date
    public var lastSeenAt: Date
    public var revokedAt: Date?

    public init(
        id: String = UUID().uuidString,
        userID: String,
        name: String,
        platform: String,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}

/// 不包含访问令牌、刷新令牌或其摘要；摘要只在仓储查询边界内短暂使用。
public struct ServerAuthSession: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var userID: String
    public var deviceID: String
    public var accessExpiresAt: Date
    public var refreshExpiresAt: Date
    public var createdAt: Date
    public var lastUsedAt: Date
    public var revokedAt: Date?

    public init(
        id: String = UUID().uuidString,
        userID: String,
        deviceID: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.deviceID = deviceID
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
    }
}

public enum ServerSecurityEventCategory: String, Codable, CaseIterable, Sendable {
    case authentication
    case identity
    case authorization
    case session
}

public enum ServerSecurityEventOutcome: String, Codable, CaseIterable, Sendable {
    case success
    case failure
    case denied
}

/// 仅保存安全操作的结构化结果。此模型刻意不提供密码、令牌、请求头、IP、
/// User-Agent、本地路径或媒体标题字段，避免审计日志成为新的敏感数据源。
public struct ServerSecurityEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var occurredAt: Date
    public var category: ServerSecurityEventCategory
    public var action: String
    public var outcome: ServerSecurityEventOutcome
    public var actorUserID: String?
    public var targetUserID: String?
    public var sessionID: String?
    public var deviceID: String?
    public var detailCode: String?

    public init(
        id: String = UUID().uuidString,
        occurredAt: Date = Date(),
        category: ServerSecurityEventCategory,
        action: String,
        outcome: ServerSecurityEventOutcome,
        actorUserID: String? = nil,
        targetUserID: String? = nil,
        sessionID: String? = nil,
        deviceID: String? = nil,
        detailCode: String? = nil
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
