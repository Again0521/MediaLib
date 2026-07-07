import Foundation
import MediaLibCore

struct AppUpdatePreferenceStore {
    private enum Key {
        static let lastSuccessfulCheck = "MediaLib.update.lastSuccessfulCheck"
        static let lastBackgroundAttempt = "MediaLib.update.lastBackgroundAttempt"
        static let launchCount = "MediaLib.launchCount"
        static let sponsorInvited = "MediaLib.sponsorInvited"
    }

    var defaults: UserDefaults
    var calendar: Calendar = .current

    func markUpdateCheckSucceeded(at date: Date = Date()) {
        defaults.set(date, forKey: Key.lastSuccessfulCheck)
    }

    func recordBackgroundAttemptIfNeeded(now: Date = Date()) -> Bool {
        if let lastAttempt = defaults.object(forKey: Key.lastBackgroundAttempt) as? Date,
           now.timeIntervalSince(lastAttempt) < 4 * 60 * 60 {
            return false
        }
        if let lastSuccess = defaults.object(forKey: Key.lastSuccessfulCheck) as? Date,
           calendar.isDate(lastSuccess, inSameDayAs: now) {
            return false
        }
        defaults.set(now, forKey: Key.lastBackgroundAttempt)
        return true
    }

    func registerLaunchAndShouldInvite() -> Bool {
        let count = defaults.integer(forKey: Key.launchCount) + 1
        defaults.set(count, forKey: Key.launchCount)
        guard count == 3, !defaults.bool(forKey: Key.sponsorInvited) else { return false }
        defaults.set(true, forKey: Key.sponsorInvited)
        return true
    }
}

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
        AppUpdatePreferenceStore(defaults: .standard).markUpdateCheckSucceeded()
    }

    /// 每天第一次启动时静默检查一次更新；失败时保留重试机会，但用短间隔节流避免反复打 GitHub。
    func checkForUpdatesDailyIfNeeded() {
        guard AppUpdatePreferenceStore(defaults: .standard).recordBackgroundAttemptIfNeeded() else {
            return
        }
        checkForUpdates(manual: false)
    }

    /// 记录启动次数；恰好第三次启动时邀请用户赞赏（只弹一次）。
    func registerLaunchAndMaybeInvite() {
        guard AppUpdatePreferenceStore(defaults: .standard).registerLaunchAndShouldInvite() else { return }
        showingSponsorPrompt = true
    }
}
