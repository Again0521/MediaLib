import Foundation

public enum DefaultPlayer: String, Codable, CaseIterable, Identifiable {
    case builtIn
    case external

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: return "内置"
        case .external: return "系统"
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
        case .videoFrame: return "从视频中截取一帧，并保留原始画面比例。"
        case .generatedDefault: return "使用统一风格的默认封面，不展示视频画面。"
        case .none: return "缺失封面时显示占位卡片。"
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
        case .favorites: return "喜欢"
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
    case neteaseCloud
    case qqMusic
    case lastFM
    case deezer
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .musicBrainz: return "MusicBrainz"
        case .iTunes: return "iTunes Search"
        case .neteaseCloud: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .lastFM: return "Last.fm"
        case .deezer: return "Deezer"
        case .disabled: return "关闭"
        }
    }

    /// 该来源是否需要 API Key（仅 Last.fm 需要）。
    public var requiresAPIKey: Bool {
        self == .lastFM
    }
}

/// 应用配色预设。custom 时使用 AppSettings 中的自定义十六进制颜色。
public enum AppThemePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case ocean
    case indigo
    case purple
    case rose
    case orange
    case mint
    case green
    case graphite
    case frosted
    case warm
    case oled
    case coral
    case lime
    case apricot
    case custom

    public static var allCases: [AppThemePreset] {
        [.classic, .coral, .lime, .apricot, .oled, .custom]
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic, .ocean, .indigo, .purple, .rose, .mint, .green, .frosted: return "清蓝"
        case .coral: return "珊瑚"
        case .lime: return "青柠"
        case .orange, .warm, .apricot: return "暖杏"
        case .graphite, .oled: return "夜幕"
        case .custom: return "自定义"
        }
    }

    public var isCustom: Bool { self == .custom }

    /// 各预设的种子颜色（浅色方案的 底色 / 高亮 / 左上光线，十六进制）。
    /// custom 由用户设置覆盖；深色方案在渲染层按规则派生。
    public var seedHex: (base: String, highlight: String, light: String) {
        switch self {
        case .classic, .ocean, .indigo, .purple, .rose, .mint, .green, .frosted, .custom:
            return ("F5F7FB", "007AFF", "EAF4FF")
        case .coral:
            return ("FFF5F2", "FF6B5A", "FFE7DF")
        case .lime:
            return ("F5FAEF", "7CB342", "ECF8D8")
        case .orange, .warm, .apricot:
            return ("FBF4EA", "E08A3E", "FFE8C7")
        case .graphite, .oled:
            return ("F0F2F7", "3D5AFE", "E0E7FF")
        }
    }

    /// 深色外观专用种子。显式给出可以让 OLED Dark 保持非纯黑的夜间基底，
    /// 同时避免浅色外观被误染成深色主题。
    public var darkSeedHex: (base: String, highlight: String, light: String) {
        switch self {
        case .classic, .ocean, .indigo, .purple, .rose, .mint, .green, .frosted, .custom:
            return ("111821", "0A84FF", "14283A")
        case .coral:
            return ("1A1112", "FF7A68", "3A1F1A")
        case .lime:
            return ("10170F", "A7D85A", "233512")
        case .orange, .warm, .apricot:
            return ("19120D", "F0A45A", "33200F")
        case .graphite, .oled:
            return ("0B0D10", "6C8CFF", "151E34")
        }
    }
}

/// 音乐均衡器预设（5 段：60 / 230 / 910 / 3600 / 14000 Hz）。
public enum MusicEqualizerPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat
    case pop
    case rock
    case jazz
    case classical
    case bassBoost
    case vocal
    case trebleBoost

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flat: return "纯平"
        case .pop: return "流行"
        case .rock: return "摇滚"
        case .jazz: return "爵士"
        case .classical: return "古典"
        case .bassBoost: return "低音增强"
        case .vocal: return "人声"
        case .trebleBoost: return "高音增强"
        }
    }

    /// 各段增益（dB），顺序对应 60 / 230 / 910 / 3600 / 14000 Hz。
    public var gainsDB: [Double] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0]
        case .pop: return [-1, 2, 4, 2, -1]
        case .rock: return [4, 2, -1, 2, 4]
        case .jazz: return [3, 1, 1, 2, 3]
        case .classical: return [4, 2, -1, 2, 3]
        case .bassBoost: return [6, 4, 1, 0, 0]
        case .vocal: return [-2, 0, 4, 3, 0]
        case .trebleBoost: return [0, 0, 1, 4, 6]
        }
    }

    public var isFlat: Bool { self == .flat }
}

/// TMDB / 元数据自动匹配的置信度宽容度。三档分别提高/降低自动套用所需的相似度阈值。
public enum MetadataMatchTolerance: String, Codable, CaseIterable, Identifiable {
    case loose
    case standard
    case strict

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .loose: return "宽松"
        case .standard: return "标准"
        case .strict: return "严格"
        }
    }

    public var summary: String {
        switch self {
        case .loose: return "更易匹配，命名混乱的库也能尽量覆盖，可能偶有误配"
        case .standard: return "在准确度与覆盖率之间平衡（推荐）"
        case .strict: return "仅高置信度才自动套用，最大限度避免误配"
        }
    }

    /// 视频自动匹配置信度阈值（标题相似度为主，年份加成）。
    public var videoThreshold: Double {
        switch self {
        case .loose: return 0.48
        case .standard: return 0.60
        case .strict: return 0.74
        }
    }

    /// 音乐自动匹配置信度阈值（标题 + 艺人加权）。
    public var musicThreshold: Double {
        switch self {
        case .loose: return 0.42
        case .standard: return 0.52
        case .strict: return 0.66
        }
    }
}

public enum LyricSyncAlgorithm: String, Codable, CaseIterable, Identifiable {
    case instant
    case balanced
    case audioEnergy
    case precise

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .instant: return "快速估算"
        case .balanced: return "语速校准"
        case .audioEnergy: return "音频校正"
        case .precise: return "精确优先"
        }
    }

    public var description: String {
        switch self {
        case .instant:
            return "按文字权重生成逐字时间，不分析音频。"
        case .balanced:
            return "结合标点、句尾留白和全曲语速校准，不分析音频。"
        case .audioEnergy:
            return "先使用语速校准，再在后台分析本地音频并自动更新结果。"
        case .precise:
            return "使用更细的音频分析进行校正，耗时更长；已有逐字歌词或缓存时直接使用。"
        }
    }

    public var usesBackgroundAlignment: Bool {
        switch self {
        case .audioEnergy, .precise: return true
        case .instant, .balanced: return false
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
    /// 配色预设 + 自定义颜色（十六进制，不含 #）。
    public var themePreset: AppThemePreset
    public var themeBaseHex: String?
    public var themeHighlightHex: String?
    public var themeLightHex: String?
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
    /// TMDB / 元数据自动匹配的置信度宽容度（宽松/标准/严格）。
    public var metadataMatchTolerance: MetadataMatchTolerance
    public var musicMetadataProvider: MusicMetadataProvider
    public var lyricSyncAlgorithm: LyricSyncAlgorithm
    public var musicLoudnessNormalization: MusicLoudnessNormalization
    public var musicTransitionMode: MusicTransitionMode
    public var musicSoftFadeDuration: Double
    /// 音乐均衡器开关与预设。
    public var musicEqualizerEnabled: Bool
    public var musicEqualizerPreset: MusicEqualizerPreset
    public var automaticScanInterval: AutomaticScanInterval
    /// 剧集 TMDB 自动拉取周期（复用扫描周期枚举：关闭/15 分钟/每小时/每 6 小时/每天）。
    public var automaticTMDBMatchInterval: AutomaticScanInterval
    public var externalPlayerPath: String?
    public var debugLoggingEnabled: Bool
    public var privacyVaultName: String
    public var privacyPINEnabled: Bool
    public var openSubtitlesAPIKey: String?
    public var subtitleLanguage: String
    /// Last.fm 音乐数据源的 API Key（其余音乐源无需密钥）。
    public var lastfmAPIKey: String?
    /// Last.fm 听歌打卡（Scrobbling）开关。
    public var lastfmScrobblingEnabled: Bool
    /// Last.fm 应用 Shared Secret（打卡签名所需）。
    public var lastfmSharedSecret: String?
    /// 授权后获得的长期 session key。
    public var lastfmSessionKey: String?
    /// 已连接的 Last.fm 用户名。
    public var lastfmUsername: String?
    /// 后台任务（扫描 / Emby 同步）完成后是否发送系统通知（仅在 App 非前台时提醒）。
    public var notifyOnTaskCompletion: Bool
    /// 是否已完成首次启动引导（完成或跳过后置 true，不再弹出）。
    public var hasCompletedOnboarding: Bool
    /// Trakt 同步：应用凭据、授权令牌与开关。
    public var traktClientID: String?
    public var traktClientSecret: String?
    public var traktAccessToken: String?
    public var traktRefreshToken: String?
    public var traktSyncEnabled: Bool

    public init(
        defaultPlayer: DefaultPlayer = .builtIn,
        theme: AppTheme = .system,
        themePreset: AppThemePreset = .classic,
        themeBaseHex: String? = nil,
        themeHighlightHex: String? = nil,
        themeLightHex: String? = nil,
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
        keepLocalAudioWithAirPlay: Bool = false,
        tmdbAPIKey: String? = nil,
        tmdbLanguage: String = "zh-CN",
        metadataMatchTolerance: MetadataMatchTolerance = .standard,
        musicMetadataProvider: MusicMetadataProvider = .musicBrainz,
        lyricSyncAlgorithm: LyricSyncAlgorithm = .audioEnergy,
        musicLoudnessNormalization: MusicLoudnessNormalization = .track,
        musicTransitionMode: MusicTransitionMode = .immediate,
        musicSoftFadeDuration: Double = 0.8,
        musicEqualizerEnabled: Bool = false,
        musicEqualizerPreset: MusicEqualizerPreset = .flat,
        automaticScanInterval: AutomaticScanInterval = .disabled,
        automaticTMDBMatchInterval: AutomaticScanInterval = .disabled,
        externalPlayerPath: String? = nil,
        debugLoggingEnabled: Bool = false,
        privacyVaultName: String = "保险库",
        privacyPINEnabled: Bool = false,
        openSubtitlesAPIKey: String? = nil,
        subtitleLanguage: String = "zh-CN",
        lastfmAPIKey: String? = nil,
        lastfmScrobblingEnabled: Bool = false,
        lastfmSharedSecret: String? = nil,
        lastfmSessionKey: String? = nil,
        lastfmUsername: String? = nil,
        notifyOnTaskCompletion: Bool = false,
        hasCompletedOnboarding: Bool = false,
        traktClientID: String? = nil,
        traktClientSecret: String? = nil,
        traktAccessToken: String? = nil,
        traktRefreshToken: String? = nil,
        traktSyncEnabled: Bool = false
    ) {
        self.defaultPlayer = defaultPlayer
        self.theme = theme
        self.themePreset = themePreset
        self.themeBaseHex = themeBaseHex
        self.themeHighlightHex = themeHighlightHex
        self.themeLightHex = themeLightHex
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
        self.metadataMatchTolerance = metadataMatchTolerance
        self.musicMetadataProvider = musicMetadataProvider
        self.lyricSyncAlgorithm = lyricSyncAlgorithm
        self.musicLoudnessNormalization = musicLoudnessNormalization
        self.musicTransitionMode = musicTransitionMode
        self.musicSoftFadeDuration = min(max(musicSoftFadeDuration, 0.3), 2)
        self.musicEqualizerEnabled = musicEqualizerEnabled
        self.musicEqualizerPreset = musicEqualizerPreset
        self.automaticScanInterval = automaticScanInterval
        self.automaticTMDBMatchInterval = automaticTMDBMatchInterval
        self.externalPlayerPath = externalPlayerPath
        self.debugLoggingEnabled = debugLoggingEnabled
        self.privacyVaultName = privacyVaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "保险库" : privacyVaultName
        self.privacyPINEnabled = privacyPINEnabled
        self.openSubtitlesAPIKey = openSubtitlesAPIKey
        self.subtitleLanguage = subtitleLanguage.isEmpty ? "zh-CN" : subtitleLanguage
        self.lastfmAPIKey = lastfmAPIKey
        self.lastfmScrobblingEnabled = lastfmScrobblingEnabled
        self.lastfmSharedSecret = lastfmSharedSecret
        self.lastfmSessionKey = lastfmSessionKey
        self.lastfmUsername = lastfmUsername
        self.notifyOnTaskCompletion = notifyOnTaskCompletion
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.traktClientID = traktClientID
        self.traktClientSecret = traktClientSecret
        self.traktAccessToken = traktAccessToken
        self.traktRefreshToken = traktRefreshToken
        self.traktSyncEnabled = traktSyncEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case defaultPlayer
        case theme
        case themePreset
        case themeBaseHex
        case themeHighlightHex
        case themeLightHex
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
        case metadataMatchTolerance
        case musicMetadataProvider
        case lyricSyncAlgorithm
        case musicLoudnessNormalization
        case musicTransitionMode
        case musicSoftFadeDuration
        case musicEqualizerEnabled
        case musicEqualizerPreset
        case automaticScanInterval
        case automaticTMDBMatchInterval
        case externalPlayerPath
        case debugLoggingEnabled
        case privacyVaultName
        case privacyPINEnabled
        case openSubtitlesAPIKey
        case subtitleLanguage
        case lastfmAPIKey
        case lastfmScrobblingEnabled
        case lastfmSharedSecret
        case lastfmSessionKey
        case lastfmUsername
        case notifyOnTaskCompletion
        case hasCompletedOnboarding
        case traktClientID
        case traktClientSecret
        case traktAccessToken
        case traktRefreshToken
        case traktSyncEnabled
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
            themePreset: try container.decodeIfPresent(AppThemePreset.self, forKey: .themePreset) ?? defaults.themePreset,
            themeBaseHex: try container.decodeIfPresent(String.self, forKey: .themeBaseHex) ?? defaults.themeBaseHex,
            themeHighlightHex: try container.decodeIfPresent(String.self, forKey: .themeHighlightHex) ?? defaults.themeHighlightHex,
            themeLightHex: try container.decodeIfPresent(String.self, forKey: .themeLightHex) ?? defaults.themeLightHex,
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
            metadataMatchTolerance: try container.decodeIfPresent(MetadataMatchTolerance.self, forKey: .metadataMatchTolerance) ?? defaults.metadataMatchTolerance,
            musicMetadataProvider: try container.decodeIfPresent(MusicMetadataProvider.self, forKey: .musicMetadataProvider) ?? defaults.musicMetadataProvider,
            lyricSyncAlgorithm: try container.decodeIfPresent(LyricSyncAlgorithm.self, forKey: .lyricSyncAlgorithm) ?? defaults.lyricSyncAlgorithm,
            musicLoudnessNormalization: try container.decodeIfPresent(MusicLoudnessNormalization.self, forKey: .musicLoudnessNormalization) ?? defaults.musicLoudnessNormalization,
            musicTransitionMode: try container.decodeIfPresent(MusicTransitionMode.self, forKey: .musicTransitionMode) ?? defaults.musicTransitionMode,
            musicSoftFadeDuration: try container.decodeIfPresent(Double.self, forKey: .musicSoftFadeDuration) ?? defaults.musicSoftFadeDuration,
            musicEqualizerEnabled: try container.decodeIfPresent(Bool.self, forKey: .musicEqualizerEnabled) ?? defaults.musicEqualizerEnabled,
            musicEqualizerPreset: try container.decodeIfPresent(MusicEqualizerPreset.self, forKey: .musicEqualizerPreset) ?? defaults.musicEqualizerPreset,
            automaticScanInterval: try container.decodeIfPresent(AutomaticScanInterval.self, forKey: .automaticScanInterval) ?? defaults.automaticScanInterval,
            automaticTMDBMatchInterval: try container.decodeIfPresent(AutomaticScanInterval.self, forKey: .automaticTMDBMatchInterval) ?? defaults.automaticTMDBMatchInterval,
            externalPlayerPath: legacyExternalPlayerPath ?? defaults.externalPlayerPath,
            debugLoggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? defaults.debugLoggingEnabled,
            privacyVaultName: try container.decodeIfPresent(String.self, forKey: .privacyVaultName) ?? defaults.privacyVaultName,
            privacyPINEnabled: try container.decodeIfPresent(Bool.self, forKey: .privacyPINEnabled) ?? false,
            openSubtitlesAPIKey: try container.decodeIfPresent(String.self, forKey: .openSubtitlesAPIKey) ?? defaults.openSubtitlesAPIKey,
            subtitleLanguage: try container.decodeIfPresent(String.self, forKey: .subtitleLanguage) ?? defaults.subtitleLanguage,
            lastfmAPIKey: try container.decodeIfPresent(String.self, forKey: .lastfmAPIKey) ?? defaults.lastfmAPIKey,
            lastfmScrobblingEnabled: try container.decodeIfPresent(Bool.self, forKey: .lastfmScrobblingEnabled) ?? defaults.lastfmScrobblingEnabled,
            lastfmSharedSecret: try container.decodeIfPresent(String.self, forKey: .lastfmSharedSecret) ?? defaults.lastfmSharedSecret,
            lastfmSessionKey: try container.decodeIfPresent(String.self, forKey: .lastfmSessionKey) ?? defaults.lastfmSessionKey,
            lastfmUsername: try container.decodeIfPresent(String.self, forKey: .lastfmUsername) ?? defaults.lastfmUsername,
            notifyOnTaskCompletion: try container.decodeIfPresent(Bool.self, forKey: .notifyOnTaskCompletion) ?? defaults.notifyOnTaskCompletion,
            hasCompletedOnboarding: try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding,
            traktClientID: try container.decodeIfPresent(String.self, forKey: .traktClientID) ?? defaults.traktClientID,
            traktClientSecret: try container.decodeIfPresent(String.self, forKey: .traktClientSecret) ?? defaults.traktClientSecret,
            traktAccessToken: try container.decodeIfPresent(String.self, forKey: .traktAccessToken) ?? defaults.traktAccessToken,
            traktRefreshToken: try container.decodeIfPresent(String.self, forKey: .traktRefreshToken) ?? defaults.traktRefreshToken,
            traktSyncEnabled: try container.decodeIfPresent(Bool.self, forKey: .traktSyncEnabled) ?? defaults.traktSyncEnabled
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
