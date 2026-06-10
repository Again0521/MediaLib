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

public enum VideoSmartCollectionRuleMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case any

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "满足全部"
        case .any: return "满足任一"
        }
    }
}

public enum VideoSmartCollectionYearRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case since2020
    case since2010
    case since2000
    case before2000
    case before1990

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: return "不限"
        case .since2020: return "2020 年以后"
        case .since2010: return "2010 年以后"
        case .since2000: return "2000 年以后"
        case .before2000: return "2000 年以前"
        case .before1990: return "1990 年以前"
        }
    }

    fileprivate func matches(year: Int?) -> Bool {
        guard let year else { return false }
        switch self {
        case .any: return true
        case .since2020: return year >= 2020
        case .since2010: return year >= 2010
        case .since2000: return year >= 2000
        case .before2000: return year < 2000
        case .before1990: return year < 1990
        }
    }
}

public enum VideoSmartCollectionProviderRatingRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case atLeastNine
    case atLeastEight
    case atLeastSeven
    case belowSix
    case unrated

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: return "不限"
        case .atLeastNine: return "9 分以上"
        case .atLeastEight: return "8 分以上"
        case .atLeastSeven: return "7 分以上"
        case .belowSix: return "低于 6 分"
        case .unrated: return "暂无评分"
        }
    }

    fileprivate func matches(rating: Double?) -> Bool {
        switch self {
        case .any:
            return true
        case .atLeastNine:
            return (rating ?? -Double.infinity) >= 9
        case .atLeastEight:
            return (rating ?? -Double.infinity) >= 8
        case .atLeastSeven:
            return (rating ?? -Double.infinity) >= 7
        case .belowSix:
            return (rating ?? Double.infinity) < 6
        case .unrated:
            return rating == nil
        }
    }
}

public enum VideoSmartCollectionUserRatingRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case fiveStars
    case atLeastFour
    case atLeastThree
    case rated
    case unrated

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: return "不限"
        case .fiveStars: return "5 星"
        case .atLeastFour: return "4 星以上"
        case .atLeastThree: return "3 星以上"
        case .rated: return "已评级"
        case .unrated: return "未评级"
        }
    }

    fileprivate func matches(rating: Double?) -> Bool {
        switch self {
        case .any:
            return true
        case .fiveStars:
            return (rating ?? -Double.infinity) >= 5
        case .atLeastFour:
            return (rating ?? -Double.infinity) >= 4
        case .atLeastThree:
            return (rating ?? -Double.infinity) >= 3
        case .rated:
            return rating != nil
        case .unrated:
            return rating == nil
        }
    }
}

public enum VideoSmartCollectionSourceRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case local
    case emby

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: return "不限"
        case .local: return "本地与挂载源"
        case .emby: return "远程媒体库"
        }
    }

    fileprivate func matches(item: MediaItem) -> Bool {
        switch self {
        case .any:
            return true
        case .local:
            return item.type != .privateCollection && !Self.isEmbyItem(item)
        case .emby:
            return Self.isEmbyItem(item)
        }
    }

    private static func isEmbyItem(_ item: MediaItem) -> Bool {
        item.sourcePath?.hasPrefix("emby://") == true ||
            item.sourcePath?.hasPrefix("jellyfin://") == true ||
            item.sourcePath?.hasPrefix("plex://") == true ||
            item.metadataProvider?.localizedCaseInsensitiveContains("emby") == true ||
            item.metadataProvider?.localizedCaseInsensitiveContains("jellyfin") == true ||
            item.metadataProvider?.localizedCaseInsensitiveContains("plex") == true
    }
}

public struct VideoSmartCollectionRules: Codable, Hashable, Sendable {
    public var matchMode: VideoSmartCollectionRuleMatchMode
    public var year: VideoSmartCollectionYearRule
    public var providerRating: VideoSmartCollectionProviderRatingRule
    public var userRating: VideoSmartCollectionUserRatingRule
    public var genreKeyword: String
    public var source: VideoSmartCollectionSourceRule

    public init(
        matchMode: VideoSmartCollectionRuleMatchMode = .all,
        year: VideoSmartCollectionYearRule = .any,
        providerRating: VideoSmartCollectionProviderRatingRule = .any,
        userRating: VideoSmartCollectionUserRatingRule = .any,
        genreKeyword: String = "",
        source: VideoSmartCollectionSourceRule = .any
    ) {
        self.matchMode = matchMode
        self.year = year
        self.providerRating = providerRating
        self.userRating = userRating
        self.genreKeyword = Self.normalizedFreeText(genreKeyword)
        self.source = source
    }

    public var hasExtendedConditions: Bool {
        year != .any ||
            providerRating != .any ||
            userRating != .any ||
            !genreKeyword.isEmpty ||
            source != .any
    }

    private static func normalizedFreeText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case matchMode
        case year
        case providerRating
        case userRating
        case genreKeyword
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            matchMode: try container.decodeIfPresent(VideoSmartCollectionRuleMatchMode.self, forKey: .matchMode) ?? .all,
            year: try container.decodeIfPresent(VideoSmartCollectionYearRule.self, forKey: .year) ?? .any,
            providerRating: try container.decodeIfPresent(VideoSmartCollectionProviderRatingRule.self, forKey: .providerRating) ?? .any,
            userRating: try container.decodeIfPresent(VideoSmartCollectionUserRatingRule.self, forKey: .userRating) ?? .any,
            genreKeyword: try container.decodeIfPresent(String.self, forKey: .genreKeyword) ?? "",
            source: try container.decodeIfPresent(VideoSmartCollectionSourceRule.self, forKey: .source) ?? .any
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(matchMode, forKey: .matchMode)
        try container.encode(year, forKey: .year)
        try container.encode(providerRating, forKey: .providerRating)
        try container.encode(userRating, forKey: .userRating)
        try container.encode(genreKeyword, forKey: .genreKeyword)
        try container.encode(source, forKey: .source)
    }
}

public struct VideoSmartCollection: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mediaScope: VideoSmartCollectionMediaScope
    public var stateFilter: VideoSmartCollectionStateFilter
    public var recency: VideoSmartCollectionRecency
    public var rules: VideoSmartCollectionRules
    public var showOnHome: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        mediaScope: VideoSmartCollectionMediaScope = .all,
        stateFilter: VideoSmartCollectionStateFilter = .any,
        recency: VideoSmartCollectionRecency = .anytime,
        rules: VideoSmartCollectionRules = VideoSmartCollectionRules(),
        showOnHome: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = trimmedName.isEmpty ? "智能集合" : trimmedName
        self.mediaScope = mediaScope
        self.stateFilter = stateFilter
        self.recency = recency
        self.rules = rules
        self.showOnHome = showOnHome
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func matches(_ item: MediaItem, watchedThreshold: Double) -> Bool {
        guard mediaScope.includes(item.type) else { return false }
        var evaluations: [Bool] = []

        if stateFilter != .any {
            evaluations.append(matchesState(item, watchedThreshold: watchedThreshold))
        }
        if recency != .anytime {
            let cutoff = Calendar.current.date(byAdding: .day, value: -recency.rawValue, to: Date()) ?? .distantPast
            evaluations.append(item.createdAt >= cutoff)
        }
        if rules.year != .any {
            evaluations.append(rules.year.matches(year: item.year))
        }
        if rules.providerRating != .any {
            evaluations.append(rules.providerRating.matches(rating: item.rating))
        }
        if rules.userRating != .any {
            evaluations.append(rules.userRating.matches(rating: item.userRating))
        }
        if !rules.genreKeyword.isEmpty {
            evaluations.append(Self.genre(item.genre, matchesKeyword: rules.genreKeyword))
        }
        if rules.source != .any {
            evaluations.append(rules.source.matches(item: item))
        }

        guard !evaluations.isEmpty else { return true }
        switch rules.matchMode {
        case .all:
            return evaluations.allSatisfy { $0 }
        case .any:
            return evaluations.contains(true)
        }
    }

    private func matchesState(_ item: MediaItem, watchedThreshold: Double) -> Bool {
        switch stateFilter {
        case .any:
            return true
        case .watchlist:
            return item.watchlist
        case .favorites:
            return item.favorite
        case .watching:
            return item.hasPlaybackTrace && !(item.watched || item.playProgress >= watchedThreshold)
        case .unwatched:
            return !item.watched && item.playProgress < watchedThreshold
        case .watched:
            return item.watched || item.playProgress >= watchedThreshold
        }
    }

    private static func genre(_ genre: String?, matchesKeyword keyword: String) -> Bool {
        let haystack = normalizedSearchText(genre)
        let tokens = normalizedSearchText(keyword)
            .split { $0 == "," || $0 == "，" || $0.isWhitespace }
            .map(String.init)
        guard !haystack.isEmpty, !tokens.isEmpty else { return false }
        return tokens.contains { haystack.contains($0) }
    }

    private static func normalizedSearchText(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mediaScope
        case stateFilter
        case recency
        case rules
        case showOnHome
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "智能集合",
            mediaScope: try container.decodeIfPresent(VideoSmartCollectionMediaScope.self, forKey: .mediaScope) ?? .all,
            stateFilter: try container.decodeIfPresent(VideoSmartCollectionStateFilter.self, forKey: .stateFilter) ?? .any,
            recency: try container.decodeIfPresent(VideoSmartCollectionRecency.self, forKey: .recency) ?? .anytime,
            rules: try container.decodeIfPresent(VideoSmartCollectionRules.self, forKey: .rules) ?? VideoSmartCollectionRules(),
            showOnHome: try container.decodeIfPresent(Bool.self, forKey: .showOnHome) ?? false,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mediaScope, forKey: .mediaScope)
        try container.encode(stateFilter, forKey: .stateFilter)
        try container.encode(recency, forKey: .recency)
        try container.encode(rules, forKey: .rules)
        try container.encode(showOnHome, forKey: .showOnHome)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
