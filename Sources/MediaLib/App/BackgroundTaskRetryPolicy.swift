import Foundation

enum BackgroundTaskRetryPolicy {
    struct Input {
        var task: BackgroundTaskSnapshot
        var activeTasks: [BackgroundTaskSnapshot]
        var retrySourceIsRemoteMediaServer: Bool?
        var artworkWarmupHasSourceItems: Bool
        var hasVideoCacheStore: Bool
        var hasVideoCacheQualityChoices: Bool
        var canGenerateKeyframeStoryboard: Bool
        var canAnalyzeMarkers: Bool
        var hasMusicProjectionRepository: Bool
        var isSupplementingMetadata: Bool
    }

    static func canRetry(_ input: Input) -> Bool {
        let task = input.task
        guard task.state == .failed,
              !hasActiveRetryEquivalent(for: task, in: input.activeTasks) else {
            return false
        }

        switch task.kind {
        case .fullScan, .incrementalScan:
            guard let isRemote = input.retrySourceIsRemoteMediaServer else { return false }
            return !isRemote
        case .embySync:
            return input.retrySourceIsRemoteMediaServer == true
        case .artworkWarmup:
            return input.retrySourceIsRemoteMediaServer == true && input.artworkWarmupHasSourceItems
        case .cleanup:
            return true
        case .metadataSupplement:
            return !input.isSupplementingMetadata
        case .videoCache:
            return input.hasVideoCacheStore && input.hasVideoCacheQualityChoices
        case .keyframeStoryboard:
            return input.canGenerateKeyframeStoryboard
        case .markerAnalysis:
            return input.canAnalyzeMarkers
        case .musicIndex:
            return input.hasMusicProjectionRepository
        }
    }

    static func hasActiveRetryEquivalent(
        for task: BackgroundTaskSnapshot,
        in tasks: [BackgroundTaskSnapshot]
    ) -> Bool {
        tasks.contains { candidate in
            guard candidate.id != task.id,
                  candidate.state.isActive,
                  candidate.kind == task.kind else {
                return false
            }
            if let sourceID = task.retrySourceID {
                return candidate.retrySourceID == sourceID
            }
            if let itemID = task.retryItemID {
                return candidate.retryItemID == itemID
            }
            return task.kind == .cleanup || task.kind == .metadataSupplement
        }
    }
}
