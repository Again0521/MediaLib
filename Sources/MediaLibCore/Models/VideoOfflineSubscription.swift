import Foundation

public enum VideoOfflineSubscriptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case nextEpisode
    case nextUnwatched
    case season
    case fullSeries

    public var id: String { rawValue }

    public var displayName: String {
        displayName(episodeLimit: 3, seasonNumber: nil)
    }

    public func displayName(episodeLimit: Int, seasonNumber: Int? = nil) -> String {
        switch self {
        case .nextEpisode: return "自动缓存下一集"
        case .nextUnwatched: return "自动缓存未看 \(max(1, episodeLimit)) 集"
        case .season:
            if let seasonNumber, seasonNumber > 0 {
                return "自动缓存第 \(seasonNumber) 季"
            }
            return "自动缓存整季"
        case .fullSeries: return "自动缓存全系列"
        }
    }

    public var systemImage: String {
        switch self {
        case .nextEpisode: return "forward.end.circle"
        case .nextUnwatched: return "tray.and.arrow.down"
        case .season: return "rectangle.stack.badge.plus"
        case .fullSeries: return "square.stack.3d.down.right"
        }
    }
}

public enum VideoOfflineSubscriptionNetworkPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case allowRemote
    case localNetworkOnly
    case wifiOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .allowRemote: return "允许远程网络"
        case .localNetworkOnly: return "仅本机局域网"
        case .wifiOnly: return "仅 Wi-Fi"
        }
    }

    public var compactDisplayName: String {
        switch self {
        case .allowRemote: return "远程可用"
        case .localNetworkOnly: return "仅局域网"
        case .wifiOnly: return "仅 Wi-Fi"
        }
    }
}

public struct VideoOfflineSubscription: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var seriesID: String
    public var seriesTitle: String
    public var mode: VideoOfflineSubscriptionMode
    public var episodeLimit: Int
    public var seasonNumber: Int?
    public var qualityID: String?
    public var enabled: Bool
    public var pausedUntil: Date?
    public var expiresAt: Date?
    public var networkPolicy: VideoOfflineSubscriptionNetworkPolicy
    public var createdAt: Date
    public var updatedAt: Date

    public var displayName: String {
        mode.displayName(episodeLimit: episodeLimit, seasonNumber: seasonNumber)
    }

    public var compactDisplayName: String {
        switch mode {
        case .nextEpisode: return "下一集"
        case .nextUnwatched: return "未看 \(episodeLimit) 集"
        case .season:
            if let seasonNumber, seasonNumber > 0 {
                return "第 \(seasonNumber) 季"
            }
            return "整季"
        case .fullSeries: return "全系列"
        }
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    public var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    public var isRunnable: Bool {
        enabled && !isExpired && !isPaused
    }

    public init(
        id: String = UUID().uuidString,
        seriesID: String,
        seriesTitle: String,
        mode: VideoOfflineSubscriptionMode,
        episodeLimit: Int = 3,
        seasonNumber: Int? = nil,
        qualityID: String? = nil,
        enabled: Bool = true,
        pausedUntil: Date? = nil,
        expiresAt: Date? = nil,
        networkPolicy: VideoOfflineSubscriptionNetworkPolicy = .allowRemote,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名系列" : seriesTitle
        self.mode = mode
        self.episodeLimit = max(1, min(episodeLimit, 99))
        if let seasonNumber, seasonNumber > 0 {
            self.seasonNumber = min(seasonNumber, 999)
        } else {
            self.seasonNumber = nil
        }
        let normalizedQualityID = qualityID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.qualityID = normalizedQualityID?.isEmpty == false ? normalizedQualityID : nil
        self.enabled = enabled
        self.pausedUntil = pausedUntil
        self.expiresAt = expiresAt
        self.networkPolicy = networkPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension VideoOfflineSubscription {
    private enum CodingKeys: String, CodingKey {
        case id
        case seriesID
        case seriesTitle
        case mode
        case episodeLimit
        case seasonNumber
        case qualityID
        case enabled
        case pausedUntil
        case expiresAt
        case networkPolicy
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            seriesID: try container.decodeIfPresent(String.self, forKey: .seriesID) ?? "",
            seriesTitle: try container.decodeIfPresent(String.self, forKey: .seriesTitle) ?? "未命名系列",
            mode: Self.decodeStringBackedEnum(
                VideoOfflineSubscriptionMode.self,
                forKey: .mode,
                in: container,
                defaultValue: .nextEpisode
            ),
            episodeLimit: try container.decodeIfPresent(Int.self, forKey: .episodeLimit) ?? 3,
            seasonNumber: try container.decodeIfPresent(Int.self, forKey: .seasonNumber),
            qualityID: try container.decodeIfPresent(String.self, forKey: .qualityID),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            pausedUntil: try container.decodeIfPresent(Date.self, forKey: .pausedUntil),
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
            networkPolicy: Self.decodeStringBackedEnum(
                VideoOfflineSubscriptionNetworkPolicy.self,
                forKey: .networkPolicy,
                in: container,
                defaultValue: .allowRemote
            ),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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
