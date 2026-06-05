import AppKit
import Foundation

public struct ExternalPlayer: Identifiable, Hashable {
    public var id: String { bundleIdentifier ?? path }
    public var name: String
    public var path: String
    public var bundleIdentifier: String?
}

public enum ExternalPlayerError: LocalizedError {
    case missingFile
    case invalidURL
    case applicationNotFound(String)
    case openFailed

    public var errorDescription: String? {
        switch self {
        case .missingFile: return "视频文件不存在或 NAS 未连接"
        case .invalidURL: return "媒体地址无效"
        case .applicationNotFound(let name): return "未找到外部播放器：\(name)"
        case .openFailed: return "无法调用外部播放器"
        }
    }
}

public final class ExternalPlayerService {
    private let workspace: NSWorkspace
    private let cacheLock = NSLock()
    private var cachedKnownPlayers: [ExternalPlayer]?
    private var cachedAvailablePlayersByCustomPath: [String: [ExternalPlayer]] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appActivationObserver: NSObjectProtocol?

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        let center = workspace.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.invalidatePlayerCache()
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.invalidatePlayerCache()
            }
        ]
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidatePlayerCache()
        }
    }

    deinit {
        for observer in workspaceObservers {
            workspace.notificationCenter.removeObserver(observer)
        }
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
    }

    public var knownPlayers: [ExternalPlayer] {
        cacheLock.lock()
        if let cachedKnownPlayers {
            cacheLock.unlock()
            return cachedKnownPlayers
        }
        cacheLock.unlock()

        let discovered = knownPlayerDefinitions.map { definition in
            let discoveredURL = workspace.urlForApplication(withBundleIdentifier: definition.bundleIdentifier)
            return ExternalPlayer(
                name: definition.name,
                path: discoveredURL?.path ?? definition.fallbackPath,
                bundleIdentifier: definition.bundleIdentifier
            )
        }
        cacheLock.lock()
        cachedKnownPlayers = discovered
        cacheLock.unlock()
        return discovered
    }

    public func availablePlayers(customPath: String? = nil) -> [ExternalPlayer] {
        let cacheKey = customPath ?? ""
        cacheLock.lock()
        if let cached = cachedAvailablePlayersByCustomPath[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var players = knownPlayers.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let customPath, FileManager.default.fileExists(atPath: customPath) {
            let customPlayer = ExternalPlayer(name: URL(fileURLWithPath: customPath).deletingPathExtension().lastPathComponent, path: customPath, bundleIdentifier: nil)
            if !players.contains(where: { $0.path == customPlayer.path }) {
                players.append(customPlayer)
            }
        }
        cacheLock.lock()
        cachedAvailablePlayersByCustomPath[cacheKey] = players
        cacheLock.unlock()
        return players
    }

    /// 外部播放器安装、退出或设置路径变化后刷新；普通 SwiftUI 重算只读取缓存。
    public func invalidatePlayerCache() {
        cacheLock.lock()
        cachedKnownPlayers = nil
        cachedAvailablePlayersByCustomPath.removeAll(keepingCapacity: true)
        cacheLock.unlock()
    }

    public func open(filePath: String, preferredPlayerPath: String?) throws {
        let remoteURL = URL(string: filePath)
        let isRemote = ["http", "https"].contains(remoteURL?.scheme?.lowercased())
        guard isRemote || FileManager.default.fileExists(atPath: filePath) else {
            throw ExternalPlayerError.missingFile
        }
        let videoURL: URL
        if isRemote {
            guard let remoteURL else { throw ExternalPlayerError.invalidURL }
            videoURL = remoteURL
        } else {
            videoURL = URL(fileURLWithPath: filePath)
        }

        if let preferredPlayerPath, !preferredPlayerPath.isEmpty {
            try open(videoURL, withApplicationAtPath: preferredPlayerPath)
            return
        }

        if isRemote, let player = availablePlayers().first {
            try open(videoURL, withApplicationAtPath: player.path)
            return
        }

        guard workspace.open(videoURL) else {
            throw ExternalPlayerError.openFailed
        }
    }

    private func open(_ mediaURL: URL, withApplicationAtPath path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ExternalPlayerError.applicationNotFound(URL(fileURLWithPath: path).lastPathComponent)
        }
        let appURL = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        workspace.open([mediaURL], withApplicationAt: appURL, configuration: configuration)
    }

    private var knownPlayerDefinitions: [(name: String, fallbackPath: String, bundleIdentifier: String)] {
        [
            ("IINA", "/Applications/IINA.app", "com.colliderli.iina"),
            ("VLC", "/Applications/VLC.app", "org.videolan.vlc"),
            ("Movist Pro", "/Applications/Movist Pro.app", "com.movist.MovistPro"),
            ("QuickTime Player", "/System/Applications/QuickTime Player.app", "com.apple.QuickTimePlayerX")
        ]
    }
}
