import Foundation

public final class SourceRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func save(_ source: MediaSource) throws {
        try database.execute(
            """
            INSERT INTO media_sources (
              id, name, path, media_type, recursive, auto_scan, minimum_file_size,
              ignore_hidden_files, read_nfo, prefer_local_artwork, network_scraping_enabled,
              screenshot_fallback_enabled, include_in_metadata_fetch, prefer_metadata_write_to_source,
              include_in_health_check, remote_trace_sync_mode, selected_emby_library_ids,
              created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              path = excluded.path,
              media_type = excluded.media_type,
              recursive = excluded.recursive,
              auto_scan = excluded.auto_scan,
              minimum_file_size = excluded.minimum_file_size,
              ignore_hidden_files = excluded.ignore_hidden_files,
              read_nfo = excluded.read_nfo,
              prefer_local_artwork = excluded.prefer_local_artwork,
              network_scraping_enabled = excluded.network_scraping_enabled,
              screenshot_fallback_enabled = excluded.screenshot_fallback_enabled,
              include_in_metadata_fetch = excluded.include_in_metadata_fetch,
              prefer_metadata_write_to_source = excluded.prefer_metadata_write_to_source,
              include_in_health_check = excluded.include_in_health_check,
              remote_trace_sync_mode = excluded.remote_trace_sync_mode,
              selected_emby_library_ids = excluded.selected_emby_library_ids,
              updated_at = excluded.updated_at
            """,
            bindings: bindings(for: source)
        )
    }

    public func delete(id: String) throws {
        try database.execute("DELETE FROM media_sources WHERE id = ?", bindings: [.text(id)])
    }

    public func fetchAll() throws -> [MediaSource] {
        try database.query(
            """
            SELECT id, name, path, media_type, recursive, auto_scan, minimum_file_size,
                   ignore_hidden_files, read_nfo, prefer_local_artwork, network_scraping_enabled,
                   screenshot_fallback_enabled, include_in_metadata_fetch, prefer_metadata_write_to_source,
                   include_in_health_check, remote_trace_sync_mode, selected_emby_library_ids,
                   created_at, updated_at
            FROM media_sources
            ORDER BY created_at ASC
            """
        ) { row in
            MediaSource(
                id: row.string(0) ?? UUID().uuidString,
                name: row.string(1) ?? "未命名媒体源",
                path: row.string(2) ?? "",
                mediaType: MediaType(rawValue: row.string(3) ?? "") ?? .auto,
                recursive: row.bool(4),
                autoScan: row.bool(5),
                minimumFileSize: row.int64(6) ?? 50 * 1024 * 1024,
                ignoreHiddenFiles: row.bool(7),
                readNFO: row.bool(8),
                preferLocalArtwork: row.bool(9),
                networkScrapingEnabled: row.bool(10),
                screenshotFallbackEnabled: row.bool(11),
                includeInMetadataFetch: row.bool(12),
                preferMetadataWriteToSource: row.bool(13),
                includeInHealthCheck: row.bool(14),
                remoteTraceSyncMode: RemoteTraceSyncMode(rawValue: row.string(15) ?? "") ?? .bidirectional,
                selectedEmbyLibraryIDs: Self.decodeEmbyLibraryIDs(row.string(16)),
                createdAt: row.date(17) ?? Date(),
                updatedAt: row.date(18) ?? Date()
            )
        }
    }

    private func bindings(for source: MediaSource) -> [SQLiteValue] {
        [
            .text(source.id),
            .text(source.name),
            .text(source.path),
            .text(source.mediaType.rawValue),
            .bool(source.recursive),
            .bool(source.autoScan),
            .int(source.minimumFileSize),
            .bool(source.ignoreHiddenFiles),
            .bool(source.readNFO),
            .bool(source.preferLocalArtwork),
            .bool(source.networkScrapingEnabled),
            .bool(source.screenshotFallbackEnabled),
            .bool(source.includeInMetadataFetch),
            .bool(source.preferMetadataWriteToSource),
            .bool(source.includeInHealthCheck),
            .text(source.remoteTraceSyncMode.rawValue),
            Self.encodeEmbyLibraryIDs(source.selectedEmbyLibraryIDs),
            .optionalDate(source.createdAt),
            .optionalDate(source.updatedAt)
        ]
    }

    private static func encodeEmbyLibraryIDs(_ ids: [String]) -> SQLiteValue {
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return .null }
        guard let data = try? JSONEncoder().encode(cleaned),
              let value = String(data: data, encoding: .utf8) else {
            return .text(cleaned.joined(separator: "\n"))
        }
        return .text(value)
    }

    private static func decodeEmbyLibraryIDs(_ value: String?) -> [String] {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return [] }
        if let data = value.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return value
            .split { $0 == "\n" || $0 == "," }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
