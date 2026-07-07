import Foundation

public enum MusicPlaybackBufferPolicy {
    public static func automaticallyWaitsToMinimizeStalling(isNetwork: Bool) -> Bool {
        isNetwork
    }

    public static func preferredForwardBufferDuration(
        isNetwork: Bool,
        preloaded: Bool
    ) -> TimeInterval {
        if isNetwork {
            return preloaded ? 30 : 12
        }
        return preloaded ? 120 : 0
    }

    public static func prefersPreciseTiming(
        isNetwork: Bool,
        isMusic: Bool
    ) -> Bool {
        !isNetwork && isMusic
    }
}
