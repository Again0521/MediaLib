import Foundation

public struct MediaExternalID: Codable, Hashable, Sendable {
    public var provider: String
    public var value: String

    public init(provider: String, value: String) {
        self.provider = provider
        self.value = value
    }
}

public struct MediaDetailMetadata: Codable, Hashable, Sendable {
    public var mediaID: String
    public var status: String?
    public var firstAirDate: String?
    public var endDate: String?
    public var seasonCount: Int?
    public var episodeCount: Int?
    public var contentRating: String?
    public var originalLanguage: String?
    public var countries: [String]
    public var productionCompanies: [String]
    public var networks: [String]
    public var trailerURL: String?
    public var provider: String
    public var language: String
    public var fetchedAt: Date
    public var fetchVersion: Int

    public init(
        mediaID: String,
        status: String? = nil,
        firstAirDate: String? = nil,
        endDate: String? = nil,
        seasonCount: Int? = nil,
        episodeCount: Int? = nil,
        contentRating: String? = nil,
        originalLanguage: String? = nil,
        countries: [String] = [],
        productionCompanies: [String] = [],
        networks: [String] = [],
        trailerURL: String? = nil,
        provider: String,
        language: String,
        fetchedAt: Date = Date(),
        fetchVersion: Int = 1
    ) {
        self.mediaID = mediaID
        self.status = status
        self.firstAirDate = firstAirDate
        self.endDate = endDate
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
        self.contentRating = contentRating
        self.originalLanguage = originalLanguage
        self.countries = countries
        self.productionCompanies = productionCompanies
        self.networks = networks
        self.trailerURL = trailerURL
        self.provider = provider
        self.language = language
        self.fetchedAt = fetchedAt
        self.fetchVersion = fetchVersion
    }
}

public struct MediaPersonWork: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var year: Int?
    public var role: String?
    public var mediaKind: String
    public var posterURL: String?
    public var popularity: Double?

    public init(
        id: String,
        title: String,
        year: Int? = nil,
        role: String? = nil,
        mediaKind: String,
        posterURL: String? = nil,
        popularity: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.role = role
        self.mediaKind = mediaKind
        self.posterURL = posterURL
        self.popularity = popularity
    }
}

public struct MediaPerson: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var profileURL: String?
    public var biography: String?
    public var birthday: String?
    public var deathday: String?
    public var placeOfBirth: String?
    public var knownForDepartment: String?
    public var externalIDs: [MediaExternalID]
    public var knownFor: [MediaPersonWork]
    public var filmography: [MediaPersonWork]
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        profileURL: String? = nil,
        biography: String? = nil,
        birthday: String? = nil,
        deathday: String? = nil,
        placeOfBirth: String? = nil,
        knownForDepartment: String? = nil,
        externalIDs: [MediaExternalID] = [],
        knownFor: [MediaPersonWork] = [],
        filmography: [MediaPersonWork] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.profileURL = profileURL
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.placeOfBirth = placeOfBirth
        self.knownForDepartment = knownForDepartment
        self.externalIDs = externalIDs
        self.knownFor = knownFor
        self.filmography = filmography
        self.updatedAt = updatedAt
    }
}

public struct MediaCredit: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var mediaID: String
    public var personID: String
    public var category: String
    public var role: String
    public var department: String?
    public var order: Int

    public init(
        id: String,
        mediaID: String,
        personID: String,
        category: String,
        role: String,
        department: String? = nil,
        order: Int = 0
    ) {
        self.id = id
        self.mediaID = mediaID
        self.personID = personID
        self.category = category
        self.role = role
        self.department = department
        self.order = order
    }
}

public struct MediaArtwork: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var mediaID: String
    public var kind: String
    public var thumbURL: String
    public var fullURL: String
    public var language: String?
    public var aspectRatio: Double
    public var order: Int
    public var localPath: String?

    public init(
        id: String,
        mediaID: String,
        kind: String,
        thumbURL: String,
        fullURL: String,
        language: String? = nil,
        aspectRatio: Double,
        order: Int = 0,
        localPath: String? = nil
    ) {
        self.id = id
        self.mediaID = mediaID
        self.kind = kind
        self.thumbURL = thumbURL
        self.fullURL = fullURL
        self.language = language
        self.aspectRatio = aspectRatio
        self.order = order
        self.localPath = localPath
    }
}

public struct MediaRelatedTitle: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var mediaID: String
    public var relation: String
    public var externalID: String
    public var title: String
    public var year: Int?
    public var posterURL: String?
    public var overview: String?
    public var rating: Double?
    public var popularity: Double?
    public var localMediaID: String?
    public var order: Int

    public init(
        id: String,
        mediaID: String,
        relation: String,
        externalID: String,
        title: String,
        year: Int? = nil,
        posterURL: String? = nil,
        overview: String? = nil,
        rating: Double? = nil,
        popularity: Double? = nil,
        localMediaID: String? = nil,
        order: Int = 0
    ) {
        self.id = id
        self.mediaID = mediaID
        self.relation = relation
        self.externalID = externalID
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.overview = overview
        self.rating = rating
        self.popularity = popularity
        self.localMediaID = localMediaID
        self.order = order
    }
}

public struct MediaDetailSnapshot: Codable, Hashable, Sendable {
    public var metadata: MediaDetailMetadata
    public var externalIDs: [MediaExternalID]
    public var people: [MediaPerson]
    public var credits: [MediaCredit]
    public var artwork: [MediaArtwork]
    public var relatedTitles: [MediaRelatedTitle]

    public init(
        metadata: MediaDetailMetadata,
        externalIDs: [MediaExternalID] = [],
        people: [MediaPerson] = [],
        credits: [MediaCredit] = [],
        artwork: [MediaArtwork] = [],
        relatedTitles: [MediaRelatedTitle] = []
    ) {
        self.metadata = metadata
        self.externalIDs = externalIDs
        self.people = people
        self.credits = credits
        self.artwork = artwork
        self.relatedTitles = relatedTitles
    }
}

public struct MediaPersonLibraryCredit: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(media.id)-\(credit.id)" }
    public var media: MediaItem
    public var credit: MediaCredit

    public init(media: MediaItem, credit: MediaCredit) {
        self.media = media
        self.credit = credit
    }
}
