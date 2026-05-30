import Foundation

public final class LoggingService {
    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private let logFileURL: URL
    private let queue = DispatchQueue(label: "MediaLib.LoggingService")

    public init(logDirectory: URL) {
        self.logFileURL = logDirectory.appendingPathComponent("medialib.log")
    }

    public func log(_ message: String, level: Level = .info) {
        let line = "[\(DateCoding.string(from: Date()) ?? "")] [\(level.rawValue)] \(message)\n"
        queue.async { [logFileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    public func exportURL() -> URL {
        logFileURL
    }
}
