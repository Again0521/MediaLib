import Foundation

/// 艺术家简介（B4）：聚合 Last.fm 文字简介 + Deezer 头像，用于音乐详情页展示。
struct ArtistInfo: Equatable {
    var name: String
    var bio: String?
    var imageURL: String?
    var tags: [String]
    var similar: [String]

    var isEmpty: Bool {
        (bio?.isEmpty ?? true) && imageURL == nil && tags.isEmpty && similar.isEmpty
    }
}

struct ArtistInfoService {
    /// 拉取艺术家信息：Last.fm `artist.getInfo` 取简介/标签/相似艺人（需 API Key），Deezer 取头像（免密钥）。
    /// 任一来源失败都不影响另一来源，尽量返回可展示的内容。
    func fetch(artist: String, lastfmAPIKey: String?, language: String) async throws -> ArtistInfo? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        async let lastfm = fetchLastfm(artist: trimmed, apiKey: lastfmAPIKey, language: language)
        async let photo = fetchDeezerImage(artist: trimmed)

        let lf = (try? await lastfm) ?? nil
        let img = (try? await photo) ?? nil

        let info = ArtistInfo(
            name: trimmed,
            bio: lf?.bio,
            imageURL: img ?? lf?.imageURL,
            tags: lf?.tags ?? [],
            similar: lf?.similar ?? []
        )
        return info.isEmpty ? nil : info
    }

    // MARK: - Last.fm

    private struct LastfmArtistResult {
        var bio: String?
        var imageURL: String?
        var tags: [String]
        var similar: [String]
    }

    private func fetchLastfm(artist: String, apiKey: String?, language: String) async throws -> LastfmArtistResult? {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }

        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        var queryItems = [
            URLQueryItem(name: "method", value: "artist.getinfo"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "format", value: "json")
        ]
        // 中文环境优先请求中文简介。
        if language.lowercased().hasPrefix("zh") {
            queryItems.append(URLQueryItem(name: "lang", value: "zh"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(LastfmArtistResponse.self, from: data)
        guard let artistDTO = decoded.artist else { return nil }

        return LastfmArtistResult(
            bio: Self.cleanedBio(artistDTO.bio?.content ?? artistDTO.bio?.summary),
            imageURL: nil,
            tags: (artistDTO.tags?.tag ?? []).compactMap { $0.name }.filter { !$0.isEmpty },
            similar: (artistDTO.similar?.artist ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        )
    }

    /// Last.fm 简介是带 HTML 的文本，末尾常有「Read more on Last.fm」链接，这里去标签、截掉尾链、清理空白。
    private static func cleanedBio(_ raw: String?) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }
        if let range = text.range(of: "<a href") {
            text = String(text[..<range.lowerBound])
        }
        // 去掉残余 HTML 标签。
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Deezer 头像

    private func fetchDeezerImage(artist: String) async throws -> String? {
        var components = URLComponents(string: "https://api.deezer.com/search/artist")
        components?.queryItems = [
            URLQueryItem(name: "q", value: artist),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(DeezerArtistSearchResponse.self, from: data)
        guard let first = decoded.data?.first else { return nil }
        let picture = first.pictureXL ?? first.pictureBig ?? first.pictureMedium
        guard let picture, !picture.isEmpty else { return nil }
        return picture
    }
}

// MARK: - 解码

private struct LastfmArtistResponse: Decodable {
    let artist: LastfmArtistDTO?
}

private struct LastfmArtistDTO: Decodable {
    let bio: Bio?
    let tags: Tags?
    let similar: Similar?

    struct Bio: Decodable {
        let summary: String?
        let content: String?
    }
    struct Tags: Decodable {
        let tag: [Tag]?
    }
    struct Tag: Decodable {
        let name: String?
    }
    struct Similar: Decodable {
        let artist: [SimilarArtist]?
    }
    struct SimilarArtist: Decodable {
        let name: String?
    }
}

private struct DeezerArtistSearchResponse: Decodable {
    let data: [DeezerArtist]?
}

private struct DeezerArtist: Decodable {
    let pictureMedium: String?
    let pictureBig: String?
    let pictureXL: String?

    enum CodingKeys: String, CodingKey {
        case pictureMedium = "picture_medium"
        case pictureBig = "picture_big"
        case pictureXL = "picture_xl"
    }
}
