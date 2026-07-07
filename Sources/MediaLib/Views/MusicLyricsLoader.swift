import Foundation
import MediaLibCore

enum MusicLyricsLoader {
    typealias MetadataLyricsProvider = @Sendable (URL) async -> String?

    static let emptyLyricsText = "暂无歌词"
    static let missingLyricsText = "暂无歌词\n\n可将同名 .lrc 或 .txt 歌词文件放在歌曲旁边，MediaLIB 会自动显示。"

    static func loadLyrics(
        for item: MediaItem,
        metadataLyricsProvider: @escaping MetadataLyricsProvider = { url in
            await defaultMetadataLyricsProvider(for: url)
        }
    ) async -> String {
        guard let filePath = item.filePath else { return emptyLyricsText }
        let url = URL(fileURLWithPath: filePath)
        if let sidecar = await sidecarLyrics(forAudioFileURL: url) {
            return sidecar
        }
        if let embeddedLyrics = await metadataLyricsProvider(url),
           !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return missingLyricsText
    }

    static func sidecarLyrics(forAudioFileURL url: URL) async -> String? {
        let directory = url.deletingLastPathComponent()
        let basename = url.deletingPathExtension().lastPathComponent
        let candidates = [
            directory.appendingPathComponent("\(basename).lrc"),
            directory.appendingPathComponent("\(basename).txt")
        ]

        return await BlockingIOExecutor.run {
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return text
                }
            }
            return nil
        }
    }

    static func localFileExists(atPath path: String) async -> Bool {
        await BlockingIOExecutor.run {
            FileManager.default.fileExists(atPath: path)
        }
    }

    private static func defaultMetadataLyricsProvider(for url: URL) async -> String? {
        let metadata = await AudioMetadataReader().metadata(for: url)
        return metadata.lyrics
    }
}
