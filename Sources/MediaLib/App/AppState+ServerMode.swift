import Foundation
import MediaLibCore
import MediaLibServerProtocol

extension AppState {
    var serverModeStatus: ServerModeProcessController.Status {
        serverModeController.status
    }

    var serverModeStatusDisplayTitle: String {
        if case .running = serverModeStatus,
           serverModeConfiguration.networkAccessMode == .lanHTTPS {
            return "局域网 HTTPS 运行中"
        }
        return serverModeStatus.title
    }

    var serverModeEndpointDisplayText: String {
        serverModeConfiguration.effectiveBaseURL.absoluteString
    }

    var serverModeCertificateAuthorityURL: URL? {
        guard let directories else { return nil }
        return ServerModeCertificateSupport.certificateAuthorityURL(
            applicationSupport: directories.applicationSupport
        )
    }

    var isServerLightweightModeActive: Bool {
        serverModeConfiguration.isEnabled && serverModeConfiguration.isLightweightMode
    }

    /// App 场景出现后恢复用户此前明确开启的本机服务模式。
    func restoreServerModeIfNeeded() {
        guard serverModeConfiguration.isEnabled else { return }
        do {
            try refreshLANAddressBeforeLaunch()
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
                try refreshLANAddressBeforeLaunch()
                try serverModeController.start(configuration: serverModeConfiguration)
                serverModeConfiguration.isEnabled = true
                serverModeSettingsStore.save(serverModeConfiguration)
                applyServerLightweightPolicyIfNeeded()
                showFloatingNotice(
                    title: "服务模式已启动",
                    message: "正在确认 Web 健康状态；就绪后可通过 \(serverModeEndpointDisplayText) 登录并访问。",
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

    /// 退出应用不改变用户的“下次启动时恢复服务模式”偏好，只释放本次启动
    /// 创建的子进程，避免它继续占用端口并导致下一次启动失败。
    func stopServerModeForApplicationTermination() {
        // 保险库的解锁会话必须随 App 一起结束。它自己也会过期，但退出时收回是
        // 确定的那条路径——否则关掉 App 之后，网页上的保险库还会开着一段时间。
        clearVaultUnlockSession()
        serverModeController.stop()
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

    func updateServerModePublicOrigin(_ origin: String) {
        var configuration = serverModeConfiguration
        configuration.updatePublicOrigin(origin)
        applyServerModeConfiguration(configuration)
    }

    func updateServerModeTrustedProxyAddresses(_ value: String) {
        var configuration = serverModeConfiguration
        configuration.updateTrustedProxyAddresses(value.split(separator: ",").map(String.init))
        applyServerModeConfiguration(configuration)
    }

    func setServerLANAccessEnabled(_ isEnabled: Bool) {
        var configuration = serverModeConfiguration
        if isEnabled {
            guard let address = LANNetworkAddressResolver.preferredPrivateIPv4Address(),
                  configuration.enableLANHTTPS(address: address)
            else {
                showFloatingNotice(
                    title: "未找到局域网地址",
                    message: "请先连接 Wi-Fi 或有线局域网，再开启局域网访问。VPN 与隔空投送地址不会被使用。",
                    kind: .error
                )
                return
            }
        } else {
            configuration.updateNetworkAccessMode(.loopbackOnly)
        }
        applyServerModeConfiguration(configuration)
        showFloatingNotice(
            title: isEnabled ? "局域网访问已启用" : "局域网访问已关闭",
            message: isEnabled
                ? "服务将通过 \(configuration.effectiveBaseURL.absoluteString) 提供 HTTPS；其他设备首次访问前需要信任 MediaLIB 证书。"
                : "服务已恢复为仅本机回环访问。",
            kind: .success
        )
    }

    /// Keeps a running LAN service aligned with the address that is actually
    /// assigned after DHCP changes, interface switches, or system wake. The
    /// path monitor can publish several updates for one transition, so only the
    /// newest delayed reconciliation is allowed to restart the child process.
    func scheduleServerLANReconciliation(
        reason: String,
        forceRestart: Bool = false,
        delayNanoseconds: UInt64 = 500_000_000
    ) {
        serverLANReconciliationTask?.cancel()
        serverLANReconciliationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
                await self?.reconcileServerLANEnvironment(
                    reason: reason,
                    forceRestart: forceRestart
                )
            } catch {
                return
            }
        }
    }

    func reconcileServerLANEnvironment(
        discoveredAddress: String? = LANNetworkAddressResolver.preferredPrivateIPv4Address(),
        reason: String,
        forceRestart: Bool = false
    ) async {
        guard serverModeConfiguration.isEnabled,
              serverModeConfiguration.networkAccessMode == .lanHTTPS,
              let discoveredAddress,
              LANIPv4AddressPolicy.isPrivate(discoveredAddress)
        else { return }

        var configuration = serverModeConfiguration
        let refreshedConfiguration = ServerLANReconciliationPolicy.refreshedConfiguration(
            configuration,
            discoveredAddress: discoveredAddress
        )
        let addressChanged = refreshedConfiguration != nil
        if let refreshedConfiguration {
            configuration = refreshedConfiguration
            serverModeConfiguration = configuration
            serverModeSettingsStore.save(configuration)
        }

        let shouldRecover = ServerLANReconciliationPolicy.shouldRestart(
            status: serverModeController.status,
            addressChanged: addressChanged,
            forceRestart: forceRestart
        )
        guard shouldRecover else { return }

        serverModeController.stop()
        do {
            try serverModeController.start(configuration: configuration)
            showFloatingNotice(
                title: addressChanged ? "局域网地址已更新" : "局域网服务已恢复",
                message: "已因\(reason)重新启动 HTTPS 服务：\(configuration.effectiveBaseURL.absoluteString)",
                kind: .success
            )
        } catch {
            // Preserve the user's explicit enabled preference. A later network
            // path update or wake will retry; one transient interface gap must
            // not silently turn LAN access off.
            showFloatingNotice(
                title: "局域网服务恢复失败",
                message: error.localizedDescription,
                kind: .error
            )
        }
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

    /// 仅由同一用户、0600 Unix Socket 和随机令牌认证过的服务子进程调用。
    /// Web 请求已完成近期密码确认；宿主仍重新规范化每个字段，并在新实例未通过
    /// 健康检查时恢复旧配置与旧监听方式。
    func applyServerRuntimeConfigurationFromHost(
        _ proposed: ServerHostRuntimeConfiguration
    ) async {
        guard serverModeConfiguration.isEnabled,
              case .running = serverModeController.status,
              let mode = ServerNetworkAccessMode(rawValue: proposed.networkAccessMode)
        else { return }

        let previous = serverModeConfiguration
        var candidate = previous
        candidate.updateServerName(proposed.serverName)
        candidate.updatePort(proposed.port)
        candidate.updateNetworkAccessMode(mode)
        candidate.updatePublicOrigin(proposed.publicOrigin)
        candidate.updateTrustedProxyAddresses(proposed.trustedProxyAddresses)
        if mode == .lanHTTPS {
            guard proposed.publicOrigin == nil,
                  proposed.trustedProxyAddresses.isEmpty,
                  let address = LANNetworkAddressResolver.preferredPrivateIPv4Address(),
                  candidate.enableLANHTTPS(address: address)
            else { return }
        }
        guard candidate.serverName == proposed.serverName.trimmingCharacters(in: .whitespacesAndNewlines),
              candidate.port == proposed.port,
              candidate.publicOrigin == proposed.publicOrigin,
              candidate.trustedProxyAddresses == proposed.trustedProxyAddresses
        else { return }

        serverModeController.stop()
        serverModeConfiguration = candidate
        serverModeSettingsStore.save(candidate)
        do {
            try serverModeController.start(configuration: candidate)
            guard await waitForServerRuntimeHealth(timeout: 7) else {
                throw ServerModeHostApplyError.healthCheckFailed
            }
            showFloatingNotice(
                title: "服务配置已应用",
                message: "新的监听配置已经通过健康检查。",
                kind: .success
            )
        } catch {
            serverModeController.stop()
            serverModeConfiguration = previous
            serverModeSettingsStore.save(previous)
            do {
                try serverModeController.start(configuration: previous)
                _ = await waitForServerRuntimeHealth(timeout: 7)
            } catch {
                // 保留旧配置；下一次桌面端启动仍会按旧边界恢复，不能持久化失败配置。
            }
            showFloatingNotice(
                title: "服务配置已回滚",
                message: "新配置未通过健康检查，已恢复此前的监听设置。",
                kind: .error
            )
        }
    }

    private func waitForServerRuntimeHealth(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
        while Date() < deadline {
            switch serverModeController.status {
            case .running: return true
            case .failed, .stopped: return false
            case .starting:
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
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

    private func refreshLANAddressBeforeLaunch() throws {
        guard serverModeConfiguration.networkAccessMode == .lanHTTPS else { return }
        guard let address = LANNetworkAddressResolver.preferredPrivateIPv4Address() else {
            throw ServerModeLANConfigurationError.privateAddressUnavailable
        }
        var configuration = serverModeConfiguration
        if configuration.refreshLANAddress(address) {
            serverModeConfiguration = configuration
            serverModeSettingsStore.save(configuration)
        }
    }

    private func applyServerLightweightPolicyIfNeeded() {
        guard isServerLightweightModeActive else { return }
        cancelNonessentialVisualWarmupsForServerMode()
    }
}

enum ServerLANReconciliationPolicy {
    static func refreshedConfiguration(
        _ configuration: ServerModeConfiguration,
        discoveredAddress: String?
    ) -> ServerModeConfiguration? {
        guard configuration.isEnabled,
              configuration.networkAccessMode == .lanHTTPS,
              let discoveredAddress,
              LANIPv4AddressPolicy.isPrivate(discoveredAddress),
              configuration.lanAddress != discoveredAddress
        else { return nil }
        var refreshed = configuration
        guard refreshed.refreshLANAddress(discoveredAddress) else { return nil }
        return refreshed
    }

    static func shouldRestart(
        status: ServerModeProcessController.Status,
        addressChanged: Bool,
        forceRestart: Bool
    ) -> Bool {
        switch status {
        case .stopped, .failed:
            return true
        case .starting:
            return false
        case .running:
            return addressChanged || forceRestart
        }
    }
}

private enum ServerModeLANConfigurationError: LocalizedError {
    case privateAddressUnavailable

    var errorDescription: String? {
        "未找到可用的 Wi-Fi 或有线局域网 IPv4 地址；服务保持关闭。"
    }
}

private enum ServerModeHostApplyError: Error {
    case healthCheckFailed
}
