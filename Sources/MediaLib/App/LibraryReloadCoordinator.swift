import Foundation
import MediaLibCore

/// 一次媒体库 reload 的只读输出。它是数据库快照，不拥有任何 UI 状态，也不触发后续任务。
struct LibraryReloadSnapshot: Sendable {
    let blockingQueueWaitNanoseconds: UInt64
    let sources: [MediaSource]
    let items: [MediaItem]
    let musicPlaylists: [MusicPlaylist]
    let musicSmartPlaylists: [MusicSmartPlaylist]
    let videoSmartCollections: [VideoSmartCollection]
    let videoManualCollections: [VideoManualCollection]
    let videoOfflineSubscriptions: [VideoOfflineSubscription]
    let metadataCorrectionCountsByMediaID: [String: Int]
    let metadataCorrectionRecordCount: Int
    let metadataCorrectionBatches: [MetadataCorrectionBatchSummary]
    let pendingSyncConflictCount: Int
    let pendingSyncConflicts: [SyncConflict]
    let remoteConnectorAccounts: [RemoteConnectorAccount]
    let musicProjectionSnapshot: MusicLibraryProjectionSnapshot
    let detailMetadataGapsByMediaID: [String: Set<String>]
    let detailSearchTermsByMediaID: [String: [String]]
    let detailBackdropPathsByMediaID: [String: String]
    let mediaExternalIDIndex: [String: String]
    let mediaIDsByPersonID: [String: Set<String>]
}

/// 从独立数据库连接读取完整 reload 快照。所有阻塞 I/O 都留在 BlockingIOExecutor，
/// 调用者只接收一个不可变结果，不需要知道仓储组合或 SQLite 生命周期。
/// `afterSourcesRead` 只供确定性交错测试注入另一个连接的提交。
enum LibraryReloadSnapshotLoader {
    nonisolated static func load(
        directories: AppDirectories,
        afterSourcesRead: (@Sendable () throws -> Void)? = nil
    ) async throws -> LibraryReloadSnapshot {
        try await BlockingIOExecutor.runCancellable { cancellation in
            try cancellation.checkCancellation()
            let database = try DatabaseManager(url: directories.database, backupDirectory: directories.databaseBackups)
            let sourceRepository = SourceRepository(database: database)
            let mediaRepository = MediaRepository(database: database)
            let musicPlaylistRepository = MusicPlaylistRepository(database: database)
            let musicSmartPlaylistRepository = MusicSmartPlaylistRepository(database: database)
            let videoSmartCollectionRepository = VideoSmartCollectionRepository(database: database)
            let videoManualCollectionRepository = VideoManualCollectionRepository(database: database)
            let videoOfflineSubscriptionRepository = VideoOfflineSubscriptionRepository(database: database)
            let metadataCorrectionRepository = MetadataCorrectionRepository(database: database)
            let syncConflictRepository = SyncConflictRepository(database: database)
            let remoteConnectorAccountRepository = RemoteConnectorAccountRepository(database: database)
            let mediaDetailRepository = MediaDetailRepository(database: database)
            let musicProjectionRepository = MusicLibraryProjectionRepository(database: database)

            return try database.readSnapshot {
                try cancellation.checkCancellation()
                let sources = try sourceRepository.fetchAll()
                try afterSourcesRead?()
                try cancellation.checkCancellation()
                let items = try mediaRepository.fetchAll()
                let detailCandidateIDs = items.compactMap { item -> String? in
                    guard item.parentID == nil,
                          item.type != .music,
                          item.type != .photo,
                          item.type != .homeVideo,
                          item.type != .privateCollection else { return nil }
                    return item.id
                }
                try cancellation.checkCancellation()
                let musicPlaylists = try musicPlaylistRepository.fetchAll()
                let musicSmartPlaylists = try musicSmartPlaylistRepository.fetchAll()
                let videoSmartCollections = try videoSmartCollectionRepository.fetchAll()
                let videoManualCollections = try videoManualCollectionRepository.fetchAll()
                let videoOfflineSubscriptions = try videoOfflineSubscriptionRepository.fetchAll()
                try cancellation.checkCancellation()
                let metadataCorrectionCountsByMediaID = try metadataCorrectionRepository.activeCountsByMediaID()
                let metadataCorrectionRecordCount = try metadataCorrectionRepository.activeRecordCount()
                let metadataCorrectionBatches = try metadataCorrectionRepository.fetchActiveBatches(limit: 120)
                let pendingSyncConflictCount = try syncConflictRepository.pendingCount()
                let pendingSyncConflicts = try syncConflictRepository.fetchPending(limit: 120)
                let remoteConnectorAccounts = try remoteConnectorAccountRepository.fetchAll()
                try cancellation.checkCancellation()
                let musicProjectionSnapshot = try musicProjectionRepository.fetchSnapshot()
                let detailMetadataGapsByMediaID = try mediaDetailRepository.detailCompleteness(mediaIDs: detailCandidateIDs)
                let detailSearchTermsByMediaID = try mediaDetailRepository.searchTermsByMediaID()
                let detailBackdropPathsByMediaID = try mediaDetailRepository.firstBackdropPathsByMediaID()
                let mediaExternalIDIndex = try mediaDetailRepository.externalMediaIDIndex()
                let mediaIDsByPersonID = try mediaDetailRepository.mediaIDsByPersonID()
                try cancellation.checkCancellation()

                return LibraryReloadSnapshot(
                    blockingQueueWaitNanoseconds: cancellation.queueWaitNanoseconds,
                    sources: sources,
                    items: items,
                    musicPlaylists: musicPlaylists,
                    musicSmartPlaylists: musicSmartPlaylists,
                    videoSmartCollections: videoSmartCollections,
                    videoManualCollections: videoManualCollections,
                    videoOfflineSubscriptions: videoOfflineSubscriptions,
                    metadataCorrectionCountsByMediaID: metadataCorrectionCountsByMediaID,
                    metadataCorrectionRecordCount: metadataCorrectionRecordCount,
                    metadataCorrectionBatches: metadataCorrectionBatches,
                    pendingSyncConflictCount: pendingSyncConflictCount,
                    pendingSyncConflicts: pendingSyncConflicts,
                    remoteConnectorAccounts: remoteConnectorAccounts,
                    musicProjectionSnapshot: musicProjectionSnapshot,
                    detailMetadataGapsByMediaID: detailMetadataGapsByMediaID,
                    detailSearchTermsByMediaID: detailSearchTermsByMediaID,
                    detailBackdropPathsByMediaID: detailBackdropPathsByMediaID,
                    mediaExternalIDIndex: mediaExternalIDIndex,
                    mediaIDsByPersonID: mediaIDsByPersonID
                )
            }
        }
    }
}

/// 只允许最新 reload 请求提交结果的编排器。
///
/// 输入是调用者捕获的目录，输出是 loader 生成的快照；`AppState` 仍是应用状态所有者。
/// 新请求或 `cancel()` 会使旧 generation 失效，即使底层 I/O 忽略 Task 取消，旧结果也不会 apply。
@MainActor
final class LibraryReloadCoordinator<Input: Sendable, Snapshot: Sendable> {
    typealias Loader = @Sendable (Input) async throws -> Snapshot

    private let loader: Loader
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var isLoading = false

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    deinit {
        task?.cancel()
    }

    func schedule(
        input: Input,
        delayNanoseconds: UInt64,
        loadingChanged: @escaping @MainActor (Bool) -> Void,
        apply: @escaping @MainActor (Snapshot, Date) -> Void,
        failure: @escaping @MainActor (Error) -> Void
    ) {
        generation += 1
        let requestGeneration = generation
        task?.cancel()
        task = Task { @MainActor [weak self, loader] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard let self,
                      !Task.isCancelled,
                      self.generation == requestGeneration else { return }
                self.setLoading(true, notify: loadingChanged)
                let startedAt = Date()
                let snapshot = try await loader(input)
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                apply(snapshot, startedAt)
                self.finish(requestGeneration: requestGeneration, notify: loadingChanged)
            } catch is CancellationError {
                self?.finish(requestGeneration: requestGeneration, notify: loadingChanged)
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                failure(error)
                self.finish(requestGeneration: requestGeneration, notify: loadingChanged)
            }
        }
    }

    func cancel(loadingChanged: (@MainActor (Bool) -> Void)? = nil) {
        generation += 1
        task?.cancel()
        task = nil
        setLoading(false, notify: loadingChanged)
    }

    private func finish(requestGeneration: Int, notify: @escaping @MainActor (Bool) -> Void) {
        guard generation == requestGeneration else { return }
        task = nil
        setLoading(false, notify: notify)
    }

    private func setLoading(_ value: Bool, notify: (@MainActor (Bool) -> Void)?) {
        guard isLoading != value else { return }
        isLoading = value
        notify?(value)
    }
}
