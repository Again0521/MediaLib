public struct HomeTabAvailabilityInput: Sendable {
    public var homeVideoItems: [MediaItem]
    public var nextUpItems: [MediaItem]
    public var continueWatchingItems: [MediaItem]
    public var offlineVideoItems: [MediaItem]
    public var musicTracks: [MediaItem]
    public var privateTopLevelItems: [MediaItem]
    public var watchedThreshold: Double

    public init(
        homeVideoItems: [MediaItem],
        nextUpItems: [MediaItem],
        continueWatchingItems: [MediaItem],
        offlineVideoItems: [MediaItem],
        musicTracks: [MediaItem],
        privateTopLevelItems: [MediaItem],
        watchedThreshold: Double
    ) {
        self.homeVideoItems = homeVideoItems
        self.nextUpItems = nextUpItems
        self.continueWatchingItems = continueWatchingItems
        self.offlineVideoItems = offlineVideoItems
        self.musicTracks = musicTracks
        self.privateTopLevelItems = privateTopLevelItems
        self.watchedThreshold = watchedThreshold
    }
}

public enum HomeVideoProjectionPolicy {
    public static func nextUpItems(
        from seriesItems: [MediaItem],
        childrenByParentID: [String: [MediaItem]],
        watchedThreshold: Double,
        limit: Int
    ) -> [MediaItem] {
        Array(seriesItems.compactMap { series -> MediaItem? in
            guard let episodes = childrenByParentID[series.id], !episodes.isEmpty else { return nil }
            guard let lastFinishedIndex = episodes.lastIndex(where: {
                $0.watched || $0.playProgress >= watchedThreshold
            }) else { return nil }
            let nextIndex = lastFinishedIndex + 1
            guard episodes.indices.contains(nextIndex) else { return nil }
            let next = episodes[nextIndex]
            guard !(next.watched || next.playProgress >= watchedThreshold) else { return nil }
            return next
        }.prefix(max(limit, 0)))
    }

    public static func availableHomeTabs(_ input: HomeTabAvailabilityInput) -> Set<HomeTab> {
        Set(HomeTab.allCases.filter { tab in
            switch tab {
            case .overview:
                return true
            case .nextUp:
                return !input.nextUpItems.isEmpty
            case .continueWatching:
                return !input.continueWatchingItems.isEmpty
            case .offline:
                return !input.offlineVideoItems.isEmpty
            case .recent:
                return !input.homeVideoItems.isEmpty
            case .movies:
                return input.homeVideoItems.contains { $0.type == .movie }
            case .tvShows:
                return input.homeVideoItems.contains { $0.type == .tvShow }
            case .anime:
                return input.homeVideoItems.contains { $0.type == .anime }
            case .documentaries:
                return input.homeVideoItems.contains { $0.type == .documentary }
            case .variety:
                return input.homeVideoItems.contains { $0.type == .variety }
            case .homeVideos:
                return input.homeVideoItems.contains { $0.type == .homeVideo }
            case .music:
                return !input.musicTracks.isEmpty
            case .other:
                return input.homeVideoItems.contains { $0.type == .other }
            case .favorites:
                return input.homeVideoItems.contains { $0.type != .music && $0.favorite }
            case .unwatched:
                return input.homeVideoItems.contains {
                    $0.type != .music && !$0.watched && $0.playProgress < input.watchedThreshold
                }
            case .privacy:
                return !input.privateTopLevelItems.isEmpty
            }
        })
    }
}
