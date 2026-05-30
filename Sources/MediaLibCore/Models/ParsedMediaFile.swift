import Foundation

public enum ParsedMediaKind: Equatable {
    case movie
    case episode
}

public struct ParsedMediaFile: Equatable {
    public var kind: ParsedMediaKind
    public var title: String
    public var year: Int?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var seriesDirectoryPath: String?

    public init(
        kind: ParsedMediaKind,
        title: String,
        year: Int? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        seriesDirectoryPath: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.year = year
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.seriesDirectoryPath = seriesDirectoryPath
    }
}
