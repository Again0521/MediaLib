import Foundation

public enum MusicQueuePreloadPolicy {
    public static func nextItemID(
        queueIDs: [String],
        currentItemID: String,
        repeatModeRawValue: String,
        shuffleEnabled: Bool
    ) -> String? {
        guard !shuffleEnabled,
              repeatModeRawValue != "repeatOne",
              let index = queueIDs.firstIndex(of: currentItemID) else {
            return nil
        }
        let nextIndex = index + 1
        if queueIDs.indices.contains(nextIndex) {
            return queueIDs[nextIndex]
        }
        if repeatModeRawValue == "repeatAll",
           let firstID = queueIDs.first,
           firstID != currentItemID {
            return firstID
        }
        return nil
    }
}
