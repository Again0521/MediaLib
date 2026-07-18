import Foundation

public enum RemoteConnectorProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case emby
    case jellyfin
    case plex
    /// MediaLIB 自有服务端协议。它与第三方媒体服务器的兼容层分离，避免凭据和 API 语义串用。
    case mlink
    case trakt
    case iCloud

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .mlink: return "MediaLIB Server"
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

extension RemoteConnectorAccount {
    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case accountLabel
        case serverURL
        case username
        case sourceID
        case connectionMode
        case syncEnabled
        case capabilitiesJSON
        case privacyNote
        case createdAt
        case updatedAt
        case lastSyncedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = Self.decodeStringBackedEnum(
            RemoteConnectorProvider.self,
            forKey: .provider,
            in: container,
            defaultValue: .emby
        )

        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            provider: provider,
            accountLabel: try container.decodeIfPresent(String.self, forKey: .accountLabel) ?? provider.displayName,
            serverURL: try container.decodeIfPresent(String.self, forKey: .serverURL),
            username: try container.decodeIfPresent(String.self, forKey: .username),
            sourceID: try container.decodeIfPresent(String.self, forKey: .sourceID),
            connectionMode: Self.decodeStringBackedEnum(
                RemoteConnectorMode.self,
                forKey: .connectionMode,
                in: container,
                defaultValue: .library
            ),
            syncEnabled: try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false,
            capabilitiesJSON: try container.decodeIfPresent(String.self, forKey: .capabilitiesJSON),
            privacyNote: try container.decodeIfPresent(String.self, forKey: .privacyNote),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            lastSyncedAt: try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        )
    }

    private static func decodeStringBackedEnum<T: RawRepresentable>(
        _ type: T.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        defaultValue: T
    ) -> T where T.RawValue == String {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key) else {
            return defaultValue
        }
        return T(rawValue: rawValue) ?? defaultValue
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

extension SyncConflict {
    private enum CodingKeys: String, CodingKey {
        case id
        case mediaID
        case profileID
        case provider
        case accountID
        case fieldName
        case localValue
        case remoteValue
        case localUpdatedAt
        case remoteUpdatedAt
        case status
        case resolution
        case errorMessage
        case createdAt
        case updatedAt
        case resolvedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            mediaID: try container.decodeIfPresent(String.self, forKey: .mediaID),
            profileID: try container.decodeIfPresent(String.self, forKey: .profileID),
            provider: Self.decodeStringBackedEnum(
                RemoteConnectorProvider.self,
                forKey: .provider,
                in: container,
                defaultValue: .emby
            ),
            accountID: try container.decodeIfPresent(String.self, forKey: .accountID),
            fieldName: try container.decodeIfPresent(String.self, forKey: .fieldName) ?? "",
            localValue: try container.decodeIfPresent(String.self, forKey: .localValue),
            remoteValue: try container.decodeIfPresent(String.self, forKey: .remoteValue),
            localUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .localUpdatedAt),
            remoteUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .remoteUpdatedAt),
            status: Self.decodeStringBackedEnum(
                SyncConflictStatus.self,
                forKey: .status,
                in: container,
                defaultValue: .pending
            ),
            resolution: Self.decodeOptionalStringBackedEnum(
                SyncConflictResolution.self,
                forKey: .resolution,
                in: container
            ),
            errorMessage: try container.decodeIfPresent(String.self, forKey: .errorMessage),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            resolvedAt: try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        )
    }

    private static func decodeStringBackedEnum<T: RawRepresentable>(
        _ type: T.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        defaultValue: T
    ) -> T where T.RawValue == String {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key) else {
            return defaultValue
        }
        return T(rawValue: rawValue) ?? defaultValue
    }

    private static func decodeOptionalStringBackedEnum<T: RawRepresentable>(
        _ type: T.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> T? where T.RawValue == String {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return T(rawValue: rawValue)
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

    private static func normalizedPosition(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }

    private static func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func normalizedUserRating(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 5 else { return nil }
        return value
    }

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
        self.playPosition = Self.normalizedPosition(playPosition)
        self.playProgress = Self.normalizedProgress(playProgress)
        self.watched = watched
        self.favorite = favorite
        self.watchlist = watchlist
        self.userRating = Self.normalizedUserRating(userRating)
        self.lastPlayedAt = lastPlayedAt
        self.updatedAt = updatedAt
    }
}
