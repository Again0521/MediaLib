import Foundation
import MediaLibCore

struct ServerRuntimeConfigurationMutationRequest: Decodable, Equatable, Sendable {
    let currentPassword: String?
    let serverName: String
    let port: Int
    let networkAccessMode: ServerNetworkAccessMode
    let publicOrigin: String?
    let trustedProxyAddresses: [String]
}

struct ServerRuntimeConfigurationValidation: Codable, Equatable, Sendable {
    let valid: Bool
    let hostControlAvailable: Bool
    let normalizedServerName: String?
    let normalizedPublicOrigin: String?
    let normalizedTrustedProxyAddresses: [String]
    let issueCodes: [String]
}

enum ServerRuntimeConfigurationValidator {
    static func validate(
        _ request: ServerRuntimeConfigurationMutationRequest,
        hostControlAvailable: Bool
    ) -> ServerRuntimeConfigurationValidation {
        var issues: [String] = []
        let trimmedName = request.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.utf8.count > 80 {
            issues.append("server-name.invalid")
        }
        if !(1_024...65_535).contains(request.port) {
            issues.append("port.out-of-range")
        }
        if request.trustedProxyAddresses.count > 32 {
            issues.append("trusted-proxies.too-many")
        }

        let normalized = ServerModeConfiguration(
            serverName: trimmedName,
            port: request.port,
            networkAccessMode: request.networkAccessMode,
            publicOrigin: request.publicOrigin,
            trustedProxyAddresses: request.trustedProxyAddresses
        )
        let requestedOrigin = request.publicOrigin?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedOrigin, !requestedOrigin.isEmpty,
           normalized.publicOrigin == nil {
            issues.append("public-origin.invalid")
        }
        let requestedProxies = request.trustedProxyAddresses.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if request.networkAccessMode == .lanHTTPS,
           (!requestedProxies.isEmpty || requestedOrigin?.isEmpty == false) {
            issues.append("lan-https.manages-origin")
        } else if requestedProxies.contains(where: { !ServerModeConfiguration.isTrustedProxyAddress($0) }) {
            issues.append("trusted-proxies.invalid")
        }

        return ServerRuntimeConfigurationValidation(
            valid: issues.isEmpty,
            hostControlAvailable: hostControlAvailable,
            normalizedServerName: issues.contains("server-name.invalid") ? nil : normalized.serverName,
            normalizedPublicOrigin: normalized.publicOrigin,
            normalizedTrustedProxyAddresses: normalized.trustedProxyAddresses,
            issueCodes: issues
        )
    }

}
