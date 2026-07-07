import Foundation

public enum MusicPlaylistM3UFileLoaderError: Error, Equatable {
    case unsupportedEncoding
}

public enum MusicPlaylistM3UFileLoader {
    public static func loadContent(from url: URL) async throws -> String {
        let data = try await BlockingIOExecutor.run {
            try Data(contentsOf: url)
        }
        return try decodedContent(from: data)
    }

    public static func loadContentSynchronously(from url: URL) throws -> String {
        try decodedContent(from: try Data(contentsOf: url))
    }

    private static func decodedContent(from data: Data) throws -> String {
        guard let content = MusicPlaylistM3UPolicy.decodedText(from: data) else {
            throw MusicPlaylistM3UFileLoaderError.unsupportedEncoding
        }
        return content
    }
}
