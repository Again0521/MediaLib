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
    }

    public var id: String
    public var mediaID: String
    public var kind: Kind
    public var title: String
    public var startTime: Double
    public var endTime: Double?
    public var origin: Origin
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
}
