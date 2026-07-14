import Foundation
import MediaLibServerProtocol

/// HLS 会话生命周期：每个认证会话拥有隔离的临时目录和 FFmpeg 进程，取消时同时终止
/// 进程并移除目录。HTTP 资源路由和用户权限已经接入；逐用户播放状态上报仍在后续阶段。
final class FFmpegHLSSessionManager {
    typealias Clock = () -> Date
    typealias ProcessFactory = (
        _ executableURL: URL,
        _ arguments: [String],
        _ onTermination: @escaping (Int32) -> Void
    ) throws -> HLSManagedProcess

    private let lock = NSLock()
    private let cacheDirectory: URL
    private let executableURLProvider: () -> URL?
    private let processFactory: ProcessFactory
    private let maximumConcurrentSessions: Int
    private let maximumRetainedSessions: Int
    private let idleSessionLifetime: TimeInterval
    private let clock: Clock
    private var sessions: [String: Session] = [:]
    private var pendingStarts = 0

    init(
        cacheDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibServer-HLS", isDirectory: true),
        executableURLProvider: @escaping () -> URL? = FFmpegHLSSessionManager.defaultExecutableURL,
        processFactory: @escaping ProcessFactory = FoundationHLSProcess.init,
        maximumConcurrentSessions: Int = 2,
        maximumRetainedSessions: Int = 8,
        idleSessionLifetime: TimeInterval = 30 * 60,
        clock: @escaping Clock = Date.init
    ) {
        precondition(maximumConcurrentSessions > 0)
        precondition(maximumRetainedSessions >= maximumConcurrentSessions)
        precondition(idleSessionLifetime > 0)
        self.cacheDirectory = cacheDirectory
        self.executableURLProvider = executableURLProvider
        self.processFactory = processFactory
        self.maximumConcurrentSessions = max(maximumConcurrentSessions, 1)
        self.maximumRetainedSessions = maximumRetainedSessions
        self.idleSessionLifetime = idleSessionLifetime
        self.clock = clock
    }

    deinit {
        cancelAll()
    }

    func start(asset: ServerMediaAsset, ownerSessionID: String) throws -> ServerHLSPlaybackSession {
        guard !ownerSessionID.isEmpty else { throw FFmpegHLSSessionManagerError.invalidOwner }
        pruneSessions(retainingAtMost: maximumRetainedSessions - 1)
        lock.lock()
        let runningCount = sessions.values.filter { $0.process?.isRunning == true }.count
        let hasCapacity = runningCount + pendingStarts < maximumConcurrentSessions
        if hasCapacity { pendingStarts += 1 }
        lock.unlock()
        guard hasCapacity else { throw FFmpegHLSSessionManagerError.capacityReached }
        defer {
            lock.lock()
            pendingStarts -= 1
            lock.unlock()
        }
        guard let executableURL = executableURLProvider() else {
            throw FFmpegHLSSessionManagerError.unavailable
        }
        let identifier = UUID().uuidString.lowercased()
        let directory = cacheDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("index.m3u8")
        let session = Session(
            id: identifier,
            itemID: asset.id,
            ownerSessionID: ownerSessionID,
            directory: directory,
            lastAccessAt: clock()
        )

        do {
            let process = try processFactory(executableURL, Self.arguments(for: asset, manifestURL: manifestURL)) {
                [weak self] exitCode in
                self?.recordTermination(sessionID: identifier, exitCode: exitCode)
            }
            session.process = process
            lock.lock()
            sessions[identifier] = session
            lock.unlock()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw FFmpegHLSSessionManagerError.startFailed
        }

        return ServerHLSPlaybackSession(
            id: identifier,
            itemID: asset.id,
            manifestPath: "/api/v1/hls/\(identifier)/index.m3u8"
        )
    }

    /// 仅返回会话目录内、单层且存在的 HLS 产物；任何路径遍历或未知会话都被拒绝。
    func outputURL(sessionID: String, fileName: String, ownerSessionID: String) -> URL? {
        guard Self.isSafeOutputName(fileName) else { return nil }
        pruneSessions(retainingAtMost: maximumRetainedSessions)
        lock.lock()
        let session = sessions[sessionID]
        if session?.ownerSessionID == ownerSessionID { session?.lastAccessAt = clock() }
        lock.unlock()
        guard let session, session.ownerSessionID == ownerSessionID else { return nil }
        let output = session.directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: output.path) else { return nil }
        return output
    }

    @discardableResult
    func cancel(sessionID: String, ownerSessionID: String) -> Bool {
        let session = removeSession(id: sessionID, ownerSessionID: ownerSessionID)
        session?.process?.terminate()
        if let session {
            try? FileManager.default.removeItem(at: session.directory)
        }
        return session != nil
    }

    func cancelAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for session in active {
            session.process?.terminate()
            try? FileManager.default.removeItem(at: session.directory)
        }
    }

    var activeSessionCount: Int {
        pruneSessions(retainingAtMost: maximumRetainedSessions)
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    static func arguments(for asset: ServerMediaAsset, manifestURL: URL) -> [String] {
        let directory = manifestURL.deletingLastPathComponent()
        return [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", asset.fileURL.path,
            "-map", "0:v:0?",
            "-map", "0:a:0?",
            "-c:v", "libx264",
            "-c:a", "aac",
            "-f", "hls",
            "-hls_time", "4",
            "-hls_list_size", "0",
            "-hls_segment_filename", directory.appendingPathComponent("segment-%05d.ts").path,
            manifestURL.path
        ]
    }

    private func removeSession(id: String, ownerSessionID: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard sessions[id]?.ownerSessionID == ownerSessionID else { return nil }
        return sessions.removeValue(forKey: id)
    }

    private func recordTermination(sessionID: String, exitCode: Int32) {
        lock.lock()
        sessions[sessionID]?.exitCode = exitCode
        lock.unlock()
    }

    /// 已完成的 VOD 清单在短期内继续供播放器读取；空闲过期或超过硬上限后，
    /// 即使客户端未成功发送 DELETE，也会在下一次服务访问时终止并删除。
    private func pruneSessions(retainingAtMost maximumCount: Int) {
        let now = clock()
        lock.lock()
        var removalIDs = sessions.values
            .filter { now.timeIntervalSince($0.lastAccessAt) >= idleSessionLifetime }
            .map(\.id)
        let retainedAfterExpiry = sessions.values.filter { !removalIDs.contains($0.id) }
        if retainedAfterExpiry.count > maximumCount {
            let overflow = retainedAfterExpiry.count - maximumCount
            let oldestInactive = retainedAfterExpiry
                .filter { $0.process?.isRunning != true }
                .sorted {
                    if $0.lastAccessAt != $1.lastAccessAt { return $0.lastAccessAt < $1.lastAccessAt }
                    return $0.id < $1.id
                }
                .prefix(overflow)
                .map(\.id)
            removalIDs.append(contentsOf: oldestInactive)
        }
        let removed = Set(removalIDs).compactMap { sessions.removeValue(forKey: $0) }
        lock.unlock()
        for session in removed {
            session.process?.terminate()
            try? FileManager.default.removeItem(at: session.directory)
        }
    }

    private static func isSafeOutputName(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == URL(fileURLWithPath: value).lastPathComponent,
              !value.contains("..")
        else {
            return false
        }
        return value == "index.m3u8" ||
            (value.hasPrefix("segment-") && value.hasSuffix(".ts"))
    }

    private static func defaultExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffmpeg"),
            CommandLine.arguments.first.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("ffmpeg")
            },
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/bin/ffmpeg")
        ].compactMap { $0 }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private final class Session {
        let id: String
        let itemID: String
        let ownerSessionID: String
        let directory: URL
        var lastAccessAt: Date
        var process: HLSManagedProcess?
        var exitCode: Int32?

        init(id: String, itemID: String, ownerSessionID: String, directory: URL, lastAccessAt: Date) {
            self.id = id
            self.itemID = itemID
            self.ownerSessionID = ownerSessionID
            self.directory = directory
            self.lastAccessAt = lastAccessAt
        }
    }
}

protocol HLSManagedProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

private final class FoundationHLSProcess: HLSManagedProcess {
    private let process: Process

    init(
        executableURL: URL,
        arguments: [String],
        onTermination: @escaping (Int32) -> Void
    ) throws {
        let process = Process()
        self.process = process
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { terminated in
            onTermination(terminated.terminationStatus)
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

enum FFmpegHLSSessionManagerError: LocalizedError {
    case unavailable
    case startFailed
    case capacityReached
    case invalidOwner

    var errorDescription: String? {
        switch self {
        case .unavailable: return "ffmpeg 不可用。"
        case .startFailed: return "无法启动 HLS 转码会话。"
        case .capacityReached: return "HLS 转码会话已达到并发上限。"
        case .invalidOwner: return "HLS 会话缺少有效所有者。"
        }
    }
}
