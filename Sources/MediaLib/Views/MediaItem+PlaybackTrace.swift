import MediaLibCore

extension MediaItem {
    var hasPlaybackTrace: Bool {
        lastPlayedAt != nil || playPosition > 0 || playProgress > 0 || watched
    }
}
