import Foundation

public enum MediaType: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case movie
    case tvShow
    case anime
    case documentary
    case variety
    case homeVideo
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
        case .homeVideo: return "家庭录像"
        case .music: return "音乐"
        case .other: return "其他"
        case .privateCollection: return "保险库"
        case .episode: return "剧集"
        }
    }

    public var systemImage: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .movie: return "film"
        case .tvShow: return "tv"
        case .anime: return "sparkles.tv"
        case .documentary: return "books.vertical"
        case .variety: return "music.mic"
        case .homeVideo: return "video"
        case .music: return "music.note"
        case .other: return "tray"
        case .privateCollection: return "lock.rectangle.stack"
        case .episode: return "play.rectangle"
        }
    }
}
