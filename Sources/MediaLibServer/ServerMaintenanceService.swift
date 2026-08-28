import Foundation
import MediaLibCore

struct ServerBackupSummary: Codable, Equatable, Sendable {
    let id: String
    let kind: ServerBackupKind
    let createdAt: Date
    let byteLength: Int64
}

enum ServerBackupKind: String, Codable, CaseIterable, Sendable {
    case manual
    case automatic
    case safety
    case other
}

/// 执行不会改变媒体源配置的本机维护操作。
///
/// 文件系统路径永不跨过此边界；HTTP 层只能看到稳定的不透明 ID、时间和字节数。
/// 所有慢操作在专用串行队列执行，并通过 v30 `server_jobs` 暴露有界状态。
final class ServerMaintenanceService: @unchecked Sendable {
    private let database: DatabaseManager
    private let experienceRepository: ServerExperienceRepository
    private let identityRepository: ServerIdentityRepository
    private let sourceRepository: SourceRepository
    private let mediaRepository: MediaRepository
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let transcodeCacheCleanup: @Sendable () -> Int
    private let operationLock = NSLock()
    private var operationTail: Task<Void, Never>?

    init(
        database: DatabaseManager,
        experienceRepository: ServerExperienceRepository? = nil,
        identityRepository: ServerIdentityRepository? = nil,
        backupDirectory: URL,
        transcodeCacheCleanup: @escaping @Sendable () -> Int = { 0 },
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.experienceRepository = experienceRepository ?? ServerExperienceRepository(database: database)
        self.identityRepository = identityRepository ?? ServerIdentityRepository(database: database)
        self.sourceRepository = SourceRepository(database: database)
        self.mediaRepository = MediaRepository(database: database)
        self.backupDirectory = backupDirectory
        self.transcodeCacheCleanup = transcodeCacheCleanup
        self.fileManager = fileManager
    }

    func backups(limit: Int = 100) throws -> [ServerBackupSummary] {
        try managedBackups(limit: limit).backups
    }

    func managedBackups(
        limit: Int,
        offset: Int = 0,
        kind: ServerBackupKind? = nil
    ) throws -> (totalCount: Int, backups: [ServerBackupSummary]) {
        guard (1...100).contains(limit), (0...1_000_000).contains(offset) else {
            throw ServerMaintenanceError.invalidQuery
        }
        try secureBackupDirectory()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let directoryEntries = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let candidates = try directoryEntries.compactMap { url -> ServerBackupSummary? in
            guard isManagedBackup(url) else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return ServerBackupSummary(
                id: opaqueIdentifier(for: url.lastPathComponent),
                kind: backupKind(for: url.lastPathComponent),
                createdAt: values.creationDate ?? values.contentModificationDate ?? .distantPast,
                byteLength: Int64(values.fileSize ?? 0)
            )
        }
        .filter { kind == nil || $0.kind == kind }
        .sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
        let totalCount = candidates.count
        return (
            totalCount,
            Array(candidates.dropFirst(offset).prefix(limit))
        )
    }

    func backupFile(id: String) throws -> (url: URL, byteLength: Int64)? {
        guard isOpaqueIdentifier(id) else { return nil }
        try secureBackupDirectory()
        let candidates = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        for url in candidates where isManagedBackup(url) && opaqueIdentifier(for: url.lastPathComponent) == id {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0))
        }
        return nil
    }

    func enqueueBackup(requestedBy principal: ServerRequestPrincipal) throws -> ServerJob {
        let counts = try experienceRepository.jobStateCounts()
        let activeCount = counts[.queued, default: 0] + counts[.running, default: 0]
        guard activeCount < 8 else { throw ServerMaintenanceError.queueFull }
        let job = try experienceRepository.saveJob(ServerJob(
            kind: "database.backup",
            requestedByUserID: principal.userID
        ))
        try appendAudit(
            category: .authorization,
            action: "backup.requested",
            outcome: .success,
            principal: principal,
            detailCode: "job.queued"
        )
        enqueueOperation { [database, backupDirectory, experienceRepository, identityRepository] in
            var running = job
            running.state = .running
            running.startedAt = Date()
            _ = try? experienceRepository.saveJob(running)
            do {
                let url = try await database.createBackupAsync(in: backupDirectory, reason: "manual")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                running.state = .succeeded
                running.progress = 1
                running.resultCode = "backup.created"
                running.finishedAt = Date()
                _ = try experienceRepository.saveJob(running)
                try identityRepository.appendSecurityEvent(ServerSecurityEvent(
                    category: .authorization,
                    action: "backup.created",
                    outcome: .success,
                    actorUserID: principal.userID,
                    sessionID: principal.sessionID,
                    deviceID: principal.deviceID,
                    detailCode: "database.snapshot"
                ))
            } catch {
                running.state = .failed
                running.resultCode = "backup.failed"
                running.finishedAt = Date()
                _ = try? experienceRepository.saveJob(running)
                try? identityRepository.appendSecurityEvent(ServerSecurityEvent(
                    category: .authorization,
                    action: "backup.failed",
                    outcome: .failure,
                    actorUserID: principal.userID,
                    sessionID: principal.sessionID,
                    deviceID: principal.deviceID,
                    detailCode: "database.snapshot"
                ))
            }
        }
        return job
    }

    func enqueueRestore(backupID: String, requestedBy principal: ServerRequestPrincipal) throws -> ServerJob {
        let counts = try experienceRepository.jobStateCounts()
        let activeCount = counts[.queued, default: 0] + counts[.running, default: 0]
        guard activeCount < 8 else { throw ServerMaintenanceError.queueFull }
        guard let backup = try backupFile(id: backupID) else { throw ServerMaintenanceError.backupNotFound }
        do {
            try database.validateBackupForRestore(at: backup.url)
        } catch {
            try? appendAudit(
                category: .authorization,
                action: "restore.preflight",
                outcome: .failure,
                principal: principal,
                detailCode: "backup.invalid"
            )
            throw ServerMaintenanceError.invalidBackup
        }
        let job = try experienceRepository.saveJob(ServerJob(
            kind: "database.restore",
            requestedByUserID: principal.userID
        ))
        try appendAudit(
            category: .authorization,
            action: "restore.requested",
            outcome: .success,
            principal: principal,
            detailCode: "job.queued"
        )
        enqueueOperation { [database, backupDirectory, experienceRepository, identityRepository] in
            var running = job
            running.state = .running
            running.startedAt = Date()
            _ = try? experienceRepository.saveJob(running)
            do {
                try database.restore(from: backup.url, safetyBackupDirectory: backupDirectory)
                // The restored snapshot may predate this job. Reinsert the stable job record
                // into the restored database before reporting success.
                running.state = .succeeded
                running.progress = 1
                running.resultCode = "restore.completed"
                running.finishedAt = Date()
                _ = try experienceRepository.saveJob(running)
                try identityRepository.appendSecurityEvent(ServerSecurityEvent(
                    category: .authorization,
                    action: "restore.completed",
                    outcome: .success,
                    actorUserID: principal.userID,
                    sessionID: principal.sessionID,
                    deviceID: principal.deviceID,
                    detailCode: "database.snapshot"
                ))
            } catch {
                running.state = .failed
                running.resultCode = "restore.failed"
                running.finishedAt = Date()
                _ = try? experienceRepository.saveJob(running)
                try? identityRepository.appendSecurityEvent(ServerSecurityEvent(
                    category: .authorization,
                    action: "restore.failed",
                    outcome: .failure,
                    actorUserID: principal.userID,
                    sessionID: principal.sessionID,
                    deviceID: principal.deviceID,
                    detailCode: "database.snapshot"
                ))
            }
        }
        return job
    }

    func enqueueLibraryJob(kind: String, requestedBy principal: ServerRequestPrincipal) throws -> ServerJob {
        guard ["library.scan", "library.reindex", "metadata.refresh"].contains(kind) else {
            throw ServerMaintenanceError.unsupportedJob
        }
        let counts = try experienceRepository.jobStateCounts()
        let activeCount = counts[.queued, default: 0] + counts[.running, default: 0]
        guard activeCount < 8 else { throw ServerMaintenanceError.queueFull }
        let job = try experienceRepository.saveJob(ServerJob(
            kind: kind,
            requestedByUserID: principal.userID
        ))
        try appendAudit(
            category: .authorization,
            action: "maintenance.requested",
            outcome: .success,
            principal: principal,
            detailCode: kind
        )
        enqueueOperation { [weak self] in
            await self?.runLibraryJob(job, principal: principal)
        }
        return job
    }

    func enqueueTranscodeCacheCleanup(requestedBy principal: ServerRequestPrincipal) throws -> ServerJob {
        let counts = try experienceRepository.jobStateCounts()
        let activeCount = counts[.queued, default: 0] + counts[.running, default: 0]
        guard activeCount < 8 else { throw ServerMaintenanceError.queueFull }
        let job = try experienceRepository.saveJob(ServerJob(
            kind: "transcode-cache.clear",
            requestedByUserID: principal.userID
        ))
        try appendAudit(
            category: .authorization,
            action: "transcode-cache.clear.requested",
            outcome: .success,
            principal: principal,
            detailCode: "job.queued"
        )
        enqueueOperation { [experienceRepository, identityRepository, transcodeCacheCleanup] in
            var running = job
            running.state = .running
            running.startedAt = Date()
            _ = try? experienceRepository.saveJob(running)
            let removedSessionCount = transcodeCacheCleanup()
            running.state = .succeeded
            running.progress = 1
            running.resultCode = removedSessionCount == 0 ? "cache.already-empty" : "cache.cleared"
            running.finishedAt = Date()
            _ = try? experienceRepository.saveJob(running)
            try? identityRepository.appendSecurityEvent(ServerSecurityEvent(
                category: .authorization,
                action: "transcode-cache.cleared",
                outcome: .success,
                actorUserID: principal.userID,
                sessionID: principal.sessionID,
                deviceID: principal.deviceID,
                detailCode: removedSessionCount == 0 ? "cache.already-empty" : "cache.sessions-removed"
            ))
        }
        return job
    }

    private func runLibraryJob(_ job: ServerJob, principal: ServerRequestPrincipal) async {
        var running = job
        running.state = .running
        running.startedAt = Date()
        _ = try? experienceRepository.saveJob(running)
        do {
            if job.kind == "library.reindex" {
                // FTS5 external-content index rebuilds from the authoritative media table.
                // It does not need to touch media files or source credentials.
                try database.execute("INSERT INTO media_items_fts(media_items_fts) VALUES ('rebuild')")
                running.state = .succeeded
                running.progress = 1
                running.resultCode = "index.rebuilt"
                running.finishedAt = Date()
                _ = try experienceRepository.saveJob(running)
                try identityRepository.appendSecurityEvent(ServerSecurityEvent(
                    category: .authorization,
                    action: "maintenance.completed",
                    outcome: .success,
                    actorUserID: principal.userID,
                    sessionID: principal.sessionID,
                    deviceID: principal.deviceID,
                    detailCode: job.kind
                ))
                return
            }
            // 网页只能触发已有本地普通媒体库的完整扫描；远程来源、URL、SMB/FTP
            // 和保险库仍由桌面宿主管理，避免 Web 进程接触来源凭据或未解锁隐私路径。
            let sources = try sourceRepository.fetchAll().filter {
                $0.sourceKind == .local && $0.mediaType != .privateCollection &&
                    (job.kind != "metadata.refresh" || $0.includeInMetadataFetch)
            }
            let scanner = MediaScanner(
                thumbnailGenerator: nil,
                mediaRepository: mediaRepository
            )
            var errorCount = 0
            for (index, source) in sources.enumerated() {
                let summary = await scanner.scan(source: source, settings: AppSettings(), progress: { _ in })
                errorCount += summary.errors.count
                running.progress = sources.isEmpty ? 1 : Double(index + 1) / Double(sources.count)
                _ = try? experienceRepository.saveJob(running)
            }
            running.state = errorCount == 0 ? .succeeded : .failed
            running.progress = 1
            let operation = job.kind == "metadata.refresh" ? "metadata" : "scan"
            running.resultCode = errorCount == 0
                ? (sources.isEmpty ? "\(operation).no-eligible-sources" : "\(operation).completed")
                : "\(operation).completed-with-errors"
            running.finishedAt = Date()
            _ = try experienceRepository.saveJob(running)
            try identityRepository.appendSecurityEvent(ServerSecurityEvent(
                category: .authorization,
                action: errorCount == 0 ? "maintenance.completed" : "maintenance.failed",
                outcome: errorCount == 0 ? .success : .failure,
                actorUserID: principal.userID,
                sessionID: principal.sessionID,
                deviceID: principal.deviceID,
                detailCode: job.kind
            ))
        } catch {
            running.state = .failed
            running.resultCode = "maintenance.failed"
            running.finishedAt = Date()
            _ = try? experienceRepository.saveJob(running)
            try? identityRepository.appendSecurityEvent(ServerSecurityEvent(
                category: .authorization,
                action: "maintenance.failed",
                outcome: .failure,
                actorUserID: principal.userID,
                sessionID: principal.sessionID,
                deviceID: principal.deviceID,
                detailCode: job.kind
            ))
        }
    }

    private func enqueueOperation(_ operation: @escaping @Sendable () async -> Void) {
        operationLock.lock()
        let predecessor = operationTail
        let task = Task.detached(priority: .utility) {
            _ = await predecessor?.value
            await operation()
        }
        operationTail = task
        operationLock.unlock()
    }

    private func appendAudit(
        category: ServerSecurityEventCategory,
        action: String,
        outcome: ServerSecurityEventOutcome,
        principal: ServerRequestPrincipal,
        detailCode: String?
    ) throws {
        try identityRepository.appendSecurityEvent(ServerSecurityEvent(
            category: category,
            action: action,
            outcome: outcome,
            actorUserID: principal.userID,
            sessionID: principal.sessionID,
            deviceID: principal.deviceID,
            detailCode: detailCode
        ))
    }

    private func secureBackupDirectory() throws {
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)
    }

    private func isManagedBackup(_ url: URL) -> Bool {
        let standardizedParent = url.deletingLastPathComponent().standardizedFileURL
        return standardizedParent == backupDirectory.standardizedFileURL
            && url.pathExtension == "sqlite"
            && url.lastPathComponent.hasPrefix("MediaLib-")
    }

    private func backupKind(for fileName: String) -> ServerBackupKind {
        if fileName.contains("-manual-") { return .manual }
        if fileName.contains("-auto-pre-restore-") { return .safety }
        if fileName.contains("-auto-pre-migration-") { return .automatic }
        return .other
    }

    private func isOpaqueIdentifier(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// 两个独立种子的 FNV-1a 64 位摘要。这里的 ID 只用于隐藏文件名与阻止路径输入，
    /// 不承担鉴权；真正的授权仍在每次 HTTP 请求上完成。
    private func opaqueIdentifier(for value: String) -> String {
        func digest(seed: UInt64) -> UInt64 {
            value.utf8.reduce(seed) { partial, byte in
                (partial ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        return String(format: "%016llx%016llx", digest(seed: 14_695_981_039_346_656_037), digest(seed: 7_807_822_957_089_402_873))
    }
}

enum ServerMaintenanceError: Error, Equatable {
    case unsupportedJob
    case queueFull
    case backupNotFound
    case invalidBackup
    case invalidQuery
}
