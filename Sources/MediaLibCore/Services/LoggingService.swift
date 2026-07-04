import Foundation

public final class LoggingService {
    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private let logFileURL: URL
    private let queue = DispatchQueue(label: "MediaLib.LoggingService")

    /// 单个日志文件的大小上限。超过后滚动为 `.1` 备份（仅保留一份历史），避免日志无限增长。
    private let maxFileBytes: Int
    /// 用户主目录前缀，用于把绝对路径脱敏为 `~/...`，避免导出日志时泄露目录结构 / 用户名。
    private let homeDirectoryPath: String

    public init(logDirectory: URL, maxFileBytes: Int = 5 * 1024 * 1024) {
        self.logFileURL = logDirectory.appendingPathComponent("medialib.log")
        self.maxFileBytes = max(maxFileBytes, 64 * 1024)
        self.homeDirectoryPath = NSHomeDirectory()
    }

    public func log(_ message: String, level: Level = .info) {
        let sanitized = Self.redact(message, homeDirectoryPath: homeDirectoryPath)
        let line = "[\(DateCoding.string(from: Date()) ?? "")] [\(level.rawValue)] \(sanitized)\n"
        queue.async { [logFileURL, maxFileBytes] in
            guard let data = line.data(using: .utf8) else { return }
            Self.rotateIfNeeded(at: logFileURL, incomingBytes: data.count, maxFileBytes: maxFileBytes)
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

    // MARK: - 路径脱敏

    /// 把消息中的用户主目录绝对路径替换成 `~`，对常见的本地路径泄露做集中防护。
    /// 仅替换前缀匹配，不改变其余内容；主目录为空时原样返回。
    static func redact(_ message: String, homeDirectoryPath: String) -> String {
        guard !homeDirectoryPath.isEmpty, homeDirectoryPath != "/" else { return message }
        return message.replacingOccurrences(of: homeDirectoryPath, with: "~")
    }

    // MARK: - 日志滚动

    /// 当现有日志加上即将写入的内容超过上限时，把当前日志滚动为 `medialib.log.1`
    /// （覆盖旧备份），随后从空文件继续。任何失败都静默忽略，绝不影响主流程。
    private static func rotateIfNeeded(at url: URL, incomingBytes: Int, maxFileBytes: Int) {
        // ★不能用 `url.resourceValues(forKeys: [.fileSizeKey])`：URL 会把资源值缓存在自身对象上，
        // 而这里每条日志都复用同一个 logFileURL，首次读到的大小会被缓存，之后即便文件已经涨大，
        // 读回来的仍是那个陈旧的小值——判断永远达不到上限，滚动从不触发，日志无限增长（撑爆磁盘）。
        // 改用 FileManager.attributesOfItem（不缓存），每次拿到的都是文件当前真实大小。
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        guard currentSize + incomingBytes > maxFileBytes, currentSize > 0 else { return }
        let backupURL = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: url, to: backupURL)
    }
}
