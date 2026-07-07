import Foundation

public struct PendingIDBatchPublishPolicy: Sendable {
    public var minimumInterval: TimeInterval
    public var minimumItemCount: Int

    private var pendingIDs = Set<String>()
    private var lastPublishedAt = Date.distantPast

    public var pendingCount: Int {
        pendingIDs.count
    }

    public init(
        minimumInterval: TimeInterval = 1.2,
        minimumItemCount: Int = 18
    ) {
        self.minimumInterval = minimumInterval
        self.minimumItemCount = minimumItemCount
    }

    public mutating func record(_ ids: Set<String>, now: Date = Date()) -> Bool {
        pendingIDs.formUnion(ids)
        guard !pendingIDs.isEmpty else { return false }
        return pendingIDs.count >= minimumItemCount ||
            now.timeIntervalSince(lastPublishedAt) >= minimumInterval
    }

    public mutating func flush(now: Date = Date()) -> Bool {
        guard !pendingIDs.isEmpty else { return false }
        pendingIDs.removeAll()
        lastPublishedAt = now
        return true
    }
}
