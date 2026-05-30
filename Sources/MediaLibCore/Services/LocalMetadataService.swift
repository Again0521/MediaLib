import Foundation

public struct LocalMetadata {
    public var title: String?
    public var originalTitle: String?
    public var year: Int?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
}

public final class LocalMetadataService {
    private let fileManager: FileManager
    private let posterNames = ["poster.jpg", "poster.png", "cover.jpg", "cover.png", "folder.jpg", "folder.png"]
    private let backdropNames = ["fanart.jpg", "fanart.png", "backdrop.jpg", "backdrop.png", "background.jpg", "background.png"]

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

    public func metadata(for videoURL: URL, readNFO: Bool, preferLocalArtwork: Bool) -> LocalMetadata {
        let directory = videoURL.deletingLastPathComponent()
        var metadata = readNFO ? parseNFO(near: videoURL) : LocalMetadata()

        if preferLocalArtwork {
            metadata.posterPath = metadata.posterPath ?? firstExistingFile(named: posterNames, in: directory)?.path
            metadata.backdropPath = metadata.backdropPath ?? firstExistingFile(named: backdropNames, in: directory)?.path
        }

        return metadata
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
        return String(raw[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
