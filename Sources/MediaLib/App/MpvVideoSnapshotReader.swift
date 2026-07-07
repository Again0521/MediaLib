import Foundation

struct MpvChapter: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let time: Double
}

struct MpvVideoSnapshotRequest: Sendable {
    let includeDuration: Bool
    let includeAspect: Bool
    let includeBuffering: Bool
    let includeTracks: Bool
    let includeChapters: Bool
}

struct MpvVideoAspectSnapshot: Sendable {
    let displayWidth: Double?
    let displayHeight: Double?
    let codedWidth: Double?
    let codedHeight: Double?
    let sourceRotation: Int
}

struct MpvVideoBufferingSnapshot: Sendable {
    let pausedForCache: Bool
    let cacheProgress: Double?
}

struct MpvVideoSnapshot: Sendable {
    let playbackTime: Double?
    let duration: Double?
    let paused: Bool?
    let eofReached: Bool?
    let aspect: MpvVideoAspectSnapshot?
    let buffering: MpvVideoBufferingSnapshot?
    let tracks: [MpvTrack]?
    let secondarySubtitleID: Int?
    let chapters: [MpvChapter]?
}

final class MpvVideoSnapshotReader {
    private let queue = DispatchQueue(label: "com.local.MediaLib.mpv-video-snapshot", qos: .utility)
    private let handle: LibMpvClient.PropertyReadHandle
    private var invalidated = false

    init(handle: LibMpvClient.PropertyReadHandle) {
        self.handle = handle
    }

    func read(
        request: MpvVideoSnapshotRequest,
        timelineOffset: Double,
        completion: @escaping @MainActor (MpvVideoSnapshot) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.invalidated else { return }
            let snapshot = Self.makeSnapshot(
                handle: self.handle,
                request: request,
                timelineOffset: timelineOffset
            )
            guard !self.invalidated else { return }
            Task { @MainActor in
                completion(snapshot)
            }
        }
    }

    func invalidateAndDrain() {
        queue.sync {
            invalidated = true
        }
    }

    static func playerTimelineTime(for playbackTime: Double, offset: Double) -> Double {
        guard offset > 0 else { return playbackTime }
        return offset + max(playbackTime, 0)
    }

    private static func makeSnapshot(
        handle: LibMpvClient.PropertyReadHandle,
        request: MpvVideoSnapshotRequest,
        timelineOffset: Double
    ) -> MpvVideoSnapshot {
        let aspect = request.includeAspect
            ? MpvVideoAspectSnapshot(
                displayWidth: handle.getDouble("dwidth"),
                displayHeight: handle.getDouble("dheight"),
                codedWidth: handle.getDouble("video-params/w") ?? handle.getDouble("width"),
                codedHeight: handle.getDouble("video-params/h") ?? handle.getDouble("height"),
                sourceRotation: Int(handle.getInt64("video-params/rotate") ?? 0)
            )
            : nil
        let buffering = request.includeBuffering
            ? MpvVideoBufferingSnapshot(
                pausedForCache: handle.getFlag("paused-for-cache") ?? false,
                cacheProgress: handle.getDouble("cache-buffering-state")
            )
            : nil
        return MpvVideoSnapshot(
            playbackTime: handle.getDouble("time-pos").map { playerTimelineTime(for: $0, offset: timelineOffset) },
            duration: request.includeDuration ? handle.getDouble("duration") : nil,
            paused: handle.getFlag("pause"),
            eofReached: handle.getFlag("eof-reached"),
            aspect: aspect,
            buffering: buffering,
            tracks: request.includeTracks ? readTracks(handle: handle) : nil,
            secondarySubtitleID: request.includeTracks ? handle.getInt64("secondary-sid").map(Int.init) : nil,
            chapters: request.includeChapters ? readChapters(handle: handle, timelineOffset: timelineOffset) : nil
        )
    }

    private static func readTracks(handle: LibMpvClient.PropertyReadHandle) -> [MpvTrack] {
        guard let count = handle.getInt64("track-list/count"), count > 0 else { return [] }
        var tracks: [MpvTrack] = []
        tracks.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let type = handle.getString("track-list/\(index)/type"),
                  let id = handle.getInt64("track-list/\(index)/id") else { continue }
            let kind = MpvTrack.Kind(rawValue: type) ?? .unknown
            guard kind != .unknown else { continue }
            tracks.append(
                MpvTrack(
                    id: Int(id),
                    type: kind,
                    title: handle.getString("track-list/\(index)/title"),
                    language: handle.getString("track-list/\(index)/lang"),
                    codec: handle.getString("track-list/\(index)/codec"),
                    isSelected: handle.getFlag("track-list/\(index)/selected") ?? false,
                    isExternal: handle.getFlag("track-list/\(index)/external") ?? false,
                    externalFilename: handle.getString("track-list/\(index)/external-filename")
                )
            )
        }
        return tracks
    }

    private static func readChapters(handle: LibMpvClient.PropertyReadHandle, timelineOffset: Double) -> [MpvChapter] {
        guard let count = handle.getInt64("chapter-list/count"), count > 0 else { return [] }
        var chapters: [MpvChapter] = []
        chapters.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let playbackTime = handle.getDouble("chapter-list/\(index)/time") else { continue }
            let title = handle.getString("chapter-list/\(index)/title")
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "章节 \(index + 1)"
            chapters.append(
                MpvChapter(
                    id: index,
                    title: title,
                    time: playerTimelineTime(for: playbackTime, offset: timelineOffset)
                )
            )
        }
        return chapters
    }
}
