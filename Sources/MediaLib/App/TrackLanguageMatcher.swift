import Foundation

enum TrackLanguageMatcher {
    private struct LanguageIdentity: Equatable {
        let base: String
        let script: String?
    }

    static func bestTrack(in tracks: [MpvTrack], matching preferredLanguage: String) -> MpvTrack? {
        let candidates = tracks.compactMap { track -> (track: MpvTrack, score: Int)? in
            let score = score(track: track, preferredLanguage: preferredLanguage)
            return score > 0 ? (track, score) : nil
        }
        return candidates
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.track.isSelected != $1.track.isSelected { return $0.track.isSelected }
                return $0.track.id < $1.track.id
            }
            .first?
            .track
    }

    private static func score(track: MpvTrack, preferredLanguage: String) -> Int {
        let languageScore = score(text: track.language, preferredLanguage: preferredLanguage)
        let titleScore = max(
            score(text: track.title, preferredLanguage: preferredLanguage) - 8,
            score(
                text: track.externalFilename.map { URL(fileURLWithPath: $0).lastPathComponent },
                preferredLanguage: preferredLanguage
            ) - 10
        )
        return max(languageScore, titleScore)
    }

    private static func score(text: String?, preferredLanguage: String) -> Int {
        guard let preferred = identity(for: preferredLanguage),
              let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }
        let normalizedText = normalized(text)
        let normalizedPreferred = normalized(preferredLanguage)
        let identities = identities(in: normalizedText)
        guard !identities.isEmpty else { return 0 }
        return identities.reduce(0) { best, candidate in
            max(best, score(candidate: candidate, preferred: preferred, exact: normalizedText == normalizedPreferred))
        }
    }

    private static func score(candidate: LanguageIdentity, preferred: LanguageIdentity, exact: Bool) -> Int {
        guard candidate.base == preferred.base else { return 0 }
        if exact { return 120 }
        if let candidateScript = candidate.script,
           let preferredScript = preferred.script {
            return candidateScript == preferredScript ? 105 : (candidate.base == "zh" ? 62 : 0)
        }
        if candidate.script == nil || preferred.script == nil {
            return 88
        }
        return 80
    }

    private static func identity(for text: String) -> LanguageIdentity? {
        identities(in: normalized(text)).first
    }

    private static func identities(in normalizedText: String) -> [LanguageIdentity] {
        var result: [LanguageIdentity] = []
        func append(_ base: String, script: String? = nil) {
            let identity = LanguageIdentity(base: base, script: script)
            if !result.contains(identity) {
                result.append(identity)
            }
        }

        let tokens = Set(normalizedText.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let hasToken: (String) -> Bool = { tokens.contains($0) }
        let contains: (String) -> Bool = { normalizedText.contains($0) }

        if contains("简") || contains("简体") || contains("simplified") ||
            hasToken("chs") || hasToken("sc") || hasToken("cn") ||
            contains("zh-cn") || contains("zh-hans") || contains("zh-sg") {
            append("zh", script: "hans")
        }
        if contains("繁") || contains("繁體") || contains("traditional") ||
            hasToken("cht") || hasToken("tc") || hasToken("tw") || hasToken("hk") ||
            contains("zh-tw") || contains("zh-hk") || contains("zh-mo") || contains("zh-hant") {
            append("zh", script: "hant")
        }
        if contains("中文") || contains("汉语") || contains("漢語") || contains("普通话") ||
            contains("國語") || contains("国语") || contains("mandarin") ||
            hasToken("zh") || hasToken("zho") || hasToken("chi") || hasToken("cmn") ||
            hasToken("chinese") {
            append("zh")
        }

        if hasToken("en") || hasToken("eng") || contains("english") { append("en") }
        if hasToken("ja") || hasToken("jpn") || hasToken("jp") || contains("japanese") ||
            contains("日本語") || contains("日语") || contains("日文") {
            append("ja")
        }
        if hasToken("ko") || hasToken("kor") || hasToken("kr") || contains("korean") ||
            contains("한국어") || contains("韩语") || contains("韓語") {
            append("ko")
        }

        let iso3Aliases: [String: String] = [
            "fre": "fr", "fra": "fr", "french": "fr",
            "ger": "de", "deu": "de", "german": "de",
            "spa": "es", "spanish": "es",
            "por": "pt", "portuguese": "pt",
            "ita": "it", "italian": "it",
            "rus": "ru", "russian": "ru",
            "vie": "vi", "vietnamese": "vi",
            "tha": "th", "thai": "th",
            "ind": "id", "indonesian": "id",
            "msa": "ms", "may": "ms", "malay": "ms"
        ]
        for token in tokens {
            if token.count == 2 {
                append(token)
            } else if let alias = iso3Aliases[token] {
                append(alias)
            }
        }

        return result
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }
}
