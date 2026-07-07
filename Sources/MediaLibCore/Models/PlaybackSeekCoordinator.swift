import Foundation

public struct PlaybackSeekTransition: Equatable {
    public let revision: Int
    public let targetTime: Double
    public let originTime: Double
    public let state: PlaybackSeekState
}

public enum PlaybackSeekCoordinator {
    public static func scrubbingTransition(
        currentState: PlaybackSeekState?,
        targetTime: Double,
        fallbackOriginTime: Double,
        createIfNeeded: Bool
    ) -> PlaybackSeekTransition? {
        let revision: Int
        let originTime: Double

        if let currentState, currentState.phase == .scrubbing {
            revision = currentState.revision
            originTime = currentState.originTime
        } else if createIfNeeded {
            revision = PlaybackSeekState.nextRevision(after: currentState)
            originTime = fallbackOriginTime
        } else {
            return nil
        }

        return PlaybackSeekTransition(
            revision: revision,
            targetTime: targetTime,
            originTime: originTime,
            state: .scrubbing(
                revision: revision,
                targetTime: targetTime,
                originTime: originTime
            )
        )
    }

    public static func seekingTransition(
        currentState: PlaybackSeekState?,
        targetTime: Double,
        fallbackOriginTime: Double
    ) -> PlaybackSeekTransition {
        let existingScrub = currentState?.phase == .scrubbing ? currentState : nil
        let revision = existingScrub?.revision ?? PlaybackSeekState.nextRevision(after: currentState)
        let originTime = existingScrub?.originTime ?? fallbackOriginTime

        return PlaybackSeekTransition(
            revision: revision,
            targetTime: targetTime,
            originTime: originTime,
            state: .seeking(
                revision: revision,
                targetTime: targetTime,
                originTime: originTime
            )
        )
    }

    public static func canCancelScrubbing(currentState: PlaybackSeekState?) -> Bool {
        currentState?.phase == .scrubbing
    }
}
