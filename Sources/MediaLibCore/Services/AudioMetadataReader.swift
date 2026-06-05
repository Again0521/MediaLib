import AVFoundation
import Foundation

public struct AudioMetadata: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var duration: Double?
    public var artworkPath: String?
    public var lyrics: String?
    public var loudnessTrackGainDB: Double?
    public var loudnessAlbumGainDB: Double?
    public var loudnessTrackPeak: Double?
    public var loudnessAlbumPeak: Double?
    public var hasEmbeddedMetadata: Bool
}

public final class AudioMetadataReader {
    public init() {}

    public func metadata(for url: URL, artworkDirectory: URL? = nil, mediaID: String? = nil) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let formatMetadata = await metadataByFormat(for: asset)
        let allMetadata = commonMetadata + formatMetadata
        let duration = try? await asset.load(.duration)
        let artworkPath = await embeddedArtworkPath(
            in: allMetadata,
            artworkDirectory: artworkDirectory,
            mediaID: mediaID
        )
        let title = await stringValue(
            identifiers: [
                .commonIdentifierTitle,
                .iTunesMetadataSongName,
                .id3MetadataTitleDescription,
                .quickTimeMetadataTitle
            ],
            keySubstrings: ["title", "song", "©nam"],
            in: allMetadata
        )
        let artist = await stringValue(
            identifiers: [
                .commonIdentifierArtist,
                .iTunesMetadataArtist,
                .iTunesMetadataAlbumArtist,
                .id3MetadataLeadPerformer,
                .id3MetadataBand,
                .quickTimeMetadataArtist
            ],
            keySubstrings: ["artist", "albumartist", "album artist", "performer", "author", "©art", "aart"],
            in: allMetadata
        )
        let album = await stringValue(
            identifiers: [
                .commonIdentifierAlbumName,
                .iTunesMetadataAlbum,
                .id3MetadataAlbumTitle,
                .quickTimeMetadataAlbum
            ],
            keySubstrings: ["album", "©alb"],
            in: allMetadata
        )
        let lyrics = await stringValue(
            identifiers: [],
            keySubstrings: ["lyrics", "lyric", "unsynchronized", "synchronized"],
            in: allMetadata
        )
        let trackNumber = await trackNumber(in: allMetadata)
        let year = await year(in: allMetadata)
        let loudnessTrackGainDB = await loudnessValue(
            keys: ["replaygain_track_gain", "replaygain track gain", "r128_track_gain", "r128 track gain"],
            in: allMetadata
        )
        let loudnessAlbumGainDB = await loudnessValue(
            keys: ["replaygain_album_gain", "replaygain album gain", "r128_album_gain", "r128 album gain"],
            in: allMetadata
        )
        let loudnessTrackPeak = await numericValue(
            keys: ["replaygain_track_peak", "replaygain track peak"],
            in: allMetadata
        )
        let loudnessAlbumPeak = await numericValue(
            keys: ["replaygain_album_peak", "replaygain album peak"],
            in: allMetadata
        )

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            year: year,
            duration: duration.map { CMTimeGetSeconds($0) }.flatMap { $0.isFinite ? $0 : nil },
            artworkPath: artworkPath,
            lyrics: lyrics,
            loudnessTrackGainDB: loudnessTrackGainDB,
            loudnessAlbumGainDB: loudnessAlbumGainDB,
            loudnessTrackPeak: loudnessTrackPeak,
            loudnessAlbumPeak: loudnessAlbumPeak,
            hasEmbeddedMetadata: [title, artist, album, artworkPath, lyrics].contains { $0?.isEmpty == false } ||
                trackNumber != nil ||
                year != nil ||
                loudnessTrackGainDB != nil ||
                loudnessAlbumGainDB != nil
        )
    }

    private func metadataByFormat(for asset: AVURLAsset) async -> [AVMetadataItem] {
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        var items: [AVMetadataItem] = []
        for format in formats {
            if let metadata = try? await asset.loadMetadata(for: format) {
                items.append(contentsOf: metadata)
            }
        }
        return items
    }

    private func stringValue(identifiers: [AVMetadataIdentifier], keySubstrings: [String], in metadata: [AVMetadataItem]) async -> String? {
        for identifier in identifiers {
            if let item = metadata.first(where: { $0.identifier == identifier }),
               let value = await cleanStringValue(for: item) {
                return value
            }
        }

        let loweredSubstrings = keySubstrings.map { $0.lowercased() }
        for item in metadata {
            let key = metadataKeyDescription(for: item)
            guard loweredSubstrings.contains(where: { key.contains($0) }) else { continue }
            if let value = await cleanStringValue(for: item) {
                return value
            }
        }
        return nil
    }

    private func cleanStringValue(for item: AVMetadataItem) async -> String? {
        if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        return nil
    }

    private func metadataKeyDescription(for item: AVMetadataItem) -> String {
        [
            item.identifier?.rawValue,
            item.commonKey?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { "\($0)" }
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private func trackNumber(in metadata: [AVMetadataItem]) async -> Int? {
        let candidates = metadata.filter {
            $0.commonKey?.rawValue.lowercased() == "tracknumber" ||
            $0.key?.description.lowercased().contains("track") == true
        }
        for item in candidates {
            if let number = try? await item.load(.numberValue)?.intValue {
                return number
            }
            if let text = try? await item.load(.stringValue) {
                let first = text.split(separator: "/").first.map(String.init) ?? text
                if let number = Int(first.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) {
                    return number
                }
            }
        }
        return nil
    }

    private func year(in metadata: [AVMetadataItem]) async -> Int? {
        let candidates = metadata.filter {
            $0.identifier == .commonIdentifierCreationDate ||
            $0.commonKey?.rawValue.lowercased() == "creationdate" ||
            $0.key?.description.lowercased().contains("year") == true ||
            $0.key?.description.lowercased().contains("date") == true
        }
        for item in candidates {
            if let number = try? await item.load(.numberValue)?.intValue, number > 0 {
                return number
            }
            if let text = try? await item.load(.stringValue), text.count >= 4, let year = Int(text.prefix(4)) {
                return year
            }
        }
        return nil
    }

    private func loudnessValue(keys: [String], in metadata: [AVMetadataItem]) async -> Double? {
        guard let match = await numericMetadataMatch(keys: keys, in: metadata) else { return nil }
        if match.key.contains("r128"), abs(match.value) > 24 {
            return match.value / 256
        }
        return match.value
    }

    private func numericValue(keys: [String], in metadata: [AVMetadataItem]) async -> Double? {
        await numericMetadataMatch(keys: keys, in: metadata)?.value
    }

    private func numericMetadataMatch(keys: [String], in metadata: [AVMetadataItem]) async -> (key: String, value: Double)? {
        let loweredKeys = keys.map { $0.lowercased() }
        for item in metadata {
            let key = metadataKeyDescription(for: item)
            guard loweredKeys.contains(where: { key.contains($0) }) else { continue }
            if let number = try? await item.load(.numberValue)?.doubleValue, number.isFinite {
                return (key, number)
            }
            guard let text = try? await item.load(.stringValue) else { continue }
            let scanner = Scanner(string: text.replacingOccurrences(of: ",", with: "."))
            scanner.charactersToBeSkipped = CharacterSet(charactersIn: " \t")
            if let number = scanner.scanDouble(), number.isFinite {
                return (key, number)
            }
        }
        return nil
    }

    private func embeddedArtworkPath(in metadata: [AVMetadataItem], artworkDirectory: URL?, mediaID: String?) async -> String? {
        guard let artworkDirectory, let mediaID else { return nil }

        // 若封面文件已存在（任意支持格式），跳过重新提取和写盘
        let existingPath = ["jpg", "png", "webp"].lazy.compactMap { ext -> String? in
            let candidate = artworkDirectory.appendingPathComponent("\(mediaID)-embedded-artwork.\(ext)")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
        }.first
        if let existing = existingPath { return existing }

        let artworkItem = metadata.first {
            $0.identifier == .commonIdentifierArtwork ||
            $0.identifier == .iTunesMetadataCoverArt ||
            $0.identifier == .id3MetadataAttachedPicture ||
            $0.identifier == .quickTimeMetadataArtwork ||
            $0.commonKey?.rawValue.lowercased() == "artwork" ||
            $0.key?.description.lowercased().contains("artwork") == true ||
            $0.key?.description.lowercased().contains("cover") == true
        }
        guard let item = artworkItem,
              let data = await artworkData(from: item),
              !data.isEmpty else { return nil }

        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
                let ext = Self.imageExtension(for: data)
                let outputURL = artworkDirectory.appendingPathComponent("\(mediaID)-embedded-artwork.\(ext)")
                try data.write(to: outputURL, options: .atomic)
                return outputURL.path
            } catch {
                return nil
            }
        }.value
    }

    private func artworkData(from item: AVMetadataItem) async -> Data? {
        if let data = try? await item.load(.dataValue), !data.isEmpty {
            return data
        }
        if let data = try? await item.load(.value) as? Data, !data.isEmpty {
            return data
        }
        if let dictionary = try? await item.load(.value) as? [String: Any],
           let data = dictionary["data"] as? Data,
           !data.isEmpty {
            return data
        }
        if let string = try? await item.load(.stringValue),
           let data = Data(base64Encoded: string),
           !data.isEmpty {
            return data
        }
        return nil
    }

    private static func imageExtension(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) {
            return "webp"
        }
        return "jpg"
    }
}
