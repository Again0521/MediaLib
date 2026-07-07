import Foundation

public enum VideoMetadataSidecarWriter {
    public static func xmlContent(for item: MediaItem, update: MediaMetadataUpdate) -> String {
        let rootTag = item.type == .movie ? "movie" : "tvshow"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <\(rootTag)>
          <title>\(xmlEscaped(update.title ?? item.title))</title>
          \(update.originalTitle.map { "<originaltitle>\(xmlEscaped($0))</originaltitle>" } ?? "")
          \(update.year.map { "<year>\($0)</year>" } ?? "")
          \(update.overview.map { "<plot>\(xmlEscaped($0))</plot>" } ?? "")
          \(update.rating.map { "<rating>\($0)</rating>" } ?? "")
          \(update.genre.map { "<genre>\(xmlEscaped($0))</genre>" } ?? "")
          \(update.externalID.map { "<uniqueid type=\"tmdb\">\(xmlEscaped($0))</uniqueid>" } ?? "")
        </\(rootTag)>
        """
    }

    @discardableResult
    public static func write(
        item: MediaItem,
        update: MediaMetadataUpdate,
        to targetURL: URL
    ) async throws -> Bool {
        let xml = xmlContent(for: item, update: update)
        return try await BlockingIOExecutor.run {
            let directory = targetURL.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: directory.path) else { return false }
            try xml.write(to: targetURL, atomically: true, encoding: .utf8)
            return true
        }
    }

    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
