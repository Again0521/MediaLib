import Foundation
import MediaLibCore

/// 一次媒体库 reload 的只读输出。它是数据库快照，不拥有任何 UI 状态，也不触发后续任务。
struct LibraryReloadSnapshot: Sendable {
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
enum LibraryReloadSnapshotLoader {
    nonisolated static func load(directories: AppDirectories) async throws -> LibraryReloadSnapshot {
        try await BlockingIOExecutor.run {
            try Task.checkCancellation()
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

            let sources = try sourceRepository.fetchAll()
            let items = try mediaRepository.fetchAll()
            let detailCandidateIDs = items.compactMap { item -> String? in
                guard item.parentID == nil,
                      item.type != .music,
                      item.type != .photo,
                      item.type != .homeVideo,
                      item.type != .privateCollection else { return nil }
                return item.id
            }
            try Task.checkCancellation()

            return LibraryReloadSnapshot(
                sources: sources,
                items: items,
                musicPlaylists: try musicPlaylistRepository.fetchAll(),
                musicSmartPlaylists: try musicSmartPlaylistRepository.fetchAll(),
                videoSmartCollections: try videoSmartCollectionRepository.fetchAll(),
                videoManualCollections: try videoManualCollectionRepository.fetchAll(),
                videoOfflineSubscriptions: try videoOfflineSubscriptionRepository.fetchAll(),
                metadataCorrectionCountsByMediaID: try metadataCorrectionRepository.activeCountsByMediaID(),
                metadataCorrectionRecordCount: try metadataCorrectionRepository.activeRecordCount(),
                metadataCorrectionBatches: try metadataCorrectionRepository.fetchActiveBatches(limit: 120),
                pendingSyncConflictCount: try syncConflictRepository.pendingCount(),
                pendingSyncConflicts: try syncConflictRepository.fetchPending(limit: 120),
                remoteConnectorAccounts: try remoteConnectorAccountRepository.fetchAll(),
                musicProjectionSnapshot: try musicProjectionRepository.fetchSnapshot(),
                detailMetadataGapsByMediaID: try mediaDetailRepository.detailCompleteness(mediaIDs: detailCandidateIDs),
                detailSearchTermsByMediaID: try mediaDetailRepository.searchTermsByMediaID(),
                detailBackdropPathsByMediaID: try mediaDetailRepository.firstBackdropPathsByMediaID(),
                mediaExternalIDIndex: try mediaDetailRepository.externalMediaIDIndex(),
                mediaIDsByPersonID: try mediaDetailRepository.mediaIDsByPersonID()
            )
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
