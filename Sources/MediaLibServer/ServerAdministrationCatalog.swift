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
    private let experienceRepository: ServerExperienceRepository?

    init(
        repository: ServerIdentityRepository,
        sourceRepository: SourceRepository? = nil,
        passwordHasher: ServerPasswordHasher? = try? ServerPasswordHasher(),
        experienceRepository: ServerExperienceRepository? = nil
    ) {
        self.repository = repository
        self.sourceRepository = sourceRepository
        self.passwordHasher = passwordHasher
        self.experienceRepository = experienceRepository
    }

    convenience init(database: DatabaseManager) {
        self.init(
            repository: ServerIdentityRepository(database: database),
            sourceRepository: SourceRepository(database: database),
            experienceRepository: ServerExperienceRepository(database: database)
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

    func recordRuntimeConfigurationApply(
        accepted: Bool,
        actor: ServerRequestPrincipal,
        detailCode: String
    ) throws {
        try repository.appendSecurityEvent(ServerSecurityEvent(
            category: .authorization,
            action: "runtime.configuration.apply",
            outcome: accepted ? .success : .failure,
            actorUserID: actor.userID,
            targetUserID: actor.userID,
            sessionID: actor.sessionID,
            deviceID: actor.deviceID,
            detailCode: detailCode
        ))
    }

    func recordDiagnosticExport(actor: ServerRequestPrincipal) throws {
        try repository.appendSecurityEvent(ServerSecurityEvent(
            category: .authorization,
            action: "diagnostics.exported",
            outcome: .success,
            actorUserID: actor.userID,
            targetUserID: actor.userID,
            sessionID: actor.sessionID,
            deviceID: actor.deviceID,
            detailCode: "redacted.json"
        ))
    }

    func activeSessions(
        limit: Int = 100,
        offset: Int = 0,
        searchText: String? = nil
    ) throws -> ServerManagedSessionsResponse {
        let boundedLimit = min(max(limit, 1), Self.maximumSessionCount)
        let boundedOffset = min(max(offset, 0), 1_000_000)
        let page = try repository.managedSessions(
            limit: boundedLimit,
            offset: boundedOffset,
            searchText: searchText
        )
        var seenDeviceIDs = Set<String>()
        let devices = page.sessions.compactMap { aggregate -> ServerManagedDeviceSummary? in
            guard seenDeviceIDs.insert(aggregate.device.id).inserted else { return nil }
            let device = aggregate.device
            return ServerManagedDeviceSummary(
                id: device.id,
                userID: device.userID,
                name: device.name,
                platform: device.platform,
                createdAt: device.createdAt,
                lastSeenAt: device.lastSeenAt
            )
        }
        return ServerManagedSessionsResponse(
            totalCount: page.totalCount,
            isTruncated: boundedOffset + page.sessions.count < page.totalCount,
            devices: devices,
            sessions: page.sessions.map {
                let session = $0.session
                return ServerManagedSessionSummary(
                    id: session.id,
                    userID: session.userID,
                    deviceID: session.deviceID,
                    accessExpiresAt: session.accessExpiresAt,
                    refreshExpiresAt: session.refreshExpiresAt,
                    createdAt: session.createdAt,
                    lastUsedAt: session.lastUsedAt,
                    username: $0.username,
                    displayName: $0.displayName
                )
            }
        )
    }

    func securityEvents(
        limit: Int = ServerAdministrationCatalog.maximumSecurityEventCount,
        offset: Int = 0,
        category: ServerSecurityEventCategory? = nil,
        outcome: ServerSecurityEventOutcome? = nil,
        searchText: String? = nil
    ) throws -> ServerSecurityEventsResponse {
        if let retentionHours = try experienceRepository?.operationalSettings().value.telemetryRetentionHours {
            let cutoff = Date().addingTimeInterval(-Double(retentionHours) * 3_600)
            try repository.pruneSecurityEvents(before: cutoff)
        }
        let page = try repository.managedSecurityEvents(
            limit: limit,
            offset: offset,
            category: category,
            outcome: outcome,
            searchText: searchText
        )
        return ServerSecurityEventsResponse(
            totalCount: page.totalCount,
            isTruncated: offset + page.events.count < page.totalCount,
            events: page.events.map {
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

    func sources(
        limit: Int = maximumSourceCount,
        offset: Int = 0,
        searchText: String? = nil
    ) throws -> ServerManagedSourcesResponse? {
        guard let sourceRepository else { return nil }
        let normalizedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allSources = try sourceRepository.fetchAll().filter { source in
            guard let normalizedSearch, !normalizedSearch.isEmpty else { return true }
            return [source.id, source.name, source.mediaType.rawValue, source.sourceKind.rawValue]
                .contains { $0.localizedCaseInsensitiveContains(normalizedSearch) }
        }.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        let boundedOffset = max(offset, 0)
        let boundedLimit = min(max(limit, 1), Self.maximumSourceCount)
        let selected = boundedOffset < allSources.count
            ? Array(allSources.dropFirst(boundedOffset).prefix(boundedLimit))
            : []
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
            isTruncated: boundedOffset + summaries.count < allSources.count,
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
