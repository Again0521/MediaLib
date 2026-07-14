import Combine
import Foundation
import MediaLibCore

struct ServerManagedUserSnapshot: Identifiable, Equatable, Sendable {
    var user: ServerUser
    var roleID: String
    var grants: [ServerLibraryGrant]
    var activeDeviceCount: Int
    var activeSessionCount: Int

    var id: String { user.id }
}

struct ServerAdministrationSnapshot: Equatable, Sendable {
    var administrator: ServerUser
    var users: [ServerManagedUserSnapshot]
    var roles: [ServerRole]
    var devices: [ServerDevice]
    var sessions: [ServerAuthSession]
    var securityEvents: [ServerSecurityEvent]
}

struct ServerLibraryAccessSelection: Identifiable, Equatable, Sendable {
    var libraryID: String
    var canView: Bool
    var canPlay: Bool
    var canDownload: Bool

    var id: String { libraryID }
}

/// 桌面端本地服务管理状态。此 Store 从不保存密码、编码哈希、Cookie 或 token；
/// Argon2 与数据库操作都在后台执行，主线程只接收无敏感字段的状态快照。
@MainActor
final class ServerAdministrationStore: ObservableObject {
    @Published private(set) var snapshot: ServerAdministrationSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private var repository: ServerIdentityRepository?
    private let passwordHasher: ServerPasswordHasher?
    private var credentialRotationService: ServerCredentialRotationService?
    private var credentialRecoveryService: ServerLocalCredentialRecoveryService?
    private let localUserPresenceAuthorizer: any ServerLocalUserPresenceAuthorizing

    init(
        repository: ServerIdentityRepository? = nil,
        passwordHasher: ServerPasswordHasher? = try? ServerPasswordHasher(),
        credentialRotationService: ServerCredentialRotationService? = nil,
        credentialRecoveryService: ServerLocalCredentialRecoveryService? = nil,
        localUserPresenceAuthorizer: (any ServerLocalUserPresenceAuthorizing)? = nil
    ) {
        self.repository = repository
        self.passwordHasher = passwordHasher
        self.credentialRotationService = credentialRotationService
        self.credentialRecoveryService = credentialRecoveryService
        self.localUserPresenceAuthorizer = localUserPresenceAuthorizer ?? SystemServerLocalUserPresenceAuthorizer()
    }

    var isAvailable: Bool { repository != nil && passwordHasher != nil }

    var requiresInitialPassword: Bool {
        snapshot?.administrator.requiresInitialPassword ?? true
    }

    var activeDeviceCount: Int { snapshot?.devices.count ?? 0 }
    var activeSessionCount: Int { snapshot?.sessions.count ?? 0 }
    var userCount: Int { snapshot?.users.count ?? 0 }

    func configure(database: DatabaseManager?) {
        repository = database.map(ServerIdentityRepository.init(database:))
        credentialRotationService = database.flatMap { database in
            passwordHasher.map { ServerCredentialRotationService(database: database, passwordHasher: $0) }
        }
        credentialRecoveryService = database.flatMap { database in
            passwordHasher.map { ServerLocalCredentialRecoveryService(database: database, passwordHasher: $0) }
        }
        if database == nil {
            snapshot = nil
            errorMessage = "服务端身份数据库不可用。"
        }
    }

    func refresh() async {
        guard let repository else {
            snapshot = nil
            errorMessage = "服务端身份数据库不可用。"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await Self.loadSnapshot(repository: repository)
            errorMessage = nil
        } catch {
            errorMessage = "无法读取服务端身份状态，请稍后重试。"
        }
    }

    @discardableResult
    func setInitialAdministratorPassword(_ password: String) async -> Bool {
        guard !isWorking, let repository, let passwordHasher else {
            errorMessage = "服务端身份服务当前不可用。"
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let encodedHash = try await Self.hash(password, with: passwordHasher)
            try await Task.detached(priority: .utility) {
                try repository.setInitialCredential(
                    userID: ServerIdentityRepository.initialAdministratorUserID,
                    argon2idEncodedHash: encodedHash
                )
            }.value
            snapshot = try await Self.loadSnapshot(repository: repository)
            return true
        } catch let error as ServerPasswordHasherError {
            errorMessage = error.localizedDescription
        } catch ServerIdentityRepositoryError.initialCredentialAlreadySet {
            snapshot = try? await Self.loadSnapshot(repository: repository)
            errorMessage = "管理员密码已经设置；首次设置入口已关闭。"
        } catch {
            errorMessage = "无法设置管理员密码，请稍后重试。"
        }
        return false
    }

    @discardableResult
    func createUser(
        username: String,
        displayName: String,
        password: String,
        roleID: String,
        access: [ServerLibraryAccessSelection]
    ) async -> Bool {
        guard !isWorking, let repository, let passwordHasher else {
            errorMessage = "服务端身份服务当前不可用。"
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let encodedHash = try await Self.hash(password, with: passwordHasher)
            let userID = UUID().uuidString
            let grants = Self.grants(userID: userID, access: access)
            _ = try await Task.detached(priority: .utility) {
                try repository.createConfiguredUser(
                    id: userID,
                    username: username,
                    displayName: displayName,
                    roleID: roleID,
                    argon2idEncodedHash: encodedHash,
                    libraryGrants: grants,
                    actorUserID: ServerIdentityRepository.initialAdministratorUserID
                )
            }.value
            snapshot = try await Self.loadSnapshot(repository: repository)
            return true
        } catch {
            setUserOperationError(error, fallback: "无法创建服务端用户，请检查输入后重试。")
            return false
        }
    }

    @discardableResult
    func updateUser(
        id: String,
        displayName: String,
        roleID: String,
        access: [ServerLibraryAccessSelection],
        disabled: Bool
    ) async -> Bool {
        guard !isWorking, let repository else {
            errorMessage = "服务端身份服务当前不可用。"
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let grants = Self.grants(userID: id, access: access)
            try await Task.detached(priority: .utility) {
                try repository.updateManagedUser(
                    userID: id,
                    displayName: displayName,
                    roleID: roleID,
                    libraryGrants: grants,
                    disabled: disabled,
                    actorUserID: ServerIdentityRepository.initialAdministratorUserID
                )
            }.value
            snapshot = try await Self.loadSnapshot(repository: repository)
            return true
        } catch {
            setUserOperationError(error, fallback: "无法更新用户权限，请刷新后重试。")
            return false
        }
    }

    @discardableResult
    func resetPassword(userID: String, password: String) async -> Bool {
        guard !isWorking, let repository, let passwordHasher else {
            errorMessage = "服务端身份服务当前不可用。"
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let encodedHash = try await Self.hash(password, with: passwordHasher)
            try await Task.detached(priority: .utility) {
                try repository.resetCredential(
                    userID: userID,
                    argon2idEncodedHash: encodedHash,
                    actorUserID: ServerIdentityRepository.initialAdministratorUserID
                )
            }.value
            snapshot = try await Self.loadSnapshot(repository: repository)
            return true
        } catch {
            setUserOperationError(error, fallback: "无法重置该用户的密码。")
            return false
        }
    }

    /// 管理员自助改密必须验证当前密码；此 Store 不保存任一密码或编码凭据。
    @discardableResult
    func changeAdministratorPassword(currentPassword: String, newPassword: String) async -> Bool {
        guard !isWorking, let repository, let credentialRotationService else {
            errorMessage = "服务端身份服务当前不可用。"
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try credentialRotationService.changePassword(
                    userID: ServerIdentityRepository.initialAdministratorUserID,
                    currentPassword: currentPassword,
                    newPassword: newPassword
                )
            }.value
            snapshot = try await Self.loadSnapshot(repository: repository)
            return true
        } catch let error as ServerCredentialRotationError {
            errorMessage = error.localizedDescription
        } catch let error as ServerPasswordHasherError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "无法修改管理员密码，请稍后重试。"
        }
        return false
    }

    /// 忘记密码恢复只允许桌面端调用：先由 macOS 验证用户存在性，再等待服务进程
    /// 确实停止，最后进入 Core 的原子恢复边界。任何口令都不写入 Published 状态。
    @discardableResult
    func recoverAdministratorPassword(
        newPassword: String,
        prepareForRecovery: @MainActor () async -> Bool
    ) async -> Bool {
        guard (12...1_024).contains(newPassword.utf8.count) else {
            errorMessage = ServerPasswordHasherError.passwordLengthInvalid.localizedDescription
            return false
        }
        guard !isWorking, let repository, let credentialRecoveryService else {
            errorMessage = "服务端身份服务当前不可用。"
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            guard try await localUserPresenceAuthorizer.authorizeAdministratorRecovery() else {
                errorMessage = "未完成 Mac 用户身份验证，管理员密码没有改变。"
                return false
            }
            guard await prepareForRecovery() else {
                errorMessage = "服务进程未能安全停止，管理员密码没有改变。"
                return false
            }
            try await Task.detached(priority: .userInitiated) {
                try credentialRecoveryService.recoverAdministratorPassword(newPassword: newPassword)
            }.value
            snapshot = try await Self.loadSnapshot(repository: repository)
            return true
        } catch let error as ServerLocalCredentialRecoveryError {
            errorMessage = error.localizedDescription
        } catch let error as ServerPasswordHasherError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "未完成 Mac 用户身份验证，管理员密码没有改变。"
        }
        return false
    }

    func revokeSession(id: String) async {
        await performRevocation {
            try $0.revokeSession(
                id: id,
                actorUserID: ServerIdentityRepository.initialAdministratorUserID
            )
        }
    }

    func revokeDevice(id: String) async {
        await performRevocation {
            try $0.revokeDevice(
                id: id,
                actorUserID: ServerIdentityRepository.initialAdministratorUserID
            )
        }
    }

    func revokeAllSessions(userID: String = ServerIdentityRepository.initialAdministratorUserID) async {
        await performRevocation {
            try $0.revokeAllSessions(
                userID: userID,
                actorUserID: ServerIdentityRepository.initialAdministratorUserID
            )
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func performRevocation(
        _ operation: @escaping @Sendable (ServerIdentityRepository) throws -> Void
    ) async {
        guard !isWorking, let repository else {
            errorMessage = "服务端身份服务当前不可用。"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await Task.detached(priority: .utility) {
                try operation(repository)
            }.value
            snapshot = try await Self.loadSnapshot(repository: repository)
        } catch {
            errorMessage = "无法撤销所选会话或设备，请刷新后重试。"
        }
    }

    private func setUserOperationError(_ error: Error, fallback: String) {
        if let repositoryError = error as? ServerIdentityRepositoryError {
            errorMessage = repositoryError.localizedDescription
        } else if let passwordError = error as? ServerPasswordHasherError {
            errorMessage = passwordError.localizedDescription
        } else {
            errorMessage = fallback
        }
    }

    private nonisolated static func hash(
        _ password: String,
        with hasher: ServerPasswordHasher
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try hasher.hash(password: password)
        }.value
    }

    private nonisolated static func grants(
        userID: String,
        access: [ServerLibraryAccessSelection]
    ) -> [ServerLibraryGrant] {
        access.filter(\.canView).map {
            ServerLibraryGrant(
                userID: userID,
                libraryID: $0.libraryID,
                canView: true,
                canPlay: $0.canPlay,
                canDownload: $0.canDownload
            )
        }
    }

    private nonisolated static func loadSnapshot(
        repository: ServerIdentityRepository
    ) async throws -> ServerAdministrationSnapshot {
        try await Task.detached(priority: .utility) {
            guard let administrator = try repository.user(
                id: ServerIdentityRepository.initialAdministratorUserID
            ) else {
                throw ServerIdentityRepositoryError.userNotFound
            }
            let users = try repository.users()
            let managedUsers = try users.map { user in
                ServerManagedUserSnapshot(
                    user: user,
                    roleID: try repository.roleIDs(userID: user.id).first ?? "",
                    grants: try repository.libraryGrants(userID: user.id),
                    activeDeviceCount: try repository.devices(userID: user.id).count,
                    activeSessionCount: try repository.sessions(userID: user.id).count
                )
            }
            return ServerAdministrationSnapshot(
                administrator: administrator,
                users: managedUsers,
                roles: try repository.roles(),
                devices: try repository.devices(userID: administrator.id),
                sessions: try repository.sessions(userID: administrator.id),
                securityEvents: try repository.securityEvents(limit: 100)
            )
        }.value
    }
}
