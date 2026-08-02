import Foundation

public enum ServerQueueRepeatMode: String, Codable, CaseIterable, Sendable {
    case sequential
    case repeatOne
    case repeatAll
}

public enum ServerQueueMutationAction: String, Codable, CaseIterable, Sendable {
    case add
    case remove
    case clear
    case move
    case settings
}

public struct ServerUserQueueSnapshot: Equatable, Sendable {
    public let itemIDs: [String]
    public let repeatMode: ServerQueueRepeatMode
    public let shuffleEnabled: Bool
    public let currentPosition: Int
    public let updatedAt: Date

    public init(itemIDs: [String] = [], repeatMode: ServerQueueRepeatMode = .sequential, shuffleEnabled: Bool = false, currentPosition: Int = 0, updatedAt: Date = Date()) {
        self.itemIDs = itemIDs
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
        self.currentPosition = max(currentPosition, 0)
        self.updatedAt = updatedAt
    }
}

public enum ServerUserQueueRepositoryError: Error, Equatable, Sendable {
    case invalidIdentifier
    case tooManyItems
    case mediaNotFound
    case invalidPosition
}

/// 网页播放队列的持久化边界。所有写操作先在事务内重排 position，用户 ID 永远由
/// 认证服务传入，不能从浏览器正文切换到其它用户队列。
public final class ServerUserQueueRepository: @unchecked Sendable {
    public static let maximumItemCount = 100
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    public func fetch(userID: String) throws -> ServerUserQueueSnapshot {
        let userID = try validated(userID)
        let state = try database.query(
            "SELECT repeat_mode, shuffle_enabled, current_position, updated_at FROM server_user_queue_state WHERE user_id = ?",
            bindings: [.text(userID)]
        ) { row in
            (ServerQueueRepeatMode(rawValue: row.string(0) ?? "") ?? .sequential, row.bool(1), row.int(2) ?? 0, row.date(3) ?? Date())
        }.first ?? (.sequential, false, 0, Date())
        let itemIDs = try database.query(
            "SELECT media_id FROM server_user_queue_items WHERE user_id = ? ORDER BY position ASC, media_id ASC",
            bindings: [.text(userID)]
        ) { $0.string(0) ?? "" }.filter { !$0.isEmpty }
        return ServerUserQueueSnapshot(itemIDs: itemIDs, repeatMode: state.0, shuffleEnabled: state.1, currentPosition: min(state.2, max(itemIDs.count - 1, 0)), updatedAt: state.3)
    }

    public func replace(userID: String, itemIDs: [String], repeatMode: ServerQueueRepeatMode, shuffleEnabled: Bool, currentPosition: Int) throws -> ServerUserQueueSnapshot {
        let userID = try validated(userID)
        let ids = try normalized(itemIDs)
        guard currentPosition >= 0, currentPosition <= max(ids.count - 1, 0) else { throw ServerUserQueueRepositoryError.invalidPosition }
        let now = Date()
        try database.transaction {
            for id in ids {
                guard try database.query("SELECT 1 FROM media_items WHERE id = ? LIMIT 1", bindings: [.text(id)], map: { _ in true }).first == true else { throw ServerUserQueueRepositoryError.mediaNotFound }
            }
            try saveState(userID: userID, repeatMode: repeatMode, shuffleEnabled: shuffleEnabled, currentPosition: currentPosition, at: now)
            try database.execute("DELETE FROM server_user_queue_items WHERE user_id = ?", bindings: [.text(userID)])
            for (position, id) in ids.enumerated() {
                try database.execute("INSERT INTO server_user_queue_items (user_id, media_id, position, added_at) VALUES (?, ?, ?, ?)", bindings: [.text(userID), .text(id), .int(Int64(position)), .optionalDate(now)])
            }
        }
        return try fetch(userID: userID)
    }

    public func mutate(userID: String, action: ServerQueueMutationAction, mediaID: String?, fromIndex: Int?, toIndex: Int?, repeatMode: ServerQueueRepeatMode?, shuffleEnabled: Bool?, currentPosition: Int?) throws -> ServerUserQueueSnapshot {
        let userID = try validated(userID)
        var snapshot = try fetch(userID: userID)
        var ids = snapshot.itemIDs
        switch action {
        case .add:
            guard let mediaID, !mediaID.isEmpty else { throw ServerUserQueueRepositoryError.invalidIdentifier }
            if !ids.contains(mediaID) { ids.append(mediaID) }
        case .remove:
            guard let mediaID else { throw ServerUserQueueRepositoryError.invalidIdentifier }
            ids.removeAll { $0 == mediaID }
        case .clear:
            ids.removeAll()
        case .move:
            guard let fromIndex, let toIndex, ids.indices.contains(fromIndex), toIndex >= 0, toIndex < ids.count else { throw ServerUserQueueRepositoryError.invalidPosition }
            let id = ids.remove(at: fromIndex); ids.insert(id, at: toIndex)
        case .settings:
            break
        }
        let nextPosition = min(max(currentPosition ?? snapshot.currentPosition, 0), max(ids.count - 1, 0))
        snapshot = try replace(userID: userID, itemIDs: ids, repeatMode: repeatMode ?? snapshot.repeatMode, shuffleEnabled: shuffleEnabled ?? snapshot.shuffleEnabled, currentPosition: nextPosition)
        return snapshot
    }

    private func saveState(userID: String, repeatMode: ServerQueueRepeatMode, shuffleEnabled: Bool, currentPosition: Int, at date: Date) throws {
        try database.execute("""
        INSERT INTO server_user_queue_state (user_id, repeat_mode, shuffle_enabled, current_position, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(user_id) DO UPDATE SET repeat_mode = excluded.repeat_mode, shuffle_enabled = excluded.shuffle_enabled, current_position = excluded.current_position, updated_at = excluded.updated_at
        """, bindings: [.text(userID), .text(repeatMode.rawValue), .bool(shuffleEnabled), .int(Int64(currentPosition)), .optionalDate(date)])
    }

    private func validated(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512, !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw ServerUserQueueRepositoryError.invalidIdentifier }
        return value
    }

    private func normalized(_ values: [String]) throws -> [String] {
        guard values.count <= Self.maximumItemCount else { throw ServerUserQueueRepositoryError.tooManyItems }
        var seen = Set<String>(); var result: [String] = []
        for value in values { let id = try validated(value); if seen.insert(id).inserted { result.append(id) } }
        return result
    }
}
