import Foundation
import MediaLibCore

struct MetadataSearchResult: Identifiable, Hashable {
    var id: String
    var provider: String
    var title: String
    var originalTitle: String? = nil
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
    var genre: String?

    var metadataUpdate: MediaMetadataUpdate {
        MediaMetadataUpdate(
            title: title,
            originalTitle: originalTitle,
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
            metadataProvider: provider,
            genre: genre
        )
    }
}

/// 自动匹配置信度评分：对候选结果按标题相似度（+年份/艺人）打分，挑最佳并给出 0–1 置信度，
/// 供一键匹配/自动拉取据此决定"高置信自动应用 vs 低置信跳过待复核"，避免盲取首条造成错配。
enum MetadataMatchScorer {
    static func bestVideoMatch(
        for item: MediaItem,
        in results: [MetadataSearchResult],
        matchedQueries: [String: [String]] = [:]
    ) -> (result: MetadataSearchResult, confidence: Double)? {
        scoredBest(in: results) { result in
            videoConfidence(item: item, result: result, matchedQueries: matchedQueries[result.id] ?? [])
        }
    }

    static func bestMusicMatch(for item: MediaItem, in results: [MetadataSearchResult]) -> (result: MetadataSearchResult, confidence: Double)? {
        scoredBest(in: results) { musicConfidence(item: item, result: $0) }
    }

    static func videoSearchQueries(for item: MediaItem) -> [String] {
        let rawTitles = [item.title, item.originalTitle, item.collectionTitle].compactMap { $0 }
        return uniqueQueries(from: rawTitles.flatMap { searchVariants(for: $0) })
    }

    private static func scoredBest(
        in results: [MetadataSearchResult],
        score: (MetadataSearchResult) -> Double
    ) -> (result: MetadataSearchResult, confidence: Double)? {
        var best: (MetadataSearchResult, Double)?
        // 同分时保留 TMDB/各源原有相关性排序（先出现者优先），所以用严格大于更新。
        for result in results {
            let value = score(result)
            if best == nil || value > best!.1 {
                best = (result, value)
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    private static func videoConfidence(
        item: MediaItem,
        result: MetadataSearchResult,
        matchedQueries: [String] = []
    ) -> Double {
        let localTitles = [item.title, item.originalTitle, item.collectionTitle]
            .compactMap { $0 }
            .flatMap { titleVariants(for: $0) }
        let resultTitles = [result.title, result.originalTitle]
            .compactMap { $0 }
            .flatMap { titleVariants(for: $0) }
        let titleSim = bestTitleSimilarity(localTitles: localTitles, resultTitles: resultTitles)
        let queryTitles = matchedQueries.flatMap { titleVariants(for: $0) }
        let querySim = bestTitleSimilarity(localTitles: queryTitles, resultTitles: resultTitles)
        // TMDB 已经按查询词召回候选；宽松匹配需要认可“清洗剧名命中”的证据，
        // 避免原始文件名里的季集号、发布组、分辨率把可手动搜到的剧集候选压到阈值下。
        var score = max(titleSim, querySim * 0.98)
        if let localYear = item.year, let resultYear = result.year {
            if localYear == resultYear { score += 0.075 }
            else if abs(localYear - resultYear) > 1 { score -= 0.16 }
        }
        return clamp(score)
    }

    private static func musicConfidence(item: MediaItem, result: MetadataSearchResult) -> Double {
        let titleSim = titleSimilarity(normalized(item.title), normalized(result.title))
        guard let localArtist = item.artist, !localArtist.isEmpty,
              let resultArtist = result.artist, !resultArtist.isEmpty else {
            return clamp(titleSim)
        }
        let artistSim = titleSimilarity(normalized(localArtist), normalized(resultArtist))
        return clamp(titleSim * 0.65 + artistSim * 0.35)
    }

    private static func bestTitleSimilarity(localTitles: [String], resultTitles: [String]) -> Double {
        localTitles
            .flatMap { local in resultTitles.map { titleSimilarity(local, $0) } }
            .max() ?? 0
    }

    /// 标题归一化：小写、去括号标签、去季集/分辨率/来源等发布噪声、分隔符与标点→空格、折叠空白。
    /// 保留 CJK 与拉丁字母数字（CharacterSet.alphanumerics 含各脚本字母，含中日韩）。
    static func normalized(_ raw: String) -> String {
        var text = raw
            .lowercased()
            .replacingOccurrences(of: "\\.[a-z0-9]{2,5}$", with: " ", options: .regularExpression)
        text = removeBracketedSegments(from: text)
        text = removeVideoNoise(from: text)
        text = text.replacingOccurrences(of: "[._/\\-]+", with: " ", options: .regularExpression)
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        text = String(text.unicodeScalars.map { keep.contains($0) ? Character($0) : " " })
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func titleVariants(for raw: String) -> [String] {
        var variants = [normalized(raw), seriesTitleCandidate(from: raw)]
        let deSeasoned = variants[0]
            .replacingOccurrences(of: "\\b\\d{4}\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        variants.append(deSeasoned)
        variants.append(contentsOf: raw.components(separatedBy: CharacterSet(charactersIn: "|｜:："))
            .map(normalized))
        return uniqueQueries(from: variants)
    }

    private static func searchVariants(for raw: String) -> [String] {
        let cleaned = normalized(raw)
        let series = seriesTitleCandidate(from: raw)
        var variants = [series, cleaned]
        variants.append(cleaned.replacingOccurrences(of: "\\b\\d{4}\\b", with: " ", options: .regularExpression))
        variants.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        variants.append(cleaned)
        variants.append(contentsOf: raw.components(separatedBy: CharacterSet(charactersIn: "|｜:："))
            .map { normalized($0) })
        return variants
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func seriesTitleCandidate(from raw: String) -> String {
        var text = raw
            .lowercased()
            .replacingOccurrences(of: "\\.[a-z0-9]{2,5}$", with: " ", options: .regularExpression)
        text = removeBracketedSegments(from: text)
        let cutPatterns = [
            "(?i)\\bs\\d{1,2}\\s*e\\d{1,3}\\b",
            "(?i)[\\s._-]+s\\d{1,2}\\b.*",
            "(?i)\\bseason\\s*\\d+\\b",
            "(?i)\\b(?:ep|episode|e)\\s*\\d{1,3}\\b",
            "第\\s*[0-9一二三四五六七八九十百千万两]+\\s*[季部].*",
            "第\\s*[0-9一二三四五六七八九十百千万两]+\\s*[集话話].*",
            "[\\s._-]+\\d{1,4}\\s*(?:v\\d+)?$",
            "[\\s._-]+\\d{1,4}\\s*[集话話].*"
        ]
        for pattern in cutPatterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                text = String(text[..<range.lowerBound])
                break
            }
        }
        text = removeVideoNoise(from: text)
        text = text.replacingOccurrences(of: "\\b(19\\d{2}|20\\d{2})\\b", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[._/\\-]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeBracketedSegments(from raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "【[^】]*】", with: " ", options: .regularExpression)
    }

    private static func removeVideoNoise(from raw: String) -> String {
        let chineseNumber = "[0-9一二三四五六七八九十百千万两]+"
        let noise = [
            "(?i)\\bs\\d{1,2}\\s*e\\d{1,3}\\b",
            "(?i)\\bs\\d{1,2}\\b",
            "(?i)\\bseason\\s*\\d+\\b",
            "(?i)\\b(?:ep|episode|e)\\s*\\d{1,3}\\b",
            "第\\s*\(chineseNumber)\\s*[季部集话話]",
            "全\\s*\(chineseNumber)\\s*[集话話]",
            "全集|完结|完結|更新至\\s*\(chineseNumber)\\s*[集话話]?",
            "(?i)\\b(part|pt)\\s*\\d+\\b",
            "\\b\\d{3,4}p\\b",
            "(?i)\\b(4k|8k|2160p|1080p|720p|480p|bluray|blu-ray|webrip|web-dl|webdl|hdtv|bdrip|dvdrip|x264|x265|h264|h265|hevc|avc|aac|flac|dts|truehd|atmos|remux|proper|repack|complete|hdr|hdr10|dv|dolby|chs|cht|jpn|kor|eng|multi|netflix|nf|amzn|amazon|hulu|disney|dsnp|bilibili|bglobal)\\b"
        ].joined(separator: "|")
        return raw.replacingOccurrences(of: noise, with: " ", options: [.regularExpression, .caseInsensitive])
    }

    private static func titleSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let compactA = a.replacingOccurrences(of: " ", with: "")
        let compactB = b.replacingOccurrences(of: " ", with: "")
        let edit = max(similarity(a, b), similarity(compactA, compactB))
        let containment: Double
        if compactA.contains(compactB) || compactB.contains(compactA) {
            let shorter = Double(min(compactA.count, compactB.count))
            let longer = Double(max(compactA.count, compactB.count))
            containment = 0.72 + 0.22 * (shorter / max(longer, 1))
        } else {
            containment = 0
        }
        return max(edit, containment, tokenDice(a, b))
    }

    private static func tokenDice(_ a: String, _ b: String) -> Double {
        let lhs = Set(a.split(separator: " ").map(String.init).filter { $0.count > 1 })
        let rhs = Set(b.split(separator: " ").map(String.init).filter { $0.count > 1 })
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let hit = lhs.intersection(rhs).count
        return Double(hit * 2) / Double(lhs.count + rhs.count)
    }

    private static func uniqueQueries(from values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 2, !seen.contains(cleaned.lowercased()) else { continue }
            seen.insert(cleaned.lowercased())
            result.append(cleaned)
        }
        return result
    }

    /// 基于字符级 Levenshtein 的 0–1 相似度（对 CJK 与英文均适用）。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let lhs = Array(a)
        let rhs = Array(b)
        let distance = levenshtein(lhs, rhs)
        return 1.0 - Double(distance) / Double(max(lhs.count, rhs.count))
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, 0), 1)
    }
}

enum MetadataSearchError: LocalizedError {
    case missingTMDBKey
    case missingLastFMKey
    case unsupportedProvider
    case invalidRequest
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingTMDBKey:
            return "请先在设置中填写 TMDB API Key 或 Read Access Token。"
        case .missingLastFMKey:
            return "请先在设置中填写 Last.fm API Key。"
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
    static func tmdbProviderName(language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return "TMDB[\(trimmed.isEmpty ? "zh-CN" : trimmed)]"
    }

    static func tmdbSearchesTVEndpoint(for itemType: MediaType) -> Bool {
        switch itemType {
        case .tvShow, .anime, .documentary, .variety, .episode:
            return true
        default:
            return false
        }
    }

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

        let endpoint = Self.tmdbSearchesTVEndpoint(for: itemType)
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
            let originalTitle = [result.originalTitle, result.originalName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != title }
            let date = result.releaseDate ?? result.firstAirDate
            let genreNames = (result.genreIDs ?? []).compactMap { TMDBGenres.name(for: $0, isTV: isTV) }
            return MetadataSearchResult(
                id: "tmdb:\(isTV ? "tv" : "movie"):\(result.id)",
                provider: Self.tmdbProviderName(language: language),
                title: title,
                originalTitle: originalTitle,
                subtitle: date,
                year: year(from: date),
                overview: result.overview,
                posterPath: result.posterPath.map { "https://image.tmdb.org/t/p/w500\($0)" },
                backdropPath: result.backdropPath.map { "https://image.tmdb.org/t/p/w780\($0)" },
                rating: result.voteAverage,
                genre: genreNames.isEmpty ? nil : genreNames.joined(separator: ", ")
            )
        }
    }

    func searchMusic(query: String, provider: MusicMetadataProvider, lastfmAPIKey: String? = nil) async throws -> [MetadataSearchResult] {
        switch provider {
        case .musicBrainz:
            return try await searchMusicBrainz(query: query)
        case .iTunes:
            return try await searchITunes(query: query)
        case .neteaseCloud:
            return try await searchNetease(query: query)
        case .qqMusic:
            return try await searchQQMusic(query: query)
        case .lastFM:
            return try await searchLastFM(query: query, apiKey: lastfmAPIKey)
        case .deezer:
            return try await searchDeezer(query: query)
        case .disabled:
            throw MetadataSearchError.unsupportedProvider
        }
    }

    // MARK: - 新增音乐数据源（网易云 / QQ / Last.fm / Deezer）

    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"

    private func searchDeezer(query: String) async throws -> [MetadataSearchResult] {
        var components = URLComponents(string: "https://api.deezer.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "12")
        ]
        guard let url = components?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MetadataSearchError.invalidResponse }
        let decoded = try JSONDecoder().decode(DeezerSearchResponse.self, from: data)
        return decoded.data.prefix(12).map { track in
            MetadataSearchResult(
                id: "deezer:\(track.id)",
                provider: "Deezer",
                title: track.title,
                subtitle: [track.artist?.name, track.album?.title].compactMap { $0 }.joined(separator: " · "),
                year: nil,
                overview: nil,
                posterPath: track.album?.coverXl ?? track.album?.coverBig ?? track.album?.coverMedium,
                artist: track.artist?.name,
                album: track.album?.title
            )
        }
    }

    private func searchNetease(query: String) async throws -> [MetadataSearchResult] {
        var components = URLComponents(string: "https://music.163.com/api/search/get/web")
        components?.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "offset", value: "0")
        ]
        guard let url = components?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MetadataSearchError.invalidResponse }
        let decoded = try JSONDecoder().decode(NeteaseSearchResponse.self, from: data)
        return (decoded.result?.songs ?? []).prefix(12).map { song in
            let artist = song.artists?.compactMap(\.name).joined(separator: ", ")
            let cover = song.album?.picUrl
                .map { $0.replacingOccurrences(of: "http://", with: "https://") }
                .map { "\($0)?param=600y600" }
            return MetadataSearchResult(
                id: "netease:\(song.id)",
                provider: "网易云音乐",
                title: song.name,
                subtitle: [artist, song.album?.name].compactMap { $0 }.joined(separator: " · "),
                year: nil,
                overview: nil,
                posterPath: cover,
                artist: artist,
                album: song.album?.name
            )
        }
    }

    private func searchQQMusic(query: String) async throws -> [MetadataSearchResult] {
        var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")
        components?.queryItems = [
            URLQueryItem(name: "w", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "12"),
            URLQueryItem(name: "cr", value: "1")
        ]
        guard let url = components?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MetadataSearchError.invalidResponse }
        let decoded = try JSONDecoder().decode(QQSearchResponse.self, from: data)
        return (decoded.data?.song?.list ?? []).prefix(12).map { song in
            let artist = song.singer?.compactMap(\.name).joined(separator: ", ")
            let cover = song.albummid.flatMap { mid in
                mid.isEmpty ? nil : "https://y.qq.com/music/photo_new/T002R500x500M000\(mid).jpg"
            }
            return MetadataSearchResult(
                id: "qqmusic:\(song.songmid ?? UUID().uuidString)",
                provider: "QQ 音乐",
                title: song.songname ?? "未命名",
                subtitle: [artist, song.albumname].compactMap { $0 }.joined(separator: " · "),
                year: nil,
                overview: nil,
                posterPath: cover,
                artist: artist,
                album: song.albumname
            )
        }
    }

    private func searchLastFM(query: String, apiKey: String?) async throws -> [MetadataSearchResult] {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw MetadataSearchError.missingLastFMKey }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "track.search"),
            URLQueryItem(name: "track", value: query),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "12")
        ]
        guard let url = components?.url else { throw MetadataSearchError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MetadataSearchError.invalidResponse }
        let decoded = try JSONDecoder().decode(LastFMSearchResponse.self, from: data)
        return (decoded.results?.trackmatches?.track ?? []).prefix(12).map { track in
            let cover = track.image?.last(where: { !($0.text?.isEmpty ?? true) })?.text
            let identity = (track.mbid?.isEmpty == false ? track.mbid! : "\(track.artist ?? "")-\(track.name)")
            return MetadataSearchResult(
                id: "lastfm:\(identity)",
                provider: "Last.fm",
                title: track.name,
                subtitle: track.artist ?? "",
                year: nil,
                overview: nil,
                posterPath: cover,
                artist: track.artist,
                album: nil
            )
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
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var genreIDs: [Int]?

    private enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case originalTitle = "original_title"
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIDs = "genre_ids"
    }
}

/// TMDB 固定 genre id→中文名映射（电影 + 电视，官方稳定列表）。搜索结果即带 genre_ids，无需额外请求。
enum TMDBGenres {
    static func name(for id: Int, isTV: Bool) -> String? {
        (isTV ? tv : movie)[id]
    }

    private static let movie: [Int: String] = [
        28: "动作", 12: "冒险", 16: "动画", 35: "喜剧", 80: "犯罪",
        99: "纪录", 18: "剧情", 10751: "家庭", 14: "奇幻", 36: "历史",
        27: "恐怖", 10402: "音乐", 9648: "悬疑", 10749: "爱情",
        878: "科幻", 10770: "电视电影", 53: "惊悚", 10752: "战争", 37: "西部"
    ]

    private static let tv: [Int: String] = [
        10759: "动作冒险", 16: "动画", 35: "喜剧", 80: "犯罪", 99: "纪录",
        18: "剧情", 10751: "家庭", 10762: "儿童", 9648: "悬疑", 10763: "新闻",
        10764: "真人秀", 10765: "科幻奇幻", 10766: "肥皂剧", 10767: "脱口秀",
        10768: "战争政治", 37: "西部"
    ]
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

// MARK: - Deezer

private struct DeezerSearchResponse: Decodable {
    let data: [DeezerTrack]
}

private struct DeezerTrack: Decodable {
    let id: Int
    let title: String
    let artist: DeezerArtist?
    let album: DeezerAlbum?
}

private struct DeezerArtist: Decodable {
    let name: String
}

private struct DeezerAlbum: Decodable {
    let title: String
    let coverMedium: String?
    let coverBig: String?
    let coverXl: String?

    enum CodingKeys: String, CodingKey {
        case title
        case coverMedium = "cover_medium"
        case coverBig = "cover_big"
        case coverXl = "cover_xl"
    }
}

// MARK: - 网易云音乐

private struct NeteaseSearchResponse: Decodable {
    let result: NeteaseResult?
}

private struct NeteaseResult: Decodable {
    let songs: [NeteaseSong]?
}

private struct NeteaseSong: Decodable {
    let id: Int
    let name: String
    let artists: [NeteaseArtist]?
    let album: NeteaseAlbum?
}

private struct NeteaseArtist: Decodable {
    let name: String
}

private struct NeteaseAlbum: Decodable {
    let name: String
    let picUrl: String?
}

// MARK: - QQ 音乐

private struct QQSearchResponse: Decodable {
    let data: QQData?
}

private struct QQData: Decodable {
    let song: QQSongList?
}

private struct QQSongList: Decodable {
    let list: [QQSong]?
}

private struct QQSong: Decodable {
    let songmid: String?
    let songname: String?
    let singer: [QQSinger]?
    let albumname: String?
    let albummid: String?
}

private struct QQSinger: Decodable {
    let name: String
}

// MARK: - Last.fm

private struct LastFMSearchResponse: Decodable {
    let results: LastFMResults?
}

private struct LastFMResults: Decodable {
    let trackmatches: LastFMTrackMatches?
}

private struct LastFMTrackMatches: Decodable {
    let track: [LastFMTrack]?
}

private struct LastFMTrack: Decodable {
    let name: String
    let artist: String?
    let mbid: String?
    let image: [LastFMImage]?
}

private struct LastFMImage: Decodable {
    let text: String?
    let size: String?

    enum CodingKeys: String, CodingKey {
        case text = "#text"
        case size
    }
}
