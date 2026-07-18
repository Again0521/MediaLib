import AppKit
import MediaLibCore
import SwiftUI
import UniformTypeIdentifiers

private struct HomeContentSnapshotInput: Sendable {
    let items: [MediaItem]
    let filter: HomeContentFilter
    let searchText: String
    let appliesSearch: Bool
    let limit: Int?
    let watchedThreshold: Double
}

private enum HomeContentFilter: Sendable {
    case none
    case mediaType(MediaType)
    case videoFavorites
    case unwatchedVideos
}

private enum HomeContentSnapshotBuilder {
    static func items(from input: HomeContentSnapshotInput) -> [MediaItem] {
        let trimmedSearch = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = filteredItems(from: input)
        let filtered: [MediaItem]
        if input.appliesSearch, !trimmedSearch.isEmpty {
            filtered = base.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedSearch) ||
                ($0.originalTitle?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) ||
                ($0.artist?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) ||
                ($0.album?.localizedCaseInsensitiveContains(trimmedSearch) ?? false)
            }
        } else {
            filtered = base
        }
        if let limit = input.limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    private static func filteredItems(from input: HomeContentSnapshotInput) -> [MediaItem] {
        switch input.filter {
        case .none:
            return input.items
        case .mediaType(let type):
            return input.items.filter { $0.type == type }
        case .videoFavorites:
            return input.items.filter { $0.type != .music && $0.favorite }
        case .unwatchedVideos:
            return input.items.filter { $0.type != .music && !$0.watched && $0.playProgress < input.watchedThreshold }
        }
    }
}

private struct HomeOverviewBoardModel: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let items: [MediaItem]
    let emptyMessage: String
}

private struct HomeOverviewSnapshotInput: Sendable {
    let daySeed: Int
    let now: Date
    let language: AppLanguage
    let watchedThreshold: Double
    let visibleVideos: [MediaItem]
    let continueWatchingItems: [MediaItem]
    let nextUpItems: [MediaItem]
    let offlineItems: [MediaItem]
    let publishedBoards: [HomeOverviewBoardModel]
    let backdropItemIDs: Set<String>
}

private struct HomePhotoWallTheme {
    let title: String
    let badge: String
    let items: [MediaItem]
}

private struct HomeMusicStyleBucket: Identifiable {
    let id: String
    let key: String
    let title: String
    let tracks: [MediaItem]
    let score: Double
}

private struct HomeRecommendationProfile {
    var genreWeights: [String: Double] = [:]
    var genreDisplayNames: [String: String] = [:]
    var typeWeights: [MediaType: Double] = [:]
    var signalItemIDs: Set<String> = []

    var hasSignals: Bool {
        !genreWeights.isEmpty || !typeWeights.isEmpty
    }

    var strongestGenre: String? {
        genreWeights
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .first?
            .key
    }

    var strongestGenreDisplayName: String? {
        guard let strongestGenre else { return nil }
        return genreDisplayNames[strongestGenre] ?? strongestGenre
    }

    var maxGenreWeight: Double {
        genreWeights.values.max() ?? 0
    }

    var maxTypeWeight: Double {
        typeWeights.values.max() ?? 0
    }
}

private enum HomeOverviewSnapshotBuilder {
    static func makeBoards(from input: HomeOverviewSnapshotInput) -> [HomeOverviewBoardModel] {
        let visibleVideos = input.visibleVideos.filter { $0.type != .music && $0.type != .episode && $0.type != .privateCollection }
        let profile = recommendationProfile(
            visibleVideos: visibleVideos,
            continueWatchingItems: input.continueWatchingItems,
            nextUpItems: input.nextUpItems,
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let dailyBannerItems = dailyBannerItems(
            daySeed: input.daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            backdropItemIDs: input.backdropItemIDs,
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let recommendedItems = recommendedOverviewItems(
            daySeed: input.daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let recommendedIDs = Set(recommendedItems.map(\.id))
        let themeItems = themedHighRatedItems(
            daySeed: input.daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            excludedIDs: recommendedIDs,
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let themeIDs = Set(themeItems.map(\.id))
        let highRatedSeriesItems = highRatedSeriesOverviewItems(
            daySeed: input.daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            excludedIDs: recommendedIDs.union(themeIDs),
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let seriesIDs = Set(highRatedSeriesItems.map(\.id))
        let watchlistItems = watchlistOverviewItems(
            daySeed: input.daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let recentSeriesItems = recentSeriesOverviewItems(
            daySeed: input.daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            excludedIDs: recommendedIDs.union(seriesIDs),
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let recentHighRatedItems = recentHighRatedOverviewItems(
            daySeed: input.daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            excludedIDs: recommendedIDs.union(seriesIDs),
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )
        let offlineItems = offlineOverviewItems(
            daySeed: input.daySeed,
            offlineItems: input.offlineItems,
            profile: profile,
            watchedThreshold: input.watchedThreshold,
            now: input.now
        )

        var boards = [
            HomeOverviewBoardModel(
                id: "daily-banner",
                title: localize("每日推荐", language: input.language),
                subtitle: recommendationSubtitle(for: profile, language: input.language),
                systemImage: "sparkles.tv",
                items: dailyBannerItems,
                emptyMessage: ""
            ),
            HomeOverviewBoardModel(
                id: "continue",
                title: localize("继续观看", language: input.language),
                subtitle: localize("上次停下的地方还在这里。", language: input.language),
                systemImage: "play.circle",
                items: continueWatchingOverviewItems(
                    daySeed: input.daySeed,
                    items: input.continueWatchingItems,
                    profile: profile,
                    watchedThreshold: input.watchedThreshold,
                    now: input.now
                ),
                emptyMessage: localize("开始播放后，这里会留下继续观看的入口。", language: input.language)
            ),
            HomeOverviewBoardModel(
                id: "nextUp",
                title: localize("下一集", language: input.language),
                subtitle: localize("把故事接着往下看。", language: input.language),
                systemImage: "forward.end.circle",
                items: nextUpOverviewItems(
                    daySeed: input.daySeed,
                    items: input.nextUpItems,
                    profile: profile,
                    now: input.now
                ),
                emptyMessage: localize("看过系列剧集后，下一集会自动出现在这里。", language: input.language)
            ),
            HomeOverviewBoardModel(
                id: "recommend",
                title: localize("为你精选", language: input.language),
                subtitle: recommendationSubtitle(for: profile, language: input.language),
                systemImage: "sparkles.tv",
                items: recommendedItems,
                emptyMessage: localize("看过、喜欢或标星一些内容后，推荐会更有方向。", language: input.language)
            )
        ]

        if !themeItems.isEmpty, let genreName = profile.strongestGenreDisplayName {
            boards.append(
                HomeOverviewBoardModel(
                    id: "theme-\(profile.strongestGenre ?? genreName)",
                    title: input.language == .zhHans ? "\(genreName)高分" : "\(localize("高分", language: input.language)) · \(genreName)",
                    subtitle: localize("沿着你最近常看的题材继续挑。", language: input.language),
                    systemImage: "tag",
                    items: themeItems,
                    emptyMessage: ""
                )
            )
        }

        if !highRatedSeriesItems.isEmpty {
            boards.append(
                HomeOverviewBoardModel(
                    id: "high-rated-series",
                    title: localize("高分剧集", language: input.language),
                    subtitle: localize("优先展示评分较高、还没看完的系列。", language: input.language),
                    systemImage: "star.circle",
                    items: highRatedSeriesItems,
                    emptyMessage: ""
                )
            )
        }

        if !watchlistItems.isEmpty {
            boards.append(
                HomeOverviewBoardModel(
                    id: "watchlist",
                    title: localize("想看清单", language: input.language),
                    subtitle: localize("你之前留意过的内容，按适合度重新排好。", language: input.language),
                    systemImage: "bookmark.circle",
                    items: watchlistItems,
                    emptyMessage: ""
                )
            )
        }

        if !recentSeriesItems.isEmpty {
            boards.append(
                HomeOverviewBoardModel(
                    id: "recent-series",
                    title: localize("最近添加 · 剧集", language: input.language),
                    subtitle: localize("按入库时间、评分和偏好信号重新整理最近加入的剧集。", language: input.language),
                    systemImage: "clock.badge.plus",
                    items: recentSeriesItems,
                    emptyMessage: ""
                )
            )
        }

        if !recentHighRatedItems.isEmpty {
            boards.append(
                HomeOverviewBoardModel(
                    id: "recent-high-rated",
                    title: localize("高分精选", language: input.language),
                    subtitle: localize("避开上方推荐，优先展示电影、纪录片和综艺里的高评分内容。", language: input.language),
                    systemImage: "clock.badge.star",
                    items: recentHighRatedItems,
                    emptyMessage: ""
                )
            )
        }

        if !offlineItems.isEmpty {
            boards.append(
                HomeOverviewBoardModel(
                    id: "offline-ready",
                    title: localize("离线可看", language: input.language),
                    subtitle: localize("已经缓存好的内容，离线也能打开。", language: input.language),
                    systemImage: "arrow.down.circle",
                    items: offlineItems,
                    emptyMessage: ""
                )
            )
        }

        boards.append(contentsOf: input.publishedBoards)
        return boards.enumerated()
            .sorted { lhs, rhs in
                let leftHasContent = !lhs.element.items.isEmpty
                let rightHasContent = !rhs.element.items.isEmpty
                if leftHasContent != rightHasContent { return leftHasContent }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func localize(_ key: String, language: AppLanguage) -> String {
        AppLocalizer.text(key, language: language)
    }

    private static let seriesRecommendationTypes: Set<MediaType> = [.tvShow, .anime, .documentary, .variety]

    private static func recommendationSubtitle(for profile: HomeRecommendationProfile, language: AppLanguage) -> String {
        if let genreName = profile.strongestGenreDisplayName {
            if language == .zhHans {
                return "根据你的观看和标星偏好，优先挑 \(genreName) 与高分系列。"
            }
            return localize("根据你的观看和标星偏好，优先挑高分系列。", language: language)
        }
        return localize("先从库内高分系列和近期偏好里挑一些适合看的。", language: language)
    }

    private static func recommendationProfile(
        visibleVideos: [MediaItem],
        continueWatchingItems: [MediaItem],
        nextUpItems: [MediaItem],
        watchedThreshold: Double,
        now: Date
    ) -> HomeRecommendationProfile {
        var profile = HomeRecommendationProfile()
        let signalItems = visibleVideos + continueWatchingItems + nextUpItems
        var seen = Set<String>()

        for item in signalItems where seen.insert(item.id).inserted {
            let signalWeight = recommendationSignalWeight(for: item, watchedThreshold: watchedThreshold, now: now)
            guard signalWeight > 0 else { continue }
            profile.signalItemIDs.insert(item.id)
            profile.typeWeights[item.type, default: 0] += signalWeight * (seriesRecommendationTypes.contains(item.type) ? 1.1 : 0.8)

            let genres = overviewGenres(for: item)
            guard !genres.isEmpty else { continue }
            let perGenreWeight = signalWeight / Double(genres.count)
            for genre in genres {
                profile.genreWeights[genre.key, default: 0] += perGenreWeight
                profile.genreDisplayNames[genre.key] = profile.genreDisplayNames[genre.key] ?? genre.display
            }
        }
        return profile
    }

    private static func recommendationSignalWeight(for item: MediaItem, watchedThreshold: Double, now: Date) -> Double {
        guard item.type != .music, item.type != .privateCollection else { return 0 }
        var weight = 0.0
        if item.favorite { weight += 4.2 }
        if item.watchlist { weight += 1.4 }
        if let userRating = item.userRating, userRating.isFinite {
            if userRating >= 4 {
                weight += userRating * 1.15
            } else if userRating >= 3 {
                weight += userRating * 0.65
            }
        }
        if item.watched || item.playProgress >= watchedThreshold {
            weight += 3.0
        } else if item.playProgress >= 0.12 {
            weight += min(item.playProgress, 0.95) * 2.4
        }
        if let lastPlayedAt = item.lastPlayedAt {
            let days = max(0, now.timeIntervalSince(lastPlayedAt) / 86_400)
            if days <= 120 {
                weight += max(0, 1.6 - days / 75)
            }
        }
        if normalizedProviderScore(item.rating) >= 8.0 {
            weight += 0.5
        }
        return weight
    }

    private static func dailyBannerItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        backdropItemIDs: Set<String>,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        let qualified = visibleVideos.filter { item in
            (normalizedProviderScore(item.rating) > 8 || normalizedUserScore(item.userRating) > 8) &&
            item.type != .music &&
            item.type != .privateCollection
        }
        let fallback = visibleVideos.filter { isHighRatedForOverview($0) }
        var seen = Set<String>()
        let base = (qualified.count >= 3 ? qualified : qualified + fallback).filter { seen.insert($0.id).inserted }
        return rankedDiverseItems(from: base, limit: 7, now: now) { item in
            var score = 0.0
            score += normalizedProviderScore(item.rating) * 0.42
            score += normalizedUserScore(item.userRating) * 0.48
            score += profileAffinityScore(for: item, profile: profile) * 1.55
            score += hasLandscape(item, backdropItemIDs: backdropItemIDs) ? 1.35 : -0.45
            score += item.watchlist ? 0.55 : 0
            score += item.favorite ? 0.42 : 0
            score += isFinished(item, watchedThreshold: watchedThreshold) ? -0.92 : 0
            score += recencyScore(for: item.updatedAt, horizonDays: 540, now: now) * 0.28
            score += stableDailyValue(forID: item.id, daySeed: daySeed, salt: "daily-banner") * 3.2
            return score
        }
    }

    private static func recommendedOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        let preferred = visibleVideos.filter { item in
            !isFinished(item, watchedThreshold: watchedThreshold) || item.watchlist
        }
        let base = preferred.count >= 6 ? preferred : visibleVideos
        return rankedDiverseItems(from: base, limit: 12, now: now) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed, watchedThreshold: watchedThreshold, now: now)
        }
    }

    private static func themedHighRatedItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        guard let strongestGenre = profile.strongestGenre else { return [] }
        let candidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            overviewGenres(for: item).contains { $0.key == strongestGenre } &&
            isHighRatedForOverview(item) &&
            !isFinished(item, watchedThreshold: watchedThreshold)
        }
        return rankedDiverseItems(from: candidates, limit: 12, now: now) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed, watchedThreshold: watchedThreshold, now: now) + 1.6
        }
    }

    private static func highRatedSeriesOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        let candidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            seriesRecommendationTypes.contains(item.type) &&
            isHighRatedForOverview(item) &&
            !isFinished(item, watchedThreshold: watchedThreshold)
        }
        return rankedDiverseItems(from: candidates, limit: 12, now: now) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed, watchedThreshold: watchedThreshold, now: now) + 1.2
        }
    }

    private static func watchlistOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        let candidates = visibleVideos.filter(\.watchlist)
        return rankedDiverseItems(from: candidates, limit: 12, now: now) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed, watchedThreshold: watchedThreshold, now: now) + 2.0
        }
    }

    private static func continueWatchingOverviewItems(
        daySeed: Int,
        items: [MediaItem],
        profile: HomeRecommendationProfile,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        rankedDiverseItems(from: items, limit: 10, now: now) { item in
            let progress = min(max(item.playProgress, 0), 1)
            let sweetSpot = progress > 0.08 && progress < watchedThreshold ? 1.25 : 0
            return recencyScore(for: item.lastPlayedAt ?? item.updatedAt, horizonDays: 45, now: now) * 3.2 +
            sweetSpot +
            profileAffinityScore(for: item, profile: profile) * 0.6 +
            stableDailyValue(forID: item.id, daySeed: daySeed, salt: "continue") * 0.35
        }
    }

    private static func nextUpOverviewItems(
        daySeed: Int,
        items: [MediaItem],
        profile: HomeRecommendationProfile,
        now: Date
    ) -> [MediaItem] {
        rankedDiverseItems(from: items, limit: 10, now: now) { item in
            recencyScore(for: item.lastPlayedAt ?? item.updatedAt, horizonDays: 90, now: now) * 2.2 +
            profileAffinityScore(for: item, profile: profile) * 0.8 +
            stableDailyValue(forID: item.id, daySeed: daySeed, salt: "next-up") * 0.55
        }
    }

    private static func recentSeriesOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        let candidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) && seriesRecommendationTypes.contains(item.type)
        }
        return rankedDiverseItems(from: candidates, limit: 24, now: now) { item in
            recencyScore(for: item.updatedAt, horizonDays: 120, now: now) * 2.1 +
            max(normalizedProviderScore(item.rating), normalizedUserScore(item.userRating)) * 0.22 +
            profileAffinityScore(for: item, profile: profile) * 0.65 +
            (isFinished(item, watchedThreshold: watchedThreshold) ? -0.65 : 0.35) +
            stableDailyValue(forID: item.id, daySeed: daySeed, salt: "recent-series") * 0.75
        }
    }

    private static func recentHighRatedOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        let primaryCandidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            !seriesRecommendationTypes.contains(item.type) &&
            isHighRatedForOverview(item) &&
            !isFinished(item, watchedThreshold: watchedThreshold)
        }
        let candidates = primaryCandidates.count >= 6
            ? primaryCandidates
            : visibleVideos.filter { item in
                !excludedIDs.contains(item.id) &&
                isHighRatedForOverview(item) &&
                !isFinished(item, watchedThreshold: watchedThreshold)
            }
        return rankedDiverseItems(from: candidates, limit: 12, now: now) { item in
            normalizedProviderScore(item.rating) * 1.8 +
            normalizedUserScore(item.userRating) * 1.4 +
            recencyScore(for: item.updatedAt, horizonDays: 240, now: now) * 0.8 +
            profileAffinityScore(for: item, profile: profile) * 0.45 +
            stableDailyValue(forID: item.id, daySeed: daySeed, salt: "recent-high-rated") * 1.75
        }
    }

    private static func offlineOverviewItems(
        daySeed: Int,
        offlineItems: [MediaItem],
        profile: HomeRecommendationProfile,
        watchedThreshold: Double,
        now: Date
    ) -> [MediaItem] {
        let candidates = offlineItems.filter { item in
            item.type != .music && item.type != .episode && item.type != .privateCollection
        }
        return rankedDiverseItems(from: candidates, limit: 12, now: now) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed, watchedThreshold: watchedThreshold, now: now) + 1.4
        }
    }

    private static func recommendationScore(
        for item: MediaItem,
        profile: HomeRecommendationProfile,
        daySeed: Int,
        watchedThreshold: Double,
        now: Date
    ) -> Double {
        let providerScore = normalizedProviderScore(item.rating)
        let userScore = normalizedUserScore(item.userRating)
        let ratingScore = max(providerScore, userScore)
        var score = ratingScore * 1.25
        score += profileAffinityScore(for: item, profile: profile)
        score += seriesRecommendationTypes.contains(item.type) ? 1.35 : 0.3
        score += item.watchlist ? 1.0 : 0
        score += item.favorite ? 0.4 : 0
        score += item.playProgress <= 0.02 && !item.watched ? 0.75 : 0
        score += recencyScore(for: item.updatedAt, horizonDays: 420, now: now) * 0.35
        score += stableDailyValue(forID: item.id, daySeed: daySeed, salt: "item") * 1.65

        if isFinished(item, watchedThreshold: watchedThreshold) {
            score -= 3.8
        } else if item.playProgress > 0.12 {
            score -= 1.2
        }
        if profile.signalItemIDs.contains(item.id), !item.watchlist {
            score -= 0.7
        }
        return score
    }

    private static func rankedDiverseItems(
        from candidates: [MediaItem],
        limit: Int,
        now: Date,
        score: (MediaItem) -> Double
    ) -> [MediaItem] {
        var seen = Set<String>()
        var remaining = candidates.compactMap { item -> (item: MediaItem, score: Double)? in
            guard seen.insert(item.id).inserted else { return nil }
            return (item, score(item))
        }
        var selected: [MediaItem] = []
        var typeCounts: [MediaType: Int] = [:]
        var genreCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]

        while !remaining.isEmpty, selected.count < limit {
            let bestIndex = remaining.indices.max { lhsIndex, rhsIndex in
                let lhs = diversityAdjustedScore(
                    remaining[lhsIndex],
                    typeCounts: typeCounts,
                    genreCounts: genreCounts,
                    sourceCounts: sourceCounts,
                    now: now
                )
                let rhs = diversityAdjustedScore(
                    remaining[rhsIndex],
                    typeCounts: typeCounts,
                    genreCounts: genreCounts,
                    sourceCounts: sourceCounts,
                    now: now
                )
                if lhs != rhs { return lhs < rhs }
                return remaining[lhsIndex].item.title.localizedCaseInsensitiveCompare(remaining[rhsIndex].item.title) == .orderedDescending
            }
            guard let bestIndex else { break }
            let picked = remaining.remove(at: bestIndex).item
            selected.append(picked)
            typeCounts[picked.type, default: 0] += 1
            for genre in overviewGenres(for: picked) {
                genreCounts[genre.key, default: 0] += 1
            }
            if let sourcePath = picked.sourcePath, !sourcePath.isEmpty {
                sourceCounts[sourcePath, default: 0] += 1
            }
        }
        return selected
    }

    private static func diversityAdjustedScore(
        _ candidate: (item: MediaItem, score: Double),
        typeCounts: [MediaType: Int],
        genreCounts: [String: Int],
        sourceCounts: [String: Int],
        now: Date
    ) -> Double {
        let item = candidate.item
        var adjusted = candidate.score
        adjusted -= Double(typeCounts[item.type] ?? 0) * 0.42
        let genres = overviewGenres(for: item)
        if !genres.isEmpty {
            let repeatedGenrePenalty = genres.reduce(0.0) { $0 + Double(genreCounts[$1.key] ?? 0) * 0.28 }
            adjusted -= min(repeatedGenrePenalty, 1.4)
        }
        if let sourcePath = item.sourcePath {
            adjusted -= Double(sourceCounts[sourcePath] ?? 0) * 0.16
        }
        adjusted += recencyScore(for: item.lastPlayedAt, horizonDays: 7, now: now) * 0.04
        return adjusted
    }

    private static func profileAffinityScore(for item: MediaItem, profile: HomeRecommendationProfile) -> Double {
        guard profile.hasSignals else { return 0 }
        let genres = overviewGenres(for: item)
        let rawGenreWeight = genres.reduce(0.0) { partial, genre in
            partial + (profile.genreWeights[genre.key] ?? 0)
        }
        let genreScore: Double
        if profile.maxGenreWeight > 0 {
            genreScore = min(rawGenreWeight / profile.maxGenreWeight, 2.4) * 2.1
        } else {
            genreScore = 0
        }
        let typeWeight = profile.typeWeights[item.type] ?? 0
        let typeScore = profile.maxTypeWeight > 0 ? min(typeWeight / profile.maxTypeWeight, 1.4) * 1.35 : 0
        return genreScore + typeScore
    }

    private static func hasLandscape(_ item: MediaItem, backdropItemIDs: Set<String>) -> Bool {
        backdropItemIDs.contains(item.id) || !(item.backdropPath ?? "").isEmpty
    }

    private static func isHighRatedForOverview(_ item: MediaItem) -> Bool {
        normalizedProviderScore(item.rating) >= 7.3 || normalizedUserScore(item.userRating) >= 8
    }

    private static func isFinished(_ item: MediaItem, watchedThreshold: Double) -> Bool {
        item.watched || item.playProgress >= watchedThreshold
    }

    private static func normalizedProviderScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return rating <= 5 ? rating * 2 : min(rating, 10)
    }

    private static func normalizedUserScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return min(rating, 5) * 2
    }

    private static func recencyScore(for date: Date?, horizonDays: Double, now: Date) -> Double {
        guard let date else { return 0 }
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        guard horizonDays > 0 else { return 0 }
        return max(0, 1 - min(days, horizonDays) / horizonDays)
    }

    private static func overviewGenres(for item: MediaItem) -> [(key: String, display: String)] {
        guard let genre = item.genre else { return [] }
        let separators = CharacterSet(charactersIn: ",，、/|;；")
        var seen = Set<String>()
        return genre
            .components(separatedBy: separators)
            .compactMap { raw -> (key: String, display: String)? in
                let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !display.isEmpty else { return nil }
                let key = display
                    .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                    .lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { return nil }
                return (key, display)
            }
    }

    private static func stableDailyValue(forID id: String, daySeed: Int, salt: String) -> Double {
        let hash = (id + "-\(salt)-\(daySeed)").unicodeScalars.reduce(UInt64(5381)) { partial, scalar in
            ((partial &* 33) &+ UInt64(scalar.value))
        }
        return Double(hash % 997) / 997.0
    }
}

/// 首页总览的跨实例计算缓存（仅主线程访问）：
/// 1) boards：HomeView 随导航切换被整体重建，@State 快照每次从空开始会导致
///    「切回首页先空白/先走同步兜底重算」——把最近一次看板快照静态留存，init 时直接回填。
/// 2) memo：photoWallTheme / 音乐推荐 / hero 兜底等重计算此前在每次 body 求值时
///    同步重算（总览模块在非 Lazy 的 VStack 里），是切页与滚动卡顿的主因。
///    以 overviewSnapshotKey 为键做单代记忆化：键不变直接复用，键变整体作废，
///    输出值与原实时计算逐位一致，不改变任何视觉结果。
@MainActor
private enum HomeOverviewComputationCache {
    static var boardsKey = ""
    static var boards: [HomeOverviewBoardModel] = []

    private static var memoKey = ""
    private static var memo: [String: Any] = [:]

    static func value<T>(_ id: String, key: String, compute: () -> T) -> T {
        if memoKey != key {
            memoKey = key
            memo.removeAll(keepingCapacity: true)
        }
        if let cached = memo[id] as? T {
            return cached
        }
        let value = compute()
        memo[id] = value
        return value
    }
}

private enum HomeModuleKind: String, CaseIterable, Identifiable {
    case hero
    case stats
    case dashboard
    case seriesRecommendations
    case continueWatching
    case recentlyPlayed
    case watchlist
    case favorites
    case musicRecommendations
    case continueListening
    case recentSeries
    case highRated
    case photoWall

    var id: String { rawValue }

    static let defaultOrder: [HomeModuleKind] = [
        .hero,
        .stats,
        .seriesRecommendations,
        .continueWatching,
        .recentlyPlayed,
        .watchlist,
        .favorites,
        .musicRecommendations,
        .continueListening,
        .recentSeries,
        .highRated,
        .photoWall,
        .dashboard
    ]

    static let vividVisibleOrder: [HomeModuleKind] = defaultOrder

    var editingTitle: String {
        switch self {
        case .hero: return "每日推荐"
        case .stats: return "媒体总览"
        case .dashboard: return "运行状态"
        case .seriesRecommendations: return "剧集推荐"
        case .continueWatching: return "继续观看"
        case .recentlyPlayed: return "最近播放"
        case .watchlist: return "想看"
        case .favorites: return "收藏"
        case .musicRecommendations: return "音乐推荐"
        case .continueListening: return "继续听"
        case .recentSeries: return "最近添加"
        case .highRated: return "高分精选"
        case .photoWall: return "照片墙"
        }
    }

    var editingSystemImage: String {
        switch self {
        case .hero: return "sparkles"
        case .stats: return "chart.bar"
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .seriesRecommendations: return "sparkles.tv"
        case .continueWatching: return "play.circle"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .watchlist: return "bookmark"
        case .favorites: return "heart"
        case .musicRecommendations: return "music.note"
        case .continueListening: return "headphones"
        case .recentSeries: return "clock.badge.plus"
        case .highRated: return "star"
        case .photoWall: return "photo.stack"
        }
    }
}

private enum HomeVividFocusedCollection: String {
    case seriesRecommendations
    case recentSeries
    case highRated
    case recentlyPlayed
    case watchlist
    case favorites

    var id: String { rawValue }
}

/// 首页编排只重排模块枚举，不搬动视图实例；这样拖动不会触发媒体数据重算或打断横向列表滚动。
private struct HomeModuleDropDelegate: DropDelegate {
    let target: HomeModuleKind
    @Binding var dragged: HomeModuleKind?
    let onMove: (HomeModuleKind, HomeModuleKind) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        onMove(dragged, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

private struct HomeLayoutFooter: View {
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            Label("编辑首页", systemImage: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HomeVividTokens.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("调整首页组件的顺序和显示内容")
    }
}

private struct HomeLayoutEditorDock: View {
    let canReset: Bool
    let addableModules: [HomeModuleKind]
    @Binding var isShowingAddPanel: Bool
    let onDone: () -> Void
    let onReset: () -> Void
    let onAdd: (HomeModuleKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isShowingAddPanel = true
            } label: {
                Label("添加", systemImage: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HomeVividTokens.textPrimary)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(AppColors.refCardBg, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(HomeVividTokens.controlBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingAddPanel, arrowEdge: .bottom) {
                HomeModuleAddPanel(modules: addableModules) { module in
                    onAdd(module)
                    isShowingAddPanel = false
                }
            }

            if canReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .help("恢复默认布局")
            }

            Button(action: onDone) {
                Label("完成", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(HomeVividTokens.gradient([HomeVividTokens.blue, HomeVividTokens.cyan]), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(AppColors.refCardBg.opacity(0.96), in: Capsule())
        .overlay {
            Capsule().strokeBorder(HomeVividTokens.border.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
    }
}

private struct HomeModuleDragPreview<Content: View>: View {
    let module: HomeModuleKind
    let content: Content

    init(module: HomeModuleKind, @ViewBuilder content: () -> Content) {
        self.module = module
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
                .frame(width: 280, height: 176, alignment: .topLeading)
                .allowsHitTesting(false)
                .clipped()

            Label(module.editingTitle, systemImage: module.editingSystemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(.black.opacity(0.46), in: Capsule())
                .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 9)
    }
}

private struct HomeModuleAddPanel: View {
    let modules: [HomeModuleKind]
    let onAdd: (HomeModuleKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if modules.isEmpty {
                Text("所有组件均已添加")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomeVividTokens.textSecondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(modules) { module in
                    HStack(spacing: 10) {
                        Image(systemName: module.editingSystemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HomeVividTokens.blue)
                            .frame(width: 24, height: 24)
                            .background(HomeVividTokens.color("EEF5FF"), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                        Text(module.editingTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HomeVividTokens.textPrimary)

                        Spacer(minLength: 10)

                        Button("添加") {
                            onAdd(module)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let onOpenHealthCenter: () -> Void
    let onOpenSources: () -> Void
    let onOpenTasks: () -> Void
    let onOpenVideoSection: (VideoLibrarySection) -> Void
    let onOpenMusicSection: (MusicLibrarySection) -> Void
    let onOpenAlbumSection: (AlbumLibrarySection) -> Void
    @State private var searchText: String
    @State private var committedSearchText: String
    @State private var visibleHomeItems: [MediaItem] = []
    @State private var visibleHomeItemsKey = ""
    @State private var isPreparingHomeItems = false
    @State private var homeContentRefreshTask: Task<Void, Never>?
    @State private var homeSearchRefreshTask: Task<Void, Never>?
    @State private var restoredOverviewAnchorID: String?
    @State private var overviewBoardsSnapshot: [HomeOverviewBoardModel] = []
    @State private var overviewBoardsKey = ""
    @State private var overviewBoardsRefreshTask: Task<Void, Never>?
    @State private var inlineReturnContentReady: Bool
    @State private var overviewVerticalReturnReady: Bool
    @State private var overviewHorizontalReturnReady: Bool
    @State private var homeReturnFallbackTask: Task<Void, Never>?
    @State private var homeInlineReturnRestoreTask: Task<Void, Never>?
    @State private var homeTimeRefreshTask: Task<Void, Never>?
    @State private var homeTimeRefreshToken = 0
    @State private var photoWallViewerIndex: Int?
    @State private var focusedVividCollection: HomeVividFocusedCollection?
    @State private var isHomeEditing = false
    @State private var draggedHomeModule: HomeModuleKind?
    @State private var isShowingHomeModuleAddPanel = false
    @AppStorage("MediaLib.home.selectedTab") private var selectedTabRaw = HomeTab.overview.rawValue
    @AppStorage("MediaLib.home.moduleOrder") private var homeModuleOrderRaw = ""
    @AppStorage("MediaLib.home.hiddenModules") private var hiddenHomeModulesRaw = ""

    init(
        initialSearchText: String = "",
        initialReturnAnchorID: String? = nil,
        onOpenHealthCenter: @escaping () -> Void = {},
        onOpenSources: @escaping () -> Void = {},
        onOpenTasks: @escaping () -> Void = {},
        onOpenVideoSection: @escaping (VideoLibrarySection) -> Void = { _ in },
        onOpenMusicSection: @escaping (MusicLibrarySection) -> Void = { _ in },
        onOpenAlbumSection: @escaping (AlbumLibrarySection) -> Void = { _ in }
    ) {
        let normalizedInitialSearch = initialSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        _searchText = State(initialValue: normalizedInitialSearch)
        _committedSearchText = State(initialValue: normalizedInitialSearch)
        // 回填最近一次总览看板快照：避免每次切回首页都从空快照起步、
        // 首帧走同步兜底重算（卡顿）且内容闪变。键不匹配时会照常异步重建。
        _overviewBoardsSnapshot = State(initialValue: HomeOverviewComputationCache.boards)
        _overviewBoardsKey = State(initialValue: HomeOverviewComputationCache.boardsKey)
        _inlineReturnContentReady = State(initialValue: initialReturnAnchorID == nil)
        _overviewVerticalReturnReady = State(initialValue: initialReturnAnchorID == nil)
        _overviewHorizontalReturnReady = State(initialValue: initialReturnAnchorID == nil)
        self.onOpenHealthCenter = onOpenHealthCenter
        self.onOpenSources = onOpenSources
        self.onOpenTasks = onOpenTasks
        self.onOpenVideoSection = onOpenVideoSection
        self.onOpenMusicSection = onOpenMusicSection
        self.onOpenAlbumSection = onOpenAlbumSection
    }

    private var selectedTab: HomeTab {
        get { HomeTab(rawValue: selectedTabRaw) ?? .overview }
        nonmutating set { selectedTabRaw = newValue.rawValue }
    }

    var body: some View {
        let tab = currentTab
        let gridItems = displayedHomeItems(for: tab)
        // 首页搜索框现在即"搜索全部媒体"：有输入时显示跨影音的全局结果（替代海报型分区路径）。
        let activeSearchText = committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !activeSearchText.isEmpty
        let isShowingFocusedVividCollection = !isSearching && tab == .overview && focusedVividCollection != nil

        Group {
            if !isSearching, !appState.sources.isEmpty, isPosterTab(tab), !gridItems.isEmpty {
                // 首页海报型 tab 走原生 List 虚拟化；页头、扫描进度、标签栏和分区标题作为前导行随内容滚动。
                PosterGridList(
                    items: gridItems,
                    bottomInset: gridBottomInset,
                    showsDeletePlaybackHistory: tab == .continueWatching || tab == .nextUp,
                    restoreAnchorID: activeReturnContext?.anchorID,
                    detailSourceDestinationID: SidebarDestination.home.id,
                    onDidRestoreAnchor: completeHomeReturnRestoration
                ) {
                    VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                        header
                        if let progress = appState.scanProgress, appState.isScanning {
                            ScanProgressView(progress: progress)
                        }
                        if usesLegacyHomeChrome {
                            HomeTabBar(tabs: enabledTabs, selection: tabSelection)
                            Text(displayName(for: tab))
                                .font(.title2.weight(.semibold))
                        }
                    }
                }
                .opacity(inlineReturnContentReady ? 1 : 0)
            } else if isShowingFocusedVividCollection, let focusedVividCollection {
                focusedVividCollectionPage(focusedVividCollection)
                    .id("focused-vivid-\(focusedVividCollection.id)")
                    .opacity(inlineReturnContentReady ? 1 : 0)
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                            Color.clear.frame(height: 0).id("home-scroll-top")
                            if !isShowingFocusedVividCollection {
                                header
                            }

                            if !isShowingFocusedVividCollection, let progress = appState.scanProgress, appState.isScanning {
                                ScanProgressView(progress: progress)
                            }

                            if appState.sources.isEmpty {
                                // 启动时媒体库正在异步读取(约120ms+)：此时 sources 还是空数组，但
                                // 磁盘上实际可能已有媒体源——不能直接判"待添加"，否则会闪一次
                                // 误导性的"请添加媒体源"提示。用 isLibraryReloading 区分"真空"与"加载中"。
                                if appState.isLibraryReloading {
                                    HomeLibraryLoadingView()
                                } else {
                                    EmptyLibraryView(onOpenSources: onOpenSources)
                                }
                            } else if isSearching {
                                GlobalSearchView(query: activeSearchText) { item in
                                    if item.type == .music {
                                        appState.play(item)
                                    } else {
                                        appState.presentDetail(
                                            item,
                                            from: SidebarDestination.home.id,
                                            anchorID: item.id,
                                            searchText: activeSearchText
                                        )
                                    }
                                }
                                .environmentObject(appState)
                            } else {
                                if usesLegacyHomeChrome {
                                    HomeTabBar(tabs: enabledTabs, selection: tabSelection)
                                }
                                homeContent(for: tab)
                            }
                        }
                        .pageContainer()
                    }
                    .opacity(inlineReturnContentReady ? 1 : 0)
                    .suppressHoverEffectsDuringScroll()
                    .onAppear {
                        restoreHomeInlineAnchorIfNeeded(
                            activeReturnContext?.anchorID,
                            isSearching: isSearching,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: activeReturnContext?.anchorID) { anchorID in
                        restoreHomeInlineAnchorIfNeeded(anchorID, isSearching: isSearching, scrollProxy: scrollProxy)
                    }
                    .onChange(of: focusedVividCollection?.id) { focusedID in
                        guard focusedID != nil else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        transaction.animation = nil
                        withTransaction(transaction) {
                            scrollProxy.scrollTo("home-scroll-top", anchor: .top)
                        }
                    }
                }
            }
        }
        .background(HomeVividPageBackground())
        .overlay {
            photoWallViewerOverlay
        }
        .navigationTitle("首页")
        .overlay(alignment: .bottom) {
            if isHomeEditing, !isSearching, tab == .overview, focusedVividCollection == nil, !appState.sources.isEmpty {
                HomeLayoutEditorDock(
                    canReset: !hiddenHomeModules.isEmpty || homeModuleOrderRaw.isEmpty == false,
                    addableModules: availableHomeModulesToAdd,
                    isShowingAddPanel: $isShowingHomeModuleAddPanel,
                    onDone: toggleHomeEditing,
                    onReset: resetHomeLayout,
                    onAdd: addHomeModule
                )
                .padding(.bottom, appState.activePlayerItem?.type == .music ? 82 : 14)
                .zIndex(60)
            }
        }
        .transaction { transaction in
            if layoutTransitionActive {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        .onAppear {
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded(force: true)
            startHomeTimeRefreshLoop()
            refreshHomeItems(for: currentTab)
            if activeReturnContext == nil {
                inlineReturnContentReady = true
                overviewVerticalReturnReady = true
                overviewHorizontalReturnReady = true
            } else {
                scheduleHomeReturnVisibilityFallback()
            }
            appState.showInterfaceTipOnce(
                key: "home.overview.boards",
                message: "总览会把继续观看、下一集、推荐和已发布片单放在一起，适合先找今天要看的内容。"
            )
            appState.showInterfaceTipOnce(
                key: "home.recommendation.preference",
                message: "推荐会参考你看过、喜欢、想看和标星的题材，优先展示评分较高且还没看完的内容。"
            )
        }
        .onChange(of: selectedTabRaw) { _ in
            refreshOverviewBoardsIfNeeded()
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: searchText) { _ in
            scheduleHomeSearchRefresh()
        }
        .onChange(of: appState.settings.enabledHomeTabs) { _ in
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.libraryRevision) { _ in
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.favoriteRevision) { _ in
            // 喜欢乐观更新只 bump favoriteRevision；首页“喜欢”标签需据此刷新。
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.watchlistRevision) { _ in
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.ratingRevision) { _ in
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.videoCacheRevision) { _ in
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.settings.watchedThreshold) { _ in
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        // 日期刷新不能只靠定时循环（Task.sleep 在系统睡眠期间挂起，会把跨天刷新
        // 拖延数小时）：日历日变更、系统唤醒、App 激活三个时机都主动对比快照键，
        // 跨天/跨 3 小时桶立即换新推荐内容，并重排定时循环的下一次触发点。
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            refreshOverviewBoardsIfNeeded()
            startHomeTimeRefreshLoop()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)) { _ in
            refreshOverviewBoardsIfNeeded()
            startHomeTimeRefreshLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshOverviewBoardsIfNeeded()
        }
        // 今日推荐 banner 的横版图兜底补抓：没有横版剧照的条目先按竖版海报裁切显示，
        // 后台异步经 TMDB/Emby 拉取 backdrop，拉到后随 backdropRevision 自动换图。
        .task(id: overviewHeroWarmupKey) {
            appState.warmHeroBackdrops(for: overviewFeaturedItems)
        }
        .onDisappear {
            homeContentRefreshTask?.cancel()
            homeSearchRefreshTask?.cancel()
            overviewBoardsRefreshTask?.cancel()
            homeReturnFallbackTask?.cancel()
            homeInlineReturnRestoreTask?.cancel()
            homeTimeRefreshTask?.cancel()
        }
    }

    private var enabledTabs: [HomeTab] {
        let configured = appState.settings.enabledHomeTabs.isEmpty ? AppSettings.defaultHomeTabs : appState.settings.enabledHomeTabs
        let available = configured.filter { appState.availableHomeTabs.contains($0) }
        return available.isEmpty ? [.overview] : available
    }

    /// 顶部首页 chrome（标签栏 HomeTabBar + 页头操作按钮：搜索/扫描/清除记录）暂时废弃。
    /// 置 false 隐藏并强制只显示总览；代码全部保留，置回 true 即恢复旧版顶部控制条与按钮。
    private let usesLegacyHomeChrome = false

    private var currentTab: HomeTab {
        guard usesLegacyHomeChrome else { return .overview }
        return enabledTabs.contains(selectedTab) ? selectedTab : (enabledTabs.first ?? .overview)
    }

    private var header: some View {
        HomeVividHeader(
            greeting: greeting,
            searchText: $searchText,
            isScanning: appState.isScanning,
            scanQueueCount: appState.scanQueueCount,
            onSubmitSearch: commitHomeSearch,
            onScan: { appState.scanSources(for: currentTab) },
            scanDisabled: appState.sources.isEmpty || appState.isScanning,
            showsScanButton: false
        )
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return appState.localized("早上好")
        case 12..<14: return appState.localized("中午好")
        case 14..<18: return appState.localized("下午好")
        case 18..<23: return appState.localized("晚上好")
        default: return appState.localized("夜深了")
        }
    }

    private func vividStatTiles(_ stats: HomeStatsSnapshot) -> [HomeVividStatTile] {
        var values: [HomeVividStatTile] = []
        values.append(HomeVividStatTile(id: "movies", title: appState.localized("影片"), value: vividCount(stats.movieCount), iconName: "movie", tint: HomeVividTokens.blue))
        values.append(HomeVividStatTile(id: "series", title: appState.localized("系列"), value: vividCount(stats.seriesCount), iconName: "series", tint: HomeVividTokens.mint))
        values.append(HomeVividStatTile(id: "episodes", title: appState.localized("剧集"), value: vividCount(stats.episodeCount), iconName: "episodes", tint: HomeVividTokens.orange))
        values.append(HomeVividStatTile(id: "unwatched", title: appState.localized("未观看"), value: vividCount(stats.unwatchedCount), iconName: "unwatched", tint: HomeVividTokens.pink))
        return values
    }

    private func vividCount(_ value: Int) -> String {
        if value >= 10_000 {
            return "\(value / 1000)K"
        }
        return value.formatted()
    }

    private func vividBarColors(seed: Int) -> [Color] {
        let pair = HomeVividTokens.accentPair(seed: seed)
        return [pair.0, pair.1]
    }

    private var tabSelection: Binding<HomeTab> {
        Binding(get: { selectedTab }, set: { selectedTab = $0 })
    }

    // 海报型 tab：非总览、且非锁定状态的保险库。这类 tab 有内容时走 PosterGridList 虚拟化。
    private func isPosterTab(_ tab: HomeTab) -> Bool {
        if tab == .overview { return false }
        if tab == .privacy, !appState.privacyPINConfigured || !appState.privacyUnlocked { return false }
        return true
    }

    private var gridBottomInset: CGFloat {
        appState.activePlayerItem?.type == .music ? 122 : 22
    }

    @ViewBuilder
    private func homeContent(for tab: HomeTab) -> some View {
        switch tab {
        case .overview:
            if focusedVividCollection == nil {
                // 普通首页只渲染有实际内容的模块；编辑态保留已添加模块，
                // 这样用户仍可将暂时为空的模块移除或调整位置。
                let modules = isHomeEditing ? orderedHomeModules : visibleHomeModules
                VStack(alignment: .leading, spacing: HomeVividTokens.moduleSpacing) {
                    ForEach(modules) { module in
                        editableOverviewModule(module) {
                            vividOverviewModuleContent(module)
                                .id("home-module-\(module.rawValue)")
                                // 首次进入首页时模块逐块浮入（blockStagger + 逐项 delay）；
                                // 从详情返回（有锚点恢复）或 Reduce Motion 时直接呈现终态。
                                .modifier(HomeModuleEntranceModifier(
                                    index: modules.firstIndex(of: module) ?? 0,
                                    staggerEnabled: activeReturnContext == nil && !isHomeEditing
                                ))
                        }
                    }

                    if !isHomeEditing {
                        HomeLayoutFooter(onEdit: toggleHomeEditing)
                            .padding(.top, 8)
                    }
                }
                .padding(.bottom, isHomeEditing ? 82 : 0)
            } else {
                EmptyView()
            }
        case .privacy where !appState.privacyPINConfigured || !appState.privacyUnlocked:
            PrivacyLockView()
                .frame(minHeight: 420)
        default:
            let items = displayedHomeItems(for: tab)
            let tabName = displayName(for: tab)
            if (isPreparingHomeItems || visibleHomeItemsAreOutOfDate(for: tab)) && items.isEmpty {
                AppLoadingView(title: homePhrase(prefix: "正在载入", name: tabName), systemImage: tab.systemImage, rowCount: 4)
            } else if items.isEmpty {
	                EmptyStateView(
	                    title: homePhrase(prefix: "暂无", name: tabName),
	                    systemImage: tab.systemImage,
	                    message: emptyMessage(for: tab)
	                )
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                // 有内容的海报型 tab 已在 body 中走 PosterGridList 虚拟化，此分支不会到达。
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func vividOverviewModuleContent(_ module: HomeModuleKind) -> some View {
        switch module {
        case .hero:
            let items = overviewFeaturedItems
            if !items.isEmpty {
                HomeVividHeroCarousel(
                    items: items,
                    cachedBanner: { cachedBannerPath(for: $0) },
                    subtitle: { item in
                        item.genre ?? recommendationSubtitle(for: recommendationProfile(from: overviewCandidateVideos()))
                    },
                    onPlay: { appState.play($0) },
                    onToggleWatchlist: { appState.toggleWatchlist($0) },
                    onSelect: { appState.presentDetail($0, from: SidebarDestination.home.id, anchorID: $0.id) }
                )
                .onAppear {
                    if let anchorID = activeReturnContext?.anchorID, items.contains(where: { $0.id == anchorID }) {
                        completeOverviewHorizontalRestoration()
                    }
                }
            }
        case .stats:
            HomeVividStatsGrid(tiles: vividStatTiles(appState.homeStats))
        case .dashboard:
            HomeVividDashboard(
                sourceGroups: dashboardSourceGroups,
                sourceOnlineCount: dashboardOnlineSourceCount,
                sourceTotalCount: dashboardVisibleSources.count,
                healthScore: dashboardOverallHealthPercent,
                sourceHealthPercent: dashboardSourceHealthPercent,
                metadataHealthPercent: dashboardMetadataHealthPercent,
                tasks: dashboardTaskSummaries,
                onOpenSources: onOpenSources,
                onOpenHealth: onOpenHealthCenter,
                onOpenTasks: onOpenTasks
            )
        case .seriesRecommendations:
            let items = seriesRecommendationItems
            if !items.isEmpty {
                HomeVividPosterRow(
                    title: appState.localized("剧集推荐"),
                    barColors: [HomeVividTokens.orange, HomeVividTokens.pink],
                    actionTitle: "查看全部 ›",
                    actionTint: HomeVividTokens.pink,
                    items: items,
                    variant: .poster,
                    metadata: overviewMetadata(for:),
                    onSelect: openHomeItem,
                    action: { focusedVividCollection = .seriesRecommendations },
                    restoreAnchorID: activeReturnContext?.anchorID,
                    onDidRestoreAnchor: completeOverviewHorizontalRestoration
                )
            }
        case .continueWatching:
            let items = continueWatchingSeriesItems
            if !items.isEmpty {
                HomeVividPosterRow(
                    title: appState.localized("继续观看 · 剧集"),
                    barColors: [HomeVividTokens.cyan, HomeVividTokens.blue],
                    actionTitle: "查看全部 ›",
                    actionTint: HomeVividTokens.blue,
                    items: items,
                    variant: .progress,
                    metadata: overviewMetadata(for:),
                    onSelect: openHomeItem,
                    action: { onOpenVideoSection(.watching) },
                    restoreAnchorID: activeReturnContext?.anchorID,
                    onDidRestoreAnchor: completeOverviewHorizontalRestoration
                )
            }
        case .recentlyPlayed:
            HomeVividPosterRow(
                title: appState.localized("最近播放"),
                barColors: [HomeVividTokens.cyan, HomeVividTokens.indigo],
                actionTitle: "查看全部 ›",
                actionTint: HomeVividTokens.indigo,
                items: homeRecentlyPlayedItems,
                variant: .poster,
                emptyMessage: appState.localized("开始播放后，这里会汇总本地与远程媒体的最近记录。"),
                metadata: overviewMetadata(for:),
                onSelect: openHomeItem,
                action: { focusedVividCollection = .recentlyPlayed },
                restoreAnchorID: activeReturnContext?.anchorID,
                onDidRestoreAnchor: completeOverviewHorizontalRestoration
            )
        case .watchlist:
            HomeVividPosterRow(
                title: appState.localized("想看"),
                barColors: [HomeVividTokens.orange, HomeVividTokens.pink],
                actionTitle: "查看全部 ›",
                actionTint: HomeVividTokens.pink,
                items: homeWatchlistItems,
                variant: .poster,
                emptyMessage: appState.localized("把感兴趣的影片加入想看，它们会在这里跨来源汇总。"),
                metadata: overviewMetadata(for:),
                onSelect: openHomeItem,
                action: { focusedVividCollection = .watchlist },
                restoreAnchorID: activeReturnContext?.anchorID,
                onDidRestoreAnchor: completeOverviewHorizontalRestoration
            )
        case .favorites:
            HomeVividPosterRow(
                title: appState.localized("收藏"),
                barColors: [HomeVividTokens.pink, HomeVividTokens.violet],
                actionTitle: "查看全部 ›",
                actionTint: HomeVividTokens.violet,
                items: homeFavoriteItems,
                variant: .poster,
                emptyMessage: appState.localized("收藏影片或喜欢歌曲后，这里会从整个公开媒体库为你汇总。"),
                metadata: overviewMetadata(for:),
                onSelect: openHomeItem,
                action: { focusedVividCollection = .favorites },
                restoreAnchorID: activeReturnContext?.anchorID,
                onDidRestoreAnchor: completeOverviewHorizontalRestoration
            )
        case .musicRecommendations:
            let tracks = musicRecommendationItems
            if !tracks.isEmpty {
                HomeVividMusicRecommendation(
                    tracks: tracks,
                    playlist: recommendedPlaylistSummary,
                    onTrackSelect: { track in appState.replaceMusicQueueAndPlay(tracks, startingAt: track) },
                    onPlaylistSelect: playPlaylistSummary,
                    onOpenMusic: { onOpenMusicSection(.songs) }
                )
            }
        case .continueListening:
            let tracks = continueListeningItems
            if !tracks.isEmpty {
                HomeVividContinueListening(
                    tracks: tracks,
                    onTrackSelect: { appState.play($0) },
                    onOpenMusic: { onOpenMusicSection(.recent) }
                )
            }
        case .recentSeries:
            let items = recentSeriesItems
            if !items.isEmpty {
                HomeVividPosterRow(
                    title: appState.localized("最近添加 · 剧集"),
                    barColors: [HomeVividTokens.indigo, HomeVividTokens.blue],
                    actionTitle: "查看全部 ›",
                    actionTint: HomeVividTokens.blue,
                    items: items,
                    variant: .poster,
                    metadata: overviewMetadata(for:),
                    onSelect: openHomeItem,
                    action: { focusedVividCollection = .recentSeries },
                    restoreAnchorID: activeReturnContext?.anchorID,
                    onDidRestoreAnchor: completeOverviewHorizontalRestoration
                )
            }
        case .highRated:
            let items = highRatedFeaturedItems
            if !items.isEmpty {
                HomeVividPosterRow(
                    title: appState.localized("高分精选"),
                    barColors: [HomeVividTokens.orange, HomeVividTokens.violet],
                    actionTitle: "查看全部 ›",
                    actionTint: HomeVividTokens.violet,
                    items: items,
                    variant: .poster,
                    metadata: overviewMetadata(for:),
                    onSelect: openHomeItem,
                    action: { focusedVividCollection = .highRated },
                    restoreAnchorID: activeReturnContext?.anchorID,
                    onDidRestoreAnchor: completeOverviewHorizontalRestoration
                )
            }
        case .photoWall:
            let theme = photoWallTheme
            if !theme.items.isEmpty {
                HomeVividPhotoWall(
                    items: theme.items,
                    themeTitle: theme.title,
                    badgeText: theme.badge,
                    onOpenAlbum: { onOpenAlbumSection(.all) },
                    onSelect: openPhotoWallItem
                )
            }
        }
    }

    @ViewBuilder
    private func focusedVividCollectionPage(_ collection: HomeVividFocusedCollection) -> some View {
        switch collection {
        case .seriesRecommendations:
            focusedCollectionPosterGrid(
                title: appState.localized("剧集推荐"),
                subtitle: appState.localized("根据你的观看、想看和评分信号整理。"),
                barColors: [HomeVividTokens.orange, HomeVividTokens.pink],
                items: seriesRecommendationItems
            )
        case .recentSeries:
            focusedCollectionPosterGrid(
                title: appState.localized("最近添加 · 剧集"),
                subtitle: appState.localized("按入库时间整理最近加入的剧集。"),
                barColors: [HomeVividTokens.indigo, HomeVividTokens.blue],
                items: recentSeriesItems
            )
        case .highRated:
            focusedCollectionPosterGrid(
                title: appState.localized("高分精选"),
                subtitle: appState.localized("从高评分和偏好信号中挑选。"),
                barColors: [HomeVividTokens.orange, HomeVividTokens.violet],
                items: highRatedFeaturedItems
            )
        case .recentlyPlayed:
            focusedCollectionPosterGrid(
                title: appState.localized("最近播放"),
                subtitle: appState.localized("从全部公开媒体源汇总最近播放记录。"),
                barColors: [HomeVividTokens.cyan, HomeVividTokens.indigo],
                items: homeRecentlyPlayedItems
            )
        case .watchlist:
            focusedCollectionPosterGrid(
                title: appState.localized("想看"),
                subtitle: appState.localized("从全部公开媒体源汇总你的想看项目。"),
                barColors: [HomeVividTokens.orange, HomeVividTokens.pink],
                items: homeWatchlistItems
            )
        case .favorites:
            focusedCollectionPosterGrid(
                title: appState.localized("收藏"),
                subtitle: appState.localized("从全部公开媒体源汇总你喜欢的影片和歌曲。"),
                barColors: [HomeVividTokens.pink, HomeVividTokens.violet],
                items: homeFavoriteItems
            )
        }
    }

    private func focusedCollectionPosterGrid(
        title: String,
        subtitle: String,
        barColors: [Color],
        items: [MediaItem]
    ) -> some View {
        PosterGridList(
            items: items,
            bottomInset: gridBottomInset,
            detailSourceDestinationID: SidebarDestination.home.id
        ) {
            focusedCollectionHeader(title: title, subtitle: subtitle, barColors: barColors)
        }
    }

    private func focusedCollectionHeader(title: String, subtitle: String, barColors: [Color]) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(HomeVividTokens.gradient(barColors))
                        .frame(width: 6, height: 32)
                    Text(title)
                        .font(.system(size: 29, weight: .black))
                        .foregroundStyle(HomeVividTokens.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(HomeVividTokens.textSecondary)
                    .padding(.leading, 16)
            }
            Spacer()
            Button {
                focusedVividCollection = nil
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .black))
                    Text("返回首页")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HomeVividTokens.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(AppColors.refCardBg, in: Capsule())
                .overlay(Capsule().strokeBorder(HomeVividTokens.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var photoWallViewerOverlay: some View {
        let items = photoWallItems
        if let start = photoWallViewerIndex, items.indices.contains(start) {
            MediaImageViewer(
                items: items.map(MediaImageViewerEntry.init(item:)),
                index: Binding(
                    get: { photoWallViewerIndex ?? start },
                    set: { photoWallViewerIndex = $0 }
                ),
                allowsFavorite: false,
                onClose: { photoWallViewerIndex = nil },
                onPlayVideo: { entry in
                    photoWallViewerIndex = nil
                    if let item = entry.item { appState.play(item) }
                }
            )
            .environmentObject(appState)
            .transition(.opacity)
            .zIndex(50)
        }
    }

    @ViewBuilder
    private func overviewModuleContent(_ module: HomeModuleKind) -> some View {
        switch module {
        case .hero:
            let featuredItems = overviewFeaturedItems
            if !featuredItems.isEmpty {
                AuroraHeroCarousel(
                    items: featuredItems,
                    localize: { appState.localized($0) },
                    cachedBanner: { cachedBannerPath(for: $0) },
                    resolveBanner: { _ in nil },
                    onPrimary: { appState.play($0) },
                    onSecondary: { appState.toggleWatchlist($0) },
                    onSelect: { appState.presentDetail($0, from: SidebarDestination.home.id, anchorID: $0.id) }
                )
            }
        case .stats:
            HomeStatsView()
        case .dashboard:
            HomeDashboardModuleView(
                sources: dashboardSourceSummaries,
                spotlight: dashboardSpotlight,
                accentColor: AuroraPalette.teal,
                onOpenSources: onOpenSources,
                onOpenSpotlight: dashboardSpotlight.progress == nil ? onOpenHealthCenter : onOpenTasks
            )
        case .seriesRecommendations:
            let items = seriesRecommendationItems
            if !items.isEmpty {
                HomeRecommendRow(
                    title: appState.localized("剧集推荐"),
                    systemImage: "sparkles.tv",
                    accentColor: AuroraPalette.blue,
                    items: items,
                    subtitle: { overviewMetadata(for: $0) },
                    mediaType: { $0.type },
                    onSelect: openHomeItem
                )
            }
        case .continueWatching:
            let items = continueWatchingSeriesItems
            if !items.isEmpty {
                HomeSectionBlock(
                    title: appState.localized("继续观看"),
                    subtitle: appState.localized("把上次停下的故事接着看。"),
                    systemImage: "play.circle",
                    accentColor: AuroraPalette.cyan,
                    items: items,
                    emptyMessage: appState.localized("开始播放后，这里会留下继续观看的入口。"),
                    metadata: overviewMetadata(for:),
                    showsDeletePlaybackHistory: true,
                    onSelect: openHomeItem,
                    restoreAnchorID: activeReturnContext?.anchorID,
                    onDidRestoreAnchor: completeOverviewHorizontalRestoration
                )
            }
        case .recentlyPlayed:
            HomeOverviewBoard(
                title: appState.localized("最近播放"),
                subtitle: appState.localized("从全部公开媒体源汇总最近播放记录。"),
                systemImage: "clock.arrow.circlepath",
                items: homeRecentlyPlayedItems,
                emptyMessage: appState.localized("开始播放后，这里会汇总本地与远程媒体的最近记录。"),
                metadata: overviewMetadata(for:),
                onSelect: openHomeItem,
                restoreAnchorID: activeReturnContext?.anchorID,
                onDidRestoreAnchor: completeOverviewHorizontalRestoration
            )
        case .watchlist:
            HomeOverviewBoard(
                title: appState.localized("想看"),
                subtitle: appState.localized("从全部公开媒体源汇总你的想看项目。"),
                systemImage: "bookmark",
                items: homeWatchlistItems,
                emptyMessage: appState.localized("把感兴趣的影片加入想看，它们会在这里跨来源汇总。"),
                metadata: overviewMetadata(for:),
                onSelect: openHomeItem,
                restoreAnchorID: activeReturnContext?.anchorID,
                onDidRestoreAnchor: completeOverviewHorizontalRestoration
            )
        case .favorites:
            HomeOverviewBoard(
                title: appState.localized("收藏"),
                subtitle: appState.localized("从全部公开媒体源汇总你喜欢的内容。"),
                systemImage: "heart",
                items: homeFavoriteItems,
                emptyMessage: appState.localized("收藏影片或喜欢歌曲后，这里会从整个公开媒体库为你汇总。"),
                metadata: overviewMetadata(for:),
                onSelect: openHomeItem,
                restoreAnchorID: activeReturnContext?.anchorID,
                onDidRestoreAnchor: completeOverviewHorizontalRestoration
            )
        case .musicRecommendations:
            let tracks = musicRecommendationItems
            if !tracks.isEmpty {
                HomeMusicRecommendationModule(
                    title: appState.localized("音乐推荐"),
                    subtitle: appState.localized("左侧挑歌，右侧留给今天的歌单。"),
                    tracks: tracks,
                    playlist: recommendedPlaylistSummary,
                    accentColor: AuroraPalette.purple,
                    onTrackSelect: { appState.play($0) },
                    onPlaylistSelect: playPlaylistSummary
                )
            }
        case .continueListening:
            let tracks = continueListeningItems
            if !tracks.isEmpty {
                HomeContinueListeningModule(
                    tracks: tracks,
                    accentColor: AuroraPalette.magenta,
                    onTrackSelect: { appState.play($0) }
                )
            }
        case .recentSeries:
            let items = recentSeriesItems
            if !items.isEmpty {
                HomeRecommendRow(
                    title: appState.localized("最近添加"),
                    systemImage: "clock.badge.plus",
                    accentColor: AuroraPalette.orange,
                    items: items,
                    subtitle: { overviewMetadata(for: $0) },
                    mediaType: { $0.type },
                    onSelect: openHomeItem
                )
            }
        case .highRated:
            let items = highRatedFeaturedItems
            if !items.isEmpty {
                HomeRecommendRow(
                    title: appState.localized("高分精选"),
                    systemImage: "star.fill",
                    accentColor: AuroraPalette.purple,
                    items: items,
                    subtitle: { overviewMetadata(for: $0) },
                    mediaType: { $0.type },
                    onSelect: openHomeItem
                )
            }
        case .photoWall:
            let theme = photoWallTheme
            if !theme.items.isEmpty {
                HomePhotoWallModule(
                    items: theme.items,
                    themeTitle: theme.title,
                    badgeText: theme.badge,
                    accentColor: AuroraPalette.cyan,
                    onSelect: openHomeItem
                )
            }
        }
    }

    // 把"前缀 + 分区名"按语言拼成自然短语：中文紧贴，英文/日文按各自语序加分隔。
    private func homePhrase(prefix: String, name: String) -> String {
        switch appState.settings.appLanguage {
        case .zhHans:
            return "\(prefix)\(name)"
        case .ja:
            return "\(name)\(appState.localized(prefix))"
        case .en:
            return "\(appState.localized(prefix)) \(name)"
        }
    }

    private var orderedHomeModules: [HomeModuleKind] {
        let hidden = hiddenHomeModules
        let visible = allOrderedHomeModules.filter { !hidden.contains($0) }
        return visible.isEmpty ? [.hero] : visible
    }

    private var visibleHomeModules: [HomeModuleKind] {
        orderedHomeModules.filter(isHomeModuleVisible)
    }

    private func isHomeModuleVisible(_ module: HomeModuleKind) -> Bool {
        switch module {
        case .hero:
            return !overviewFeaturedItems.isEmpty
        case .stats, .dashboard:
            // 这两项是全局状态而非媒体项目；媒体库存在时始终保留总览入口。
            return true
        case .seriesRecommendations:
            return !seriesRecommendationItems.isEmpty
        case .continueWatching:
            return !continueWatchingSeriesItems.isEmpty
        case .recentlyPlayed:
            return !homeRecentlyPlayedItems.isEmpty
        case .watchlist:
            return !homeWatchlistItems.isEmpty
        case .favorites:
            return !homeFavoriteItems.isEmpty
        case .musicRecommendations:
            return !musicRecommendationItems.isEmpty
        case .continueListening:
            return !continueListeningItems.isEmpty
        case .recentSeries:
            return !recentSeriesItems.isEmpty
        case .highRated:
            return !highRatedFeaturedItems.isEmpty
        case .photoWall:
            return !photoWallTheme.items.isEmpty
        }
    }

    private var hiddenHomeModules: Set<HomeModuleKind> {
        let allowedIDs = HomeModuleKind.vividVisibleOrder.map(\.rawValue)
        let storedIDs = homeModuleOrderRaw
            .split(separator: ",")
            .map(String.init)
        let hiddenIDs = HomeModuleLayoutPolicy.normalizedHiddenIDs(
            storedIDs: hiddenHomeModulesRaw.split(separator: ",").map(String.init),
            allowedIDs: allowedIDs
        )
        // 在当前有效顺序外的 id 无意义，顺带从读取结果中剔除。
        let effectiveIDs = Set(HomeModuleLayoutPolicy.normalizedOrder(storedIDs: storedIDs, allowedIDs: allowedIDs))
        return Set(hiddenIDs.intersection(effectiveIDs).compactMap(HomeModuleKind.init(rawValue:)))
    }

    /// 首页的公开集合边界：本地、远程视频与远程音乐都允许进入；保险库条目在
    /// AppState 的首页投影阶段已经剔除，这里再做一次防御性过滤以保证 UI 不泄漏。
    private var homePublicMediaItems: [MediaItem] {
        var seen = Set<String>()
        return (appState.homeVideoItems + appState.homeMusicTracks + appState.albumItems)
            .filter { item in
                item.type != .privateCollection &&
                !appState.isPrivateItem(item) &&
                seen.insert(item.id).inserted
            }
    }

    private var homeRecentlyPlayedItems: [MediaItem] {
        // 相册源的录像仍可能是 .homeVideo；必须经 isAlbumItem 按来源路径过滤，
        // 不能只依赖 MediaType，否则“最近播放”会重新混入相册内容。
        MediaPlaybackRecencyPolicy.recentNonMusicItems(
            homePublicMediaItems.filter { !appState.isAlbumItem($0) },
            limit: 36
        )
    }

    private var homeWatchlistItems: [MediaItem] {
        homePublicMediaItems
            .filter(\.watchlist)
            .sorted { lhs, rhs in
                let leftScore = max(lhs.rating ?? 0, (lhs.userRating ?? 0) * 2)
                let rightScore = max(rhs.rating ?? 0, (rhs.userRating ?? 0) * 2)
                if leftScore != rightScore { return leftScore > rightScore }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(36)
            .map { $0 }
    }

    private var homeFavoriteItems: [MediaItem] {
        homePublicMediaItems
            .filter(\.favorite)
            .sorted { lhs, rhs in
                let left = lhs.lastPlayedAt ?? lhs.updatedAt
                let right = rhs.lastPlayedAt ?? rhs.updatedAt
                if left != right { return left > right }
                let leftScore = max(lhs.rating ?? 0, (lhs.userRating ?? 0) * 2)
                let rightScore = max(rhs.rating ?? 0, (rhs.userRating ?? 0) * 2)
                if leftScore != rightScore { return leftScore > rightScore }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(36)
            .map { $0 }
    }

    @ViewBuilder
    private func editableOverviewModule<Content: View>(
        _ module: HomeModuleKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isHomeEditing {
            let isDragged = draggedHomeModule == module
            content()
                .allowsHitTesting(false)
                .opacity(isDragged ? 0.42 : 1)
                .scaleEffect(isDragged ? 0.985 : 1, anchor: .center)
                .zIndex(isDragged ? 2 : 0)
                .animation(.easeOut(duration: 0.16), value: isDragged)
                .overlay {
                    // 编辑时内容区被禁用以避免误播放；透明层只提供拖放与右键移除。
                    // 顺序在拖入目标模块时即时重排，因此无需额外的插入线提示。
                    Color.clear
                        .contentShape(RoundedRectangle(cornerRadius: HomeVividTokens.largeCardRadius, style: .continuous))
                        .onDrag {
                            draggedHomeModule = module
                            return NSItemProvider(object: module.rawValue as NSString)
                        } preview: {
                            HomeModuleDragPreview(module: module) {
                                content()
                            }
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: HomeModuleDropDelegate(
                                target: module,
                                dragged: $draggedHomeModule,
                                onMove: moveHomeModule
                            )
                        )
                        .contextMenu {
                            Button(role: .destructive) {
                                hideHomeModule(module)
                            } label: {
                                Label("移除\(module.editingTitle)", systemImage: "minus.circle")
                            }
                        }
                        .accessibilityLabel("拖动\(module.editingTitle)以调整顺序")
                }
                .contentShape(RoundedRectangle(cornerRadius: HomeVividTokens.largeCardRadius, style: .continuous))
        } else {
            content()
        }
    }

    private func toggleHomeEditing() {
        withAnimation(AppMotion.standard) {
            isHomeEditing.toggle()
        }
        if !isHomeEditing {
            draggedHomeModule = nil
            isShowingHomeModuleAddPanel = false
        }
    }

    private func moveHomeModule(_ module: HomeModuleKind, before destination: HomeModuleKind) {
        let movedIDs = HomeModuleLayoutPolicy.moving(
            module.rawValue,
            before: destination.rawValue,
            in: allOrderedHomeModules.map(\.rawValue)
        )
        persistHomeModuleOrder(movedIDs.compactMap(HomeModuleKind.init(rawValue:)))
    }

    private func hideHomeModule(_ module: HomeModuleKind) {
        // 至少保留一个可见模块，避免用户因误触进入空白首页且没有恢复入口。
        guard orderedHomeModules.count > 1 else { return }
        var hidden = hiddenHomeModules
        hidden.insert(module)
        hiddenHomeModulesRaw = HomeModuleKind.vividVisibleOrder
            .filter { hidden.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private var availableHomeModulesToAdd: [HomeModuleKind] {
        HomeModuleKind.vividVisibleOrder.filter { hiddenHomeModules.contains($0) }
    }

    private func addHomeModule(_ module: HomeModuleKind) {
        let reorderedIDs = HomeModuleLayoutPolicy.appending(
            module.rawValue,
            to: allOrderedHomeModules.map(\.rawValue)
        )
        persistHomeModuleOrder(reorderedIDs.compactMap(HomeModuleKind.init(rawValue:)))

        var hidden = hiddenHomeModules
        hidden.remove(module)
        hiddenHomeModulesRaw = HomeModuleKind.vividVisibleOrder
            .filter { hidden.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func resetHomeLayout() {
        homeModuleOrderRaw = ""
        hiddenHomeModulesRaw = ""
    }

    private var allOrderedHomeModules: [HomeModuleKind] {
        let storedIDs = homeModuleOrderRaw
            .split(separator: ",")
            .map(String.init)
        let allowedIDs = HomeModuleKind.vividVisibleOrder.map(\.rawValue)
        return HomeModuleLayoutPolicy.normalizedOrder(storedIDs: storedIDs, allowedIDs: allowedIDs)
            .compactMap(HomeModuleKind.init(rawValue:))
    }

    private func persistHomeModuleOrder(_ modules: [HomeModuleKind]) {
        homeModuleOrderRaw = modules.map(\.rawValue).joined(separator: ",")
    }

    private func openHomeItem(_ item: MediaItem) {
        if item.type == .music {
            appState.play(item)
        } else if appState.isAlbumItem(item) {
            // 首页的全库收藏可包含相册来源；相册项没有影视详情页语义，进入相册总览。
            onOpenAlbumSection(.all)
        } else {
            appState.presentDetail(item, from: SidebarDestination.home.id, anchorID: item.id)
        }
    }

    private func openPhotoWallItem(_ item: MediaItem) {
        let items = photoWallItems
        photoWallViewerIndex = items.firstIndex(where: { $0.id == item.id })
    }

    private var secondaryOverviewBoards: [HomeOverviewBoardModel] {
        let primaryIDs: Set<String> = [
            "continue",
            "nextUp",
            "recommend",
            "high-rated-series"
        ]
        return overviewBoards.filter { board in
            !primaryIDs.contains(board.id) && !board.items.isEmpty
        }
    }

    private var seriesRecommendationItems: [MediaItem] {
        if let items = overviewBoards.first(where: { $0.id == "high-rated-series" })?.items, !items.isEmpty {
            return Array(items.prefix(24))
        }
        if let items = overviewBoards.first(where: { $0.id == "recommend" })?.items {
            let series = items.filter { seriesRecommendationTypes.contains($0.type) || $0.type == .episode }
            if !series.isEmpty { return Array(series.prefix(24)) }
        }
        return Array(appState.homeVideoItems.filter { seriesRecommendationTypes.contains($0.type) }.prefix(24))
    }

    private var continueWatchingSeriesItems: [MediaItem] {
        if let items = overviewBoards.first(where: { $0.id == "continue" })?.items, !items.isEmpty {
            let seriesItems = items.filter { seriesRecommendationTypes.contains($0.type) || $0.type == .episode }
            return Array((seriesItems.isEmpty ? items : seriesItems).prefix(24))
        }
        var seen = Set<String>()
        var combined: [MediaItem] = []
        for item in appState.continueWatchingItems + appState.nextUpItems
            where (seriesRecommendationTypes.contains(item.type) || item.type == .episode) && seen.insert(item.id).inserted {
            combined.append(item)
        }
        if combined.isEmpty {
            for item in appState.continueWatchingItems where seen.insert(item.id).inserted {
                combined.append(item)
            }
        }
        return Array(combined.prefix(24))
    }

    private var recentSeriesItems: [MediaItem] {
        if let items = overviewBoards.first(where: { $0.id == "recent-series" })?.items, !items.isEmpty {
            return Array(items.prefix(24))
        }
        return Array(appState.homeVideoItems
            .filter { seriesRecommendationTypes.contains($0.type) }
            .prefix(24))
    }

    private var highRatedFeaturedItems: [MediaItem] {
        if let boardItems = overviewBoards.first(where: { $0.id == "recent-high-rated" })?.items, !boardItems.isEmpty {
            return Array(boardItems.prefix(24))
        }
        let themeBoards = overviewBoards.filter { $0.id.hasPrefix("theme-") }.flatMap(\.items)
        if !themeBoards.isEmpty {
            return Array(themeBoards.prefix(24))
        }
        return Array(appState.homeVideoItems
            .filter { ($0.rating ?? 0) >= 8.0 }
            .sorted { lhs, rhs in
                let lhsRating = lhs.rating ?? 0
                let rhsRating = rhs.rating ?? 0
                if lhsRating != rhsRating { return lhsRating > rhsRating }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(24))
    }

    private var musicRecommendationItems: [MediaItem] {
        // 全曲库打分 + 贪心多样性挑选，代价随曲库线性放大；按快照键记忆化，
        // 避免每次 body 求值（滚动/悬停/播放态变化）都同步重算。
        HomeOverviewComputationCache.value("music-recommendation", key: overviewSnapshotKey) {
            let profile = musicRecommendationProfile()
            return rankedOverviewItems(from: musicRecommendationPlayableTracks, limit: 30) { track in
                musicRecommendationScore(for: track, profile: profile, daySeed: overviewDaySeed)
            }
        }
    }

    private var musicRecommendationPlayableTracks: [MediaItem] {
        appState.homeMusicPlayableTracks
    }

    private var musicStyleBuckets: [HomeMusicStyleBucket] {
        // 逐曲目风格分桶 + 每桶排序打分，属首页最重的同步计算之一；按快照键记忆化。
        HomeOverviewComputationCache.value("music-style-buckets", key: overviewSnapshotKey) {
            computeMusicStyleBuckets()
        }
    }

    private func computeMusicStyleBuckets() -> [HomeMusicStyleBucket] {
        var buckets: [String: (display: String, tracks: [MediaItem])] = [:]
        for track in musicRecommendationPlayableTracks {
            for token in musicStyleTokens(for: track) {
                if buckets[token.key] == nil {
                    buckets[token.key] = (token.display, [])
                }
                buckets[token.key]?.tracks.append(track)
            }
        }
        let profile = musicRecommendationProfile()
        return buckets.compactMap { key, value in
            let uniqueTracks = Array(Dictionary(grouping: value.tracks, by: \.id).compactMap { $0.value.first })
            guard uniqueTracks.count >= 3 else { return nil }
            let rankedTracks = rankedOverviewItems(from: uniqueTracks, limit: 30) { track in
                musicRecommendationScore(for: track, profile: profile, daySeed: overviewDaySeed) +
                stableDailyValue(forID: track.id, daySeed: overviewDaySeed, salt: "music-style-\(key)") * 1.2
            }
            let affinity = (profile.genreWeights[key] ?? 0) / max(profile.maxGenreWeight, 1)
            let score = min(Double(uniqueTracks.count), 36) * 0.10 +
                min(affinity, 1.8) * 1.35 +
                stableDailyValue(forID: key, daySeed: overviewDaySeed, salt: "style-playlist") * 2.4
            return HomeMusicStyleBucket(
                id: "style.\(key)",
                key: key,
                title: value.display,
                tracks: rankedTracks,
                score: score
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private var continueListeningItems: [MediaItem] {
        appState.homeContinueListeningTracks
    }

    private var recommendedPlaylistSummary: HomePlaylistSummary? {
        if let bucket = musicStyleBuckets.first {
            let covers = Array(bucket.tracks.prefix(6))
            return HomePlaylistSummary(
                id: "synthetic.style.\(bucket.key)",
                title: "\(bucket.title)精选",
                subtitle: "\(bucket.tracks.count) 首 · 风格歌单 · 每日换新",
                posterPaths: covers.compactMap(\.posterPath),
                trackIDs: bucket.tracks.map(\.id)
            )
        }
        let playlists = appState.musicPlaylists.filter { !$0.itemIDs.isEmpty }
        let selected = playlists.sorted { lhs, rhs in
            let left = stableDailyValue(forID: lhs.id, daySeed: overviewDaySeed, salt: "playlist") + recencyScore(for: lhs.updatedAt, horizonDays: 120)
            let right = stableDailyValue(forID: rhs.id, daySeed: overviewDaySeed, salt: "playlist") + recencyScore(for: rhs.updatedAt, horizonDays: 120)
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.first
        guard let selected else {
            let tracks = Array(musicRecommendationItems.prefix(6))
            guard !tracks.isEmpty else { return nil }
            let genreName = musicRecommendationProfile().strongestGenreDisplayName
            return HomePlaylistSummary(
                id: "synthetic.recommend",
                title: appState.localized("今日推荐"),
                subtitle: genreName.map { "\($0) · 30 首歌" } ?? "30 首歌 · 每日换新",
                posterPaths: tracks.compactMap(\.posterPath),
                trackIDs: musicRecommendationItems.map(\.id)
            )
        }
        let tracks = selected.itemIDs.compactMap { appState.item(withID: $0) }
        return HomePlaylistSummary(
            id: selected.id,
            title: selected.name,
            subtitle: "\(selected.itemIDs.count) 首歌",
            posterPaths: tracks.compactMap(\.posterPath),
            trackIDs: tracks.map(\.id)
        )
    }

    private func playPlaylistSummary(_ summary: HomePlaylistSummary) {
        let summaryTracks = summary.trackIDs.compactMap { appState.item(withID: $0) }
        if !summaryTracks.isEmpty {
            appState.replaceMusicQueueAndPlay(summaryTracks)
            return
        }
        if let playlist = appState.musicPlaylists.first(where: { $0.id == summary.id }) {
            let playlistTracks = playlist.itemIDs.compactMap { appState.item(withID: $0) }
            appState.replaceMusicQueueAndPlay(playlistTracks)
            return
        }
        if !musicRecommendationItems.isEmpty {
            appState.replaceMusicQueueAndPlay(musicRecommendationItems)
        }
    }

    private func musicRecommendationProfile() -> HomeRecommendationProfile {
        var profile = HomeRecommendationProfile()
        let now = Date()
        let signalTracks = appState.homeMusicSignalTracks
        for track in signalTracks {
            let tokens = musicTasteTokens(for: track)
            guard !tokens.isEmpty else { continue }
            var weight = Double(track.playCount ?? 0) * 0.35
            if track.favorite { weight += 3.0 }
            if let rating = track.userRating, rating > 0 { weight += normalizedUserScore(rating) * 0.45 }
            if let lastPlayedAt = track.lastPlayedAt {
                let days = max(0, now.timeIntervalSince(lastPlayedAt) / 86_400)
                weight += max(0, 2.2 - days / 28)
            }
            guard weight > 0 else { continue }
            profile.signalItemIDs.insert(track.id)
            for token in tokens {
                profile.genreWeights[token.key, default: 0] += weight / Double(tokens.count)
                if profile.genreDisplayNames[token.key] == nil {
                    profile.genreDisplayNames[token.key] = token.display
                }
            }
        }
        return profile
    }

    private func musicRecommendationScore(for track: MediaItem, profile: HomeRecommendationProfile, daySeed: Int) -> Double {
        var score = 0.0
        let playCount = track.playCount ?? 0
        score += min(Double(playCount), 40) * 0.08
        score += playCount <= 2 ? 0.48 : 0
        score += track.favorite ? 1.6 : 0
        score += normalizedUserScore(track.userRating) * 0.20
        score += recencyScore(for: track.lastPlayedAt, horizonDays: 45) * 1.1
        score += recencyScore(for: track.updatedAt, horizonDays: 180) * 0.35
        score += musicAffinityScore(for: track, profile: profile)
        score += stableDailyVariation(for: track, daySeed: daySeed) * 2.2
        if let duration = track.duration, duration.isFinite, duration >= 60, duration <= 900 {
            score += 0.18
        }
        if let lastPlayedAt = track.lastPlayedAt, Date().timeIntervalSince(lastPlayedAt) < 20 * 60 * 60 {
            score -= 0.82
        }
        if profile.signalItemIDs.contains(track.id), playCount > 8 {
            score -= 0.55
        }
        return score
    }

    private func musicAffinityScore(for track: MediaItem, profile: HomeRecommendationProfile) -> Double {
        guard profile.hasSignals, profile.maxGenreWeight > 0 else { return 0 }
        let raw = musicTasteTokens(for: track).reduce(0.0) { partial, token in
            partial + (profile.genreWeights[token.key] ?? 0)
        }
        return min(raw / profile.maxGenreWeight, 2.4) * 1.45
    }

    private func musicTasteTokens(for track: MediaItem) -> [(key: String, display: String)] {
        let styleTokens = musicStyleTokens(for: track)
        if !styleTokens.isEmpty {
            return styleTokens
        }
        let values = [track.artist, track.album]
        return normalizedMusicTokens(from: values)
    }

    private func musicStyleTokens(for track: MediaItem) -> [(key: String, display: String)] {
        normalizedMusicTokens(from: [track.genre])
    }

    private func normalizedMusicTokens(from values: [String?]) -> [(key: String, display: String)] {
        var seen = Set<String>()
        return values.flatMap { value -> [String] in
            guard let value else { return [] }
            return value.components(separatedBy: CharacterSet(charactersIn: ",，、/|;；·&＋+"))
        }
        .compactMap { raw -> (key: String, display: String)? in
            let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard display.count >= 2 else { return nil }
            let key = display
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return (key, display)
        }
    }

    private var photoWallTheme: HomePhotoWallTheme {
        // 相册全量打分 + O(候选×张数) 贪心多样性挑选，是首页滚动卡顿的主要热点；
        // 按快照键（含 3 小时桶）记忆化，桶未跨界时直接复用同一结果。
        HomeOverviewComputationCache.value("photo-wall-theme", key: overviewSnapshotKey) {
            computePhotoWallTheme()
        }
    }

    private func computePhotoWallTheme() -> HomePhotoWallTheme {
        let all = appState.albumItems
        guard !all.isEmpty else {
            return HomePhotoWallTheme(title: "照片墙", badge: "暂无照片", items: [])
        }
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day], from: Date())
        let currentMonth = today.month ?? 1
        let refreshSeed = photoWallRefreshSeed
        let variants: [(title: String, badge: String, items: [MediaItem])] = [
            ("那年今日", "同日回忆", all.filter {
                let comps = calendar.dateComponents([.month, .day], from: $0.createdAt)
                return comps.month == today.month && comps.day == today.day
            }),
            ("本季色彩", seasonBadge(for: currentMonth), all.filter {
                seasonIndex(for: calendar.component(.month, from: $0.createdAt)) == seasonIndex(for: currentMonth)
            }),
            ("喜欢瞬间", "收藏照片", all.filter(\.favorite)),
            ("最近回忆", "最近入库", all),
            ("此刻照片墙", "3 小时换新", all)
        ]
        let offset = refreshSeed % variants.count
        let ordered = variants.indices.map { variants[($0 + offset) % variants.count] }
        let selected = ordered.first { $0.items.count >= 6 } ?? ordered.first { !$0.items.isEmpty } ?? variants[3]
        let ranked = rankedOverviewItems(from: selected.items, limit: 36) { item in
            let itemMonth = calendar.component(.month, from: item.createdAt)
            let itemDay = calendar.component(.day, from: item.createdAt)
            let sameDayBonus = (itemMonth == today.month && itemDay == today.day) ? 1.4 : 0
            let seasonBonus = seasonIndex(for: itemMonth) == seasonIndex(for: currentMonth) ? 0.42 : 0
            return recencyScore(for: item.createdAt, horizonDays: selected.title == "最近回忆" ? 90 : 720) * 0.86 +
            sameDayBonus +
            seasonBonus +
            (item.favorite ? 1.05 : 0) +
            stableDailyValue(forID: item.id, daySeed: refreshSeed, salt: "photo-wall") * 2.7
        }
        // 供排布挑选的候选池比实际展示格数(12)多一倍：HomeVividPhotoWall.arrangedItems
        // 本就按"每个格子目标宽高比 × 2"的候选量去挑最贴近的图（横向格配横向图、纵向格配纵向图），
        // 但如果这里只给刚好 12 张，候选量恒等于格数，算法没有任何"挑"的余地，退化成按原顺序摆放。
        // 展示数量与角标文案仍按 12 张收口，只是给排布算法更大的原始素材池。
        let displayLimit = 12
        let pool = diversifiedPhotoWallItems(ranked, limit: displayLimit * 2, seed: refreshSeed)
        let displayCount = min(pool.count, displayLimit)
        return HomePhotoWallTheme(title: selected.title, badge: "\(selected.badge) · \(displayCount) 张", items: pool)
    }

    private func diversifiedPhotoWallItems(_ candidates: [MediaItem], limit: Int, seed: Int) -> [MediaItem] {
        var remaining = candidates
        var selected: [MediaItem] = []
        var dayCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        let calendar = Calendar.current

        while !remaining.isEmpty, selected.count < limit {
            let bestIndex = remaining.indices.max { lhsIndex, rhsIndex in
                let lhs = photoWallDiversityScore(
                    remaining[lhsIndex],
                    calendar: calendar,
                    dayCounts: dayCounts,
                    sourceCounts: sourceCounts,
                    seed: seed
                )
                let rhs = photoWallDiversityScore(
                    remaining[rhsIndex],
                    calendar: calendar,
                    dayCounts: dayCounts,
                    sourceCounts: sourceCounts,
                    seed: seed
                )
                if lhs != rhs { return lhs < rhs }
                return remaining[lhsIndex].createdAt < remaining[rhsIndex].createdAt
            }
            guard let bestIndex else { break }
            let item = remaining.remove(at: bestIndex)
            selected.append(item)
            dayCounts[photoWallDayKey(for: item, calendar: calendar), default: 0] += 1
            if let sourcePath = item.sourcePath, !sourcePath.isEmpty {
                sourceCounts[sourcePath, default: 0] += 1
            }
        }
        return selected
    }

    private func photoWallDiversityScore(
        _ item: MediaItem,
        calendar: Calendar,
        dayCounts: [String: Int],
        sourceCounts: [String: Int],
        seed: Int
    ) -> Double {
        var score = stableDailyValue(forID: item.id, daySeed: seed, salt: "photo-wall-diversity")
        score += item.favorite ? 0.24 : 0
        score += recencyScore(for: item.createdAt, horizonDays: 900) * 0.22
        score -= Double(dayCounts[photoWallDayKey(for: item, calendar: calendar)] ?? 0) * 0.52
        if let sourcePath = item.sourcePath {
            score -= Double(sourceCounts[sourcePath] ?? 0) * 0.18
        }
        if item.type == .homeVideo {
            score += 0.08
        }
        return score
    }

    private func photoWallDayKey(for item: MediaItem, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: item.createdAt)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private var photoWallItems: [MediaItem] {
        photoWallTheme.items
    }

    private var dashboardSourceGroups: [HomeVividSourceGroup] {
        let visibleSources = dashboardVisibleSources
        guard !visibleSources.isEmpty else { return [] }

        let offlineIDs = Set(dashboardOfflineSources.map(\.id))
        // 全库条目 × 来源归属解析，随库体量线性放大；按快照键记忆化（在线状态仍取实时值）。
        let countsBySourceID = HomeOverviewComputationCache.value("dashboard-source-counts", key: overviewSnapshotKey) {
            var counts: [String: Int] = [:]
            for item in dashboardAllPublicItems {
                guard let source = appState.source(for: item),
                      visibleSources.contains(where: { $0.id == source.id }) else { continue }
                counts[source.id, default: 0] += 1
            }
            return counts
        }

        return visibleSources.enumerated().map { index, source in
            HomeVividSourceGroup(
                id: source.id,
                title: source.name,
                count: countsBySourceID[source.id] ?? 0,
                tint: dashboardSourceGroupTint(for: source, index: index),
                isOnline: !offlineIDs.contains(source.id)
            )
        }
    }

    private var dashboardAllPublicItems: [MediaItem] {
        var seen = Set<String>()
        let combined = appState.homeVideoItems + appState.homeMusicPlayableTracks + appState.albumItems
        return combined.filter { item in
            guard appState.privacyUnlocked || item.type != .privateCollection else { return false }
            return seen.insert(item.id).inserted
        }
    }

    private var dashboardTaskSummaries: [HomeVividTaskSummary] {
        appState.backgroundTasks
            .sorted { lhs, rhs in
                let lhsDate = lhs.finishedAt ?? lhs.startedAt
                let rhsDate = rhs.finishedAt ?? rhs.startedAt
                if lhs.state.isActive != rhs.state.isActive {
                    return lhs.state.isActive && !rhs.state.isActive
                }
                return lhsDate > rhsDate
            }
            .prefix(3)
            .map { task in
                HomeVividTaskSummary(
                    id: task.id,
                    title: task.hidesDetail ? task.kind.title : task.title,
                    detail: task.hidesDetail ? appState.localized("任务正在后台处理。") : (task.detail ?? task.kind.title),
                    stateTitle: task.state.title,
                    progress: task.progress,
                    isActive: task.state.isActive,
                    tint: dashboardTaskTint(for: task)
                )
            }
    }

    private var dashboardSourceHealthPercent: Int {
        let total = max(dashboardVisibleSources.count, 1)
        let offlinePenalty = min(dashboardOfflineSources.count, total) * 22
        let excludedPenalty = dashboardVisibleSources.filter { !$0.includeInHealthCheck }.count * 4
        return max(35, min(100, 100 - offlinePenalty - excludedPenalty))
    }

    private var dashboardMetadataHealthPercent: Int {
        let totalItems = max(dashboardAllPublicItems.count, 1)
        let issueCount =
            dashboardPublicHealthItems(appState.missingMetadataItems).count +
            dashboardPublicHealthItems(appState.detailMetadataGapItems).count +
            dashboardPublicHealthItems(appState.unhealthyURLItems).count
        let ratioPenalty = Int((Double(issueCount) / Double(totalItems) * 100).rounded())
        let cappedPenalty = min(55, max(ratioPenalty, min(issueCount, 12) * 3))
        return max(45, min(100, 100 - cappedPenalty))
    }

    private func dashboardSourceGroupTitle(for kind: MediaSourceKind) -> String {
        switch kind {
        case .local: return appState.localized("本地硬盘")
        case .smb: return "NAS · SMB"
        case .ftp: return "FTP"
        case .emby: return "EMBY 服务器"
        case .jellyfin: return "Jellyfin 服务器"
        case .plex: return "Plex 服务器"
        case .mlink: return "MediaLIB 服务器"
        case .url: return appState.localized("网络视频")
        }
    }

    private func dashboardSourceGroupTint(for source: MediaSource, index: Int) -> Color {
        let palette: [Color] = [
            HomeVividTokens.mint,
            HomeVividTokens.pink,
            HomeVividTokens.blue,
            HomeVividTokens.orange,
            HomeVividTokens.cyan,
            HomeVividTokens.violet,
            HomeVividTokens.indigo,
            HomeVividTokens.color("F97316"),
            HomeVividTokens.color("14B8A6"),
            HomeVividTokens.color("A855F7")
        ]
        // 用溢出安全的运算合成哈希：hashValue 是全域 Int，直接相加/取 abs 会在
        // 溢出或命中 Int.min 时触发算术溢出陷阱崩溃，改用 &+/&* 并手动取非负余数。
        let combined = source.id.hashValue &+ source.name.hashValue &+ (index &* 31)
        let bucket = combined % palette.count
        return palette[bucket < 0 ? bucket + palette.count : bucket]
    }

    private func dashboardTaskTint(for task: BackgroundTaskSnapshot) -> Color {
        switch task.kind {
        case .fullScan, .incrementalScan: return HomeVividTokens.blue
        case .embySync: return HomeVividTokens.pink
        case .artworkWarmup: return HomeVividTokens.cyan
        case .cleanup: return HomeVividTokens.mint
        case .videoCache: return HomeVividTokens.orange
        case .metadataSupplement: return HomeVividTokens.violet
        case .keyframeStoryboard, .markerAnalysis, .musicIndex: return HomeVividTokens.cyan
        }
    }

    private var dashboardSourceSummaries: [HomeDashboardSourceSummary] {
        let offlineIDs = Set(appState.offlineSources.map(\.id))
        return dashboardVisibleSources
            .sorted { lhs, rhs in
                let lhsRank = dashboardSourceRank(lhs, offlineIDs: offlineIDs)
                let rhsRank = dashboardSourceRank(rhs, offlineIDs: offlineIDs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(4)
            .map { dashboardSourceSummary(for: $0, offlineIDs: offlineIDs) }
    }

    private var dashboardVisibleSources: [MediaSource] {
        appState.sources.filter { $0.mediaType != .privateCollection }
    }

    private func dashboardSourceRank(_ source: MediaSource, offlineIDs: Set<String>) -> Int {
        if offlineIDs.contains(source.id) { return 0 }
        if !source.includeInHealthCheck { return 1 }
        return 2
    }

    private func dashboardSourceSummary(for source: MediaSource, offlineIDs: Set<String>) -> HomeDashboardSourceSummary {
        let isOffline = offlineIDs.contains(source.id)
        let health: Double
        let status: String
        let tint: Color
        if isOffline {
            health = 0.42
            status = appState.localized("有错误")
            tint = AuroraPalette.magenta
        } else if !source.includeInHealthCheck {
            health = 0.76
            status = appState.localized("已排除")
            tint = AuroraPalette.orange
        } else {
            health = 1.0
            status = appState.localized("在线")
            tint = AuroraPalette.teal
        }
        return HomeDashboardSourceSummary(
            id: source.id,
            title: source.name,
            detail: "\(source.sourceKind.displayName) · \(source.mediaType.displayName)",
            statusTitle: status,
            systemImage: dashboardSourceIcon(for: source),
            health: health,
            tint: tint
        )
    }

    private func dashboardSourceIcon(for source: MediaSource) -> String {
        switch source.sourceKind {
        case .local: return source.mediaType == .music ? "music.note" : "externaldrive"
        case .smb, .ftp: return "network"
        case .emby, .jellyfin, .plex, .mlink: return "server.rack"
        case .url: return "link"
        }
    }

    private var dashboardSpotlight: HomeDashboardSpotlight {
        if let task = appState.backgroundTasks.first(where: { $0.state.isActive }) {
            let safeTitle = task.hidesDetail ? task.kind.title : task.title
            let safeDetail = task.hidesDetail ? appState.localized("任务正在后台处理。") : (task.detail ?? task.state.title)
            return HomeDashboardSpotlight(
                title: safeTitle,
                subtitle: safeDetail,
                systemImage: task.kind.systemImage,
                tint: AuroraPalette.blue,
                progress: task.progress ?? 0.04
            )
        }

        let issueCount = dashboardIssueCount
        if issueCount > 0 {
            return HomeDashboardSpotlight(
                title: appState.localized("媒体库需要处理"),
                subtitle: appState.localized("优先查看离线来源、失效路径和资料缺口。"),
                systemImage: "stethoscope",
                tint: AuroraPalette.orange,
                progress: nil,
                primaryMetric: "\(issueCount)",
                primaryLabel: appState.localized("待处理"),
                secondaryMetric: "\(dashboardOverallHealthPercent)%",
                secondaryLabel: appState.localized("健康度")
            )
        }

        let recentPublicCount = dashboardRecentPublicItems.count
        if recentPublicCount > 0 {
            return HomeDashboardSpotlight(
                title: appState.localized("最近入库"),
                subtitle: appState.localized("片库保持更新，最近添加内容可继续整理。"),
                systemImage: "clock.badge.plus",
                tint: AuroraPalette.orange,
                progress: nil,
                primaryMetric: "\(recentPublicCount)",
                primaryLabel: appState.localized("最近添加"),
                secondaryMetric: "\(dashboardOverallHealthPercent)%",
                secondaryLabel: appState.localized("健康度")
            )
        }

        return HomeDashboardSpotlight(
            title: appState.localized("片库状态良好"),
            subtitle: appState.localized("当前没有发现需要立即处理的健康问题。"),
            systemImage: "checkmark.seal",
            tint: AuroraPalette.teal,
            progress: nil,
            primaryMetric: "\(dashboardOverallHealthPercent)%",
            primaryLabel: appState.localized("健康度"),
            secondaryMetric: "\(dashboardOnlineSourceCount)",
            secondaryLabel: appState.localized("在线来源")
        )
    }

    private var dashboardIssueCount: Int {
        dashboardOfflineSources.count +
            dashboardPublicHealthItems(appState.missingFileItems).count +
            dashboardPublicDuplicateGroups.count +
            dashboardPublicHealthItems(appState.missingMetadataItems).count +
            dashboardPublicHealthItems(appState.detailMetadataGapItems).count +
            dashboardPublicHealthItems(appState.unhealthyURLItems).count
    }

    private var dashboardOfflineSources: [MediaSource] {
        appState.offlineSources.filter { source in
            appState.privacyUnlocked || source.mediaType != .privateCollection
        }
    }

    private var dashboardPublicDuplicateGroups: [[MediaItem]] {
        appState.duplicateTitleGroups
            .map(dashboardPublicHealthItems)
            .filter { $0.count > 1 }
    }

    private func dashboardPublicHealthItems(_ items: [MediaItem]) -> [MediaItem] {
        appState.privacyUnlocked ? items : items.filter { $0.type != .privateCollection }
    }

    private var dashboardRecentPublicItems: [MediaItem] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return appState.homeVideoItems.filter { item in
            item.updatedAt >= cutoff && (appState.privacyUnlocked || item.type != .privateCollection)
        }
    }

    private var dashboardOnlineSourceCount: Int {
        let offlineIDs = Set(dashboardOfflineSources.map(\.id))
        return dashboardVisibleSources.filter { !offlineIDs.contains($0.id) }.count
    }

    private var dashboardOverallHealthPercent: Int {
        let blended = Double(dashboardSourceHealthPercent) * 0.55 + Double(dashboardMetadataHealthPercent) * 0.45
        let healthIssuePenalty = min(
            dashboardPublicHealthItems(appState.missingFileItems).count + dashboardPublicDuplicateGroups.count,
            8
        )
        return max(42, min(100, Int(blended.rounded()) - healthIssuePenalty * 2))
    }

    private func displayName(for tab: HomeTab) -> String {
        tab == .privacy ? appState.settings.privacyVaultName : appState.localized(tab.displayName)
    }

    private func baseHomeItems(for tab: HomeTab) -> [MediaItem] {
        switch tab {
        case .overview:
            return []
        case .nextUp:
            return appState.nextUpItems
        case .continueWatching:
            return Array(appState.continueWatchingItems.prefix(48))
        case .offline:
            return appState.homeOfflineVideoItems
        case .recent:
            return appState.homeVideoItems
        case .movies:
            return appState.homeVideoItems
        case .tvShows:
            return appState.homeVideoItems
        case .anime:
            return appState.homeVideoItems
        case .documentaries:
            return appState.homeVideoItems
        case .variety:
            return appState.homeVideoItems
        case .homeVideos:
            return appState.homeVideoItems
        case .music:
            return appState.musicItems(for: .songs)
        case .other:
            return appState.homeVideoItems
        case .favorites:
            return appState.homeVideoItems
        case .unwatched:
            return appState.homeVideoItems
        case .privacy:
            return appState.privateTopLevelItems
        }
    }

    private func displayedHomeItems(for tab: HomeTab) -> [MediaItem] {
        visibleHomeItemsKey == homeItemsKey(for: tab) ? visibleHomeItems : []
    }

    private func visibleHomeItemsAreOutOfDate(for tab: HomeTab) -> Bool {
        visibleHomeItemsKey != homeItemsKey(for: tab)
    }

    private func homeItemsKey(for tab: HomeTab) -> String {
        [
            tab.rawValue,
            searchApplies(to: tab) ? committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            "\(appState.libraryRevision)",
            "\(appState.favoriteRevision)",
            "\(appState.watchlistRevision)",
            "\(appState.ratingRevision)",
            "\(appState.videoCacheRevision)",
            "\(appState.privacyUnlocked)",
            "\(appState.settings.watchedThreshold)"
        ].joined(separator: "|")
    }

    private func searchApplies(to tab: HomeTab) -> Bool {
        switch tab {
        case .overview, .nextUp, .continueWatching:
            return false
        default:
            return true
        }
    }

    private func itemLimit(for tab: HomeTab) -> Int? {
        switch tab {
        case .recent:
            return 48
        default:
            return nil
        }
    }

    private func contentFilter(for tab: HomeTab) -> HomeContentFilter {
        switch tab {
        case .movies:
            return .mediaType(.movie)
        case .tvShows:
            return .mediaType(.tvShow)
        case .anime:
            return .mediaType(.anime)
        case .documentaries:
            return .mediaType(.documentary)
        case .variety:
            return .mediaType(.variety)
        case .homeVideos:
            return .mediaType(.homeVideo)
        case .other:
            return .mediaType(.other)
        case .favorites:
            return .videoFavorites
        case .unwatched:
            return .unwatchedVideos
        default:
            return .none
        }
    }

    private func emptyMessage(for tab: HomeTab) -> String {
        switch tab {
        case .privacy:
            return appState.localized("解锁后展示保险库内容。")
        case .offline:
            return appState.localized("右键视频或单集选择缓存后，离线副本会出现在这里。")
        default:
            return appState.localized("接入媒体源并完成扫描后，内容会自动归入此页。")
        }
    }

    private func refreshHomeItems(for tab: HomeTab, deferred: Bool = false) {
        homeContentRefreshTask?.cancel()
        guard tab != .overview else {
            visibleHomeItems = []
            visibleHomeItemsKey = homeItemsKey(for: tab)
            isPreparingHomeItems = false
            return
        }
        if tab == .privacy && (!appState.privacyPINConfigured || !appState.privacyUnlocked) {
            visibleHomeItems = []
            visibleHomeItemsKey = homeItemsKey(for: tab)
            isPreparingHomeItems = false
            return
        }

        let key = homeItemsKey(for: tab)
        let input = HomeContentSnapshotInput(
            items: baseHomeItems(for: tab),
            filter: contentFilter(for: tab),
            searchText: committedSearchText,
            appliesSearch: searchApplies(to: tab),
            limit: itemLimit(for: tab),
            watchedThreshold: appState.settings.watchedThreshold
        )
        isPreparingHomeItems = true
        homeContentRefreshTask = Task { @MainActor in
            if deferred {
                await Task.yield()
            }
            let items = await Task.detached(priority: .userInitiated) {
                HomeContentSnapshotBuilder.items(from: input)
            }.value
            guard !Task.isCancelled, key == homeItemsKey(for: tab) else { return }
            visibleHomeItems = items
            visibleHomeItemsKey = key
            isPreparingHomeItems = false
        }
    }

    private func scheduleHomeSearchRefresh() {
        homeSearchRefreshTask?.cancel()
        let targetTab = currentTab
        let pendingSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        homeSearchRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard currentTab == targetTab else { return }
            committedSearchText = pendingSearchText
            refreshHomeItems(for: targetTab, deferred: true)
        }
    }

    private func commitHomeSearch() {
        homeSearchRefreshTask?.cancel()
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        committedSearchText = normalizedSearchText
        refreshHomeItems(for: currentTab, deferred: true)
    }

    private var homePlaybackTraceItems: [MediaItem] {
        switch currentTab {
        case .continueWatching:
            return displayedHomeItems(for: currentTab).filter(\.hasPlaybackTrace)
        default:
            return []
        }
    }

    private var showsPlaybackHistoryAction: Bool {
        switch currentTab {
        case .continueWatching:
            return true
        default:
            return false
        }
    }

    private var overviewBoards: [HomeOverviewBoardModel] {
        overviewBoardsKey == overviewSnapshotKey ? overviewBoardsSnapshot : []
    }

    private var overviewSnapshotKey: String {
        [
            "\(appState.libraryRevision)",
            "\(appState.favoriteRevision)",
            "\(appState.watchlistRevision)",
            "\(appState.ratingRevision)",
            "\(appState.videoCacheRevision)",
            "\(appState.settings.watchedThreshold)",
            appState.settings.appLanguage.rawValue,
            "\(overviewDaySeed)",
            // 照片墙 3 小时桶直接入键：系统睡眠会拖延定时循环，唤醒/激活时的
            // 非强制刷新靠键变化即可感知「跨天/跨桶」，不再依赖定时器准点触发。
            "\(photoWallRefreshSeed)",
            "\(homeTimeRefreshToken)"
        ].joined(separator: "|")
    }

    private var overviewDaySeed: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    }

    private var photoWallRefreshSeed: Int {
        let hourBucket = Calendar.current.component(.hour, from: Date()) / 3
        return overviewDaySeed * 8 + hourBucket
    }

    private func refreshOverviewBoardsIfNeeded(force: Bool = false) {
        let key = overviewSnapshotKey
        guard force || overviewBoardsKey != key else { return }
        overviewBoardsRefreshTask?.cancel()
        let input = HomeOverviewSnapshotInput(
            daySeed: overviewDaySeed,
            now: Date(),
            language: appState.settings.appLanguage,
            watchedThreshold: appState.settings.watchedThreshold,
            visibleVideos: overviewCandidateVideos(),
            continueWatchingItems: appState.continueWatchingItems,
            nextUpItems: appState.nextUpItems,
            offlineItems: appState.homeOfflineVideoItems,
            publishedBoards: publishedCollectionBoards(),
            backdropItemIDs: Set(appState.homeVideoItems.compactMap { item in
                hasSyncLandscape(item) ? item.id : nil
            })
        )
        overviewBoardsRefreshTask = Task { @MainActor in
            await Task.yield()
            let boards = await Task.detached(priority: .utility) {
                HomeOverviewSnapshotBuilder.makeBoards(from: input)
            }.value
            guard !Task.isCancelled, key == overviewSnapshotKey else { return }
            overviewBoardsSnapshot = boards
            overviewBoardsKey = key
            HomeOverviewComputationCache.boards = boards
            HomeOverviewComputationCache.boardsKey = key
        }
    }

    private func startHomeTimeRefreshLoop() {
        homeTimeRefreshTask?.cancel()
        homeTimeRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                let seconds = secondsUntilNextHomeRefresh()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                homeTimeRefreshToken &+= 1
                refreshOverviewBoardsIfNeeded(force: true)
            }
        }
    }

    private func secondsUntilNextHomeRefresh(from date: Date = Date()) -> TimeInterval {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let nextBucketHour = ((hour / 3) + 1) * 3
        let target: Date?
        if nextBucketHour < 24 {
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = nextBucketHour
            components.minute = 0
            components.second = 0
            target = calendar.date(from: components)
        } else {
            target = calendar.nextDate(
                after: date,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            )
        }
        return max(60, target?.timeIntervalSince(date) ?? 10_800)
    }

    private func overviewCandidateVideos() -> [MediaItem] {
        appState.homeVideoItems.filter { item in
            item.type != .music &&
            item.type != .episode &&
            item.type != .privateCollection &&
            !(appState.isPrivateItem(item) && !appState.canDisplayPrivateItems)
        }
    }

    private func recommendationSubtitle(for profile: HomeRecommendationProfile) -> String {
        if let genreName = profile.strongestGenreDisplayName {
            if appState.settings.appLanguage == .zhHans {
                return "根据你的观看和标星偏好，优先挑 \(genreName) 与高分系列。"
            }
            return appState.localized("根据你的观看和标星偏好，优先挑高分系列。")
        }
        return appState.localized("先从库内高分系列和近期偏好里挑一些适合看的。")
    }

    private func recommendationProfile(from visibleVideos: [MediaItem]) -> HomeRecommendationProfile {
        var profile = HomeRecommendationProfile()
        let now = Date()
        let signalItems = visibleVideos + appState.continueWatchingItems + appState.nextUpItems
        var seen = Set<String>()

        for item in signalItems where seen.insert(item.id).inserted {
            let signalWeight = recommendationSignalWeight(for: item, now: now)
            guard signalWeight > 0 else { continue }
            profile.signalItemIDs.insert(item.id)
            profile.typeWeights[item.type, default: 0] += signalWeight * (seriesRecommendationTypes.contains(item.type) ? 1.1 : 0.8)

            let genres = overviewGenres(for: item)
            guard !genres.isEmpty else { continue }
            let perGenreWeight = signalWeight / Double(genres.count)
            for genre in genres {
                profile.genreWeights[genre.key, default: 0] += perGenreWeight
                if profile.genreDisplayNames[genre.key] == nil {
                    profile.genreDisplayNames[genre.key] = genre.display
                }
            }
        }

        return profile
    }

    private func recommendationSignalWeight(for item: MediaItem, now: Date) -> Double {
        guard item.type != .music, item.type != .privateCollection else { return 0 }
        var weight = 0.0
        if item.favorite { weight += 4.2 }
        if item.watchlist { weight += 1.4 }
        if let userRating = item.userRating, userRating.isFinite {
            if userRating >= 4 {
                weight += userRating * 1.15
            } else if userRating >= 3 {
                weight += userRating * 0.65
            }
        }
        if item.watched || item.playProgress >= appState.settings.watchedThreshold {
            weight += 3.0
        } else if item.playProgress >= 0.12 {
            weight += min(item.playProgress, 0.95) * 2.4
        }
        if let lastPlayedAt = item.lastPlayedAt {
            let days = max(0, now.timeIntervalSince(lastPlayedAt) / 86_400)
            if days <= 120 {
                weight += max(0, 1.6 - days / 75)
            }
        }
        if normalizedProviderScore(item.rating) >= 8.0 {
            weight += 0.5
        }
        return weight
    }

    private func recommendedOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile
    ) -> [MediaItem] {
        let preferred = visibleVideos.filter { item in
            !isFinishedForRecommendation(item) || item.watchlist
        }
        let base = preferred.count >= 6 ? preferred : visibleVideos
        return rankedOverviewItems(from: base, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed)
        }
    }

    private func themedHighRatedItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>
    ) -> [MediaItem] {
        guard let strongestGenre = profile.strongestGenre else { return [] }
        let candidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            overviewGenres(for: item).contains { $0.key == strongestGenre } &&
            isHighRatedForOverview(item) &&
            !isFinishedForRecommendation(item)
        }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 1.6
        }
    }

    private func highRatedSeriesOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>
    ) -> [MediaItem] {
        let candidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            seriesRecommendationTypes.contains(item.type) &&
            isHighRatedForOverview(item) &&
            !isFinishedForRecommendation(item)
        }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 1.2
        }
    }

    private func watchlistOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile
    ) -> [MediaItem] {
        let candidates = visibleVideos.filter { $0.watchlist }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 2.0
        }
    }

    private func recentHighRatedOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>
    ) -> [MediaItem] {
        let primaryCandidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            !seriesRecommendationTypes.contains(item.type) &&
            isHighRatedForOverview(item) &&
            !isFinishedForRecommendation(item)
        }
        let candidates = primaryCandidates.count >= 6
            ? primaryCandidates
            : visibleVideos.filter { item in
                !excludedIDs.contains(item.id) &&
                isHighRatedForOverview(item) &&
                !isFinishedForRecommendation(item)
        }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            normalizedProviderScore(item.rating) * 1.8 +
            normalizedUserScore(item.userRating) * 1.4 +
            recencyScore(for: item.updatedAt, horizonDays: 240) * 0.8 +
            stableDailyVariation(for: item, daySeed: daySeed) * 1.75
        }
    }

    private func offlineOverviewItems(
        daySeed: Int,
        profile: HomeRecommendationProfile
    ) -> [MediaItem] {
        let candidates = appState.homeOfflineVideoItems.filter { item in
            item.type != .music && item.type != .episode && item.type != .privateCollection
        }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 1.4
        }
    }

    private func rankedOverviewItems(
        from candidates: [MediaItem],
        limit: Int,
        score: (MediaItem) -> Double
    ) -> [MediaItem] {
        var seen = Set<String>()
        var remaining = candidates.compactMap { item -> (item: MediaItem, score: Double)? in
            guard seen.insert(item.id).inserted else { return nil }
            return (item, score(item))
        }
        var selected: [MediaItem] = []
        var typeCounts: [MediaType: Int] = [:]
        var genreCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]

        while !remaining.isEmpty, selected.count < limit {
            let bestIndex = remaining.indices.max { lhsIndex, rhsIndex in
                let lhs = diversityAdjustedScore(
                    item: remaining[lhsIndex].item,
                    baseScore: remaining[lhsIndex].score,
                    typeCounts: typeCounts,
                    genreCounts: genreCounts,
                    sourceCounts: sourceCounts
                )
                let rhs = diversityAdjustedScore(
                    item: remaining[rhsIndex].item,
                    baseScore: remaining[rhsIndex].score,
                    typeCounts: typeCounts,
                    genreCounts: genreCounts,
                    sourceCounts: sourceCounts
                )
                if lhs != rhs { return lhs < rhs }
                return remaining[lhsIndex].item.title.localizedCaseInsensitiveCompare(remaining[rhsIndex].item.title) == .orderedDescending
            }
            guard let bestIndex else { break }
            let picked = remaining.remove(at: bestIndex).item
            selected.append(picked)
            typeCounts[picked.type, default: 0] += 1
            for genre in overviewGenres(for: picked) {
                genreCounts[genre.key, default: 0] += 1
            }
            if let sourcePath = picked.sourcePath, !sourcePath.isEmpty {
                sourceCounts[sourcePath, default: 0] += 1
            }
        }
        return selected
    }

    private func diversityAdjustedScore(
        item: MediaItem,
        baseScore: Double,
        typeCounts: [MediaType: Int],
        genreCounts: [String: Int],
        sourceCounts: [String: Int]
    ) -> Double {
        var adjusted = baseScore
        adjusted -= Double(typeCounts[item.type] ?? 0) * 0.42
        let genres = overviewGenres(for: item)
        if !genres.isEmpty {
            let repeatedGenrePenalty = genres.reduce(0.0) { partial, genre in
                partial + Double(genreCounts[genre.key] ?? 0) * 0.28
            }
            adjusted -= min(repeatedGenrePenalty, 1.4)
        }
        if let sourcePath = item.sourcePath {
            adjusted -= Double(sourceCounts[sourcePath] ?? 0) * 0.16
        }
        return adjusted
    }

    private func publishedCollectionBoards() -> [HomeOverviewBoardModel] {
        let manualBoards = appState.videoManualCollections.compactMap { collection -> HomeOverviewBoardModel? in
            guard collection.showOnHome else { return nil }
            let items = appState.videoManualCollectionHomeItems(collection)
            guard !items.isEmpty else { return nil }
            return HomeOverviewBoardModel(
                id: "manual-\(collection.id)",
                title: collection.name,
                subtitle: appState.localized("手动整理的专题片单。"),
                systemImage: "rectangle.stack",
                items: items,
                emptyMessage: ""
            )
        }

        let smartBoards = appState.videoSmartCollections.compactMap { collection -> HomeOverviewBoardModel? in
            guard collection.showOnHome else { return nil }
            let items = appState.videoSmartCollectionHomeItems(collection)
            guard !items.isEmpty else { return nil }
            return HomeOverviewBoardModel(
                id: "smart-\(collection.id)",
                title: collection.name,
                subtitle: appState.localized("按规则自动更新。"),
                systemImage: "sparkles.rectangle.stack",
                items: items,
                emptyMessage: ""
            )
        }

        return manualBoards + smartBoards
    }

    private var seriesRecommendationTypes: Set<MediaType> {
        [.tvShow, .anime, .documentary, .variety]
    }

    private func recommendationScore(
        for item: MediaItem,
        profile: HomeRecommendationProfile,
        daySeed: Int
    ) -> Double {
        let providerScore = normalizedProviderScore(item.rating)
        let userScore = normalizedUserScore(item.userRating)
        let ratingScore = max(providerScore, userScore)
        var score = ratingScore * 1.25
        score += profileAffinityScore(for: item, profile: profile)
        score += seriesRecommendationTypes.contains(item.type) ? 1.35 : 0.3
        score += item.watchlist ? 1.0 : 0
        score += item.favorite ? 0.4 : 0
        score += item.playProgress <= 0.02 && !item.watched ? 0.75 : 0
        score += stableDailyVariation(for: item, daySeed: daySeed) * 1.65

        if item.watched || item.playProgress >= appState.settings.watchedThreshold {
            score -= 3.8
        } else if item.playProgress > 0.12 {
            score -= 1.2
        }
        if profile.signalItemIDs.contains(item.id), !item.watchlist {
            score -= 0.7
        }
        return score
    }

    private func profileAffinityScore(for item: MediaItem, profile: HomeRecommendationProfile) -> Double {
        guard profile.hasSignals else { return 0 }
        let genres = overviewGenres(for: item)
        let rawGenreWeight = genres.reduce(0.0) { partial, genre in
            partial + (profile.genreWeights[genre.key] ?? 0)
        }
        let genreScore: Double
        if profile.maxGenreWeight > 0 {
            genreScore = min(rawGenreWeight / profile.maxGenreWeight, 2.4) * 2.1
        } else {
            genreScore = 0
        }
        let typeWeight = profile.typeWeights[item.type] ?? 0
        let typeScore = profile.maxTypeWeight > 0 ? min(typeWeight / profile.maxTypeWeight, 1.4) * 1.35 : 0
        return genreScore + typeScore
    }

    private func stableDailyVariation(for item: MediaItem, daySeed: Int) -> Double {
        stableDailyValue(forID: item.id, daySeed: daySeed, salt: "item")
    }

    private func stableDailyValue(forID id: String, daySeed: Int, salt: String) -> Double {
        let hash = (id + "-\(salt)-\(daySeed)").unicodeScalars.reduce(UInt64(5381)) { partial, scalar in
            ((partial &* 33) &+ UInt64(scalar.value))
        }
        return Double(hash % 997) / 997.0
    }

    private func seasonIndex(for month: Int) -> Int {
        switch month {
        case 3...5: return 0
        case 6...8: return 1
        case 9...11: return 2
        default: return 3
        }
    }

    private func seasonBadge(for month: Int) -> String {
        switch seasonIndex(for: month) {
        case 0: return "春日记忆"
        case 1: return "夏日记忆"
        case 2: return "秋日记忆"
        default: return "冬日记忆"
        }
    }

    private func isHighRatedForOverview(_ item: MediaItem) -> Bool {
        normalizedProviderScore(item.rating) >= 7.3 || normalizedUserScore(item.userRating) >= 8
    }

    private func isFinishedForRecommendation(_ item: MediaItem) -> Bool {
        item.watched || item.playProgress >= appState.settings.watchedThreshold
    }

    private func normalizedProviderScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return rating <= 5 ? rating * 2 : min(rating, 10)
    }

    private func normalizedUserScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return min(rating, 5) * 2
    }

    private func recencyScore(for date: Date?, horizonDays: Double) -> Double {
        guard let date else { return 0 }
        let days = max(0, Date().timeIntervalSince(date) / 86_400)
        guard horizonDays > 0 else { return 0 }
        return max(0, 1 - min(days, horizonDays) / horizonDays)
    }

    private func overviewGenres(for item: MediaItem) -> [(key: String, display: String)] {
        guard let genre = item.genre else { return [] }
        let separators = CharacterSet(charactersIn: ",，、/|;；")
        var seen = Set<String>()
        return genre
            .components(separatedBy: separators)
            .compactMap { raw -> (key: String, display: String)? in
                let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !display.isEmpty else { return nil }
                let key = display
                    .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                    .lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { return nil }
                return (key, display)
            }
    }

    private func isDailyBannerQualified(_ item: MediaItem) -> Bool {
        normalizedProviderScore(item.rating) > 8 || normalizedUserScore(item.userRating) > 8
    }

    private func dailyBannerScore(for item: MediaItem, profile: HomeRecommendationProfile, daySeed: Int) -> Double {
        var score = 0.0
        score += normalizedProviderScore(item.rating) * 0.42
        score += normalizedUserScore(item.userRating) * 0.48
        score += profileAffinityScore(for: item, profile: profile) * 1.55
        score += hasSyncLandscape(item) ? 1.35 : -0.45
        score += item.watchlist ? 0.55 : 0
        score += item.favorite ? 0.42 : 0
        score += item.watched || item.playProgress >= appState.settings.watchedThreshold ? -0.92 : 0
        score += recencyScore(for: item.updatedAt, horizonDays: 540) * 0.28
        score += stableDailyValue(forID: item.id, daySeed: daySeed, salt: "daily-banner") * 3.2
        return score
    }

    // Hero 轮播是真正的每日推荐：评分 > 8 的高分视频优先，再按用户已看题材相似度、
    // 横版剧照可用性和每日稳定随机值排序。候选不足时才降级到普通高分/推荐看板。
    private var overviewFeaturedItems: [MediaItem] {
        if let items = overviewBoards.first(where: { $0.id == "daily-banner" })?.items, !items.isEmpty {
            return Array(items.prefix(7))
        }
        // 兜底路径按快照键记忆化：看板异步生成前，这段全量打分排序此前会在
        // 每次 body 求值时同步重跑，是切到首页首帧卡顿的来源之一。
        return HomeOverviewComputationCache.value("hero-fallback", key: overviewSnapshotKey) {
            let videos = overviewCandidateVideos()
            let profile = recommendationProfile(from: videos)
            let qualified = videos.filter { item in
                isDailyBannerQualified(item) &&
                item.type != .music &&
                !(appState.isPrivateItem(item) && !appState.canDisplayPrivateItems)
            }
            let fallback = highRatedFeaturedItems + (overviewBoards.first(where: { $0.id == "recommend" })?.items ?? [])
            var seen = Set<String>()
            let base = (qualified.count >= 3 ? qualified : qualified + fallback).filter { seen.insert($0.id).inserted }
            let ranked = base.sorted { lhs, rhs in
                let lhsScore = dailyBannerScore(for: lhs, profile: profile, daySeed: overviewDaySeed)
                let rhsScore = dailyBannerScore(for: rhs, profile: profile, daySeed: overviewDaySeed)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if hasSyncLandscape(lhs) != hasSyncLandscape(rhs) { return hasSyncLandscape(lhs) }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return Array(ranked.prefix(7))
        }
    }

    /// banner 横版图补抓任务的触发键：推荐条目集合变化时重新检查一次。
    private var overviewHeroWarmupKey: String {
        overviewFeaturedItems.map(\.id).joined(separator: "|")
    }

    private func hasSyncLandscape(_ item: MediaItem) -> Bool {
        if appState.cachedBackdropPath(for: item) != nil { return true }
        if let backdrop = item.backdropPath, !backdrop.isEmpty { return true }
        return false
    }

    private func firstBackdropPath(_ snapshot: MediaDetailSnapshot?) -> String? {
        guard let snapshot else { return nil }
        return snapshot.artwork
            .filter { ($0.kind == "backdrop" || $0.aspectRatio >= 1.45) && $0.aspectRatio >= 1.3 }
            .sorted { lhs, rhs in
                if (lhs.kind == "backdrop") != (rhs.kind == "backdrop") {
                    return lhs.kind == "backdrop"
                }
                if lhs.localPath != rhs.localPath {
                    return lhs.localPath != nil
                }
                if abs(lhs.aspectRatio - rhs.aspectRatio) > 0.08 {
                    return lhs.aspectRatio > rhs.aspectRatio
                }
                return lhs.order < rhs.order
            }
            .first
            .map { $0.localPath ?? $0.fullURL }
    }

    // banner 图：同步优先详情快照横版艺术图，再用条目 backdrop，兜底竖版封面。
    private func cachedBannerPath(for item: MediaItem) -> String? {
        if let url = appState.cachedBackdropPath(for: item) { return url }
        if let backdrop = item.backdropPath, !backdrop.isEmpty { return backdrop }
        return item.posterPath
    }

    private func overviewMetadata(for item: MediaItem) -> String {
        var parts: [String] = []
        if item.type == .episode {
            parts.append(item.episodeLabel)
        } else {
            parts.append(item.type.displayName)
        }
        if item.year != nil {
            parts.append(item.displayYear)
        }
        // 评分已由海报右上角徽标展示，元信息行不再重复（避免「★ 9.6」出现两次）。
        if item.playProgress > 0, item.playProgress < 0.98 {
            parts.append("\(appState.localized("已看")) \(Int((item.playProgress * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    private func normalizeSelectedTab() {
        if !enabledTabs.contains(selectedTab) {
            selectedTab = enabledTabs.first ?? .overview
        }
    }

    private var activeReturnContext: DetailReturnContext? {
        guard appState.selectedItem == nil,
              appState.detailReturnContext?.destinationID == SidebarDestination.home.id else { return nil }
        return appState.detailReturnContext
    }

    private func completeHomeReturnRestoration() {
        overviewVerticalReturnReady = true
        overviewHorizontalReturnReady = true
        finishHomeReturnRestorationIfReady()
    }

    private func completeOverviewHorizontalRestoration() {
        overviewHorizontalReturnReady = true
        finishHomeReturnRestorationIfReady()
    }

    private func finishHomeReturnRestorationIfReady() {
        guard overviewVerticalReturnReady, overviewHorizontalReturnReady else { return }
        homeReturnFallbackTask?.cancel()
        homeInlineReturnRestoreTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil
        withTransaction(transaction) {
            inlineReturnContentReady = true
        }
        guard let context = activeReturnContext else { return }
        appState.consumeDetailReturnContext(
            destinationID: SidebarDestination.home.id,
            anchorID: context.anchorID
        )
    }

    /// 返回首页时的可见性兜底：锚点恢复链路一旦未能走完（总览分区刷新时序、锚点对应内容
    /// 在返回后已不存在、或子分区回调缺失），内容会卡在 opacity 0 形成空白页。这里在短暂
    /// 延时后强制把页面标记为就绪，确保返回首页永不出现空白页；成功恢复时该任务会被取消。
    private func scheduleHomeReturnVisibilityFallback() {
        homeReturnFallbackTask?.cancel()
        homeReturnFallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            overviewVerticalReturnReady = true
            overviewHorizontalReturnReady = true
            finishHomeReturnRestorationIfReady()
        }
    }

    private func restoreOverviewAnchorIfNeeded(_ anchorID: String?, scrollProxy: ScrollViewProxy) {
        guard currentTab == .overview,
              let anchorID,
              restoredOverviewAnchorID != anchorID else { return }
        restoredOverviewAnchorID = anchorID
        Task { @MainActor in
            // 让出一帧，等总览分区快照在 onAppear 中刷新完成后再查找锚点所属分区；
            // 否则首帧 overviewBoards 仍为空会找不到分区，使页面永久停在 opacity 0（空白页）。
            await Task.yield()
            if let board = overviewBoards.first(where: { $0.items.contains(where: { $0.id == anchorID }) }) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                transaction.animation = nil
                withTransaction(transaction) {
                    scrollProxy.scrollTo("overview-board-\(board.id)", anchor: .center)
                }
                await Task.yield()
                // 水平方向由命中分区的 HomeOverviewBoard 回调 completeOverviewHorizontalRestoration 置位。
            } else {
                // 锚点对应内容在返回后已不在任何分区（推荐/继续观看会变化）：放弃滚动定位，
                // 但仍需把水平方向标记就绪，否则两方向缺一会让内容一直不可见。
                overviewHorizontalReturnReady = true
            }
            // 无论锚点是否仍存在，都必须把垂直方向标记为就绪让内容显示出来——
            // 锚点定位只是“尽力而为”的滚动，绝不能成为内容可见性的前置条件。
            overviewVerticalReturnReady = true
            finishHomeReturnRestorationIfReady()
        }
    }

    private func restoreHomeInlineAnchorIfNeeded(
        _ anchorID: String?,
        isSearching: Bool,
        scrollProxy: ScrollViewProxy
    ) {
        if isSearching {
            guard let anchorID else {
                completeHomeReturnRestoration()
                return
            }
            if restoredOverviewAnchorID == anchorID {
                if !inlineReturnContentReady {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                    withTransaction(transaction) {
                        inlineReturnContentReady = true
                    }
                }
                return
            }
            restoredOverviewAnchorID = anchorID

            // 搜索结果按分类异步增量出现。返回时如果先等待锚点恢复再显示页面，
            // 锚点尚未生成就会造成空白页；因此先显示内容，再在后续几帧尽力滚回来源条目。
            homeReturnFallbackTask?.cancel()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            transaction.animation = nil
            withTransaction(transaction) {
                inlineReturnContentReady = true
            }
            homeInlineReturnRestoreTask?.cancel()
            homeInlineReturnRestoreTask = Task { @MainActor in
                let delays: [UInt64] = [0, 90_000_000, 220_000_000, 480_000_000, 760_000_000]
                for delay in delays {
                    guard !Task.isCancelled else { return }
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    } else {
                        await Task.yield()
                    }
                    guard !Task.isCancelled else { return }
                    guard activeReturnContext?.anchorID == anchorID else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(anchorID, anchor: .center)
                    }
                }
                completeHomeReturnRestoration()
            }
        } else {
            restoreOverviewAnchorIfNeeded(anchorID, scrollProxy: scrollProxy)
        }
    }
}

struct HomeTabBar: View {
    @EnvironmentObject private var appState: AppState
    let tabs: [HomeTab]
    @Binding var selection: HomeTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            singleRowTabs
            wrappedTabs
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 1.04)
    }

    private var singleRowTabs: some View {
        HStack(spacing: 10) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .frame(height: 46, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    // 标签放不下时（英文 / 日文标签更长）不再换成挤在一起的两行网格，
    // 而是退化成单行横向滚动的胶囊，和能放下时的单行外观一致，避免排版错乱。
    private var wrappedTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(4)
        }
        .verticalScrollPassthroughFromNestedHorizontal()
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        Button {
            withAnimation(AppMotion.fast) {
                selection = tab
            }
        } label: {
            GlassCapsuleControl(isSelected: selection == tab, height: 30, horizontalPadding: 12) {
                Label(appState.localized(tab.displayName), systemImage: tab.systemImage)
            }
        }
        .buttonStyle(.plain)
        .help(appState.localized(tab.displayName))
    }
}

struct HomeStatsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let stats = appState.homeStats
        let tiles = statTiles(stats)
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 150), spacing: 12),
            count: max(1, min(tiles.count, 4))
        )

        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                AppStatTile(
                    title: tile.title,
                    value: tile.value,
                    systemImage: tile.systemImage,
                    color: AppColors.accentFamilyColor(forSeed: index)
                )
            }
        }
    }

    private func statTiles(_ stats: HomeStatsSnapshot) -> [HomeStatTileModel] {
        var values: [HomeStatTileModel] = []
        if stats.movieCount > 0 {
            values.append(HomeStatTileModel(title: appState.localized("影片"), value: "\(stats.movieCount)", systemImage: "film"))
        }
        if stats.seriesCount > 0 {
            values.append(HomeStatTileModel(title: appState.localized("系列"), value: "\(stats.seriesCount)", systemImage: "rectangle.stack"))
        }
        if stats.episodeCount > 0 {
            values.append(HomeStatTileModel(title: appState.localized("剧集"), value: "\(stats.episodeCount)", systemImage: "play.square.stack"))
        }
        if stats.unwatchedCount > 0 {
            values.append(HomeStatTileModel(title: appState.localized("未观看"), value: "\(stats.unwatchedCount)", systemImage: "eye"))
        }
        if stats.favoriteCount > 0 {
            values.append(HomeStatTileModel(title: appState.localized("喜欢"), value: "\(stats.favoriteCount)", systemImage: "heart"))
        }
        if stats.watchedMovieCount > 0 {
            values.append(HomeStatTileModel(title: appState.localized("已看影片"), value: "\(stats.watchedMovieCount)", systemImage: "checkmark.circle"))
        }
        if stats.watchedEpisodeCount > 0 {
            values.append(HomeStatTileModel(title: appState.localized("已看剧集"), value: "\(stats.watchedEpisodeCount)", systemImage: "checkmark.seal"))
        }
        if stats.totalWatchedMinutes >= 60 {
            let hours = stats.totalWatchedMinutes / 60
            let label = hours >= 10000 ? "\(hours / 1000)K+" : (hours >= 1000 ? "\(hours / 100 * 100)+" : "\(hours)")
            values.append(HomeStatTileModel(title: appState.localized("已看时长(h)"), value: label, systemImage: "clock.badge.checkmark"))
        }
        return values
    }
}

private struct HomeStatTileModel: Identifiable {
    let title: String
    let value: String
    let systemImage: String

    var id: String { "\(title)-\(systemImage)" }
}

/// 活力色彩区块：彩条标题 + 不横滚的整行分页海报。
/// 返回首页时通过 onDidRestoreAnchor 兑现「水平就绪」契约（网格无需横向定位，命中即标记就绪）。
struct HomeSectionBlock: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accentColor: Color
    let items: [MediaItem]
    let emptyMessage: String
    let metadata: (MediaItem) -> String
    var showsDeletePlaybackHistory = false
    let onSelect: (MediaItem) -> Void
    var restoreAnchorID: String? = nil
    var onDidRestoreAnchor: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeading(
                title: title,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                systemImage: systemImage,
                accentColor: accentColor,
                usesAuroraIcon: true
            )

            if items.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                HomePagedPosterRow(
                    items: items,
                    maxItems: 24,
                    minCardWidth: 132,
                    spacing: 14,
                    pageTint: accentColor
                ) { item in
                    AuroraPosterCard(
                        title: item.cardTitle,
                        subtitle: metadata(item),
                        posterPath: item.posterPath,
                        mediaType: item.type,
                        rating: item.rating.map { String(format: "%.1f", $0) },
                        progress: item.playProgress,
                        accent: accentColor,
                        onSelect: { onSelect(item) }
                    )
                    .id(item.id)
                }
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 1.02)
        .repeatedCardChrome(false, cornerRadius: 20)
        .onAppear { notifyRestoreIfNeeded() }
        .onChange(of: restoreAnchorID) { _ in notifyRestoreIfNeeded() }
    }

    private func notifyRestoreIfNeeded() {
        guard let restoreAnchorID, items.contains(where: { $0.id == restoreAnchorID }) else { return }
        onDidRestoreAnchor?()
    }
}

struct HomeOverviewBoard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let title: String
    let subtitle: String
    let systemImage: String
    let items: [MediaItem]
    let emptyMessage: String
    let metadata: (MediaItem) -> String
    var showsDeletePlaybackHistory = false
    let onSelect: (MediaItem) -> Void
    var restoreAnchorID: String? = nil
    var onDidRestoreAnchor: (() -> Void)? = nil
    @State private var autoScrollIndex = 0
    @State private var isHoveringStrip = false
    @State private var isDraggingStrip = false
    @State private var restoredAnchorID: String?
    @State private var returnContentReady: Bool

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        items: [MediaItem],
        emptyMessage: String,
        metadata: @escaping (MediaItem) -> String,
        showsDeletePlaybackHistory: Bool = false,
        onSelect: @escaping (MediaItem) -> Void,
        restoreAnchorID: String? = nil,
        onDidRestoreAnchor: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.items = items
        self.emptyMessage = emptyMessage
        self.metadata = metadata
        self.showsDeletePlaybackHistory = showsDeletePlaybackHistory
        self.onSelect = onSelect
        self.restoreAnchorID = restoreAnchorID
        self.onDidRestoreAnchor = onDidRestoreAnchor
        _returnContentReady = State(
            initialValue: restoreAnchorID == nil || !items.contains(where: { $0.id == restoreAnchorID })
        )
    }

    private var autoScrollKey: String {
        items.map(\.id).joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeading(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            )

            if items.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        let cardWidth = HomeOverviewStripLayout.cardWidth(
                            availableWidth: geometry.size.width,
                            itemCount: items.count
                        )
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: HomeOverviewStripLayout.cardSpacing) {
                                ForEach(items) { item in
                                    HomeOverviewPosterCard(
                                        item: item,
                                        metadata: metadata(item),
                                        showsDeletePlaybackHistory: showsDeletePlaybackHistory,
                                        cardWidth: cardWidth,
                                        onSelect: { onSelect(item) }
                                    )
                                    .id(item.id)
                                }
                            }
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                        // 横向海报条吞掉落在卡片上的纵向滚动，放行给外层首页竖向滚动。
                        .verticalScrollPassthroughFromNestedHorizontal()
                        .horizontalMouseDragScroll(enabled: !layoutTransitionActive) { dragging in
                            isDraggingStrip = dragging
                        }
                    }
                    .frame(height: HomeOverviewStripLayout.stripHeight)
                    .onHover { hovering in
                        isHoveringStrip = layoutTransitionActive ? false : hovering
                    }
                    .onAppear {
                        restoreAnchorIfNeeded(restoreAnchorID, scrollProxy: proxy)
                    }
                    .onChange(of: restoreAnchorID) { anchorID in
                        restoreAnchorIfNeeded(anchorID, scrollProxy: proxy)
                    }
                    .onChange(of: layoutTransitionActive) { active in
                        if active {
                            isHoveringStrip = false
                            isDraggingStrip = false
                        }
                    }
                    .task(id: "\(autoScrollKey)|\(layoutTransitionActive)") {
                        autoScrollIndex = 0
                        guard items.count > 1, !reduceMotion, !layoutTransitionActive else { return }
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(nanoseconds: 5_200_000_000)
                            } catch {
                                return
                            }
                            guard !Task.isCancelled, !isHoveringStrip, !isDraggingStrip, !items.isEmpty else { continue }
                            autoScrollIndex = (autoScrollIndex + 1) % items.count
                            let targetID = items[autoScrollIndex].id
                            withAnimation(AppMotion.page) {
                                proxy.scrollTo(targetID, anchor: .leading)
                            }
                        }
                    }
                }
                .opacity(returnContentReady ? 1 : 0)
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 1.02)
        .repeatedCardChrome(false, cornerRadius: 20)
    }

    private func restoreAnchorIfNeeded(_ anchorID: String?, scrollProxy: ScrollViewProxy) {
        guard let anchorID,
              restoredAnchorID != anchorID,
              let index = items.firstIndex(where: { $0.id == anchorID }) else { return }
        restoredAnchorID = anchorID
        autoScrollIndex = index
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            transaction.animation = nil
            withTransaction(transaction) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
                returnContentReady = true
            }
            await Task.yield()
            onDidRestoreAnchor?()
        }
    }
}

private enum HomeOverviewStripLayout {
    static let cardSpacing: CGFloat = 12
    static let cardMinWidth: CGFloat = 112
    static let stripHeight: CGFloat = 214

    static func cardWidth(availableWidth: CGFloat, itemCount: Int) -> CGFloat {
        guard availableWidth > 0, itemCount > 0 else { return cardMinWidth }
        let visibleCapacity = max(1, Int((availableWidth + cardSpacing) / (cardMinWidth + cardSpacing)))
        let visibleCount = max(1, min(itemCount, visibleCapacity))
        let spacingWidth = CGFloat(visibleCount - 1) * cardSpacing
        return max(cardMinWidth, floor((availableWidth - spacingWidth) / CGFloat(visibleCount)))
    }
}

private struct HomeOverviewPosterCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let item: MediaItem
    let metadata: String
    var showsDeletePlaybackHistory = false
    let cardWidth: CGFloat
    let onSelect: () -> Void
    @State private var isHovering = false

    private var active: Bool {
        isHovering && !suppressHoverDuringScroll && !layoutTransitionActive
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    PosterImage(
                        path: item.posterPath,
                        title: item.cardTitle,
                        mediaType: item.type,
                        cacheTargetSize: CGSize(width: 180, height: 270)
                    )
                    .aspectRatio(2.0 / 3.0, contentMode: .fill)
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if item.playProgress > 0, item.playProgress < 0.98 {
                        ProgressView(value: item.playProgress)
                            .tint(AppColors.selectedGlassTint)
                            .controlSize(.small)
                            .padding(.horizontal, 7)
                            .padding(.bottom, 7)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(active ? 0.56 : 0.26), lineWidth: active ? 1.1 : 0.7)
                }

                Text(item.cardTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .staticSurfaceBackground(cornerRadius: 16, thickness: active ? 1.08 : 0.92)
            .repeatedCardChrome(active, cornerRadius: 16)
            .repeatedSurfaceHover(active, cornerRadius: 16, intensity: 0.62)
            .scaleEffect(active && !reduceMotion ? 1.018 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            VideoItemContextMenuItems(
                item: item,
                showsDeletePlaybackHistory: showsDeletePlaybackHistory
            )
        }
        .onHover { hovering in
            isHovering = (suppressHoverDuringScroll || layoutTransitionActive) ? false : hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .onChange(of: layoutTransitionActive) { active in
            if active {
                isHovering = false
            }
        }
        .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
    }
}

struct LibraryHealthView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let onOpen: () -> Void
    @State private var isHovering = false

    private func libraryHealthSummary(offline: Int, missingFiles: Int, duplicateGroups: Int, missingMetadata: Int) -> String {
        switch appState.settings.appLanguage {
        case .zhHans:
            return "\(offline) 个媒体源不可访问，\(missingFiles) 个文件/播放路径失效，\(duplicateGroups) 组疑似重复条目，\(missingMetadata) 个条目缺少核心信息。"
        case .en:
            return "\(offline) sources unreachable, \(missingFiles) broken files/paths, \(duplicateGroups) likely duplicate groups, \(missingMetadata) items missing key info."
        case .ja:
            return "アクセス不可のソース \(offline) 件、無効なファイル/パス \(missingFiles) 件、重複の疑い \(duplicateGroups) 組、主要情報が不足 \(missingMetadata) 件。"
        }
    }

    var body: some View {
        let offline = appState.offlineSources
        let missingFiles = appState.missingFileItems
        let duplicateGroups = appState.duplicateTitleGroups
        let missingMetadata = appState.missingMetadataItems

        if !offline.isEmpty || !missingFiles.isEmpty || !duplicateGroups.isEmpty || !missingMetadata.isEmpty {
            let tint = AppColors.selectedGlassTint
            let active = isHovering && !suppressHoverDuringScroll && !layoutTransitionActive
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(active ? tint.opacity(0.96) : tint.opacity(0.82))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.localized("媒体库需要处理"))
                            .font(.headline)
                        Text(libraryHealthSummary(offline: offline.count, missingFiles: missingFiles.count, duplicateGroups: duplicateGroups.count, missingMetadata: missingMetadata.count))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.08))
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.cleanPanelFill.opacity(colorScheme == .dark ? 0.56 : 0.74))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.34 : 0.70),
                                tint.opacity(colorScheme == .dark ? 0.34 : 0.24),
                                tint.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .repeatedSurfaceHover(active, cornerRadius: 14, tint: tint, intensity: 0.78)
            .brightness(active ? 0.006 : 0)
            .onHover { hovering in
                isHovering = (suppressHoverDuringScroll || layoutTransitionActive) ? false : hovering
            }
            .onChange(of: suppressHoverDuringScroll) { suppressing in
                if suppressing {
                    isHovering = false
                }
            }
            .onChange(of: layoutTransitionActive) { active in
                if active {
                    isHovering = false
                }
            }
            .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
        }
    }
}

/// 启动时媒体库仍在异步读取（约120ms+，见 AppState.scheduleLibraryReload）的过渡态。
/// 与"待添加媒体源"的真空态严格区分，避免磁盘上明明已有媒体源却先误闪一次"请添加"提示。
struct HomeLibraryLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("正在整理媒体库…")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .center)
        .padding(32)
        .staticSurfaceBackground(cornerRadius: 22)
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenSources: () -> Void
    @State private var iconShakeStep = 0
    @State private var iconShakeTask: Task<Void, Never>?

    private var iconShakeAngle: Double {
        guard !reduceMotion else { return 0 }
        let pattern: [Double] = [0, -5.0, 4.6, -3.4, 2.6, -1.4, 0.7, 0]
        return pattern[iconShakeStep % pattern.count]
    }

    var body: some View {
        ZStack {
            PlayfulSymbolIcon(systemImage: "externaldrive.badge.plus", size: 62)
                .rotationEffect(.degrees(iconShakeAngle), anchor: .center)
                .scaleEffect(iconShakeStep == 0 || reduceMotion ? 1 : 1.012)
                .opacity(0.94)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.085), value: iconShakeStep)

            VStack(spacing: 18) {
	            Text(appState.localized("媒体源待添加"))
	                .font(.title2.weight(.semibold))
	            Text(appState.localized("接入本地文件夹、移动硬盘、网络挂载或 Emby 媒体库后，MediaLIB 会整理索引。"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(action: onOpenSources) {
                Label(appState.localized("前往媒体源添加"), systemImage: "arrow.right.circle.fill")
            }
            // 与全局按钮系统统一(圆角矩形12+蓝色实心)，不再用独立的胶囊描边样式。
            .buttonStyle(AppSheetPrimaryButtonStyle())
            .help(appState.localized("前往媒体源添加"))
            .padding(.top, 4)
            }
            .offset(y: 116)
        }
        // 内容在更高的卡片内水平+垂直居中，让磁盘固定在空状态视觉中心。
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .center)
        .padding(32)
        .staticSurfaceBackground(cornerRadius: 22)
        .onAppear { startIconShakeIfNeeded() }
        .onDisappear {
            iconShakeTask?.cancel()
            iconShakeTask = nil
        }
    }

    private func startIconShakeIfNeeded() {
        guard iconShakeTask == nil, !reduceMotion else { return }
        iconShakeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_150_000_000)
                for step in 1...7 {
                    guard !Task.isCancelled else { return }
                    iconShakeStep = step
                    try? await Task.sleep(nanoseconds: 85_000_000)
                }
                iconShakeStep = 0
            }
        }
    }
}

struct ScanProgressView: View {
    @EnvironmentObject private var appState: AppState
    let progress: ScanProgress

    private func scanningVaultTitle(_ name: String) -> String {
        switch appState.settings.appLanguage {
        case .zhHans: return "正在扫描\(name)媒体源"
        case .en: return "Scanning \(name) source"
        case .ja: return "\(name)ソースをスキャン中"
        }
    }

    var body: some View {
        let source = appState.sources.first { $0.id == progress.sourceID }
        let hidesPath = source?.mediaType == .privateCollection && !appState.privacyUnlocked

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(hidesPath ? scanningVaultTitle(appState.settings.privacyVaultName) : appState.localized("正在扫描"))
                    .font(.headline)
                Spacer()
                Text("\(progress.processedFiles)/\(progress.totalFiles)")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .tint(AppColors.selectedGlassTint)
            if hidesPath {
                Text(appState.localized("扫描详情已隐藏"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let currentPath = progress.currentPath {
                Text(currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .staticSurfaceBackground()
    }
}

/// 首页模块入场：首次进入时按模块顺序做淡入 + 轻上浮的 stagger（AppMotion.blockStagger），
/// delay 封顶 6 档避免长首页底部模块等待过久；从详情返回或 Reduce Motion 时直接呈现终态。
private struct HomeModuleEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let staggerEnabled: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion || !staggerEnabled {
                    appeared = true
                } else {
                    withAnimation(
                        AppMotion.blockStagger.delay(Double(min(index, 6)) * AppAuroraMetrics.blockStaggerStep)
                    ) {
                        appeared = true
                    }
                }
            }
    }
}
