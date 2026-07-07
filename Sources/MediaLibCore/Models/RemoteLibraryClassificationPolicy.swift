import Foundation

public struct RemoteLibraryClassificationHint: Sendable, Equatable {
    public var libraryName: String?
    public var collectionType: String?

    public init(libraryName: String? = nil, collectionType: String? = nil) {
        self.libraryName = libraryName
        self.collectionType = collectionType
    }
}

public enum RemoteLibraryClassificationPolicy {
    public static func inferredMediaType(for item: MediaItem, hint: RemoteLibraryClassificationHint?) -> MediaType {
        if let fromName = inferMediaType(fromLibraryName: hint?.libraryName) {
            return fromName
        }
        if let fromGenre = inferMediaType(fromGenre: item.genre) {
            return fromGenre
        }
        if let fromCollection = inferMediaType(fromCollectionType: hint?.collectionType) {
            return fromCollection
        }
        return item.type == .episode ? .tvShow : item.type
    }

    static func inferMediaType(fromLibraryName name: String?) -> MediaType? {
        guard let normalized = normalizedClassifierText(name), !normalized.isEmpty else { return nil }
        let rules: [(MediaType, [String])] = [
            (.anime, ["动漫", "动画", "番剧", "新番", "国漫", "日漫", "anime", "animation", "bangumi", "cartoon"]),
            (.documentary, ["纪录", "纪实", "documentary", "docu"]),
            (.variety, ["综艺", "真人秀", "脱口秀", "variety", "reality", "talk show", "talkshow"]),
            (.homeVideo, ["其他视频", "家庭录像", "家庭视频", "家庭影像", "自拍视频", "生活录像", "home video", "homevideo", "homevideos", "home movie", "home movies", "other video", "other videos"]),
            (.movie, ["电影", "影片", "影院", "movie", "movies", "film", "cinema"]),
            (.tvShow, ["电视剧", "剧集", "连续剧", "美剧", "日剧", "韩剧", "英剧", "华语剧", "tv", "series", "drama", "shows"])
        ]
        return rules.first { _, keywords in keywords.contains { normalized.contains($0) } }?.0
    }

    static func inferMediaType(fromCollectionType collectionType: String?) -> MediaType? {
        guard let normalized = normalizedClassifierText(collectionType), !normalized.isEmpty else { return nil }
        if normalized.contains("movies") || normalized == "movie" { return .movie }
        if normalized.contains("homevideos") || normalized.contains("home video") || normalized.contains("homevideo") { return .homeVideo }
        if normalized.contains("music") { return .music }
        if normalized.contains("tvshows") || normalized.contains("series") { return .tvShow }
        return nil
    }

    static func inferMediaType(fromGenre genre: String?) -> MediaType? {
        guard let normalized = normalizedClassifierText(genre), !normalized.isEmpty else { return nil }
        let rules: [(MediaType, [String])] = [
            (.anime, ["动画", "动漫", "animation", "anime"]),
            (.documentary, ["纪录", "documentary"]),
            (.variety, ["综艺", "真人秀", "脱口秀", "reality", "talk", "variety"]),
            (.homeVideo, ["其他视频", "家庭录像", "家庭视频", "home video", "homevideo", "home movie", "other video"])
        ]
        return rules.first { _, keywords in keywords.contains { normalized.contains($0) } }?.0
    }

    static func normalizedClassifierText(_ text: String?) -> String? {
        guard let text else { return nil }
        return (text.removingPercentEncoding ?? text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
