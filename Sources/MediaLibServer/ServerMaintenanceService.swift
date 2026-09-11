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

struct ServerMaintenanceServiceHooks: @unchecked Sendable {
    var beforeOperationStart: @Sendable (ServerJob) throws -> Void
    var beforeRunningPersistence: @Sendable (ServerJob) throws -> Void
    var beforeTerminalPersistence: @Sendable (ServerJob) throws -> Void

    init(
        beforeOperationStart: @escaping @Sendable (ServerJob) throws -> Void = { _ in },
        beforeRunningPersistence: @escaping @Sendable (ServerJob) throws -> Void = { _ in },
        beforeTerminalPersistence: @escaping @Sendable (ServerJob) throws -> Void = { _ in }
    ) {
        self.beforeOperationStart = beforeOperationStart
        self.beforeRunningPersistence = beforeRunningPersistence
        self.beforeTerminalPersistence = beforeTerminalPersistence
    }

    static let live = ServerMaintenanceServiceHooks()
}

private struct ServerMaintenanceOperationResult: Sendable {
    let state: ServerJobState
    let resultCode: String
    let auditAction: String
    let auditOutcome: ServerSecurityEventOutcome
    let auditDetailCode: String
}

/// Fields owned by a local file/tag/NFO scan. User playback state, ratings,
/// correction history, timestamps, and remote identifiers are deliberately
/// excluded so a no-op reload is not reported as a metadata change.
private struct ServerLocalMetadataSnapshot: Equatable, Sendable {
    let type: MediaType
    let title: String
    let originalTitle: String?
    let artist: String?
    let album: String?
    let trackNumber: Int?
    let year: Int?
    let overview: String?
    let genre: String?
    let posterPath: String?
    let backdropPath: String?
    let parentID: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let filePath: String?
    let fileSize: Int64?
    let videoCodec: String?
    let audioCodec: String?
    let resolution: String?
    let duration: Double?
    let loudnessTrackGainDB: Double?
    let loudnessAlbumGainDB: Double?
    let loudnessTrackPeak: Double?
    let loudnessAlbumPeak: Double?
    let metadataProvider: String?
    let hasLyrics: Bool

    init(_ item: MediaItem) {
        type = item.type
        title = item.title
        originalTitle = item.originalTitle
        artist = item.artist
        album = item.album
        trackNumber = item.trackNumber
        year = item.year
        overview = item.overview
        genre = item.genre
        posterPath = item.posterPath
        backdropPath = item.backdropPath
        parentID = item.parentID
        seasonNumber = item.seasonNumber
        episodeNumber = item.episodeNumber
        filePath = item.filePath
        fileSize = item.fileSize
        videoCodec = item.videoCodec
        audioCodec = item.audioCodec
        resolution = item.resolution
        duration = item.duration
        loudnessTrackGainDB = item.loudnessTrackGainDB
        loudnessAlbumGainDB = item.loudnessAlbumGainDB
        loudnessTrackPeak = item.loudnessTrackPeak
        loudnessAlbumPeak = item.loudnessAlbumPeak
        metadataProvider = item.metadataProvider
        hasLyrics = item.hasLyrics
    }
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
    private let restoreAllowed: @Sendable () -> Bool
    private let securityEventAppender: @Sendable (ServerSecurityEvent) throws -> Void
    private let hooks: ServerMaintenanceServiceHooks
    private let operationLock = NSLock()
    private var operationTail: Task<Void, Never>?
    private var acceptingJobs = false
    private var preparedForServing = false
    private var storedDiagnosticCode: String?

    init(
        database: DatabaseManager,
        experienceRepository: ServerExperienceRepository? = nil,
        identityRepository: ServerIdentityRepository? = nil,
        backupDirectory: URL,
        transcodeCacheCleanup: @escaping @Sendable () -> Int = { 0 },
        restoreAllowed: @escaping @Sendable () -> Bool = { true },
        fileManager: FileManager = .default,
        securityEventAppender: (@Sendable (ServerSecurityEvent) throws -> Void)? = nil,
        hooks: ServerMaintenanceServiceHooks = .live
    ) {
        let resolvedExperienceRepository = experienceRepository ?? ServerExperienceRepository(database: database)
        let resolvedIdentityRepository = identityRepository ?? ServerIdentityRepository(database: database)
        self.database = database
        self.experienceRepository = resolvedExperienceRepository
        self.identityRepository = resolvedIdentityRepository
        self.sourceRepository = SourceRepository(database: database)
        self.mediaRepository = MediaRepository(database: database)
        self.backupDirectory = backupDirectory
        self.transcodeCacheCleanup = transcodeCacheCleanup
        self.restoreAllowed = restoreAllowed
        self.fileManager = fileManager
        self.securityEventAppender = securityEventAppender ?? { event in
            try resolvedIdentityRepository.appendSecurityEvent(event)
        }
        self.hooks = hooks
    }

    var diagnosticCode: String? {
        operationLock.withLock { storedDiagnosticCode }
    }

    func stopAcceptingNewJobs() {
        operationLock.withLock { acceptingJobs = false }
    }

    /// Stops admission and gives already committed work a bounded opportunity to finish.
    /// Anything still queued/running after process exit is explained by startup recovery.
    @discardableResult
    func shutdown(waitTimeout: TimeInterval = 5) -> Bool {
        let tail = operationLock.withLock { () -> Task<Void, Never>? in
            acceptingJobs = false
            return operationTail
        }
        guard let tail else { return true }
        let completion = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await tail.value
            completion.signal()
        }
        return completion.wait(timeout: .now() + max(0, waitTimeout)) == .success
    }

    func prepareForServing() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        if preparedForServing { return }
        do {
            try recoverInterruptedJobsFromPreviousExecutor()
            preparedForServing = true
            acceptingJobs = true
        } catch {
            acceptingJobs = false
            storedDiagnosticCode = "job.startup-recovery-failed"
            throw error
        }
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
        let job = ServerJob(
            kind: "database.backup",
            requestedByUserID: principal.userID
        )
        return try admitAndSchedule(
            job: job,
            principal: principal,
            requestedAction: "backup.requested",
            requestedDetailCode: "job.queued",
            failureResult: .init(
                state: .failed,
                resultCode: "backup.failed",
                auditAction: "backup.failed",
                auditOutcome: .failure,
                auditDetailCode: "database.snapshot"
            )
        ) { [database, backupDirectory] _ in
            let url = try await database.createBackupAsync(in: backupDirectory, reason: "manual")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .init(
                state: .succeeded,
                resultCode: "backup.created",
                auditAction: "backup.created",
                auditOutcome: .success,
                auditDetailCode: "database.snapshot"
            )
        }
    }

    func enqueueRestore(backupID: String, requestedBy principal: ServerRequestPrincipal) throws -> ServerJob {
        guard restoreAllowed() else { throw ServerMaintenanceError.restoreHostActive }
        guard let backup = try backupFile(id: backupID) else { throw ServerMaintenanceError.backupNotFound }
        do {
            try database.validateBackupForRestore(at: backup.url)
        } catch {
            try? securityEventAppender(event(
                action: "restore.preflight",
                outcome: .failure,
                principal: principal,
                detailCode: "backup.invalid"
            ))
            throw ServerMaintenanceError.invalidBackup
        }
        let job = ServerJob(
            kind: "database.restore",
            requestedByUserID: principal.userID
        )
        return try admitAndSchedule(
            job: job,
            principal: principal,
            requestedAction: "restore.requested",
            requestedDetailCode: "job.queued",
            failureResult: .init(
                state: .failed,
                resultCode: "restore.failed",
                auditAction: "restore.failed",
                auditOutcome: .failure,
                auditDetailCode: "database.snapshot"
            )
        ) { [database, backupDirectory, experienceRepository, securityEventAppender] running in
            try database.restore(from: backup.url, safetyBackupDirectory: backupDirectory)
            _ = try experienceRepository.reconcileAfterRestore(currentRestoreJob: running) { interruptedCount in
                let actorUserID = try self.identityRepository.user(id: principal.userID) == nil
                    ? nil
                    : principal.userID
                try securityEventAppender(ServerSecurityEvent(
                    category: .authorization,
                    action: "restore.snapshot-applied",
                    outcome: .success,
                    actorUserID: actorUserID,
                    sessionID: principal.sessionID,
                    deviceID: principal.deviceID,
                    detailCode: interruptedCount == 0 ? "database.snapshot" : "jobs.interrupted"
                ))
            }
            return .init(
                state: .succeeded,
                resultCode: "restore.completed",
                auditAction: "restore.completed",
                auditOutcome: .success,
                auditDetailCode: "database.snapshot"
            )
        }
    }

    func enqueueLibraryJob(kind: String, requestedBy principal: ServerRequestPrincipal) throws -> ServerJob {
        guard ["library.scan", "library.reindex", "metadata.refresh"].contains(kind) else {
            throw ServerMaintenanceError.unsupportedJob
        }
        let failureCode = kind == "metadata.refresh"
            ? "metadata.local-reload-failed"
            : "maintenance.failed"
        let job = ServerJob(
            kind: kind,
            requestedByUserID: principal.userID
        )
        return try admitAndSchedule(
            job: job,
            principal: principal,
            requestedAction: "maintenance.requested",
            requestedDetailCode: kind,
            failureResult: .init(
                state: .failed,
                resultCode: failureCode,
                auditAction: "maintenance.failed",
                auditOutcome: .failure,
                auditDetailCode: kind
            )
        ) { [weak self] running in
            guard let self else { throw ServerMaintenanceError.unavailable }
            return try await self.runLibraryJob(running)
        }
    }

    func enqueueTranscodeCacheCleanup(requestedBy principal: ServerRequestPrincipal) throws -> ServerJob {
        let job = ServerJob(
            kind: "transcode-cache.clear",
            requestedByUserID: principal.userID
        )
        return try admitAndSchedule(
            job: job,
            principal: principal,
            requestedAction: "transcode-cache.clear.requested",
            requestedDetailCode: "job.queued",
            failureResult: .init(
                state: .failed,
                resultCode: "cache.failed",
                auditAction: "transcode-cache.clear.failed",
                auditOutcome: .failure,
                auditDetailCode: "result.unknown"
            )
        ) { [transcodeCacheCleanup] _ in
            let removedSessionCount = transcodeCacheCleanup()
            return .init(
                state: .succeeded,
                resultCode: removedSessionCount == 0 ? "cache.already-empty" : "cache.cleared",
                auditAction: "transcode-cache.cleared",
                auditOutcome: .success,
                auditDetailCode: removedSessionCount == 0 ? "cache.already-empty" : "cache.sessions-removed"
            )
        }
    }

    private func runLibraryJob(_ job: ServerJob) async throws -> ServerMaintenanceOperationResult {
        if job.kind == "library.reindex" {
            // FTS5 external-content index rebuilds from the authoritative media table.
            // It does not need to touch media files or source credentials.
            try database.execute("INSERT INTO media_items_fts(media_items_fts) VALUES ('rebuild')")
            return .init(
                state: .succeeded,
                resultCode: "index.rebuilt",
                auditAction: "maintenance.completed",
                auditOutcome: .success,
                auditDetailCode: job.kind
            )
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
        var reloadedItemCount = 0
        var changedItemCount = 0
        for (index, source) in sources.enumerated() {
            let isMetadataReload = job.kind == "metadata.refresh"
            let before = isMetadataReload ? try localMetadataSnapshot(sourcePath: source.path) : [:]
            var boundedSource = source
            if isMetadataReload {
                // The standalone server is authorized only to read local tags,
                // NFO, and artwork. It never uses remote providers, source
                // write-back, or generated thumbnails for this operation.
                boundedSource.networkScrapingEnabled = false
                boundedSource.screenshotFallbackEnabled = false
                boundedSource.preferMetadataWriteToSource = false
            }
            let summary = await scanner.scan(
                source: boundedSource,
                options: isMetadataReload ? .localMetadataReload : .localLibraryScan,
                progress: { _ in }
            )
            errorCount += summary.errors.count
            reloadedItemCount += summary.importedItems
            if isMetadataReload {
                let after = try localMetadataSnapshot(sourcePath: source.path)
                changedItemCount += Self.changedMetadataItemCount(before: before, after: after)
            }
            try experienceRepository.updateRunningJobProgress(
                id: job.id,
                progress: sources.isEmpty ? 1 : Double(index + 1) / Double(sources.count)
            )
        }
        if job.kind == "metadata.refresh" {
            let resultCode: String
            if sources.isEmpty {
                resultCode = "metadata.no-eligible-sources"
            } else if errorCount > 0 {
                resultCode = reloadedItemCount > 0
                    ? "metadata.local-reload-partial"
                    : "metadata.local-reload-failed"
            } else if changedItemCount > 0 {
                resultCode = "metadata.local-reload-completed"
            } else {
                resultCode = "metadata.local-reload-no-changes"
            }
            return .init(
                state: errorCount == 0 ? .succeeded : .failed,
                resultCode: resultCode,
                auditAction: errorCount == 0 ? "maintenance.completed" : "maintenance.failed",
                auditOutcome: errorCount == 0 ? .success : .failure,
                auditDetailCode: job.kind
            )
        }
        return .init(
            state: errorCount == 0 ? .succeeded : .failed,
            resultCode: errorCount == 0
                ? (sources.isEmpty ? "scan.no-eligible-sources" : "scan.completed")
                : "scan.completed-with-errors",
            auditAction: errorCount == 0 ? "maintenance.completed" : "maintenance.failed",
            auditOutcome: errorCount == 0 ? .success : .failure,
            auditDetailCode: job.kind
        )
    }

    private func localMetadataSnapshot(sourcePath: String) throws -> [String: ServerLocalMetadataSnapshot] {
        Dictionary(uniqueKeysWithValues: try mediaRepository.fetchItems(sourcePath: sourcePath).map {
            ($0.id, ServerLocalMetadataSnapshot($0))
        })
    }

    private static func changedMetadataItemCount(
        before: [String: ServerLocalMetadataSnapshot],
        after: [String: ServerLocalMetadataSnapshot]
    ) -> Int {
        Set(before.keys).union(after.keys).reduce(into: 0) { count, id in
            if before[id] != after[id] { count += 1 }
        }
    }

    private func admitAndSchedule(
        job: ServerJob,
        principal: ServerRequestPrincipal,
        requestedAction: String,
        requestedDetailCode: String,
        failureResult: ServerMaintenanceOperationResult,
        operation: @escaping @Sendable (ServerJob) async throws -> ServerMaintenanceOperationResult
    ) throws -> ServerJob {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard acceptingJobs else { throw ServerMaintenanceError.unavailable }
        let committed: ServerJob
        do {
            committed = try experienceRepository.admitJob(job) {
                try securityEventAppender(event(
                    action: requestedAction,
                    outcome: .success,
                    principal: principal,
                    detailCode: requestedDetailCode
                ))
            }
        } catch ServerJobAdmissionError.queueFull {
            throw ServerMaintenanceError.queueFull
        } catch ServerJobAdmissionError.exclusiveJobConflict {
            throw ServerMaintenanceError.exclusiveJobActive
        } catch {
            throw error
        }

        let predecessor = operationTail
        operationTail = Task.detached(priority: .utility) { [self] in
            _ = await predecessor?.value
            await execute(
                committed,
                principal: principal,
                failureResult: failureResult,
                operation: operation
            )
        }
        return committed
    }

    private func execute(
        _ job: ServerJob,
        principal: ServerRequestPrincipal,
        failureResult: ServerMaintenanceOperationResult,
        operation: @escaping @Sendable (ServerJob) async throws -> ServerMaintenanceOperationResult
    ) async {
        let running: ServerJob
        do {
            try hooks.beforeOperationStart(job)
            try hooks.beforeRunningPersistence(job)
            guard let claimed = try experienceRepository.beginJob(id: job.id) else {
                pauseAfterLifecycleFailure(code: "job.claim-conflict")
                return
            }
            running = claimed
        } catch {
            try? experienceRepository.markLifecyclePersistenceFailure(
                id: job.id,
                expectedState: .queued,
                resultCode: "job.start-persistence-failed"
            )
            pauseAfterLifecycleFailure(code: "job.start-persistence-failed")
            return
        }

        let result: ServerMaintenanceOperationResult
        do {
            result = try await operation(running)
        } catch {
            result = failureResult
        }
        do {
            try hooks.beforeTerminalPersistence(running)
            _ = try experienceRepository.finishRunningJob(
                id: running.id,
                state: result.state,
                resultCode: result.resultCode
            ) {
                try securityEventAppender(event(
                    action: result.auditAction,
                    outcome: result.auditOutcome,
                    principal: principal,
                    detailCode: result.auditDetailCode
                ))
            }
        } catch {
            try? experienceRepository.markLifecyclePersistenceFailure(
                id: running.id,
                expectedState: .running,
                resultCode: "job.finalization-failed"
            )
            pauseAfterLifecycleFailure(code: "job.finalization-failed")
        }
    }

    private func recoverInterruptedJobsFromPreviousExecutor() throws {
        _ = try experienceRepository.interruptActiveJobs {
            try securityEventAppender(ServerSecurityEvent(
                category: .authorization,
                action: "maintenance.recovered",
                outcome: .failure,
                detailCode: "jobs.interrupted"
            ))
        }
    }

    private func pauseAfterLifecycleFailure(code: String) {
        operationLock.withLock {
            acceptingJobs = false
            storedDiagnosticCode = code
        }
    }

    private func event(
        action: String,
        outcome: ServerSecurityEventOutcome,
        principal: ServerRequestPrincipal,
        detailCode: String
    ) throws -> ServerSecurityEvent {
        let actorUserID = try identityRepository.user(id: principal.userID) == nil
            ? nil
            : principal.userID
        return ServerSecurityEvent(
            category: .authorization,
            action: action,
            outcome: outcome,
            actorUserID: actorUserID,
            sessionID: principal.sessionID,
            deviceID: principal.deviceID,
            detailCode: detailCode
        )
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
    case exclusiveJobActive
    case unavailable
    case restoreHostActive
    case backupNotFound
    case invalidBackup
    case invalidQuery
}
