import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 将身份仓储收敛成远程管理只读 DTO。路由负责逐操作权限判断；此处只负责固定上限、
/// 排序与脱敏映射，避免 Web/Mlink 直接编码数据库实体。
final class ServerAdministrationCatalog: @unchecked Sendable {
    static let maximumUserCount = 200
    static let maximumDeviceCount = 500
    static let maximumSessionCount = 500
    static let maximumSecurityEventCount = 100
    static let maximumSourceCount = 500

    private let repository: ServerIdentityRepository
    private let sourceRepository: SourceRepository?
    private let passwordHasher: ServerPasswordHasher?

    init(
        repository: ServerIdentityRepository,
        sourceRepository: SourceRepository? = nil,
        passwordHasher: ServerPasswordHasher? = try? ServerPasswordHasher()
    ) {
        self.repository = repository
        self.sourceRepository = sourceRepository
        self.passwordHasher = passwordHasher
    }

    convenience init(database: DatabaseManager) {
        self.init(
            repository: ServerIdentityRepository(database: database),
            sourceRepository: SourceRepository(database: database)
        )
    }

    func users(limit: Int = maximumUserCount, offset: Int = 0) throws -> ServerManagedUsersResponse {
        let boundedLimit = min(max(limit, 1), Self.maximumUserCount)
        let page = try repository.managedUsers(limit: boundedLimit, offset: max(offset, 0))
        let summaries = page.users.map { aggregate in
            let user = aggregate.user
            return ServerManagedUserSummary(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                isBuiltInAdministrator: user.id == ServerIdentityRepository.initialAdministratorUserID,
                isDisabled: user.isDisabled,
                requiresInitialPassword: user.requiresInitialPassword,
                roleIDs: aggregate.roleIDs,
                libraryIDs: aggregate.libraryIDs,
                libraryGrantCount: aggregate.libraryGrantCount,
                activeDeviceCount: aggregate.activeDeviceCount,
                activeSessionCount: aggregate.activeSessionCount
            )
        }
        return ServerManagedUsersResponse(
            totalCount: page.totalCount,
            isTruncated: offset + summaries.count < page.totalCount,
            users: summaries
        )
    }

    func containsUser(id: String) throws -> Bool {
        guard Self.isSafeIdentifier(id) else { return false }
        return try repository.user(id: id) != nil
    }

    func recordPolicyUpdate(userID: String, actor: ServerRequestPrincipal) throws {
        try repository.revokeAllSessions(userID: userID, actorUserID: actor.userID)
        try repository.appendSecurityEvent(ServerSecurityEvent(
            category: .authorization,
            action: "user.policy.updated",
            outcome: .success,
            actorUserID: actor.userID,
            targetUserID: userID,
            sessionID: actor.sessionID,
            deviceID: actor.deviceID,
            detailCode: "policy.versioned.sessions.revoked"
        ))
    }

    func activeSessions() throws -> ServerManagedSessionsResponse {
        let devices = try repository.activeDevices(limit: Self.maximumDeviceCount + 1)
        let sessions = try repository.activeSessions(limit: Self.maximumSessionCount + 1)
        let selectedDevices = devices.prefix(Self.maximumDeviceCount)
        let selectedSessions = sessions.prefix(Self.maximumSessionCount)
        return ServerManagedSessionsResponse(
            isTruncated: devices.count > selectedDevices.count || sessions.count > selectedSessions.count,
            devices: selectedDevices.map {
                ServerManagedDeviceSummary(
                    id: $0.id,
                    userID: $0.userID,
                    name: $0.name,
                    platform: $0.platform,
                    createdAt: $0.createdAt,
                    lastSeenAt: $0.lastSeenAt
                )
            },
            sessions: selectedSessions.map {
                ServerManagedSessionSummary(
                    id: $0.id,
                    userID: $0.userID,
                    deviceID: $0.deviceID,
                    accessExpiresAt: $0.accessExpiresAt,
                    refreshExpiresAt: $0.refreshExpiresAt,
                    createdAt: $0.createdAt,
                    lastUsedAt: $0.lastUsedAt
                )
            }
        )
    }

    func securityEvents() throws -> ServerSecurityEventsResponse {
        let events = try repository.securityEvents(limit: Self.maximumSecurityEventCount)
        return ServerSecurityEventsResponse(
            isTruncated: events.count == Self.maximumSecurityEventCount,
            events: events.map {
                ServerSecurityEventSummary(
                    id: $0.id,
                    occurredAt: $0.occurredAt,
                    category: $0.category.rawValue,
                    action: $0.action,
                    outcome: $0.outcome.rawValue,
                    actorUserID: $0.actorUserID,
                    targetUserID: $0.targetUserID,
                    sessionID: $0.sessionID,
                    deviceID: $0.deviceID,
                    detailCode: $0.detailCode
                )
            }
        )
    }

    func sources() throws -> ServerManagedSourcesResponse? {
        guard let sourceRepository else { return nil }
        let allSources = try sourceRepository.fetchAll()
        let selected = allSources.prefix(Self.maximumSourceCount)
        let summaries = selected.map { source in
            ServerManagedSourceSummary(
                id: source.id,
                name: source.name,
                mediaType: source.mediaType.rawValue,
                sourceKind: source.sourceKind.rawValue,
                autoScan: source.autoScan,
                includeInMetadataFetch: source.includeInMetadataFetch,
                includeInHealthCheck: source.includeInHealthCheck,
                updatedAt: source.updatedAt
            )
        }
        return ServerManagedSourcesResponse(
            totalCount: allSources.count,
            isTruncated: allSources.count > summaries.count,
            sources: summaries
        )
    }

    /// 可授权的资料库，**包含保险库**。
    ///
    /// 保险库此前在这三处（列表、创建、修改）被一律过滤掉，于是它既不能被授权，
    /// 也不能被撤销——一个管理不了的资源。它的保护不来自"不出现在列表里"：网页
    /// 侧要同时满足逐库授权与"这台 Mac 上的 App 正解锁着"两个条件，缺一不可。
    func libraries() throws -> ServerManagedLibrariesResponse? {
        guard let sourceRepository else { return nil }
        let allLibraries = try sourceRepository.fetchAll()
            .sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
        let selected = allLibraries.prefix(Self.maximumSourceCount)
        return ServerManagedLibrariesResponse(
            totalCount: allLibraries.count,
            isTruncated: allLibraries.count > selected.count,
            libraries: selected.map {
                ServerManagedLibrarySummary(id: $0.id, name: $0.name, mediaType: $0.mediaType.rawValue)
            }
        )
    }

    /// 创建只能得到普通成员角色；提升至管理员或修改角色仍需专门的权限管理流程。
    /// 所选资料库必须是真实存在的来源（含保险库），并统一授予 view/play、拒绝下载与编辑权限。
    func createMember(
        username: String,
        displayName: String,
        password: String,
        libraryIDs: [String],
        actorUserID: String
    ) throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(trimmedUsername.utf8.count),
              (1...256).contains(trimmedDisplayName.utf8.count),
              (12...1_024).contains(password.utf8.count),
              libraryIDs.count <= 100,
              Set(libraryIDs).count == libraryIDs.count,
              libraryIDs.allSatisfy(Self.isSafeIdentifier)
        else { throw ServerIdentityRepositoryError.invalidIdentifier }
        guard let sourceRepository, let passwordHasher else {
            throw ServerAdministrationCatalogError.unavailable
        }
        let permittedLibraryIDs = Set(try sourceRepository.fetchAll().map(\.id))
        guard Set(libraryIDs).isSubset(of: permittedLibraryIDs) else {
            throw ServerIdentityRepositoryError.invalidIdentifier
        }

        // Argon2 成本计算始终发生在数据库事务外，明文也不保存在本 Catalog 的状态中。
        let hash = try passwordHasher.hash(password: password)
        let userID = UUID().uuidString
        let grants = libraryIDs.map {
            ServerLibraryGrant(
                userID: userID,
                libraryID: $0,
                canView: true,
                canPlay: true,
                canDownload: false
            )
        }
        _ = try repository.createConfiguredUser(
            id: userID,
            username: trimmedUsername,
            displayName: trimmedDisplayName,
            roleID: ServerIdentityRepository.memberRoleID,
            argon2idEncodedHash: hash,
            libraryGrants: grants,
            actorUserID: actorUserID
        )
    }

    func revokeSession(id: String, actorUserID: String) throws {
        try repository.revokeSession(id: id, actorUserID: actorUserID)
    }

    func setUserDisabled(id: String, disabled: Bool, actorUserID: String) throws {
        try repository.setUserDisabled(id: id, disabled: disabled, actorUserID: actorUserID)
    }

    /// 编辑普通成员的显示名与资料库访问。网页管理不允许通过此入口提升角色、
    /// 授予下载/编辑/删除权限，也不能修改内置管理员；权限变化由仓储事务撤销旧会话。
    func updateMemberAccess(
        id: String,
        displayName: String,
        libraryIDs: [String],
        actorUserID: String
    ) throws {
        guard let user = try repository.user(id: id),
              id != ServerIdentityRepository.initialAdministratorUserID,
              try repository.roleIDs(userID: id) == [ServerIdentityRepository.memberRoleID],
              let sourceRepository
        else { throw ServerIdentityRepositoryError.userNotFound }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(trimmedDisplayName.utf8.count),
              libraryIDs.count <= 100,
              Set(libraryIDs).count == libraryIDs.count,
              libraryIDs.allSatisfy(Self.isSafeIdentifier)
        else { throw ServerIdentityRepositoryError.invalidIdentifier }
        let permittedLibraryIDs = Set(try sourceRepository.fetchAll().map(\.id))
        guard Set(libraryIDs).isSubset(of: permittedLibraryIDs) else {
            throw ServerIdentityRepositoryError.invalidIdentifier
        }
        let grants = libraryIDs.map {
            ServerLibraryGrant(
                userID: id,
                libraryID: $0,
                canView: true,
                canPlay: true,
                canDownload: false
            )
        }
        try repository.updateManagedUser(
            userID: id,
            displayName: trimmedDisplayName,
            roleID: ServerIdentityRepository.memberRoleID,
            libraryGrants: grants,
            disabled: user.isDisabled,
            actorUserID: actorUserID
        )
    }

    /// 管理员只能重置普通成员密码；仓储会在同一事务中撤销其全部会话并写审计。
    func resetMemberPassword(id: String, password: String, actorUserID: String) throws {
        guard id != ServerIdentityRepository.initialAdministratorUserID,
              try repository.roleIDs(userID: id) == [ServerIdentityRepository.memberRoleID],
              let passwordHasher
        else { throw ServerIdentityRepositoryError.userNotFound }
        guard (12...1_024).contains(password.utf8.count) else {
            throw ServerIdentityRepositoryError.invalidIdentifier
        }
        let hash = try passwordHasher.hash(password: password)
        try repository.resetCredential(
            userID: id,
            argon2idEncodedHash: hash,
            actorUserID: actorUserID
        )
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.contains("/"), !value.contains("\\")
        else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}

enum ServerAdministrationCatalogError: Error {
    case unavailable
}
