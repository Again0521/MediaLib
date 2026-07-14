import Foundation
import LocalAuthentication

@MainActor
protocol ServerLocalUserPresenceAuthorizing {
    func authorizeAdministratorRecovery() async throws -> Bool
}

struct SystemServerLocalUserPresenceAuthorizer: ServerLocalUserPresenceAuthorizing {
    func authorizeAdministratorRecovery() async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消恢复"
        context.localizedFallbackTitle = "使用 Mac 登录密码"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            if let policyError { throw policyError }
            return false
        }
        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "恢复 MediaLIB 服务端管理员密码"
            ) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
