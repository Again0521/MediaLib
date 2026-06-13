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
    let publishedAt: Date?

    var id: String { tagName }
}

enum AppVersion {
    /// 打包版从 Info.plist 读取；swift run 裸二进制兜底用当前发布版本。
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.3"
    }

    /// 从任意文本里提取版本号：抓出第一段「点分数字」，如 v1.1.1 / 1.20.01 / 标题里的 1.1.11。
    /// 返回归一化后的字符串（去掉前导 v、保留原始数字段）。
    static func extractVersion(from text: String) -> String? {
        // 匹配两段及以上点分数字（1.1 / 1.1.1 / 1.20.01 ...）。
        guard let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
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

    /// 拉取 releases 列表，从每个 release 的「标签 + 标题」里提取版本号，
    /// 在带 .dmg 资产的 release 中选出版本号最大的一个返回。
    static func fetchLatestRelease() async throws -> AppUpdateInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Again0521/MediaLib/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        var best: (version: String, info: AppUpdateInfo)?
        for release in releases {
            // 草稿不展示给用户。
            if (release["draft"] as? Bool) == true { continue }
            let tag = (release["tag_name"] as? String) ?? ""
            let title = (release["name"] as? String) ?? ""
            // 标签优先，标题兜底——「检测标签与标题中的数字」。
            guard let version = AppVersion.extractVersion(from: tag)
                ?? AppVersion.extractVersion(from: title) else { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            let dmgAsset = assets.first { asset in
                ((asset["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
            }
            guard let dmgAsset else { continue }
            guard let pageURL = (release["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
            let publishedAt = (release["published_at"] as? String).flatMap(parseReleaseDate)
            let info = AppUpdateInfo(
                version: version,
                tagName: tag.isEmpty ? version : tag,
                title: title.isEmpty ? "MediaLIB \(version)" : title,
                releaseNotes: (release["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                releaseURL: pageURL,
                downloadURL: (dmgAsset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                publishedAt: publishedAt
            )
            if let current = best {
                if AppVersion.isVersion(version, newerThan: current.version) {
                    best = (version, info)
                }
            } else {
                best = (version, info)
            }
        }
        return best?.info
    }

    private static func parseReleaseDate(_ text: String) -> Date? {
        releaseDateFormatter.date(from: text) ?? fallbackReleaseDateFormatter.date(from: text)
    }
}
