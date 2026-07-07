import Foundation

public enum MediaMetadataCompletenessPolicy {
    public static func isMissingCoreMetadata(_ item: MediaItem) -> Bool {
        if item.type == .music {
            return item.posterPath == nil ||
                item.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
                item.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        return item.posterPath == nil ||
            item.year == nil ||
            item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}
