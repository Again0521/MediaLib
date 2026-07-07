import Foundation

public enum MediaPlaybackRecencyPolicy {
    public static func isMoreRecent(_ lhs: MediaItem, than rhs: MediaItem) -> Bool {
        playbackRecencyDate(for: lhs) > playbackRecencyDate(for: rhs)
    }

    public static func sortedByMostRecentPlaybackTrace(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted(by: isMoreRecent)
    }

    public static func playbackRecencyDate(for item: MediaItem) -> Date {
        item.lastPlayedAt ?? item.updatedAt
    }
}
