import Foundation
import MediaLibCore

/// Security-sensitive administration mutations extracted from the main HTTP router.
///
/// The caller supplies the existing management rate-limit bucket. Method checks deliberately run
/// before that closure, preserving the previous behavior where an unsupported method cannot spend
/// a mutation token. CSRF remains enforced by the transport request-security policy before routing.
struct ServerAdministrationMutationHandler {
    private let catalog: ServerAdministrationCatalog?
    private let experienceRepository: ServerExperienceRepository?
    private let maintenanceService: ServerMaintenanceService?
    private let runtimeDiagnosticsProvider: () -> ServerRuntimeDiagnosticsSnapshot?
    private let runtimeConfigurationApplyProvider: (ServerRuntimeConfigurationMutationRequest) throws -> Bool
    private let authenticationService: ServerAuthenticationService?
    private let playbackSessionCancellationProvider: (String, ServerRequestPrincipal) -> Bool

    init(
        catalog: ServerAdministrationCatalog?,
        experienceRepository: ServerExperienceRepository?,
        maintenanceService: ServerMaintenanceService?,
        runtimeDiagnosticsProvider: @escaping () -> ServerRuntimeDiagnosticsSnapshot?,
        runtimeConfigurationApplyProvider: @escaping (ServerRuntimeConfigurationMutationRequest) throws -> Bool,
        authenticationService: ServerAuthenticationService?,
        playbackSessionCancellationProvider: @escaping (String, ServerRequestPrincipal) -> Bool
    ) {
        self.catalog = catalog
        self.experienceRepository = experienceRepository
        self.maintenanceService = maintenanceService
        self.runtimeDiagnosticsProvider = runtimeDiagnosticsProvider
        self.runtimeConfigurationApplyProvider = runtimeConfigurationApplyProvider
        self.authenticationService = authenticationService
        self.playbackSessionCancellationProvider = playbackSessionCancellationProvider
    }

    func response(
        method: String,
        path: String,
        requestHead: String,
        body: Data,
        principal: ServerRequestPrincipal,
        rateLimitResponse: (Double) -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        if path == "/api/v1/admin/settings" {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "PATCH" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(1) { return limited }
            return operationalSettingsResponse(
                requestHead: requestHead,
                body: body,
                principal: principal
            )
        }
        if path.hasPrefix("/api/v1/admin/users/"), path.hasSuffix("/policy") {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "PATCH" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(1) { return limited }
            return userPolicyResponse(
                path: path,
                requestHead: requestHead,
                body: body,
                principal: principal
            )
        }
        if path == "/api/v1/admin/runtime/validate" || path == "/api/v1/admin/runtime/apply" {
            guard method == "POST" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(path.hasSuffix("/apply") ? 3 : 1) { return limited }
            return runtimeResponse(path: path, body: body, principal: principal)
        }
        if path == "/api/v1/admin/jobs" {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "POST" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(1) { return limited }
            return jobCreationResponse(body: body, principal: principal)
        }
        if path == "/api/v1/admin/backups" {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "POST" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(3) { return limited }
            return backupCreationResponse(body: body, principal: principal)
        }
        if path.hasPrefix("/api/v1/admin/backups/"), path.hasSuffix("/restore") {
            guard method == "POST" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(4) { return limited }
            guard let backupID = backupRestoreIdentifier(from: path) else { return .badRequest() }
            return backupRestoreResponse(
                backupID: backupID,
                body: body,
                principal: principal
            )
        }
        if path == "/api/v1/admin/users" {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "POST" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(1) { return limited }
            return memberCreationResponse(body: body, principal: principal)
        }
        if path.hasPrefix("/api/v1/admin/users/") {
            guard method == "POST" else { return nil }
            if let limited = rateLimitResponse(1) { return limited }
            return memberMutationResponse(path: path, body: body, principal: principal)
        }
        if path.hasPrefix("/api/v1/admin/sessions/") {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "POST" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(1) { return limited }
            return sessionRevocationResponse(path: path, body: body, principal: principal)
        }
        if path.hasPrefix("/api/v1/admin/playback-sessions/") {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "DELETE" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(1) { return limited }
            return playbackSessionTerminationResponse(path: path, body: body, principal: principal)
        }
        if path == "/api/v1/admin/storage/transcode-cache" {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "DELETE" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse(3) { return limited }
            return transcodeCacheCleanupResponse(body: body, principal: principal)
        }
        return nil
    }

    private func operationalSettingsResponse(
        requestHead: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageServer) else { return .forbidden() }
        guard let expectedVersion = ifMatchVersion(in: requestHead) else {
            return .preconditionRequired()
        }
        guard let value = ServerStrictJSONDecoder.decode(
            ServerOperationalSettings.self,
            from: body,
            allowedKeys: [
                "schemaVersion", "transcodeEngine", "maximumTranscodeSessions",
                "defaultRemoteBitrateMbps", "temporaryStorageLimitGB", "minimumFreeDiskGB",
                "sessionIdleMinutes", "telemetryRetentionHours"
            ]
        ), value.isValid, let experienceRepository else { return .badRequest() }
        do {
            let saved = try experienceRepository.saveOperationalSettings(
                value,
                expectedVersion: expectedVersion
            )
            guard let data = ServerCommandOutput.jsonData(saved) else {
                return .serviceUnavailable()
            }
            return .json(
                body: data,
                additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"]
            )
        } catch { return experienceMutationErrorResponse(error) }
    }

    private func userPolicyResponse(
        path: String,
        requestHead: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
        guard let expectedVersion = ifMatchVersion(in: requestHead) else {
            return .preconditionRequired()
        }
        guard let userID = safeIdentifier(
            in: path,
            prefix: "/api/v1/admin/users/",
            suffix: "/policy",
            maximumByteCount: 128
        ) else { return .notFound() }
        guard let catalog, (try? catalog.containsUser(id: userID)) == true else {
            return .notFound()
        }
        guard let value = ServerStrictJSONDecoder.decode(
            ServerUserPolicy.self,
            from: body,
            allowedKeys: [
                "schemaVersion", "playbackAllowed", "remoteAccessAllowed", "directPlayAllowed",
                "remuxAllowed", "transcodeAllowed", "downloadAllowed", "maximumConcurrentStreams",
                "remoteBitrateLimitMbps", "accessStartMinute", "accessEndMinute",
                "maximumContentRating"
            ]
        ), value.isValid, let experienceRepository else { return .badRequest() }
        do {
            let saved = try experienceRepository.saveUserPolicy(
                userID: userID,
                value: value,
                expectedVersion: expectedVersion
            )
            try catalog.recordPolicyUpdate(userID: userID, actor: principal)
            guard let data = ServerCommandOutput.jsonData(saved) else {
                return .serviceUnavailable()
            }
            return .json(
                body: data,
                additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"]
            )
        } catch { return experienceMutationErrorResponse(error) }
    }

    private func memberCreationResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
        guard let request = ServerStrictJSONDecoder.decode(
            ServerAdministrationMemberCreateRequest.self,
            from: body,
            allowedKeys: ["username", "displayName", "password", "libraryIDs"]
        ), let catalog else { return .badRequest() }
        guard request.libraryIDs.isEmpty || principal.permissions.contains(.manageLibraries) else {
            return .forbidden()
        }
        do {
            try catalog.createMember(
                username: request.username,
                displayName: request.displayName,
                password: request.password,
                libraryIDs: request.libraryIDs,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch ServerAdministrationCatalogError.unavailable {
            return .serviceUnavailable()
        } catch {
            return .badRequest()
        }
    }

    private func memberMutationResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
        if path.hasSuffix("/access") {
            guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
            return memberAccessResponse(path: path, body: body, principal: principal)
        }
        if path.hasSuffix("/password") {
            return memberPasswordResponse(path: path, body: body, principal: principal)
        }
        guard body.isEmpty else { return .badRequest() }
        let action: (suffix: String, disabled: Bool)
        if path.hasSuffix("/disable") {
            action = ("/disable", true)
        } else if path.hasSuffix("/enable") {
            action = ("/enable", false)
        } else {
            return .notFound()
        }
        guard let userID = safeIdentifier(
            in: path,
            prefix: "/api/v1/admin/users/",
            suffix: action.suffix
        ), let catalog else { return .notFound() }
        do {
            try catalog.setUserDisabled(
                id: userID,
                disabled: action.disabled,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch { return .notFound() }
    }

    private func memberAccessResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let userID = safeIdentifier(
            in: path,
            prefix: "/api/v1/admin/users/",
            suffix: "/access"
        ), let request = ServerStrictJSONDecoder.decode(
            ServerAdministrationMemberAccessRequest.self,
            from: body,
            allowedKeys: ["displayName", "libraryIDs"]
        ), let catalog else { return .badRequest() }
        do {
            try catalog.updateMemberAccess(
                id: userID,
                displayName: request.displayName,
                libraryIDs: request.libraryIDs,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch { return .badRequest() }
    }

    private func memberPasswordResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let userID = safeIdentifier(
            in: path,
            prefix: "/api/v1/admin/users/",
            suffix: "/password"
        ), let request = ServerStrictJSONDecoder.decode(
            ServerAdministrationPasswordResetRequest.self,
            from: body,
            allowedKeys: ["password"]
        ), (12...1_024).contains(request.password.utf8.count), let catalog
        else { return .badRequest() }
        do {
            try catalog.resetMemberPassword(
                id: userID,
                password: request.password,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch { return .badRequest() }
    }

    private func sessionRevocationResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
        guard body.isEmpty else { return .badRequest() }
        guard let sessionID = safeIdentifier(
            in: path,
            prefix: "/api/v1/admin/sessions/",
            suffix: "/revoke"
        ), let catalog else { return .notFound() }
        do {
            try catalog.revokeSession(id: sessionID, actorUserID: principal.userID)
            return .noContent()
        } catch { return .notFound() }
    }

    private func playbackSessionTerminationResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
        guard body.isEmpty,
              let sessionID = safeIdentifier(
                in: path,
                prefix: "/api/v1/admin/playback-sessions/",
                suffix: ""
              )
        else { return .notFound() }
        guard playbackSessionCancellationProvider(sessionID, principal) else { return .notFound() }
        return .noContent()
    }

    private func transcodeCacheCleanupResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageServer) else { return .forbidden() }
        guard body.isEmpty, let maintenanceService else { return .badRequest() }
        do {
            let job = try maintenanceService.enqueueTranscodeCacheCleanup(requestedBy: principal)
            guard let data = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
            return .accepted(body: data, additionalHeaders: ["Cache-Control: no-store"])
        } catch { return .serviceUnavailable() }
    }

    private func safeIdentifier(
        in path: String,
        prefix: String,
        suffix: String,
        maximumByteCount: Int = 512
    ) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encoded = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !encoded.isEmpty,
              let value = encoded.removingPercentEncoding,
              !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              value.utf8.count <= maximumByteCount,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return value
    }

    private func ifMatchVersion(in requestHead: String) -> Int? {
        guard let raw = httpHeader(named: "If-Match", in: requestHead),
              !raw.contains(","),
              !raw.hasPrefix("W/")
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let version = Int(value),
              version >= 0
        else { return nil }
        return version
    }

    private func etagHeader(_ version: Int) -> String {
        "ETag: \"\(max(version, 0))\""
    }

    private func experienceMutationErrorResponse(_ error: Error) -> LocalHTTPResponse {
        switch error {
        case ServerExperienceRepositoryError.invalidValue:
            return .badRequest()
        case let ServerExperienceRepositoryError.versionConflict(currentVersion):
            return .conflict(additionalHeaders: [etagHeader(currentVersion)])
        case ServerExperienceRepositoryError.notFound:
            return .notFound()
        default:
            return .serviceUnavailable()
        }
    }

    private func runtimeResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageServer) else { return .forbidden() }
        guard let request = ServerStrictJSONDecoder.decode(
            ServerRuntimeConfigurationMutationRequest.self,
            from: body,
            allowedKeys: [
                "currentPassword", "serverName", "port", "networkAccessMode",
                "publicOrigin", "trustedProxyAddresses"
            ]
        ) else { return .badRequest() }
        let hostControlAvailable = runtimeDiagnosticsProvider()?.hostControlAvailable == true
        let validation = ServerRuntimeConfigurationValidator.validate(
            request,
            hostControlAvailable: hostControlAvailable
        )
        guard validation.valid else {
            guard let data = ServerCommandOutput.jsonData(validation) else {
                return .serviceUnavailable()
            }
            return .jsonError(
                statusCode: 400,
                reason: "Bad Request",
                body: data,
                additionalHeaders: ["Cache-Control: no-store"]
            )
        }
        guard path.hasSuffix("/apply") else {
            guard let data = ServerCommandOutput.jsonData(validation) else {
                return .serviceUnavailable()
            }
            return .json(body: data, additionalHeaders: ["Cache-Control: no-store"])
        }
        guard hostControlAvailable else { return .serviceUnavailable() }
        guard let authenticationService,
              let password = request.currentPassword,
              (try? authenticationService.verifyCurrentPassword(
                for: principal,
                password: password,
                purpose: "runtime.apply"
              )) == true
        else { return .forbidden() }
        do {
            let accepted = try runtimeConfigurationApplyProvider(request)
            try catalog?.recordRuntimeConfigurationApply(
                accepted: accepted,
                actor: principal,
                detailCode: accepted ? "host.accepted" : "host.rejected"
            )
            guard accepted, let data = ServerCommandOutput.jsonData(validation) else {
                return .serviceUnavailable()
            }
            return .accepted(
                body: data,
                additionalHeaders: ["Cache-Control: no-store", "Retry-After: 1"]
            )
        } catch {
            try? catalog?.recordRuntimeConfigurationApply(
                accepted: false,
                actor: principal,
                detailCode: "host.transport-failed"
            )
            return .serviceUnavailable()
        }
    }

    private func jobCreationResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
        guard let request = ServerStrictJSONDecoder.decode(
            ServerJobCreationRequest.self,
            from: body,
            allowedKeys: ["kind"]
        ), request.isValid, let maintenanceService else { return .badRequest() }
        do {
            let job = try maintenanceService.enqueueLibraryJob(kind: request.kind, requestedBy: principal)
            guard let data = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
            return .created(body: data, additionalHeaders: ["Cache-Control: no-store"])
        } catch { return .serviceUnavailable() }
    }

    private func backupCreationResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageServer) else { return .forbidden() }
        guard body.isEmpty else { return .badRequest() }
        guard let maintenanceService else { return .badRequest() }
        do {
            let job = try maintenanceService.enqueueBackup(requestedBy: principal)
            guard let data = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
            return .created(body: data, additionalHeaders: ["Cache-Control: no-store"])
        } catch { return .serviceUnavailable() }
    }

    private func backupRestoreResponse(
        backupID: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageServer) else { return .forbidden() }
        guard let request = ServerStrictJSONDecoder.decode(
            ServerBackupRestoreRequest.self,
            from: body,
            allowedKeys: ["currentPassword"]
        ) else { return .badRequest() }
        guard let authenticationService,
              (try? authenticationService.verifyCurrentPassword(
                for: principal,
                password: request.currentPassword,
                purpose: "backup.restore"
              )) == true
        else { return .forbidden() }
        guard let maintenanceService else { return .serviceUnavailable() }
        do {
            let job = try maintenanceService.enqueueRestore(
                backupID: backupID,
                requestedBy: principal
            )
            guard let data = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
            return .accepted(body: data, additionalHeaders: [
                "Cache-Control: no-store",
                "Clear-Site-Data: \"cache\""
            ])
        } catch ServerMaintenanceError.backupNotFound {
            return .notFound()
        } catch ServerMaintenanceError.invalidBackup {
            return .conflict()
        } catch {
            return .serviceUnavailable()
        }
    }

    private func backupRestoreIdentifier(from path: String) -> String? {
        let prefix = "/api/v1/admin/backups/"
        let suffix = "/restore"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let value = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard value.utf8.count == 32, value.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }) else { return nil }
        return value
    }
}

private struct ServerJobCreationRequest: Decodable {
    let kind: String

    var isValid: Bool {
        ["library.scan", "library.reindex", "metadata.refresh"].contains(kind)
    }
}

private struct ServerAdministrationMemberCreateRequest: Decodable {
    let username: String
    let displayName: String
    let password: String
    let libraryIDs: [String]
}

private struct ServerAdministrationMemberAccessRequest: Decodable {
    let displayName: String
    let libraryIDs: [String]
}

private struct ServerAdministrationPasswordResetRequest: Decodable {
    let password: String
}

private struct ServerBackupRestoreRequest: Decodable {
    let currentPassword: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case currentPassword
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: ServerAdministrationDynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unexpected fields"
            ))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        currentPassword = try values.decode(String.self, forKey: .currentPassword)
        guard (1...1_024).contains(currentPassword.utf8.count) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "invalid password length"
            ))
        }
    }
}

private struct ServerAdministrationDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
