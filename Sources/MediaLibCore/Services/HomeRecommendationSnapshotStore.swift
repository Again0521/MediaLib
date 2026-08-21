import Foundation

/// 网页首页那几条**推荐**栏目到底由谁来算——桌面 App 与服务进程之间的第二条消息
/// （第一条是 `VaultUnlockSessionStore`）。
///
/// 首页的「剧集推荐」「音乐推荐」「最近添加剧集」「高分精选」和 banner 轮播，在客户端
/// 是一整套打过分、按题材相似度与每日稳定随机值排过序的结果（`HomeOverviewSnapshotBuilder`
/// 那一族）。服务进程从前对同一批内容**又推导了一遍**，用的却是另一套更简单的规则：
/// 数据库按 `dateAdded` / `score` 各取一页，剧集就是"所有 isSeries 的条目"。于是同一个
/// 资料库，同一个人，在 App 和网页上看到的"推荐"是两份不一样的片单——而且那份重算
/// 还要多跑两次全库排序查询。
///
/// 这里传的是**只有条目 ID 的排好的名单**，刻意不传标题、路径、封面或任何元数据：
///
/// * 服务端拿到 ID 之后仍然要走它自己那套授权（逐用户资料库授权、保险库排除、
///   `privateCollection` 类型排除）再把条目查出来。客户端算的是**顺序**，
///   不是**可见性**——机主能看到的东西不会因为出现在这份名单里就漏给网页用户。
/// * 名单里没有痕迹。谁看到哪一集、哪一首收藏了，网页那一侧永远读它自己的
///   `server_user_media_state` / `server_user_media_preferences`（逐用户），
///   与这份文件无关。
/// * 文件与数据库同在 0700 的应用支持目录下，权限 0600，并且**有效期是硬的**：
///   App 关掉之后这份名单最多再服务一天，过期后服务端回落到自己的推导，网页不会
///   卡在一份陈旧的片单上。
public enum HomeRecommendationSection: String, Codable, Sendable, CaseIterable {
    /// 首页顶部 banner 轮播（客户端的 `daily-banner`）。
    case banner
    /// 「剧集推荐」。
    case seriesRecommendation
    /// 「最近添加 · 剧集」。
    case recentSeries
    /// 「高分精选」。
    case highRated
    /// 「音乐推荐」。
    case musicRecommendation
    /// 首页照片墙的当日主题选片。
    case photoWall
}

public struct HomeRecommendationSnapshot: Codable, Equatable, Sendable {
    /// 一条栏目名单。
    ///
    /// `sectionID` 存字符串而不是枚举：老版本 App 与新版本服务端（或者反过来）共存时，
    /// 一个不认识的栏目名只该让**那一条**被忽略，而不是让整份文件解码失败、连带把
    /// 认识的那几条也丢掉。
    public struct Entry: Codable, Equatable, Sendable {
        public let sectionID: String
        public let itemIDs: [String]

        public var section: HomeRecommendationSection? {
            HomeRecommendationSection(rawValue: sectionID)
        }

        public init(section: HomeRecommendationSection, itemIDs: [String]) {
            self.sectionID = section.rawValue
            self.itemIDs = itemIDs
        }

        public init(sectionID: String, itemIDs: [String]) {
            self.sectionID = sectionID
            self.itemIDs = itemIDs
        }

        private enum CodingKeys: String, CodingKey {
            case sectionID = "section"
            case itemIDs
        }
    }

    public let generatedAt: Date
    public let expiresAt: Date
    public let entries: [Entry]

    public init(generatedAt: Date, expiresAt: Date, entries: [Entry]) {
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.entries = entries
    }

    public func isValid(at moment: Date) -> Bool {
        expiresAt > moment && generatedAt <= expiresAt
    }

    /// 某一栏的名单，顺序与客户端首页上的顺序一致。未发布的栏目是空数组。
    public func itemIDs(for section: HomeRecommendationSection) -> [String] {
        entries.first { $0.section == section }?.itemIDs ?? []
    }

    public var isEmpty: Bool {
        entries.allSatisfy { $0.itemIDs.isEmpty }
    }
}

public struct HomeRecommendationSnapshotStore: Sendable {
    /// 名单的有效期。客户端首页每次重算看板都会续写一次，所以 App 开着时它永远新鲜；
    /// App 关掉之后最多再服务这么久，然后服务端回落到自己的推导。
    public static let lifetime: TimeInterval = 24 * 60 * 60
    public static let fileName = "home-recommendations.json"

    /// 三道尺寸闸门。这份文件与数据库同在 0700 目录下，但"同一台机器上的文件"不是
    /// "可以无条件相信的输入"：读进来的东西会变成 SQL 绑定参数和页面上的卡片，
    /// 所以条数、单条长度和文件本身都要有上界。
    public static let maximumSectionCount = 8
    public static let maximumItemsPerSection = 24
    public static let maximumIdentifierLength = 128
    public static let maximumFileByteCount = 64 * 1024

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

    /// 发布一份新的名单。写失败只影响网页首页的取材，绝不能让客户端首页出错。
    @discardableResult
    public func publish(
        entries: [HomeRecommendationSnapshot.Entry],
        now: Date = Date(),
        lifetime: TimeInterval = HomeRecommendationSnapshotStore.lifetime
    ) -> Bool {
        let snapshot = HomeRecommendationSnapshot(
            generatedAt: now,
            expiresAt: now.addingTimeInterval(max(lifetime, 0)),
            entries: Self.sanitized(entries)
        )
        guard let data = try? JSONEncoder.homeRecommendations.encode(snapshot),
              data.count <= Self.maximumFileByteCount
        else { return false }
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

    /// 当前有效的名单；文件缺失、损坏、超尺寸或已过期一律是 nil——**读不到就自己算**。
    public func current(now: Date = Date()) -> HomeRecommendationSnapshot? {
        guard let data = try? io.read(fileURL),
              data.count <= Self.maximumFileByteCount,
              let snapshot = try? JSONDecoder.homeRecommendations.decode(
                  HomeRecommendationSnapshot.self, from: data
              ),
              snapshot.isValid(at: now)
        else { return nil }
        // 写入侧已经裁剪过一次，读取侧再裁剪一次：这两侧可以是不同版本的进程。
        let entries = Self.sanitized(snapshot.entries)
        guard !entries.isEmpty else { return nil }
        return HomeRecommendationSnapshot(
            generatedAt: snapshot.generatedAt,
            expiresAt: snapshot.expiresAt,
            entries: entries
        )
    }

    /// 去重、裁剪、丢弃空条目与不认识的栏目。同一个栏目只保留第一次出现的那条。
    static func sanitized(_ entries: [HomeRecommendationSnapshot.Entry]) -> [HomeRecommendationSnapshot.Entry] {
        var seenSections = Set<String>()
        var result: [HomeRecommendationSnapshot.Entry] = []
        for entry in entries {
            guard entry.section != nil, seenSections.insert(entry.sectionID).inserted else { continue }
            var seenIDs = Set<String>()
            let itemIDs = entry.itemIDs
                .filter { identifier in
                    !identifier.isEmpty
                        && identifier.count <= maximumIdentifierLength
                        && seenIDs.insert(identifier).inserted
                }
                .prefix(maximumItemsPerSection)
            guard !itemIDs.isEmpty else { continue }
            result.append(.init(sectionID: entry.sectionID, itemIDs: Array(itemIDs)))
            if result.count == maximumSectionCount { break }
        }
        return result
    }
}

private extension JSONEncoder {
    static let homeRecommendations: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let homeRecommendations: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
