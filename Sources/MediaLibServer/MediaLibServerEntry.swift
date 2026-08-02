import Foundation
import MediaLibCore
import MediaLibServerProtocol

@main
struct MediaLibServer {
    static func main() throws {
        let configuration = try ServerLaunchConfiguration.load()
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--health":
            try ServerCommandOutput.write(
                ServerHealth(
                    serverID: configuration.serverID,
                    serverName: configuration.serverName
                )
            )
        case "--describe":
            try ServerCommandOutput.write(
                MlinkServerDescriptor(
                    serverID: configuration.serverID,
                    serverName: configuration.serverName,
                    capabilities: ServerCommandOutput.capabilities
                )
            )
        case "--serve":
            let defaultDirectories = try FileAccessService.appDirectories()
            let dataDirectories = try ServerDataDirectories.fromEnvironment() ?? ServerDataDirectories(
                root: defaultDirectories.applicationSupport,
                database: defaultDirectories.database,
                databaseBackups: defaultDirectories.databaseBackups
            )
            let database = try DatabaseManager(
                url: dataDirectories.database,
                backupDirectory: dataDirectories.databaseBackups
            )
            let catalog = ServerLibraryCatalog(database: database)
            let administrationCatalog = ServerAdministrationCatalog(database: database)
            let authentication = try ServerAuthenticationService(database: database)
            let inspector = FFprobeMediaInspector()
            let server = try LocalLoopbackHTTPServer(
                configuration: configuration,
                librarySnapshotProvider: { try catalog.snapshot(for: $0) },
                libraryBrowseProvider: { try catalog.browse($0, for: $1) },
                libraryCategoriesProvider: { try catalog.categories(for: $0) },
                mediaDetailProvider: { try catalog.publicDetail(id: $0, for: $1) },
                seriesDetailProvider: { try catalog.seriesDetail(id: $0, for: $1) },
                seriesEpisodesProvider: { try catalog.seriesEpisodes(id: $0, season: $1, offset: $2, limit: $3, for: $4) },
                peopleProvider: { try catalog.people(searchText: $0, offset: $1, limit: $2, for: $3) },
                personDetailProvider: { try catalog.personDetail(id: $0, offset: $1, limit: $2, for: $3) },
                collectionsProvider: { try catalog.collections(offset: $0, limit: $1, for: $2) },
                collectionDetailProvider: { try catalog.collectionDetail(id: $0, offset: $1, limit: $2, for: $3) },
                queueProvider: { try catalog.queue(for: $0) },
                queueMutationProvider: { try catalog.mutateQueue(request: $0, for: $1) },
                mediaPlaybackStateUpdater: { try catalog.updatePlaybackState(id: $0, request: $1, for: $2) },
                mediaPreferenceUpdater: { try catalog.updatePreference(id: $0, preference: $1, for: $2) },
                mediaAssetProvider: { try catalog.publicAsset(id: $0, for: $1, requiring: $2) },
                webVTTSubtitleTracksProvider: { try catalog.webVTTSubtitleTracks(id: $0, for: $1) },
                webVTTSubtitleAssetProvider: { try catalog.publicWebVTTSubtitleAsset(id: $0, trackID: $1, for: $2) },
                artworkAssetProvider: { try catalog.publicArtwork(id: $0, kind: $1, for: $2) },
                playbackInfoProvider: { itemID, principal in
                    guard let asset = try catalog.publicAsset(
                        id: itemID,
                        for: principal,
                        requiring: ServerPermission.playMedia
                    ) else { return nil }
                    return try inspector.inspect(asset: asset)
                },
                currentUserProfileProvider: { try authentication.currentUserProfile(for: $0) },
                administrationCatalog: administrationCatalog,
                authenticationService: authentication,
                authenticationProvider: { try authentication.principal(forRequestHead: $0) }
            )
            print("MediaLibServer 正在监听 http://\(configuration.host):\(configuration.port)")
            try server.run()
        case "--help", "-h":
            print(ServerCommandOutput.usage)
        default:
            throw ServerConfigurationError.runtimeNotInstalled(
                host: configuration.host,
                port: configuration.port
            )
        }
    }
}

/// Docker/服务进程的数据根目录适配层。当前服务仍只监听回环；该目录注入只为让
/// 数据库与备份不再强制依赖 macOS Application Support，为后续纯服务端拆分预留稳定边界。
struct ServerDataDirectories: Equatable {
    let root: URL
    let database: URL
    let databaseBackups: URL

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> Self? {
        guard let rawValue = environment["MEDIALIB_SERVER_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        guard rawValue.hasPrefix("/") else {
            throw ServerDataDirectoryError.notAbsolute(rawValue)
        }
        let root = URL(fileURLWithPath: rawValue, isDirectory: true).standardizedFileURL
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServerDataDirectoryError.notDirectory(root.path)
        }
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(
            at: backups,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return Self(
            root: root,
            database: root.appendingPathComponent("medialib.sqlite", isDirectory: false),
            databaseBackups: backups
        )
    }
}

enum ServerDataDirectoryError: LocalizedError, Equatable {
    case notAbsolute(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .notAbsolute(path): return "MEDIALIB_SERVER_DATA_DIR 必须是绝对路径：\(path)。"
        case let .notDirectory(path): return "MEDIALIB_SERVER_DATA_DIR 不是可用目录：\(path)。"
        }
    }
}

enum ServerCommandOutput {
    static let capabilities = [
        "administration-read",
        "authenticated-library",
        "categorized-library-browse",
        "protected-artwork",
        "health",
        "loopback-range-streaming",
        "media-detail",
        "media-probe",
        "per-user-playback-state",
        "server-discovery",
        "web-playback"
    ]

    static let usage = """
    MediaLibServer 回环预览服务
      --health   输出不含敏感信息的服务器健康 JSON
      --describe 输出 Mlink 服务描述 JSON
      --serve    仅在 127.0.0.1 上启动认证 Web/媒体预览服务

    当前具备登录/刷新/注销、桌面多用户与逐资料库授权、安全审计、
    Web 列表/详情/浏览器原生播放、逐用户续播/已看、只读管理、播放探测、HTTP Range 与分级限速。限速参数压测、
    告警聚合、可信代理、TLS 与远程部署尚未完成，因此不会接受局域网或公网监听地址。
    """

    static func write<T: Encodable>(_ value: T) throws {
        let data = try jsonDataOrThrow(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func jsonData<T: Encodable>(_ value: T) -> Data? {
        try? jsonDataOrThrow(value)
    }

    private static func jsonDataOrThrow<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

struct ServerLaunchConfiguration: Sendable {
    let host: String
    let port: Int
    let serverID: String
    let serverName: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let host = environment["MEDIALIB_SERVER_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host?.isEmpty == false ? host! : "127.0.0.1"
        guard ["127.0.0.1", "localhost"].contains(normalizedHost.lowercased()) else {
            throw ServerConfigurationError.nonLoopbackHost(normalizedHost)
        }

        let portValue = environment["MEDIALIB_SERVER_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = portValue.flatMap(Int.init) ?? 8098
        guard (1...65_535).contains(port) else {
            throw ServerConfigurationError.invalidPort(portValue ?? "")
        }

        let serverID = environment["MEDIALIB_SERVER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverName = environment["MEDIALIB_SERVER_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            host: normalizedHost,
            port: port,
            // App/容器必须注入持久化 ID；默认值只用于开发命令和本机健康探测。
            serverID: serverID?.isEmpty == false ? serverID! : "medialib-development",
            serverName: serverName?.isEmpty == false ? serverName! : "MediaLIB Server"
        )
    }
}

enum ServerConfigurationError: LocalizedError {
    case invalidPort(String)
    case nonLoopbackHost(String)
    case runtimeNotInstalled(host: String, port: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(value):
            return "MEDIALIB_SERVER_PORT 无效：\(value)。端口必须在 1 到 65535 之间。"
        case let .nonLoopbackHost(host):
            return "当前安全门槛下服务端只允许监听本机回环地址，不能使用：\(host)。"
        case let .runtimeNotInstalled(host, port):
            return "MediaLibServer 未选择运行命令，尚未监听 \(host):\(port)。使用 --health、--describe、--serve 或 --help。"
        }
    }
}
