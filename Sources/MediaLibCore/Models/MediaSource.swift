import Foundation

public struct MediaSource: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var path: String
    public var mediaType: MediaType
    public var recursive: Bool
    public var autoScan: Bool
    public var minimumFileSize: Int64
    public var ignoreHiddenFiles: Bool
    public var readNFO: Bool
    public var preferLocalArtwork: Bool
    public var networkScrapingEnabled: Bool
    public var screenshotFallbackEnabled: Bool
    /// 是否参与"一键拉取元数据"（剧集 TMDB / 音乐补全）。
    public var includeInMetadataFetch: Bool
    /// 一键补充时是否优先把可写字段写回媒体源目录或媒体文件；不可写/远程来源会回落到 MediaLIB 索引。
    public var preferMetadataWriteToSource: Bool
    /// 是否参与"片库健康"检查（离线/失效/重复/元数据缺口）。
    public var includeInHealthCheck: Bool
    /// Emby 痕迹数据同步策略：控制播放记录、收藏和已观看状态是否与服务端互写。
    public var remoteTraceSyncMode: RemoteTraceSyncMode
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        mediaType: MediaType = .auto,
        recursive: Bool = true,
        autoScan: Bool = true,
        minimumFileSize: Int64 = 50 * 1024 * 1024,
        ignoreHiddenFiles: Bool = true,
        readNFO: Bool = true,
        preferLocalArtwork: Bool = true,
        networkScrapingEnabled: Bool = true,
        screenshotFallbackEnabled: Bool = true,
        includeInMetadataFetch: Bool = true,
        preferMetadataWriteToSource: Bool = false,
        includeInHealthCheck: Bool = true,
        remoteTraceSyncMode: RemoteTraceSyncMode = .bidirectional,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.mediaType = mediaType
        self.recursive = recursive
        self.autoScan = autoScan
        self.minimumFileSize = minimumFileSize
        self.ignoreHiddenFiles = ignoreHiddenFiles
        self.readNFO = readNFO
        self.preferLocalArtwork = preferLocalArtwork
        self.networkScrapingEnabled = networkScrapingEnabled
        self.screenshotFallbackEnabled = screenshotFallbackEnabled
        self.includeInMetadataFetch = includeInMetadataFetch
        self.preferMetadataWriteToSource = preferMetadataWriteToSource
        self.includeInHealthCheck = includeInHealthCheck
        self.remoteTraceSyncMode = remoteTraceSyncMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case mediaType
        case recursive
        case autoScan
        case minimumFileSize
        case ignoreHiddenFiles
        case readNFO
        case preferLocalArtwork
        case networkScrapingEnabled
        case screenshotFallbackEnabled
        case includeInMetadataFetch
        case preferMetadataWriteToSource
        case includeInHealthCheck
        case remoteTraceSyncMode
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try container.decode(String.self, forKey: .name),
            path: try container.decode(String.self, forKey: .path),
            mediaType: try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .auto,
            recursive: try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? true,
            autoScan: try container.decodeIfPresent(Bool.self, forKey: .autoScan) ?? true,
            minimumFileSize: try container.decodeIfPresent(Int64.self, forKey: .minimumFileSize) ?? 50 * 1024 * 1024,
            ignoreHiddenFiles: try container.decodeIfPresent(Bool.self, forKey: .ignoreHiddenFiles) ?? true,
            readNFO: try container.decodeIfPresent(Bool.self, forKey: .readNFO) ?? true,
            preferLocalArtwork: try container.decodeIfPresent(Bool.self, forKey: .preferLocalArtwork) ?? true,
            networkScrapingEnabled: try container.decodeIfPresent(Bool.self, forKey: .networkScrapingEnabled) ?? true,
            screenshotFallbackEnabled: try container.decodeIfPresent(Bool.self, forKey: .screenshotFallbackEnabled) ?? true,
            includeInMetadataFetch: try container.decodeIfPresent(Bool.self, forKey: .includeInMetadataFetch) ?? true,
            preferMetadataWriteToSource: try container.decodeIfPresent(Bool.self, forKey: .preferMetadataWriteToSource) ?? false,
            includeInHealthCheck: try container.decodeIfPresent(Bool.self, forKey: .includeInHealthCheck) ?? true,
            remoteTraceSyncMode: try container.decodeIfPresent(RemoteTraceSyncMode.self, forKey: .remoteTraceSyncMode) ?? .bidirectional,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var sourceKind: MediaSourceKind {
        if path.hasPrefix("emby://") {
            return .emby
        }
        if path.hasPrefix("smb://") {
            return .smb
        }
        if path.hasPrefix("ftp://") || path.hasPrefix("ftps://") {
            return .ftp
        }
        if name.hasPrefix("SMB ") {
            return .smb
        }
        if name.hasPrefix("FTP ") || name.hasPrefix("FTPS ") {
            return .ftp
        }
        return .local
    }

    public var exists: Bool {
        if sourceKind == .emby {
            return true
        }
        return FileManager.default.fileExists(atPath: path)
    }

    public var displayPath: String {
        guard let components = URLComponents(string: path),
              let scheme = components.scheme,
              ["emby", "smb", "ftp", "ftps"].contains(scheme.lowercased()) else {
            return path
        }
        var sanitized = components
        sanitized.user = nil
        sanitized.password = nil
        return sanitized.string ?? path
    }
}

public enum MediaSourceKind: String, Codable, Hashable {
    case local
    case emby
    case smb
    case ftp
}

public enum RemoteTraceSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bidirectional
    case importOnly
    case disabled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bidirectional: return "数据双向同步"
        case .importOnly: return "仅从 Emby 同步"
        case .disabled: return "数据不同步"
        }
    }

    public var shortTitle: String {
        switch self {
        case .bidirectional: return "双向同步"
        case .importOnly: return "单向同步"
        case .disabled: return "不同步"
        }
    }

    public var detail: String {
        switch self {
        case .bidirectional:
            return "本地播放记录、收藏和已观看状态会与 Emby 互相更新。"
        case .importOnly:
            return "只接收 Emby 状态，不把本机痕迹写回服务器。"
        case .disabled:
            return "本机痕迹完全保留在 MediaLIB，不受 Emby 多人使用影响。"
        }
    }
}
