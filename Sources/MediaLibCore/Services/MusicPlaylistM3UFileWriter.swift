import Foundation

public enum MusicPlaylistM3UFileWriter {
    public static func writeContent(_ content: String, to url: URL) async throws {
        try await BlockingIOExecutor.run {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
