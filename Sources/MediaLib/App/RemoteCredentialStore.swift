import Foundation
import MediaLibCore

struct RemoteSourceCredential: Codable {
    var kind: String
    var serverURL: String
    var username: String?
    var password: String?
    var accessToken: String?
    var userID: String?
}

/// 凭据改为存放在 Application Support 下的文件，而非 keychain。
/// 原因：本应用为 ad-hoc 签名，每次更新签名都会变化，keychain 项的 ACL 因此失效，
/// 导致每次更新后首次读取（启动时加载 Emby/NAS 凭据）都会弹出系统钥匙串密码框。
/// 文件读取不会触发该提示；现在也不再删除旧 keychain 项，确保启动和更新路径完全不触碰 Keychain。
final class RemoteCredentialStore {
    struct IO: @unchecked Sendable {
        let fileURL: (String, URL?) -> URL?
        let write: (Data, URL) throws -> Void
        let read: (URL) throws -> Data
        let remove: (URL) throws -> Void

        static let fileSystem = IO(
            fileURL: { sourceID, directoryOverride in
                RemoteCredentialStore.fileURL(for: sourceID, directoryOverride: directoryOverride)
            },
            write: { data, url in
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            },
            read: { url in
                try Data(contentsOf: url)
            },
            remove: { url in
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    private let directoryOverride: URL?
    private let io: IO

    init(directory: URL? = nil, io: IO = .fileSystem) {
        self.directoryOverride = directory
        self.io = io
    }

    func save(_ credential: RemoteSourceCredential, sourceID: String) throws {
        try Self.save(credential, sourceID: sourceID, directoryOverride: directoryOverride, io: io)
    }

    func saveAsync(_ credential: RemoteSourceCredential, sourceID: String) async throws {
        let directoryOverride = directoryOverride
        let io = io
        try await BlockingIOExecutor.run {
            try Self.save(credential, sourceID: sourceID, directoryOverride: directoryOverride, io: io)
        }
    }

    func load(sourceID: String) throws -> RemoteSourceCredential? {
        try Self.load(sourceID: sourceID, directoryOverride: directoryOverride, io: io)
    }

    func loadAsync(sourceID: String) async throws -> RemoteSourceCredential? {
        let directoryOverride = directoryOverride
        let io = io
        return try await BlockingIOExecutor.run {
            try Self.load(sourceID: sourceID, directoryOverride: directoryOverride, io: io)
        }
    }

    func delete(sourceID: String) {
        Self.delete(sourceID: sourceID, directoryOverride: directoryOverride, io: io)
    }

    func deleteAsync(sourceID: String) async {
        let directoryOverride = directoryOverride
        let io = io
        await BlockingIOExecutor.run {
            Self.delete(sourceID: sourceID, directoryOverride: directoryOverride, io: io)
        }
    }

    // MARK: - 文件存储

    private static func save(
        _ credential: RemoteSourceCredential,
        sourceID: String,
        directoryOverride: URL?,
        io: IO
    ) throws {
        let data = try JSONEncoder().encode(credential)
        guard let url = io.fileURL(sourceID, directoryOverride) else {
            throw NSError(domain: "MediaLib.RemoteCredentialStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法定位凭据存储目录"])
        }
        try io.write(data, url)
    }

    private static func load(sourceID: String, directoryOverride: URL?, io: IO) throws -> RemoteSourceCredential? {
        // 只读文件，绝不读 keychain。读取旧 keychain（SecItemCopyMatching 取数据）会因 ad-hoc 签名
        // 每次更新变化而弹出系统钥匙串密码框——这正是"更新后首次打开要输密码"的根因，故彻底不再读取。
        // 旧用户更新后需在设置里重新登录一次 Emby/NAS（一次性，且不会弹任何系统密码框）。
        if let url = io.fileURL(sourceID, directoryOverride),
           let data = try? io.read(url),
           let credential = try? JSONDecoder().decode(RemoteSourceCredential.self, from: data) {
            return credential
        }
        return nil
    }

    private static func delete(sourceID: String, directoryOverride: URL?, io: IO) {
        if let url = io.fileURL(sourceID, directoryOverride) {
            try? io.remove(url)
        }
    }

    private static func directory(directoryOverride: URL?) -> URL? {
        if let directoryOverride {
            try? FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            return directoryOverride
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base
            .appendingPathComponent("MediaLib", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
            .appendingPathComponent("RemoteSources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for sourceID: String, directoryOverride: URL?) -> URL? {
        let safe = sourceID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let name = String(safe)
        return directory(directoryOverride: directoryOverride)?.appendingPathComponent("\(name).json")
    }

}
