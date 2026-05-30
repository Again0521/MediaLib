import Foundation

struct SubtitleResult: Identifiable, Hashable, Sendable {
    let id: String
    let fileID: Int
    let displayName: String
    let language: String
    let downloadCount: Int
    let isHearingImpaired: Bool
}

struct OnlineSubtitleResult: Identifiable, Hashable, Sendable {
    enum Source: Sendable, Hashable {
        case openSubtitles(fileID: Int)
        case podnapisi(subtitleID: Int)
    }
    let id: String
    let sourceName: String
    let displayName: String
    let language: String
    let downloads: Int
    let source: Source
}

enum SubtitleError: LocalizedError {
    case missingAPIKey
    case quotaExceeded
    case searchFailed(Int)
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在设置中填写 OpenSubtitles API Key（opensubtitles.com 注册后免费获取）。"
        case .quotaExceeded:
            return "今日下载配额已用完（免费账户每天 5 条），请明天再试或升级 OpenSubtitles 账户。"
        case .searchFailed(let code):
            return "字幕搜索失败（HTTP \(code)），请检查 API Key 是否正确。"
        case .downloadFailed:
            return "字幕下载失败，请稍后重试。"
        }
    }
}

struct SubtitleSearchService {
    private static let openSubsBase = "https://api.opensubtitles.com/api/v1"
    private static let agent = "MediaLIB v1.0"

    // MARK: - OpenSubtitles (requires API key)

    func search(
        title: String,
        year: Int?,
        imdbID: String?,
        language: String,
        apiKey: String
    ) async throws -> [SubtitleResult] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SubtitleError.missingAPIKey }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "languages", value: language),
            URLQueryItem(name: "order_by", value: "download_count"),
            URLQueryItem(name: "order_direction", value: "desc")
        ]
        if let year { queryItems.append(URLQueryItem(name: "year", value: "\(year)")) }
        if let imdbID, imdbID.hasPrefix("tt") { queryItems.append(URLQueryItem(name: "imdb_id", value: imdbID)) }

        var components = URLComponents(string: "\(Self.openSubsBase)/subtitles")
        components?.queryItems = queryItems
        guard let url = components?.url else { throw URLError(.badURL) }

        let (data, response) = try await makeOpenSubsRequest(url: url, apiKey: key)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubtitleError.searchFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let decoded = try JSONDecoder().decode(SubsSearchResponse.self, from: data)
        return decoded.data.compactMap { item in
            guard let file = item.attributes?.files?.first, file.file_id > 0 else { return nil }
            return SubtitleResult(
                id: item.id,
                fileID: file.file_id,
                displayName: file.file_name ?? item.attributes?.release ?? item.id,
                language: item.attributes?.language ?? language,
                downloadCount: item.attributes?.download_count ?? 0,
                isHearingImpaired: item.attributes?.hearing_impaired ?? false
            )
        }
    }

    func downloadAndSave(fileID: Int, videoPath: String, apiKey: String) async throws -> URL {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(Self.openSubsBase)/download") else { throw URLError(.badURL) }

        let body = try JSONEncoder().encode(["file_id": fileID])
        let (data, response) = try await makeOpenSubsRequest(url: url, apiKey: key, method: "POST", body: body)

        if let http = response as? HTTPURLResponse, http.statusCode == 406 || http.statusCode == 429 {
            throw SubtitleError.quotaExceeded
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubtitleError.downloadFailed
        }

        let info = try JSONDecoder().decode(SubsDownloadResponse.self, from: data)
        guard let dlURL = URL(string: info.link) else { throw SubtitleError.downloadFailed }

        let (subData, _) = try await URLSession.shared.data(from: dlURL)

        let videoURL = URL(fileURLWithPath: videoPath)
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let dir = videoURL.deletingLastPathComponent()
        let rawExt = URL(fileURLWithPath: info.file_name).pathExtension.lowercased()
        let ext = rawExt.isEmpty ? "srt" : rawExt
        let outputURL = dir.appendingPathComponent("\(baseName).\(ext)")
        try subData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    // MARK: - Unified multi-source search (free + configured)

    /// Searches all available sources (Podnapisi free + OpenSubtitles if API key configured).
    func searchAll(
        title: String,
        year: Int?,
        imdbID: String?,
        language: String,
        openSubtitlesKey: String?
    ) async -> [OnlineSubtitleResult] {
        async let podnapisiTask = searchPodnapisi(title: title, language: language)
        async let openSubsTask: [OnlineSubtitleResult] = {
            guard let key = openSubtitlesKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { return [] }
            let results = (try? await search(title: title, year: year, imdbID: imdbID, language: language, apiKey: key)) ?? []
            return results.map { r in
                OnlineSubtitleResult(
                    id: "os-\(r.id)", sourceName: "OpenSubtitles",
                    displayName: r.displayName, language: r.language,
                    downloads: r.downloadCount, source: .openSubtitles(fileID: r.fileID)
                )
            }
        }()
        let (pod, os) = await (podnapisiTask, openSubsTask)
        // Deduplicate by display name (case-insensitive)
        var seen = Set<String>()
        return (pod + os).filter { seen.insert($0.displayName.lowercased()).inserted }
    }

    /// Downloads a result from any source and saves next to the video file.
    func downloadOnline(result: OnlineSubtitleResult, videoPath: String, apiKey: String?) async throws -> URL {
        switch result.source {
        case .openSubtitles(let fileID):
            guard let key = apiKey, !key.isEmpty else { throw SubtitleError.missingAPIKey }
            return try await downloadAndSave(fileID: fileID, videoPath: videoPath, apiKey: key)
        case .podnapisi(let id):
            return try await downloadPodnapisi(id: id, videoPath: videoPath)
        }
    }

    // MARK: - Podnapisi.net (free, no API key required)

    private func searchPodnapisi(title: String, language: String) async -> [OnlineSubtitleResult] {
        guard var components = URLComponents(string: "https://www.podnapisi.net/api/search/1") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "keywords", value: title),
            URLQueryItem(name: "language", value: podnapisiLang(language)),
        ]
        guard let url = components.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return PodnapisiXMLParser(data: data).parse()
    }

    private func downloadPodnapisi(id: Int, videoPath: String) async throws -> URL {
        guard let url = URL(string: "https://www.podnapisi.net/subtitles/\(id)/download") else {
            throw SubtitleError.downloadFailed
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw SubtitleError.downloadFailed
        }
        let videoURL = URL(fileURLWithPath: videoPath)
        let base = videoURL.deletingPathExtension().lastPathComponent
        let dir = videoURL.deletingLastPathComponent()
        let outputURL = dir.appendingPathComponent("\(base).srt")
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func podnapisiLang(_ language: String) -> String {
        let l = language.lowercased()
        if l.hasPrefix("zh-hans") || l == "zh-cn" || l == "zh-sg" { return "zh" }
        if l.hasPrefix("zh-hant") || l == "zh-tw" || l == "zh-hk" { return "zht" }
        if l.hasPrefix("zh") { return "zh" }
        if l.hasPrefix("en") { return "en" }
        if l.hasPrefix("ja") { return "ja" }
        if l.hasPrefix("ko") { return "ko" }
        if l.hasPrefix("fr") { return "fr" }
        if l.hasPrefix("de") { return "de" }
        if l.hasPrefix("es") { return "es" }
        if l.hasPrefix("pt") { return "pt" }
        if l.hasPrefix("it") { return "it" }
        if l.hasPrefix("ru") { return "ru" }
        if l.hasPrefix("ar") { return "ar" }
        return l.components(separatedBy: "-").first ?? l
    }

    // MARK: - Shared HTTP

    private func makeOpenSubsRequest(
        url: URL,
        apiKey: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: req)
    }
}

// MARK: - Podnapisi XML Parsing

private final class PodnapisiXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let data: Data
    private var results: [OnlineSubtitleResult] = []
    private var currentTag = ""
    private var id = ""
    private var release = ""
    private var lang = ""
    private var dlCount = 0

    init(data: Data) { self.data = data }

    func parse() -> [OnlineSubtitleResult] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return results
    }

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentTag = name
        if name == "subtitle" { id = ""; release = ""; lang = ""; dlCount = 0 }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        switch currentTag {
        case "id": id = t
        case "release": if release.isEmpty { release = t }
        case "language": lang = t
        case "downloads": dlCount = Int(t) ?? 0
        default: break
        }
    }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "subtitle", let numID = Int(id) else { return }
        results.append(OnlineSubtitleResult(
            id: "pod-\(id)", sourceName: "Podnapisi",
            displayName: release.isEmpty ? "字幕 #\(id)" : release,
            language: lang.isEmpty ? "Unknown" : lang,
            downloads: dlCount,
            source: .podnapisi(subtitleID: numID)
        ))
    }
}

// MARK: - OpenSubtitles JSON Models

private struct SubsSearchResponse: Decodable { let data: [SubsItem] }
private struct SubsItem: Decodable { let id: String; let attributes: SubsAttrs? }
private struct SubsAttrs: Decodable {
    let language: String?
    let download_count: Int?
    let release: String?
    let hearing_impaired: Bool?
    let files: [SubsFile]?
}
private struct SubsFile: Decodable { let file_id: Int; let file_name: String? }
private struct SubsDownloadResponse: Decodable { let link: String; let file_name: String }
