import Foundation

public struct PendingPlaybackSeek: Equatable {
    public let revision: Int
    public let generation: Int
    public let targetTime: Double
    public let originTime: Double
    public let startedAt: Date
    public private(set) var lastReissuedAt: Date?
    public private(set) var reissueCount: Int

    public init(
        revision: Int,
        generation: Int,
        targetTime: Double,
        originTime: Double,
        startedAt: Date,
        lastReissuedAt: Date? = nil,
        reissueCount: Int = 0
    ) {
        self.revision = revision
        self.generation = generation
        self.targetTime = targetTime
        self.originTime = originTime
        self.startedAt = startedAt
        self.lastReissuedAt = lastReissuedAt
        self.reissueCount = reissueCount
    }

    public func elapsedTime(at date: Date) -> TimeInterval {
        date.timeIntervalSince(startedAt)
    }

    public func secondsSinceLastReissue(at date: Date) -> TimeInterval? {
        lastReissuedAt.map { date.timeIntervalSince($0) }
    }

    public mutating func markReissued(at date: Date) {
        reissueCount += 1
        lastReissuedAt = date
    }
}
