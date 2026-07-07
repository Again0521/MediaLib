import Foundation

public enum RemoteConnectorProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case emby
    case jellyfin
    case plex
    case trakt
    case iCloud

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .trakt: return "Trakt"
        case .iCloud: return "iCloud"
        }
    }
}

public enum RemoteConnectorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct
    case library
    case syncOnly

    public var id: String { rawValue }
}

public struct RemoteConnectorAccount: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var provider: RemoteConnectorProvider
    public var accountLabel: String
    public var serverURL: String?
    public var username: String?
    public var sourceID: String?
    public var connectionMode: RemoteConnectorMode
    public var syncEnabled: Bool
    public var capabilitiesJSON: String?
    public var privacyNote: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSyncedAt: Date?

    public init(
        id: String = UUID().uuidString,
        provider: RemoteConnectorProvider,
        accountLabel: String,
        serverURL: String? = nil,
        username: String? = nil,
        sourceID: String? = nil,
        connectionMode: RemoteConnectorMode = .library,
        syncEnabled: Bool = false,
        capabilitiesJSON: String? = nil,
        privacyNote: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.accountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? provider.displayName
            : accountLabel
        self.serverURL = serverURL
        self.username = username
        self.sourceID = sourceID
        self.connectionMode = connectionMode
        self.syncEnabled = syncEnabled
        self.capabilitiesJSON = capabilitiesJSON
        self.privacyNote = privacyNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
    }
}

public enum SyncConflictStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case resolved
    case ignored

    public var id: String { rawValue }
}

public enum SyncConflictResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case useLocal
    case useRemote
    case merge
    case keepBoth

    public var id: String { rawValue }
}

public struct SyncConflict: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var mediaID: String?
    public var profileID: String?
    public var provider: RemoteConnectorProvider
    public var accountID: String?
    public var fieldName: String
    public var localValue: String?
    public var remoteValue: String?
    public var localUpdatedAt: Date?
    public var remoteUpdatedAt: Date?
    public var status: SyncConflictStatus
    public var resolution: SyncConflictResolution?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?

    public init(
        id: String = UUID().uuidString,
        mediaID: String? = nil,
        profileID: String? = nil,
        provider: RemoteConnectorProvider,
        accountID: String? = nil,
        fieldName: String,
        localValue: String? = nil,
        remoteValue: String? = nil,
        localUpdatedAt: Date? = nil,
        remoteUpdatedAt: Date? = nil,
        status: SyncConflictStatus = .pending,
        resolution: SyncConflictResolution? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.mediaID = mediaID
        self.profileID = profileID
        self.provider = provider
        self.accountID = accountID
        self.fieldName = fieldName
        self.localValue = localValue
        self.remoteValue = remoteValue
        self.localUpdatedAt = localUpdatedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.status = status
        self.resolution = resolution
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }
}

public struct LocalUserProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    public var avatarSymbol: String?
    public var restrictsPrivateItems: Bool
    public var childMode: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        isDefault: Bool = false,
        avatarSymbol: String? = "person.circle",
        restrictsPrivateItems: Bool = false,
        childMode: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名档案" : name
        self.isDefault = isDefault
        self.avatarSymbol = avatarSymbol
        self.restrictsPrivateItems = restrictsPrivateItems
        self.childMode = childMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProfileMediaState: Identifiable, Codable, Hashable, Sendable {
    public var profileID: String
    public var mediaID: String
    public var playCount: Int
    public var playPosition: Double
    public var playProgress: Double
    public var watched: Bool
    public var favorite: Bool
    public var watchlist: Bool
    public var userRating: Double?
    public var lastPlayedAt: Date?
    public var updatedAt: Date

    public var id: String { "\(profileID)-\(mediaID)" }

    public init(
        profileID: String,
        mediaID: String,
        playCount: Int = 0,
        playPosition: Double = 0,
        playProgress: Double = 0,
        watched: Bool = false,
        favorite: Bool = false,
        watchlist: Bool = false,
        userRating: Double? = nil,
        lastPlayedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.profileID = profileID
        self.mediaID = mediaID
        self.playCount = max(playCount, 0)
        self.playPosition = max(playPosition, 0)
        self.playProgress = min(max(playProgress, 0), 1)
        self.watched = watched
        self.favorite = favorite
        self.watchlist = watchlist
        self.userRating = userRating
        self.lastPlayedAt = lastPlayedAt
        self.updatedAt = updatedAt
    }
}
