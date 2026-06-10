import Foundation

public final class FilenameParser {
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "m4v", "wmv", "flv", "webm", "ts", "m2ts", "mts", "rmvb", "rm",
        "mpg", "mpeg", "3gp", "3g2", "vob", "ogv", "mxf", "divx", "f4v"
    ]

    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "ogg", "opus", "ape", "caf", "mka"
    ]

    public static let sidecarMetadataExtensions: Set<String> = [
        "lrc", "txt", "srt", "ass", "ssa", "vtt", "nfo", "cue",
        "jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "gif", "bmp", "avif"
    ]

    private let noiseTokens: Set<String> = [
        "1080p", "2160p", "720p", "480p", "4k", "8k", "bluray", "blu-ray", "bdrip",
        "web-dl", "webdl", "webrip", "hdr", "hdr10", "dv", "dolby", "vision",
        "x264", "x265", "h264", "h265", "hevc", "avc", "aac", "dts", "truehd",
        "atmos", "chs", "cht", "eng", "jpn", "kor", "字幕", "中字", "国配", "双语"
    ]

    // 所有固定正则预编译为静态字典，避免每次 firstMatch 都重新编译
    private static let compiledPatterns: [String: NSRegularExpression] = {
        let patterns: [String] = [
            #"(?i)(.*?)[\s._-]*S(\d{1,2})[\s._-]*E(\d{1,3})"#,
            #"(.*?)[\s._-]*第\s*(\d{1,2})\s*[季部][\s._-]*第\s*(\d{1,3})\s*[集话話]"#,
            #"(?i)(.*?)[\s._-]*(?:EP|E)(\d{1,3})(?:\D|$)"#,
            #"(?i)(.*?)(?:^|[\s._-])(\d{1,3})(?:\D|$)"#,
            #"(?i)Season\s*(\d{1,2})"#,
            #"第\s*(\d{1,2})\s*[季部]"#,
            #"(?:^|\D)(19\d{2}|20\d{2})(?:\D|$)"#,
            #"\[[^\]]*\]|\([^\)]*\)|【[^】]*】"#,
            #"\s*[\(\[]?(19\d{2}|20\d{2})[\)\]]?\s*$"#,
            #"(?i)[\s._-]*[\(\[]?(19\d{2}|20\d{2})[\)\]]?"#,
            #"^\d{3,4}p$"#
        ]
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (pattern, $0) }
        })
    }()

    public init() {}

    public func isVideoFile(_ url: URL) -> Bool {
        Self.supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    public func isAudioFile(_ url: URL) -> Bool {
        Self.supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    public func isSidecarMetadataFile(_ url: URL) -> Bool {
        Self.sidecarMetadataExtensions.contains(url.pathExtension.lowercased())
    }

    public func isMediaFile(_ url: URL, preferredType: MediaType) -> Bool {
        guard !isSidecarMetadataFile(url) else { return false }
        switch preferredType {
        case .music:
            return isAudioFile(url)
        case .auto:
            return isAudioFile(url) || isVideoFile(url)
        default:
            return isVideoFile(url)
        }
    }

    public func parse(url: URL, preferredType: MediaType = .auto, sourcePath: String? = nil) -> ParsedMediaFile {
        let filename = url.deletingPathExtension().lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent
        let grandParentName = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let seriesDirectory = seriesDirectory(for: url, sourcePath: sourcePath)
        let directoryTitle = seriesDirectory.map { cleanedTitle(removingYearSuffix(from: $0.lastPathComponent)) }.flatMap { $0.isEmpty ? nil : $0 }

        if preferredType != .movie, let episode = parseEpisode(
            filename: filename,
            parentName: parentName,
            grandParentName: grandParentName,
            directoryTitle: directoryTitle,
            seriesDirectoryPath: seriesDirectory?.path
        ) {
            return episode
        }

        if preferredType == .tvShow || preferredType == .anime || preferredType == .variety,
           let episode = parseEpisode(
            filename: filename,
            parentName: parentName,
            grandParentName: grandParentName,
            directoryTitle: directoryTitle,
            seriesDirectoryPath: seriesDirectory?.path
           ) {
            return episode
        }

        return parseMovie(filename: filename, parentName: parentName)
    }

    public func seriesDirectory(for url: URL, sourcePath: String?) -> URL? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let source = sourcePath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let candidate: URL
        if seasonNumber(from: parent.lastPathComponent) != nil || isSeasonFolder(parent.lastPathComponent) {
            candidate = parent.deletingLastPathComponent().standardizedFileURL
        } else {
            candidate = parent
        }

        if let source, candidate.path == source.path {
            return nil
        }
        return candidate
    }

    private func parseEpisode(
        filename: String,
        parentName: String,
        grandParentName: String,
        directoryTitle: String?,
        seriesDirectoryPath: String?
    ) -> ParsedMediaFile? {
        let normalized = normalizeSeparators(filename)

        if let match = firstMatch(pattern: #"(?i)(.*?)[\s._-]*S(\d{1,2})[\s._-]*E(\d{1,3})"#, in: normalized),
           match.count >= 4,
           let season = Int(match[2]),
           let episode = Int(match[3]) {
            let fallbackTitle = match[1].isEmpty ? seriesName(parentName: parentName, grandParentName: grandParentName) : match[1]
            let title = directoryTitle ?? cleanedTitle(fallbackTitle)
            return ParsedMediaFile(kind: .episode, title: title, seasonNumber: season, episodeNumber: episode, seriesDirectoryPath: seriesDirectoryPath)
        }

        if let match = firstMatch(pattern: #"(.*?)[\s._-]*第\s*(\d{1,2})\s*[季部][\s._-]*第\s*(\d{1,3})\s*[集话話]"#, in: normalized),
           match.count >= 4,
           let season = Int(match[2]),
           let episode = Int(match[3]) {
            let fallbackTitle = match[1].isEmpty ? seriesName(parentName: parentName, grandParentName: grandParentName) : match[1]
            let title = directoryTitle ?? cleanedTitle(fallbackTitle)
            return ParsedMediaFile(kind: .episode, title: title, seasonNumber: season, episodeNumber: episode, seriesDirectoryPath: seriesDirectoryPath)
        }

        if let match = firstMatch(pattern: #"(?i)(.*?)[\s._-]*(?:EP|E)(\d{1,3})(?:\D|$)"#, in: normalized),
           match.count >= 3,
           let episode = Int(match[2]) {
            let rawTitle = match[1].isEmpty ? seriesName(parentName: parentName, grandParentName: grandParentName) : match[1]
            return ParsedMediaFile(kind: .episode, title: directoryTitle ?? cleanedTitle(rawTitle), seasonNumber: seasonNumber(from: parentName) ?? 1, episodeNumber: episode, seriesDirectoryPath: seriesDirectoryPath)
        }

        if isSeasonFolder(parentName) {
            let season = seasonNumber(from: parentName) ?? 1
            if let match = firstMatch(pattern: #"(?i)(.*?)(?:^|[\s._-])(\d{1,3})(?:\D|$)"#, in: normalized),
               match.count >= 3,
               let episode = Int(match[2]) {
                return ParsedMediaFile(kind: .episode, title: directoryTitle ?? cleanedTitle(seriesName(parentName: parentName, grandParentName: grandParentName)), seasonNumber: season, episodeNumber: episode, seriesDirectoryPath: seriesDirectoryPath)
            }
        }

        return nil
    }

    private func isSeasonFolder(_ value: String) -> Bool {
        seasonNumber(from: value) != nil ||
        value.localizedCaseInsensitiveContains("Specials") ||
        value.localizedCaseInsensitiveContains("Season")
    }

    private func removingYearSuffix(from value: String) -> String {
        let pattern = #"\s*[\(\[]?(19\d{2}|20\d{2})[\)\]]?\s*$"#
        guard let regex = Self.compiledPatterns[pattern] else { return value }
        let ns = value as NSString
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    private func parseMovie(filename: String, parentName: String) -> ParsedMediaFile {
        let normalized = normalizeSeparators(filename)
        let year = year(from: normalized) ?? year(from: parentName)
        let movieYearPattern = #"(?i)[\s._-]*[\(\[]?(19\d{2}|20\d{2})[\)\]]?"#
        let titleWithoutYear: String
        if let regex = Self.compiledPatterns[movieYearPattern] {
            let ns = normalized as NSString
            titleWithoutYear = regex.stringByReplacingMatches(
                in: normalized,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: " "
            )
        } else {
            titleWithoutYear = normalized
        }
        var title = cleanedTitle(titleWithoutYear)
        if title.isEmpty || title.count <= 2 {
            title = cleanedTitle(parentName)
        }
        return ParsedMediaFile(kind: .movie, title: title, year: year)
    }

    private func normalizeSeparators(_ value: String) -> String {
        value
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func cleanedTitle(_ value: String) -> String {
        let bracketPattern = #"\[[^\]]*\]|\([^\)]*\)|【[^】]*】"#
        let bracketless: String
        if let regex = Self.compiledPatterns[bracketPattern] {
            let nsValue = value as NSString
            bracketless = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: nsValue.length),
                withTemplate: " "
            )
        } else {
            bracketless = value
        }
        let resolutionPattern = #"^\d{3,4}p$"#
        let resolutionRegex = Self.compiledPatterns[resolutionPattern]
        let tokens = bracketless
            .replacingOccurrences(of: "-", with: " ")
            .split { $0.isWhitespace || $0 == "." || $0 == "_" }
            .filter { token in
                let lower = token.lowercased()
                if noiseTokens.contains(lower) { return false }
                if let regex = resolutionRegex {
                    let ns = lower as NSString
                    if regex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) != nil { return false }
                }
                return true
            }
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func seriesName(parentName: String, grandParentName: String) -> String {
        if seasonNumber(from: parentName) != nil {
            return grandParentName
        }
        return parentName
    }

    private func seasonNumber(from value: String) -> Int? {
        if let match = firstMatch(pattern: #"(?i)Season\s*(\d{1,2})"#, in: value), match.count >= 2 {
            return Int(match[1])
        }
        if let match = firstMatch(pattern: #"第\s*(\d{1,2})\s*[季部]"#, in: value), match.count >= 2 {
            return Int(match[1])
        }
        return nil
    }

    private func year(from value: String) -> Int? {
        guard let match = firstMatch(pattern: #"(?:^|\D)(19\d{2}|20\d{2})(?:\D|$)"#, in: value),
              match.count >= 2 else { return nil }
        return Int(match[1])
    }

    private func firstMatch(pattern: String, in value: String) -> [String]? {
        guard let regex = Self.compiledPatterns[pattern] else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard let swiftRange = Range(range, in: value) else { return "" }
            return String(value[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
