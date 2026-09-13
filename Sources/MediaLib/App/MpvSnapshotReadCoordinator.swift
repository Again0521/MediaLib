import Foundation

/// Identifies the reader and playback session that owns one pending snapshot.
struct MpvSnapshotReadTicket: Equatable {
    let revision: Int
    let readerIdentity: ObjectIdentifier
    let playbackGeneration: Int
    let forceTrackRefresh: Bool
}

/// Owns the in-flight snapshot marker and coalesced forced-track request.
/// A late completion from an invalidated reader cannot release a newer read.
@MainActor
final class MpvSnapshotReadCoordinator {
    private var revision = 0
    private var inFlight: MpvSnapshotReadTicket?
    private(set) var forceTrackRefreshPending = false

    func begin(reader: AnyObject, playbackGeneration: Int, forceTrackRefresh: Bool) -> MpvSnapshotReadTicket? {
        if forceTrackRefresh {
            forceTrackRefreshPending = true
        }
        guard inFlight == nil else { return nil }

        revision &+= 1
        let ticket = MpvSnapshotReadTicket(
            revision: revision,
            readerIdentity: ObjectIdentifier(reader),
            playbackGeneration: playbackGeneration,
            forceTrackRefresh: forceTrackRefreshPending
        )
        forceTrackRefreshPending = false
        inFlight = ticket
        return ticket
    }

    func complete(
        _ ticket: MpvSnapshotReadTicket,
        currentReader: AnyObject?,
        playbackGeneration: Int
    ) -> Bool {
        guard inFlight == ticket else { return false }
        inFlight = nil
        guard let currentReader else { return false }
        return ObjectIdentifier(currentReader) == ticket.readerIdentity
            && playbackGeneration == ticket.playbackGeneration
    }

    func invalidate() {
        revision &+= 1
        inFlight = nil
        forceTrackRefreshPending = false
    }
}
