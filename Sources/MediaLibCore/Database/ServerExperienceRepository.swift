import Foundation

/// v30 服务端个性化、策略和运维设置仓储。
///
/// 所有文档写入都在同一事务内检查版本并递增，HTTP 层可直接把版本映射为 ETag。
/// 此处只接受已经通过模型验证的非敏感数据。
public final class ServerExperienceRepository: @unchecked Sendable {
    private let database: DatabaseManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(database: DatabaseManager) {
        self.database = database
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func userPreferences(userID: String) throws -> ServerVersionedDocument<ServerUserExperiencePreferences> {
        try document(
            table: "server_user_preferences",
            predicates: "user_id = ?",
            bindings: [.text(userID)],
            fallback: ServerUserExperiencePreferences()
        )
    }

    public func saveUserPreferences(
        userID: String,
        value: ServerUserExperiencePreferences,
        expectedVersion: Int
    ) throws -> ServerVersionedDocument<ServerUserExperiencePreferences> {
        guard value.isValid else { throw ServerExperienceRepositoryError.invalidValue }
        return try saveDocument(
            table: "server_user_preferences",
            keyColumns: ["user_id"],
            keyBindings: [.text(userID)],
            value: value,
            expectedVersion: expectedVersion
        )
    }

    public func devicePreferences(
        userID: String,
        deviceID: String
    ) throws -> ServerVersionedDocument<ServerDeviceExperienceOverrides>? {
        try optionalDocument(
            table: "server_device_preferences",
            predicates: "user_id = ? AND device_id = ?",
            bindings: [.text(userID), .text(deviceID)]
        )
    }

    public func saveDevicePreferences(
        userID: String,
        deviceID: String,
        value: ServerDeviceExperienceOverrides,
        expectedVersion: Int
    ) throws -> ServerVersionedDocument<ServerDeviceExperienceOverrides> {
        guard value.isValid else { throw ServerExperienceRepositoryError.invalidValue }
        return try saveDocument(
            table: "server_device_preferences",
            keyColumns: ["user_id", "device_id"],
            keyBindings: [.text(userID), .text(deviceID)],
            value: value,
            expectedVersion: expectedVersion
        )
    }

    public func deleteDevicePreferences(userID: String, deviceID: String, expectedVersion: Int) throws {
        try database.transaction {
            let current = try currentVersion(
                table: "server_device_preferences",
                predicates: "user_id = ? AND device_id = ?",
                bindings: [.text(userID), .text(deviceID)]
            )
            guard let current else { throw ServerExperienceRepositoryError.notFound }
            guard current == expectedVersion else {
                throw ServerExperienceRepositoryError.versionConflict(currentVersion: current)
            }
            try database.execute(
                "DELETE FROM server_device_preferences WHERE user_id = ? AND device_id = ?",
                bindings: [.text(userID), .text(deviceID)]
            )
        }
    }

    public func trackOverride(
        userID: String,
        scope: ServerTrackOverrideScope,
        scopeID: String
    ) throws -> ServerTrackSelectionOverride? {
        try database.query(
            """
            SELECT audio_fingerprint, subtitle_fingerprint, subtitle_disabled, updated_at
            FROM server_user_track_overrides
            WHERE user_id = ? AND scope_kind = ? AND scope_id = ?
            LIMIT 1
            """,
            bindings: [.text(userID), .text(scope.rawValue), .text(scopeID)]
        ) { row in
            ServerTrackSelectionOverride(
                scope: scope,
                scopeID: scopeID,
                audioFingerprint: row.string(0),
                subtitleFingerprint: row.string(1),
                subtitleDisabled: row.bool(2),
                updatedAt: row.date(3) ?? Date()
            )
        }.first
    }

    @discardableResult
    public func saveTrackOverride(
        userID: String,
        value: ServerTrackSelectionOverride
    ) throws -> ServerTrackSelectionOverride {
        guard value.isValid else { throw ServerExperienceRepositoryError.invalidValue }
        var updated = value
        updated.updatedAt = Date()
        try database.execute(
            """
            INSERT INTO server_user_track_overrides (
              user_id, scope_kind, scope_id, audio_fingerprint, subtitle_fingerprint,
              subtitle_disabled, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, scope_kind, scope_id) DO UPDATE SET
              audio_fingerprint = excluded.audio_fingerprint,
              subtitle_fingerprint = excluded.subtitle_fingerprint,
              subtitle_disabled = excluded.subtitle_disabled,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(userID), .text(updated.scope.rawValue), .text(updated.scopeID),
                .optionalText(updated.audioFingerprint), .optionalText(updated.subtitleFingerprint),
                .bool(updated.subtitleDisabled), .optionalDate(updated.updatedAt)
            ]
        )
        return updated
    }

    public func deleteTrackOverride(userID: String, scope: ServerTrackOverrideScope, scopeID: String) throws {
        try database.execute(
            "DELETE FROM server_user_track_overrides WHERE user_id = ? AND scope_kind = ? AND scope_id = ?",
            bindings: [.text(userID), .text(scope.rawValue), .text(scopeID)]
        )
    }

    public func userPolicy(userID: String) throws -> ServerVersionedDocument<ServerUserPolicy> {
        try document(
            table: "server_user_policies",
            predicates: "user_id = ?",
            bindings: [.text(userID)],
            fallback: ServerUserPolicy()
        )
    }

    public func saveUserPolicy(
        userID: String,
        value: ServerUserPolicy,
        expectedVersion: Int
    ) throws -> ServerVersionedDocument<ServerUserPolicy> {
        guard value.isValid else { throw ServerExperienceRepositoryError.invalidValue }
        return try saveDocument(
            table: "server_user_policies",
            keyColumns: ["user_id"],
            keyBindings: [.text(userID)],
            value: value,
            expectedVersion: expectedVersion
        )
    }

    public func operationalSettings() throws -> ServerVersionedDocument<ServerOperationalSettings> {
        try document(
            table: "server_operational_settings",
            predicates: "id = 1",
            bindings: [],
            fallback: ServerOperationalSettings()
        )
    }

    public func saveOperationalSettings(
        _ value: ServerOperationalSettings,
        expectedVersion: Int
    ) throws -> ServerVersionedDocument<ServerOperationalSettings> {
        guard value.isValid else { throw ServerExperienceRepositoryError.invalidValue }
        return try saveDocument(
            table: "server_operational_settings",
            keyColumns: ["id"],
            keyBindings: [.int(1)],
            value: value,
            expectedVersion: expectedVersion
        )
    }

    public func jobs(limit: Int = 50, offset: Int = 0, state: ServerJobState? = nil) throws -> [ServerJob] {
        let boundedLimit = min(max(limit, 1), 200)
        let boundedOffset = max(offset, 0)
        let predicate = state == nil ? "" : "WHERE state = ?"
        var bindings = state.map { [SQLiteValue.text($0.rawValue)] } ?? []
        bindings.append(.int(Int64(boundedLimit)))
        bindings.append(.int(Int64(boundedOffset)))
        return try database.query(
            """
            SELECT id, kind, state, progress, result_code, created_at, started_at, finished_at, requested_by_user_id
            FROM server_jobs
            \(predicate)
            ORDER BY created_at DESC, id ASC
            LIMIT ? OFFSET ?
            """,
            bindings: bindings
        ) { row in
            ServerJob(
                id: row.string(0) ?? UUID().uuidString,
                kind: row.string(1) ?? "unknown",
                state: ServerJobState(rawValue: row.string(2) ?? "") ?? .failed,
                progress: row.double(3) ?? 0,
                resultCode: row.string(4),
                createdAt: row.date(5) ?? Date(),
                startedAt: row.date(6),
                finishedAt: row.date(7),
                requestedByUserID: row.string(8)
            )
        }
    }

    @discardableResult
    public func saveJob(_ job: ServerJob) throws -> ServerJob {
        guard job.isValid else { throw ServerExperienceRepositoryError.invalidValue }
        try database.execute(
            """
            INSERT INTO server_jobs (
              id, kind, state, progress, result_code, created_at, started_at, finished_at, requested_by_user_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              state = excluded.state,
              progress = excluded.progress,
              result_code = excluded.result_code,
              started_at = excluded.started_at,
              finished_at = excluded.finished_at
            """,
            bindings: [
                .text(job.id), .text(job.kind), .text(job.state.rawValue), .double(job.progress),
                .optionalText(job.resultCode), .optionalDate(job.createdAt), .optionalDate(job.startedAt),
                .optionalDate(job.finishedAt), .optionalText(job.requestedByUserID)
            ]
        )
        return job
    }

    private func document<Value: Codable & Equatable & Sendable>(
        table: String,
        predicates: String,
        bindings: [SQLiteValue],
        fallback: Value
    ) throws -> ServerVersionedDocument<Value> {
        try optionalDocument(table: table, predicates: predicates, bindings: bindings)
            ?? ServerVersionedDocument(value: fallback, version: 0, updatedAt: nil)
    }

    private func optionalDocument<Value: Codable & Equatable & Sendable>(
        table: String,
        predicates: String,
        bindings: [SQLiteValue]
    ) throws -> ServerVersionedDocument<Value>? {
        try database.query(
            "SELECT document_version, payload_json, updated_at FROM \(table) WHERE \(predicates) LIMIT 1",
            bindings: bindings
        ) { row in
            guard let json = row.string(1)?.data(using: .utf8) else {
                throw ServerExperienceRepositoryError.invalidValue
            }
            let value = try decoder.decode(Value.self, from: json)
            return ServerVersionedDocument(value: value, version: row.int(0) ?? 0, updatedAt: row.date(2))
        }.first
    }

    private func saveDocument<Value: Codable & Equatable & Sendable>(
        table: String,
        keyColumns: [String],
        keyBindings: [SQLiteValue],
        value: Value,
        expectedVersion: Int
    ) throws -> ServerVersionedDocument<Value> {
        try database.transaction {
            let predicates = keyColumns.map { "\($0) = ?" }.joined(separator: " AND ")
            let current = try currentVersion(table: table, predicates: predicates, bindings: keyBindings) ?? 0
            guard current == expectedVersion else {
                throw ServerExperienceRepositoryError.versionConflict(currentVersion: current)
            }
            let nextVersion = current + 1
            let updatedAt = Date()
            let json = String(decoding: try encoder.encode(value), as: UTF8.self)
            let columns = keyColumns + ["document_version", "payload_json", "updated_at"]
            let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
            let updates = ["document_version", "payload_json", "updated_at"]
                .map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
            try database.execute(
                "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders)) "
                    + "ON CONFLICT(\(keyColumns.joined(separator: ", "))) DO UPDATE SET \(updates)",
                bindings: keyBindings + [.int(Int64(nextVersion)), .text(json), .optionalDate(updatedAt)]
            )
            return ServerVersionedDocument(value: value, version: nextVersion, updatedAt: updatedAt)
        }
    }

    private func currentVersion(
        table: String,
        predicates: String,
        bindings: [SQLiteValue]
    ) throws -> Int? {
        try database.query(
            "SELECT document_version FROM \(table) WHERE \(predicates) LIMIT 1",
            bindings: bindings
        ) { $0.int(0) }.first ?? nil
    }
}
