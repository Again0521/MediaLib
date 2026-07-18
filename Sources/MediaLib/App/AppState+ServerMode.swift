import Foundation
import MediaLibCore

extension AppState {
    var serverModeStatus: ServerModeProcessController.Status {
        serverModeController.status
    }

    var serverModeEndpointDisplayText: String {
        serverModeConfiguration.loopbackBaseURL.absoluteString
    }

    var isServerLightweightModeActive: Bool {
        serverModeConfiguration.isEnabled && serverModeConfiguration.isLightweightMode
    }

    /// App 场景出现后恢复用户此前明确开启的本机服务模式。
    func restoreServerModeIfNeeded() {
        guard serverModeConfiguration.isEnabled else { return }
        do {
            try serverModeController.start(configuration: serverModeConfiguration)
            applyServerLightweightPolicyIfNeeded()
        } catch {
            serverModeConfiguration.isEnabled = false
            serverModeSettingsStore.save(serverModeConfiguration)
            showFloatingNotice(
                title: "服务模式未启动",
                message: error.localizedDescription,
                kind: .error
            )
        }
    }

    func setServerModeEnabled(_ isEnabled: Bool) {
        if isEnabled {
            do {
                try serverModeController.start(configuration: serverModeConfiguration)
                serverModeConfiguration.isEnabled = true
                serverModeSettingsStore.save(serverModeConfiguration)
                applyServerLightweightPolicyIfNeeded()
                showFloatingNotice(
                    title: "服务模式已启动",
                    message: "当前仅允许本机通过 \(serverModeEndpointDisplayText) 登录并访问 Web 服务。",
                    kind: .success
                )
            } catch {
                serverModeConfiguration.isEnabled = false
                serverModeSettingsStore.save(serverModeConfiguration)
                showFloatingNotice(title: "服务模式未启动", message: error.localizedDescription, kind: .error)
            }
        } else {
            serverModeController.stop()
            serverModeConfiguration.isEnabled = false
            serverModeSettingsStore.save(serverModeConfiguration)
        }
    }

    /// 管理员忘记密码恢复的停机门槛。先持久化关闭自动启动，再等待服务子进程退出；
    /// 恢复完成后保持关闭，由管理员用新密码确认后手动重新开启。
    func prepareServerForCredentialRecovery() async -> Bool {
        serverModeConfiguration.isEnabled = false
        serverModeSettingsStore.save(serverModeConfiguration)
        return await serverModeController.stopAndWaitForExit()
    }

    func updateServerModeServerName(_ name: String) {
        var configuration = serverModeConfiguration
        configuration.updateServerName(name)
        applyServerModeConfiguration(configuration)
    }

    func updateServerModePort(_ port: Int) {
        var configuration = serverModeConfiguration
        configuration.updatePort(port)
        applyServerModeConfiguration(configuration)
    }

    func setServerLightweightModeEnabled(_ isEnabled: Bool) {
        guard serverModeConfiguration.isEnabled else {
            showFloatingNotice(
                title: "请先启动服务模式",
                message: "轻量模式只在服务运行时生效，避免误以为已降低本机负载。",
                kind: .warning
            )
            return
        }
        var configuration = serverModeConfiguration
        configuration.isLightweightMode = isEnabled
        applyServerModeConfiguration(configuration)
        if isEnabled {
            showFloatingNotice(
                title: "轻量服务模式已启用",
                message: "已停止桌面视觉预热；索引、扫描、认证与媒体分发继续运行。",
                kind: .success
            )
        }
    }

    private func applyServerModeConfiguration(_ configuration: ServerModeConfiguration) {
        guard configuration != serverModeConfiguration else { return }
        let shouldRestart = serverModeConfiguration.isEnabled
        if shouldRestart {
            serverModeController.stop()
        }
        serverModeConfiguration = configuration
        serverModeSettingsStore.save(configuration)
        if shouldRestart {
            restoreServerModeIfNeeded()
        }
        applyServerLightweightPolicyIfNeeded()
    }

    private func applyServerLightweightPolicyIfNeeded() {
        guard isServerLightweightModeActive else { return }
        cancelNonessentialVisualWarmupsForServerMode()
    }
}
