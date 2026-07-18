import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Mlink 的无凭据发现边界。发现阶段只读取公开描述，不能请求资料库、媒体或登录端点，
/// 也不能把 URL 中的用户信息、查询参数或片段持久化到来源模型。
enum MlinkDiscoveryService {
    enum Error: LocalizedError {
        case invalidServerURL
        case untrustedResponse
        case unsupportedVersion(String)
        case requestFailed(Int)

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: return "Mlink 服务器地址必须是 HTTP 或 HTTPS 地址，且不能包含账号信息。"
            case .untrustedResponse: return "Mlink 服务描述无效或包含不安全字段。"
            case .unsupportedVersion(let version): return "该 Mlink 服务版本（\(version)）暂不受支持。"
            case .requestFailed(let status): return "Mlink 服务发现失败（HTTP \(status)）。"
            }
        }
    }

    static func discover(serverURL: URL) async throws -> MlinkServerDescriptor {
        do {
            return try await MlinkAPIClient().discover(serverURL: serverURL)
        } catch let error as MlinkAPIClient.Error {
            switch error {
            case .invalidServerURL, .insecureTransport: throw Error.invalidServerURL
            case .unsupportedVersion(let version): throw Error.unsupportedVersion(version)
            case .requestFailed(let status): throw Error.requestFailed(status)
            default: throw Error.untrustedResponse
            }
        }
    }
}
