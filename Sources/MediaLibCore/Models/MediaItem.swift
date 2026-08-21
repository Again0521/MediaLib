import Foundation

public struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var type: MediaType
    public var title: String
    public var originalTitle: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var overview: String?
    /// 类型 / 题材标签（逗号分隔的名称，如 "动作, 科幻"），来自 TMDB genre。
    public var genre: String?
    public var posterPath: String?
    public var backdropPath: String?
    /// 服务端 / TMDB 等资料源评分，按 0-10 口径保存；用户五角星评级单独写入 userRating。
    public var rating: Double?
    /// 用户手动评级，按 1-5 星口径保存。nil 表示用户尚未评级。
    public var userRating: Double?
    public var runtime: Int?
    public var sourcePath: String?
    public var parentID: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var filePath: String?
    public var fileSize: Int64?
    public var videoCodec: String?
    public var audioCodec: String?
    public var resolution: String?
    public var videoBitrate: Int64?
    public var duration: Double?
    public var loudnessTrackGainDB: Double?
    public var loudnessAlbumGainDB: Double?
    public var loudnessTrackPeak: Double?
    public var loudnessAlbumPeak: Double?
    public var playCount: Int?
    public var playPosition: Double
    public var playProgress: Double
    public var watched: Bool
    public var favorite: Bool
    public var watchlist: Bool
    public var externalID: String?
    public var metadataProvider: String?
    public var collectionTitle: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastPlayedAt: Date?
    /// 这首曲目有没有歌词——内嵌标签或同目录外挂文件，判定见 `MusicLyricsPresence`。
    /// 扫描时落库，两端读同一个值；非音乐条目恒为 `false`。
    public var hasLyrics: Bool

    /// 缺键即取默认值，而不是整条载荷解不出来。
    ///
    /// 合成的解码器要求每个非可选属性都在载荷里出现，于是每加一个新字段，所有
    /// 早先写出的载荷就都解不动了——`has_lyrics` 落库那次正是这样被一条用例拦
    /// 下的。这里逐键 `decodeIfPresent`，新增字段对旧载荷从此是兼容的。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.type = try values.decodeIfPresent(MediaType.self, forKey: .type) ?? .other
        let decodedTitle = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.title = decodedTitle.isEmpty ? "未命名媒体" : decodedTitle
        self.originalTitle = try values.decodeIfPresent(String.self, forKey: .originalTitle)
        self.artist = try values.decodeIfPresent(String.self, forKey: .artist)
        self.album = try values.decodeIfPresent(String.self, forKey: .album)
        self.trackNumber = try values.decodeIfPresent(Int.self, forKey: .trackNumber)
        self.year = try values.decodeIfPresent(Int.self, forKey: .year)
        self.overview = try values.decodeIfPresent(String.self, forKey: .overview)
        self.genre = try values.decodeIfPresent(String.self, forKey: .genre)
        self.posterPath = try values.decodeIfPresent(String.self, forKey: .posterPath)
        self.backdropPath = try values.decodeIfPresent(String.self, forKey: .backdropPath)
        self.rating = try values.decodeIfPresent(Double.self, forKey: .rating)
        self.userRating = try values.decodeIfPresent(Double.self, forKey: .userRating)
        self.runtime = try values.decodeIfPresent(Int.self, forKey: .runtime)
        self.sourcePath = try values.decodeIfPresent(String.self, forKey: .sourcePath)
        self.parentID = try values.decodeIfPresent(String.self, forKey: .parentID)
        self.seasonNumber = try values.decodeIfPresent(Int.self, forKey: .seasonNumber)
        self.episodeNumber = try values.decodeIfPresent(Int.self, forKey: .episodeNumber)
        self.filePath = try values.decodeIfPresent(String.self, forKey: .filePath)
        self.fileSize = try values.decodeIfPresent(Int64.self, forKey: .fileSize)
        self.videoCodec = try values.decodeIfPresent(String.self, forKey: .videoCodec)
        self.audioCodec = try values.decodeIfPresent(String.self, forKey: .audioCodec)
        self.resolution = try values.decodeIfPresent(String.self, forKey: .resolution)
        self.videoBitrate = try values.decodeIfPresent(Int64.self, forKey: .videoBitrate)
        self.duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        self.loudnessTrackGainDB = try values.decodeIfPresent(Double.self, forKey: .loudnessTrackGainDB)
        self.loudnessAlbumGainDB = try values.decodeIfPresent(Double.self, forKey: .loudnessAlbumGainDB)
        self.loudnessTrackPeak = try values.decodeIfPresent(Double.self, forKey: .loudnessTrackPeak)
        self.loudnessAlbumPeak = try values.decodeIfPresent(Double.self, forKey: .loudnessAlbumPeak)
        self.playCount = try values.decodeIfPresent(Int.self, forKey: .playCount)
        self.externalID = try values.decodeIfPresent(String.self, forKey: .externalID)
        self.metadataProvider = try values.decodeIfPresent(String.self, forKey: .metadataProvider)
        self.collectionTitle = try values.decodeIfPresent(String.self, forKey: .collectionTitle)
        self.lastPlayedAt = try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        self.playPosition = try values.decodeIfPresent(Double.self, forKey: .playPosition) ?? 0
        self.playProgress = try values.decodeIfPresent(Double.self, forKey: .playProgress) ?? 0
        self.watched = try values.decodeIfPresent(Bool.self, forKey: .watched) ?? false
        self.favorite = try values.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        self.watchlist = try values.decodeIfPresent(Bool.self, forKey: .watchlist) ?? false
        self.hasLyrics = try values.decodeIfPresent(Bool.self, forKey: .hasLyrics) ?? false
        self.createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public init(
        id: String,
        type: MediaType,
        title: String,
        originalTitle: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        year: Int? = nil,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        rating: Double? = nil,
        userRating: Double? = nil,
        runtime: Int? = nil,
        sourcePath: String? = nil,
        parentID: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        filePath: String? = nil,
        fileSize: Int64? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        resolution: String? = nil,
        videoBitrate: Int64? = nil,
        duration: Double? = nil,
        loudnessTrackGainDB: Double? = nil,
        loudnessAlbumGainDB: Double? = nil,
        loudnessTrackPeak: Double? = nil,
        loudnessAlbumPeak: Double? = nil,
        playCount: Int? = 0,
        playPosition: Double = 0,
        playProgress: Double = 0,
        watched: Bool = false,
        favorite: Bool = false,
        watchlist: Bool = false,
        externalID: String? = nil,
        metadataProvider: String? = nil,
        collectionTitle: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        genre: String? = nil,
        hasLyrics: Bool = false
    ) {
        self.id = id
        self.type = type
        self.title = title.isEmpty ? "未命名媒体" : title
        self.originalTitle = originalTitle
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.year = year
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.rating = rating
        self.userRating = userRating
        self.runtime = runtime
        self.sourcePath = sourcePath
        self.parentID = parentID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.filePath = filePath
        self.fileSize = fileSize
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.resolution = resolution
        self.videoBitrate = videoBitrate
        self.duration = duration
        self.loudnessTrackGainDB = loudnessTrackGainDB
        self.loudnessAlbumGainDB = loudnessAlbumGainDB
        self.loudnessTrackPeak = loudnessTrackPeak
        self.loudnessAlbumPeak = loudnessAlbumPeak
        self.playCount = playCount
        self.playPosition = playPosition
        self.playProgress = playProgress
        self.watched = watched
        self.favorite = favorite
        self.watchlist = watchlist
        self.externalID = externalID
        self.metadataProvider = metadataProvider
        self.collectionTitle = collectionTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPlayedAt = lastPlayedAt
        self.genre = genre
        self.hasLyrics = hasLyrics
    }

    public var displayYear: String {
        year.map(String.init) ?? "未知年份"
    }

    public var isRemoteResource: Bool {
        guard let filePath,
              let scheme = URL(string: filePath)?.scheme?.lowercased() else {
            return false
        }
        // 除 Emby/Plex 的 http(s) 外，也认手动打开的常见串流协议。
        return ["http", "https", "rtsp", "rtmp", "rtp", "mms", "srt", "udp", "ftp"].contains(scheme)
    }

    public var hasEmbeddedArtwork: Bool {
        posterPath?.contains("-embedded-artwork.") == true
    }

    public var sortKey: String {
        "\(title.localizedLowercase)-\(seasonNumber ?? 0)-\(episodeNumber ?? 0)"
    }

    public var episodeLabel: String {
        if let seasonNumber, let episodeNumber {
            return String(format: "S%02dE%02d", seasonNumber, episodeNumber)
        }
        if let episodeNumber {
            return String(format: "第 %02d 集", episodeNumber)
        }
        return "剧集"
    }

    public var cardTitle: String {
        type == .episode ? "\(episodeLabel)  \(title)" : title
    }

    public var artistAlbumLine: String? {
        let values = [artist, album].compactMap { value in
            value?.isEmpty == false ? value : nil
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    public var hasPlaybackTrace: Bool {
        lastPlayedAt != nil ||
            (playPosition.isFinite && playPosition > 0) ||
            (playProgress.isFinite && playProgress > 0) ||
            watched
    }
}
