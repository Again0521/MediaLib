import Foundation

/// 稳定的 Mlink 协议版本。服务端和客户端必须通过 capabilities 协商可选能力，
/// 不能只根据应用版本推断行为。
public enum MlinkProtocol {
    public static let currentAPIVersion = "v1"
}

/// 服务健康检查响应；不包含目录、用户、token 或其它敏感信息。
public struct ServerHealth: Codable, Equatable, Sendable {
    public let status: String
    public let apiVersion: String
    public let serverID: String
    public let serverName: String
    public let timestamp: Date

    public init(
        status: String = "ok",
        apiVersion: String = MlinkProtocol.currentAPIVersion,
        serverID: String,
        serverName: String,
        timestamp: Date = Date()
    ) {
        self.status = status
        self.apiVersion = apiVersion
        self.serverID = serverID
        self.serverName = serverName
        self.timestamp = timestamp
    }
}

/// `/.well-known/mlink` 的公开描述。此阶段仅声明可安全探测的能力；认证、库列表
/// 和任何媒体路径将在后续 API 中单独授权后返回。
public struct MlinkServerDescriptor: Codable, Equatable, Sendable {
    public let serverID: String
    public let serverName: String
    public let apiVersion: String
    public let capabilities: [String]

    public init(
        serverID: String,
        serverName: String,
        apiVersion: String = MlinkProtocol.currentAPIVersion,
        capabilities: [String]
    ) {
        self.serverID = serverID
        self.serverName = serverName
        self.apiVersion = apiVersion
        self.capabilities = capabilities.sorted()
    }
}
