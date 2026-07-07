import Foundation

public enum MusicPlaylistM3UPolicy {
    public static func m3uContent(for tracks: [MediaItem]) -> String {
        var lines = ["#EXTM3U"]
        for track in tracks {
            guard let path = track.filePath,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let seconds = extinfSeconds(for: track.duration)
            let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let info = artist.isEmpty ? track.title : "\(artist) - \(track.title)"
            lines.append("#EXTINF:\(seconds),\(info)")
            lines.append(path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func extinfSeconds(for duration: Double?) -> Int {
        guard let duration, duration.isFinite else { return 0 }
        let rounded = duration.rounded()
        guard rounded >= Double(Int.min), rounded <= Double(Int.max) else { return 0 }
        return Int(rounded)
    }

    public static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    public static func candidatePaths(from content: String, baseDirectory: URL) -> [String] {
        content
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                if isAbsoluteOrURLPath(line) { return line }
                return baseDirectory.appendingPathComponent(line).standardizedFileURL.path
            }
    }

    public static func matchedTracks(for candidatePaths: [String], in musicTracks: [MediaItem]) -> [MediaItem] {
        let byPath = Dictionary(musicTracks.compactMap { track in
            track.filePath.map { ($0, track) }
        }, uniquingKeysWith: { first, _ in first })
        let byFilename = Dictionary(musicTracks.compactMap { track -> (String, MediaItem)? in
            guard let path = track.filePath else { return nil }
            return (filenameComponent(from: path), track)
        }, uniquingKeysWith: { first, _ in first })

        var matched: [MediaItem] = []
        var seenIDs = Set<String>()
        for path in candidatePaths {
            let track = byPath[path] ?? byFilename[filenameComponent(from: path)]
            if let track, seenIDs.insert(track.id).inserted {
                matched.append(track)
            }
        }
        return matched
    }

    private static func isAbsoluteOrURLPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            || path.hasPrefix(#"\\"#)
            || path.contains("://")
            || isWindowsDrivePath(path)
    }

    private static func isWindowsDrivePath(_ path: String) -> Bool {
        guard path.count >= 3 else { return false }
        let prefix = Array(path.prefix(3))
        return prefix[0].isLetter
            && prefix[1] == ":"
            && (prefix[2] == "\\" || prefix[2] == "/")
    }

    private static func filenameComponent(from path: String) -> String {
        if path.hasPrefix(#"\\"#) || isWindowsDrivePath(path) {
            return URL(fileURLWithPath: path.replacingOccurrences(of: #"\"#, with: "/")).lastPathComponent
        }
        if let url = URL(string: path),
           url.scheme != nil,
           !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return URL(fileURLWithPath: path.replacingOccurrences(of: #"\"#, with: "/")).lastPathComponent
    }
}
