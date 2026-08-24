import Foundation

struct ServerHLSPlaybackRequest: Codable, Equatable {
    let audioTrackID: Int?
    let startSeconds: Double?
    let durationSeconds: Double?

    var isValid: Bool {
        let audio = audioTrackID ?? 0
        let start = startSeconds ?? 0
        return (0..<ServerWebAudioTrackSet.maximumTrackCount).contains(audio) &&
            start.isFinite && start >= 0 && start < 86_400 &&
            (durationSeconds == nil || (
                durationSeconds?.isFinite == true &&
                (durationSeconds ?? 0) > 0 &&
                (durationSeconds ?? 0) < 86_400
            ))
    }
}

struct ServerHLSPlaybackDescriptor: Codable, Equatable {
    let sessionID: String
    let mode: String
    let durationSeconds: Double?
    let actualStartSeconds: Double
    let reason: String
    let mediaURL: String
}

struct ServerHLSResource {
    let data: Data
    let contentType: String
}

/// Authenticated, bounded HLS session owner.
///
/// Each session owns one ffmpeg process and, for remote assets, one ephemeral
/// loopback Range bridge. Sessions are bound to the complete authenticated
/// principal identity and are never addressable by an upstream URL or path.
final class ServerHLSPlaybackSessionManager: @unchecked Sendable {
    private final class Session {
        let id: String
        let owner: Owner
        let directory: URL
        let startedAt: Date
        let actualStartSeconds: Double
        let durationSeconds: Double?
        let mode: String
        let bridge: ServerRemoteMediaBridge?
        var process: Process?
        var finishedAt: Date?

        init(
            id: String,
            owner: Owner,
            directory: URL,
            actualStartSeconds: Double,
            durationSeconds: Double?,
            mode: String,
            bridge: ServerRemoteMediaBridge?
        ) {
            self.id = id
            self.owner = owner
            self.directory = directory
            self.startedAt = Date()
            self.actualStartSeconds = actualStartSeconds
            self.durationSeconds = durationSeconds
            self.mode = mode
            self.bridge = bridge
        }
    }

    private struct Owner: Equatable {
        let userID: String
        let deviceID: String
        let sessionID: String

        init(_ principal: ServerRequestPrincipal) {
            userID = principal.userID
            deviceID = principal.deviceID
            sessionID = principal.sessionID
        }
    }

    private let rootDirectory: URL
    private let remoteAssetFetcher: ServerRemoteAssetFetcher
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private static let maximumConcurrentSessions = 2
    private static let activeLifetime: TimeInterval = 4 * 60 * 60
    private static let finishedRetention: TimeInterval = 5 * 60
    private static let maximumPlaylistBytes = 1 * 1_024 * 1_024
    private static let maximumSegmentBytes = 96 * 1_024 * 1_024

    init(
        remoteAssetFetcher: ServerRemoteAssetFetcher,
        rootDirectory: URL? = nil
    ) {
        self.remoteAssetFetcher = remoteAssetFetcher
        self.rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        lock.lock()
        let current = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        current.forEach(stopAndRemove)
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func create(
        asset: ServerMediaAsset,
        request: ServerHLSPlaybackRequest,
        actualStartSeconds: Double,
        videoCodec: String?,
        audioCodec: String?,
        principal: ServerRequestPrincipal
    ) -> ServerHLSPlaybackDescriptor? {
        guard request.isValid,
              actualStartSeconds.isFinite,
              actualStartSeconds >= 0,
              actualStartSeconds < 86_400,
              let executable = ServerMediaToolchain.ffmpegURL()
        else { return nil }
        prune()
        lock.lock()
        let activeCount = sessions.values.filter { $0.finishedAt == nil }.count
        lock.unlock()
        guard activeCount < Self.maximumConcurrentSessions else { return nil }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )) != nil else { return nil }

        let bridge = asset.remoteURL == nil
            ? nil
            : ServerRemoteMediaBridge(asset: asset, fetcher: remoteAssetFetcher)
        guard asset.remoteURL == nil || bridge != nil else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let input = bridge?.inputURL.absoluteString ?? ServerMediaToolchain.inputArgument(for: asset.fileURL)
        // H.264 can be repackaged without quality loss. Other codecs take the
        // VideoToolbox path so Safari always receives an Apple-supported HLS
        // profile; this is the last compatibility tier, not the default.
        let copiesVideo = videoCodec?.lowercased() == "h264"
        let copiesAudio = audioCodec?.lowercased() == "aac"
        let mode = copiesVideo
            ? (copiesAudio ? "hlsRemux" : "hlsAudioTranscode")
            : "hlsTranscode"
        let playlist = directory.appendingPathComponent("index.m3u8")
        let segmentPattern = directory.appendingPathComponent("segment-%05d.ts").path
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", String(format: "%.3f", actualStartSeconds),
            // Keep generation near playback speed. Combined with the sliding
            // playlist below this bounds temporary storage instead of racing
            // through a multi-hour movie and materializing gigabytes of HLS.
            "-re",
            "-i", input,
            "-map", "0:v:0?",
            "-map", "0:a:\(request.audioTrackID ?? 0)?",
            "-sn", "-dn", "-map_chapters", "-1"
        ]
        if copiesVideo {
            arguments += ["-c:v", "copy"]
        } else {
            arguments += [
                "-c:v", "h264_videotoolbox", "-allow_sw", "1",
                "-pix_fmt", "yuv420p", "-b:v", "6000k",
                "-maxrate", "8000k", "-bufsize", "12000k",
                "-force_key_frames", "expr:gte(t,n_forced*6)"
            ]
        }
        arguments += copiesAudio
            ? ["-c:a", "copy"]
            : ["-c:a", "aac", "-ac", "2", "-b:a", "256k"]
        arguments += [
            "-avoid_negative_ts", "make_zero",
            "-f", "hls", "-hls_init_time", "1", "-hls_time", "6",
            "-hls_list_size", "30", "-hls_delete_threshold", "2",
            "-hls_flags", "delete_segments+independent_segments+temp_file",
            "-hls_segment_filename", segmentPattern,
            playlist.path
        ]

        let session = Session(
            id: id,
            owner: Owner(principal),
            directory: directory,
            actualStartSeconds: actualStartSeconds,
            durationSeconds: request.durationSeconds,
            mode: mode,
            bridge: bridge
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.lock.lock()
            session.finishedAt = Date()
            self.lock.unlock()
            session.bridge?.stop()
        }
        session.process = process
        lock.lock()
        // Recheck while reserving the slot so simultaneous creates cannot both
        // pass the optimistic count above.
        guard sessions.values.filter({ $0.finishedAt == nil }).count < Self.maximumConcurrentSessions else {
            lock.unlock()
            stopAndRemove(session)
            return nil
        }
        sessions[id] = session
        lock.unlock()
        do { try process.run() } catch {
            cancel(sessionID: id, principal: principal)
            return nil
        }

        // Return only when Safari can immediately load a valid manifest. HLS
        // generation continues asynchronously with bounded on-disk segments.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: playlist.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > 0 {
                return ServerHLSPlaybackDescriptor(
                    sessionID: id,
                    mode: mode,
                    durationSeconds: request.durationSeconds,
                    actualStartSeconds: actualStartSeconds,
                    reason: copiesVideo
                        ? (copiesAudio ? "containerCompatibility" : "audioCodecCompatibility")
                        : "videoCodecCompatibility",
                    mediaURL: "/api/v1/playback/hls/\(id)/index.m3u8"
                )
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        cancel(sessionID: id, principal: principal)
        return nil
    }

    func resource(
        sessionID: String,
        fileName: String,
        principal: ServerRequestPrincipal
    ) -> ServerHLSResource? {
        prune()
        guard Self.isSafeSessionID(sessionID), Self.isSafeResourceName(fileName) else { return nil }
        lock.lock()
        let session = sessions[sessionID]
        let allowed = session?.owner == Owner(principal)
        lock.unlock()
        guard allowed, let session else { return nil }
        let url = session.directory.appendingPathComponent(fileName, isDirectory: false)
        let limit = fileName.hasSuffix(".m3u8") ? Self.maximumPlaylistBytes : Self.maximumSegmentBytes
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= limit,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return nil }
        return ServerHLSResource(
            data: data,
            contentType: fileName.hasSuffix(".m3u8")
                ? "application/vnd.apple.mpegurl"
                : "video/mp2t"
        )
    }

    func cancel(sessionID: String, principal: ServerRequestPrincipal) {
        guard Self.isSafeSessionID(sessionID) else { return }
        lock.lock()
        guard let session = sessions[sessionID], session.owner == Owner(principal) else {
            lock.unlock()
            return
        }
        sessions.removeValue(forKey: sessionID)
        lock.unlock()
        stopAndRemove(session)
    }

    private func prune() {
        let now = Date()
        lock.lock()
        let stale = sessions.values.filter { session in
            if let finishedAt = session.finishedAt {
                return now.timeIntervalSince(finishedAt) > Self.finishedRetention
            }
            return now.timeIntervalSince(session.startedAt) > Self.activeLifetime
        }
        stale.forEach { sessions.removeValue(forKey: $0.id) }
        lock.unlock()
        stale.forEach(stopAndRemove)
    }

    private func stopAndRemove(_ session: Session) {
        session.bridge?.stop()
        if session.process?.isRunning == true { session.process?.terminate() }
        try? FileManager.default.removeItem(at: session.directory)
    }

    private static func isSafeSessionID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isSafeResourceName(_ value: String) -> Bool {
        if value == "index.m3u8" { return true }
        guard value.hasPrefix("segment-"), value.hasSuffix(".ts") else { return false }
        let digits = value.dropFirst("segment-".count).dropLast(3)
        return digits.count == 5 && digits.allSatisfy(\.isNumber)
    }
}
