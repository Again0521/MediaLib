import Foundation

public struct AppDirectories: Sendable {
    public let applicationSupport: URL
    public let database: URL
    public let databaseBackups: URL
    public let cache: URL
    public let thumbnails: URL
    public let previewFrames: URL
    public let logs: URL
}

struct AppDirectoryIO: @unchecked Sendable {
    let urlForDirectory: (FileManager.SearchPathDirectory) throws -> URL
    let createDirectory: (URL) throws -> Void

    static func fileSystem(fileManager: FileManager) -> AppDirectoryIO {
        AppDirectoryIO(
            urlForDirectory: { directory in
                try fileManager.url(
                    for: directory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            },
            createDirectory: { directory in
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        )
    }
}

public enum FileAccessService {
    public static func appDirectories(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "com.local.MediaLib"
    ) throws -> AppDirectories {
        try appDirectories(
            io: .fileSystem(fileManager: fileManager),
            bundleIdentifier: bundleIdentifier
        )
    }

    static func appDirectories(
        io: AppDirectoryIO,
        bundleIdentifier: String = "com.local.MediaLib"
    ) throws -> AppDirectories {
        let supportBase = try io.urlForDirectory(.applicationSupportDirectory)
        let cacheBase = try io.urlForDirectory(.cachesDirectory)

        let appSupport = supportBase.appendingPathComponent("MediaLib", isDirectory: true)
        let cache = cacheBase.appendingPathComponent("MediaLib", isDirectory: true)
        let thumbnails = cache.appendingPathComponent("Thumbnails", isDirectory: true)
        let previewFrames = cache.appendingPathComponent("PreviewFrames", isDirectory: true)
        let logs = appSupport.appendingPathComponent("Logs", isDirectory: true)
        let databaseBackups = appSupport.appendingPathComponent("DatabaseBackups", isDirectory: true)

        for directory in [appSupport, cache, thumbnails, previewFrames, logs, databaseBackups] {
            try io.createDirectory(directory)
        }

        return AppDirectories(
            applicationSupport: appSupport,
            database: appSupport.appendingPathComponent("MediaLib.sqlite"),
            databaseBackups: databaseBackups,
            cache: cache,
            thumbnails: thumbnails,
            previewFrames: previewFrames,
            logs: logs
        )
    }

    public static func appDirectoriesAsync(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "com.local.MediaLib"
    ) async throws -> AppDirectories {
        try await appDirectoriesAsync(
            io: .fileSystem(fileManager: fileManager),
            bundleIdentifier: bundleIdentifier
        )
    }

    static func appDirectoriesAsync(
        io: AppDirectoryIO,
        bundleIdentifier: String = "com.local.MediaLib"
    ) async throws -> AppDirectories {
        try await BlockingIOExecutor.run {
            try appDirectories(io: io, bundleIdentifier: bundleIdentifier)
        }
    }

    public static func isReachableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public static func isReachableDirectoryAsync(_ path: String) async -> Bool {
        await BlockingIOExecutor.run {
            isReachableDirectory(path)
        }
    }
}
