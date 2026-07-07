import AppKit
import Foundation
import MediaLibCore

// 从 AppState.swift 物理拆出（零行为变化）：Last.fm 听歌打卡（B2）领域。
// 仍是同一个 AppState 类型的 extension（单一 ObservableObject 不变），只是把该领域的方法移到独立文件，
// 便于维护与后续真正的 store 化。访问的存储属性（logger / pendingScrobble / lastfmPendingAuthToken /
// isLastfmAuthorizing）已在主类放开为 internal；scrobbleMusicStart 也放开为 internal 供播放链路跨文件调用。
extension AppState {
    private var lastfmService: LastfmScrobbleService? {
        let key = settings.lastfmAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = settings.lastfmSharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, !secret.isEmpty else { return nil }
        return LastfmScrobbleService(apiKey: key, sharedSecret: secret)
    }

    var isLastfmConnected: Bool {
        LastfmScrobbleService.normalizedSessionKey(settings.lastfmSessionKey) != nil
    }

    /// 新曲目开始：先结算上一首，再对当前曲目发送 updateNowPlaying 并登记候选。
    func scrobbleMusicStart(_ item: MediaItem) {
        finalizeScrobble()
        guard settings.lastfmScrobblingEnabled,
              let sessionKey = LastfmScrobbleService.normalizedSessionKey(settings.lastfmSessionKey),
              let service = lastfmService,
              let artist = item.artist, !artist.isEmpty else {
            pendingScrobble = nil
            return
        }
        let duration = item.duration ?? Double((item.runtime ?? 0) * 60)
        pendingScrobble = (item: item, startedAt: Date(), duration: duration)

        let track = item.title
        let album = item.album
        let durationSeconds = duration > 0 ? Int(duration) : nil
        Task { [weak self] in
            do {
                try await service.updateNowPlaying(
                    artist: artist, track: track, album: album,
                    durationSeconds: durationSeconds, sessionKey: sessionKey
                )
            } catch {
                self?.logger?.log("Last.fm updateNowPlaying 失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    /// 结算待打卡曲目：满足时长门槛（>30s 且播放过半或满 4 分钟）才提交 track.scrobble。
    func finalizeScrobble() {
        guard let candidate = pendingScrobble else { return }
        pendingScrobble = nil
        guard settings.lastfmScrobblingEnabled,
              let sessionKey = LastfmScrobbleService.normalizedSessionKey(settings.lastfmSessionKey),
              let service = lastfmService,
              let artist = candidate.item.artist, !artist.isEmpty else { return }

        let duration = candidate.duration
        // 时长未知时按播放满 30s 估计；已知时按官方门槛：过半或满 4 分钟。
        let elapsed = min(Date().timeIntervalSince(candidate.startedAt), duration > 0 ? duration : .greatestFiniteMagnitude)
        let threshold: Double = duration > 0 ? min(duration / 2, 240) : 30
        guard duration <= 0 || duration > 30, elapsed >= threshold else { return }

        let timestamp = Int(candidate.startedAt.timeIntervalSince1970)
        let track = candidate.item.title
        let album = candidate.item.album
        let durationSeconds = duration > 0 ? Int(duration) : nil
        Task { [weak self] in
            do {
                try await service.scrobble(
                    artist: artist, track: track, album: album,
                    timestamp: timestamp, durationSeconds: durationSeconds, sessionKey: sessionKey
                )
                self?.logger?.log("Last.fm 已打卡：\(artist) - \(track)")
            } catch {
                self?.logger?.log("Last.fm scrobble 失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    /// 设置页：第一步——获取 token 并打开浏览器授权页。
    func beginLastfmAuthorization() {
        guard let service = lastfmService else {
            alert = AppAlert(title: "缺少凭据", message: "请先填写 Last.fm API Key 与 Shared Secret。")
            return
        }
        guard !isLastfmAuthorizing else { return }
        isLastfmAuthorizing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLastfmAuthorizing = false }
            do {
                let token = try await service.fetchToken()
                self.lastfmPendingAuthToken = token
                if let url = service.authorizationURL(token: token) {
                    NSWorkspace.shared.open(url)
                }
                self.alert = AppAlert(
                    title: "请在浏览器中授权",
                    message: "已打开 Last.fm 授权页。点击“允许访问”后，回到这里点击「完成连接」。"
                )
            } catch {
                self.showError("Last.fm 授权失败", error)
            }
        }
    }

    /// 设置页：第二步——用户授权后用 token 换 session key 并保存。
    func completeLastfmAuthorization() {
        guard let service = lastfmService else { return }
        guard let token = lastfmPendingAuthToken else {
            alert = AppAlert(title: "尚未开始授权", message: "请先点击「授权」并在浏览器中确认。")
            return
        }
        guard !isLastfmAuthorizing else { return }
        isLastfmAuthorizing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLastfmAuthorizing = false }
            do {
                let session = try await service.fetchSession(token: token)
                self.settings.lastfmSessionKey = session.sessionKey
                self.settings.lastfmUsername = session.username
                self.lastfmPendingAuthToken = nil
                self.saveSettings()
                self.alert = AppAlert(title: "Last.fm 已连接", message: "已连接账号 \(session.username)，开始播放音乐即可自动打卡。")
            } catch {
                self.showError("Last.fm 连接失败", error)
            }
        }
    }

    func disconnectLastfm() {
        settings.lastfmSessionKey = nil
        settings.lastfmUsername = nil
        lastfmPendingAuthToken = nil
        saveSettings()
    }
}
