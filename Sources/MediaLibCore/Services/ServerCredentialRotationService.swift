import Foundation

public enum ServerCredentialRotationError: Error, LocalizedError, Equatable, Sendable {
    case credentialUnavailable
    case currentPasswordIncorrect
    case newPasswordMatchesCurrent
    case credentialChangedConcurrently
    case userDisabled

    public var errorDescription: String? {
        switch self {
        case .credentialUnavailable: "服务端密码尚未配置。"
        case .currentPasswordIncorrect: "当前管理员密码不正确。"
        case .newPasswordMatchesCurrent: "新密码不能与当前密码相同。"
        case .credentialChangedConcurrently: "管理员密码已在其它操作中变更，请重新输入后再试。"
        case .userDisabled: "该服务端用户已停用。"
        }
    }
}

/// 需要验证当前密码的服务端凭据轮换边界。
///
/// 明文密码只在调用栈与 Argon2 校验/哈希过程内短暂存在，不进入数据库、状态快照或审计。
/// Argon2 在数据库事务外执行；提交时重新核对原编码凭据，使并发改密只能有一个成功。
public final class ServerCredentialRotationService: @unchecked Sendable {
    private let database: DatabaseManager
    private let passwordHasher: ServerPasswordHasher
    private let identityRepository: ServerIdentityRepository

    public init(database: DatabaseManager, passwordHasher: ServerPasswordHasher) {
        self.database = database
        self.passwordHasher = passwordHasher
        identityRepository = ServerIdentityRepository(database: database)
    }

    public func changePassword(
        userID: String,
        currentPassword: String,
        newPassword: String,
        at date: Date = Date()
    ) throws {
        guard let original = try credentialState(userID: userID), !original.requiresInitialPassword else {
            throw ServerCredentialRotationError.credentialUnavailable
        }
        guard !original.isDisabled else { throw ServerCredentialRotationError.userDisabled }

        guard passwordHasher.verify(password: currentPassword, encodedHash: original.passwordHash) else {
            try recordRejectedChange(userID: userID, detailCode: "current.mismatch", at: date)
            throw ServerCredentialRotationError.currentPasswordIncorrect
        }
        guard currentPassword != newPassword else {
            try recordRejectedChange(userID: userID, detailCode: "password.reused", at: date)
            throw ServerCredentialRotationError.newPasswordMatchesCurrent
        }

        let replacementHash = try passwordHasher.hash(password: newPassword)
        do {
            try database.transaction {
                guard let latest = try credentialState(userID: userID), !latest.requiresInitialPassword else {
                    throw ServerCredentialRotationError.credentialUnavailable
                }
                guard !latest.isDisabled else { throw ServerCredentialRotationError.userDisabled }
                guard latest.passwordHash == original.passwordHash else {
                    throw ServerCredentialRotationError.credentialChangedConcurrently
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
                    throw ServerCredentialRotationError.credentialChangedConcurrently
                }
                try database.execute(
                    "UPDATE server_users SET updated_at = ? WHERE id = ?",
                    bindings: [.optionalDate(date), .text(userID)]
                )
                try database.execute(
                    "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                    bindings: [.optionalDate(date), .text(userID)]
                )
                try identityRepository.appendSecurityEvent(ServerSecurityEvent(
                    occurredAt: date,
                    category: .identity,
                    action: "credential.changed",
                    outcome: .success,
                    actorUserID: userID,
                    targetUserID: userID,
                    detailCode: "sessions.revoked"
                ))
            }
        } catch ServerCredentialRotationError.credentialChangedConcurrently {
            // 事务中的失败审计会随回滚消失，因此在回滚完成后单独记录拒绝事件。
            try recordRejectedChange(userID: userID, detailCode: "credential.changed", at: date)
            throw ServerCredentialRotationError.credentialChangedConcurrently
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

    private func recordRejectedChange(userID: String, detailCode: String, at date: Date) throws {
        try identityRepository.appendSecurityEvent(ServerSecurityEvent(
            occurredAt: date,
            category: .identity,
            action: "credential.change.rejected",
            outcome: .denied,
            actorUserID: userID,
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
