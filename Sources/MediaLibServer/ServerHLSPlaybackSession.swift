import Foundation
import MediaLibCore

struct ServerHLSPlaybackRequest: Codable, Equatable {
    let audioTrackID: Int?
    let startSeconds: Double?
    let durationSeconds: Double?
    let capabilities: ServerWebClientCapabilities?

    init(
        audioTrackID: Int?,
        startSeconds: Double?,
        durationSeconds: Double?,
        capabilities: ServerWebClientCapabilities? = nil
    ) {
        self.audioTrackID = audioTrackID
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.capabilities = capabilities
    }

    var isValid: Bool {
        let audio = audioTrackID ?? 0
        let start = startSeconds ?? 0
        return (0..<ServerWebAudioTrackSet.maximumTrackCount).contains(audio) &&
            start.isFinite && start >= 0 && start < 86_400 &&
            (durationSeconds == nil || (
                durationSeconds?.isFinite == true &&
                (durationSeconds ?? 0) > 0 &&
                (durationSeconds ?? 0) < 86_400
            )) && (capabilities?.isValid ?? true)
    }
}

struct ServerWebClientCapabilities: Codable, Equatable {
    let nativeHLS: Bool
    let mediaSource: Bool
    let videoCodecs: [String]
    let audioCodecs: [String]
    let screenWidth: Int
    let screenHeight: Int
    let hdrDisplay: Bool
    let measuredDownlinkMbps: Double?

    var isValid: Bool {
        videoCodecs.count <= 16 && audioCodecs.count <= 16 &&
            (1...16_384).contains(screenWidth) && (1...16_384).contains(screenHeight) &&
            videoCodecs.allSatisfy(Self.isSafeCodec) && audioCodecs.allSatisfy(Self.isSafeCodec) &&
            (measuredDownlinkMbps.map { $0.isFinite && $0 > 0 && $0 <= 10_000 } ?? true)
    }

    private static func isSafeCodec(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 &&
            value.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }
}

struct ServerHLSPlaybackSessionCreationRequest: Codable {
    let itemID: String
    let audioTrackID: Int?
    let startSeconds: Double?
    let durationSeconds: Double?
    let capabilities: ServerWebClientCapabilities?

    var playbackRequest: ServerHLSPlaybackRequest {
        ServerHLSPlaybackRequest(
            audioTrackID: audioTrackID,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            capabilities: capabilities
        )
    }

    var isValid: Bool {
        !itemID.isEmpty && itemID.utf8.count <= 512 && !itemID.contains("/") && !itemID.contains("\\") &&
            playbackRequest.isValid
    }
}

struct ServerHLSPlaybackDescriptor: Codable, Equatable {
    let sessionID: String
    let state: ServerHLSPlaybackSessionState
    let mode: String
    let durationSeconds: Double?
    let actualStartSeconds: Double
    let reason: String
    let mediaURL: String

    init(
        sessionID: String,
        state: ServerHLSPlaybackSessionState = .ready,
        mode: String,
        durationSeconds: Double?,
        actualStartSeconds: Double,
        reason: String,
        mediaURL: String
    ) {
        self.sessionID = sessionID
        self.state = state
        self.mode = mode
        self.durationSeconds = durationSeconds
        self.actualStartSeconds = actualStartSeconds
        self.reason = reason
        self.mediaURL = mediaURL
    }
}

enum ServerHLSPlaybackSessionState: String, Codable, Equatable {
    case queued, preparing, ready, playing, finished, failed, cancelled
}

struct ServerHLSResource {
    enum Storage {
        case data(Data)
        case file(url: URL, byteLength: Int64)
    }

    let storage: Storage
    let contentType: String

    init(data: Data, contentType: String) {
        storage = .data(data)
        self.contentType = contentType
    }

    init(fileURL: URL, byteLength: Int64, contentType: String) {
        storage = .file(url: fileURL, byteLength: byteLength)
        self.contentType = contentType
    }

    var data: Data {
        guard case let .data(value) = storage else { return Data() }
        return value
    }
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
        let reason: String
        let mediaURL: String
        let bridge: ServerRemoteMediaBridge?
        var process: Process?
        var state: ServerHLSPlaybackSessionState = .preparing
        var readinessTimer: DispatchSourceTimer?
        var finishedAt: Date?

        init(
            id: String,
            owner: Owner,
            directory: URL,
            actualStartSeconds: Double,
            durationSeconds: Double?,
            mode: String,
            reason: String,
            mediaURL: String,
            bridge: ServerRemoteMediaBridge?
        ) {
            self.id = id
            self.owner = owner
            self.directory = directory
            self.startedAt = Date()
            self.actualStartSeconds = actualStartSeconds
            self.durationSeconds = durationSeconds
            self.mode = mode
            self.reason = reason
            self.mediaURL = mediaURL
            self.bridge = bridge
        }

        var descriptor: ServerHLSPlaybackDescriptor {
            ServerHLSPlaybackDescriptor(
                sessionID: id,
                state: state,
                mode: mode,
                durationSeconds: durationSeconds,
                actualStartSeconds: actualStartSeconds,
                reason: reason,
                mediaURL: mediaURL
            )
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
    private let maximumConcurrentSessions: Int
    private let lock = NSLock()
    private let readinessQueue = DispatchQueue(label: "MediaLibServer.HLSReadiness", qos: .utility)
    private var sessions: [String: Session] = [:]
    private var pendingSessionIDs: [String] = []
    private static let maximumQueuedSessions = 8
    private static let activeLifetime: TimeInterval = 4 * 60 * 60
    private static let finishedRetention: TimeInterval = 5 * 60
    private static let maximumPlaylistBytes = 1 * 1_024 * 1_024
    private static let maximumSegmentBytes = 96 * 1_024 * 1_024

    init(
        remoteAssetFetcher: ServerRemoteAssetFetcher,
        rootDirectory: URL? = nil,
        maximumConcurrentSessions: Int = 2
    ) {
        self.remoteAssetFetcher = remoteAssetFetcher
        self.maximumConcurrentSessions = min(max(maximumConcurrentSessions, 1), 4)
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
        principal: ServerRequestPrincipal,
        policy: ServerUserPolicy = ServerUserPolicy()
    ) -> ServerHLSPlaybackDescriptor? {
        guard request.isValid, policy.isValid, policy.playbackAllowed,
              Self.isWithinAccessWindow(policy),
              actualStartSeconds.isFinite,
              actualStartSeconds >= 0,
              actualStartSeconds < 86_400,
              let executable = ServerMediaToolchain.ffmpegURL()
        else { return nil }
        prune()
        lock.lock()
        let owner = Owner(principal)
        let ownedSessionCount = sessions.values.filter {
            $0.owner.userID == owner.userID && ![.finished, .failed, .cancelled].contains($0.state)
        }.count
        let hasCapacity = ownedSessionCount < policy.maximumConcurrentStreams && (
            activeSessionCountLocked() < maximumConcurrentSessions ||
                pendingSessionIDs.count < Self.maximumQueuedSessions
        )
        lock.unlock()
        guard hasCapacity else { return nil }

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
        let normalizedVideoCodec = videoCodec?.lowercased()
        let copiesVideo = normalizedVideoCodec == "h264" || (
            ["hevc", "h265"].contains(normalizedVideoCodec ?? "") &&
                request.capabilities?.nativeHLS == true &&
                request.capabilities?.videoCodecs.contains(where: { ["hevc", "h265", "hvc1"].contains($0.lowercased()) }) == true
        )
        let copiesAudio = audioCodec?.lowercased() == "aac"
        let mode = copiesVideo
            ? (copiesAudio ? "hlsRemux" : "hlsAudioTranscode")
            : "hlsTranscode"
        guard (mode == "hlsRemux" && policy.remuxAllowed) ||
                (mode != "hlsRemux" && policy.transcodeAllowed)
        else {
            bridge?.stop()
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let reason = copiesVideo
            ? (copiesAudio ? "containerCompatibility" : "audioCodecCompatibility")
            : "videoCodecCompatibility"
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
            reason: reason,
            mediaURL: "/api/v1/playback/hls/\(id)/index.m3u8",
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
            self.processDidTerminate(session)
        }
        session.process = process
        lock.lock()
        // Recheck while reserving so simultaneous creates cannot overrun either
        // the active slots or the bounded waiting queue.
        let shouldLaunch = activeSessionCountLocked() < maximumConcurrentSessions
        guard shouldLaunch || pendingSessionIDs.count < Self.maximumQueuedSessions else {
            lock.unlock()
            stopAndRemove(session)
            return nil
        }
        session.state = shouldLaunch ? .preparing : .queued
        sessions[id] = session
        if !shouldLaunch { pendingSessionIDs.append(id) }
        lock.unlock()
        if shouldLaunch, !launch(session) {
            return session.descriptor
        }
        return session.descriptor
    }

    func status(sessionID: String, principal: ServerRequestPrincipal) -> ServerHLSPlaybackDescriptor? {
        prune()
        guard Self.isSafeSessionID(sessionID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID], session.owner == Owner(principal) else { return nil }
        return session.descriptor
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
              size <= limit
        else { return nil }
        lock.lock()
        if session.state == .ready { session.state = .playing }
        lock.unlock()
        return ServerHLSResource(
            fileURL: url,
            byteLength: Int64(size),
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
        session.state = .cancelled
        session.finishedAt = Date()
        session.readinessTimer?.cancel()
        session.readinessTimer = nil
        pendingSessionIDs.removeAll { $0 == sessionID }
        sessions.removeValue(forKey: sessionID)
        lock.unlock()
        stopAndRemove(session)
        startNextIfPossible()
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
        let staleIDs = Set(stale.map(\.id))
        pendingSessionIDs.removeAll { staleIDs.contains($0) }
        lock.unlock()
        stale.forEach(stopAndRemove)
        if !stale.isEmpty { startNextIfPossible() }
    }

    private func stopAndRemove(_ session: Session) {
        session.readinessTimer?.cancel()
        session.bridge?.stop()
        if session.process?.isRunning == true { session.process?.terminate() }
        try? FileManager.default.removeItem(at: session.directory)
    }

    private func monitorReadiness(of session: Session, playlist: URL) {
        let deadline = Date().addingTimeInterval(10)
        let timer = DispatchSource.makeTimerSource(queue: readinessQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            let isReady: Bool = {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: playlist.path),
                      let size = attributes[.size] as? NSNumber else { return false }
                return size.intValue > 0
            }()
            self.lock.lock()
            guard self.sessions[session.id] === session, session.state == .preparing else {
                self.lock.unlock()
                timer.cancel()
                return
            }
            if isReady {
                session.state = .ready
                session.readinessTimer = nil
                self.lock.unlock()
                timer.cancel()
                return
            }
            let failed = Date() >= deadline || session.process?.isRunning != true
            if failed {
                session.state = .failed
                session.finishedAt = Date()
                session.readinessTimer = nil
            }
            self.lock.unlock()
            if failed {
                timer.cancel()
                session.bridge?.stop()
                if session.process?.isRunning == true { session.process?.terminate() }
            }
        }
        lock.lock()
        session.readinessTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func activeSessionCountLocked() -> Int {
        sessions.values.filter { [.preparing, .ready, .playing].contains($0.state) }.count
    }

    @discardableResult
    private func launch(_ session: Session) -> Bool {
        guard let process = session.process else { return false }
        do {
            try process.run()
            monitorReadiness(
                of: session,
                playlist: session.directory.appendingPathComponent("index.m3u8")
            )
            return true
        } catch {
            lock.lock()
            if sessions[session.id] === session {
                session.state = .failed
                session.finishedAt = Date()
            }
            lock.unlock()
            session.bridge?.stop()
            startNextIfPossible()
            return false
        }
    }

    private func processDidTerminate(_ session: Session) {
        lock.lock()
        session.readinessTimer?.cancel()
        session.readinessTimer = nil
        if session.state == .preparing { session.state = .failed }
        else if session.state != .cancelled && session.state != .failed { session.state = .finished }
        session.finishedAt = Date()
        lock.unlock()
        session.bridge?.stop()
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        while true {
            lock.lock()
            guard activeSessionCountLocked() < maximumConcurrentSessions,
                  !pendingSessionIDs.isEmpty else {
                lock.unlock()
                return
            }
            let id = pendingSessionIDs.removeFirst()
            guard let session = sessions[id], session.state == .queued else {
                lock.unlock()
                continue
            }
            session.state = .preparing
            lock.unlock()
            _ = launch(session)
        }
    }

    private static func isSafeSessionID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isWithinAccessWindow(_ policy: ServerUserPolicy, at date: Date = Date()) -> Bool {
        guard let start = policy.accessStartMinute, let end = policy.accessEndMinute else { return true }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let current = hour * 60 + minute
        return start <= end ? (start...end).contains(current) : (current >= start || current <= end)
    }

    private static func isSafeResourceName(_ value: String) -> Bool {
        if value == "index.m3u8" { return true }
        guard value.hasPrefix("segment-"), value.hasSuffix(".ts") else { return false }
        let digits = value.dropFirst("segment-".count).dropLast(3)
        return digits.count == 5 && digits.allSatisfy(\.isNumber)
    }
}
