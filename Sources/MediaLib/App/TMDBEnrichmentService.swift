import Foundation
import MediaLibCore

struct TMDBPerson: Identifiable, Hashable {
    let id: Int
    let name: String
    let role: String
    let profileURL: String?
}

struct TMDBSimilarTitle: Identifiable, Hashable {
    /// 形如 "tmdb:movie:123" / "tmdb:tv:123"，用于和本地条目的 externalID 交叉匹配。
    let id: String
    let title: String
    let year: Int?
    let posterURL: String?
}

struct TMDBEnrichment {
    var cast: [TMDBPerson]
    var crew: [TMDBPerson]
    var similar: [TMDBSimilarTitle]
    var trailerURL: String?

    var isEmpty: Bool { cast.isEmpty && crew.isEmpty && similar.isEmpty && trailerURL == nil }
}

/// 拉取 TMDB 演职人员 + 相关推荐（一次 append_to_response 请求拿全），用于详情页内容深度展示。
struct TMDBEnrichmentService {
    func fetch(externalID: String, apiKey: String?, language: String) async throws -> TMDBEnrichment? {
        guard let (kind, numericID) = Self.parse(externalID: externalID) else { return nil }
        let token = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw MetadataSearchError.missingTMDBKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/\(kind)/\(numericID)")
        components?.queryItems = [
            URLQueryItem(name: "language", value: language.isEmpty ? "zh-CN" : language),
            URLQueryItem(name: "append_to_response", value: "credits,similar,videos")
        ]
        guard let baseURL = components?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 12
        if token.contains(".") || token.count > 80 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            components?.queryItems?.append(URLQueryItem(name: "api_key", value: token))
            guard let keyedURL = components?.url else { throw MetadataSearchError.invalidRequest }
            request.url = keyedURL
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MetadataSearchError.invalidResponse }
        let decoded = try JSONDecoder().decode(TMDBDetailResponse.self, from: data)

        let cast = (decoded.credits?.cast ?? [])
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
            .prefix(16)
            .map { member in
                TMDBPerson(
                    id: member.id,
                    name: member.name,
                    role: member.character?.isEmpty == false ? member.character! : "演员",
                    profileURL: Self.profileURL(member.profilePath)
                )
            }

        var crew: [TMDBPerson] = []
        var seenCrew = Set<Int>()
        for creator in decoded.createdBy ?? [] where seenCrew.insert(creator.id).inserted {
            crew.append(TMDBPerson(id: creator.id, name: creator.name, role: "主创", profileURL: Self.profileURL(creator.profilePath)))
        }
        let keyJobs = ["Director", "Writer", "Screenplay", "Producer", "Original Music Composer"]
        for member in decoded.credits?.crew ?? [] {
            guard let job = member.job, keyJobs.contains(job), seenCrew.insert(member.id).inserted else { continue }
            crew.append(TMDBPerson(id: member.id, name: member.name, role: Self.localizedJob(job), profileURL: Self.profileURL(member.profilePath)))
            if crew.count >= 8 { break }
        }

        let similar = (decoded.similar?.results ?? [])
            .prefix(16)
            .compactMap { item -> TMDBSimilarTitle? in
                let title = item.title ?? item.name
                guard let title, !title.isEmpty else { return nil }
                let date = item.releaseDate ?? item.firstAirDate
                return TMDBSimilarTitle(
                    id: "tmdb:\(kind == "movie" ? "movie" : "tv"):\(item.id)",
                    title: title,
                    year: Self.year(from: date),
                    posterURL: Self.posterURL(item.posterPath)
                )
            }

        let trailerURL = Self.trailerURL(from: decoded.videos?.results ?? [])

        let enrichment = TMDBEnrichment(cast: Array(cast), crew: crew, similar: similar, trailerURL: trailerURL)
        return enrichment.isEmpty ? nil : enrichment
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

private struct TMDBDetailResponse: Decodable {
    let createdBy: [TMDBCreatedBy]?
    let credits: TMDBCredits?
    let similar: TMDBSimilarResponse?
    let videos: TMDBVideosResponse?

    enum CodingKeys: String, CodingKey {
        case createdBy = "created_by"
        case credits
        case similar
        case videos
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
    enum CodingKeys: String, CodingKey { case id, name, job, profilePath = "profile_path" }
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
    enum CodingKeys: String, CodingKey {
        case id, title, name
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }
}
