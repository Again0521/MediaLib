import AppKit
import Foundation

/// 一个可用的新版本（来自 GitHub Releases）。
struct AppUpdateInfo: Identifiable, Equatable {
    let version: String
    let tagName: String
    let releaseNotes: String
    let releaseURL: URL

    var id: String { tagName }
}

enum AppVersion {
    /// 打包版从 Info.plist 读取；swift run 裸二进制兜底用当前发布版本。
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.0"
    }

    /// 语义化版本比较（x.y.z，越靠前的数字权重越大）。
    static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = baseline.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// 从 GitHub Releases 检查更新（Sparkle 式体验的轻量替代：
/// 用官方 releases/latest API + dmg 资产判定，避免引入第三方更新框架）。
enum AppUpdateChecker {
    static let repositoryPage = URL(string: "https://github.com/Again0521/MediaLib/releases")!

    /// 返回最新的、带 .dmg 资产的 release；没有更新渠道资产时视为无更新。
    static func fetchLatestRelease() async throws -> AppUpdateInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Again0521/MediaLib/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            return nil
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let hasDMGAsset = assets.contains { asset in
            ((asset["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
        }
        guard hasDMGAsset else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return AppUpdateInfo(
            version: version,
            tagName: tag,
            releaseNotes: (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            releaseURL: pageURL
        )
    }
}
