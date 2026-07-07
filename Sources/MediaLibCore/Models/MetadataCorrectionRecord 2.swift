import Foundation

public enum MetadataCorrectionField: String, Codable, CaseIterable, Identifiable, Sendable {
    case title
    case originalTitle
    case artist
    case album
    case trackNumber
    case year
    case overview
    case posterPath
    case backdropPath
    case rating
    case userRating
    case runtime
    case externalID
    case metadataProvider
    case collectionTitle
    case genre

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: return "标题"
        case .originalTitle: return "原始标题"
        case .artist: return "艺术家"
        case .album: return "专辑"
        case .trackNumber: return "曲目号"
        case .year: return "年份"
        case .overview: return "简介"
        case .posterPath: return "封面"
        case .backdropPath: return "背景图"
        case .rating: return "资料评分"
        case .userRating: return "用户评级"
        case .runtime: return "片长"
        case .externalID: return "外部 ID"
        case .metadataProvider: return "元数据来源"
        case .collectionTitle: return "合集"
        case .genre: return "分类标签"
        }
    }

    public var databaseColumn: String {
        switch self {
        case .title: return "title"
        case .originalTitle: return "original_title"
        case .artist: return "artist"
        case .album: return "album"
        case .trackNumber: return "track_number"
        case .year: return "year"
        case .overview: return "overview"
        case .posterPath: return "poster_path"
        case .backdropPath: return "backdrop_path"
        case .rating: return "rating"
        case .userRating: return "user_rating"
        case .runtime: return "runtime"
        case .externalID: return "external_id"
        case .metadataProvider: return "metadata_provider"
        case .collectionTitle: return "collection_title"
        case .genre: return "genre"
        }
    }

    public var storageKind: MetadataCorrectionValueKind {
        switch self {
        case .trackNumber, .year, .runtime:
            return .integer
        case .rating, .userRating:
            return .real
        default:
            return .text
        }
    }

    public func encodedValue(from item: MediaItem) -> String? {
        switch self {
        case .title: return item.title
        case .originalTitle: return item.originalTitle
        case .artist: return item.artist
        case .album: return item.album
        case .trackNumber: return item.trackNumber.map(String.init)
        case .year: return item.year.map(String.init)
        case .overview: return item.overview
        case .posterPath: return item.posterPath
        case .backdropPath: return item.backdropPath
        case .rating: return item.rating.map(Self.encodeDouble)
        case .userRating: return item.userRating.map(Self.encodeDouble)
        case .runtime: return item.runtime.map(String.init)
        case .externalID: return item.externalID
        case .metadataProvider: return item.metadataProvider
        case .collectionTitle: return item.collectionTitle
        case .genre: return item.genre
        }
    }

    private static func encodeDouble(_ value: Double) -> String {
        String(format: "%.6f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

public enum MetadataCorrectionValueKind: String, Codable, Sendable {
    case text
    case integer
    case real
}

public struct MetadataCorrectionFieldChange: Hashable, Sendable {
    public var field: MetadataCorrectionField
    public var oldValue: String?
    public var newValue: String?

    public init(field: MetadataCorrectionField, oldValue: String?, newValue: String?) {
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

public struct MetadataCorrectionRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var batchID: String
    public var mediaID: String
    public var field: MetadataCorrectionField
    public var oldValue: String?
    public var newValue: String?
    public var source: String
    public var createdAt: Date
    public var undoneAt: Date?

    public init(
        id: String = UUID().uuidString,
        batchID: String,
        mediaID: String,
        field: MetadataCorrectionField,
        oldValue: String?,
        newValue: String?,
        source: String,
        createdAt: Date = Date(),
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.mediaID = mediaID
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.source = source
        self.createdAt = createdAt
        self.undoneAt = undoneAt
    }
}

public struct MetadataCorrectionBatchSummary: Identifiable, Codable, Hashable, Sendable {
    public var batchID: String
    public var mediaID: String
    public var source: String
    public var createdAt: Date
    public var fieldCount: Int
    public var fields: [MetadataCorrectionField]

    public var id: String { "\(mediaID)-\(batchID)" }

    public init(
        batchID: String,
        mediaID: String,
        source: String,
        createdAt: Date,
        fieldCount: Int,
        fields: [MetadataCorrectionField]
    ) {
        self.batchID = batchID
        self.mediaID = mediaID
        self.source = source
        self.createdAt = createdAt
        self.fieldCount = max(fieldCount, 0)
        self.fields = fields
    }
}
