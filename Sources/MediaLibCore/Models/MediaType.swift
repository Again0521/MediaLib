import Foundation

public enum MediaType: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case movie
    case tvShow
    case anime
    case documentary
    case variety
    case music
    case other
    case privateCollection = "private"
    case episode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "自动识别"
        case .movie: return "电影"
        case .tvShow: return "电视剧"
        case .anime: return "动漫"
        case .documentary: return "纪录片"
        case .variety: return "综艺"
        case .music: return "音乐"
        case .other: return "其他"
        case .privateCollection: return "保险库"
        case .episode: return "剧集"
        }
    }
}
