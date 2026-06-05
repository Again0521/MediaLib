import Foundation

public struct AppDirectories {
    public let applicationSupport: URL
    public let database: URL
    public let databaseBackups: URL
    public let cache: URL
    public let thumbnails: URL
    public let logs: URL
}

public enum FileAccessService {
    public static func appDirectories(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "com.local.MediaLib"
    ) throws -> AppDirectories {
        let supportBase = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheBase = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appSupport = supportBase.appendingPathComponent("MediaLib", isDirectory: true)
        let cache = cacheBase.appendingPathComponent("MediaLib", isDirectory: true)
        let thumbnails = cache.appendingPathComponent("Thumbnails", isDirectory: true)
        let logs = appSupport.appendingPathComponent("Logs", isDirectory: true)
        let databaseBackups = appSupport.appendingPathComponent("DatabaseBackups", isDirectory: true)

        for directory in [appSupport, cache, thumbnails, logs, databaseBackups] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return AppDirectories(
            applicationSupport: appSupport,
            database: appSupport.appendingPathComponent("MediaLib.sqlite"),
            databaseBackups: databaseBackups,
            cache: cache,
            thumbnails: thumbnails,
            logs: logs
        )
    }

    public static func isReachableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
