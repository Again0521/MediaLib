import Foundation

/// Trakt 媒体引用：用 TMDB id 表达，与本地条目的 externalID 对应。
public enum TraktMediaRef: Equatable, Hashable, Sendable {
    case movie(tmdbID: Int)
    case show(tmdbID: Int)
    case episode(showTmdbID: Int, season: Int, episode: Int)
}

public struct TraktEpisodeKey: Hashable, Equatable, Sendable {
    public var showTmdbID: Int
    public var season: Int
    public var episode: Int

    public init(showTmdbID: Int, season: Int, episode: Int) {
        self.showTmdbID = showTmdbID
        self.season = season
        self.episode = episode
    }
}

public enum TraktSyncPayloadBuilder {
    /// 把引用聚合成 Trakt sync 载荷：movies 列表 + 按剧集归并的 shows（含 seasons/episodes）。
    public static func buildPayload(from refs: [TraktMediaRef]) -> [String: Any] {
        var movieIDs = Set<Int>()
        var standaloneShowIDs = Set<Int>()
        var showEpisodes: [Int: [Int: Set<Int>]] = [:]

        for ref in refs {
            switch ref {
            case .movie(let id):
                movieIDs.insert(id)
            case .show(let id):
                standaloneShowIDs.insert(id)
            case .episode(let showID, let season, let episode):
                showEpisodes[showID, default: [:]][season, default: []].insert(episode)
            }
        }

        let movies: [[String: Any]] = movieIDs
            .sorted()
            .map { ["ids": ["tmdb": $0]] }

        var shows: [[String: Any]] = standaloneShowIDs
            .sorted()
            .map { ["ids": ["tmdb": $0]] }
        for (showID, seasons) in showEpisodes.sorted(by: { $0.key < $1.key }) {
            let seasonsPayload: [[String: Any]] = seasons
                .sorted { $0.key < $1.key }
                .map { season, episodes in
                    [
                        "number": season,
                        "episodes": episodes.sorted().map { ["number": $0] }
                    ]
                }
            shows.append(["ids": ["tmdb": showID], "seasons": seasonsPayload])
        }

        var payload: [String: Any] = [:]
        if !movies.isEmpty { payload["movies"] = movies }
        if !shows.isEmpty { payload["shows"] = shows }
        return payload
    }
}
