import Foundation
import MediaLibCore

/// 将常见影视分级归一成最低建议年龄。设置了上限却遇到无法识别的分级时失败即拒绝，
/// 避免一个新标签绕过家长策略；未设置上限时保持升级前行为。
enum ServerContentRatingPolicy {
    static func allows(contentRating: String?, maximum: String?) -> Bool {
        ServerContentRatingAgePolicy.allows(contentRating: contentRating, maximum: maximum)
    }

    static func age(for rawValue: String) -> Int? {
        ServerContentRatingAgePolicy.age(for: rawValue)
    }
}
