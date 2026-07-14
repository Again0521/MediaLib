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
            let directories = try FileAccessService.appDirectories()
            let database = try DatabaseManager(
                url: directories.database,
                backupDirectory: directories.databaseBackups
            )
            let catalog = ServerLibraryCatalog(database: database)
            let administrationCatalog = ServerAdministrationCatalog(database: database)
            let authentication = try ServerAuthenticationService(database: database)
            let inspector = FFprobeMediaInspector()
            let hlsSessionManager = FFmpegHLSSessionManager()
            let server = try LocalLoopbackHTTPServer(
                configuration: configuration,
                librarySnapshotProvider: { try catalog.snapshot(for: $0) },
                libraryBrowseProvider: { try catalog.browse($0, for: $1) },
                libraryCategoriesProvider: { try catalog.categories(for: $0) },
                mediaDetailProvider: { try catalog.publicDetail(id: $0, for: $1) },
                mediaPlaybackStateUpdater: { try catalog.updatePlaybackState(id: $0, request: $1, for: $2) },
                mediaAssetProvider: { try catalog.publicAsset(id: $0, for: $1, requiring: $2) },
                artworkAssetProvider: { try catalog.publicArtwork(id: $0, kind: $1, for: $2) },
                playbackInfoProvider: { itemID, principal in
                    guard let asset = try catalog.publicAsset(
                        id: itemID,
                        for: principal,
                        requiring: .playMedia
                    ) else { return nil }
                    return try inspector.inspect(asset: asset)
                },
                hlsSessionManager: hlsSessionManager,
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

enum ServerCommandOutput {
    static let capabilities = [
        "administration-read",
        "authenticated-library",
        "categorized-library-browse",
        "protected-artwork",
        "health",
        "loopback-hls-transcode",
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
    Web 列表/详情/播放、逐用户续播/已看、只读管理、播放探测、HTTP Range、HLS 与分级限速。限速参数压测、
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
