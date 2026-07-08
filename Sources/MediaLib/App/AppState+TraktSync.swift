import AppKit
import Foundation
import MediaLibCore

// Trakt 导入结果（原 AppState.swift 的 private struct，随 Trakt 同步搬来）。
private struct TraktImportReport {
    var conflictCount: Int
}

// Trakt 同步（Phase 4）从 AppState.swift 拆到本文件，直接缩小那个超大文件（R1-ARCH-001 头号债务）。
// 纯文件搬运，方法体逐字不变。stored 属性（isTraktConnecting / isImportingTraktState facade / traktPollTask）
// 仍留在 AppState 主体；本文件含 traktService / isTraktConnected 两个计算属性与全部 Trakt 方法。
// 放宽到 internal 的成员：traktPollTask / remoteConnectorAccounts / remoteConnectorAccountRepository /
// cachedPrivateItemIDs（AppState 主体内），以及有组外调用者的 traktAccountRecord / withValidTraktToken /
// traktHistoryRef / traktWatchlistRef（本文件内，去掉 private）。
extension AppState {
    private var traktService: TraktService? {
        let id = settings.traktClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = settings.traktClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return TraktService(clientID: id, clientSecret: secret)
    }

    var isTraktConnected: Bool {
        TraktService.normalizedToken(settings.traktAccessToken) != nil
    }

    /// 设备码授权：请求 code → 打开浏览器 → 提示验证码 → 轮询直至授权或超时。
    func beginTraktConnect() {
        guard let service = traktService else {
            alert = AppAlert(title: "缺少凭据", message: "请先填写 Trakt Client ID 与 Client Secret。")
            return
        }
        guard !isTraktConnecting else { return }
        isTraktConnecting = true
        traktPollTask?.cancel()
        traktPollTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTraktConnecting = false }
            do {
                let device = try await service.requestDeviceCode()
                if let url = URL(string: device.verificationURL) { NSWorkspace.shared.open(url) }
                self.alert = AppAlert(
                    title: "在 Trakt 输入验证码",
                    message: "已打开 \(device.verificationURL)\n请输入验证码：\(device.userCode)\n授权后将自动完成连接。"
                )
                let deadline = Date().addingTimeInterval(Double(device.expiresIn))
                let interval = UInt64(max(device.interval, 1)) * 1_000_000_000
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: interval)
                    if Task.isCancelled { return }
                    do {
                        let tokens = try await service.pollOnce(deviceCode: device.deviceCode)
                        self.settings.traktAccessToken = tokens.accessToken
                        self.settings.traktRefreshToken = tokens.refreshToken
                        self.settings.traktSyncEnabled = true
                        self.saveSettings()
                        _ = self.traktAccountRecord(syncEnabled: true)
                        self.alert = AppAlert(title: "Trakt 已连接", message: "之后标记已看 / 想看会自动同步到 Trakt。")
                        return
                    } catch TraktError.authorizationPending {
                        continue
                    } catch TraktError.authorizationExpired {
                        self.alert = AppAlert(title: "授权超时", message: "验证码已过期，请重新连接。")
                        return
                    } catch TraktError.authorizationDenied {
                        self.alert = AppAlert(title: "已取消", message: "你拒绝了 Trakt 授权。")
                        return
                    } catch {
                        self.alert = AppAlert(title: "连接失败", message: error.localizedDescription)
                        return
                    }
                }
                self.alert = AppAlert(title: "授权超时", message: "未在有效期内完成授权，请重新连接。")
            } catch {
                self.showError("Trakt 连接失败", error)
            }
        }
    }

    func disconnectTrakt() {
        traktPollTask?.cancel()
        settings.traktAccessToken = nil
        settings.traktRefreshToken = nil
        settings.traktSyncEnabled = false
        saveSettings()
        deleteTraktAccountRecord()
    }

    func setTraktSyncEnabled(_ enabled: Bool) {
        settings.traktSyncEnabled = enabled
        saveSettings()
        if isTraktConnected {
            _ = traktAccountRecord(syncEnabled: enabled)
        }
    }

    @discardableResult
    func traktAccountRecord(syncEnabled: Bool? = nil, lastSyncedAt: Date? = nil) -> RemoteConnectorAccount? {
        guard let remoteConnectorAccountRepository else { return nil }
        let existing = remoteConnectorAccounts.first { $0.provider == .trakt }
        let now = Date()
        var account = existing ?? RemoteConnectorAccount(
            provider: .trakt,
            accountLabel: "Trakt",
            serverURL: "https://trakt.tv",
            username: nil,
            sourceID: nil,
            connectionMode: .syncOnly,
            syncEnabled: settings.traktSyncEnabled,
            capabilitiesJSON: #"{"historySync":true,"watchlistSync":true,"bidirectionalImport":true}"#,
            privacyNote: "Trakt token 仅保存在本机设置中；同步只处理已匹配 TMDB 的公开视频。"
        )
        account.connectionMode = .syncOnly
        account.serverURL = "https://trakt.tv"
        account.syncEnabled = syncEnabled ?? settings.traktSyncEnabled
        account.capabilitiesJSON = #"{"historySync":true,"watchlistSync":true,"bidirectionalImport":true}"#
        account.privacyNote = "Trakt token 仅保存在本机设置中；同步只处理已匹配 TMDB 的公开视频。"
        if let lastSyncedAt {
            account.lastSyncedAt = lastSyncedAt
        }
        account.updatedAt = now
        do {
            let saved = try remoteConnectorAccountRepository.save(account)
            if let index = remoteConnectorAccounts.firstIndex(where: { $0.id == saved.id }) {
                remoteConnectorAccounts[index] = saved
            } else {
                remoteConnectorAccounts.append(saved)
            }
            return saved
        } catch {
            logger?.log("Trakt 连接器账号保存失败：\(error.localizedDescription)", level: .warning)
            return existing
        }
    }

    private func deleteTraktAccountRecord() {
        guard let remoteConnectorAccountRepository else { return }
        for account in remoteConnectorAccounts where account.provider == .trakt {
            do {
                try remoteConnectorAccountRepository.delete(id: account.id)
            } catch {
                logger?.log("删除 Trakt 账户记录失败(\(account.id))：\(error.localizedDescription)", level: .warning)
            }
        }
        remoteConnectorAccounts.removeAll { $0.provider == .trakt }
    }

    func withValidTraktToken<T>(_ operation: (TraktService, String) async throws -> T) async throws -> T {
        guard let service = traktService, let token = TraktService.normalizedToken(settings.traktAccessToken) else {
            throw TraktError.notConnected
        }
        do {
            return try await operation(service, token)
        } catch TraktError.requestFailed(401) {
            guard let refresh = TraktService.normalizedToken(settings.traktRefreshToken) else { throw TraktError.notConnected }
            let tokens = try await service.refreshTokens(refresh)
            settings.traktAccessToken = tokens.accessToken
            settings.traktRefreshToken = tokens.refreshToken
            saveSettings()
            return try await operation(service, tokens.accessToken)
        }
    }

    /// 带令牌的 Trakt 操作；遇 401 自动刷新令牌后重试一次。
    private func runTrakt(_ operation: (TraktService, String) async throws -> Void) async {
        do {
            try await withValidTraktToken(operation)
        } catch {
            logger?.log("Trakt 同步失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private static func tmdbNumericID(_ externalID: String?, kind: String) -> Int? {
        let prefix = "tmdb:\(kind):"
        guard let externalID, externalID.hasPrefix(prefix) else { return nil }
        return Int(externalID.dropFirst(prefix.count))
    }

    func traktHistoryRef(for item: MediaItem) -> TraktMediaRef? {
        switch item.type {
        case .movie:
            return Self.tmdbNumericID(item.externalID, kind: "movie").map { .movie(tmdbID: $0) }
        case .episode:
            guard let season = item.seasonNumber, let episode = item.episodeNumber,
                  let parentID = item.parentID,
                  let parent = items.first(where: { $0.id == parentID }),
                  let showID = Self.tmdbNumericID(parent.externalID, kind: "tv") else { return nil }
            return .episode(showTmdbID: showID, season: season, episode: episode)
        default:
            return nil
        }
    }

    func traktWatchlistRef(for item: MediaItem) -> TraktMediaRef? {
        switch item.type {
        case .movie:
            return Self.tmdbNumericID(item.externalID, kind: "movie").map { .movie(tmdbID: $0) }
        case .tvShow:
            return Self.tmdbNumericID(item.externalID, kind: "tv").map { .show(tmdbID: $0) }
        default:
            return nil
        }
    }

    /// 标记已看 / 取消已看后推送到 Trakt 历史。
    func syncTraktHistory(_ items: [MediaItem], watched: Bool) {
        guard settings.traktSyncEnabled, isTraktConnected else { return }
        let refs = items
            .filter { $0.type != .privateCollection && !cachedPrivateItemIDs.contains($0.id) }
            .compactMap { traktHistoryRef(for: $0) }
        guard !refs.isEmpty else { return }
        Task { [weak self] in
            await self?.runTrakt { service, token in
                if watched {
                    try await service.addToHistory(refs, accessToken: token)
                } else {
                    try await service.removeFromHistory(refs, accessToken: token)
                }
            }
        }
    }

    /// 加入 / 移出想看后推送到 Trakt 想看清单。
    func syncTraktWatchlist(_ item: MediaItem, add: Bool) {
        guard item.type != .privateCollection, !cachedPrivateItemIDs.contains(item.id) else { return }
        guard settings.traktSyncEnabled, isTraktConnected,
              let ref = traktWatchlistRef(for: item) else { return }
        Task { [weak self] in
            await self?.runTrakt { service, token in
                if add {
                    try await service.addToWatchlist([ref], accessToken: token)
                } else {
                    try await service.removeFromWatchlist([ref], accessToken: token)
                }
            }
        }
    }

    func importTraktState() {
        guard settings.traktSyncEnabled, isTraktConnected else {
            alert = AppAlert(title: "Trakt 未启用", message: "请先连接 Trakt 并开启同步。")
            return
        }
        guard !isImportingTraktState else { return }
        isImportingTraktState = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isImportingTraktState = false }
            do {
                let state = try await self.withValidTraktToken { service, token in
                    try await service.fetchRemoteState(accessToken: token)
                }
                let report = try self.recordTraktImportConflicts(remoteState: state)
                let now = Date()
                _ = self.traktAccountRecord(syncEnabled: self.settings.traktSyncEnabled, lastSyncedAt: now)
                self.remoteConnectorAccounts = try self.remoteConnectorAccountRepository?.fetchAll() ?? self.remoteConnectorAccounts
                try self.syncConflictStore.refreshFromRepository()
                let message = report.conflictCount == 0
                    ? "没有发现需要处理的本地/远端状态差异。"
                    : "已生成 \(report.conflictCount) 条待处理同步冲突，可在“连接器与同步 > 同步冲突”中处理。"
                self.deliverTaskNotice(
                    title: "Trakt 导入完成",
                    message: message,
                    kind: .success,
                    systemTitle: "Trakt 导入完成",
                    systemBody: message
                )
            } catch {
                self.deliverTaskNotice(
                    title: "Trakt 导入失败",
                    message: error.localizedDescription,
                    kind: .error,
                    systemTitle: "Trakt 导入失败",
                    systemBody: error.localizedDescription
                )
            }
        }
    }

    private func recordTraktImportConflicts(remoteState: TraktRemoteState) throws -> TraktImportReport {
        guard syncConflictStore.isAvailable else { return TraktImportReport(conflictCount: 0) }
        let accountID = traktAccountRecord(syncEnabled: settings.traktSyncEnabled)?.id
        let remoteUpdatedAt = Date()
        var conflictCount = 0

        func saveConflict(item: MediaItem, fieldName: String, local: Bool, remote: Bool) throws {
            guard local != remote else { return }
            let conflict = SyncConflict(
                id: StableID.make(prefix: "sync-conflict", value: "trakt-\(item.id)-\(fieldName)"),
                mediaID: item.id,
                provider: .trakt,
                accountID: accountID,
                fieldName: fieldName,
                localValue: local ? "true" : "false",
                remoteValue: remote ? "true" : "false",
                localUpdatedAt: item.updatedAt,
                remoteUpdatedAt: remoteUpdatedAt
            )
            _ = try syncConflictStore.save(conflict)
            conflictCount += 1
        }

        for item in items {
            guard !cachedPrivateItemIDs.contains(item.id), item.type != .privateCollection else { continue }
            switch item.type {
            case .movie:
                guard let tmdbID = Self.tmdbNumericID(item.externalID, kind: "movie") else { continue }
                try saveConflict(
                    item: item,
                    fieldName: "watched",
                    local: item.watched,
                    remote: remoteState.watchedMovies.contains(tmdbID)
                )
                try saveConflict(
                    item: item,
                    fieldName: "watchlist",
                    local: item.watchlist,
                    remote: remoteState.watchlistMovies.contains(tmdbID)
                )
            case .tvShow:
                guard let tmdbID = Self.tmdbNumericID(item.externalID, kind: "tv") else { continue }
                try saveConflict(
                    item: item,
                    fieldName: "watchlist",
                    local: item.watchlist,
                    remote: remoteState.watchlistShows.contains(tmdbID)
                )
            case .episode:
                guard let ref = traktHistoryRef(for: item),
                      case let .episode(showTmdbID, season, episode) = ref else { continue }
                let remoteWatched = remoteState.watchedEpisodes.contains(
                    TraktEpisodeKey(showTmdbID: showTmdbID, season: season, episode: episode)
                )
                try saveConflict(
                    item: item,
                    fieldName: "watched",
                    local: item.watched,
                    remote: remoteWatched
                )
            default:
                continue
            }
        }

        return TraktImportReport(conflictCount: conflictCount)
    }
}
