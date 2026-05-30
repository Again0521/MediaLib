import Foundation

public enum DefaultPlayer: String, Codable, CaseIterable, Identifiable {
    case builtIn
    case external

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: return "内置播放器"
        case .external: return "系统播放器"
        }
    }
}

public enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case dark
    case light

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

public enum ArtworkFallbackMode: String, Codable, CaseIterable, Identifiable {
    case videoFrame
    case generatedDefault
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .videoFrame: return "截取视频帧"
        case .generatedDefault: return "绘制默认封面"
        case .none: return "不生成"
        }
    }

    public var description: String {
        switch self {
        case .videoFrame: return "使用视频真实比例，适合家庭影片、演唱会和横版剧集。"
        case .generatedDefault: return "生成统一风格的默认封面，适合封面缺失但不想暴露视频画面。"
        case .none: return "缺失封面时仅在界面中显示占位卡片。"
        }
    }
}

public enum HomeTab: String, Codable, CaseIterable, Identifiable {
    case overview
    case nextUp
    case continueWatching
    case recent
    case movies
    case tvShows
    case anime
    case documentaries
    case variety
    case music
    case other
    case favorites
    case unwatched
    case privacy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: return "总览"
        case .nextUp: return "下一集"
        case .continueWatching: return "继续观看"
        case .recent: return "最近添加"
        case .movies: return "电影"
        case .tvShows: return "电视剧"
        case .anime: return "动漫"
        case .documentaries: return "纪录片"
        case .variety: return "综艺"
        case .music: return "音乐"
        case .other: return "其他"
        case .favorites: return "收藏"
        case .unwatched: return "未观看"
        case .privacy: return "保险库"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .nextUp: return "forward.end"
        case .continueWatching: return "play.circle"
        case .recent: return "clock"
        case .movies: return "film"
        case .tvShows: return "tv"
        case .anime: return "sparkles.tv"
        case .documentaries: return "books.vertical"
        case .variety: return "music.mic"
        case .music: return "music.note.list"
        case .other: return "tray"
        case .favorites: return "heart"
        case .unwatched: return "eye"
        case .privacy: return "lock.rectangle.stack"
        }
    }
}

public enum MusicMetadataProvider: String, Codable, CaseIterable, Identifiable {
    case musicBrainz
    case iTunes
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .musicBrainz: return "MusicBrainz"
        case .iTunes: return "iTunes Search"
        case .disabled: return "关闭"
        }
    }
}

public enum AutomaticScanInterval: String, Codable, CaseIterable, Identifiable {
    case disabled
    case fifteenMinutes
    case hourly
    case sixHours
    case daily

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disabled: return "关闭"
        case .fifteenMinutes: return "每 15 分钟"
        case .hourly: return "每小时"
        case .sixHours: return "每 6 小时"
        case .daily: return "每天"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .disabled: return nil
        case .fifteenMinutes: return 15 * 60
        case .hourly: return 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .daily: return 24 * 60 * 60
        }
    }
}

public struct AppSettings: Codable, Hashable {
    public static let defaultHomeTabs: [HomeTab] = [
        .overview,
        .nextUp,
        .continueWatching,
        .recent,
        .movies,
        .tvShows,
        .anime,
        .documentaries,
        .variety,
        .music,
        .other,
        .favorites,
        .unwatched
    ]

    public var defaultPlayer: DefaultPlayer
    public var theme: AppTheme
    public var rememberPlaybackPosition: Bool
    public var autoPlayNextEpisode: Bool
    public var autoMarkWatched: Bool
    public var watchedThreshold: Double
    public var skipInterval: Double
    public var defaultVolume: Double
    public var lastVideoVolume: Double
    public var lastMusicVolume: Double
    public var defaultPlaybackRate: Double
    public var enableQuickPreview: Bool
    public var quickPreviewStartRatio: Double
    public var quickPreviewMuted: Bool
    public var enableThumbnailFallback: Bool
    public var thumbnailCaptureRatio: Double
    public var avoidBlackFrames: Bool
    public var artworkFallbackMode: ArtworkFallbackMode
    public var thumbnailConcurrency: Int
    public var posterMinWidth: Double
    public var posterMaxWidth: Double
    public var videoPlayerPreferredWidth: Double
    public var enabledHomeTabs: [HomeTab]
    public var videoDefaultPlayer: DefaultPlayer
    public var musicDefaultPlayer: DefaultPlayer
    public var videoExternalPlayerPath: String?
    public var musicExternalPlayerPath: String?
    public var keepLocalAudioWithAirPlay: Bool
    public var tmdbAPIKey: String?
    public var tmdbLanguage: String
    public var musicMetadataProvider: MusicMetadataProvider
    public var automaticScanInterval: AutomaticScanInterval
    public var externalPlayerPath: String?
    public var debugLoggingEnabled: Bool
    public var privacyVaultName: String
    public var privacyPINEnabled: Bool
    public var openSubtitlesAPIKey: String?
    public var subtitleLanguage: String

    public init(
        defaultPlayer: DefaultPlayer = .builtIn,
        theme: AppTheme = .system,
        rememberPlaybackPosition: Bool = true,
        autoPlayNextEpisode: Bool = true,
        autoMarkWatched: Bool = true,
        watchedThreshold: Double = 0.9,
        skipInterval: Double = 5,
        defaultVolume: Double = 0.8,
        lastVideoVolume: Double? = nil,
        lastMusicVolume: Double? = nil,
        defaultPlaybackRate: Double = 1.0,
        enableQuickPreview: Bool = true,
        quickPreviewStartRatio: Double = 0.1,
        quickPreviewMuted: Bool = true,
        enableThumbnailFallback: Bool = true,
        thumbnailCaptureRatio: Double = 0.1,
        avoidBlackFrames: Bool = true,
        artworkFallbackMode: ArtworkFallbackMode = .videoFrame,
        thumbnailConcurrency: Int = 2,
        posterMinWidth: Double = 150,
        posterMaxWidth: Double = 240,
        videoPlayerPreferredWidth: Double = 1120,
        enabledHomeTabs: [HomeTab] = AppSettings.defaultHomeTabs,
        videoDefaultPlayer: DefaultPlayer? = nil,
        musicDefaultPlayer: DefaultPlayer = .builtIn,
        videoExternalPlayerPath: String? = nil,
        musicExternalPlayerPath: String? = nil,
        keepLocalAudioWithAirPlay: Bool = true,
        tmdbAPIKey: String? = nil,
        tmdbLanguage: String = "zh-CN",
        musicMetadataProvider: MusicMetadataProvider = .musicBrainz,
        automaticScanInterval: AutomaticScanInterval = .disabled,
        externalPlayerPath: String? = nil,
        debugLoggingEnabled: Bool = false,
        privacyVaultName: String = "保险库",
        privacyPINEnabled: Bool = false,
        openSubtitlesAPIKey: String? = nil,
        subtitleLanguage: String = "zh-CN"
    ) {
        self.defaultPlayer = defaultPlayer
        self.theme = theme
        self.rememberPlaybackPosition = rememberPlaybackPosition
        self.autoPlayNextEpisode = autoPlayNextEpisode
        self.autoMarkWatched = autoMarkWatched
        self.watchedThreshold = watchedThreshold
        self.skipInterval = skipInterval
        self.defaultVolume = defaultVolume
        self.lastVideoVolume = Self.clampedVolume(lastVideoVolume ?? defaultVolume)
        self.lastMusicVolume = Self.clampedVolume(lastMusicVolume ?? defaultVolume)
        self.defaultPlaybackRate = defaultPlaybackRate
        self.enableQuickPreview = enableQuickPreview
        self.quickPreviewStartRatio = quickPreviewStartRatio
        self.quickPreviewMuted = quickPreviewMuted
        self.enableThumbnailFallback = enableThumbnailFallback
        self.thumbnailCaptureRatio = thumbnailCaptureRatio
        self.avoidBlackFrames = avoidBlackFrames
        self.artworkFallbackMode = artworkFallbackMode
        self.thumbnailConcurrency = thumbnailConcurrency
        self.posterMinWidth = posterMinWidth
        self.posterMaxWidth = posterMaxWidth
        self.videoPlayerPreferredWidth = videoPlayerPreferredWidth
        self.enabledHomeTabs = enabledHomeTabs.isEmpty ? AppSettings.defaultHomeTabs : enabledHomeTabs
        self.videoDefaultPlayer = videoDefaultPlayer ?? defaultPlayer
        self.musicDefaultPlayer = musicDefaultPlayer
        self.videoExternalPlayerPath = videoExternalPlayerPath
        self.musicExternalPlayerPath = musicExternalPlayerPath
        self.keepLocalAudioWithAirPlay = keepLocalAudioWithAirPlay
        self.tmdbAPIKey = tmdbAPIKey
        self.tmdbLanguage = tmdbLanguage
        self.musicMetadataProvider = musicMetadataProvider
        self.automaticScanInterval = automaticScanInterval
        self.externalPlayerPath = externalPlayerPath
        self.debugLoggingEnabled = debugLoggingEnabled
        self.privacyVaultName = privacyVaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "保险库" : privacyVaultName
        self.privacyPINEnabled = privacyPINEnabled
        self.openSubtitlesAPIKey = openSubtitlesAPIKey
        self.subtitleLanguage = subtitleLanguage.isEmpty ? "zh-CN" : subtitleLanguage
    }

    private enum CodingKeys: String, CodingKey {
        case defaultPlayer
        case theme
        case rememberPlaybackPosition
        case autoPlayNextEpisode
        case autoMarkWatched
        case watchedThreshold
        case skipInterval
        case defaultVolume
        case lastVideoVolume
        case lastMusicVolume
        case defaultPlaybackRate
        case enableQuickPreview
        case quickPreviewStartRatio
        case quickPreviewMuted
        case enableThumbnailFallback
        case thumbnailCaptureRatio
        case avoidBlackFrames
        case artworkFallbackMode
        case thumbnailConcurrency
        case posterMinWidth
        case posterMaxWidth
        case videoPlayerPreferredWidth
        case enabledHomeTabs
        case videoDefaultPlayer
        case musicDefaultPlayer
        case videoExternalPlayerPath
        case musicExternalPlayerPath
        case keepLocalAudioWithAirPlay
        case tmdbAPIKey
        case tmdbLanguage
        case musicMetadataProvider
        case automaticScanInterval
        case externalPlayerPath
        case debugLoggingEnabled
        case privacyVaultName
        case privacyPINEnabled
        case openSubtitlesAPIKey
        case subtitleLanguage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        let legacyThumbnailFallback = try container.decodeIfPresent(Bool.self, forKey: .enableThumbnailFallback) ?? defaults.enableThumbnailFallback
        let decodedArtworkMode = try container.decodeIfPresent(ArtworkFallbackMode.self, forKey: .artworkFallbackMode)
        let legacyDefaultPlayer = try container.decodeIfPresent(DefaultPlayer.self, forKey: .defaultPlayer)
        let legacyExternalPlayerPath = try container.decodeIfPresent(String.self, forKey: .externalPlayerPath)
        let decodedVideoDefaultPlayer = try container.decodeIfPresent(DefaultPlayer.self, forKey: .videoDefaultPlayer)
        let decodedVideoExternalPlayerPath = try container.decodeIfPresent(String.self, forKey: .videoExternalPlayerPath)
        let legacyDefaultVolume = try container.decodeIfPresent(Double.self, forKey: .defaultVolume) ?? defaults.defaultVolume

        self.init(
            defaultPlayer: legacyDefaultPlayer ?? defaults.defaultPlayer,
            theme: try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? defaults.theme,
            rememberPlaybackPosition: try container.decodeIfPresent(Bool.self, forKey: .rememberPlaybackPosition) ?? defaults.rememberPlaybackPosition,
            autoPlayNextEpisode: try container.decodeIfPresent(Bool.self, forKey: .autoPlayNextEpisode) ?? defaults.autoPlayNextEpisode,
            autoMarkWatched: try container.decodeIfPresent(Bool.self, forKey: .autoMarkWatched) ?? defaults.autoMarkWatched,
            watchedThreshold: try container.decodeIfPresent(Double.self, forKey: .watchedThreshold) ?? defaults.watchedThreshold,
            skipInterval: try container.decodeIfPresent(Double.self, forKey: .skipInterval) ?? defaults.skipInterval,
            defaultVolume: legacyDefaultVolume,
            lastVideoVolume: try container.decodeIfPresent(Double.self, forKey: .lastVideoVolume) ?? legacyDefaultVolume,
            lastMusicVolume: try container.decodeIfPresent(Double.self, forKey: .lastMusicVolume) ?? legacyDefaultVolume,
            defaultPlaybackRate: try container.decodeIfPresent(Double.self, forKey: .defaultPlaybackRate) ?? defaults.defaultPlaybackRate,
            enableQuickPreview: try container.decodeIfPresent(Bool.self, forKey: .enableQuickPreview) ?? defaults.enableQuickPreview,
            quickPreviewStartRatio: try container.decodeIfPresent(Double.self, forKey: .quickPreviewStartRatio) ?? defaults.quickPreviewStartRatio,
            quickPreviewMuted: try container.decodeIfPresent(Bool.self, forKey: .quickPreviewMuted) ?? defaults.quickPreviewMuted,
            enableThumbnailFallback: legacyThumbnailFallback,
            thumbnailCaptureRatio: try container.decodeIfPresent(Double.self, forKey: .thumbnailCaptureRatio) ?? defaults.thumbnailCaptureRatio,
            avoidBlackFrames: try container.decodeIfPresent(Bool.self, forKey: .avoidBlackFrames) ?? defaults.avoidBlackFrames,
            artworkFallbackMode: decodedArtworkMode ?? (legacyThumbnailFallback ? defaults.artworkFallbackMode : .none),
            thumbnailConcurrency: try container.decodeIfPresent(Int.self, forKey: .thumbnailConcurrency) ?? defaults.thumbnailConcurrency,
            posterMinWidth: try container.decodeIfPresent(Double.self, forKey: .posterMinWidth) ?? defaults.posterMinWidth,
            posterMaxWidth: try container.decodeIfPresent(Double.self, forKey: .posterMaxWidth) ?? defaults.posterMaxWidth,
            videoPlayerPreferredWidth: try container.decodeIfPresent(Double.self, forKey: .videoPlayerPreferredWidth) ?? defaults.videoPlayerPreferredWidth,
            enabledHomeTabs: try container.decodeIfPresent([HomeTab].self, forKey: .enabledHomeTabs) ?? defaults.enabledHomeTabs,
            videoDefaultPlayer: decodedVideoDefaultPlayer ?? legacyDefaultPlayer ?? defaults.videoDefaultPlayer,
            musicDefaultPlayer: try container.decodeIfPresent(DefaultPlayer.self, forKey: .musicDefaultPlayer) ?? defaults.musicDefaultPlayer,
            videoExternalPlayerPath: decodedVideoExternalPlayerPath ?? legacyExternalPlayerPath ?? defaults.videoExternalPlayerPath,
            musicExternalPlayerPath: try container.decodeIfPresent(String.self, forKey: .musicExternalPlayerPath) ?? defaults.musicExternalPlayerPath,
            keepLocalAudioWithAirPlay: try container.decodeIfPresent(Bool.self, forKey: .keepLocalAudioWithAirPlay) ?? defaults.keepLocalAudioWithAirPlay,
            tmdbAPIKey: try container.decodeIfPresent(String.self, forKey: .tmdbAPIKey) ?? defaults.tmdbAPIKey,
            tmdbLanguage: try container.decodeIfPresent(String.self, forKey: .tmdbLanguage) ?? defaults.tmdbLanguage,
            musicMetadataProvider: try container.decodeIfPresent(MusicMetadataProvider.self, forKey: .musicMetadataProvider) ?? defaults.musicMetadataProvider,
            automaticScanInterval: try container.decodeIfPresent(AutomaticScanInterval.self, forKey: .automaticScanInterval) ?? defaults.automaticScanInterval,
            externalPlayerPath: legacyExternalPlayerPath ?? defaults.externalPlayerPath,
            debugLoggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? defaults.debugLoggingEnabled,
            privacyVaultName: try container.decodeIfPresent(String.self, forKey: .privacyVaultName) ?? defaults.privacyVaultName,
            privacyPINEnabled: try container.decodeIfPresent(Bool.self, forKey: .privacyPINEnabled) ?? false,
            openSubtitlesAPIKey: try container.decodeIfPresent(String.self, forKey: .openSubtitlesAPIKey) ?? defaults.openSubtitlesAPIKey,
            subtitleLanguage: try container.decodeIfPresent(String.self, forKey: .subtitleLanguage) ?? defaults.subtitleLanguage
        )
    }

    public func rememberedVolume(for mediaType: MediaType) -> Double {
        mediaType == .music ? lastMusicVolume : lastVideoVolume
    }

    public mutating func setRememberedVolume(_ volume: Double, for mediaType: MediaType) {
        let clamped = Self.clampedVolume(volume)
        if mediaType == .music {
            lastMusicVolume = clamped
        } else {
            lastVideoVolume = clamped
        }
    }

    private static func clampedVolume(_ volume: Double) -> Double {
        min(max(volume, 0), 1)
    }
}
