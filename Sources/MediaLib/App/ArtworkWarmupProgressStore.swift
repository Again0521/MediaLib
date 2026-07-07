import Foundation
import MediaLibCore

struct ArtworkWarmupProgressRecord: Codable, Equatable, Sendable {
    var sourceID: String
    var completedURLs: [String]
    var totalCount: Int
    var updatedAt: Date
}

enum ArtworkWarmupProgressStore {
    struct IO: @unchecked Sendable {
        let read: (URL) throws -> Data
        let write: (Data, URL) throws -> Void
        let remove: (URL) throws -> Void
        let exists: (URL) -> Bool

        init(
            read: @escaping (URL) throws -> Data,
            write: @escaping (Data, URL) throws -> Void,
            remove: @escaping (URL) throws -> Void,
            exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        ) {
            self.read = read
            self.write = write
            self.remove = remove
            self.exists = exists
        }

        static let fileSystem = IO(
            read: { url in
                try Data(contentsOf: url)
            },
            write: { data, url in
                try data.write(to: url, options: [.atomic])
            },
            remove: { url in
                try FileManager.default.removeItem(at: url)
            },
            exists: { url in
                FileManager.default.fileExists(atPath: url.path)
            }
        )
    }

    static func load(from url: URL?) async -> [String: ArtworkWarmupProgressRecord] {
        await load(from: url, io: .fileSystem)
    }

    static func load(from url: URL?, io: IO) async -> [String: ArtworkWarmupProgressRecord] {
        await BlockingIOExecutor.run {
            guard let url,
                  let data = try? io.read(url),
                  let decoded = try? JSONDecoder().decode([String: ArtworkWarmupProgressRecord].self, from: data) else {
                return [:]
            }
            return decoded
        }
    }

    static func record(
        for sourceID: String,
        from url: URL?
    ) async -> ArtworkWarmupProgressRecord? {
        await record(for: sourceID, from: url, io: .fileSystem)
    }

    static func record(
        for sourceID: String,
        from url: URL?,
        io: IO
    ) async -> ArtworkWarmupProgressRecord? {
        await load(from: url, io: io)[sourceID]
    }

    static func persist(
        sourceID: String,
        completedURLs: Set<String>,
        totalCount: Int,
        to url: URL?
    ) async throws {
        try await persist(sourceID: sourceID, completedURLs: completedURLs, totalCount: totalCount, to: url, io: .fileSystem)
    }

    static func persist(
        sourceID: String,
        completedURLs: Set<String>,
        totalCount: Int,
        to url: URL?,
        io: IO
    ) async throws {
        var records = await load(from: url, io: io)
        records[sourceID] = ArtworkWarmupProgressRecord(
            sourceID: sourceID,
            completedURLs: completedURLs.sorted(),
            totalCount: totalCount,
            updatedAt: Date()
        )
        try await save(records, to: url, io: io)
    }

    @discardableResult
    static func clear(sourceID: String, from url: URL?) async throws -> Bool {
        try await clear(sourceID: sourceID, from: url, io: .fileSystem)
    }

    @discardableResult
    static func clear(sourceID: String, from url: URL?, io: IO) async throws -> Bool {
        var records = await load(from: url, io: io)
        guard records.removeValue(forKey: sourceID) != nil else { return false }
        try await save(records, to: url, io: io)
        return true
    }

    @discardableResult
    static func removeFile(at url: URL?) async -> Bool {
        await removeFile(at: url, io: .fileSystem)
    }

    @discardableResult
    static func removeFile(at url: URL?, io: IO) async -> Bool {
        await BlockingIOExecutor.run {
            guard let url else { return false }
            guard io.exists(url) else { return true }
            do {
                try io.remove(url)
                return true
            } catch {
                return false
            }
        }
    }

    static func save(
        _ records: [String: ArtworkWarmupProgressRecord],
        to url: URL?
    ) async throws {
        try await save(records, to: url, io: .fileSystem)
    }

    static func save(
        _ records: [String: ArtworkWarmupProgressRecord],
        to url: URL?,
        io: IO
    ) async throws {
        try await BlockingIOExecutor.run {
            guard let url else { return }
            if records.isEmpty {
                guard io.exists(url) else { return }
                try io.remove(url)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try io.write(data, url)
        }
    }
}
