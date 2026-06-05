import Foundation

/// 中文拼音 / 模糊搜索匹配器。
/// 在原有"子串包含"基础上，额外支持：
/// - 全拼匹配（"beijiaer" 命中"贝加尔"）
/// - 拼音首字母匹配（"bje" 命中"贝加尔"，"bb" 命中"Breaking Bad"）
/// 用 CFStringTransform 把中日韩转写为拉丁拼音并缓存，避免每次按键重复转写。
enum PinyinSearchMatcher {
    private struct Forms {
        let lowercased: String
        let pinyinJoined: String
        let pinyinInitials: String
    }

    private static var cache: [String: Forms] = [:]
    private static let lock = NSLock()
    private static let cacheLimit = 40_000

    /// query 命中 fields 中任意一项即返回 true；query 为空视为全部命中。
    static func matches(query: String, in fields: [String?]) -> Bool {
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }
        let queryIsLatin = isLatinQuery(normalizedQuery)
        for case let field? in fields where !field.isEmpty {
            if matchesField(field, query: normalizedQuery, queryIsLatin: queryIsLatin) {
                return true
            }
        }
        return false
    }

    private static func matchesField(_ field: String, query: String, queryIsLatin: Bool) -> Bool {
        let forms = forms(for: field)
        if forms.lowercased.contains(query) { return true }
        // 拼音匹配只在 query 是拉丁字母时进行（用户用拼音/首字母搜中文）。
        guard queryIsLatin else { return false }
        if forms.pinyinJoined.contains(query) { return true }
        if forms.pinyinInitials.contains(query) { return true }
        return false
    }

    private static func forms(for source: String) -> Forms {
        lock.lock()
        if let cached = cache[source] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let lowercased = source.lowercased()
        let (joined, initials) = pinyin(of: source)
        let forms = Forms(lowercased: lowercased, pinyinJoined: joined, pinyinInitials: initials)

        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[source] = forms
        lock.unlock()
        return forms
    }

    private static func pinyin(of source: String) -> (joined: String, initials: String) {
        let mutable = NSMutableString(string: source) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let latin = (mutable as String).lowercased()
        let syllables = latin.split { !$0.isLetter && !$0.isNumber }
        let joined = syllables.joined()
        let initials = String(syllables.compactMap { $0.first })
        return (joined, initials)
    }

    private static func isLatinQuery(_ query: String) -> Bool {
        query.unicodeScalars.allSatisfy { scalar in
            scalar == " " || (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)))
        }
    }
}
