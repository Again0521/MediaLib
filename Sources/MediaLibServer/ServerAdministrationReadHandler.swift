import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Catalog-backed administration reads extracted from the main HTTP router.
///
/// The outer router still owns authentication and the independent API rate-limit bucket. This
/// handler owns each endpoint's precise permission, strict query contract, redacted catalog call
/// and HTTP mapping so a new management page cannot accidentally inherit another page's policy.
struct ServerAdministrationReadHandler {
    private let catalog: ServerAdministrationCatalog?
    private let experienceRepository: ServerExperienceRepository?
    private let maintenanceService: ServerMaintenanceService?
    private let serverName: String
    private let playbackTelemetry: ServerPlaybackTelemetry
    private let remoteAccessPolicy: ServerRemoteAccessPolicy
    private let runtimeDiagnosticsProvider: () -> ServerRuntimeDiagnosticsSnapshot?
    private let playbackSessionsProvider: () -> [ServerAdminHLSPlaybackSession]

    init(
        catalog: ServerAdministrationCatalog?,
        experienceRepository: ServerExperienceRepository?,
        maintenanceService: ServerMaintenanceService?,
        serverName: String,
        playbackTelemetry: ServerPlaybackTelemetry,
        remoteAccessPolicy: ServerRemoteAccessPolicy,
        runtimeDiagnosticsProvider: @escaping () -> ServerRuntimeDiagnosticsSnapshot?,
        playbackSessionsProvider: @escaping () -> [ServerAdminHLSPlaybackSession]
    ) {
        self.catalog = catalog
        self.experienceRepository = experienceRepository
        self.maintenanceService = maintenanceService
        self.serverName = serverName
        self.playbackTelemetry = playbackTelemetry
        self.remoteAccessPolicy = remoteAccessPolicy
        self.runtimeDiagnosticsProvider = runtimeDiagnosticsProvider
        self.playbackSessionsProvider = playbackSessionsProvider
    }

    /// Returns the independent API-read bucket cost for routes owned by this handler.
    /// Keeping recognition here prevents the outer router from maintaining a second route list.
    func rateLimitCost(for path: String) -> Double? {
        if path == "/api/v1/admin/diagnostics" { return 2 }
        if backupDownloadIdentifier(from: path) != nil { return 1 }
        if path.hasPrefix("/api/v1/admin/playback-sessions/") ||
            (path.hasPrefix("/api/v1/admin/users/") && path.hasSuffix("/policy")) {
            return 1
        }
        return [
            "/api/v1/admin/dashboard", "/api/v1/admin/settings", "/api/v1/admin/jobs",
            "/api/v1/admin/backups", "/api/v1/admin/users", "/api/v1/admin/sessions",
            "/api/v1/admin/security-events", "/api/v1/admin/logs",
            "/api/v1/admin/sources", "/api/v1/admin/libraries",
            "/api/v1/admin/lan-readiness", "/api/v1/admin/playback-telemetry",
            "/api/v1/admin/playback-sessions"
        ].contains(path) ? 1 : nil
    }

    func response(
        path: String,
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse? {
        if path == "/api/v1/admin/diagnostics" {
            return diagnosticResponse(target: target, principal: principal, omitBody: omitBody)
        }
        if let backupID = backupDownloadIdentifier(from: path) {
            return backupDownloadResponse(
                path: path,
                target: target,
                backupID: backupID,
                principal: principal,
                omitBody: omitBody
            )
        }
        if path.hasPrefix("/api/v1/admin/playback-sessions/") {
            return playbackSessionDetailResponse(
                path: path,
                target: target,
                principal: principal,
                omitBody: omitBody
            )
        }
        if path.hasPrefix("/api/v1/admin/users/"), path.hasSuffix("/policy") {
            return userPolicyResponse(
                path: path,
                target: target,
                principal: principal,
                omitBody: omitBody
            )
        }
        switch path {
        case "/api/v1/admin/dashboard":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard ServerAdministrationQueryParser.dashboard(from: target) else { return .badRequest() }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                let settings = try experienceRepository.operationalSettings()
                let jobCounts = try experienceRepository.jobStateCounts()
                let value = ServerAdminDashboardResponse(
                    serverName: serverName,
                    apiVersion: MlinkProtocol.currentAPIVersion,
                    settingsVersion: settings.version,
                    maximumTranscodeSessions: settings.value.maximumTranscodeSessions,
                    queuedJobCount: jobCounts[.queued, default: 0],
                    runningJobCount: jobCounts[.running, default: 0],
                    failedJobCount: jobCounts[.failed, default: 0],
                    recentSecurityEventCount: (try? catalog?.securityEvents().events.count) ?? 0,
                    playback: playbackTelemetry.snapshot(),
                    lan: remoteAccessPolicy.lanAccessReadiness(),
                    runtime: runtimeDiagnosticsProvider()
                )
                guard let data = ServerCommandOutput.jsonData(value) else {
                    return .serviceUnavailable()
                }
                return .json(body: data, omitBody: omitBody, additionalHeaders: ["Cache-Control: no-store"])
            } catch { return .serviceUnavailable() }

        case "/api/v1/admin/settings":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard ServerAdministrationQueryParser.settings(from: target) else { return .badRequest() }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                let value = try experienceRepository.operationalSettings()
                guard let data = ServerCommandOutput.jsonData(value) else {
                    return .serviceUnavailable()
                }
                return .json(
                    body: data,
                    omitBody: omitBody,
                    additionalHeaders: [etagHeader(value.version), "Cache-Control: no-store"]
                )
            } catch { return .serviceUnavailable() }

        case "/api/v1/admin/lan-readiness":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard target == path else { return .badRequest() }
            guard let data = ServerCommandOutput.jsonData(remoteAccessPolicy.lanAccessReadiness()) else {
                return .serviceUnavailable()
            }
            return .json(body: data, omitBody: omitBody, additionalHeaders: ["Cache-Control: no-store"])

        case "/api/v1/admin/playback-telemetry":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard target == path else { return .badRequest() }
            guard let data = ServerCommandOutput.jsonData(playbackTelemetry.snapshot()) else {
                return .serviceUnavailable()
            }
            return .json(body: data, omitBody: omitBody, additionalHeaders: ["Cache-Control: no-store"])

        case "/api/v1/admin/playback-sessions":
            guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.playbackSessions(from: target) else {
                return .badRequest()
            }
            let page = ServerAdminPlaybackSessionCatalog.page(playbackSessionsProvider(), query: query)
            guard let data = ServerCommandOutput.jsonData(page.sessions) else {
                return .serviceUnavailable()
            }
            return .json(
                body: data,
                omitBody: omitBody,
                additionalHeaders: paginationHeaders(
                    totalCount: page.totalCount,
                    offset: query.offset,
                    itemCount: page.sessions.count
                )
            )

        case "/api/v1/admin/jobs":
            guard principal.permissions.contains(.manageLibraries) ||
                    principal.permissions.contains(.manageServer)
            else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.jobs(from: target) else {
                return .badRequest()
            }
            guard let experienceRepository else { return .serviceUnavailable() }
            let libraryKinds: Set<String> = ["library.scan", "library.reindex", "metadata.refresh"]
            let serverKinds: Set<String> = ["database.backup", "database.restore", "transcode-cache.clear"]
            var allowedKinds: Set<String> = []
            if principal.permissions.contains(.manageLibraries) { allowedKinds.formUnion(libraryKinds) }
            if principal.permissions.contains(.manageServer) { allowedKinds.formUnion(serverKinds) }
            if query.scope == "library" { allowedKinds.formIntersection(libraryKinds) }
            if query.scope == "server" { allowedKinds.formIntersection(serverKinds) }
            guard query.kind.map({ allowedKinds.contains($0) }) ?? true else { return .forbidden() }
            do {
                let page = try experienceRepository.managedJobs(
                    limit: query.limit,
                    offset: query.offset,
                    state: query.state,
                    kind: query.kind,
                    searchText: query.searchText,
                    allowedKinds: allowedKinds
                )
                guard let data = ServerCommandOutput.jsonData(page.jobs) else {
                    return .serviceUnavailable()
                }
                return .json(
                    body: data,
                    omitBody: omitBody,
                    additionalHeaders: paginationHeaders(
                        totalCount: page.totalCount,
                        offset: query.offset,
                        itemCount: page.jobs.count
                    )
                )
            } catch { return .serviceUnavailable() }

        case "/api/v1/admin/backups":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.backups(from: target) else {
                return .badRequest()
            }
            guard let maintenanceService else { return .serviceUnavailable() }
            do {
                let page = try maintenanceService.managedBackups(
                    limit: query.limit,
                    offset: query.offset,
                    kind: query.kind
                )
                guard let data = ServerCommandOutput.jsonData(page.backups) else {
                    return .serviceUnavailable()
                }
                return .json(
                    body: data,
                    omitBody: omitBody,
                    additionalHeaders: paginationHeaders(
                        totalCount: page.totalCount,
                        offset: query.offset,
                        itemCount: page.backups.count
                    )
                )
            } catch { return .serviceUnavailable() }

        case "/api/v1/admin/users":
            guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.users(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.users(limit: query.limit, offset: query.offset),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/sessions":
            guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.sessions(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.activeSessions(
                    limit: query.limit,
                    offset: query.offset,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/security-events", "/api/v1/admin/logs":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.securityEvents(from: target, path: path) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.securityEvents(
                    limit: query.limit,
                    offset: query.offset,
                    category: query.category,
                    outcome: query.outcome,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/sources":
            guard principal.permissions.contains(.manageLibraries) ||
                    principal.permissions.contains(.manageServer)
            else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.sources(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.sources(
                    limit: query.limit,
                    offset: query.offset,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/libraries":
            guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
            guard ServerAdministrationQueryParser.libraries(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.libraries(),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        default:
            return nil
        }
    }

    private func diagnosticResponse(
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageServer) else { return .forbidden() }
        guard ServerAdministrationQueryParser.diagnostics(from: target) else { return .badRequest() }
        guard let catalog, let experienceRepository, let runtime = runtimeDiagnosticsProvider() else {
            return .serviceUnavailable()
        }
        do {
            try catalog.recordDiagnosticExport(actor: principal)
            let users = try catalog.users(limit: 1)
            let sessions = try catalog.activeSessions()
            let sources = try catalog.sources()
            let security = try catalog.securityEvents()
            let value = ServerRedactedDiagnosticExport(
                runtime: runtime,
                userCount: users.totalCount,
                activeDeviceCount: sessions.devices.count,
                activeSessionCount: sessions.sessions.count,
                managedSourceCount: sources?.totalCount ?? 0,
                jobs: try experienceRepository.jobs(limit: 25),
                securityEvents: security.events
            )
            guard let data = ServerCommandOutput.jsonData(value) else { return .serviceUnavailable() }
            return .json(
                body: data,
                omitBody: omitBody,
                additionalHeaders: [
                    "Cache-Control: no-store",
                    "Content-Disposition: attachment; filename=\"MediaLIB-diagnostics.json\""
                ]
            )
        } catch { return .serviceUnavailable() }
    }

    private func playbackSessionDetailResponse(
        path: String,
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
        guard target == path,
              let sessionID = decodedIdentifier(
                path: path,
                prefix: "/api/v1/admin/playback-sessions/",
                suffix: "",
                maximumByteCount: 512
              ),
              let session = playbackSessionsProvider().first(where: { $0.sessionID == sessionID }),
              let data = ServerCommandOutput.jsonData(session)
        else { return target == path ? .notFound() : .badRequest() }
        return .json(body: data, omitBody: omitBody, additionalHeaders: ["Cache-Control: no-store"])
    }

    private func userPolicyResponse(
        path: String,
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
        guard target == path else { return .badRequest() }
        guard let userID = decodedIdentifier(
            path: path,
            prefix: "/api/v1/admin/users/",
            suffix: "/policy",
            maximumByteCount: 128
        ) else { return .notFound() }
        guard let catalog, (try? catalog.containsUser(id: userID)) == true else {
            return .notFound()
        }
        guard let experienceRepository else { return .serviceUnavailable() }
        do {
            let policy = try experienceRepository.userPolicy(userID: userID)
            guard let data = ServerCommandOutput.jsonData(policy) else {
                return .serviceUnavailable()
            }
            return .json(
                body: data,
                omitBody: omitBody,
                additionalHeaders: [etagHeader(policy.version), "Cache-Control: no-store"]
            )
        } catch { return .serviceUnavailable() }
    }

    private func backupDownloadResponse(
        path: String,
        target: String,
        backupID: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard principal.permissions.contains(.manageServer) else { return .forbidden() }
        guard ServerAdministrationQueryParser.backupDownload(from: target, path: path) else {
            return .badRequest()
        }
        guard let maintenanceService,
              let backup = try? maintenanceService.backupFile(id: backupID)
        else { return .notFound() }
        if !omitBody {
            do {
                try catalog?.recordBackupDownload(actor: principal)
            } catch { return .serviceUnavailable() }
        }
        return .file(
            url: backup.url,
            byteLength: backup.byteLength,
            contentType: "application/vnd.sqlite3",
            omitBody: omitBody,
            additionalHeaders: [
                "Cache-Control: no-store",
                "Content-Disposition: attachment; filename=\"MediaLib-backup.sqlite\""
            ]
        )
    }

    private func backupDownloadIdentifier(from path: String) -> String? {
        let prefix = "/api/v1/admin/backups/"
        let suffix = "/download"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let value = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard value.utf8.count == 32, value.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }) else { return nil }
        return value
    }

    private func decodedIdentifier(
        path: String,
        prefix: String,
        suffix: String,
        maximumByteCount: Int
    ) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encoded = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !encoded.isEmpty,
              let value = encoded.removingPercentEncoding,
              !value.isEmpty,
              value.utf8.count <= maximumByteCount,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return value
    }

    private func etagHeader(_ version: Int) -> String {
        "ETag: \"\(max(version, 0))\""
    }

    private func paginationHeaders(totalCount: Int, offset: Int, itemCount: Int) -> [String] {
        let boundedTotal = max(totalCount, 0)
        let boundedOffset = max(offset, 0)
        let boundedItemCount = max(itemCount, 0)
        return [
            "Cache-Control: no-store",
            "X-MediaLIB-Total-Count: \(boundedTotal)",
            "X-MediaLIB-Is-Truncated: \(boundedOffset + boundedItemCount < boundedTotal ? "true" : "false")"
        ]
    }
}

private struct ServerAdminDashboardResponse: Encodable {
    let serverName: String
    let apiVersion: String
    let settingsVersion: Int
    let maximumTranscodeSessions: Int
    let queuedJobCount: Int
    let runningJobCount: Int
    let failedJobCount: Int
    let recentSecurityEventCount: Int
    let playback: ServerPlaybackTelemetrySnapshot
    let lan: ServerLanAccessReadiness
    let runtime: ServerRuntimeDiagnosticsSnapshot?
}
