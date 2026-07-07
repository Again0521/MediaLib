import Foundation

/// 敏感凭据（第三方 API Key / Shared Secret / OAuth Token）的本地存储。
///
/// 设计动机：此前这些字段随整个 `AppSettings` 以**明文 JSON** 写入 `UserDefaults`
/// （落盘于 `~/Library/Preferences/<bundleid>.plist`），任何能读该用户目录的进程、
/// 备份或同步都会暴露。改为单独存放到 Application Support 下的 `0600` 文件，
/// 与既有 `RemoteCredentialStore` 的安全姿态保持一致（同样规避 ad-hoc 签名导致的
/// Keychain ACL 反复失效问题，不触碰 Keychain）。
///
/// 注意：本存储**不做加密**，仅靠文件权限 + 移出全局可读的 prefs 来收敛暴露面；
/// 这是相对「明文存 UserDefaults」的明确改进，后续如需更强保护可在此叠加对称加密。
public final class SecretStore {
    struct IO: @unchecked Sendable {
        let read: (URL) throws -> Data
        let write: (Data, URL) throws -> Void

        static let fileSystem = IO(
            read: { url in
                try Data(contentsOf: url)
            },
            write: { data, url in
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        )
    }

    private let fileURL: URL?
    private let io: IO

    /// - Parameter directory: 存储目录。默认 `Application Support/MediaLib/Credentials`；
    ///   测试可注入临时目录以隔离。
    public convenience init(directory: URL? = nil) {
        self.init(directory: directory, io: .fileSystem)
    }

    init(directory: URL? = nil, io: IO) {
        self.io = io
        let baseDirectory = directory ?? Self.defaultDirectory()
        if let baseDirectory {
            try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            self.fileURL = baseDirectory.appendingPathComponent("AppSecrets.json")
        } else {
            self.fileURL = nil
        }
    }

    /// 读取全部 secret 键值；文件不存在或解析失败返回空字典。
    public func load() -> [String: String] {
        Self.load(from: fileURL, io: io)
    }

    /// 异步读取全部 secret 键值，避免运行期设置保存/迁移占用 Swift 协作线程。
    public func loadAsync() async -> [String: String] {
        let fileURL = fileURL
        let io = io
        return await BlockingIOExecutor.run {
            Self.load(from: fileURL, io: io)
        }
    }

    /// 覆盖写入全部 secret 键值。空字典会清空文件内容（仍写入 `{}`，保持文件存在与权限）。
    /// 返回值用于审计和测试；调用方仍可忽略失败，避免影响设置主流程。
    @discardableResult
    public func save(_ secrets: [String: String]) -> Bool {
        guard let fileURL,
              let data = try? JSONEncoder().encode(secrets) else { return false }
        return Self.save(data, to: fileURL, io: io)
    }

    /// 异步覆盖写入全部 secret 键值。失败策略与同步 `save` 保持一致。
    @discardableResult
    public func saveAsync(_ secrets: [String: String]) async -> Bool {
        guard let fileURL,
              let data = try? JSONEncoder().encode(secrets) else { return false }
        let io = io
        return await BlockingIOExecutor.run {
            Self.save(data, to: fileURL, io: io)
        }
    }

    private static func defaultDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("MediaLib", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
    }

    private static func load(from fileURL: URL?, io: IO) -> [String: String] {
        guard let fileURL,
              let data = try? io.read(fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func save(_ data: Data, to fileURL: URL, io: IO) -> Bool {
        do {
            try io.write(data, fileURL)
            return true
        } catch {
            return false
        }
    }
}
