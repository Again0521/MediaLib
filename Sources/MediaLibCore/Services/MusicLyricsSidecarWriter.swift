import Foundation

public enum MusicLyricsSidecarWriter {
    public static func write(_ lyrics: String, to outputURL: URL) async throws {
        try await BlockingIOExecutor.run {
            try lyrics.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }
}
