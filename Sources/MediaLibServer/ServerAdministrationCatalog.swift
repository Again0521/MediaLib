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

    private let repository: ServerIdentityRepository

    init(repository: ServerIdentityRepository) {
        self.repository = repository
    }

    convenience init(database: DatabaseManager) {
        self.init(repository: ServerIdentityRepository(database: database))
    }

    func users() throws -> ServerManagedUsersResponse {
        let allUsers = try repository.users()
        let selected = allUsers.prefix(Self.maximumUserCount)
        let summaries = try selected.map { user in
            ServerManagedUserSummary(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                isDisabled: user.isDisabled,
                requiresInitialPassword: user.requiresInitialPassword,
                roleIDs: try repository.roleIDs(userID: user.id),
                libraryGrantCount: try repository.libraryGrants(userID: user.id).count,
                activeDeviceCount: try repository.devices(userID: user.id).count,
                activeSessionCount: try repository.sessions(userID: user.id).count
            )
        }
        return ServerManagedUsersResponse(
            totalCount: allUsers.count,
            isTruncated: allUsers.count > summaries.count,
            users: summaries
        )
    }

    func activeSessions() throws -> ServerManagedSessionsResponse {
        // 用户数本身也受固定上限约束，避免异常数据库让一次请求产生无界查询扇出。
        let users = try repository.users().prefix(Self.maximumUserCount)
        var devices: [ServerDevice] = []
        var sessions: [ServerAuthSession] = []
        for user in users {
            devices.append(contentsOf: try repository.devices(userID: user.id))
            sessions.append(contentsOf: try repository.sessions(userID: user.id))
        }
        devices.sort {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.id < $1.id
        }
        sessions.sort {
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.id < $1.id
        }
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
}
