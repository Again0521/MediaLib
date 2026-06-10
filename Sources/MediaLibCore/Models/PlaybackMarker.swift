import Foundation

public struct PlaybackMarker: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case chapter
        case intro
        case credits
        case bookmark

        public var title: String {
            switch self {
            case .chapter: "章节"
            case .intro: "片头"
            case .credits: "片尾"
            case .bookmark: "书签"
            }
        }
    }

    public enum Origin: String, Codable, Sendable {
        case embedded
        case manual
        case automatic
    }

    public enum ReviewStatus: String, Codable, Sendable {
        case accepted
        case pending
        case rejected
    }

    public var id: String
    public var mediaID: String
    public var kind: Kind
    public var title: String
    public var startTime: Double
    public var endTime: Double?
    public var origin: Origin
    public var reviewStatus: ReviewStatus
    public var detectorIdentifier: String?
    public var confidence: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        mediaID: String,
        kind: Kind,
        title: String,
        startTime: Double,
        endTime: Double? = nil,
        origin: Origin = .manual,
        reviewStatus: ReviewStatus = .accepted,
        detectorIdentifier: String? = nil,
        confidence: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.kind = kind
        self.title = title
        self.startTime = max(startTime, 0)
        self.endTime = endTime.map { max($0, 0) }
        self.origin = origin
        self.reviewStatus = reviewStatus
        self.detectorIdentifier = detectorIdentifier
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isCompleteRange: Bool {
        guard let endTime else { return false }
        return endTime > startTime
    }

    public func contains(_ time: Double) -> Bool {
        guard isCompleteRange, let endTime else { return false }
        return time >= startTime && time < endTime
    }

    public var isPendingReview: Bool {
        origin == .automatic && reviewStatus == .pending
    }

    public var isAcceptedForPlayback: Bool {
        origin != .automatic || reviewStatus == .accepted
    }
}
