import Foundation
import MediaLibCore

struct CustomArtworkFileIO: @unchecked Sendable {
    var createDirectory: @Sendable (URL) throws -> Void
    var contentsOfDirectory: @Sendable (URL) throws -> [URL]
    var removeItem: @Sendable (URL) throws -> Void
    var copyItem: @Sendable (URL, URL) throws -> Void

    static let fileSystem = CustomArtworkFileIO(
        createDirectory: { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        },
        contentsOfDirectory: { directory in
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        },
        removeItem: { url in
            try FileManager.default.removeItem(at: url)
        },
        copyItem: { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    )
}

enum CustomArtworkFileImporter {
    static func importArtwork(
        itemID: String,
        sourceURL: URL,
        thumbnailsDirectory: URL,
        kind: VideoArtworkKind,
        timestamp: Int = Int(Date().timeIntervalSince1970),
        io: CustomArtworkFileIO = .fileSystem
    ) async throws -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension.lowercased()
        let suffix = suffix(for: kind)
        let filenameID = filenameComponent(itemID)
        let destURL = thumbnailsDirectory
            .appendingPathComponent("\(filenameID)-\(suffix)-\(timestamp).\(ext)")
        let prefix = "\(filenameID)-\(suffix)-"

        return try await BlockingIOExecutor.run {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try io.createDirectory(thumbnailsDirectory)
            if let existing = try? io.contentsOfDirectory(thumbnailsDirectory) {
                for old in existing where old.lastPathComponent.hasPrefix(prefix) {
                    try? io.removeItem(old)
                }
            }
            try io.copyItem(sourceURL, destURL)
            return destURL
        }
    }

    private static func suffix(for kind: VideoArtworkKind) -> String {
        switch kind {
        case .poster:
            return "custom-poster"
        case .backdrop:
            return "custom-backdrop"
        }
    }

    private static func filenameComponent(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filename = text.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        return filename.isEmpty ? UUID().uuidString : filename
    }
}
