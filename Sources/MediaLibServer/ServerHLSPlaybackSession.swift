import Foundation
import MediaLibCore

struct ServerHLSPlaybackRequest: Codable, Equatable {
    let audioTrackID: Int?
    let subtitleTrackID: Int?
    let startSeconds: Double?
    let durationSeconds: Double?
    let capabilities: ServerWebClientCapabilities?
    let quality: ServerPlaybackQuality?
    let maximumBitrateMbps: Int?

    init(
        audioTrackID: Int?,
        subtitleTrackID: Int? = nil,
        startSeconds: Double?,
        durationSeconds: Double?,
        capabilities: ServerWebClientCapabilities? = nil,
        quality: ServerPlaybackQuality? = nil,
        maximumBitrateMbps: Int? = nil
    ) {
        self.audioTrackID = audioTrackID
        self.subtitleTrackID = subtitleTrackID
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.capabilities = capabilities
        self.quality = quality
        self.maximumBitrateMbps = maximumBitrateMbps
    }

    var isValid: Bool {
        let audio = audioTrackID ?? 0
        let subtitle = subtitleTrackID ?? 0
        let start = startSeconds ?? 0
        return (0..<ServerWebAudioTrackSet.maximumTrackCount).contains(audio) &&
            (subtitleTrackID == nil || (0..<ServerWebVTTSubtitleTrack.maximumTrackCount).contains(subtitle)) &&
            start.isFinite && start >= 0 && start < 86_400 &&
            (durationSeconds == nil || (
                durationSeconds?.isFinite == true &&
                (durationSeconds ?? 0) > 0 &&
                (durationSeconds ?? 0) < 86_400
            )) && (capabilities?.isValid ?? true) &&
            (maximumBitrateMbps.map { (1...200).contains($0) } ?? true)
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
    let subtitleTrackID: Int?
    let startSeconds: Double?
    let durationSeconds: Double?
    let capabilities: ServerWebClientCapabilities?
    let quality: ServerPlaybackQuality?
    let maximumBitrateMbps: Int?

    var playbackRequest: ServerHLSPlaybackRequest {
        ServerHLSPlaybackRequest(
            audioTrackID: audioTrackID,
            subtitleTrackID: subtitleTrackID,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            capabilities: capabilities,
            quality: quality,
            maximumBitrateMbps: maximumBitrateMbps
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

struct ServerAdminHLSPlaybackSession: Codable, Equatable {
    let sessionID: String
    let userID: String
    let state: ServerHLSPlaybackSessionState
    let mode: String
    let startedAt: Date
    let lastAccessedAt: Date
    let durationSeconds: Double?
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

/// Codec and timeline facts resolved before an HLS process is launched. Remote
/// callers produce this from an authenticated loopback Range bridge so the
/// upstream URL and credentials never become ffprobe or response metadata.
struct ServerHLSPreparedMedia {
    let videoCodec: String?
    let videoHeight: Int?
    let sourceIsHDR: Bool
    let audioCodec: String?
    let durationSeconds: Double?
    let actualStartSeconds: Double

    /// A missing remote probe is a recoverable compatibility miss, not proof
    /// that the media is unplayable. Unknown codecs deliberately select the
    /// full-transcode path, preserving playback while avoiding a false remux.
    init(
        remoteProbe: FFprobeMediaInspector.ProbedMedia?,
        selectedAudioID: Int,
        fallbackDurationSeconds: Double?,
        actualStartSeconds: Double
    ) {
        videoCodec = remoteProbe?.video.first?.codec
        videoHeight = remoteProbe?.video.first?.height
        sourceIsHDR = remoteProbe?.video.first?.isHDR == true
        audioCodec = remoteProbe?.audio.first(where: {
            $0.typeOrdinal == selectedAudioID
        })?.codec
        durationSeconds = remoteProbe?.durationSeconds ?? fallbackDurationSeconds
        self.actualStartSeconds = actualStartSeconds
    }

    init(
        videoCodec: String?,
        videoHeight: Int?,
        sourceIsHDR: Bool,
        audioCodec: String?,
        durationSeconds: Double?,
        actualStartSeconds: Double
    ) {
        self.videoCodec = videoCodec
        self.videoHeight = videoHeight
        self.sourceIsHDR = sourceIsHDR
        self.audioCodec = audioCodec
        self.durationSeconds = durationSeconds
        self.actualStartSeconds = actualStartSeconds
    }
}

/// Authenticated, bounded HLS session owner.
///
/// Each session owns one ffmpeg process and, for remote assets, one ephemeral
/// loopback Range bridge. Sessions are bound to the complete authenticated
/// principal identity and are never addressable by an upstream URL or path.
final class ServerHLSPlaybackSessionManager: @unchecked Sendable {
    private struct PreparedLaunch {
        let mode: String
        let reason: String
        let durationSeconds: Double?
        let actualStartSeconds: Double
        let process: Process
    }

    private final class Session {
        let id: String
        let owner: Owner
        let directory: URL
        let startedAt: Date
        var actualStartSeconds: Double
        var durationSeconds: Double?
        var mode: String
        var reason: String
        let mediaURL: String
        let bridge: ServerRemoteMediaBridge?
        var lastAccessedAt: Date
        var process: Process?
        let preparationCancellation = ServerBoundedProcess.Cancellation()
        let launchBuilder: (ServerBoundedProcess.Cancellation) -> PreparedLaunch?
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
            bridge: ServerRemoteMediaBridge?,
            launchBuilder: @escaping (ServerBoundedProcess.Cancellation) -> PreparedLaunch?
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
            self.launchBuilder = launchBuilder
            self.lastAccessedAt = Date()
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
    private let configurationProvider: @Sendable () -> ServerOperationalSettings
    private let configurationLock = NSLock()
    private var cachedConfiguration: ServerOperationalSettings
    private var configurationFetchedAt = Date.distantPast
    private let configurationCacheLifetime: TimeInterval
    private let ffmpegFilterCapabilities: ServerMediaToolchain.FFmpegFilterCapabilities
    private let ffmpegURLProvider: () -> URL?
    /// Deterministic seam for exercising the final atomic reservation under a
    /// simultaneous-create barrier. Production leaves it nil.
    private let beforeReservation: (@Sendable () -> Void)?
    private let lock = NSLock()
    private let readinessQueue = DispatchQueue(label: "MediaLibServer.HLSReadiness", qos: .utility)
    private let preparationQueue = DispatchQueue(
        label: "MediaLibServer.HLSPreparation",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var sessions: [String: Session] = [:]
    private var pendingSessionIDs: [String] = []
    private static let maximumQueuedSessions = 8
    private static let finishedRetention: TimeInterval = 5 * 60
    private static let maximumPlaylistBytes = 1 * 1_024 * 1_024
    private static let maximumSegmentBytes = 96 * 1_024 * 1_024

    init(
        remoteAssetFetcher: ServerRemoteAssetFetcher,
        rootDirectory: URL? = nil,
        maximumConcurrentSessions: Int = 2,
        defaultRemoteBitrateMbps: Int = 20,
        ffmpegFilterCapabilities: ServerMediaToolchain.FFmpegFilterCapabilities? = nil,
        ffmpegURLProvider: @escaping () -> URL? = { ServerMediaToolchain.ffmpegURL() },
        operationalSettingsProvider: (@Sendable () -> ServerOperationalSettings)? = nil,
        configurationCacheLifetime: TimeInterval = 2,
        beforeReservation: (@Sendable () -> Void)? = nil
    ) {
        self.remoteAssetFetcher = remoteAssetFetcher
        let initialConfiguration = ServerOperationalSettings(
            maximumTranscodeSessions: maximumConcurrentSessions,
            defaultRemoteBitrateMbps: defaultRemoteBitrateMbps
        )
        self.cachedConfiguration = initialConfiguration
        self.configurationProvider = operationalSettingsProvider ?? { initialConfiguration }
        self.configurationCacheLifetime = max(configurationCacheLifetime, 0)
        self.ffmpegFilterCapabilities = ffmpegFilterCapabilities
            ?? ServerMediaToolchain.ffmpegFilterCapabilities()
        self.ffmpegURLProvider = ffmpegURLProvider
        self.beforeReservation = beforeReservation
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
        startResolver: ((ServerBoundedProcess.Cancellation) -> Double)? = nil,
        videoCodec: String?,
        videoHeight: Int? = nil,
        sourceIsHDR: Bool = false,
        audioCodec: String?,
        burnInSubtitleStreamIndex: Int? = nil,
        preparationResolver: ((URL, ServerBoundedProcess.Cancellation) -> ServerHLSPreparedMedia?)? = nil,
        principal: ServerRequestPrincipal,
        policy: ServerUserPolicy = ServerUserPolicy()
    ) -> ServerHLSPlaybackDescriptor? {
        guard request.isValid, policy.isValid, policy.playbackAllowed,
              Self.isWithinAccessWindow(policy),
              actualStartSeconds.isFinite,
              actualStartSeconds >= 0,
              actualStartSeconds < 86_400,
              let executable = ffmpegURLProvider()
        else { return nil }
        prune()
        let configuration = currentConfiguration()
        guard hasStorageCapacity(for: configuration) else { return nil }
        lock.lock()
        let owner = Owner(principal)
        let ownedSessionCount = sessions.values.filter {
            $0.owner.userID == owner.userID && ![.finished, .failed, .cancelled].contains($0.state)
        }.count
        let hasCapacity = ownedSessionCount < policy.maximumConcurrentStreams && (
            activeSessionCountLocked() < configuration.maximumTranscodeSessions ||
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
        let inputURL = bridge?.inputURL ?? asset.fileURL
        let input = bridge == nil
            ? ServerMediaToolchain.inputArgument(for: inputURL)
            : inputURL.absoluteString
        let playlist = directory.appendingPathComponent("index.m3u8")
        let buildLaunch: (ServerHLSPreparedMedia) -> PreparedLaunch? = { prepared in
            guard prepared.actualStartSeconds.isFinite,
                  prepared.actualStartSeconds >= 0,
                  prepared.actualStartSeconds < 86_400
            else { return nil }
            let normalizedVideoCodec = prepared.videoCodec?.lowercased()
            let targetHeight = Self.targetVideoHeight(
                quality: request.quality ?? .auto,
                sourceHeight: prepared.videoHeight,
                capabilities: request.capabilities
            )
            let preservesHDR = prepared.sourceIsHDR && request.capabilities?.hdrDisplay == true &&
                targetHeight == nil && burnInSubtitleStreamIndex == nil &&
                ["hevc", "h265"].contains(normalizedVideoCodec ?? "") &&
                request.capabilities?.nativeHLS == true &&
                request.capabilities?.videoCodecs.contains(where: {
                    ["hevc", "h265", "hvc1"].contains($0.lowercased())
                }) == true
            let toneMapsHDR = prepared.sourceIsHDR && !preservesHDR
            guard !toneMapsHDR || self.ffmpegFilterCapabilities.softwareHDRToneMapping else {
                return nil
            }
            let copiesVideo = !toneMapsHDR && burnInSubtitleStreamIndex == nil && targetHeight == nil && (
                normalizedVideoCodec == "h264" || (
                    ["hevc", "h265"].contains(normalizedVideoCodec ?? "") &&
                    request.capabilities?.nativeHLS == true &&
                    request.capabilities?.videoCodecs.contains(where: {
                        ["hevc", "h265", "hvc1"].contains($0.lowercased())
                    }) == true
                )
            )
            let copiesAudio = prepared.audioCodec?.lowercased() == "aac"
            let mode = copiesVideo
                ? (copiesAudio ? "hlsRemux" : "hlsAudioTranscode")
                : "hlsTranscode"
            guard (mode == "hlsRemux" && policy.remuxAllowed) ||
                    (mode != "hlsRemux" && policy.transcodeAllowed)
            else { return nil }
            let reason = burnInSubtitleStreamIndex != nil
                ? "bitmapSubtitleCompatibility"
                : targetHeight != nil
                ? "qualityCompatibility"
                : copiesVideo
                ? (copiesAudio ? "containerCompatibility" : "audioCodecCompatibility")
                : "videoCodecCompatibility"
            // Apple clients accept HEVC in HLS through fragmented MP4. H.264
            // and H.264 transcodes retain the mature MPEG-TS path.
            let usesFragmentedMP4 = copiesVideo &&
                ["hevc", "h265"].contains(normalizedVideoCodec ?? "")
            let segmentExtension = usesFragmentedMP4 ? "m4s" : "ts"
            let segmentPattern = directory
                .appendingPathComponent("segment-%05d.\(segmentExtension)").path
            let hdrFilter = toneMapsHDR ? Self.softwareHDRToneMappingFilter : nil
            let bitrate = Self.effectiveBitrateMbps(
                request: request,
                policy: policy,
                defaultValue: configuration.defaultRemoteBitrateMbps,
                targetHeight: targetHeight
            )
            let encoderArguments = Self.encoderArguments(for: configuration.transcodeEngine)
            // Input-side seeking is fast, but Matroska can land video on the
            // preceding keyframe while TrueHD/DTS begins at the requested
            // timestamp. That produces valid-looking HLS with seconds of silent
            // video. Seek at most ten seconds earlier, burst-read only that
            // bounded preroll, then trim on the output timeline. Copied video
            // retains 250 ms before its resolved keyframe: trimming at the exact
            // timestamp can make ffmpeg select the *next* keyframe and emit a
            // zero-duration stream near EOF. The descriptor reports this real
            // stream origin so the client can seek the remaining fraction.
            let streamStartSeconds = copiesVideo
                ? max(0, prepared.actualStartSeconds - 0.25)
                : prepared.actualStartSeconds
            let inputSeekSeconds = max(0, streamStartSeconds - 10)
            let outputTrimSeconds = streamStartSeconds - inputSeekSeconds
            var arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.3f", inputSeekSeconds)
            ]
            if outputTrimSeconds > 0.001 {
                arguments += [
                    "-readrate", "1",
                    "-readrate_initial_burst", String(format: "%.3f", outputTrimSeconds + 1)
                ]
            } else {
                // Keep steady-state generation near playback speed. Combined
                // with the sliding playlist this bounds temporary storage.
                arguments += ["-re"]
            }
            arguments += ["-i", input]
            if outputTrimSeconds > 0.001 {
                arguments += ["-ss", String(format: "%.3f", outputTrimSeconds)]
            }
            if let burnInSubtitleStreamIndex {
                let graph: String
                let inputVideo = hdrFilter.map { "[0:v:0]\($0)[toned]" }
                let videoLabel = hdrFilter == nil ? "[0:v:0]" : "[toned]"
                if let targetHeight {
                    graph = [
                        inputVideo,
                        "\(videoLabel)[0:\(burnInSubtitleStreamIndex)]overlay=eof_action=pass[burned]",
                        "[burned]scale=-2:min(\(targetHeight)\\,ih)[vout]"
                    ].compactMap { $0 }.joined(separator: ";")
                } else {
                    graph = [
                        inputVideo,
                        "\(videoLabel)[0:\(burnInSubtitleStreamIndex)]overlay=eof_action=pass[vout]"
                    ].compactMap { $0 }.joined(separator: ";")
                }
                arguments += [
                    "-filter_complex", graph,
                    "-map", "[vout]"
                ]
            } else {
                arguments += ["-map", "0:v:0?"]
                let filters = [
                    hdrFilter,
                    targetHeight.map { "scale=-2:min(\($0)\\,ih)" }
                ].compactMap { $0 }.joined(separator: ",")
                if !filters.isEmpty {
                    arguments += ["-vf", filters]
                }
            }
            arguments += [
                "-map", "0:a:\(request.audioTrackID ?? 0)?",
                "-sn", "-dn", "-map_chapters", "-1"
            ]
            if copiesVideo {
                arguments += ["-c:v", "copy"]
            } else {
                arguments += encoderArguments + [
                    "-pix_fmt", "yuv420p", "-b:v", "\(bitrate * 1_000)k",
                    "-maxrate", "\(bitrate * 1_250)k", "-bufsize", "\(bitrate * 2_000)k",
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
                "-hls_flags", "delete_segments+independent_segments+temp_file"
            ]
            if usesFragmentedMP4 {
                arguments += [
                    "-hls_segment_type", "fmp4",
                    "-hls_fmp4_init_filename", "init.mp4"
                ]
            }
            arguments += ["-hls_segment_filename", segmentPattern, playlist.path]
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return PreparedLaunch(
                mode: mode,
                reason: reason,
                durationSeconds: prepared.durationSeconds,
                actualStartSeconds: streamStartSeconds,
                process: process
            )
        }

        let knownPrepared = ServerHLSPreparedMedia(
            videoCodec: videoCodec,
            videoHeight: videoHeight,
            sourceIsHDR: sourceIsHDR,
            audioCodec: audioCodec,
            durationSeconds: request.durationSeconds,
            actualStartSeconds: actualStartSeconds
        )
        let preview = preparationResolver == nil ? buildLaunch(knownPrepared) : nil
        guard preparationResolver != nil || preview != nil else {
            bridge?.stop()
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let launchBuilder: (ServerBoundedProcess.Cancellation) -> PreparedLaunch? = { cancellation in
            guard !cancellation.isCancelled else { return nil }
            if let preparationResolver {
                guard let prepared = preparationResolver(inputURL, cancellation),
                      !cancellation.isCancelled
                else { return nil }
                return buildLaunch(prepared)
            }
            let resolvedStart = startResolver?(cancellation) ?? actualStartSeconds
            guard !cancellation.isCancelled else { return nil }
            return buildLaunch(ServerHLSPreparedMedia(
                videoCodec: videoCodec,
                videoHeight: videoHeight,
                sourceIsHDR: sourceIsHDR,
                audioCodec: audioCodec,
                durationSeconds: request.durationSeconds,
                actualStartSeconds: resolvedStart
            ))
        }

        let session = Session(
            id: id,
            owner: Owner(principal),
            directory: directory,
            actualStartSeconds: actualStartSeconds,
            durationSeconds: preview?.durationSeconds ?? request.durationSeconds,
            mode: preview?.mode ?? "hlsPreparing",
            reason: preview?.reason ?? "capabilityNegotiation",
            mediaURL: "/api/v1/playback/hls/\(id)/index.m3u8",
            bridge: bridge,
            launchBuilder: launchBuilder
        )
        beforeReservation?()
        lock.lock()
        // Recheck *every* capacity boundary while reserving. The preflight above
        // deliberately releases the lock before directory/bridge construction;
        // without this owner count, simultaneous requests from one account can
        // all observe the same old value and enqueue past maximumConcurrentStreams.
        let reservedOwnedSessionCount = sessions.values.filter {
            $0.owner.userID == owner.userID && ![.finished, .failed, .cancelled].contains($0.state)
        }.count
        let shouldLaunch = activeSessionCountLocked() < configuration.maximumTranscodeSessions
        guard reservedOwnedSessionCount < policy.maximumConcurrentStreams,
              shouldLaunch || pendingSessionIDs.count < Self.maximumQueuedSessions else {
            lock.unlock()
            stopAndRemove(session)
            return nil
        }
        session.state = shouldLaunch ? .preparing : .queued
        sessions[id] = session
        if !shouldLaunch { pendingSessionIDs.append(id) }
        let initialDescriptor = session.descriptor
        lock.unlock()
        if shouldLaunch { _ = launch(session) }
        return initialDescriptor
    }

    static let softwareHDRToneMappingFilter = "zscale=t=linear:npl=100,format=gbrpf32le,tonemap=tonemap=hable:desat=0,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p"

    static func encoderArguments(for engine: ServerTranscodeEngine) -> [String] {
        switch engine {
        case .software: ["-c:v", "libx264", "-preset", "medium"]
        case .automatic: ["-c:v", "h264_videotoolbox", "-allow_sw", "1"]
        case .videoToolbox: ["-c:v", "h264_videotoolbox", "-allow_sw", "0"]
        }
    }

    static func targetVideoHeight(
        quality: ServerPlaybackQuality,
        sourceHeight: Int?,
        capabilities: ServerWebClientCapabilities?
    ) -> Int? {
        guard let sourceHeight, sourceHeight > 0 else { return nil }
        let requested: Int?
        switch quality {
        case .original: requested = nil
        case .quality2160p: requested = 2_160
        case .quality1080p: requested = 1_080
        case .quality720p: requested = 720
        case .quality480p: requested = 480
        case .auto:
            let screen = capabilities.map { max($0.screenWidth, $0.screenHeight) } ?? sourceHeight
            let networkCap: Int
            switch capabilities?.measuredDownlinkMbps {
            case let value? where value < 5: networkCap = 480
            case let value? where value < 10: networkCap = 720
            case let value? where value < 20: networkCap = 1_080
            default: networkCap = 2_160
            }
            requested = min(screen, networkCap)
        }
        guard let requested, requested < sourceHeight else { return nil }
        return requested >= 2_160 ? 2_160 : requested >= 1_080 ? 1_080 : requested >= 720 ? 720 : 480
    }

    static func effectiveBitrateMbps(
        request: ServerHLSPlaybackRequest,
        policy: ServerUserPolicy,
        defaultValue: Int,
        targetHeight: Int?
    ) -> Int {
        var cap = request.maximumBitrateMbps ?? defaultValue
        if let policyCap = policy.remoteBitrateLimitMbps { cap = min(cap, policyCap) }
        if let measured = request.capabilities?.measuredDownlinkMbps {
            cap = min(cap, max(1, Int((measured * 0.8).rounded(.down))))
        }
        let tierCap = switch targetHeight {
        case 480: 4
        case 720: 8
        case 1_080: 16
        case 2_160: 40
        default: defaultValue
        }
        return min(max(cap, 1), tierCap)
    }

    func status(sessionID: String, principal: ServerRequestPrincipal) -> ServerHLSPlaybackDescriptor? {
        prune()
        guard Self.isSafeSessionID(sessionID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID], session.owner == Owner(principal) else { return nil }
        session.lastAccessedAt = Date()
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
        session.lastAccessedAt = Date()
        if session.state == .ready { session.state = .playing }
        lock.unlock()
        return ServerHLSResource(
            fileURL: url,
            byteLength: Int64(size),
            contentType: Self.resourceContentType(fileName)
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

    func administrativeSessions() -> [ServerAdminHLSPlaybackSession] {
        prune()
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.map {
            ServerAdminHLSPlaybackSession(
                sessionID: $0.id,
                userID: $0.owner.userID,
                state: $0.state,
                mode: $0.mode,
                startedAt: $0.startedAt,
                lastAccessedAt: $0.lastAccessedAt,
                durationSeconds: $0.durationSeconds
            )
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.sessionID < $1.sessionID
        }
    }

    @discardableResult
    func administrativelyCancel(sessionID: String) -> Bool {
        guard Self.isSafeSessionID(sessionID) else { return false }
        lock.lock()
        guard let session = sessions.removeValue(forKey: sessionID) else {
            lock.unlock()
            return false
        }
        session.state = .cancelled
        session.finishedAt = Date()
        pendingSessionIDs.removeAll { $0 == sessionID }
        lock.unlock()
        stopAndRemove(session)
        startNextIfPossible()
        return true
    }

    /// 管理维护只通过后台任务调用：先从状态机原子摘除全部会话，再终止进程、
    /// 远程桥与私有目录。返回值仅是会话数量，不暴露目录或媒体标识。
    func clearAllSessionsAndCache() -> Int {
        lock.lock()
        let current = Array(sessions.values)
        sessions.removeAll()
        pendingSessionIDs.removeAll()
        lock.unlock()
        current.forEach(stopAndRemove)
        try? FileManager.default.removeItem(at: rootDirectory)
        try? FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return current.count
    }

    private func prune() {
        let now = Date()
        let idleLifetime = TimeInterval(currentConfiguration().sessionIdleMinutes * 60)
        lock.lock()
        let stale = sessions.values.filter { session in
            if let finishedAt = session.finishedAt {
                return now.timeIntervalSince(finishedAt) > Self.finishedRetention
            }
            return now.timeIntervalSince(session.lastAccessedAt) > idleLifetime
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
        session.preparationCancellation.cancel()
        session.bridge?.stop()
        if let process = session.process, process.isRunning {
            ServerBoundedProcess.terminate(process)
        }
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
                if let process = session.process, process.isRunning {
                    ServerBoundedProcess.terminate(process)
                }
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
        preparationQueue.async { [weak self, weak session] in
            guard let self, let session else { return }
            self.prepareAndLaunch(session)
        }
        return true
    }

    private func prepareAndLaunch(_ session: Session) {
        lock.lock()
        guard sessions[session.id] === session, session.state == .preparing else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let launch = session.launchBuilder(session.preparationCancellation) else {
            guard !session.preparationCancellation.isCancelled else { return }
            lock.lock()
            let shouldAdvanceQueue = sessions[session.id] === session && session.state == .preparing
            if shouldAdvanceQueue {
                session.state = .failed
                session.finishedAt = Date()
            }
            lock.unlock()
            if shouldAdvanceQueue {
                session.bridge?.stop()
                startNextIfPossible()
            }
            return
        }
        guard !session.preparationCancellation.isCancelled else { return }
        let process = launch.process
        process.terminationHandler = { [weak self, weak session] process in
            guard let self, let session else { return }
            self.processDidTerminate(
                session,
                succeeded: process.terminationReason == .exit && process.terminationStatus == 0
            )
        }
        lock.lock()
        guard sessions[session.id] === session, session.state == .preparing else {
            lock.unlock()
            return
        }
        session.actualStartSeconds = launch.actualStartSeconds
        session.durationSeconds = launch.durationSeconds
        session.mode = launch.mode
        session.reason = launch.reason
        session.process = process
        lock.unlock()

        do {
            try process.run()
            lock.lock()
            let stillActive = sessions[session.id] === session && session.state == .preparing
            lock.unlock()
            guard stillActive else {
                ServerBoundedProcess.terminate(process, forceAfter: 0)
                return
            }
            monitorReadiness(
                of: session,
                playlist: session.directory.appendingPathComponent("index.m3u8")
            )
        } catch {
            lock.lock()
            if sessions[session.id] === session {
                session.state = .failed
                session.finishedAt = Date()
            }
            lock.unlock()
            session.bridge?.stop()
            startNextIfPossible()
        }
    }

    private func processDidTerminate(_ session: Session, succeeded: Bool) {
        let playlist = session.directory.appendingPathComponent("index.m3u8")
        let hasCompletedPlaylist: Bool = {
            guard succeeded,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: playlist.path),
                  let size = attributes[.size] as? NSNumber
            else { return false }
            return size.intValue > 0
        }()
        lock.lock()
        session.readinessTimer?.cancel()
        session.readinessTimer = nil
        if session.state != .cancelled && session.state != .failed {
            // A short seek near EOF can finish before the 50 ms readiness poll.
            // A successful process plus a non-empty manifest is a complete VOD,
            // not a preparation failure, and remains readable during retention.
            session.state = hasCompletedPlaylist ? .finished : .failed
            session.finishedAt = Date()
        }
        lock.unlock()
        session.bridge?.stop()
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        while true {
            let maximumConcurrentSessions = currentConfiguration().maximumTranscodeSessions
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

    private func currentConfiguration() -> ServerOperationalSettings {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(configurationFetchedAt) >= configurationCacheLifetime else {
            return cachedConfiguration
        }
        let candidate = configurationProvider()
        if candidate.isValid { cachedConfiguration = candidate }
        configurationFetchedAt = now
        return cachedConfiguration
    }

    /// Internal observability for deterministic configuration regression tests.
    func operationalSettingsSnapshot() -> ServerOperationalSettings { currentConfiguration() }

    private func hasStorageCapacity(for configuration: ServerOperationalSettings) -> Bool {
        let limit = Int64(configuration.temporaryStorageLimitGB) * 1_024 * 1_024 * 1_024
        guard Self.directoryByteCount(rootDirectory, stoppingAt: limit) < limit else { return false }
        guard let values = try? rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        let reserve = Int64(configuration.minimumFreeDiskGB) * 1_024 * 1_024 * 1_024
        return available > reserve
    }

    private static func directoryByteCount(_ directory: URL, stoppingAt limit: Int64) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? 0)
            if total >= limit { return total }
        }
        return total
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
        if value == "init.mp4" { return true }
        guard value.hasPrefix("segment-") else { return false }
        let suffixLength: Int
        if value.hasSuffix(".ts") { suffixLength = 3 }
        else if value.hasSuffix(".m4s") { suffixLength = 4 }
        else { return false }
        let digits = value.dropFirst("segment-".count).dropLast(suffixLength)
        return digits.count == 5 && digits.allSatisfy(\.isNumber)
    }

    private static func resourceContentType(_ fileName: String) -> String {
        if fileName.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if fileName == "init.mp4" { return "video/mp4" }
        if fileName.hasSuffix(".m4s") { return "video/iso.segment" }
        return "video/mp2t"
    }

    static func supportsKeyframeAlignedSeek(videoCodec: String?) -> Bool {
        guard let codec = videoCodec?.lowercased() else { return false }
        return ["h264", "hevc", "h265"].contains(codec)
    }
}
