import Foundation

public enum ServerHostControlAction: String, Codable, Sendable {
    case applyRuntimeConfiguration
}

public struct ServerHostRuntimeConfiguration: Codable, Equatable, Sendable {
    public let serverName: String
    public let port: Int
    public let networkAccessMode: String
    public let publicOrigin: String?
    public let trustedProxyAddresses: [String]

    public init(
        serverName: String,
        port: Int,
        networkAccessMode: String,
        publicOrigin: String?,
        trustedProxyAddresses: [String]
    ) {
        self.serverName = serverName
        self.port = port
        self.networkAccessMode = networkAccessMode
        self.publicOrigin = publicOrigin
        self.trustedProxyAddresses = trustedProxyAddresses
    }
}

public struct ServerHostControlRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let token: String
    public let action: ServerHostControlAction
    public let configuration: ServerHostRuntimeConfiguration

    public init(
        protocolVersion: Int = 1,
        requestID: String,
        token: String,
        action: ServerHostControlAction,
        configuration: ServerHostRuntimeConfiguration
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.token = token
        self.action = action
        self.configuration = configuration
    }
}

public struct ServerHostControlResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case accepted
        case rejected
    }

    public let protocolVersion: Int
    public let requestID: String
    public let status: Status
    public let resultCode: String

    public init(
        protocolVersion: Int = 1,
        requestID: String,
        status: Status,
        resultCode: String
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.status = status
        self.resultCode = resultCode
    }
}

public enum ServerHostControlEnvironment {
    public static let socketPath = "MEDIALIB_SERVER_HOST_CONTROL_SOCKET"
    public static let token = "MEDIALIB_SERVER_HOST_CONTROL_TOKEN"
}
