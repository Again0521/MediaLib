import Foundation

public struct MusicTagDraft: Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var lyrics: String?
    public var artworkPath: String?
    public var externalID: String?
    public var metadataProvider: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        year: Int? = nil,
        lyrics: String? = nil,
        artworkPath: String? = nil,
        externalID: String? = nil,
        metadataProvider: String? = nil
    ) {
        self.title = Self.cleaned(title)
        self.artist = Self.cleaned(artist)
        self.album = Self.cleaned(album)
        self.trackNumber = trackNumber
        self.year = year
        self.lyrics = Self.cleaned(lyrics)
        self.artworkPath = Self.cleaned(artworkPath)
        self.externalID = Self.cleaned(externalID)
        self.metadataProvider = Self.cleaned(metadataProvider)
    }

    public init(item: MediaItem, lyrics: String? = nil) {
        self.init(
            title: item.title,
            artist: item.artist,
            album: item.album,
            trackNumber: item.trackNumber,
            year: item.year,
            lyrics: lyrics,
            artworkPath: item.posterPath,
            externalID: item.externalID,
            metadataProvider: item.metadataProvider
        )
    }

    public var metadataUpdate: MediaMetadataUpdate {
        MediaMetadataUpdate(
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            year: year,
            posterPath: artworkPath,
            externalID: externalID,
            metadataProvider: metadataProvider ?? "MediaLIB MusicTag"
        )
    }

    public var writableMetadataPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        Self.append("title", title, to: &pairs)
        Self.append("artist", artist, to: &pairs)
        Self.append("album", album, to: &pairs)
        if let trackNumber, trackNumber > 0 {
            pairs.append(("track", "\(trackNumber)"))
            pairs.append(("tracknumber", "\(trackNumber)"))
        }
        if let year, year > 0 {
            pairs.append(("date", "\(year)"))
            pairs.append(("year", "\(year)"))
        }
        Self.append("lyrics", lyrics, to: &pairs)
        return pairs
    }

    public var hasWritableMetadata: Bool {
        !writableMetadataPairs.isEmpty
    }

    private static func append(_ key: String, _ value: String?, to pairs: inout [(String, String)]) {
        guard let value = cleaned(value), !value.isEmpty else { return }
        pairs.append((key, value))
    }

    private static func cleaned(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }
}

public struct MusicTagWriteReport: Sendable, Hashable {
    public var filePath: String
    public var updatedFieldCount: Int
    public var warning: String?

    public init(filePath: String, updatedFieldCount: Int, warning: String? = nil) {
        self.filePath = filePath
        self.updatedFieldCount = updatedFieldCount
        self.warning = warning
    }
}

public enum MusicTagEditingError: LocalizedError {
    case remoteResource
    case missingFile
    case unsupportedFormat(String)
    case fileNotWritable
    case ffmpegUnavailable
    case ffmpegFailed(String)
    case outputMissing

    public var errorDescription: String? {
        switch self {
        case .remoteResource:
            return "远程音乐不能直接写入文件标签。"
        case .missingFile:
            return "找不到本地音乐文件。"
        case .unsupportedFormat(let ext):
            return "暂不支持写入 .\(ext) 文件标签。"
        case .fileNotWritable:
            return "当前音乐文件或所在文件夹不可写。"
        case .ffmpegUnavailable:
            return "缺少音频标签写入组件，无法写入文件标签。"
        case .ffmpegFailed(let message):
            return message.isEmpty ? "音频标签写入失败。" : "音频标签写入失败：\(message)"
        case .outputMissing:
            return "写入结果未通过校验，原文件未被替换。"
        }
    }
}

public final class MusicTagEditingService {
    private let logger: LoggingService?
    private static let writableExtensions: Set<String> = [
        "aac", "aif", "aiff", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wv"
    ]
    private static let artworkWritableExtensions: Set<String> = [
        "flac", "m4a", "mp3", "ogg", "opus"
    ]

    public init(logger: LoggingService? = nil) {
        self.logger = logger
    }

    public func canWriteFileTags(for item: MediaItem) -> Bool {
        guard let url = localFileURL(for: item) else { return false }
        let ext = url.pathExtension.lowercased()
        return Self.writableExtensions.contains(ext)
    }

    public func write(_ draft: MusicTagDraft, to item: MediaItem) async throws -> MusicTagWriteReport {
        guard draft.hasWritableMetadata else {
            return MusicTagWriteReport(filePath: item.filePath ?? "", updatedFieldCount: 0, warning: "没有可写入的标签字段。")
        }
        guard let inputURL = localFileURL(for: item) else {
            throw item.isRemoteResource ? MusicTagEditingError.remoteResource : MusicTagEditingError.missingFile
        }
        let ext = inputURL.pathExtension.lowercased()
        guard Self.writableExtensions.contains(ext) else {
            throw MusicTagEditingError.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
        }
        guard let ffmpegURL = Self.ffmpegExecutableURL() else {
            throw MusicTagEditingError.ffmpegUnavailable
        }

        let task = Task.detached(priority: .utility) { [logger] in
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: inputURL.path) else {
                throw MusicTagEditingError.missingFile
            }
            let directoryURL = inputURL.deletingLastPathComponent()
            guard fileManager.isWritableFile(atPath: inputURL.path),
                  fileManager.isWritableFile(atPath: directoryURL.path) else {
                throw MusicTagEditingError.fileNotWritable
            }

            let originalAttributes = try? fileManager.attributesOfItem(atPath: inputURL.path)
            let token = UUID().uuidString
            let tempURL = directoryURL.appendingPathComponent(".\(inputURL.deletingPathExtension().lastPathComponent).medialib-tagging-\(token).\(ext)")
            try? fileManager.removeItem(at: tempURL)

            let artworkURL = Self.localArtworkURL(from: draft.artworkPath)
            let canEmbedArtwork = artworkURL != nil && Self.artworkWritableExtensions.contains(ext)
            var result = Self.runFFmpeg(
                ffmpegURL: ffmpegURL,
                arguments: Self.ffmpegArguments(
                    inputURL: inputURL,
                    artworkURL: canEmbedArtwork ? artworkURL : nil,
                    outputURL: tempURL,
                    draft: draft,
                    fileExtension: ext
                ),
                timeout: 90
            )
            var warning: String?
            if !result.succeeded, canEmbedArtwork {
                try? fileManager.removeItem(at: tempURL)
                result = Self.runFFmpeg(
                    ffmpegURL: ffmpegURL,
                    arguments: Self.ffmpegArguments(
                        inputURL: inputURL,
                        artworkURL: nil,
                        outputURL: tempURL,
                        draft: draft,
                        fileExtension: ext
                    ),
                    timeout: 90
                )
                warning = result.succeeded ? "封面写入失败，已只写入文字标签。" : nil
            }
            guard result.succeeded else {
                try? fileManager.removeItem(at: tempURL)
                logger?.log("音乐标签写入失败：\(inputURL.path) \(result.stderr)", level: .warning)
                throw MusicTagEditingError.ffmpegFailed(result.stderr)
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: tempURL.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0 else {
                try? fileManager.removeItem(at: tempURL)
                throw MusicTagEditingError.outputMissing
            }

            let backupName = ".\(inputURL.lastPathComponent).medialib-tag-backup-\(token)"
            let resultingURL = try fileManager.replaceItemAt(
                inputURL,
                withItemAt: tempURL,
                backupItemName: backupName,
                options: []
            )
            let backupURL = directoryURL.appendingPathComponent(backupName)
            try? fileManager.removeItem(at: backupURL)

            var restoreAttributes: [FileAttributeKey: Any] = [:]
            if let permissions = originalAttributes?[.posixPermissions] {
                restoreAttributes[.posixPermissions] = permissions
            }
            if let modificationDate = originalAttributes?[.modificationDate] {
                restoreAttributes[.modificationDate] = modificationDate
            }
            if !restoreAttributes.isEmpty {
                try? fileManager.setAttributes(restoreAttributes, ofItemAtPath: inputURL.path)
            }

            return MusicTagWriteReport(
                filePath: resultingURL?.path ?? inputURL.path,
                updatedFieldCount: draft.writableMetadataPairs.count + (canEmbedArtwork && warning == nil ? 1 : 0),
                warning: warning
            )
        }
        return try await task.value
    }

    private func localFileURL(for item: MediaItem) -> URL? {
        guard let filePath = item.filePath, !filePath.isEmpty, !item.isRemoteResource else {
            return nil
        }
        return URL(fileURLWithPath: filePath)
    }

    private static func localArtworkURL(from path: String?) -> URL? {
        guard let path, !path.isEmpty, !path.hasPrefix("http") else { return nil }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "webp"].contains(ext),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func ffmpegArguments(
        inputURL: URL,
        artworkURL: URL?,
        outputURL: URL,
        draft: MusicTagDraft,
        fileExtension: String
    ) -> [String] {
        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", inputURL.path
        ]
        if let artworkURL {
            arguments.append(contentsOf: [
                "-i", artworkURL.path,
                "-map", "0:a?",
                "-map", "0:s?",
                "-map", "1:v:0"
            ])
        } else {
            arguments.append(contentsOf: ["-map", "0"])
        }
        arguments.append(contentsOf: [
            "-c", "copy",
            "-map_metadata", "0"
        ])
        if let artworkURL {
            arguments.append(contentsOf: [
                "-disposition:v:0", "attached_pic",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)"
            ])
            if artworkURL.pathExtension.lowercased() == "webp" {
                arguments.append(contentsOf: ["-c:v", "mjpeg"])
            }
        }
        if fileExtension == "mp3" {
            arguments.append(contentsOf: ["-id3v2_version", "3", "-write_id3v1", "1"])
        }
        for (key, value) in draft.writableMetadataPairs {
            arguments.append(contentsOf: ["-metadata", "\(key)=\(value)"])
        }
        arguments.append(outputURL.path)
        return arguments
    }

    private static func ffmpegExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("ffmpeg"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/ffmpeg"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runFFmpeg(ffmpegURL: URL, arguments: [String], timeout: TimeInterval) -> (succeeded: Bool, stderr: String) {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return (false, "写入超时")
        }
        process.waitUntilExit()

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, stderr)
    }
}
