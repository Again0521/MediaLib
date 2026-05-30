import Foundation
import MediaLibCore

struct MetadataSearchResult: Identifiable, Hashable {
    var id: String
    var provider: String
    var title: String
    var subtitle: String?
    var year: Int?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var rating: Double?
    var runtime: Int?
    var artist: String?
    var album: String?
    var trackNumber: Int?

    var metadataUpdate: MediaMetadataUpdate {
        MediaMetadataUpdate(
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            year: year,
            overview: overview,
            posterPath: posterPath?.hasPrefix("http") == true ? nil : posterPath,
            backdropPath: backdropPath?.hasPrefix("http") == true ? nil : backdropPath,
            rating: rating,
            runtime: runtime,
            externalID: id,
            metadataProvider: provider
        )
    }
}

enum MetadataSearchError: LocalizedError {
    case missingTMDBKey
    case unsupportedProvider
    case invalidRequest
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingTMDBKey:
            return "请先在设置中填写 TMDB API Key 或 Read Access Token。"
        case .unsupportedProvider:
            return "当前元数据源不可用。"
        case .invalidRequest:
            return "无法生成元数据请求地址。"
        case .invalidResponse:
            return "元数据服务返回了无法解析的结果。"
        }
    }
}

struct MetadataSearchService {
    func materializedMetadataUpdate(
        for result: MetadataSearchResult,
        itemID: String,
        artworkDirectory: URL?,
        preserveEmbeddedPoster: Bool = false
    ) async -> MediaMetadataUpdate {
        var update = result.metadataUpdate
        guard let artworkDirectory else { return update }

        if !preserveEmbeddedPoster, let posterPath = await downloadArtwork(
            from: result.posterPath,
            itemID: itemID,
            resultID: result.id,
            kind: "poster",
            directory: artworkDirectory
        ) {
            update.posterPath = posterPath
        }
        if let backdropPath = await downloadArtwork(
            from: result.backdropPath,
            itemID: itemID,
            resultID: result.id,
            kind: "backdrop",
            directory: artworkDirectory
        ) {
            update.backdropPath = backdropPath
        }

        return update
    }

    func searchTMDB(query: String, itemType: MediaType, apiKey: String?, language: String) async throws -> [MetadataSearchResult] {
        let token = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw MetadataSearchError.missingTMDBKey }

        let endpoint = itemType == .tvShow || itemType == .anime || itemType == .documentary || itemType == .variety
            ? "https://api.themoviedb.org/3/search/tv"
            : "https://api.themoviedb.org/3/search/movie"
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: language.isEmpty ? "zh-CN" : language),
            URLQueryItem(name: "include_adult", value: "false")
        ]

        guard let baseURL = components?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 12
        if token.contains(".") || token.count > 80 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            var keyedComponents = components
            keyedComponents?.queryItems?.append(URLQueryItem(name: "api_key", value: token))
            guard let keyedURL = keyedComponents?.url else { throw MetadataSearchError.invalidRequest }
            request.url = keyedURL
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MetadataSearchError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
        return decoded.results.prefix(12).map { result in
            let isTV = endpoint.hasSuffix("/tv")
            let title = result.title ?? result.name ?? "未命名"
            let date = result.releaseDate ?? result.firstAirDate
            return MetadataSearchResult(
                id: "tmdb:\(isTV ? "tv" : "movie"):\(result.id)",
                provider: "TMDB",
                title: title,
                subtitle: date,
                year: year(from: date),
                overview: result.overview,
                posterPath: result.posterPath.map { "https://image.tmdb.org/t/p/w500\($0)" },
                backdropPath: result.backdropPath.map { "https://image.tmdb.org/t/p/w780\($0)" },
                rating: result.voteAverage
            )
        }
    }

    func searchMusic(query: String, provider: MusicMetadataProvider) async throws -> [MetadataSearchResult] {
        switch provider {
        case .musicBrainz:
            return try await searchMusicBrainz(query: query)
        case .iTunes:
            return try await searchITunes(query: query)
        case .disabled:
            throw MetadataSearchError.unsupportedProvider
        }
    }

    private func searchMusicBrainz(query: String) async throws -> [MetadataSearchResult] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "12")
        ]
        guard let url = components?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("MediaLIB/1.0 (local macOS media library)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MetadataSearchError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(MusicBrainzRecordingResponse.self, from: data)
        return decoded.recordings.prefix(12).map { recording in
            let artist = recording.artistCredit?.compactMap(\.name).joined(separator: ", ")
            let release = recording.releases?.first
            return MetadataSearchResult(
                id: "musicbrainz:recording:\(recording.id)",
                provider: "MusicBrainz",
                title: recording.title,
                subtitle: [artist, release?.title].compactMap { $0 }.joined(separator: " · "),
                year: year(from: recording.firstReleaseDate ?? release?.date),
                overview: nil,
                artist: artist,
                album: release?.title,
                trackNumber: release?.media?.first?.tracks?.first?.number.flatMap(Int.init)
            )
        }
    }

    private func searchITunes(query: String) async throws -> [MetadataSearchResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "12")
        ]
        guard let url = components?.url else { throw MetadataSearchError.invalidRequest }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MetadataSearchError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results.map { item in
            MetadataSearchResult(
                id: "itunes:\(item.trackId)",
                provider: "iTunes Search",
                title: item.trackName,
                subtitle: "\(item.artistName) · \(item.collectionName ?? "")",
                year: year(from: item.releaseDate),
                overview: item.primaryGenreName,
                posterPath: item.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "600x600bb"),
                artist: item.artistName,
                album: item.collectionName,
                trackNumber: item.trackNumber
            )
        }
    }

    private func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private func downloadArtwork(
        from urlString: String?,
        itemID: String,
        resultID: String,
        kind: String,
        directory: URL
    ) async -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        guard urlString.hasPrefix("http"), let url = URL(string: urlString) else {
            return urlString
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 18

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                return nil
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
                ? url.pathExtension.lowercased()
                : "jpg"
            let filename = "\(safeFilename(itemID))-\(safeFilename(resultID))-\(kind).\(ext)"
            let outputURL = directory.appendingPathComponent(filename)
            try data.write(to: outputURL, options: .atomic)
            return outputURL.path
        } catch {
            return nil
        }
    }

    private func safeFilename(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = text.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        let filename = mapped.joined()
        return filename.isEmpty ? UUID().uuidString : filename
    }
}

private struct TMDBSearchResponse: Decodable {
    var results: [TMDBSearchResult]
}

private struct TMDBSearchResult: Decodable {
    var id: Int
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?

    private enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }
}

private struct MusicBrainzRecordingResponse: Decodable {
    var recordings: [MusicBrainzRecording]
}

private struct MusicBrainzRecording: Decodable {
    var id: String
    var title: String
    var firstReleaseDate: String?
    var artistCredit: [MusicBrainzArtistCredit]?
    var releases: [MusicBrainzRelease]?

    private enum CodingKeys: String, CodingKey {
        case id, title, releases
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
    }
}

private struct MusicBrainzArtistCredit: Decodable {
    var name: String?
}

private struct MusicBrainzRelease: Decodable {
    var title: String?
    var date: String?
    var media: [MusicBrainzMedium]?
}

private struct MusicBrainzMedium: Decodable {
    var tracks: [MusicBrainzTrack]?
}

private struct MusicBrainzTrack: Decodable {
    var number: String?
}

private struct ITunesSearchResponse: Decodable {
    var results: [ITunesSearchResult]
}

private struct ITunesSearchResult: Decodable {
    var trackId: Int
    var trackName: String
    var artistName: String
    var collectionName: String?
    var releaseDate: String?
    var artworkUrl100: String?
    var primaryGenreName: String?
    var trackNumber: Int?
}
