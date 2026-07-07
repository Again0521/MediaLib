import Foundation

public enum PlaybackQueuePolicy {
    public static func adjacentItemID(
        queueIDs: [String],
        currentItemID: String,
        direction: Int,
        wraps: Bool
    ) -> String? {
        guard let index = queueIDs.firstIndex(of: currentItemID) else { return nil }
        let normalizedDirection = direction < 0 ? -1 : 1
        let targetIndex = index + normalizedDirection

        if wraps, !queueIDs.isEmpty {
            if targetIndex < queueIDs.startIndex {
                return queueIDs.last
            }
            if targetIndex >= queueIDs.endIndex {
                return queueIDs.first
            }
        }

        guard queueIDs.indices.contains(targetIndex) else { return nil }
        return queueIDs[targetIndex]
    }

    public static func musicAdjacentItemID(
        queueIDs: [String],
        currentItemID: String,
        direction: Int,
        repeatModeRawValue: String
    ) -> String? {
        if repeatModeRawValue == "repeatOne" {
            return currentItemID
        }
        return adjacentItemID(
            queueIDs: queueIDs,
            currentItemID: currentItemID,
            direction: direction,
            wraps: repeatModeRawValue == "repeatAll"
        )
    }
}
