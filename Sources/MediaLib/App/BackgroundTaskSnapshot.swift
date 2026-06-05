import Foundation

enum BackgroundTaskKind: String, Sendable {
    case fullScan
    case incrementalScan
    case embySync

    var title: String {
        switch self {
        case .fullScan: return "完整扫描"
        case .incrementalScan: return "增量扫描"
        case .embySync: return "Emby 同步"
        }
    }

    var systemImage: String {
        switch self {
        case .fullScan: return "arrow.triangle.2.circlepath"
        case .incrementalScan: return "bolt.horizontal.circle"
        case .embySync: return "server.rack"
        }
    }
}

enum BackgroundTaskState: String, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "进行中"
        case .completed: return "已完成"
        case .failed: return "有错误"
        case .cancelled: return "已取消"
        }
    }

    var isActive: Bool {
        self == .queued || self == .running
    }
}

struct BackgroundTaskSnapshot: Identifiable, Sendable {
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
        hidesDetail: Bool = false
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
    }
}
