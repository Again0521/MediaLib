import Foundation
import MediaLibCore

enum URLSourcePolicy {
    static let mediaSourcePath = "urlsource://local"
    static let mediaSchemes: Set<String> = ["http", "https", "rtsp", "rtmp", "rtp", "mms", "srt", "udp", "ftp"]

    static func normalizedURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              mediaSchemes.contains(scheme),
              components.host?.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    static func defaultTitle(forURL urlString: String) -> String {
        if let url = URL(string: urlString) {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/" {
                let stem = (last as NSString).deletingPathExtension
                return stem.isEmpty ? last : stem
            }
            if let host = url.host, !host.isEmpty { return host }
        }
        return "URL 视频"
    }

    static func addableURLCount(in raw: String) -> Int {
        var seen = Set<String>()
        for candidate in candidateLines(from: raw) {
            if let normalized = normalizedURLString(candidate) {
                seen.insert(normalized)
            }
        }
        return seen.count
    }

    static func normalizedMultilineURLs(from raw: String) -> [String] {
        candidateLines(from: raw).compactMap(normalizedURLString)
    }

    static func probeItems(from items: [MediaItem]) -> [(id: String, url: URL)] {
        items.compactMap { item -> (id: String, url: URL)? in
            guard let filePath = item.filePath,
                  let url = URL(string: filePath),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }
            return (item.id, url)
        }
    }

    private static func candidateLines(from raw: String) -> [String] {
        let lines = raw.split(whereSeparator: { $0.isNewline }).map(String.init)
        return lines.isEmpty ? [raw] : lines
    }
}
