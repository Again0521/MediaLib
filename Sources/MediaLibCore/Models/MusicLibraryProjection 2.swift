import Foundation

public struct MusicAlbumSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var titleKey: String
    public var artistKey: String
    public var trackCount: Int
    public var favoriteCount: Int
    public var remoteCount: Int
    public var playCount: Int
    public var totalDuration: Double?
    public var coverPath: String?
    public var latestUpdatedAt: Date
    public var trackIDs: [String]

    public init(
        id: String,
        title: String,
        artist: String,
        titleKey: String,
        artistKey: String,
        trackCount: Int,
        favoriteCount: Int,
        remoteCount: Int,
        playCount: Int,
        totalDuration: Double?,
        coverPath: String?,
        latestUpdatedAt: Date,
        trackIDs: [String]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.titleKey = titleKey
        self.artistKey = artistKey
        self.trackCount = trackCount
        self.favoriteCount = favoriteCount
        self.remoteCount = remoteCount
        self.playCount = playCount
        self.totalDuration = totalDuration
        self.coverPath = coverPath
        self.latestUpdatedAt = latestUpdatedAt
        self.trackIDs = trackIDs
    }
}

public struct MusicArtistSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var nameKey: String
    public var trackCount: Int
    public var albumCount: Int
    public var favoriteCount: Int
    public var remoteCount: Int
    public var playCount: Int
    public var coverPath: String?
    public var latestUpdatedAt: Date
    public var trackIDs: [String]

    public init(
        id: String,
        name: String,
        nameKey: String,
        trackCount: Int,
        albumCount: Int,
        favoriteCount: Int,
        remoteCount: Int,
        playCount: Int,
        coverPath: String?,
        latestUpdatedAt: Date,
        trackIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.nameKey = nameKey
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.favoriteCount = favoriteCount
        self.remoteCount = remoteCount
        self.playCount = playCount
        self.coverPath = coverPath
        self.latestUpdatedAt = latestUpdatedAt
        self.trackIDs = trackIDs
    }
}

public struct MusicLibraryProjectionSnapshot: Sendable {
    public var albums: [MusicAlbumSummary]
    public var artists: [MusicArtistSummary]
    public var rebuiltAt: Date?

    public init(albums: [MusicAlbumSummary], artists: [MusicArtistSummary], rebuiltAt: Date?) {
        self.albums = albums
        self.artists = artists
        self.rebuiltAt = rebuiltAt
    }
}

public struct MusicProjectionRebuildResult: Equatable, Sendable {
    public var musicItemCount: Int
    public var albumCount: Int
    public var artistCount: Int
    public var rebuiltAt: Date

    public init(musicItemCount: Int, albumCount: Int, artistCount: Int, rebuiltAt: Date) {
        self.musicItemCount = musicItemCount
        self.albumCount = albumCount
        self.artistCount = artistCount
        self.rebuiltAt = rebuiltAt
    }
}

public enum MusicProjectionMaintenancePlan: Equatable, Sendable {
    case none
    case bootstrap
    case incremental
}

public struct MusicProjectionIncrementalResult: Equatable, Sendable {
    public var musicItemCount: Int
    public var affectedAlbumCount: Int
    public var affectedArtistCount: Int
    public var rebuiltAt: Date

    public init(
        musicItemCount: Int,
        affectedAlbumCount: Int,
        affectedArtistCount: Int,
        rebuiltAt: Date
    ) {
        self.musicItemCount = musicItemCount
        self.affectedAlbumCount = affectedAlbumCount
        self.affectedArtistCount = affectedArtistCount
        self.rebuiltAt = rebuiltAt
    }
}
