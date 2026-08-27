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
        } else if requestedProxies.contains(where: { !isIPv4Address($0) }) {
            issues.append("trusted-proxies.invalid")
        }
        if !normalized.trustedProxyAddresses.isEmpty, normalized.publicOrigin == nil {
            issues.append("trusted-proxies.require-origin")
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

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) &&
                Int(part).map { (0...255).contains($0) } == true
        }
    }
}
