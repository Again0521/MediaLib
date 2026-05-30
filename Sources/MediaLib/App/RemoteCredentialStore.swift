import Foundation

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
    func save(_ credential: RemoteSourceCredential, sourceID: String) throws {
        let data = try JSONEncoder().encode(credential)
        guard let url = fileURL(for: sourceID) else {
            throw NSError(domain: "MediaLib.RemoteCredentialStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法定位凭据存储目录"])
        }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(sourceID: String) throws -> RemoteSourceCredential? {
        // 只读文件，绝不读 keychain。读取旧 keychain（SecItemCopyMatching 取数据）会因 ad-hoc 签名
        // 每次更新变化而弹出系统钥匙串密码框——这正是"更新后首次打开要输密码"的根因，故彻底不再读取。
        // 旧用户更新后需在设置里重新登录一次 Emby/NAS（一次性，且不会弹任何系统密码框）。
        if let url = fileURL(for: sourceID),
           let data = try? Data(contentsOf: url),
           let credential = try? JSONDecoder().decode(RemoteSourceCredential.self, from: data) {
            return credential
        }
        return nil
    }

    func delete(sourceID: String) {
        if let url = fileURL(for: sourceID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 文件存储

    private func directory() -> URL? {
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

    private func fileURL(for sourceID: String) -> URL? {
        let safe = sourceID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let name = String(safe)
        return directory()?.appendingPathComponent("\(name).json")
    }

}
