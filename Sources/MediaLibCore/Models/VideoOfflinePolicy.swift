import Foundation

public enum VideoSeriesCacheState: Equatable, Sendable {
    case none
    case partial
    case complete
}

public enum VideoOfflinePolicy {
    public static func seriesCacheStates(
        childrenByParentID: [String: [MediaItem]],
        cachedItemIDs: Set<String>
    ) -> [String: VideoSeriesCacheState] {
        var states: [String: VideoSeriesCacheState] = [:]
        states.reserveCapacity(childrenByParentID.count)
        for (parentID, children) in childrenByParentID {
            guard let state = seriesCacheState(for: children, cachedItemIDs: cachedItemIDs) else { continue }
            states[parentID] = state
        }
        return states
    }

    public static func seriesCacheState(
        for children: [MediaItem],
        cachedItemIDs: Set<String>
    ) -> VideoSeriesCacheState? {
        let candidates = children.filter { isCacheableVideoCandidate($0) || cachedItemIDs.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        let cachedCount = candidates.reduce(into: 0) { count, child in
            if cachedItemIDs.contains(child.id) {
                count += 1
            }
        }
        if cachedCount == 0 {
            return VideoSeriesCacheState.none
        }
        if cachedCount == candidates.count {
            return .complete
        }
        return .partial
    }

    public static func subscriptionCandidates(
        for subscription: VideoOfflineSubscription,
        episodes: [MediaItem],
        cachedItemIDs: Set<String>,
        queuedItemIDs: Set<String>,
        wifiAvailable: Bool,
        watchedThreshold: Double
    ) -> [MediaItem] {
        let cacheableEpisodes = episodes.filter(isCacheableVideoCandidate)
        guard !cacheableEpisodes.isEmpty else { return [] }

        let planned: [MediaItem] = switch subscription.mode {
        case .fullSeries:
            cacheableEpisodes
        case .nextEpisode:
            Array(nextUnwatchedEpisodes(in: cacheableEpisodes, watchedThreshold: watchedThreshold).prefix(1))
        case .nextUnwatched:
            Array(nextUnwatchedEpisodes(in: cacheableEpisodes, watchedThreshold: watchedThreshold).prefix(max(subscription.episodeLimit, 1)))
        case .season:
            cacheableEpisodes.filter { episode in
                guard let seasonNumber = subscription.seasonNumber else { return true }
                return episode.seasonNumber == seasonNumber
            }
        }

        return planned.filter {
            !cachedItemIDs.contains($0.id) &&
            !queuedItemIDs.contains($0.id) &&
            networkPolicyAllows(subscription.networkPolicy, item: $0, wifiAvailable: wifiAvailable)
        }
    }

    public static func preferredSubscriptionSeasonNumber(
        for item: MediaItem,
        episodes: [MediaItem],
        watchedThreshold: Double
    ) -> Int? {
        if item.type == .episode, let seasonNumber = item.seasonNumber {
            return seasonNumber
        }
        let cacheableEpisodes = episodes.filter(isCacheableVideoCandidate)
        return nextUnwatchedEpisodes(
            in: cacheableEpisodes,
            watchedThreshold: watchedThreshold
        ).first?.seasonNumber ?? cacheableEpisodes.first?.seasonNumber
    }

    public static func isCacheableVideoCandidate(_ item: MediaItem) -> Bool {
        guard item.type != .music,
              let filePath = item.filePath,
              let scheme = URL(string: filePath)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return true
    }

    public static func nextUnwatchedEpisodes(
        in episodes: [MediaItem],
        watchedThreshold: Double
    ) -> [MediaItem] {
        episodes.filter { !($0.watched || $0.playProgress >= watchedThreshold) }
    }

    public static func networkPolicyAllows(
        _ policy: VideoOfflineSubscriptionNetworkPolicy,
        item: MediaItem,
        wifiAvailable: Bool
    ) -> Bool {
        switch policy {
        case .allowRemote:
            return true
        case .wifiOnly:
            return wifiAvailable
        case .localNetworkOnly:
            guard let filePath = item.filePath,
                  let host = URL(string: filePath)?.host else {
                return false
            }
            return isLocalNetworkHost(host)
        }
    }

    public static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "localhost" || normalized == "::1" || normalized.hasSuffix(".local") {
            return true
        }
        if normalized.hasPrefix("fe80:") ||
            ((normalized.hasPrefix("fc") || normalized.hasPrefix("fd")) && normalized.contains(":")) {
            return true
        }
        let octets = normalized.split(separator: ".").compactMap { Int(String($0)) }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }
}
