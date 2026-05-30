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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
