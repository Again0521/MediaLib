import Foundation
import MediaLibCore

struct TMDBPerson: Identifiable, Hashable, Sendable {
    let id: Int
    let stableID: String
    let name: String
    let role: String
    let profileURL: String?
    let category: String
    let department: String?

    init(
        id: Int,
        stableID: String? = nil,
        name: String,
        role: String,
        profileURL: String?,
        category: String = "cast",
        department: String? = nil
    ) {
        self.id = id
        self.stableID = stableID ?? "tmdb-person-\(id)"
        self.name = name
        self.role = role
        self.profileURL = profileURL
        self.category = category
        self.department = department
    }
}

struct TMDBSimilarTitle: Identifiable, Hashable, Sendable {
    /// 形如 "tmdb:movie:123" / "tmdb:tv:123"，用于和本地条目的 externalID 交叉匹配。
    let id: String
    let title: String
    let year: Int?
    let posterURL: String?
    let overview: String?
    let rating: Double?
    let popularity: Double?
    let relation: String

    init(
        id: String,
        title: String,
        year: Int?,
        posterURL: String?,
        overview: String? = nil,
        rating: Double? = nil,
        popularity: Double? = nil,
        relation: String = "similar"
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.overview = overview
        self.rating = rating
        self.popularity = popularity
        self.relation = relation
    }
}

/// TMDB 艺术照（剧照 backdrop / 海报 poster）。缩略图用 w500，全屏看大图用 original。
struct TMDBImage: Identifiable, Hashable, Sendable {
    let id: String
    let thumbURL: String
    let fullURL: String
    let aspectRatio: Double
    let kind: String
    let language: String?

    init(
        id: String,
        thumbURL: String,
        fullURL: String,
        aspectRatio: Double,
        kind: String = "backdrop",
        language: String? = nil
    ) {
        self.id = id
        self.thumbURL = thumbURL
        self.fullURL = fullURL
        self.aspectRatio = aspectRatio
        self.kind = kind
        self.language = language
    }
}

struct TMDBEnrichment: Sendable {
    var title: String?
    var originalTitle: String?
    var overview: String?
    var posterURL: String?
    var backdropURL: String?
    var rating: Double?
    var runtime: Int?
    var genres: [String] = []
    var cast: [TMDBPerson]
    var crew: [TMDBPerson]
    var similar: [TMDBSimilarTitle]
    var images: [TMDBImage]
    var trailerURL: String?
    var imdbID: String?
    /// TMDB 条目页链接所需（movie/tv + 数字 ID）；Emby 条目从 ProviderIds 解析，本地从 externalID 解析。
    var tmdbKind: String?
    var tmdbID: String?
    var status: String?
    var firstAirDate: String?
    var endDate: String?
    var seasonCount: Int?
    var episodeCount: Int?
    var contentRating: String?
    var originalLanguage: String?
    var countries: [String] = []
    var productionCompanies: [String] = []
    var networks: [String] = []

    var isEmpty: Bool {
        title == nil &&
            overview == nil &&
            cast.isEmpty &&
            crew.isEmpty &&
            similar.isEmpty &&
            images.isEmpty &&
            trailerURL == nil &&
            imdbID == nil &&
            tmdbID == nil
    }
}

/// 拉取 TMDB 演职人员 + 相关推荐（一次 append_to_response 请求拿全），用于详情页内容深度展示。
struct TMDBEnrichmentService {
    func fetch(externalID: String, apiKey: String?, language: String) async throws -> TMDBEnrichment? {
        guard let (kind, numericID) = Self.parse(externalID: externalID) else { return nil }
        let token = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw MetadataSearchError.missingTMDBKey }

        let resolvedLanguage = language.isEmpty ? "zh-CN" : language
        let imageLanguages = Self.imageLanguageFilter(for: resolvedLanguage)
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(kind)/\(numericID)")
        components?.queryItems = [
            URLQueryItem(name: "language", value: resolvedLanguage),
            URLQueryItem(
                name: "append_to_response",
                value: kind == "tv"
                    ? "aggregate_credits,recommendations,similar,videos,images,external_ids,content_ratings"
                    : "credits,recommendations,similar,videos,images,external_ids,release_dates"
            ),
            URLQueryItem(name: "include_image_language", value: imageLanguages)
        ]
        let data = try await Self.performRequest(components: components, token: token)
        let decoded = try JSONDecoder().decode(TMDBDetailResponse.self, from: data)

        let castSource = kind == "tv"
            ? (decoded.aggregateCredits?.cast ?? []).map(\.flattened)
            : (decoded.credits?.cast ?? [])
        let cast = castSource
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
            .prefix(16)
            .map { member in
                TMDBPerson(
                    id: member.id,
                    name: member.name,
                    role: member.character.flatMap { $0.isEmpty ? nil : $0 } ?? "演员",
                    profileURL: Self.profileURL(member.profilePath),
                    category: "cast",
                    department: "Acting"
                )
            }

        var crew: [TMDBPerson] = []
        var seenCrew = Set<Int>()
        for creator in decoded.createdBy ?? [] where seenCrew.insert(creator.id).inserted {
            crew.append(TMDBPerson(
                id: creator.id,
                name: creator.name,
                role: "主创",
                profileURL: Self.profileURL(creator.profilePath),
                category: "crew",
                department: "Creator"
            ))
        }
        let keyJobs = ["Director", "Writer", "Screenplay", "Producer", "Original Music Composer"]
        let crewSource = kind == "tv"
            ? (decoded.aggregateCredits?.crew ?? []).map(\.flattened)
            : (decoded.credits?.crew ?? [])
        for member in crewSource {
            guard let job = member.job, keyJobs.contains(job), seenCrew.insert(member.id).inserted else { continue }
            crew.append(TMDBPerson(
                id: member.id,
                name: member.name,
                role: Self.localizedJob(job),
                profileURL: Self.profileURL(member.profilePath),
                category: "crew",
                department: member.department
            ))
            if crew.count >= 8 { break }
        }

        var relatedSeen = Set<Int>()
        let recommendations = (decoded.recommendations?.results ?? []).prefix(16).compactMap {
            Self.relatedTitle(from: $0, kind: kind, relation: "recommendation", seen: &relatedSeen)
        }
        let similar = recommendations + (decoded.similar?.results ?? [])
            .prefix(16)
            .compactMap { item -> TMDBSimilarTitle? in
                Self.relatedTitle(from: item, kind: kind, relation: "similar", seen: &relatedSeen)
            }

        let trailerURL = Self.trailerURL(from: decoded.videos?.results ?? [])

        let backdrops = (decoded.images?.backdrops ?? []).prefix(14)
        let posters = (decoded.images?.posters ?? []).prefix(8)
        let images = (Array(backdrops).map { ($0, "backdrop") } + Array(posters).map { ($0, "poster") }).compactMap { pair -> TMDBImage? in
            let (dto, imageKind) = pair
            guard let path = dto.filePath, !path.isEmpty else { return nil }
            return TMDBImage(
                id: path,
                thumbURL: "https://image.tmdb.org/t/p/w500\(path)",
                fullURL: "https://image.tmdb.org/t/p/original\(path)",
                aspectRatio: dto.aspectRatio ?? 1.78,
                kind: imageKind,
                language: dto.iso6391
            )
        }

        let enrichment = TMDBEnrichment(
            title: decoded.title ?? decoded.name,
            originalTitle: decoded.originalTitle ?? decoded.originalName,
            overview: decoded.overview,
            posterURL: decoded.posterPath.map { "https://image.tmdb.org/t/p/w500\($0)" },
            backdropURL: decoded.backdropPath.map { "https://image.tmdb.org/t/p/w780\($0)" },
            rating: decoded.voteAverage,
            runtime: decoded.runtime ?? decoded.episodeRunTime?.first,
            genres: (decoded.genres ?? []).compactMap(\.name),
            cast: Array(cast),
            crew: crew,
            similar: similar,
            images: images,
            trailerURL: trailerURL,
            imdbID: decoded.externalIds?.imdbId?.isEmpty == false ? decoded.externalIds?.imdbId : nil,
            tmdbKind: kind,
            tmdbID: numericID,
            status: decoded.status,
            firstAirDate: decoded.firstAirDate ?? decoded.releaseDate,
            endDate: decoded.lastAirDate,
            seasonCount: decoded.numberOfSeasons,
            episodeCount: decoded.numberOfEpisodes,
            contentRating: Self.contentRating(from: decoded, kind: kind),
            originalLanguage: decoded.originalLanguage,
            countries: (decoded.originCountry ?? []) + (decoded.productionCountries ?? []).compactMap(\.name),
            productionCompanies: (decoded.productionCompanies ?? []).compactMap(\.name),
            networks: (decoded.networks ?? []).compactMap(\.name)
        )
        return enrichment.isEmpty ? nil : enrichment
    }

    func fetchPerson(personID: Int, apiKey: String?, language: String) async throws -> MediaPerson {
        let token = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw MetadataSearchError.missingTMDBKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3/person/\(personID)")
        components?.queryItems = [
            URLQueryItem(name: "language", value: language.isEmpty ? "zh-CN" : language),
            URLQueryItem(name: "append_to_response", value: "combined_credits,external_ids")
        ]
        let data = try await Self.performRequest(components: components, token: token)
        let detail = try JSONDecoder().decode(TMDBPersonDetailResponse.self, from: data)
        let works = Self.personWorks(from: detail.combinedCredits)
        let knownFor = Array(works.sorted {
            ($0.popularity ?? 0) > ($1.popularity ?? 0)
        }.prefix(12))
        var externalIDs = [MediaExternalID(provider: "tmdb", value: "\(personID)")]
        if let imdb = detail.externalIds?.imdbId, !imdb.isEmpty {
            externalIDs.append(MediaExternalID(provider: "imdb", value: imdb))
        }
        return MediaPerson(
            id: "tmdb-person-\(personID)",
            name: detail.name,
            profileURL: Self.profileURL(detail.profilePath),
            biography: detail.biography?.trimmingCharacters(in: .whitespacesAndNewlines),
            birthday: detail.birthday,
            deathday: detail.deathday,
            placeOfBirth: detail.placeOfBirth,
            knownForDepartment: detail.knownForDepartment,
            externalIDs: externalIDs,
            knownFor: knownFor,
            filmography: works,
            updatedAt: Date()
        )
    }

    func snapshot(
        mediaID: String,
        externalID: String,
        apiKey: String?,
        language: String
    ) async throws -> MediaDetailSnapshot? {
        guard let enrichment = try await fetch(externalID: externalID, apiKey: apiKey, language: language) else {
            return nil
        }
        return enrichment.snapshot(mediaID: mediaID, provider: "TMDB", language: language)
    }

    /// TMDB 艺术照按语言过滤：保留当前语言、无文字版(null)与英文，覆盖大多数剧照。
    private static func imageLanguageFilter(for language: String) -> String {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        var langs = [base, "null", "en"]
        var seen = Set<String>()
        langs = langs.filter { seen.insert($0).inserted }
        return langs.joined(separator: ",")
    }

    /// 选出最佳预告片：优先 官方 YouTube Trailer，其次任意 YouTube Trailer，再次任意 YouTube 视频。
    private static func trailerURL(from videos: [TMDBVideo]) -> String? {
        let youtube = videos.filter { ($0.site ?? "").lowercased() == "youtube" && !($0.key ?? "").isEmpty }
        let pick = youtube.first { ($0.type ?? "") == "Trailer" && $0.official == true }
            ?? youtube.first { ($0.type ?? "") == "Trailer" }
            ?? youtube.first
        guard let key = pick?.key else { return nil }
        return "https://www.youtube.com/watch?v=\(key)"
    }

    private static func parse(externalID: String) -> (kind: String, id: String)? {
        let parts = externalID.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "tmdb", !parts[2].isEmpty else { return nil }
        let kind = parts[1] == "movie" ? "movie" : (parts[1] == "tv" ? "tv" : "")
        guard !kind.isEmpty else { return nil }
        return (kind, parts[2])
    }

    private static func profileURL(_ path: String?) -> String? {
        path.map { "https://image.tmdb.org/t/p/w185\($0)" }
    }

    private static func posterURL(_ path: String?) -> String? {
        path.map { "https://image.tmdb.org/t/p/w342\($0)" }
    }

    private static func relatedTitle(
        from item: TMDBSimilarItem,
        kind: String,
        relation: String,
        seen: inout Set<Int>
    ) -> TMDBSimilarTitle? {
        guard seen.insert(item.id).inserted else { return nil }
        let title = item.title ?? item.name
        guard let title, !title.isEmpty else { return nil }
        let date = item.releaseDate ?? item.firstAirDate
        return TMDBSimilarTitle(
            id: "tmdb:\(kind == "movie" ? "movie" : "tv"):\(item.id)",
            title: title,
            year: year(from: date),
            posterURL: posterURL(item.posterPath),
            overview: item.overview,
            rating: item.voteAverage,
            popularity: item.popularity,
            relation: relation
        )
    }

    private static func contentRating(from detail: TMDBDetailResponse, kind: String) -> String? {
        if kind == "tv" {
            let preferred = detail.contentRatings?.results?.first { $0.iso31661 == "US" }
                ?? detail.contentRatings?.results?.first
            return preferred?.rating?.nilIfEmpty
        }
        let preferred = detail.releaseDates?.results?.first { $0.iso31661 == "US" }
            ?? detail.releaseDates?.results?.first
        return preferred?.releaseDates?.compactMap(\.certification).first(where: { !$0.isEmpty })
    }

    private static func performRequest(components: URLComponents?, token: String) async throws -> Data {
        var mutableComponents = components
        guard let initialURL = mutableComponents?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: initialURL)
        request.timeoutInterval = 12
        if token.contains(".") || token.count > 80 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            mutableComponents?.queryItems?.append(URLQueryItem(name: "api_key", value: token))
            guard let keyedURL = mutableComponents?.url else { throw MetadataSearchError.invalidRequest }
            request.url = keyedURL
        }
        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MetadataSearchError.invalidResponse }
            if http.statusCode == 200 { return data }
            if (http.statusCode == 429 || (500...599).contains(http.statusCode)), attempt < 2 {
                attempt += 1
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(attempt)
                try await Task.sleep(nanoseconds: UInt64(min(max(retry, 0.5), 4) * 1_000_000_000))
                continue
            }
            throw MetadataSearchError.invalidResponse
        }
    }

    private static func personWorks(from credits: TMDBCombinedCredits?) -> [MediaPersonWork] {
        let cast = credits?.cast ?? []
        let crew = credits?.crew ?? []
        var byID: [String: MediaPersonWork] = [:]
        for item in cast + crew {
            guard let mediaType = item.mediaType, mediaType == "movie" || mediaType == "tv",
                  let title = item.title ?? item.name, !title.isEmpty else { continue }
            let externalID = "tmdb:\(mediaType):\(item.id)"
            let role = item.character?.nilIfEmpty ?? item.job?.nilIfEmpty
            let work = MediaPersonWork(
                id: externalID,
                title: title,
                year: year(from: item.releaseDate ?? item.firstAirDate),
                role: role,
                mediaKind: mediaType,
                posterURL: posterURL(item.posterPath),
                popularity: item.popularity
            )
            if (work.popularity ?? 0) >= (byID[externalID]?.popularity ?? -1) {
                byID[externalID] = work
            }
        }
        return byID.values.sorted {
            if $0.year != $1.year { return ($0.year ?? 0) > ($1.year ?? 0) }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private static func localizedJob(_ job: String) -> String {
        switch job {
        case "Director": return "导演"
        case "Writer", "Screenplay": return "编剧"
        case "Producer": return "制片"
        case "Original Music Composer": return "配乐"
        default: return job
        }
    }
}

/// TMDB 的统一公开边界。搜索结果应用、自动补全和详情扩展都从同一个
/// append_to_response 响应读取，避免同一作品紧接着重复请求基础详情和扩展详情。
struct TMDBMetadataClient {
    func fetch(
        externalID: String,
        apiKey: String?,
        language: String
    ) async throws -> TMDBEnrichment? {
        try await TMDBMetadataRequestPool.shared.fetch(
            externalID: externalID,
            apiKey: apiKey,
            language: language
        )
    }

    func metadataResult(
        replacing fallback: MetadataSearchResult,
        apiKey: String?,
        language: String
    ) async -> MetadataSearchResult? {
        guard let detail = try? await fetch(
            externalID: fallback.id,
            apiKey: apiKey,
            language: language
        ) else { return nil }
        let title = detail.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallback.title
        let originalTitle = detail.originalTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let date = detail.firstAirDate ?? fallback.subtitle
        return MetadataSearchResult(
            id: fallback.id,
            provider: MetadataSearchService.tmdbProviderName(language: language),
            title: title,
            originalTitle: originalTitle == title ? fallback.originalTitle : (originalTitle ?? fallback.originalTitle),
            subtitle: date,
            year: date.flatMap { Int($0.prefix(4)) } ?? fallback.year,
            overview: detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallback.overview,
            posterPath: detail.posterURL ?? fallback.posterPath,
            backdropPath: detail.backdropURL ?? fallback.backdropPath,
            rating: detail.rating ?? fallback.rating,
            runtime: detail.runtime ?? fallback.runtime,
            genre: detail.genres.isEmpty ? fallback.genre : detail.genres.joined(separator: ", ")
        )
    }
}

private actor TMDBMetadataRequestPool {
    static let shared = TMDBMetadataRequestPool()

    private struct CachedValue {
        let value: TMDBEnrichment?
        let expiresAt: Date
    }

    private var cached: [String: CachedValue] = [:]
    private var tasks: [String: Task<TMDBEnrichment?, Error>] = [:]

    func fetch(
        externalID: String,
        apiKey: String?,
        language: String
    ) async throws -> TMDBEnrichment? {
        let key = "\(externalID)|\(language.isEmpty ? "zh-CN" : language)"
        if let value = cached[key], value.expiresAt > Date() {
            return value.value
        }
        if let task = tasks[key] {
            return try await task.value
        }
        let task = Task {
            try await TMDBEnrichmentService().fetch(
                externalID: externalID,
                apiKey: apiKey,
                language: language
            )
        }
        tasks[key] = task
        do {
            let value = try await task.value
            cached[key] = CachedValue(value: value, expiresAt: Date().addingTimeInterval(30))
            tasks[key] = nil
            return value
        } catch {
            tasks[key] = nil
            throw error
        }
    }
}

private struct TMDBDetailResponse: Decodable {
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [TMDBNamedValue]?
    let createdBy: [TMDBCreatedBy]?
    let credits: TMDBCredits?
    let similar: TMDBSimilarResponse?
    let videos: TMDBVideosResponse?
    let images: TMDBImagesResponse?
    let externalIds: TMDBExternalIds?
    let aggregateCredits: TMDBAggregateCredits?
    let recommendations: TMDBSimilarResponse?
    let contentRatings: TMDBContentRatingsResponse?
    let releaseDates: TMDBReleaseDatesResponse?
    let status: String?
    let firstAirDate: String?
    let lastAirDate: String?
    let releaseDate: String?
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let originalLanguage: String?
    let originCountry: [String]?
    let productionCountries: [TMDBNamedCountry]?
    let productionCompanies: [TMDBNamedValue]?
    let networks: [TMDBNamedValue]?

    enum CodingKeys: String, CodingKey {
        case title, name, overview, runtime, genres
        case originalTitle = "original_title"
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case episodeRunTime = "episode_run_time"
        case createdBy = "created_by"
        case credits
        case similar
        case videos
        case images
        case externalIds = "external_ids"
        case aggregateCredits = "aggregate_credits"
        case recommendations
        case contentRatings = "content_ratings"
        case releaseDates = "release_dates"
        case status
        case firstAirDate = "first_air_date"
        case lastAirDate = "last_air_date"
        case releaseDate = "release_date"
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case originalLanguage = "original_language"
        case originCountry = "origin_country"
        case productionCountries = "production_countries"
        case productionCompanies = "production_companies"
        case networks
    }
}

private struct TMDBImagesResponse: Decodable {
    let backdrops: [TMDBImageDTO]?
    let posters: [TMDBImageDTO]?
}

private struct TMDBImageDTO: Decodable {
    let filePath: String?
    let aspectRatio: Double?
    let iso6391: String?
    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case aspectRatio = "aspect_ratio"
        case iso6391 = "iso_639_1"
    }
}

private struct TMDBExternalIds: Decodable {
    let imdbId: String?
    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
    }
}

private struct TMDBVideosResponse: Decodable {
    let results: [TMDBVideo]?
}

private struct TMDBVideo: Decodable {
    let key: String?
    let site: String?
    let type: String?
    let official: Bool?
}

private struct TMDBCreatedBy: Decodable {
    let id: Int
    let name: String
    let profilePath: String?
    enum CodingKeys: String, CodingKey { case id, name, profilePath = "profile_path" }
}

private struct TMDBCredits: Decodable {
    let cast: [TMDBCastMember]?
    let crew: [TMDBCrewMember]?
}

private struct TMDBCastMember: Decodable {
    let id: Int
    let name: String
    let character: String?
    let order: Int?
    let profilePath: String?
    enum CodingKeys: String, CodingKey { case id, name, character, order, profilePath = "profile_path" }
}

private struct TMDBCrewMember: Decodable {
    let id: Int
    let name: String
    let job: String?
    let profilePath: String?
    let department: String?
    enum CodingKeys: String, CodingKey { case id, name, job, department, profilePath = "profile_path" }
}

private struct TMDBSimilarResponse: Decodable {
    let results: [TMDBSimilarItem]?
}

private struct TMDBSimilarItem: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let voteAverage: Double?
    let popularity: Double?
    enum CodingKeys: String, CodingKey {
        case id, title, name
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case overview, popularity
        case voteAverage = "vote_average"
    }
}

private struct TMDBAggregateCredits: Decodable {
    let cast: [TMDBAggregateCastMember]?
    let crew: [TMDBAggregateCrewMember]?
}

private struct TMDBAggregateCastMember: Decodable {
    let id: Int
    let name: String
    let profilePath: String?
    let order: Int?
    let roles: [TMDBAggregateRole]?
    enum CodingKeys: String, CodingKey { case id, name, order, roles, profilePath = "profile_path" }

    var flattened: TMDBCastMember {
        TMDBCastMember(
            id: id,
            name: name,
            character: roles?.first?.character,
            order: order,
            profilePath: profilePath
        )
    }
}

private struct TMDBAggregateRole: Decodable {
    let character: String?
}

private struct TMDBAggregateCrewMember: Decodable {
    let id: Int
    let name: String
    let profilePath: String?
    let department: String?
    let jobs: [TMDBAggregateJob]?
    enum CodingKeys: String, CodingKey { case id, name, department, jobs, profilePath = "profile_path" }

    var flattened: TMDBCrewMember {
        TMDBCrewMember(
            id: id,
            name: name,
            job: jobs?.first?.job,
            profilePath: profilePath,
            department: department
        )
    }
}

private struct TMDBAggregateJob: Decodable {
    let job: String?
}

private struct TMDBNamedValue: Decodable {
    let name: String?
}

private struct TMDBNamedCountry: Decodable {
    let name: String?
}

private struct TMDBContentRatingsResponse: Decodable {
    let results: [TMDBContentRating]?
}

private struct TMDBContentRating: Decodable {
    let iso31661: String?
    let rating: String?
    enum CodingKeys: String, CodingKey { case rating, iso31661 = "iso_3166_1" }
}

private struct TMDBReleaseDatesResponse: Decodable {
    let results: [TMDBReleaseCountry]?
}

private struct TMDBReleaseCountry: Decodable {
    let iso31661: String?
    let releaseDates: [TMDBReleaseDate]?
    enum CodingKeys: String, CodingKey { case iso31661 = "iso_3166_1", releaseDates = "release_dates" }
}

private struct TMDBReleaseDate: Decodable {
    let certification: String?
}

private struct TMDBPersonDetailResponse: Decodable {
    let name: String
    let profilePath: String?
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let knownForDepartment: String?
    let combinedCredits: TMDBCombinedCredits?
    let externalIds: TMDBPersonExternalIDs?
    enum CodingKeys: String, CodingKey {
        case name, biography, birthday, deathday
        case profilePath = "profile_path"
        case placeOfBirth = "place_of_birth"
        case knownForDepartment = "known_for_department"
        case combinedCredits = "combined_credits"
        case externalIds = "external_ids"
    }
}

private struct TMDBPersonExternalIDs: Decodable {
    let imdbId: String?
    enum CodingKeys: String, CodingKey { case imdbId = "imdb_id" }
}

private struct TMDBCombinedCredits: Decodable {
    let cast: [TMDBPersonCredit]?
    let crew: [TMDBPersonCredit]?
}

private struct TMDBPersonCredit: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let character: String?
    let job: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let popularity: Double?
    enum CodingKeys: String, CodingKey {
        case id, title, name, character, job, popularity
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }
}

extension TMDBEnrichment {
    func snapshot(mediaID: String, provider: String, language: String) -> MediaDetailSnapshot {
        let allPeople = crew + cast
        let people = Dictionary(allPeople.map { person in
            (
                person.stableID,
                MediaPerson(
                    id: person.stableID,
                    name: person.name,
                    profileURL: person.profileURL,
                    knownForDepartment: person.department,
                    externalIDs: person.stableID.hasPrefix("tmdb-person-")
                        ? [MediaExternalID(provider: "tmdb", value: "\(person.id)")]
                        : []
                )
            )
        }, uniquingKeysWith: { first, second in
            var merged = first
            if merged.profileURL == nil { merged.profileURL = second.profileURL }
            return merged
        }).values.map { $0 }
        let credits = allPeople.enumerated().map { index, person in
            MediaCredit(
                id: "\(mediaID)-\(person.stableID)-\(person.category)-\(index)",
                mediaID: mediaID,
                personID: person.stableID,
                category: person.category,
                role: person.role,
                department: person.department,
                order: index
            )
        }
        let artworkValues = images.enumerated().map { index, image in
            MediaArtwork(
                id: "\(mediaID)-\(image.id)",
                mediaID: mediaID,
                kind: image.kind,
                thumbURL: image.thumbURL,
                fullURL: image.fullURL,
                language: image.language,
                aspectRatio: image.aspectRatio,
                order: index
            )
        }
        let related = similar.enumerated().map { index, value in
            MediaRelatedTitle(
                id: "\(mediaID)-\(value.relation)-\(value.id)",
                mediaID: mediaID,
                relation: value.relation,
                externalID: value.id,
                title: value.title,
                year: value.year,
                posterURL: value.posterURL,
                overview: value.overview,
                rating: value.rating,
                popularity: value.popularity,
                order: index
            )
        }
        var ids: [MediaExternalID] = []
        if let tmdbID, let tmdbKind {
            ids.append(MediaExternalID(provider: "tmdb", value: "\(tmdbKind):\(tmdbID)"))
        }
        if let imdbID { ids.append(MediaExternalID(provider: "imdb", value: imdbID)) }
        return MediaDetailSnapshot(
            metadata: MediaDetailMetadata(
                mediaID: mediaID,
                status: status,
                firstAirDate: firstAirDate,
                endDate: endDate,
                seasonCount: seasonCount,
                episodeCount: episodeCount,
                contentRating: contentRating,
                originalLanguage: originalLanguage,
                countries: Array(Set(countries)).filter { !$0.isEmpty },
                productionCompanies: productionCompanies,
                networks: networks,
                trailerURL: trailerURL,
                provider: provider,
                language: language,
                fetchedAt: Date(),
                fetchVersion: 1
            ),
            externalIDs: ids,
            people: people,
            credits: credits,
            artwork: artworkValues,
            relatedTitles: related
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
