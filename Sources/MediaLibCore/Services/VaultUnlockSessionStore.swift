import Foundation

/// 保险库当前是否在这台机器上被解锁——桌面 App 与服务进程之间唯一的那条消息。
///
/// 解锁状态原本只活在 App 的内存里（`PrivacyLockStateStore.isUnlocked`），而网页由
/// **另一个进程**（`MediaLibServer --serve`）提供。两者共用同一个数据库和同一个
/// 应用支持目录，但没有任何一条通路让服务端知道"用户刚刚用 Touch ID 解开了保险库"。
/// 于是网页上的保险库永远画着那张锁屏，不管 App 里是什么状态。
///
/// 这里补上的就是那条通路，而且刻意只传递**一个事实**：
///
/// * 文件里没有口令、没有密钥、没有任何条目信息——只有两个时间戳。保险库的口令
///   由 `PrivacyLockService` 保管，一个字节都不会离开 App。
/// * 文件与数据库同在 0700 的应用支持目录下，权限 0600。这不是新增的信任面：
///   保险库是一道**访问控制**，不是静态加密，它的元数据本来就明文存在同一个目录
///   的数据库里。
/// * 有效期是硬的。App 崩溃或断电时没有人来删这个文件，所以它自己会过期；App
///   在解锁期间按 `refreshInterval` 续期。上锁、移除口令、退出都会立刻删除它。
///
/// 服务端**只**把它当作"是否解锁"这一个条件，另一个条件是逐用户的资料库授权。
/// 两个条件都满足才谈得上让保险库内容出现在网页上。
public struct VaultUnlockSession: Codable, Equatable, Sendable {
    public let unlockedAt: Date
    public let expiresAt: Date

    public init(unlockedAt: Date, expiresAt: Date) {
        self.unlockedAt = unlockedAt
        self.expiresAt = expiresAt
    }

    public func isValid(at moment: Date) -> Bool {
        expiresAt > moment && unlockedAt <= expiresAt
    }
}

public struct VaultUnlockSessionStore: Sendable {
    /// 会话有效期。App 每 `refreshInterval` 续一次，所以正常使用中它永远不会到期；
    /// 而 App 意外退出时，网页侧最多在这段时间之后自己回到锁定。
    public static let lifetime: TimeInterval = 30 * 60
    /// 续期间隔取有效期的三分之一：漏掉一次续期（睡眠、临时卡顿）也不会误锁。
    public static let refreshInterval: TimeInterval = 10 * 60
    public static let fileName = "vault-unlock.json"

    public struct IO: Sendable {
        public let write: @Sendable (Data, URL) throws -> Void
        public let read: @Sendable (URL) throws -> Data
        public let remove: @Sendable (URL) throws -> Void

        public init(
            write: @escaping @Sendable (Data, URL) throws -> Void,
            read: @escaping @Sendable (URL) throws -> Data,
            remove: @escaping @Sendable (URL) throws -> Void
        ) {
            self.write = write
            self.read = read
            self.remove = remove
        }

        public static let fileSystem = IO(
            write: { data, url in
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path
                )
            },
            read: { url in try Data(contentsOf: url) },
            remove: { url in try FileManager.default.removeItem(at: url) }
        )
    }

    private let directory: URL
    private let io: IO

    /// - Parameter directory: 应用支持目录根（App 与服务进程解析到同一个）。
    public init(directory: URL, io: IO = .fileSystem) {
        self.directory = directory
        self.io = io
    }

    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// 发布/续期一次解锁会话。写失败只影响网页侧的可见性，绝不能让 App 的解锁失败。
    @discardableResult
    public func publish(now: Date = Date(), lifetime: TimeInterval = VaultUnlockSessionStore.lifetime) -> Bool {
        let session = VaultUnlockSession(unlockedAt: now, expiresAt: now.addingTimeInterval(max(lifetime, 0)))
        guard let data = try? JSONEncoder.vaultUnlock.encode(session) else { return false }
        do {
            try io.write(data, fileURL)
            return true
        } catch {
            return false
        }
    }

    public func clear() {
        try? io.remove(fileURL)
    }

    /// 当前有效的解锁会话；文件缺失、损坏或已过期一律是 nil——**失败即锁定**。
    public func current(now: Date = Date()) -> VaultUnlockSession? {
        guard let data = try? io.read(fileURL),
              data.count <= 4_096,
              let session = try? JSONDecoder.vaultUnlock.decode(VaultUnlockSession.self, from: data),
              session.isValid(at: now)
        else { return nil }
        return session
    }

    public func isUnlocked(now: Date = Date()) -> Bool {
        current(now: now) != nil
    }
}

private extension JSONEncoder {
    static let vaultUnlock: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let vaultUnlock: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
