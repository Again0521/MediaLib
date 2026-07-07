import Foundation

public struct LocalMetadata: Sendable {
    public var title: String?
    public var originalTitle: String?
    public var year: Int?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?

    public init(
        title: String? = nil,
        originalTitle: String? = nil,
        year: Int? = nil,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil
    ) {
        self.title = Self.cleaned(title)
        self.originalTitle = Self.cleaned(originalTitle)
        self.year = Self.normalizedYear(year)
        self.overview = Self.cleaned(overview)
        self.posterPath = Self.cleaned(posterPath)
        self.backdropPath = Self.cleaned(backdropPath)
    }

    static func normalizedYear(_ year: Int?) -> Int? {
        guard let year, year > 0 else { return nil }
        return year
    }

    private static func cleaned(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }
}

public final class LocalMetadataService: @unchecked Sendable {
    private let fileManager: FileManager
    private let posterNames = LocalMetadataService.artworkNames(stems: ["poster", "cover", "folder"])
    private let backdropNames = LocalMetadataService.artworkNames(stems: ["fanart", "backdrop", "background"])

    // 预编译常用 NFO 字段正则，避免每次解析都重新编译
    private static let compiledTagPatterns: [String: NSRegularExpression] = {
        let tagNames = ["title", "originaltitle", "year", "plot", "overview"]
        return Dictionary(uniqueKeysWithValues: tagNames.compactMap { name in
            let pattern = "<\(name)>\\s*([^<]+)\\s*</\(name)>"
            return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { (name, $0) }
        })
    }()

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private static func artworkNames(stems: [String]) -> [String] {
        let extensions = ["jpg", "jpeg", "png", "webp", "heic"]
        return stems.flatMap { stem in extensions.map { "\(stem).\($0)" } }
    }

    public func metadata(for videoURL: URL, readNFO: Bool, preferLocalArtwork: Bool) -> LocalMetadata {
        let directory = videoURL.deletingLastPathComponent()
        var metadata = readNFO ? parseNFO(near: videoURL) : LocalMetadata()

        if preferLocalArtwork {
            metadata.posterPath = metadata.posterPath ?? firstExistingFile(named: posterNames, in: directory)?.path
            metadata.backdropPath = metadata.backdropPath ?? firstExistingFile(named: backdropNames, in: directory)?.path
        }

        return metadata
    }

    public func metadataAsync(for videoURL: URL, readNFO: Bool, preferLocalArtwork: Bool) async -> LocalMetadata {
        await BlockingIOExecutor.run {
            self.metadata(for: videoURL, readNFO: readNFO, preferLocalArtwork: preferLocalArtwork)
        }
    }

    public func metadata(forDirectory directory: URL, readNFO: Bool, preferLocalArtwork: Bool) -> LocalMetadata {
        var metadata = readNFO ? parseNFO(candidates: [
            directory.appendingPathComponent("tvshow.nfo"),
            directory.appendingPathComponent("movie.nfo")
        ]) : LocalMetadata()

        if preferLocalArtwork {
            metadata.posterPath = metadata.posterPath ?? firstExistingFile(named: posterNames, in: directory)?.path
            metadata.backdropPath = metadata.backdropPath ?? firstExistingFile(named: backdropNames, in: directory)?.path
        }

        return metadata
    }

    public func metadataAsync(forDirectory directory: URL, readNFO: Bool, preferLocalArtwork: Bool) async -> LocalMetadata {
        await BlockingIOExecutor.run {
            self.metadata(forDirectory: directory, readNFO: readNFO, preferLocalArtwork: preferLocalArtwork)
        }
    }

    private func firstExistingFile(named names: [String], in directory: URL) -> URL? {
        for name in names {
            let url = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func parseNFO(near videoURL: URL) -> LocalMetadata {
        let directory = videoURL.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("movie.nfo"),
            directory.appendingPathComponent("tvshow.nfo"),
            videoURL.deletingPathExtension().appendingPathExtension("nfo")
        ]

        return parseNFO(candidates: candidates)
    }

    private func parseNFO(candidates: [URL]) -> LocalMetadata {
        guard let nfoURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let raw = try? String(contentsOf: nfoURL, encoding: .utf8) else {
            return LocalMetadata()
        }

        return LocalMetadata(
            title: tag("title", in: raw),
            originalTitle: tag("originaltitle", in: raw),
            year: tag("year", in: raw).flatMap(Int.init),
            overview: tag("plot", in: raw) ?? tag("overview", in: raw),
            posterPath: nil,
            backdropPath: nil
        )
    }

    private func tag(_ name: String, in raw: String) -> String? {
        let regex: NSRegularExpression
        if let cached = Self.compiledTagPatterns[name] {
            regex = cached
        } else if let compiled = try? NSRegularExpression(
            pattern: "<\(name)>\\s*([^<]+)\\s*</\(name)>",
            options: .caseInsensitive
        ) {
            regex = compiled
        } else {
            return nil
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              match.numberOfRanges >= 2,
              let swiftRange = Range(match.range(at: 1), in: raw) else {
            return nil
        }
        let value = String(raw[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
