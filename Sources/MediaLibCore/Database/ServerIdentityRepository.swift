import Foundation

public enum ServerIdentityRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentifier
    case invalidUsername
    case invalidDisplayValue
    case invalidPasswordHash
    case invalidTokenDigest
    case invalidExpiration
    case userNotFound
    case roleNotFound
    case deviceNotFound
    case deviceOwnershipMismatch
    case initialCredentialAlreadySet
    case usernameAlreadyExists
    case cannotModifyInitialAdministrator

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "标识符格式无效。"
        case .invalidUsername: "用户名格式无效。"
        case .invalidDisplayValue: "显示文本格式无效。"
        case .invalidPasswordHash: "密码凭据不是有效的 Argon2id 编码结果。"
        case .invalidTokenDigest: "会话令牌摘要格式无效。"
        case .invalidExpiration: "会话有效期设置无效。"
        case .userNotFound: "服务端用户不存在。"
        case .roleNotFound: "服务端角色不存在。"
        case .deviceNotFound: "服务端设备不存在。"
        case .deviceOwnershipMismatch: "设备不属于指定用户。"
        case .initialCredentialAlreadySet: "初始管理员密码已经设置，不能再次走首次设置流程。"
        case .usernameAlreadyExists: "该服务端用户名已经存在。"
        case .cannotModifyInitialAdministrator: "不能禁用或降低内置管理员的权限。"
        }
    }
}

/// 服务端身份数据边界。调用方只能提交 Argon2id 编码结果与 BLAKE2b-256 十六进制摘要，
/// 此类型没有接收明文密码或原始令牌的 API。
public final class ServerIdentityRepository: @unchecked Sendable {
    public static let administratorRoleID = "server-role-admin"
    public static let memberRoleID = "server-role-member"
    public static let initialAdministratorUserID = "server-user-local-admin"

    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    @discardableResult
    public func createUser(
        id: String = UUID().uuidString,
        username: String,
        displayName: String,
        roleID: String = ServerIdentityRepository.memberRoleID,
        at date: Date = Date()
    ) throws -> ServerUser {
        let id = try validatedIdentifier(id)
        let roleID = try validatedIdentifier(roleID)
        let username = try validatedUsername(username)
        let displayName = try validatedDisplayValue(displayName)
        let user = ServerUser(
            id: id,
            username: username,
            displayName: displayName,
            createdAt: date,
            updatedAt: date
        )
        try database.transaction {
            guard try roleExists(id: roleID) else { throw ServerIdentityRepositoryError.roleNotFound }
            let normalizedUsername = Self.normalizeUsername(user.username)
            let existingUsernameCount = try database.query(
                "SELECT COUNT(*) FROM server_users WHERE normalized_username = ?",
                bindings: [.text(normalizedUsername)],
                map: { $0.int(0) ?? 0 }
            ).first ?? 0
            guard existingUsernameCount == 0 else {
                throw ServerIdentityRepositoryError.usernameAlreadyExists
            }
            try database.execute(
                """
                INSERT INTO server_users (
                  id, username, normalized_username, display_name, is_disabled,
                  requires_initial_password, created_at, updated_at
                ) VALUES (?, ?, ?, ?, 0, 1, ?, ?)
                """,
                bindings: [
                    .text(user.id), .text(user.username), .text(normalizedUsername),
                    .text(user.displayName), .optionalDate(date), .optionalDate(date)
                ]
            )
            try database.execute(
                "INSERT INTO server_user_roles (user_id, role_id, assigned_at) VALUES (?, ?, ?)",
                bindings: [.text(user.id), .text(roleID), .optionalDate(date)]
            )
        }
        return user
    }

    /// 密码摘要、角色与媒体库授权在同一事务中落库，不会留下“有账号但没有凭据”
    /// 或“凭据已设置但权限只写入一半”的中间状态。
    @discardableResult
    public func createConfiguredUser(
        id: String = UUID().uuidString,
        username: String,
        displayName: String,
        roleID: String = ServerIdentityRepository.memberRoleID,
        argon2idEncodedHash: String,
        libraryGrants: [ServerLibraryGrant],
        actorUserID: String,
        at date: Date = Date()
    ) throws -> ServerUser {
        try database.transaction {
            let user = try createUser(
                id: id,
                username: username,
                displayName: displayName,
                roleID: roleID,
                at: date
            )
            try setCredential(userID: user.id, argon2idEncodedHash: argon2idEncodedHash, changedAt: date)
            try replaceLibraryGrants(userID: user.id, grants: libraryGrants, at: date)
            try appendSecurityEvent(ServerSecurityEvent(
                occurredAt: date,
                category: .identity,
                action: "user.created",
                outcome: .success,
                actorUserID: actorUserID,
                targetUserID: user.id,
                detailCode: roleID == Self.administratorRoleID ? "administrator" : "member"
            ))
            return user
        }
    }

    public func user(id: String) throws -> ServerUser? {
        let id = try validatedIdentifier(id)
        return try database.query(
            """
            SELECT id, username, display_name, is_disabled, requires_initial_password, created_at, updated_at
            FROM server_users WHERE id = ?
            """,
            bindings: [.text(id)],
            map: mapUser(row:)
        ).first
    }

    public func users() throws -> [ServerUser] {
        try database.query(
            """
            SELECT id, username, display_name, is_disabled, requires_initial_password, created_at, updated_at
            FROM server_users ORDER BY normalized_username
            """,
            map: mapUser(row:)
        )
    }

    public func roles() throws -> [ServerRole] {
        let rows = try database.query(
            """
            SELECT id, name, is_system, created_at, updated_at
            FROM server_roles ORDER BY is_system DESC, normalized_name
            """
        ) { row in
            (
                id: row.string(0) ?? "",
                name: row.string(1) ?? "",
                isSystem: row.bool(2),
                createdAt: row.date(3) ?? Date(),
                updatedAt: row.date(4) ?? Date()
            )
        }
        return try rows.map { row in
            let rawPermissions = try database.query(
                "SELECT permission FROM server_role_permissions WHERE role_id = ? ORDER BY permission",
                bindings: [.text(row.id)]
            ) { $0.string(0) ?? "" }
            return ServerRole(
                id: row.id,
                name: row.name,
                isSystem: row.isSystem,
                permissions: Set(rawPermissions.compactMap(ServerPermission.init(rawValue:))),
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }
    }

    public func roleIDs(userID: String) throws -> [String] {
        let userID = try validatedIdentifier(userID)
        guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        return try database.query(
            "SELECT role_id FROM server_user_roles WHERE user_id = ? ORDER BY role_id",
            bindings: [.text(userID)]
        ) { $0.string(0) ?? "" }
    }

    public func setCredential(
        userID: String,
        argon2idEncodedHash: String,
        changedAt: Date = Date()
    ) throws {
        let userID = try validatedIdentifier(userID)
        guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        guard Self.isValidArgon2idEncodedHash(argon2idEncodedHash) else {
            throw ServerIdentityRepositoryError.invalidPasswordHash
        }
        try database.transaction {
            try database.execute(
                """
                INSERT INTO server_credentials (user_id, password_hash, password_algorithm, password_changed_at)
                VALUES (?, ?, 'argon2id', ?)
                ON CONFLICT(user_id) DO UPDATE SET
                  password_hash = excluded.password_hash,
                  password_algorithm = excluded.password_algorithm,
                  password_changed_at = excluded.password_changed_at,
                  failed_attempt_count = 0,
                  locked_until = NULL,
                  last_failed_at = NULL
                """,
                bindings: [.text(userID), .text(argon2idEncodedHash), .optionalDate(changedAt)]
            )
            try database.execute(
                "UPDATE server_users SET requires_initial_password = 0, updated_at = ? WHERE id = ?",
                bindings: [.optionalDate(changedAt), .text(userID)]
            )
            try database.execute(
                "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                bindings: [.optionalDate(changedAt), .text(userID)]
            )
        }
    }

    /// 只允许待初始化且尚无凭据的用户设置首个密码。检查与写入位于同一
    /// BEGIN IMMEDIATE 事务内，多个窗口或进程不能通过此入口互相覆盖密码。
    public func setInitialCredential(
        userID: String,
        argon2idEncodedHash: String,
        changedAt: Date = Date()
    ) throws {
        let userID = try validatedIdentifier(userID)
        guard Self.isValidArgon2idEncodedHash(argon2idEncodedHash) else {
            throw ServerIdentityRepositoryError.invalidPasswordHash
        }
        try database.transaction {
            guard let state = try database.query(
                """
                SELECT requires_initial_password,
                       EXISTS(SELECT 1 FROM server_credentials WHERE user_id = server_users.id)
                FROM server_users WHERE id = ?
                """,
                bindings: [.text(userID)],
                map: { ($0.bool(0), $0.bool(1)) }
            ).first else {
                throw ServerIdentityRepositoryError.userNotFound
            }
            guard state.0, !state.1 else {
                throw ServerIdentityRepositoryError.initialCredentialAlreadySet
            }
            try database.execute(
                """
                INSERT INTO server_credentials (
                  user_id, password_hash, password_algorithm, password_changed_at,
                  failed_attempt_count, locked_until, last_failed_at, last_login_at
                ) VALUES (?, ?, 'argon2id', ?, 0, NULL, NULL, NULL)
                """,
                bindings: [.text(userID), .text(argon2idEncodedHash), .optionalDate(changedAt)]
            )
            try database.execute(
                """
                UPDATE server_users
                SET requires_initial_password = 0, updated_at = ?
                WHERE id = ? AND requires_initial_password = 1
                """,
                bindings: [.optionalDate(changedAt), .text(userID)]
            )
            try database.execute(
                "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                bindings: [.optionalDate(changedAt), .text(userID)]
            )
            try appendSecurityEvent(ServerSecurityEvent(
                occurredAt: changedAt,
                category: .identity,
                action: "credential.initialized",
                outcome: .success,
                actorUserID: userID,
                targetUserID: userID
            ))
        }
    }

    public func resetCredential(
        userID: String,
        argon2idEncodedHash: String,
        actorUserID: String,
        changedAt: Date = Date()
    ) throws {
        if userID == Self.initialAdministratorUserID {
            throw ServerIdentityRepositoryError.cannotModifyInitialAdministrator
        }
        try database.transaction {
            try setCredential(
                userID: userID,
                argon2idEncodedHash: argon2idEncodedHash,
                changedAt: changedAt
            )
            try appendSecurityEvent(ServerSecurityEvent(
                occurredAt: changedAt,
                category: .identity,
                action: "credential.reset",
                outcome: .success,
                actorUserID: actorUserID,
                targetUserID: userID,
                detailCode: "sessions.revoked"
            ))
        }
    }

    public func hasCredential(userID: String) throws -> Bool {
        let userID = try validatedIdentifier(userID)
        return try database.query(
            "SELECT COUNT(*) FROM server_credentials WHERE user_id = ?",
            bindings: [.text(userID)]
        ) { $0.int(0) ?? 0 }.first == 1
    }

    public func assignRole(userID: String, roleID: String, at date: Date = Date()) throws {
        let userID = try validatedIdentifier(userID)
        let roleID = try validatedIdentifier(roleID)
        guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        guard try roleExists(id: roleID) else { throw ServerIdentityRepositoryError.roleNotFound }
        try database.execute(
            "INSERT OR IGNORE INTO server_user_roles (user_id, role_id, assigned_at) VALUES (?, ?, ?)",
            bindings: [.text(userID), .text(roleID), .optionalDate(date)]
        )
    }

    public func replaceRole(userID: String, roleID: String, at date: Date = Date()) throws {
        let userID = try validatedIdentifier(userID)
        let roleID = try validatedIdentifier(roleID)
        guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        guard try roleExists(id: roleID) else { throw ServerIdentityRepositoryError.roleNotFound }
        if userID == Self.initialAdministratorUserID, roleID != Self.administratorRoleID {
            throw ServerIdentityRepositoryError.cannotModifyInitialAdministrator
        }
        try database.transaction {
            try database.execute("DELETE FROM server_user_roles WHERE user_id = ?", bindings: [.text(userID)])
            try database.execute(
                "INSERT INTO server_user_roles (user_id, role_id, assigned_at) VALUES (?, ?, ?)",
                bindings: [.text(userID), .text(roleID), .optionalDate(date)]
            )
        }
    }

    public func permissions(userID: String) throws -> Set<ServerPermission> {
        let userID = try validatedIdentifier(userID)
        let rawValues = try database.query(
            """
            SELECT DISTINCT permission
            FROM server_role_permissions
            JOIN server_user_roles ON server_user_roles.role_id = server_role_permissions.role_id
            JOIN server_users ON server_users.id = server_user_roles.user_id
            WHERE server_user_roles.user_id = ? AND server_users.is_disabled = 0
            """,
            bindings: [.text(userID)]
        ) { $0.string(0) ?? "" }
        return Set(rawValues.compactMap(ServerPermission.init(rawValue:)))
    }

    @discardableResult
    public func setLibraryGrant(_ grant: ServerLibraryGrant) throws -> ServerLibraryGrant {
        let userID = try validatedIdentifier(grant.userID)
        let libraryID = try validatedIdentifier(grant.libraryID)
        guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        guard Self.isCoherent(grant) else { throw ServerIdentityRepositoryError.invalidIdentifier }
        let updated = ServerLibraryGrant(
            userID: userID,
            libraryID: libraryID,
            canView: grant.canView,
            canPlay: grant.canPlay,
            canDownload: grant.canDownload,
            canEditMetadata: grant.canEditMetadata,
            canDeleteItems: grant.canDeleteItems,
            updatedAt: Date()
        )
        try database.execute(
            """
            INSERT INTO server_library_grants (
              user_id, library_id, can_view, can_play, can_download,
              can_edit_metadata, can_delete_items, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, library_id) DO UPDATE SET
              can_view = excluded.can_view,
              can_play = excluded.can_play,
              can_download = excluded.can_download,
              can_edit_metadata = excluded.can_edit_metadata,
              can_delete_items = excluded.can_delete_items,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(userID), .text(libraryID), .bool(updated.canView), .bool(updated.canPlay),
                .bool(updated.canDownload), .bool(updated.canEditMetadata),
                .bool(updated.canDeleteItems), .optionalDate(updated.updatedAt)
            ]
        )
        return updated
    }

    public func libraryGrants(userID: String) throws -> [ServerLibraryGrant] {
        let userID = try validatedIdentifier(userID)
        return try database.query(
            """
            SELECT user_id, library_id, can_view, can_play, can_download,
                   can_edit_metadata, can_delete_items, updated_at
            FROM server_library_grants WHERE user_id = ? ORDER BY library_id
            """,
            bindings: [.text(userID)]
        ) { row in
            ServerLibraryGrant(
                userID: row.string(0) ?? "",
                libraryID: row.string(1) ?? "",
                canView: row.bool(2),
                canPlay: row.bool(3),
                canDownload: row.bool(4),
                canEditMetadata: row.bool(5),
                canDeleteItems: row.bool(6),
                updatedAt: row.date(7) ?? Date()
            )
        }
    }

    public func replaceLibraryGrants(
        userID: String,
        grants: [ServerLibraryGrant],
        at date: Date = Date()
    ) throws {
        let userID = try validatedIdentifier(userID)
        guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        guard Set(grants.map(\.libraryID)).count == grants.count,
              grants.allSatisfy({ $0.userID == userID && Self.isCoherent($0) }) else {
            throw ServerIdentityRepositoryError.invalidIdentifier
        }
        try database.transaction {
            try database.execute("DELETE FROM server_library_grants WHERE user_id = ?", bindings: [.text(userID)])
            for grant in grants {
                let libraryID = try validatedIdentifier(grant.libraryID)
                try database.execute(
                    """
                    INSERT INTO server_library_grants (
                      user_id, library_id, can_view, can_play, can_download,
                      can_edit_metadata, can_delete_items, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(userID), .text(libraryID), .bool(grant.canView), .bool(grant.canPlay),
                        .bool(grant.canDownload), .bool(grant.canEditMetadata),
                        .bool(grant.canDeleteItems), .optionalDate(date)
                    ]
                )
            }
        }
    }

    /// 修改成员显示名、单一角色、媒体库授权与启用状态。任何管理修改都会撤销该
    /// 用户的既有会话，使权限变化不依赖客户端刷新令牌后才生效。
    public func updateManagedUser(
        userID: String,
        displayName: String,
        roleID: String,
        libraryGrants: [ServerLibraryGrant],
        disabled: Bool,
        actorUserID: String,
        at date: Date = Date()
    ) throws {
        let userID = try validatedIdentifier(userID)
        let displayName = try validatedDisplayValue(displayName)
        if userID == Self.initialAdministratorUserID {
            throw ServerIdentityRepositoryError.cannotModifyInitialAdministrator
        }
        try database.transaction {
            guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
            try replaceRole(userID: userID, roleID: roleID, at: date)
            try replaceLibraryGrants(userID: userID, grants: libraryGrants, at: date)
            try database.execute(
                "UPDATE server_users SET display_name = ?, is_disabled = ?, updated_at = ? WHERE id = ?",
                bindings: [.text(displayName), .bool(disabled), .optionalDate(date), .text(userID)]
            )
            try database.execute(
                "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                bindings: [.optionalDate(date), .text(userID)]
            )
            try appendSecurityEvent(ServerSecurityEvent(
                occurredAt: date,
                category: .authorization,
                action: "user.access.updated",
                outcome: .success,
                actorUserID: actorUserID,
                targetUserID: userID,
                detailCode: disabled ? "disabled" : "enabled"
            ))
        }
    }

    @discardableResult
    public func registerDevice(
        id: String = UUID().uuidString,
        userID: String,
        name: String,
        platform: String,
        at date: Date = Date()
    ) throws -> ServerDevice {
        let id = try validatedIdentifier(id)
        let userID = try validatedIdentifier(userID)
        let name = try validatedDisplayValue(name)
        let platform = try validatedDisplayValue(platform)
        guard let owner = try user(id: userID), !owner.isDisabled else {
            throw ServerIdentityRepositoryError.userNotFound
        }
        let device = ServerDevice(
            id: id, userID: userID, name: name, platform: platform,
            createdAt: date, lastSeenAt: date
        )
        try database.execute(
            """
            INSERT INTO server_devices (id, user_id, name, platform, created_at, last_seen_at, revoked_at)
            VALUES (?, ?, ?, ?, ?, ?, NULL)
            """,
            bindings: [
                .text(id), .text(userID), .text(name), .text(platform),
                .optionalDate(date), .optionalDate(date)
            ]
        )
        return device
    }

    public func device(id: String) throws -> ServerDevice? {
        let id = try validatedIdentifier(id)
        return try database.query(
            """
            SELECT id, user_id, name, platform, created_at, last_seen_at, revoked_at
            FROM server_devices WHERE id = ?
            """,
            bindings: [.text(id)],
            map: mapDevice(row:)
        ).first
    }

    public func devices(userID: String, includeRevoked: Bool = false) throws -> [ServerDevice] {
        let userID = try validatedIdentifier(userID)
        let revokedPredicate = includeRevoked ? "" : "AND revoked_at IS NULL"
        return try database.query(
            """
            SELECT id, user_id, name, platform, created_at, last_seen_at, revoked_at
            FROM server_devices
            WHERE user_id = ? \(revokedPredicate)
            ORDER BY last_seen_at DESC, created_at DESC
            """,
            bindings: [.text(userID)],
            map: mapDevice(row:)
        )
    }

    @discardableResult
    public func createSession(
        id: String = UUID().uuidString,
        userID: String,
        deviceID: String,
        accessTokenDigest: String,
        refreshTokenDigest: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date,
        createdAt: Date = Date()
    ) throws -> ServerAuthSession {
        let id = try validatedIdentifier(id)
        let userID = try validatedIdentifier(userID)
        let deviceID = try validatedIdentifier(deviceID)
        let accessDigest = try validatedTokenDigest(accessTokenDigest)
        let refreshDigest = try validatedTokenDigest(refreshTokenDigest)
        guard accessDigest != refreshDigest else { throw ServerIdentityRepositoryError.invalidTokenDigest }
        guard accessExpiresAt > createdAt, refreshExpiresAt > accessExpiresAt else {
            throw ServerIdentityRepositoryError.invalidExpiration
        }
        guard let owner = try user(id: userID), !owner.isDisabled else {
            throw ServerIdentityRepositoryError.userNotFound
        }
        guard let device = try device(id: deviceID) else {
            throw ServerIdentityRepositoryError.deviceNotFound
        }
        guard device.userID == userID else { throw ServerIdentityRepositoryError.deviceOwnershipMismatch }
        guard device.revokedAt == nil else { throw ServerIdentityRepositoryError.deviceNotFound }

        let session = ServerAuthSession(
            id: id, userID: userID, deviceID: deviceID,
            accessExpiresAt: accessExpiresAt, refreshExpiresAt: refreshExpiresAt,
            createdAt: createdAt, lastUsedAt: createdAt
        )
        try database.transaction {
            try database.execute(
                """
                INSERT INTO server_auth_sessions (
                  id, user_id, device_id, access_token_digest, refresh_token_digest,
                  access_expires_at, refresh_expires_at, created_at, last_used_at, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                bindings: [
                    .text(id), .text(userID), .text(deviceID), .text(accessDigest), .text(refreshDigest),
                    .optionalDate(accessExpiresAt), .optionalDate(refreshExpiresAt),
                    .optionalDate(createdAt), .optionalDate(createdAt)
                ]
            )
            try database.execute(
                "UPDATE server_devices SET last_seen_at = ? WHERE id = ?",
                bindings: [.optionalDate(createdAt), .text(deviceID)]
            )
        }
        return session
    }

    public func activeSession(accessTokenDigest: String, at date: Date = Date()) throws -> ServerAuthSession? {
        let digest = try validatedTokenDigest(accessTokenDigest)
        return try database.query(
            """
            SELECT session.id, session.user_id, session.device_id, session.access_expires_at,
                   session.refresh_expires_at, session.created_at, session.last_used_at, session.revoked_at
            FROM server_auth_sessions AS session
            JOIN server_users AS user ON user.id = session.user_id
            JOIN server_devices AS device ON device.id = session.device_id
            WHERE session.access_token_digest = ?
              AND session.revoked_at IS NULL
              AND device.revoked_at IS NULL
              AND user.is_disabled = 0
              AND session.access_expires_at > ?
            LIMIT 1
            """,
            bindings: [.text(digest), .optionalDate(date)],
            map: mapSession(row:)
        ).first
    }

    public func activeSession(refreshTokenDigest: String, at date: Date = Date()) throws -> ServerAuthSession? {
        let digest = try validatedTokenDigest(refreshTokenDigest)
        return try database.query(
            """
            SELECT session.id, session.user_id, session.device_id, session.access_expires_at,
                   session.refresh_expires_at, session.created_at, session.last_used_at, session.revoked_at
            FROM server_auth_sessions AS session
            JOIN server_users AS user ON user.id = session.user_id
            JOIN server_devices AS device ON device.id = session.device_id
            WHERE session.refresh_token_digest = ?
              AND session.revoked_at IS NULL
              AND device.revoked_at IS NULL
              AND user.is_disabled = 0
              AND session.refresh_expires_at > ?
            LIMIT 1
            """,
            bindings: [.text(digest), .optionalDate(date)],
            map: mapSession(row:)
        ).first
    }

    @discardableResult
    public func rotateSession(
        refreshTokenDigest: String,
        newSessionID: String = UUID().uuidString,
        newAccessTokenDigest: String,
        newRefreshTokenDigest: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date,
        at date: Date = Date()
    ) throws -> ServerAuthSession? {
        let oldDigest = try validatedTokenDigest(refreshTokenDigest)
        guard let current = try activeSession(refreshTokenDigest: oldDigest, at: date) else { return nil }
        return try database.transaction {
            // 再次在写事务内确认，保证同一个 refresh token 只能成功轮换一次。
            guard let confirmed = try activeSession(refreshTokenDigest: oldDigest, at: date),
                  confirmed.id == current.id
            else {
                return nil
            }
            try database.execute(
                "UPDATE server_auth_sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                bindings: [.optionalDate(date), .text(current.id)]
            )
            return try createSession(
                id: newSessionID,
                userID: current.userID,
                deviceID: current.deviceID,
                accessTokenDigest: newAccessTokenDigest,
                refreshTokenDigest: newRefreshTokenDigest,
                accessExpiresAt: accessExpiresAt,
                refreshExpiresAt: refreshExpiresAt,
                createdAt: date
            )
        }
    }

    public func revokeSession(
        id: String,
        actorUserID: String? = nil,
        at date: Date = Date()
    ) throws {
        let id = try validatedIdentifier(id)
        try database.transaction {
            try database.execute(
                "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?",
                bindings: [.optionalDate(date), .text(id)]
            )
            if let actorUserID {
                try appendSecurityEvent(ServerSecurityEvent(
                    occurredAt: date,
                    category: .session,
                    action: "session.revoked",
                    outcome: .success,
                    actorUserID: actorUserID,
                    sessionID: id
                ))
            }
        }
    }

    public func sessions(
        userID: String,
        includeRevoked: Bool = false,
        at date: Date = Date()
    ) throws -> [ServerAuthSession] {
        let userID = try validatedIdentifier(userID)
        let activePredicate = includeRevoked
            ? ""
            : "AND session.revoked_at IS NULL AND device.revoked_at IS NULL AND session.refresh_expires_at > ?"
        var bindings: [SQLiteValue] = [.text(userID)]
        if !includeRevoked { bindings.append(.optionalDate(date)) }
        return try database.query(
            """
            SELECT session.id, session.user_id, session.device_id, session.access_expires_at,
                   session.refresh_expires_at, session.created_at, session.last_used_at, session.revoked_at
            FROM server_auth_sessions AS session
            JOIN server_devices AS device ON device.id = session.device_id
            WHERE session.user_id = ? \(activePredicate)
            ORDER BY session.last_used_at DESC, session.created_at DESC
            """,
            bindings: bindings,
            map: mapSession(row:)
        )
    }

    public func revokeAllSessions(
        userID: String,
        actorUserID: String? = nil,
        at date: Date = Date()
    ) throws {
        let userID = try validatedIdentifier(userID)
        guard try user(id: userID) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        try database.transaction {
            try database.execute(
                "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                bindings: [.optionalDate(date), .text(userID)]
            )
            if let actorUserID {
                try appendSecurityEvent(ServerSecurityEvent(
                    occurredAt: date,
                    category: .session,
                    action: "sessions.revoked.all",
                    outcome: .success,
                    actorUserID: actorUserID,
                    targetUserID: userID
                ))
            }
        }
    }

    public func revokeDevice(
        id: String,
        actorUserID: String? = nil,
        at date: Date = Date()
    ) throws {
        let id = try validatedIdentifier(id)
        guard try device(id: id) != nil else { throw ServerIdentityRepositoryError.deviceNotFound }
        try database.transaction {
            try database.execute(
                "UPDATE server_devices SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?",
                bindings: [.optionalDate(date), .text(id)]
            )
            try database.execute(
                "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE device_id = ?",
                bindings: [.optionalDate(date), .text(id)]
            )
            if let actorUserID {
                try appendSecurityEvent(ServerSecurityEvent(
                    occurredAt: date,
                    category: .session,
                    action: "device.revoked",
                    outcome: .success,
                    actorUserID: actorUserID,
                    deviceID: id
                ))
            }
        }
    }

    public func setUserDisabled(id: String, disabled: Bool, at date: Date = Date()) throws {
        let id = try validatedIdentifier(id)
        if id == Self.initialAdministratorUserID {
            throw ServerIdentityRepositoryError.cannotModifyInitialAdministrator
        }
        guard try user(id: id) != nil else { throw ServerIdentityRepositoryError.userNotFound }
        try database.transaction {
            try database.execute(
                "UPDATE server_users SET is_disabled = ?, updated_at = ? WHERE id = ?",
                bindings: [.bool(disabled), .optionalDate(date), .text(id)]
            )
            if disabled {
                try database.execute(
                    "UPDATE server_auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
                    bindings: [.optionalDate(date), .text(id)]
                )
            }
        }
    }

    public func appendSecurityEvent(_ event: ServerSecurityEvent, maximumRetained: Int = 10_000) throws {
        guard (1...100_000).contains(maximumRetained) else {
            throw ServerIdentityRepositoryError.invalidIdentifier
        }
        let id = try validatedIdentifier(event.id)
        let action = try validatedAuditCode(event.action)
        let detailCode = try event.detailCode.map(validatedAuditCode)
        let actorUserID = try event.actorUserID.map(validatedIdentifier)
        let targetUserID = try event.targetUserID.map(validatedIdentifier)
        let sessionID = try event.sessionID.map(validatedIdentifier)
        let deviceID = try event.deviceID.map(validatedIdentifier)
        try database.transaction {
            try database.execute(
                """
                INSERT INTO server_security_events (
                  id, occurred_at, category, action, outcome, actor_user_id,
                  target_user_id, session_id, device_id, detail_code
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(id), .optionalDate(event.occurredAt), .text(event.category.rawValue),
                    .text(action), .text(event.outcome.rawValue), .optionalText(actorUserID),
                    .optionalText(targetUserID), .optionalText(sessionID), .optionalText(deviceID),
                    .optionalText(detailCode)
                ]
            )
            try database.execute(
                """
                DELETE FROM server_security_events
                WHERE id IN (
                  SELECT id FROM server_security_events
                  ORDER BY occurred_at DESC, id DESC
                  LIMIT -1 OFFSET ?
                )
                """,
                bindings: [.int(Int64(maximumRetained))]
            )
        }
    }

    public func securityEvents(limit: Int = 100) throws -> [ServerSecurityEvent] {
        guard (1...500).contains(limit) else { throw ServerIdentityRepositoryError.invalidIdentifier }
        return try database.query(
            """
            SELECT id, occurred_at, category, action, outcome, actor_user_id,
                   target_user_id, session_id, device_id, detail_code
            FROM server_security_events
            ORDER BY occurred_at DESC, id DESC
            LIMIT ?
            """,
            bindings: [.int(Int64(limit))]
        ) { row in
            ServerSecurityEvent(
                id: row.string(0) ?? "",
                occurredAt: row.date(1) ?? Date(),
                category: ServerSecurityEventCategory(rawValue: row.string(2) ?? "") ?? .identity,
                action: row.string(3) ?? "unknown",
                outcome: ServerSecurityEventOutcome(rawValue: row.string(4) ?? "") ?? .failure,
                actorUserID: row.string(5),
                targetUserID: row.string(6),
                sessionID: row.string(7),
                deviceID: row.string(8),
                detailCode: row.string(9)
            )
        }
    }

    private func roleExists(id: String) throws -> Bool {
        try database.query(
            "SELECT COUNT(*) FROM server_roles WHERE id = ?",
            bindings: [.text(id)]
        ) { $0.int(0) ?? 0 }.first == 1
    }

    private func validatedIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, (1...128).contains(trimmed.utf8.count),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServerIdentityRepositoryError.invalidIdentifier
        }
        return trimmed
    }

    private func validatedUsername(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, (1...64).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            throw ServerIdentityRepositoryError.invalidUsername
        }
        return trimmed
    }

    public static func normalizeUsername(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func validatedDisplayValue(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServerIdentityRepositoryError.invalidDisplayValue
        }
        return trimmed
    }

    private func validatedTokenDigest(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ServerIdentityRepositoryError.invalidTokenDigest
        }
        return normalized
    }

    private func validatedAuditCode(_ value: String) throws -> String {
        guard (1...64).contains(value.utf8.count),
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }) else {
            throw ServerIdentityRepositoryError.invalidIdentifier
        }
        return value
    }

    private static func isValidArgon2idEncodedHash(_ value: String) -> Bool {
        (32...1024).contains(value.utf8.count) &&
            value.hasPrefix("$argon2id$") &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isCoherent(_ grant: ServerLibraryGrant) -> Bool {
        (!grant.canPlay || grant.canView) &&
            (!grant.canDownload || grant.canPlay) &&
            (!grant.canEditMetadata || grant.canView) &&
            (!grant.canDeleteItems || grant.canView)
    }

    private func mapUser(row: SQLiteRow) -> ServerUser {
        ServerUser(
            id: row.string(0) ?? "",
            username: row.string(1) ?? "",
            displayName: row.string(2) ?? "",
            isDisabled: row.bool(3),
            requiresInitialPassword: row.bool(4),
            createdAt: row.date(5) ?? Date(),
            updatedAt: row.date(6) ?? Date()
        )
    }

    private func mapDevice(row: SQLiteRow) -> ServerDevice {
        ServerDevice(
            id: row.string(0) ?? "",
            userID: row.string(1) ?? "",
            name: row.string(2) ?? "",
            platform: row.string(3) ?? "",
            createdAt: row.date(4) ?? Date(),
            lastSeenAt: row.date(5) ?? Date(),
            revokedAt: row.date(6)
        )
    }

    private func mapSession(row: SQLiteRow) -> ServerAuthSession {
        ServerAuthSession(
            id: row.string(0) ?? "",
            userID: row.string(1) ?? "",
            deviceID: row.string(2) ?? "",
            accessExpiresAt: row.date(3) ?? Date(),
            refreshExpiresAt: row.date(4) ?? Date(),
            createdAt: row.date(5) ?? Date(),
            lastUsedAt: row.date(6) ?? Date(),
            revokedAt: row.date(7)
        )
    }
}
