import Foundation

/// 将常见影视分级归一成最低建议年龄。设置了上限却遇到无法识别的分级时失败即拒绝，
/// 避免一个新标签绕过家长策略；未设置上限时保持升级前行为。
enum ServerContentRatingPolicy {
    static func allows(contentRating: String?, maximum: String?) -> Bool {
        guard let maximum else { return true }
        guard let maximumAge = age(for: maximum),
              let contentRating,
              let contentAge = age(for: contentRating)
        else { return false }
        return contentAge <= maximumAge
    }

    static func age(for rawValue: String) -> Int? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let exact: [String: Int] = [
            "G": 0, "TV-Y": 0, "TV-G": 0, "U": 0, "ALL": 0,
            "TV-Y7": 7, "PG": 8, "TV-PG": 10,
            "PG-13": 13, "TV-14": 14,
            "R": 17, "TV-MA": 17, "NC-17": 18, "X": 18
        ]
        if let value = exact[normalized] { return value }
        let components = normalized.split(whereSeparator: { !$0.isNumber })
        guard let numeric = components.compactMap({ Int($0) }).first,
              (0...21).contains(numeric) else { return nil }
        return numeric
    }
}
