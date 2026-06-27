import AppKit
import Foundation

/// 一个可用的新版本（来自 GitHub Releases）。
struct AppUpdateInfo: Identifiable, Equatable {
    let version: String
    let tagName: String
    let title: String
    let releaseNotes: String
    let releaseURL: URL
    let downloadURL: URL?
    let assetName: String?
    let assetSize: Int?
    let publishedAt: Date?
    let prerelease: Bool

    var id: String { tagName }
}

enum AppVersion {
    /// 打包版从 Info.plist 读取；swift run 裸二进制兜底用当前发布版本。
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.2.5"
    }

    /// 从任意文本里提取版本号：抓出第一段「点分数字」，如 v1.1.1 / MediaLIB_V1.1.8 / 标题里的 1.1.11。
    /// 返回归一化后的字符串（去掉前导 v、保留原始数字段）。
    static func extractVersion(from text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "_", with: ".")
        guard let range = normalized.range(of: #"(?i)(?<!\d)v?\d+(?:\.\d+){1,3}(?!\d)"#, options: .regularExpression) else {
            return nil
        }
        return String(normalized[range]).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    /// 数字化版本比较：按小数点分段，逐段比较整数大小（越靠前权重越大）。
    /// 例：1.20.01 < 1.20.10（第三段 1 < 10），1.1.2 < 1.1.11。
    static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        let lhs = components(of: candidate)
        let rhs = components(of: baseline)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}

/// 从 GitHub Releases 检查更新（Sparkle 式体验的轻量替代：
/// 用官方 Releases API + dmg 资产判定，避免引入第三方更新框架）。
enum AppUpdateChecker {
    static let repositoryPage = URL(string: "https://github.com/Again0521/MediaLib/releases")!
    private static let releaseSources: [GitHubReleaseSource] = [
        .init(owner: "Again0521", repository: "MediaLib"),
        // 为后续软件更名预备：该仓库当前可能不存在，404 时静默跳过。
        .init(owner: "Again0521", repository: "LumiNest")
    ]
    private static let releaseDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let fallbackReleaseDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 拉取 releases 列表，从 tag/title/body/assets 中提取版本号，
    /// 并在可安装资产中选出版本号最大的发布。
    static func fetchLatestRelease() async throws -> AppUpdateInfo? {
        var best: (version: String, info: AppUpdateInfo)?
        var lastError: Error?

        for source in releaseSources {
            do {
                guard let candidate = try await fetchLatestRelease(from: source) else { continue }
                if let current = best {
                    if AppVersion.isVersion(candidate.version, newerThan: current.version) {
                        best = (candidate.version, candidate)
                    } else if candidate.version == current.version,
                              let currentDate = current.info.publishedAt,
                              let candidateDate = candidate.publishedAt,
                              candidateDate > currentDate {
                        best = (candidate.version, candidate)
                    }
                } else {
                    best = (candidate.version, candidate)
                }
            } catch {
                lastError = error
            }
        }

        if let best {
            return best.info
        }
        if let lastError {
            throw lastError
        }
        return nil
    }

    private static func fetchLatestRelease(from source: GitHubReleaseSource) async throws -> AppUpdateInfo? {
        var request = URLRequest(url: source.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MediaLIB/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                return nil
            }
            throw URLError(.badServerResponse)
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        var best: (version: String, info: AppUpdateInfo)?
        for release in releases {
            guard !release.draft else { continue }
            guard let version = version(for: release),
                  let asset = preferredAsset(in: release.assets),
                  let pageURL = URL(string: release.htmlURL) else { continue }
            let publishedAt = release.publishedAt.flatMap(parseReleaseDate)
            let info = AppUpdateInfo(
                version: version,
                tagName: release.tagName.isEmpty ? version : release.tagName,
                title: cleanReleaseTitle(release.name ?? "", version: version),
                releaseNotes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                releaseURL: pageURL,
                downloadURL: URL(string: asset.browserDownloadURL),
                assetName: asset.name,
                assetSize: asset.size,
                publishedAt: publishedAt,
                prerelease: release.prerelease
            )
            if let current = best {
                if AppVersion.isVersion(version, newerThan: current.version) {
                    best = (version, info)
                } else if version == current.version,
                          let currentDate = current.info.publishedAt,
                          let publishedAt,
                          publishedAt > currentDate {
                    best = (version, info)
                }
            } else {
                best = (version, info)
            }
        }
        return best?.info
    }

    private static func version(for release: GitHubRelease) -> String? {
        let candidates = [
            release.tagName,
            release.name ?? "",
            release.body ?? ""
        ] + release.assets.map(\.name)
        return candidates.compactMap(AppVersion.extractVersion(from:)).first
    }

    private static func preferredAsset(in assets: [GitHubAsset]) -> GitHubAsset? {
        assets
            .filter { !$0.browserDownloadURL.isEmpty }
            .sorted { lhs, rhs in
                let lhsRank = assetRank(lhs)
                let rhsRank = assetRank(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.size > rhs.size
            }
            .first { assetRank($0) < 100 }
    }

    private static func assetRank(_ asset: GitHubAsset) -> Int {
        let name = asset.name.lowercased()
        let type = asset.contentType.lowercased()
        if name.hasSuffix(".dmg") || type.contains("diskimage") { return 0 }
        if name.contains("medialib.app") && name.hasSuffix(".zip") { return 1 }
        if name.hasSuffix(".zip") { return 2 }
        return 100
    }

    private static func cleanReleaseTitle(_ raw: String, version: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "MediaLIB \(version)" }
        let compact = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"(?i)\bmedia\s*lib\b"#, with: "MediaLIB", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bv(?=\d)"#, with: "", options: .regularExpression)
        return compact.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseReleaseDate(_ text: String) -> Date? {
        releaseDateFormatter.date(from: text) ?? fallbackReleaseDateFormatter.date(from: text)
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubReleaseSource {
    let owner: String
    let repository: String

    var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=30")!
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let contentType: String
    let size: Int
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case contentType = "content_type"
        case size
        case browserDownloadURL = "browser_download_url"
    }
}
