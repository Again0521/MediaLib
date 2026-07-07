import Foundation

public enum MusicSmartPlaylistFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case favorites
    case recentlyPlayed
    case neverPlayed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: return "全部"
        case .favorites: return "喜欢"
        case .recentlyPlayed: return "最近播放"
        case .neverPlayed: return "从未播放"
        }
    }
}

/// 按"加入时间"过滤（createdAt 距今天数）。
public enum MusicSmartPlaylistRecency: Int, Codable, CaseIterable, Identifiable, Sendable {
    case anytime = 0
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .anytime: return "不限"
        case .sevenDays: return "最近 7 天"
        case .thirtyDays: return "最近 30 天"
        case .ninetyDays: return "最近 90 天"
        }
    }
}

public enum MusicSmartPlaylistSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case dateAddedDesc
    case playCountDesc
    case lastPlayedDesc
    case titleAsc
    case artistAsc
    case yearDesc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dateAddedDesc: return "最近加入"
        case .playCountDesc: return "最常播放"
        case .lastPlayedDesc: return "最近播放"
        case .titleAsc: return "歌曲名"
        case .artistAsc: return "艺术家"
        case .yearDesc: return "年份"
        }
    }
}

public enum MusicSmartPlaylistLimit: Int, Codable, CaseIterable, Identifiable, Sendable {
    case unlimited = 0
    case twentyFive = 25
    case fifty = 50
    case hundred = 100
    case twoHundred = 200

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .unlimited: return "不限"
        default: return "前 \(rawValue) 首"
        }
    }
}

/// 音乐智能歌单：只保存筛选 / 排序 / 数量规则，曲目随媒体库状态自动更新（类比视频智能合集）。
public struct MusicSmartPlaylist: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var filter: MusicSmartPlaylistFilter
    public var recency: MusicSmartPlaylistRecency
    public var sort: MusicSmartPlaylistSort
    public var limit: MusicSmartPlaylistLimit
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        filter: MusicSmartPlaylistFilter = .any,
        recency: MusicSmartPlaylistRecency = .anytime,
        sort: MusicSmartPlaylistSort = .dateAddedDesc,
        limit: MusicSmartPlaylistLimit = .unlimited,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = trimmedName.isEmpty ? "智能歌单" : trimmedName
        self.filter = filter
        self.recency = recency
        self.sort = sort
        self.limit = limit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 规则摘要，用于详情副标题。
    public var ruleSummary: String {
        var parts = [filter.displayName]
        if recency != .anytime { parts.append(recency.displayName) }
        parts.append("按\(sort.displayName)")
        if limit != .unlimited { parts.append(limit.displayName) }
        return parts.joined(separator: " · ")
    }
}
