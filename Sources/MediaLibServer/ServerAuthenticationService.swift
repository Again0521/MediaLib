import Foundation
import MediaLibCore
import MediaLibServerProtocol

struct ServerRequestPrincipal: Equatable, Sendable {
    let userID: String
    let deviceID: String
    let sessionID: String
    let permissions: Set<ServerPermission>
    let libraryGrants: [String: ServerLibraryGrant]

    var canManageServer: Bool { permissions.contains(.manageServer) }

    func allows(_ permission: ServerPermission, libraryID: String? = nil) -> Bool {
        guard permissions.contains(permission) else { return false }
        guard let libraryID, !canManageServer else { return true }
        guard let grant = libraryGrants[libraryID], grant.canView else { return false }
        switch permission {
        case .viewMedia: return grant.canView
        case .playMedia: return grant.canPlay
        case .downloadMedia: return grant.canDownload
        case .editMetadata: return grant.canEditMetadata
        case .deleteItems: return grant.canDeleteItems
        case .transcodePlayback: return grant.canPlay
        case .manageServer, .manageUsers, .manageLibraries, .manageSessions:
            return false
        }
    }
}

struct ServerIssuedTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
    let sessionID: String
    let deviceID: String

    init(
        accessToken: String,
        refreshToken: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date,
        sessionID: String,
        deviceID: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = "Bearer"
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.sessionID = sessionID
        self.deviceID = deviceID
    }
}

enum ServerLoginResult: Equatable, Sendable {
    case success(ServerIssuedTokens)
    case rejected
    case temporarilyLocked(until: Date)
    case initialSetupRequired
}

final class ServerAuthenticationService: @unchecked Sendable {
    typealias TokenGenerator = @Sendable () -> String

    static let accessCookieName = "MediaLIBAccess"
    static let refreshCookieName = "MediaLIBRefresh"

    private let database: DatabaseManager
    private let identityRepository: ServerIdentityRepository
    private let passwordHasher: ServerPasswordHasher
    private let accessTokenLifetime: TimeInterval
    private let refreshTokenLifetime: TimeInterval
    private let maximumFailedAttempts: Int
    private let lockDuration: TimeInterval
    private let tokenGenerator: TokenGenerator
    private let dummyHash: String

    init(
        database: DatabaseManager,
        identityRepository: ServerIdentityRepository? = nil,
        passwordHasher: ServerPasswordHasher? = nil,
        accessTokenLifetime: TimeInterval = 15 * 60,
        refreshTokenLifetime: TimeInterval = 30 * 24 * 60 * 60,
        maximumFailedAttempts: Int = 5,
        lockDuration: TimeInterval = 15 * 60,
        tokenGenerator: @escaping TokenGenerator = { ServerTokenSecurity.generateToken() }
    ) throws {
        let hasher = try passwordHasher ?? ServerPasswordHasher()
        guard accessTokenLifetime > 0,
              refreshTokenLifetime > accessTokenLifetime,
              maximumFailedAttempts >= 2,
              lockDuration > 0
        else {
            throw ServerAuthenticationError.invalidConfiguration
        }
        self.database = database
        self.identityRepository = identityRepository ?? ServerIdentityRepository(database: database)
        self.passwordHasher = hasher
        self.accessTokenLifetime = accessTokenLifetime
        self.refreshTokenLifetime = refreshTokenLifetime
        self.maximumFailedAttempts = maximumFailedAttempts
        self.lockDuration = lockDuration
        self.tokenGenerator = tokenGenerator
        self.dummyHash = try hasher.hash(password: "MediaLIB-dummy-password")
    }

    func login(
        username: String,
        password: String,
        deviceName: String,
        platform: String,
        at date: Date = Date()
    ) throws -> ServerLoginResult {
        let normalized = ServerIdentityRepository.normalizeUsername(
            username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalized.isEmpty, normalized.utf8.count <= 128 else {
            _ = passwordHasher.verify(password: password, encodedHash: dummyHash)
            try recordAuthenticationEvent(action: "login.rejected", outcome: .denied, detailCode: "invalid.username", at: date)
            return .rejected
        }
        guard let record = try authenticationRecord(normalizedUsername: normalized) else {
            _ = passwordHasher.verify(password: password, encodedHash: dummyHash)
            try recordAuthenticationEvent(action: "login.rejected", outcome: .denied, detailCode: "unknown.user", at: date)
            return .rejected
        }
        guard !record.user.isDisabled else {
            _ = passwordHasher.verify(password: password, encodedHash: dummyHash)
            try recordAuthenticationEvent(
                action: "login.rejected", outcome: .denied,
                targetUserID: record.user.id, detailCode: "user.disabled", at: date
            )
            return .rejected
        }
        guard !record.user.requiresInitialPassword else {
            _ = passwordHasher.verify(password: password, encodedHash: dummyHash)
            try recordAuthenticationEvent(
                action: "login.rejected", outcome: .denied,
                targetUserID: record.user.id, detailCode: "initial.setup.required", at: date
            )
            return .initialSetupRequired
        }
        if let lockedUntil = record.lockedUntil, lockedUntil > date {
            try recordAuthenticationEvent(
                action: "login.locked", outcome: .denied,
                targetUserID: record.user.id, detailCode: "account.locked", at: date
            )
            return .temporarilyLocked(until: lockedUntil)
        }

        guard passwordHasher.verify(password: password, encodedHash: record.passwordHash) else {
            return try recordFailedLogin(
                normalizedUsername: normalized,
                expectedPasswordHash: record.passwordHash,
                at: date
            )
        }

        return try finalizeSuccessfulLogin(
            normalizedUsername: normalized,
            expectedPasswordHash: record.passwordHash,
            deviceName: deviceName,
            platform: platform,
            at: date
        )
    }

    func refresh(refreshToken: String, at date: Date = Date()) throws -> ServerIssuedTokens? {
        guard let oldDigest = validatedDigest(for: refreshToken) else {
            try recordAuthenticationEvent(
                action: "refresh.rejected", outcome: .denied, detailCode: "invalid.token", at: date
            )
            return nil
        }
        let accessToken = tokenGenerator()
        let newRefreshToken = tokenGenerator()
        guard accessToken != newRefreshToken,
              let accessDigest = validatedDigest(for: accessToken),
              let refreshDigest = validatedDigest(for: newRefreshToken)
        else {
            throw ServerAuthenticationError.tokenGenerationFailed
        }
        let accessExpiry = date.addingTimeInterval(accessTokenLifetime)
        let refreshExpiry = date.addingTimeInterval(refreshTokenLifetime)
        guard let session = try identityRepository.rotateSession(
            refreshTokenDigest: oldDigest,
            newAccessTokenDigest: accessDigest,
            newRefreshTokenDigest: refreshDigest,
            accessExpiresAt: accessExpiry,
            refreshExpiresAt: refreshExpiry,
            at: date
        ) else {
            try recordAuthenticationEvent(
                action: "refresh.rejected", outcome: .denied, detailCode: "expired.or.reused", at: date
            )
            return nil
        }
        try recordAuthenticationEvent(
            action: "refresh.succeeded",
            outcome: .success,
            actorUserID: session.userID,
            targetUserID: session.userID,
            sessionID: session.id,
            deviceID: session.deviceID,
            at: date
        )
        return ServerIssuedTokens(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            accessExpiresAt: accessExpiry,
            refreshExpiresAt: refreshExpiry,
            sessionID: session.id,
            deviceID: session.deviceID
        )
    }

    func principal(forAccessToken token: String, at date: Date = Date()) throws -> ServerRequestPrincipal? {
        guard let digest = validatedDigest(for: token),
              let session = try identityRepository.activeSession(accessTokenDigest: digest, at: date)
        else {
            return nil
        }
        let grants = try identityRepository.libraryGrants(userID: session.userID)
        return ServerRequestPrincipal(
            userID: session.userID,
            deviceID: session.deviceID,
            sessionID: session.id,
            permissions: try identityRepository.permissions(userID: session.userID),
            libraryGrants: Dictionary(uniqueKeysWithValues: grants.map { ($0.libraryID, $0) })
        )
    }

    func principal(forRequestHead requestHead: String, at date: Date = Date()) throws -> ServerRequestPrincipal? {
        let authorization = httpHeader(named: "Authorization", in: requestHead)
        let cookie = httpHeader(named: "Cookie", in: requestHead)
        let bearer = authorization.flatMap(Self.bearerToken(from:))
        let cookieToken = cookie.flatMap { Self.cookie(named: Self.accessCookieName, in: $0) }
        guard !(bearer != nil && cookieToken != nil), let token = bearer ?? cookieToken else { return nil }
        return try principal(forAccessToken: token, at: date)
    }

    /// 仅供当前认证用户读取自己的显示身份与已生效权限；不暴露会话、设备、token 或
    /// 其它用户的身份资料。用户被删除或状态失配时一律作为不可用处理。
    func currentUserProfile(for principal: ServerRequestPrincipal) throws -> ServerCurrentUserProfile? {
        guard let user = try identityRepository.user(id: principal.userID), !user.isDisabled else {
            return nil
        }
        return ServerCurrentUserProfile(
            username: user.username,
            displayName: user.displayName,
            roleIDs: try identityRepository.roleIDs(userID: user.id),
            permissionIDs: principal.permissions.map(\.rawValue)
        )
    }

    /// 当前主体的自助改密入口。目标用户只能来自已验证 principal，且轮换服务会在成功
    /// 后原子撤销该用户的所有旧会话；不提供代表其它用户或管理员恢复的远程变体。
    func changePassword(
        for principal: ServerRequestPrincipal,
        currentPassword: String,
        newPassword: String
    ) throws {
        try ServerCredentialRotationService(database: database, passwordHasher: passwordHasher)
            .changePassword(
                userID: principal.userID,
                currentPassword: currentPassword,
                newPassword: newPassword
            )
    }

    func logout(accessToken: String, at date: Date = Date()) throws {
        guard let principal = try principal(forAccessToken: accessToken, at: date) else { return }
        try identityRepository.revokeSession(id: principal.sessionID, at: date)
        try recordAuthenticationEvent(
            action: "logout.succeeded", outcome: .success,
            actorUserID: principal.userID, targetUserID: principal.userID,
            sessionID: principal.sessionID, deviceID: principal.deviceID, at: date
        )
    }

    func logout(principal: ServerRequestPrincipal, at date: Date = Date()) throws {
        try identityRepository.revokeSession(id: principal.sessionID, at: date)
        try recordAuthenticationEvent(
            action: "logout.succeeded", outcome: .success,
            actorUserID: principal.userID, targetUserID: principal.userID,
            sessionID: principal.sessionID, deviceID: principal.deviceID, at: date
        )
    }

    func refreshToken(forRequestHead requestHead: String) -> String? {
        guard let cookieHeader = httpHeader(named: "Cookie", in: requestHead) else { return nil }
        return Self.cookie(named: Self.refreshCookieName, in: cookieHeader)
    }

    private func issueTokens(userID: String, deviceID: String, at date: Date) throws -> ServerIssuedTokens {
        let accessToken = tokenGenerator()
        let refreshToken = tokenGenerator()
        guard accessToken != refreshToken,
              let accessDigest = validatedDigest(for: accessToken),
              let refreshDigest = validatedDigest(for: refreshToken)
        else {
            throw ServerAuthenticationError.tokenGenerationFailed
        }
        let accessExpiry = date.addingTimeInterval(accessTokenLifetime)
        let refreshExpiry = date.addingTimeInterval(refreshTokenLifetime)
        let session = try identityRepository.createSession(
            userID: userID,
            deviceID: deviceID,
            accessTokenDigest: accessDigest,
            refreshTokenDigest: refreshDigest,
            accessExpiresAt: accessExpiry,
            refreshExpiresAt: refreshExpiry,
            createdAt: date
        )
        return ServerIssuedTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessExpiresAt: accessExpiry,
            refreshExpiresAt: refreshExpiry,
            sessionID: session.id,
            deviceID: deviceID
        )
    }

    private func validatedDigest(for token: String) -> String? {
        guard (32...128).contains(token.utf8.count),
              token.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else {
            return nil
        }
        return ServerTokenSecurity.digest(token)
    }

    private func authenticationRecord(normalizedUsername: String) throws -> AuthenticationRecord? {
        try database.query(
            """
            SELECT user.id, user.username, user.display_name, user.is_disabled,
                   user.requires_initial_password, user.created_at, user.updated_at,
                   credential.password_hash, credential.failed_attempt_count,
                   credential.locked_until
            FROM server_users AS user
            LEFT JOIN server_credentials AS credential ON credential.user_id = user.id
            WHERE user.normalized_username = ?
            LIMIT 1
            """,
            bindings: [.text(normalizedUsername)]
        ) { row in
            AuthenticationRecord(
                user: ServerUser(
                    id: row.string(0) ?? "",
                    username: row.string(1) ?? "",
                    displayName: row.string(2) ?? "",
                    isDisabled: row.bool(3),
                    requiresInitialPassword: row.bool(4),
                    createdAt: row.date(5) ?? Date(),
                    updatedAt: row.date(6) ?? Date()
                ),
                passwordHash: row.string(7) ?? self.dummyHash,
                failedAttemptCount: row.int(8) ?? 0,
                lockedUntil: row.date(9)
            )
        }.first
    }

    /// Argon2 校验在事务外执行；校验失败后重新进入 BEGIN IMMEDIATE 读取权威计数，
    /// 使并发失败请求逐个累加，而不是以旧快照互相覆盖。
    private func recordFailedLogin(
        normalizedUsername: String,
        expectedPasswordHash: String,
        at date: Date
    ) throws -> ServerLoginResult {
        try database.transaction {
            guard let latest = try authenticationRecord(normalizedUsername: normalizedUsername),
                  latest.passwordHash == expectedPasswordHash
            else {
                try recordAuthenticationEvent(
                    action: "login.rejected", outcome: .denied,
                    detailCode: "credential.changed", at: date
                )
                return .rejected
            }
            if let lockedUntil = latest.lockedUntil, lockedUntil > date {
                try recordAuthenticationEvent(
                    action: "login.locked", outcome: .denied,
                    targetUserID: latest.user.id, detailCode: "account.locked", at: date
                )
                return .temporarilyLocked(until: lockedUntil)
            }
            guard !latest.user.isDisabled else {
                try recordAuthenticationEvent(
                    action: "login.rejected", outcome: .denied,
                    targetUserID: latest.user.id, detailCode: "user.disabled", at: date
                )
                return .rejected
            }
            let previousFailures = latest.lockedUntil.map { $0 <= date } == true
                ? 0
                : latest.failedAttemptCount
            let nextFailures = previousFailures + 1
            let nextLock = nextFailures >= maximumFailedAttempts
                ? date.addingTimeInterval(lockDuration)
                : nil
            try database.execute(
                """
                UPDATE server_credentials
                SET failed_attempt_count = ?, locked_until = ?, last_failed_at = ?
                WHERE user_id = ?
                """,
                bindings: [
                    .int(Int64(nextFailures)), .optionalDate(nextLock),
                    .optionalDate(date), .text(latest.user.id)
                ]
            )
            try recordAuthenticationEvent(
                action: nextLock == nil ? "login.rejected" : "login.locked",
                outcome: .failure,
                targetUserID: latest.user.id,
                detailCode: nextLock == nil ? "password.mismatch" : "failure.threshold",
                at: date
            )
            return nextLock.map(ServerLoginResult.temporarilyLocked(until:)) ?? .rejected
        }
    }

    /// 密码验证成功后在同一写事务内复核凭据与账号状态，再清零失败计数、
    /// 注册设备、签发会话并记录审计。并发改密/停用不能在复核后插入旧凭据会话。
    private func finalizeSuccessfulLogin(
        normalizedUsername: String,
        expectedPasswordHash: String,
        deviceName: String,
        platform: String,
        at date: Date
    ) throws -> ServerLoginResult {
        try database.transaction {
            guard let latest = try authenticationRecord(normalizedUsername: normalizedUsername),
                  latest.passwordHash == expectedPasswordHash
            else {
                try recordAuthenticationEvent(
                    action: "login.rejected", outcome: .denied,
                    detailCode: "credential.changed", at: date
                )
                return .rejected
            }
            guard !latest.user.isDisabled else {
                try recordAuthenticationEvent(
                    action: "login.rejected", outcome: .denied,
                    targetUserID: latest.user.id, detailCode: "user.disabled", at: date
                )
                return .rejected
            }
            guard !latest.user.requiresInitialPassword else {
                return .initialSetupRequired
            }
            if let lockedUntil = latest.lockedUntil, lockedUntil > date {
                try recordAuthenticationEvent(
                    action: "login.locked", outcome: .denied,
                    targetUserID: latest.user.id, detailCode: "account.locked", at: date
                )
                return .temporarilyLocked(until: lockedUntil)
            }
            try database.execute(
                """
                UPDATE server_credentials
                SET failed_attempt_count = 0, locked_until = NULL,
                    last_failed_at = NULL, last_login_at = ?
                WHERE user_id = ?
                """,
                bindings: [.optionalDate(date), .text(latest.user.id)]
            )
            let device = try identityRepository.registerDevice(
                userID: latest.user.id,
                name: deviceName,
                platform: platform,
                at: date
            )
            let tokens = try issueTokens(userID: latest.user.id, deviceID: device.id, at: date)
            try recordAuthenticationEvent(
                action: "login.succeeded",
                outcome: .success,
                actorUserID: latest.user.id,
                targetUserID: latest.user.id,
                sessionID: tokens.sessionID,
                deviceID: tokens.deviceID,
                at: date
            )
            return .success(tokens)
        }
    }

    private func recordAuthenticationEvent(
        action: String,
        outcome: ServerSecurityEventOutcome,
        actorUserID: String? = nil,
        targetUserID: String? = nil,
        sessionID: String? = nil,
        deviceID: String? = nil,
        detailCode: String? = nil,
        at date: Date
    ) throws {
        try identityRepository.appendSecurityEvent(ServerSecurityEvent(
            occurredAt: date,
            category: .authentication,
            action: action,
            outcome: outcome,
            actorUserID: actorUserID,
            targetUserID: targetUserID,
            sessionID: sessionID,
            deviceID: deviceID,
            detailCode: detailCode
        ))
    }

    private static func bearerToken(from authorization: String) -> String? {
        let components = authorization.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 2, components[0].lowercased() == "bearer" else { return nil }
        return String(components[1])
    }

    private static func cookie(named name: String, in header: String) -> String? {
        let matches = header.split(separator: ";").compactMap { component -> String? in
            let pair = component.trimmingCharacters(in: .whitespaces)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let key = pair[..<separator]
            guard key == name else { return nil }
            return String(pair[pair.index(after: separator)...])
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private struct AuthenticationRecord {
        let user: ServerUser
        let passwordHash: String
        let failedAttemptCount: Int
        let lockedUntil: Date?
    }
}

enum ServerAuthenticationError: Error, LocalizedError {
    case invalidConfiguration
    case tokenGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "服务端认证参数无效。"
        case .tokenGenerationFailed: "无法安全生成服务端会话。"
        }
    }
}
