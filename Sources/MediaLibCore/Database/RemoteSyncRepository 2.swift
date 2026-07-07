import Foundation

public final class RemoteConnectorAccountRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    @discardableResult
    public func save(_ account: RemoteConnectorAccount) throws -> RemoteConnectorAccount {
        var updated = account
        updated.updatedAt = Date()
        try database.execute(
            """
            INSERT INTO remote_connector_accounts (
              id, provider, account_label, server_url, username, source_id, connection_mode,
              sync_enabled, capabilities_json, privacy_note, created_at, updated_at, last_synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              provider = excluded.provider,
              account_label = excluded.account_label,
              server_url = excluded.server_url,
              username = excluded.username,
              source_id = excluded.source_id,
              connection_mode = excluded.connection_mode,
              sync_enabled = excluded.sync_enabled,
              capabilities_json = excluded.capabilities_json,
              privacy_note = excluded.privacy_note,
              updated_at = excluded.updated_at,
              last_synced_at = excluded.last_synced_at
            """,
            bindings: [
                .text(updated.id),
                .text(updated.provider.rawValue),
                .text(updated.accountLabel),
                .optionalText(updated.serverURL),
                .optionalText(updated.username),
                .optionalText(updated.sourceID),
                .text(updated.connectionMode.rawValue),
                .bool(updated.syncEnabled),
                .optionalText(updated.capabilitiesJSON),
                .optionalText(updated.privacyNote),
                .optionalDate(updated.createdAt),
                .optionalDate(updated.updatedAt),
                .optionalDate(updated.lastSyncedAt)
            ]
        )
        return updated
    }

    public func fetchAll() throws -> [RemoteConnectorAccount] {
        try database.query(
            """
            SELECT id, provider, account_label, server_url, username, source_id, connection_mode,
                   sync_enabled, capabilities_json, privacy_note, created_at, updated_at, last_synced_at
            FROM remote_connector_accounts
            ORDER BY provider ASC, updated_at DESC
            """,
            map: map(row:)
        )
    }

    public func delete(id: String) throws {
        try database.execute("DELETE FROM remote_connector_accounts WHERE id = ?", bindings: [.text(id)])
    }

    public func delete(sourceID: String) throws {
        try database.execute(
            "DELETE FROM remote_connector_accounts WHERE source_id = ?",
            bindings: [.text(sourceID)]
        )
    }

    private func map(row: SQLiteRow) -> RemoteConnectorAccount {
        let provider = RemoteConnectorProvider(rawValue: row.string(1) ?? "") ?? .emby
        return RemoteConnectorAccount(
            id: row.string(0) ?? UUID().uuidString,
            provider: provider,
            accountLabel: row.string(2) ?? provider.displayName,
            serverURL: row.string(3),
            username: row.string(4),
            sourceID: row.string(5),
            connectionMode: RemoteConnectorMode(rawValue: row.string(6) ?? "") ?? .library,
            syncEnabled: row.bool(7),
            capabilitiesJSON: row.string(8),
            privacyNote: row.string(9),
            createdAt: row.date(10) ?? Date(),
            updatedAt: row.date(11) ?? Date(),
            lastSyncedAt: row.date(12)
        )
    }
}

public final class SyncConflictRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    @discardableResult
    public func save(_ conflict: SyncConflict) throws -> SyncConflict {
        var updated = conflict
        updated.updatedAt = Date()
        try database.execute(
            """
            INSERT INTO sync_conflicts (
              id, media_id, profile_id, provider, account_id, field_name, local_value, remote_value,
              local_updated_at, remote_updated_at, status, resolution, error_message,
              created_at, updated_at, resolved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              media_id = excluded.media_id,
              profile_id = excluded.profile_id,
              provider = excluded.provider,
              account_id = excluded.account_id,
              field_name = excluded.field_name,
              local_value = excluded.local_value,
              remote_value = excluded.remote_value,
              local_updated_at = excluded.local_updated_at,
              remote_updated_at = excluded.remote_updated_at,
              status = excluded.status,
              resolution = excluded.resolution,
              error_message = excluded.error_message,
              updated_at = excluded.updated_at,
              resolved_at = excluded.resolved_at
            """,
            bindings: [
                .optionalText(updated.id),
                .optionalText(updated.mediaID),
                .optionalText(updated.profileID),
                .text(updated.provider.rawValue),
                .optionalText(updated.accountID),
                .text(updated.fieldName),
                .optionalText(updated.localValue),
                .optionalText(updated.remoteValue),
                .optionalDate(updated.localUpdatedAt),
                .optionalDate(updated.remoteUpdatedAt),
                .text(updated.status.rawValue),
                .optionalText(updated.resolution?.rawValue),
                .optionalText(updated.errorMessage),
                .optionalDate(updated.createdAt),
                .optionalDate(updated.updatedAt),
                .optionalDate(updated.resolvedAt)
            ]
        )
        return updated
    }

    public func fetchPending(limit: Int = 200) throws -> [SyncConflict] {
        try database.query(
            """
            SELECT id, media_id, profile_id, provider, account_id, field_name, local_value, remote_value,
                   local_updated_at, remote_updated_at, status, resolution, error_message,
                   created_at, updated_at, resolved_at
            FROM sync_conflicts
            WHERE status = ?
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            bindings: [.text(SyncConflictStatus.pending.rawValue), .int(Int64(max(limit, 1)))],
            map: map(row:)
        )
    }

    public func pendingCount() throws -> Int {
        try database.query(
            "SELECT COUNT(*) FROM sync_conflicts WHERE status = ?",
            bindings: [.text(SyncConflictStatus.pending.rawValue)]
        ) { row in
            row.int(0) ?? 0
        }.first ?? 0
    }

    public func resolve(id: String, resolution: SyncConflictResolution) throws {
        try database.execute(
            """
            UPDATE sync_conflicts
            SET status = ?, resolution = ?, resolved_at = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(SyncConflictStatus.resolved.rawValue),
                .text(resolution.rawValue),
                .optionalDate(Date()),
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    public func ignore(id: String) throws {
        try database.execute(
            """
            UPDATE sync_conflicts
            SET status = ?, resolution = NULL, resolved_at = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(SyncConflictStatus.ignored.rawValue),
                .optionalDate(Date()),
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    private func map(row: SQLiteRow) -> SyncConflict {
        SyncConflict(
            id: row.string(0) ?? UUID().uuidString,
            mediaID: row.string(1),
            profileID: row.string(2),
            provider: RemoteConnectorProvider(rawValue: row.string(3) ?? "") ?? .emby,
            accountID: row.string(4),
            fieldName: row.string(5) ?? "",
            localValue: row.string(6),
            remoteValue: row.string(7),
            localUpdatedAt: row.date(8),
            remoteUpdatedAt: row.date(9),
            status: SyncConflictStatus(rawValue: row.string(10) ?? "") ?? .pending,
            resolution: SyncConflictResolution(rawValue: row.string(11) ?? ""),
            errorMessage: row.string(12),
            createdAt: row.date(13) ?? Date(),
            updatedAt: row.date(14) ?? Date(),
            resolvedAt: row.date(15)
        )
    }
}

public final class LocalUserProfileRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    @discardableResult
    public func save(_ profile: LocalUserProfile) throws -> LocalUserProfile {
        var updated = profile
        updated.updatedAt = Date()
        try database.transaction {
            if updated.isDefault {
                try database.execute("UPDATE local_user_profiles SET is_default = 0 WHERE id != ?", bindings: [.text(updated.id)])
            }
            try database.execute(
                """
                INSERT INTO local_user_profiles (
                  id, name, is_default, avatar_symbol, restricts_private_items, child_mode, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  is_default = excluded.is_default,
                  avatar_symbol = excluded.avatar_symbol,
                  restricts_private_items = excluded.restricts_private_items,
                  child_mode = excluded.child_mode,
                  updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(updated.id),
                    .text(updated.name),
                    .bool(updated.isDefault),
                    .optionalText(updated.avatarSymbol),
                    .bool(updated.restrictsPrivateItems),
                    .bool(updated.childMode),
                    .optionalDate(updated.createdAt),
                    .optionalDate(updated.updatedAt)
                ]
            )
        }
        return updated
    }

    public func fetchAll() throws -> [LocalUserProfile] {
        try database.query(
            """
            SELECT id, name, is_default, avatar_symbol, restricts_private_items, child_mode, created_at, updated_at
            FROM local_user_profiles
            ORDER BY is_default DESC, updated_at DESC
            """,
            map: mapProfile(row:)
        )
    }

    public func delete(id: String) throws {
        guard id != "default" else { return }
        try database.execute("DELETE FROM local_user_profiles WHERE id = ? AND is_default = 0", bindings: [.text(id)])
    }

    @discardableResult
    public func saveState(_ state: ProfileMediaState) throws -> ProfileMediaState {
        var updated = state
        updated.updatedAt = Date()
        try database.execute(
            """
            INSERT INTO profile_media_state (
              profile_id, media_id, play_count, play_position, play_progress, watched,
              favorite, watchlist, user_rating, last_played_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(profile_id, media_id) DO UPDATE SET
              play_count = excluded.play_count,
              play_position = excluded.play_position,
              play_progress = excluded.play_progress,
              watched = excluded.watched,
              favorite = excluded.favorite,
              watchlist = excluded.watchlist,
              user_rating = excluded.user_rating,
              last_played_at = excluded.last_played_at,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(updated.profileID),
                .text(updated.mediaID),
                .int(Int64(updated.playCount)),
                .double(updated.playPosition),
                .double(updated.playProgress),
                .bool(updated.watched),
                .bool(updated.favorite),
                .bool(updated.watchlist),
                .optionalDouble(updated.userRating),
                .optionalDate(updated.lastPlayedAt),
                .optionalDate(updated.updatedAt)
            ]
        )
        return updated
    }

    public func state(profileID: String, mediaID: String) throws -> ProfileMediaState? {
        try database.query(
            """
            SELECT profile_id, media_id, play_count, play_position, play_progress, watched,
                   favorite, watchlist, user_rating, last_played_at, updated_at
            FROM profile_media_state
            WHERE profile_id = ? AND media_id = ?
            """,
            bindings: [.text(profileID), .text(mediaID)],
            map: mapState(row:)
        ).first
    }

    public func states(profileID: String) throws -> [ProfileMediaState] {
        try database.query(
            """
            SELECT profile_id, media_id, play_count, play_position, play_progress, watched,
                   favorite, watchlist, user_rating, last_played_at, updated_at
            FROM profile_media_state
            WHERE profile_id = ?
            """,
            bindings: [.text(profileID)],
            map: mapState(row:)
        )
    }

    private func mapProfile(row: SQLiteRow) -> LocalUserProfile {
        LocalUserProfile(
            id: row.string(0) ?? UUID().uuidString,
            name: row.string(1) ?? "未命名档案",
            isDefault: row.bool(2),
            avatarSymbol: row.string(3),
            restrictsPrivateItems: row.bool(4),
            childMode: row.bool(5),
            createdAt: row.date(6) ?? Date(),
            updatedAt: row.date(7) ?? Date()
        )
    }

    private func mapState(row: SQLiteRow) -> ProfileMediaState {
        ProfileMediaState(
            profileID: row.string(0) ?? "",
            mediaID: row.string(1) ?? "",
            playCount: row.int(2) ?? 0,
            playPosition: row.double(3) ?? 0,
            playProgress: row.double(4) ?? 0,
            watched: row.bool(5),
            favorite: row.bool(6),
            watchlist: row.bool(7),
            userRating: row.double(8),
            lastPlayedAt: row.date(9),
            updatedAt: row.date(10) ?? Date()
        )
    }
}
