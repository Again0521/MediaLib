import Foundation

/// 桌面端服务模式的本地配置。
///
/// 此配置刻意独立于 `AppSettings`：服务端未来会同时被桌面端、纯服务端
/// Docker 镜像和管理网页消费，不能把服务端运行时细节耦合进播放器偏好设置。
public struct ServerModeConfiguration: Codable, Equatable, Sendable {
    public static let defaultPort = 8098
    public static let defaultServerName = "MediaLIB Server"

    public var isEnabled: Bool
    public var serverID: String
    public var serverName: String
    public var port: Int
    /// 仅在服务模式运行时生效：桌面端停止非必要视觉预热，服务子进程采用 utility QoS。
    /// 索引、认证、扫描和媒体分发仍保持可用，不能把轻量模式实现成停掉服务功能。
    public var isLightweightMode: Bool

    public init(
        isEnabled: Bool = false,
        serverID: String = UUID().uuidString.lowercased(),
        serverName: String = ServerModeConfiguration.defaultServerName,
        port: Int = ServerModeConfiguration.defaultPort,
        isLightweightMode: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.serverID = Self.normalizedServerID(serverID)
        self.serverName = Self.normalizedServerName(serverName)
        self.port = Self.normalizedPort(port)
        self.isLightweightMode = isLightweightMode
    }

    public var loopbackBaseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    public mutating func updateServerName(_ name: String) {
        serverName = Self.normalizedServerName(name)
    }

    public mutating func updatePort(_ port: Int) {
        self.port = Self.normalizedPort(port)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case serverID
        case serverName
        case port
        case isLightweightMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            serverID: try container.decodeIfPresent(String.self, forKey: .serverID) ?? UUID().uuidString.lowercased(),
            serverName: try container.decodeIfPresent(String.self, forKey: .serverName) ?? Self.defaultServerName,
            port: try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort,
            isLightweightMode: try container.decodeIfPresent(Bool.self, forKey: .isLightweightMode) ?? false
        )
    }

    private static func normalizedServerID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? UUID().uuidString.lowercased() : trimmed
    }

    private static func normalizedServerName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultServerName : String(trimmed.prefix(80))
    }

    private static func normalizedPort(_ value: Int) -> Int {
        (1...65_535).contains(value) ? value : defaultPort
    }
}

/// 服务端配置的单独存储空间，避免与历史播放器设置的迁移耦合。
public final class ServerModeSettingsStore {
    private let key = "MediaLib.ServerModeConfiguration"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ServerModeConfiguration {
        let configuration: ServerModeConfiguration
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ServerModeConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = ServerModeConfiguration()
        }
        save(configuration)
        return configuration
    }

    public func save(_ configuration: ServerModeConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}
