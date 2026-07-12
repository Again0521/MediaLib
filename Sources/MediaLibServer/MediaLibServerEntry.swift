import Foundation
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
                    capabilities: [
                        "health",
                        "server-discovery"
                    ]
                )
            )
        case "--serve":
            let server = try LocalLoopbackHTTPServer(configuration: configuration)
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
    static let usage = """
    MediaLibServer Phase 0
      --health   输出不含敏感信息的服务器健康 JSON
      --describe 输出 Mlink 服务描述 JSON
      --serve    仅在 127.0.0.1 上启动 Phase 0 探测 HTTP 服务

    当前 HTTP 服务仅提供 GET/HEAD /health 与 /.well-known/mlink，
    不提供用户、媒体、资料库或远程网络访问。完整 HTTP runtime 将在 Hummingbird 依赖可用后接入。
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
            // Phase 0 的默认标识仅用于本地健康探测；进入配对流程前会迁移为数据库持久化 ID。
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
            return "Phase 0 服务端只允许监听本机回环地址，不能使用：\(host)。"
        case let .runtimeNotInstalled(host, port):
            return "MediaLibServer 当前仅提供 Phase 0 协议验证命令，尚未监听 \(host):\(port)。使用 --health、--describe、--serve 或 --help。"
        }
    }
}
