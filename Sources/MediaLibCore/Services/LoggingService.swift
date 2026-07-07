import Foundation

public final class LoggingService {
    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public struct WriteFailure: Equatable {
        public let operation: String
        public let path: String
        public let message: String
    }

    private let logFileURL: URL
    private let queue = DispatchQueue(label: "MediaLib.LoggingService")

    /// 单个日志文件的大小上限。超过后滚动为 `.1` 备份（仅保留一份历史），避免日志无限增长。
    private let maxFileBytes: Int
    /// 用户主目录前缀，用于把绝对路径脱敏为 `~/...`，避免导出日志时泄露目录结构 / 用户名。
    private let homeDirectoryPath: String
    private var lastWriteFailure: WriteFailure?

    public init(logDirectory: URL, maxFileBytes: Int = 5 * 1024 * 1024) {
        self.logFileURL = logDirectory.appendingPathComponent("medialib.log")
        self.maxFileBytes = max(maxFileBytes, 64 * 1024)
        self.homeDirectoryPath = NSHomeDirectory()
    }

    public func log(_ message: String, level: Level = .info) {
        let sanitized = Self.redact(message, homeDirectoryPath: homeDirectoryPath)
        let line = "[\(DateCoding.string(from: Date()) ?? "")] [\(level.rawValue)] \(sanitized)\n"
        queue.async { [self, logFileURL, maxFileBytes] in
            guard let data = line.data(using: .utf8) else { return }
            self.lastWriteFailure = Self.writeLine(data, to: logFileURL, maxFileBytes: maxFileBytes)
        }
    }

    public func exportURL() -> URL {
        logFileURL
    }

    public func lastFailure() -> WriteFailure? {
        queue.sync { lastWriteFailure }
    }

    func flush() {
        queue.sync {}
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
    private static func writeLine(_ data: Data, to url: URL, maxFileBytes: Int) -> WriteFailure? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return WriteFailure(operation: "createDirectory", path: url.deletingLastPathComponent().path, message: error.localizedDescription)
        }

        if let failure = rotateIfNeeded(at: url, incomingBytes: data.count, maxFileBytes: maxFileBytes) {
            return failure
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return append(data, to: url)
        }

        do {
            try data.write(to: url)
            return nil
        } catch {
            return WriteFailure(operation: "createFile", path: url.path, message: error.localizedDescription)
        }
    }

    private static func append(_ data: Data, to url: URL) -> WriteFailure? {
        do {
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
                return nil
            } catch {
                do {
                    try handle.close()
                } catch {}
                return WriteFailure(operation: "appendFile", path: url.path, message: error.localizedDescription)
            }
        } catch {
            return WriteFailure(operation: "openFile", path: url.path, message: error.localizedDescription)
        }
    }

    private static func rotateIfNeeded(at url: URL, incomingBytes: Int, maxFileBytes: Int) -> WriteFailure? {
        // ★不能用 `url.resourceValues(forKeys: [.fileSizeKey])`：URL 会把资源值缓存在自身对象上，
        // 而这里每条日志都复用同一个 logFileURL，首次读到的大小会被缓存，之后即便文件已经涨大，
        // 读回来的仍是那个陈旧的小值——判断永远达不到上限，滚动从不触发，日志无限增长（撑爆磁盘）。
        // 改用 FileManager.attributesOfItem（不缓存），每次拿到的都是文件当前真实大小。
        let currentSize: Int
        do {
            currentSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                return WriteFailure(operation: "readFileSize", path: url.path, message: error.localizedDescription)
            }
            currentSize = 0
        }
        guard currentSize + incomingBytes > maxFileBytes, currentSize > 0 else { return nil }
        let backupURL = url.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                try FileManager.default.removeItem(at: backupURL)
            } catch {
                return WriteFailure(operation: "removeBackup", path: backupURL.path, message: error.localizedDescription)
            }
        }

        do {
            try FileManager.default.moveItem(at: url, to: backupURL)
            return nil
        } catch {
            return WriteFailure(operation: "rotateFile", path: url.path, message: error.localizedDescription)
        }
    }
}
