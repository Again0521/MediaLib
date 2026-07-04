import Foundation
import MediaLibCore

// 应用更新检查 + 启动计数/赞赏邀请从 AppState.swift 拆到本文件，直接缩小那个超大文件
// （R1-ARCH-001 头号债务）。纯文件搬运，逐字不变。依赖均为 internal（alert / settings /
// availableUpdate / isCheckingForUpdates / updateCheckTask / showingSponsorPrompt / localized）；
// markUpdateCheckSucceeded 仅本特性使用，随之搬来仍保持 private（仅本文件可见）。
extension AppState {
    func checkForUpdates(manual: Bool) {
        if isCheckingForUpdates {
            if manual {
                alert = AppAlert(
                    title: localized("正在检查更新"),
                    message: localized("MediaLIB 正在后台确认最新版本，请稍等。")
                )
            }
            return
        }
        isCheckingForUpdates = true
        updateCheckTask?.cancel()
        updateCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isCheckingForUpdates = false
                self.updateCheckTask = nil
            }
            do {
                guard let info = try await AppUpdateChecker.fetchLatestRelease(),
                      AppVersion.isVersion(info.version, newerThan: AppVersion.current) else {
                self.markUpdateCheckSucceeded()
                if manual {
                    self.alert = AppAlert(
                        title: self.localized("已是最新版本"),
                        message: "\(self.localized("当前版本")) \(AppVersion.current)。"
                    )
                }
                return
            }
                self.markUpdateCheckSucceeded()
                if !manual {
                    if self.settings.updateSkippedVersion != nil,
                       self.settings.updateSkippedVersion != info.tagName {
                        self.settings.updateSkippedVersion = nil
                        self.saveSettings()
                    }
                    guard self.settings.updateSkippedVersion != info.tagName else { return }
                }
                self.availableUpdate = info
        } catch {
            if manual {
                self.alert = AppAlert(title: self.localized("检查更新失败"), message: error.localizedDescription)
            }
        }
    }
    }

    private func markUpdateCheckSucceeded() {
        UserDefaults.standard.set(Date(), forKey: "MediaLib.update.lastSuccessfulCheck")
    }

    /// 每天第一次启动时静默检查一次更新；失败时保留重试机会，但用短间隔节流避免反复打 GitHub。
    func checkForUpdatesDailyIfNeeded() {
        let defaults = UserDefaults.standard
        let now = Date()
        if let lastAttempt = defaults.object(forKey: "MediaLib.update.lastBackgroundAttempt") as? Date,
           now.timeIntervalSince(lastAttempt) < 4 * 60 * 60 {
            return
        }
        if let lastSuccess = defaults.object(forKey: "MediaLib.update.lastSuccessfulCheck") as? Date,
           Calendar.current.isDate(lastSuccess, inSameDayAs: now) {
            return
        }
        defaults.set(now, forKey: "MediaLib.update.lastBackgroundAttempt")
        checkForUpdates(manual: false)
    }

    /// 记录启动次数；恰好第三次启动时邀请用户赞赏（只弹一次）。
    func registerLaunchAndMaybeInvite() {
        let countKey = "MediaLib.launchCount"
        let invitedKey = "MediaLib.sponsorInvited"
        let count = UserDefaults.standard.integer(forKey: countKey) + 1
        UserDefaults.standard.set(count, forKey: countKey)
        guard count == 3, !UserDefaults.standard.bool(forKey: invitedKey) else { return }
        UserDefaults.standard.set(true, forKey: invitedKey)
        showingSponsorPrompt = true
    }
}
