import XCTest
@testable import MediaLib

final class BackgroundTaskRetryPolicyTests: XCTestCase {
    func testActiveRetryEquivalentMatchesBySourceBeforeItemAndIgnoresSelfInactiveAndDifferentKinds() {
        let task = makeTask(kind: .fullScan, state: .failed, sourceID: "source-a", itemID: "item-a")
        let selfTask = task
        let inactiveSameSource = makeTask(kind: .fullScan, state: .completed, sourceID: "source-a")
        let differentKindSameSource = makeTask(kind: .embySync, state: .running, sourceID: "source-a")
        let sameItemDifferentSource = makeTask(kind: .fullScan, state: .running, sourceID: "source-b", itemID: "item-a")

        XCTAssertFalse(
            BackgroundTaskRetryPolicy.hasActiveRetryEquivalent(
                for: task,
                in: [selfTask, inactiveSameSource, differentKindSameSource, sameItemDifferentSource]
            )
        )

        let sameSource = makeTask(kind: .fullScan, state: .running, sourceID: "source-a")
        XCTAssertTrue(BackgroundTaskRetryPolicy.hasActiveRetryEquivalent(for: task, in: [sameSource]))
    }

    func testActiveRetryEquivalentMatchesByItemWhenTaskHasNoSource() {
        let task = makeTask(kind: .videoCache, state: .failed, itemID: "movie-a")
        let sameItem = makeTask(kind: .videoCache, state: .paused, itemID: "movie-a")
        let differentItem = makeTask(kind: .videoCache, state: .running, itemID: "movie-b")

        XCTAssertTrue(BackgroundTaskRetryPolicy.hasActiveRetryEquivalent(for: task, in: [sameItem]))
        XCTAssertFalse(BackgroundTaskRetryPolicy.hasActiveRetryEquivalent(for: task, in: [differentItem]))
    }

    func testActiveRetryEquivalentMatchesGlobalCleanupAndMetadataTasksOnlyWhenTargetless() {
        let cleanup = makeTask(kind: .cleanup, state: .failed)
        let activeCleanup = makeTask(kind: .cleanup, state: .running)
        let metadata = makeTask(kind: .metadataSupplement, state: .failed)
        let activeMetadata = makeTask(kind: .metadataSupplement, state: .queued)
        let targetedCache = makeTask(kind: .videoCache, state: .failed)
        let activeTargetlessCache = makeTask(kind: .videoCache, state: .running)

        XCTAssertTrue(BackgroundTaskRetryPolicy.hasActiveRetryEquivalent(for: cleanup, in: [activeCleanup]))
        XCTAssertTrue(BackgroundTaskRetryPolicy.hasActiveRetryEquivalent(for: metadata, in: [activeMetadata]))
        XCTAssertFalse(BackgroundTaskRetryPolicy.hasActiveRetryEquivalent(for: targetedCache, in: [activeTargetlessCache]))
    }

    func testCanRetryRejectsNonFailedTasksAndActiveEquivalentTasksBeforeKindSpecificChecks() {
        let running = makeTask(kind: .cleanup, state: .running)
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: running)))

        let failedCleanup = makeTask(kind: .cleanup, state: .failed)
        let activeCleanup = makeTask(kind: .cleanup, state: .running)
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: failedCleanup, activeTasks: [activeCleanup])))
    }

    func testScanRetryRequiresExistingLocalSource() {
        let fullScan = makeTask(kind: .fullScan, state: .failed, sourceID: "local")
        let incremental = makeTask(kind: .incrementalScan, state: .failed, sourceID: "local")

        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: fullScan, sourceIsRemote: false)))
        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: incremental, sourceIsRemote: false)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: fullScan, sourceIsRemote: true)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: fullScan, sourceIsRemote: nil)))
    }

    func testRemoteSyncAndArtworkWarmupRequireRemoteMediaServerSource() {
        let sync = makeTask(kind: .embySync, state: .failed, sourceID: "remote")
        let warmup = makeTask(kind: .artworkWarmup, state: .failed, sourceID: "remote")

        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: sync, sourceIsRemote: true)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: sync, sourceIsRemote: false)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: sync, sourceIsRemote: nil)))

        XCTAssertTrue(
            BackgroundTaskRetryPolicy.canRetry(
                input(for: warmup, sourceIsRemote: true, artworkWarmupHasSourceItems: true)
            )
        )
        XCTAssertFalse(
            BackgroundTaskRetryPolicy.canRetry(
                input(for: warmup, sourceIsRemote: true, artworkWarmupHasSourceItems: false)
            )
        )
        XCTAssertFalse(
            BackgroundTaskRetryPolicy.canRetry(
                input(for: warmup, sourceIsRemote: false, artworkWarmupHasSourceItems: true)
            )
        )
    }

    func testCleanupAndMetadataSupplementRetryRules() {
        let cleanup = makeTask(kind: .cleanup, state: .failed)
        let metadata = makeTask(kind: .metadataSupplement, state: .failed)

        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: cleanup)))
        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: metadata, isSupplementingMetadata: false)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: metadata, isSupplementingMetadata: true)))
    }

    func testVideoCacheRetryRequiresCacheStoreAndQualityChoices() {
        let cache = makeTask(kind: .videoCache, state: .failed, itemID: "movie")

        XCTAssertTrue(
            BackgroundTaskRetryPolicy.canRetry(
                input(for: cache, hasVideoCacheStore: true, hasVideoCacheQualityChoices: true)
            )
        )
        XCTAssertFalse(
            BackgroundTaskRetryPolicy.canRetry(
                input(for: cache, hasVideoCacheStore: false, hasVideoCacheQualityChoices: true)
            )
        )
        XCTAssertFalse(
            BackgroundTaskRetryPolicy.canRetry(
                input(for: cache, hasVideoCacheStore: true, hasVideoCacheQualityChoices: false)
            )
        )
    }

    func testVideoAnalysisAndMusicIndexRetryRules() {
        let storyboard = makeTask(kind: .keyframeStoryboard, state: .failed, itemID: "movie")
        let marker = makeTask(kind: .markerAnalysis, state: .failed, itemID: "movie")
        let musicIndex = makeTask(kind: .musicIndex, state: .failed)

        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: storyboard, canGenerateKeyframeStoryboard: true)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: storyboard, canGenerateKeyframeStoryboard: false)))
        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: marker, canAnalyzeMarkers: true)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: marker, canAnalyzeMarkers: false)))
        XCTAssertTrue(BackgroundTaskRetryPolicy.canRetry(input(for: musicIndex, hasMusicProjectionRepository: true)))
        XCTAssertFalse(BackgroundTaskRetryPolicy.canRetry(input(for: musicIndex, hasMusicProjectionRepository: false)))
    }

    private func input(
        for task: BackgroundTaskSnapshot,
        activeTasks: [BackgroundTaskSnapshot] = [],
        sourceIsRemote: Bool? = nil,
        artworkWarmupHasSourceItems: Bool = false,
        hasVideoCacheStore: Bool = false,
        hasVideoCacheQualityChoices: Bool = false,
        canGenerateKeyframeStoryboard: Bool = false,
        canAnalyzeMarkers: Bool = false,
        hasMusicProjectionRepository: Bool = false,
        isSupplementingMetadata: Bool = false
    ) -> BackgroundTaskRetryPolicy.Input {
        BackgroundTaskRetryPolicy.Input(
            task: task,
            activeTasks: activeTasks,
            retrySourceIsRemoteMediaServer: sourceIsRemote,
            artworkWarmupHasSourceItems: artworkWarmupHasSourceItems,
            hasVideoCacheStore: hasVideoCacheStore,
            hasVideoCacheQualityChoices: hasVideoCacheQualityChoices,
            canGenerateKeyframeStoryboard: canGenerateKeyframeStoryboard,
            canAnalyzeMarkers: canAnalyzeMarkers,
            hasMusicProjectionRepository: hasMusicProjectionRepository,
            isSupplementingMetadata: isSupplementingMetadata
        )
    }

    private func makeTask(
        id: UUID = UUID(),
        kind: BackgroundTaskKind,
        state: BackgroundTaskState,
        sourceID: String? = nil,
        itemID: String? = nil
    ) -> BackgroundTaskSnapshot {
        BackgroundTaskSnapshot(
            id: id,
            kind: kind,
            state: state,
            title: kind.title,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isCancellable: true,
            retrySourceID: sourceID,
            retryItemID: itemID
        )
    }
}
