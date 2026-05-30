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
    public var posterPath: String?
    public var backdropPath: String?
    public var rating: Double?
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
    public var playPosition: Double
    public var playProgress: Double
    public var watched: Bool
    public var favorite: Bool
    public var externalID: String?
    public var metadataProvider: String?
    public var collectionTitle: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastPlayedAt: Date?

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
        playPosition: Double = 0,
        playProgress: Double = 0,
        watched: Bool = false,
        favorite: Bool = false,
        externalID: String? = nil,
        metadataProvider: String? = nil,
        collectionTitle: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastPlayedAt: Date? = nil
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
        self.playPosition = playPosition
        self.playProgress = playProgress
        self.watched = watched
        self.favorite = favorite
        self.externalID = externalID
        self.metadataProvider = metadataProvider
        self.collectionTitle = collectionTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPlayedAt = lastPlayedAt
    }

    public var displayYear: String {
        year.map(String.init) ?? "未知年份"
    }

    public var isPlayable: Bool {
        guard let filePath, !filePath.isEmpty else { return false }
        if isRemoteResource {
            return true
        }
        return FileManager.default.fileExists(atPath: filePath)
    }

    public var isRemoteResource: Bool {
        guard let filePath,
              let scheme = URL(string: filePath)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
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
}
