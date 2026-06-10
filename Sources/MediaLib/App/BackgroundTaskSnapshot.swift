import Foundation

enum BackgroundTaskKind: String, Codable, Sendable {
    case fullScan
    case incrementalScan
    case embySync
    case artworkWarmup
    case cleanup
    case videoCache
    case metadataSupplement
    case keyframeStoryboard
    case markerAnalysis

    var title: String {
        switch self {
        case .fullScan: return "完整扫描"
        case .incrementalScan: return "增量扫描"
        case .embySync: return "Emby 同步"
        case .artworkWarmup: return "封面预热"
        case .cleanup: return "一键清理"
        case .videoCache: return "视频缓存"
        case .metadataSupplement: return "元数据补充"
        case .keyframeStoryboard: return "章节图"
        case .markerAnalysis: return "片头片尾检测"
        }
    }

    var systemImage: String {
        switch self {
        case .fullScan: return "arrow.triangle.2.circlepath"
        case .incrementalScan: return "bolt.horizontal.circle"
        case .embySync: return "server.rack"
        case .artworkWarmup: return "photo.stack"
        case .cleanup: return "sparkles"
        case .videoCache: return "arrow.down.circle"
        case .metadataSupplement: return "tag.badge.plus"
        case .keyframeStoryboard: return "film.stack"
        case .markerAnalysis: return "wand.and.stars"
        }
    }
}

enum BackgroundTaskState: String, Codable, Sendable {
    case queued
    case running
    case pausing
    case paused
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "进行中"
        case .pausing: return "暂停中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "有错误"
        case .cancelled: return "已取消"
        }
    }

    var isActive: Bool {
        self == .queued || self == .running || self == .pausing || self == .paused
    }
}

struct BackgroundTaskSnapshot: Identifiable, Codable, Sendable {
    let id: UUID
    var kind: BackgroundTaskKind
    var state: BackgroundTaskState
    var title: String
    var detail: String?
    var progress: Double?
    var startedAt: Date
    var finishedAt: Date?
    var isCancellable: Bool
    var hidesDetail: Bool
    var retrySourceID: String?
    var retryItemID: String?
    var retryQualityID: String?

    init(
        id: UUID = UUID(),
        kind: BackgroundTaskKind,
        state: BackgroundTaskState = .queued,
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        isCancellable: Bool = true,
        hidesDetail: Bool = false,
        retrySourceID: String? = nil,
        retryItemID: String? = nil,
        retryQualityID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.title = title
        self.detail = detail
        self.progress = progress
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isCancellable = isCancellable
        self.hidesDetail = hidesDetail
        self.retrySourceID = retrySourceID
        self.retryItemID = retryItemID
        self.retryQualityID = retryQualityID
    }
}
