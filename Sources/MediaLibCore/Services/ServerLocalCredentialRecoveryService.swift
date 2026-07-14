import Foundation

public enum ServerLocalCredentialRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedUser
    case credentialUnavailable
    case newPasswordMatchesCurrent
    case credentialChangedConcurrently
    case userDisabled

    public var errorDescription: String? {
        switch self {
        case .unsupportedUser: "本机恢复只适用于内置管理员。"
        case .credentialUnavailable: "管理员密码尚未完成首次设置。"
        case .newPasswordMatchesCurrent: "恢复密码不能与当前密码相同。"
        case .credentialChangedConcurrently: "管理员密码已在其它操作中变更，请重新验证本机身份后再试。"
        case .userDisabled: "内置管理员当前不可用。"
        }
    }
}

/// 忘记密码时的本机恢复写入边界。
///
/// 调用方必须先完成操作系统用户存在性验证并停止 App 管理的服务进程；HTTP 路由层
/// 不引用此服务，它也不生成恢复 token 或网络端点。成功恢复会撤销全部设备和会话。
public final class ServerLocalCredentialRecoveryService: @unchecked Sendable {
    private let database: DatabaseManager
    private let passwordHasher: ServerPasswordHasher
    private let identityRepository: ServerIdentityRepository

    public init(database: DatabaseManager, passwordHasher: ServerPasswordHasher) {
        self.database = database
        self.passwordHasher = passwordHasher
        identityRepository = ServerIdentityRepository(database: database)
    }

    public func recoverAdministratorPassword(
        userID: String = ServerIdentityRepository.initialAdministratorUserID,
        newPassword: String,
        at date: Date = Date()
    ) throws {
        guard (12...1_024).contains(newPassword.utf8.count) else {
            throw ServerPasswordHasherError.passwordLengthInvalid
        }
        guard userID == ServerIdentityRepository.initialAdministratorUserID else {
            throw ServerLocalCredentialRecoveryError.unsupportedUser
        }
        guard let original = try credentialState(userID: userID), !original.requiresInitialPassword else {
            throw ServerLocalCredentialRecoveryError.credentialUnavailable
        }
        guard !original.isDisabled else { throw ServerLocalCredentialRecoveryError.userDisabled }
        guard !passwordHasher.verify(password: newPassword, encodedHash: original.passwordHash) else {
            try recordRejectedRecovery(userID: userID, detailCode: "password.reused", at: date)
            throw ServerLocalCredentialRecoveryError.newPasswordMatchesCurrent
        }

        let replacementHash = try passwordHasher.hash(password: newPassword)
        do {
            try database.transaction {
                guard let latest = try credentialState(userID: userID), !latest.requiresInitialPassword else {
                    throw ServerLocalCredentialRecoveryError.credentialUnavailable
                }
                guard !latest.isDisabled else { throw ServerLocalCredentialRecoveryError.userDisabled }
                guard latest.passwordHash == original.passwordHash else {
                    throw ServerLocalCredentialRecoveryError.credentialChangedConcurrently
                }

                try database.execute(
                    """
                    UPDATE server_credentials
                    SET password_hash = ?, password_algorithm = 'argon2id', password_changed_at = ?,
                        failed_attempt_count = 0, locked_until = NULL, last_failed_at = NULL
                    WHERE user_id = ? AND password_hash = ?
                    """,
                    bindings: [
                        .text(replacementHash), .optionalDate(date), .text(userID), .text(original.passwordHash)
                    ]
                )
                let changedRows = try database.query("SELECT changes()") { $0.int(0) ?? 0 }.first ?? 0
                guard changedRows == 1 else {
                    throw ServerLocalCredentialRecoveryError.credentialChangedConcurrently
                }
                try database.execute(
                    "UPDATE server_users SET updated_at = ? WHERE id = ?",
                    bindings: [.optionalDate(date), .text(userID)]
                )
                try database.execute(
                    "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                    bindings: [.optionalDate(date), .text(userID)]
                )
                try database.execute(
                    "UPDATE server_devices SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                    bindings: [.optionalDate(date), .text(userID)]
                )
                try identityRepository.appendSecurityEvent(ServerSecurityEvent(
                    occurredAt: date,
                    category: .identity,
                    action: "credential.recovered",
                    outcome: .success,
                    actorUserID: nil,
                    targetUserID: userID,
                    detailCode: "local.user-presence"
                ))
            }
        } catch ServerLocalCredentialRecoveryError.credentialChangedConcurrently {
            try recordRejectedRecovery(userID: userID, detailCode: "credential.changed", at: date)
            throw ServerLocalCredentialRecoveryError.credentialChangedConcurrently
        }
    }

    private func credentialState(userID: String) throws -> CredentialState? {
        try database.query(
            """
            SELECT credential.password_hash, user.is_disabled, user.requires_initial_password
            FROM server_users AS user
            LEFT JOIN server_credentials AS credential ON credential.user_id = user.id
            WHERE user.id = ?
            LIMIT 1
            """,
            bindings: [.text(userID)]
        ) { row -> CredentialState? in
            guard let passwordHash = row.string(0), !passwordHash.isEmpty else { return nil }
            return CredentialState(
                passwordHash: passwordHash,
                isDisabled: row.bool(1),
                requiresInitialPassword: row.bool(2)
            )
        }.first ?? nil
    }

    private func recordRejectedRecovery(userID: String, detailCode: String, at date: Date) throws {
        try identityRepository.appendSecurityEvent(ServerSecurityEvent(
            occurredAt: date,
            category: .identity,
            action: "credential.recovery.rejected",
            outcome: .denied,
            actorUserID: nil,
            targetUserID: userID,
            detailCode: detailCode
        ))
    }

    private struct CredentialState {
        let passwordHash: String
        let isDisabled: Bool
        let requiresInitialPassword: Bool
    }
}
