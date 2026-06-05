import Foundation

public enum VideoSmartCollectionMediaScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case movies
    case tvShows
    case anime
    case documentaries
    case variety
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "全部"
        case .movies: return "电影"
        case .tvShows: return "电视剧"
        case .anime: return "动漫"
        case .documentaries: return "纪录片"
        case .variety: return "综艺"
        case .other: return "其他"
        }
    }

    public func includes(_ type: MediaType) -> Bool {
        switch self {
        case .all: return type != .music && type != .privateCollection && type != .episode
        case .movies: return type == .movie
        case .tvShows: return type == .tvShow
        case .anime: return type == .anime
        case .documentaries: return type == .documentary
        case .variety: return type == .variety
        case .other: return type == .other
        }
    }
}

public enum VideoSmartCollectionStateFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case watchlist
    case favorites
    case watching
    case unwatched
    case watched

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: return "不限"
        case .watchlist: return "想看"
        case .favorites: return "喜欢"
        case .watching: return "正在观看"
        case .unwatched: return "未观看"
        case .watched: return "已观看"
        }
    }
}

public enum VideoSmartCollectionRecency: Int, Codable, CaseIterable, Identifiable, Sendable {
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

public struct VideoSmartCollection: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mediaScope: VideoSmartCollectionMediaScope
    public var stateFilter: VideoSmartCollectionStateFilter
    public var recency: VideoSmartCollectionRecency
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        mediaScope: VideoSmartCollectionMediaScope = .all,
        stateFilter: VideoSmartCollectionStateFilter = .any,
        recency: VideoSmartCollectionRecency = .anytime,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = trimmedName.isEmpty ? "智能集合" : trimmedName
        self.mediaScope = mediaScope
        self.stateFilter = stateFilter
        self.recency = recency
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
