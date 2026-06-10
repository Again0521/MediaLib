import MediaLibCore
import SwiftUI

struct VideoCacheMenuItems: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem

    var body: some View {
        let choices = appState.videoCacheQualityChoices(for: item)
        let hasCachedVideo = appState.includesCachedVideo(item)
        if choices.count > 1 {
            Menu {
                ForEach(choices) { choice in
                    Button {
                        appState.cacheVideo(item, qualityID: choice.id)
                    } label: {
                        Label("\(choice.label) · \(choice.detail)", systemImage: choice.id == "original" ? "sparkles.tv" : "rectangle.compress.vertical")
                    }
                }
            } label: {
                Label(hasCachedVideo ? "重新缓存到本地" : "缓存到本地", systemImage: "arrow.down.circle")
            }
        } else if let choice = choices.first {
            Button {
                appState.cacheVideo(item, qualityID: choice.id)
            } label: {
                Label(hasCachedVideo ? "重新缓存到本地" : "缓存到本地", systemImage: "arrow.down.circle")
            }
        }

        if hasCachedVideo {
            Button(role: .destructive) {
                appState.deleteVideoCache(item)
            } label: {
                Label("删除缓存文件", systemImage: "trash")
            }
        }

        if appState.canGenerateVideoFrameStoryboard(for: item) {
            Button {
                appState.generateVideoFrameStoryboard(for: item)
            } label: {
                Label("预生成章节图", systemImage: "film.stack")
            }
        }

        if appState.canAnalyzeIntroOutroMarkers(for: item) {
            Button {
                appState.analyzeIntroOutroMarkers(for: item)
            } label: {
                Label("检测片头片尾", systemImage: "wand.and.stars")
            }
        }

        if appState.canUseVideoOfflineSubscription(item) {
            Divider()
            Menu {
                automaticModeButtons(qualityID: nil)
                if choices.count > 1 {
                    Divider()
                    Menu {
                        ForEach(choices) { choice in
                            Menu {
                                automaticModeButtons(qualityID: choice.id)
                            } label: {
                                Label("\(choice.label) · \(choice.detail)", systemImage: choice.id == "original" ? "sparkles.tv" : "rectangle.compress.vertical")
                            }
                        }
                    } label: {
                        Label("指定缓存清晰度", systemImage: "slider.horizontal.3")
                    }
                }
                if let subscription = appState.videoOfflineSubscription(for: item) {
                    Divider()
                    if subscription.isPaused {
                        Button {
                            appState.resumeVideoOfflineSubscription(for: item)
                        } label: {
                            Label("继续自动缓存", systemImage: "play.circle")
                        }
                    } else {
                        Button {
                            appState.pauseVideoOfflineSubscription(for: item)
                        } label: {
                            Label("暂停 7 天", systemImage: "pause.circle")
                        }
                    }
                    Menu {
                        ForEach(VideoOfflineSubscriptionMenuPreset.visibleNetworkPolicies) { policy in
                            Button {
                                appState.setVideoOfflineSubscriptionNetworkPolicy(for: item, policy: policy)
                            } label: {
                                Label(
                                    networkPolicyTitle(policy, subscription: subscription),
                                    systemImage: networkPolicySystemImage(policy)
                                )
                            }
                        }
                    } label: {
                        Label("网络策略：\(subscription.networkPolicy.compactDisplayName)", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Menu {
                        ForEach(VideoOfflineSubscriptionExpirationPreset.all) { preset in
                            Button {
                                appState.setVideoOfflineSubscriptionExpiration(for: item, days: preset.days)
                            } label: {
                                Label(
                                    expirationPresetTitle(preset, subscription: subscription),
                                    systemImage: preset.systemImage
                                )
                            }
                        }
                    } label: {
                        Label("到期计划：\(expirationSummary(subscription))", systemImage: "calendar.badge.clock")
                    }
                    Divider()
                    Button(role: .destructive) {
                        appState.deleteVideoOfflineSubscription(for: item)
                    } label: {
                        Label("停止自动缓存", systemImage: "xmark.circle")
                    }
                }
            } label: {
                let subscription = appState.videoOfflineSubscription(for: item)
                Label(
                    subscription == nil ? "自动缓存系列" : "自动缓存：\(subscription?.compactDisplayName ?? "")",
                    systemImage: "arrow.down.circle.dotted"
                )
            }
        }
    }

    @ViewBuilder
    private func automaticModeButtons(qualityID: String?) -> some View {
        let subscription = appState.videoOfflineSubscription(for: item)
        ForEach(VideoOfflineSubscriptionMenuPreset.all) { preset in
            Button {
                appState.saveVideoOfflineSubscription(
                    for: item,
                    mode: preset.mode,
                    episodeLimit: preset.episodeLimit,
                    qualityID: qualityID
                )
            } label: {
                Label(
                    automaticModeTitle(preset, qualityID: qualityID, subscription: subscription),
                    systemImage: preset.systemImage
                )
            }
        }
        Divider()
        Button {
            appState.requestCustomVideoOfflineSubscriptionLimit(for: item, qualityID: qualityID)
        } label: {
            Label("自定义未看集数…", systemImage: "number.circle")
        }
    }

    private func automaticModeTitle(
        _ preset: VideoOfflineSubscriptionMenuPreset,
        qualityID: String?,
        subscription: VideoOfflineSubscription?
    ) -> String {
        guard let subscription,
              subscription.mode == preset.mode,
              preset.matchesEpisodeLimit(subscription.episodeLimit) else {
            return preset.title
        }
        let currentQualityID = normalizedQualityID(subscription.qualityID)
        let targetQualityID = normalizedQualityID(qualityID)
        return currentQualityID == targetQualityID ? "\(preset.title)（已开启）" : preset.title
    }

    private func normalizedQualityID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "original" else { return nil }
        return value
    }

    private func networkPolicyTitle(
        _ policy: VideoOfflineSubscriptionNetworkPolicy,
        subscription: VideoOfflineSubscription
    ) -> String {
        policy == subscription.networkPolicy ? "\(policy.displayName)（已选择）" : policy.displayName
    }

    private func networkPolicySystemImage(_ policy: VideoOfflineSubscriptionNetworkPolicy) -> String {
        switch policy {
        case .allowRemote: return "network"
        case .localNetworkOnly: return "house.and.flag"
        case .wifiOnly: return "wifi"
        }
    }

    private func expirationSummary(_ subscription: VideoOfflineSubscription) -> String {
        guard let expiresAt = subscription.expiresAt else { return "不自动到期" }
        if expiresAt <= Date() {
            return "已到期"
        }
        let remainingDays = max(1, Int(ceil(expiresAt.timeIntervalSinceNow / (24 * 60 * 60))))
        return "\(remainingDays) 天后"
    }

    private func expirationPresetTitle(
        _ preset: VideoOfflineSubscriptionExpirationPreset,
        subscription: VideoOfflineSubscription
    ) -> String {
        if preset.days == nil, subscription.expiresAt == nil {
            return "\(preset.title)（已选择）"
        }
        if let days = preset.days,
           let expiresAt = subscription.expiresAt {
            let remainingDays = max(1, Int(round(expiresAt.timeIntervalSinceNow / (24 * 60 * 60))))
            if remainingDays == days {
                return "\(preset.title)（已选择）"
            }
        }
        return preset.title
    }
}

private struct VideoOfflineSubscriptionMenuPreset: Identifiable {
    let mode: VideoOfflineSubscriptionMode
    let episodeLimit: Int

    var id: String { "\(mode.rawValue)-\(episodeLimit)" }
    var title: String { mode.displayName(episodeLimit: episodeLimit) }
    var systemImage: String { mode.systemImage }

    func matchesEpisodeLimit(_ value: Int) -> Bool {
        mode == .nextUnwatched ? max(value, 1) == episodeLimit : true
    }

    static let all: [VideoOfflineSubscriptionMenuPreset] = [
        VideoOfflineSubscriptionMenuPreset(mode: .nextEpisode, episodeLimit: 1),
        VideoOfflineSubscriptionMenuPreset(mode: .nextUnwatched, episodeLimit: 3),
        VideoOfflineSubscriptionMenuPreset(mode: .nextUnwatched, episodeLimit: 5),
        VideoOfflineSubscriptionMenuPreset(mode: .nextUnwatched, episodeLimit: 10),
        VideoOfflineSubscriptionMenuPreset(mode: .season, episodeLimit: 1),
        VideoOfflineSubscriptionMenuPreset(mode: .fullSeries, episodeLimit: 1)
    ]

    static let visibleNetworkPolicies: [VideoOfflineSubscriptionNetworkPolicy] = [
        .allowRemote,
        .localNetworkOnly,
        .wifiOnly
    ]
}

private struct VideoOfflineSubscriptionExpirationPreset: Identifiable {
    let days: Int?
    let title: String
    let systemImage: String

    var id: String { days.map(String.init) ?? "none" }

    static let all: [VideoOfflineSubscriptionExpirationPreset] = [
        VideoOfflineSubscriptionExpirationPreset(days: nil, title: "不自动到期", systemImage: "infinity"),
        VideoOfflineSubscriptionExpirationPreset(days: 7, title: "7 天后到期", systemImage: "calendar"),
        VideoOfflineSubscriptionExpirationPreset(days: 30, title: "30 天后到期", systemImage: "calendar"),
        VideoOfflineSubscriptionExpirationPreset(days: 90, title: "90 天后到期", systemImage: "calendar")
    ]
}

struct VideoOfflineSubscriptionLimitSheet: View {
    let request: VideoOfflineSubscriptionLimitRequest
    let onSave: (Int) -> Void
    let onCancel: () -> Void

    @State private var episodeLimit: Int

    init(
        request: VideoOfflineSubscriptionLimitRequest,
        onSave: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _episodeLimit = State(initialValue: max(1, min(request.initialEpisodeLimit, 99)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "自定义自动缓存",
                subtitle: "为\(request.displayTitle)设置未看剧集的离线窗口。",
                systemImage: "tray.and.arrow.down"
            )

            VStack(spacing: 14) {
                SettingsRow(title: "保持集数", systemImage: "number") {
                    Stepper(value: $episodeLimit, in: 1...99) {
                        Text("\(episodeLimit) 集")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                    .frame(width: 168, alignment: .trailing)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 18)

            AppInfoNote(
                text: "MediaLIB 会把未观看队列前 \(episodeLimit) 集保持为离线缓存；已缓存或正在缓存的剧集不会重复加入任务。",
                systemImage: "info.circle"
            )

            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                Button {
                    onSave(episodeLimit)
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
            }
        }
        .appSheetChrome(width: 500)
    }
}
