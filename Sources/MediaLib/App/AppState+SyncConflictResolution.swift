import Foundation
import MediaLibCore

// 同步冲突处理逻辑从 AppState.swift 拆到本文件，直接缩小那个超大文件（R1-ARCH-001 头号债务）。
// 与 SyncConflictStore（持久化/列表）配套：本文件是处理逻辑（采用远端→库内变更并在同一
// database.transaction 内落库解决，保原子性；采用本地→Trakt 写回）。纯文件搬运，逐字不变。
// 两个 sync-conflict 专用私有类型随之搬来。放宽到 internal 的主体成员：database /
// shouldClearWatchlistWhenMarkedWatched / updateFavoriteInMemory / updateWatchedInMemory。
private struct SyncConflictRemoteMutation {
    enum Value {
        case boolean(Bool)
        case userRating(Double?)
    }

    var item: MediaItem
    var fieldName: String
    var value: Value
}

private enum SyncConflictApplyError: LocalizedError {
    case missingMediaID
    case missingRemoteValue
    case missingLocalValue
    case invalidBooleanValue(String)
    case invalidRatingValue(String)
    case unsupportedField(String)
    case unsupportedProvider(RemoteConnectorProvider)
    case privateItemLocked
    case privateItemNotSyncable
    case mediaItemNotFound(String)
    case repositoryUnavailable

    var errorDescription: String? {
        switch self {
        case .missingMediaID:
            return "同步冲突缺少媒体条目 ID。"
        case .missingRemoteValue:
            return "同步冲突缺少远端值。"
        case .missingLocalValue:
            return "同步冲突缺少本地值。"
        case .invalidBooleanValue(let value):
            return "无法识别远端布尔值：\(value)"
        case .invalidRatingValue(let value):
            return "无法识别远端用户评级：\(value)"
        case .unsupportedField(let field):
            return "暂不支持自动采用该字段：\(field)"
        case .unsupportedProvider(let provider):
            return "暂不支持向 \(provider.displayName) 写回该冲突。"
        case .privateItemLocked:
            return "保险库锁定时不能处理该条同步冲突。"
        case .privateItemNotSyncable:
            return "保险库内容不会同步到远端服务。"
        case .mediaItemNotFound(let id):
            return "媒体条目不存在：\(id)"
        case .repositoryUnavailable:
            return "媒体索引仓库不可用。"
        }
    }
}

extension AppState {
    func resolveSyncConflict(_ conflict: SyncConflict, resolution: SyncConflictResolution) {
        guard syncConflictStore.isAvailable else { return }
        if conflict.provider == .trakt, resolution == .useLocal {
            resolveTraktSyncConflictUsingLocal(conflict)
            return
        }
        do {
            if resolution == .useRemote,
               let database,
               let mediaRepository {
                let mutation = try remoteMutation(for: conflict)
                try database.transaction {
                    switch mutation.value {
                    case .boolean(let value):
                        switch mutation.fieldName {
                        case "watched":
                            try mediaRepository.markWatched(
                                id: mutation.item.id,
                                watched: value,
                                clearWatchlistWhenWatched: shouldClearWatchlistWhenMarkedWatched(mutation.item, watched: value)
                            )
                        case "watchlist":
                            try mediaRepository.setWatchlist(id: mutation.item.id, watchlist: value)
                        case "favorite":
                            try mediaRepository.setFavorite(id: mutation.item.id, favorite: value)
                        default:
                            throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
                        }
                    case .userRating(let rating):
                        try mediaRepository.updateRating(id: mutation.item.id, rating: rating)
                    }
                    try syncConflictStore.persistResolution(id: conflict.id, resolution: resolution)
                }
                applyRemoteMutationInMemory(mutation)
            } else {
                try syncConflictStore.persistResolution(id: conflict.id, resolution: resolution)
            }
            syncConflictStore.forgetPending(id: conflict.id)
            showFloatingNotice(
                title: resolution == .useRemote ? "已采用远端状态" : "已记录冲突处理",
                message: syncConflictResolutionNotice(conflict, resolution: resolution),
                kind: .success
            )
        } catch {
            showError("处理同步冲突失败", error)
        }
    }

    private func resolveTraktSyncConflictUsingLocal(_ conflict: SyncConflict) {
        guard syncConflictStore.isAvailable else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let mutation = try self.localMutation(for: conflict)
                try await self.pushLocalMutationToTrakt(mutation)
                try self.syncConflictStore.persistResolution(id: conflict.id, resolution: .useLocal)
                let now = Date()
                _ = self.traktAccountRecord(syncEnabled: self.settings.traktSyncEnabled, lastSyncedAt: now)
                self.remoteConnectorAccounts = try self.remoteConnectorAccountRepository?.fetchAll() ?? self.remoteConnectorAccounts
                self.syncConflictStore.forgetPending(id: conflict.id)
                let message = self.syncConflictResolutionNotice(conflict, resolution: .useLocal)
                self.deliverTaskNotice(
                    title: "已保留本地并同步 Trakt",
                    message: message,
                    kind: .success,
                    systemTitle: "已保留本地并同步 Trakt",
                    systemBody: message
                )
            } catch {
                self.deliverTaskNotice(
                    title: "Trakt 写回失败",
                    message: error.localizedDescription,
                    kind: .error,
                    systemTitle: "Trakt 写回失败",
                    systemBody: error.localizedDescription
                )
            }
        }
    }

    private func remoteMutation(for conflict: SyncConflict) throws -> SyncConflictRemoteMutation {
        guard let mediaID = conflict.mediaID, !mediaID.isEmpty else {
            throw SyncConflictApplyError.missingMediaID
        }
        if cachedPrivateItemIDs.contains(mediaID), !canDisplayPrivateItems {
            throw SyncConflictApplyError.privateItemLocked
        }
        guard let mediaRepository else {
            throw SyncConflictApplyError.repositoryUnavailable
        }
        guard let existing = try mediaRepository.fetch(id: mediaID) else {
            throw SyncConflictApplyError.mediaItemNotFound(mediaID)
        }
        let fieldName = normalizedSyncConflictField(conflict.fieldName)

        switch fieldName {
        case "watchlist":
            guard existing.type != .music else {
                throw SyncConflictApplyError.unsupportedField(conflict.fieldName)
            }
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .boolean(try booleanSyncValue(conflict.remoteValue)))
        case "watched", "favorite":
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .boolean(try booleanSyncValue(conflict.remoteValue)))
        case "user_rating":
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .userRating(try userRatingSyncValue(conflict.remoteValue)))
        default:
            throw SyncConflictApplyError.unsupportedField(conflict.fieldName)
        }
    }

    private func localMutation(for conflict: SyncConflict) throws -> SyncConflictRemoteMutation {
        guard conflict.provider == .trakt else {
            throw SyncConflictApplyError.unsupportedProvider(conflict.provider)
        }
        guard let mediaID = conflict.mediaID, !mediaID.isEmpty else {
            throw SyncConflictApplyError.missingMediaID
        }
        if cachedPrivateItemIDs.contains(mediaID) {
            throw SyncConflictApplyError.privateItemNotSyncable
        }
        guard let mediaRepository else {
            throw SyncConflictApplyError.repositoryUnavailable
        }
        guard let existing = try mediaRepository.fetch(id: mediaID) else {
            throw SyncConflictApplyError.mediaItemNotFound(mediaID)
        }
        guard existing.type != .privateCollection else {
            throw SyncConflictApplyError.privateItemNotSyncable
        }
        let fieldName = normalizedSyncConflictField(conflict.fieldName)
        switch fieldName {
        case "watched", "watchlist":
            let localValue = try booleanSyncValue(conflict.localValue, missing: .missingLocalValue)
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .boolean(localValue))
        default:
            throw SyncConflictApplyError.unsupportedField(conflict.fieldName)
        }
    }

    private func pushLocalMutationToTrakt(_ mutation: SyncConflictRemoteMutation) async throws {
        guard settings.traktSyncEnabled, isTraktConnected else { throw TraktError.notConnected }
        switch mutation.fieldName {
        case "watched":
            guard case .boolean(let value) = mutation.value else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            guard let ref = traktHistoryRef(for: mutation.item) else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            try await withValidTraktToken { service, token in
                if value {
                    try await service.addToHistory([ref], accessToken: token)
                } else {
                    try await service.removeFromHistory([ref], accessToken: token)
                }
            }
        case "watchlist":
            guard case .boolean(let value) = mutation.value else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            guard let ref = traktWatchlistRef(for: mutation.item) else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            try await withValidTraktToken { service, token in
                if value {
                    try await service.addToWatchlist([ref], accessToken: token)
                } else {
                    try await service.removeFromWatchlist([ref], accessToken: token)
                }
            }
        default:
            throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
        }
    }

    private func applyRemoteMutationInMemory(_ mutation: SyncConflictRemoteMutation) {
        switch mutation.value {
        case .boolean(let value):
            switch mutation.fieldName {
            case "watched":
                updateWatchedInMemory(ids: [mutation.item.id], watched: value)
                if shouldClearWatchlistWhenMarkedWatched(mutation.item, watched: value) {
                    updateWatchlistInMemory(id: mutation.item.id, watchlist: false)
                }
            case "watchlist":
                updateWatchlistInMemory(id: mutation.item.id, watchlist: value)
            case "favorite":
                updateFavoriteInMemory(id: mutation.item.id, favorite: value)
            default:
                break
            }
        case .userRating(let rating):
            updateRatingInMemory(id: mutation.item.id, rating: rating)
        }
    }

    private func normalizedSyncConflictField(_ fieldName: String) -> String {
        SyncConflictValueParser.isUserRatingField(fieldName)
            ? "user_rating"
            : SyncConflictValueParser.normalizedFieldName(fieldName)
    }

    private func booleanSyncValue(_ rawValue: String?) throws -> Bool {
        try booleanSyncValue(rawValue, missing: .missingRemoteValue)
    }

    private func booleanSyncValue(_ rawValue: String?, missing: SyncConflictApplyError) throws -> Bool {
        do {
            return try SyncConflictValueParser.boolean(rawValue)
        } catch SyncConflictValueParseError.missingValue {
            throw missing
        } catch SyncConflictValueParseError.invalidBoolean(let value) {
            throw SyncConflictApplyError.invalidBooleanValue(value)
        } catch {
            throw error
        }
    }

    private func userRatingSyncValue(_ rawValue: String?) throws -> Double? {
        do {
            return try SyncConflictValueParser.userRating(rawValue)
        } catch SyncConflictValueParseError.missingValue {
            throw SyncConflictApplyError.missingRemoteValue
        } catch SyncConflictValueParseError.invalidUserRating(let value) {
            throw SyncConflictApplyError.invalidRatingValue(value)
        } catch {
            throw error
        }
    }

    func ignoreSyncConflict(_ conflict: SyncConflict) {
        guard syncConflictStore.isAvailable else { return }
        do {
            try syncConflictStore.persistIgnore(id: conflict.id)
            syncConflictStore.forgetPending(id: conflict.id)
            showFloatingNotice(title: "已忽略同步冲突", message: syncConflictDisplayTitle(conflict), kind: .info)
        } catch {
            showError("忽略同步冲突失败", error)
        }
    }

    private func displayedItem(id: String, fallback: MediaItem? = nil) -> MediaItem? {
        // 展开成早返回，避免 `??` + flatMap 闭包深链让编译器类型检查超时（CI 旧编译器复现）。
        if let item = items.first(where: { $0.id == id }) { return item }
        if let active = activePlayerItem, active.id == id { return active }
        if let selected = selectedItem, selected.id == id { return selected }
        if let preview = quickPreviewItem, preview.id == id { return preview }
        return fallback
    }

    private func syncConflictDisplayTitle(_ conflict: SyncConflict) -> String {
        "\(conflict.provider.displayName) · \(displayTitleForMediaID(conflict.mediaID))"
    }

    private func resolutionDisplayName(_ resolution: SyncConflictResolution) -> String {
        switch resolution {
        case .useLocal: return "保留本地"
        case .useRemote: return "采用远端"
        case .merge: return "合并"
        case .keepBoth: return "都保留"
        }
    }

    private func syncConflictResolutionNotice(_ conflict: SyncConflict, resolution: SyncConflictResolution) -> String {
        switch resolution {
        case .useRemote:
            return "\(syncConflictDisplayTitle(conflict)) · 已写入 MediaLIB 内部索引"
        case .useLocal where conflict.provider == .trakt:
            return "\(syncConflictDisplayTitle(conflict)) · 已写回 Trakt"
        case .useLocal, .merge, .keepBoth:
            return resolutionDisplayName(resolution)
        }
    }

}

