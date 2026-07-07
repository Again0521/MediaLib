import Foundation

public enum MusicTrackProjectionPolicy {
    public static func uniquePlayableMusicTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []
        for track in tracks where track.type == .music && track.filePath != nil {
            guard seen.insert(track.id).inserted else { continue }
            result.append(track)
        }
        return result
    }

    public static func sortedByAlbumTrackAndTitle(_ tracks: [MediaItem]) -> [MediaItem] {
        tracks.sorted(by: isOrderedByAlbumTrackAndTitle)
    }

    public static func isOrderedByAlbumTrackAndTitle(_ lhs: MediaItem, before rhs: MediaItem) -> Bool {
        let leftAlbum = lhs.album ?? ""
        let rightAlbum = rhs.album ?? ""
        if leftAlbum != rightAlbum {
            return leftAlbum.localizedStandardCompare(rightAlbum) == .orderedAscending
        }
        if (lhs.trackNumber ?? 0) != (rhs.trackNumber ?? 0) {
            return (lhs.trackNumber ?? 0) < (rhs.trackNumber ?? 0)
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    public static func recentlyPlayedTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        tracks
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    public static func continueListeningTracks(
        _ tracks: [MediaItem],
        limit: Int
    ) -> [MediaItem] {
        Array(tracks
            .filter { $0.lastPlayedAt != nil || ($0.playProgress > 0 && $0.playProgress < 0.98) }
            .sorted { ($0.lastPlayedAt ?? $0.updatedAt) > ($1.lastPlayedAt ?? $1.updatedAt) }
            .prefix(max(limit, 0)))
    }

    public static func signalTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        tracks.filter {
            ($0.playCount ?? 0) > 0 || $0.lastPlayedAt != nil || $0.favorite || ($0.userRating ?? 0) > 0
        }
    }
}
