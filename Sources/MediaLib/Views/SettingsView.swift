import AppKit
import MediaLibCore
import Photos
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsControlMetrics {
    static let compactControlWidth: CGFloat = 190
    static let actionButtonWidth: CGFloat = 96
    static let wideControlWidth: CGFloat = 430
}

private enum SettingsHeaderChrome {
    // 固定区只容纳标题、副标题及其与首个分组之间的留白（190→172：按用户反馈略微收紧
    // 标题与首个设置分组的间距）。
    static let height: CGFloat = 172
    // 标题区硬遮罩的下缘（相对内容区顶部）：只盖到标题+副标题下方一点点，
    // 不延伸到与首个分组之间的整段留白，底边硬切、无渐隐。
    // 遮罩常驻显示（静止时也在），避免滚动途中突然出现的观感。
    static let scrollMaskHeight: CGFloat = 122
}

/// 设置 List 的“刻意结构动画”通行证：List 上有禁用隐式动画的滚动性能闸，
/// 开关/选择器联动行的显隐动画必须带此标记才能通过（macOS 14+；更早系统保持瞬时）。
@available(macOS 14.0, *)
private struct SettingsExplicitAnimationKey: TransactionKey {
    static let defaultValue = false
}

/// 用带通行证的动画事务写入设置：驱动条件行以 List 行插入/移除动画显隐。
private func withSettingsRevealAnimation(_ body: () -> Void) {
    if #available(macOS 14.0, *) {
        var transaction = Transaction(animation: AppMotion.standard)
        transaction[SettingsExplicitAnimationKey.self] = true
        withTransaction(transaction, body)
    } else {
        body()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var systemPhotoLibrary: SystemPhotoLibraryStore
    @State private var showingMusicTagSheet = false
    @State private var showingAboutSoftware = false
    @State private var showingSyncConflictQueue = false
    @State private var showingMetadataHistory = false
    @State private var showingServerPasswordSetup = false
    @State private var showingServerPasswordChange = false
    @State private var showingServerPasswordRecovery = false
    @State private var showingServerSessionManagement = false
    @State private var showingServerUserManagement = false
    @State private var autoStartMusicMetadataConsole = false
    @State private var serverModeNameDraft = ""
    @State private var serverModePortDraft = ""
    @State private var serverModePublicOriginDraft = ""
    @State private var serverModeTrustedProxiesDraft = ""
    /// 高级选项开关：关闭时（默认）隐藏未做完 / 不建议小白修改的进阶分区
    /// （服务端预览、Trakt、账号同步、数据诊断，以及音乐主题 JSON 微调行）。
    /// 仅控制显隐，不影响已保存的配置。用 AppStorage 持久化，属纯 UI 偏好。
    @AppStorage("MediaLib.settings.showAdvancedOptions") private var showAdvancedOptions = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            // 设置分组继续使用原生 List 虚拟化；标题区移出 List，避免 List 行内边距和
            // 普通页面的 pageContainer 链路不一致，造成标题位置偏移。
            List {
                Color.clear
                    .frame(height: SettingsHeaderChrome.height - 8)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                // 小白友好分区：始终可见。
                settingsRow(topPadding: 0) { appearanceSettings }
                settingsRow { videoPlaybackSettings }
                settingsRow { musicPlaybackSettings }
                settingsRow { scanSettings }
                settingsRow { metadataSettings }
                settingsRow { subtitleSettings }
                settingsRow { thumbnailSettings }
                settingsRow { privacySettings }

                // 高级选项开关：其下进阶分区仅在开启时显示。
                settingsRow { advancedOptionsSection }
                if showAdvancedOptions {
                    settingsRow { traktSettings }
                    settingsRow { connectorStateSettings }
                    settingsRow { serverModeSettings }
                    settingsRow { advancedSettings }
                }

                settingsRow { aboutSettings }
                Color.clear
                    .frame(height: 18)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .suppressHoverEffectsDuringScroll()
            .glassPerformanceMode(.balanced)
            .preferStaticGlassSurfaces(true)
            .suppressListHighlight()
            .transaction { transaction in
                // 历史滚动优化：禁用设置 List 的隐式动画（主题 ripple、滚动重排）。
                // 带通行证的刻意结构动画（联动行显隐）放行，其余照旧扼杀。
                if #available(macOS 14.0, *), transaction[SettingsExplicitAnimationKey.self] {
                    return
                }
                transaction.animation = nil
            }

            // 标题区硬遮罩：常驻显示（静止时也在，不做滚动门控，避免滑动途中突然出现），
            // 从窗口最顶盖到标题+副标题下方一点点，底边硬切不做渐隐。
            // 材质必须全不透明度：加 .opacity 会让系统放弃 backdrop 模糊（Apple 材质规则），
            // ultraThinMaterial 本身就是官方最透的模糊档位。
            AppPageTitleBlurBand(solidExtension: SettingsHeaderChrome.scrollMaskHeight)
                .zIndex(1)

            SettingsHeader()
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.top, AppSpacing.pageVertical)
                .padding(.bottom, AppSpacing.headerToControls)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: SettingsHeaderChrome.height, alignment: .topLeading)
                .allowsHitTesting(false)
                .zIndex(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPageBackground())
        .navigationTitle(appState.localized("设置"))
        .sheet(isPresented: $showingMusicTagSheet) {
            MusicTagScraperSheet(
                autoStart: autoStartMusicMetadataConsole,
                includeLyrics: autoStartMusicMetadataConsole
            )
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingAboutSoftware) {
            AboutMediaLIBSheet()
        }
        .sheet(isPresented: $showingSyncConflictQueue) {
            SyncConflictQueueSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingMetadataHistory) {
            MetadataCorrectionHistorySheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingServerPasswordSetup) {
            ServerInitialPasswordSetupSheet(
                store: appState.serverAdministrationStore,
                onComplete: {
                    showingServerPasswordSetup = false
                    appState.showFloatingNotice(
                        title: "管理员密码已设置",
                        message: "现在可以使用 admin 登录本机 Web 服务。",
                        kind: .success
                    )
                },
                onCancel: { showingServerPasswordSetup = false }
            )
        }
        .sheet(isPresented: $showingServerPasswordChange) {
            ServerAdministratorPasswordChangeSheet(
                store: appState.serverAdministrationStore,
                onComplete: {
                    showingServerPasswordChange = false
                    appState.showFloatingNotice(
                        title: "管理员密码已修改",
                        message: "全部 Web 与 Mlink 会话已退出，请使用新密码重新登录。",
                        kind: .success
                    )
                },
                onCancel: { showingServerPasswordChange = false }
            )
        }
        .sheet(isPresented: $showingServerPasswordRecovery) {
            ServerAdministratorPasswordRecoverySheet(
                store: appState.serverAdministrationStore,
                prepareForRecovery: { await appState.prepareServerForCredentialRecovery() },
                onComplete: {
                    showingServerPasswordRecovery = false
                    appState.showFloatingNotice(
                        title: "管理员密码已恢复",
                        message: "旧设备和会话已全部撤销；服务保持关闭，请确认新密码后手动重新开启。",
                        kind: .success
                    )
                },
                onCancel: { showingServerPasswordRecovery = false }
            )
        }
        .sheet(isPresented: $showingServerSessionManagement) {
            ServerSessionManagementSheet(
                store: appState.serverAdministrationStore,
                onClose: { showingServerSessionManagement = false }
            )
        }
        .sheet(isPresented: $showingServerUserManagement) {
            ServerUserManagementSheet(
                store: appState.serverAdministrationStore,
                libraries: serverLibraryOptions,
                onClose: { showingServerUserManagement = false }
            )
        }
        .onAppear {
            if serverModeNameDraft.isEmpty {
                serverModeNameDraft = appState.serverModeConfiguration.serverName
            }
            if serverModePortDraft.isEmpty {
                serverModePortDraft = String(appState.serverModeConfiguration.port)
            }
            if serverModePublicOriginDraft.isEmpty {
                serverModePublicOriginDraft = appState.serverModeConfiguration.publicOrigin ?? ""
            }
            if serverModeTrustedProxiesDraft.isEmpty {
                serverModeTrustedProxiesDraft = appState.serverModeConfiguration.trustedProxyAddresses.joined(separator: ", ")
            }
        }
        .task {
            await appState.serverAdministrationStore.refresh()
        }
    }

    // 设置分组行：860pt 居中最大宽度 + 上下内边距构成 24pt 间距，清除 List 默认行样式。
    // 横向留白统一读 pageHorizontal（曾写死 34，窄窗口下与页头的 32 差 2pt 造成左边线不齐）。
    @ViewBuilder
    private func settingsRow<Content: View>(topPadding: CGFloat = 12, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .listRowInsets(EdgeInsets(top: topPadding, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var videoPlaybackSettings: some View {
        SettingsSection(title: "视频播放与缓存", subtitle: "设置视频启动方式、观看规则和离线缓存。", systemImage: "play.rectangle") {
            SettingsSubsectionHeader(title: "启动方式", systemImage: "play.rectangle")

            SettingsRow(title: "视频播放器", systemImage: "play.rectangle") {
                Picker("视频播放器", selection: Binding(get: {
                    appState.settings.videoDefaultPlayer
                }, set: { value in
                    // 带通行证的动画事务：外部播放器路径行随选择显隐时走行插入动画。
                    withSettingsRevealAnimation {
                        appState.settings.videoDefaultPlayer = value
                    }
                    appState.saveSettings()
                })) {
                    ForEach(DefaultPlayer.allCases) { player in
                        Text(appState.localized(player.displayName)).tag(player)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.videoDefaultPlayer.displayName))
            }

            if appState.settings.videoDefaultPlayer == .external {
                SettingsRow(title: "视频系统播放器", systemImage: "app.badge") {
                    SettingsPathText(text: appState.settings.videoExternalPlayerPath ?? "系统默认")
                    Button {
                        chooseExternalPlayer(forMusic: false)
                    } label: {
                        Label("选择…", systemImage: "app")
                    }
                    .settingsActionButton()
                }
            }

            SettingsRow(title: "系统默认视频播放器", systemImage: "checkmark.seal") {
                Button {
                    registerAsSystemDefault(forMusic: false)
                } label: {
                    Label("设为默认", systemImage: "star")
                }
                .settingsActionButton()
            }

            SettingsDescription(text: "选「内置」用 MediaLIB 自带的播放器看视频；选「系统」交给你常用的播放器打开。播放中的窗口、倍速、字幕等设置都在播放窗口的齿轮菜单里。点「设为默认」后，在访达中双击视频也会用 MediaLIB 打开。")

            SettingsSubsectionHeader(title: "观看规则", systemImage: "slider.horizontal.3")

            SettingsToggleRow(title: "记忆播放进度", systemImage: "clock.arrow.circlepath", isOn: binding(\.rememberPlaybackPosition))
            SettingsToggleRow(title: "播放完成自动标记已看", systemImage: "checkmark.circle", isOn: binding(\.autoMarkWatched))

            SettingsRow(title: "播放结束行为", systemImage: "forward.end") {
                Picker("播放结束行为", selection: Binding(get: {
                    appState.settings.videoPlaybackEndAction
                }, set: { action in
                    appState.settings.videoPlaybackEndAction = action
                    appState.settings.autoPlayNextEpisode = action == .nextEpisode
                    appState.saveSettings()
                })) {
                    ForEach(VideoPlaybackEndAction.allCases) { action in
                        Text(appState.localized(action.displayName)).tag(action)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.videoPlaybackEndAction.displayName))
            }

            SettingsRow(title: "已看判定", systemImage: "checkmark.seal") {
                Picker("已看判定", selection: Binding(get: {
                    appState.settings.watchedThreshold
                }, set: { value in
                    appState.settings.watchedThreshold = value
                    appState.saveSettings()
                })) {
                    Text("播放 70%").tag(0.7)
                    Text("播放 80%").tag(0.8)
                    Text("播放 90%").tag(0.9)
                    Text("播放 95%").tag(0.95)
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: "\(Int((appState.settings.watchedThreshold * 100).rounded()))%")
            }

            SettingsSubsectionHeader(title: "离线缓存", systemImage: "externaldrive.badge.arrow.down")

            SettingsRow(title: "视频缓存位置", systemImage: "externaldrive.badge.arrow.down") {
                SettingsPathText(text: appState.videoCacheDirectoryDisplayPath)
                Button {
                    chooseVideoCacheDirectory()
                } label: {
                    Label("选择…", systemImage: "folder")
                }
                .settingsActionButton(width: 82)

                if appState.settings.videoCacheDirectoryPath != nil {
                    Button {
                        appState.chooseVideoCacheDirectory(url: nil)
                    } label: {
                        Label("默认", systemImage: "arrow.uturn.backward")
                    }
                    .settingsActionButton(width: 82)
                }
            }

            SettingsDescription(text: "离线视频会保存在这个位置。删除缓存只清理这些离线副本，不会动你原来的文件。")

            SettingsRow(title: "视频缓存占用", systemImage: "internaldrive") {
                Text(appState.videoCacheStorageDisplayText)
                    .font(.caption.weight(appState.videoCacheStorageSummary.isOverLimit ? .semibold : .regular))
                    .foregroundStyle(appState.videoCacheStorageSummary.isOverLimit ? AppColors.selectedGlassTint : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .staticSurfaceBackground(cornerRadius: 9, thickness: 0.86)
            }

            SettingsRow(title: "缓存容量上限", systemImage: "externaldrive.badge.minus") {
                Picker("缓存容量上限", selection: Binding(get: {
                    appState.settings.videoCacheSizeLimitGB
                }, set: { value in
                    appState.updateVideoCacheSizeLimit(value)
                })) {
                    ForEach(settingsVideoCacheLimitOptions(current: appState.settings.videoCacheSizeLimitGB), id: \.self) { value in
                        Text(settingsVideoCacheLimitTitle(value)).tag(value)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.videoCacheSizeLimitDisplayText)
            }

            SettingsDescription(text: "设定上限后，会优先清理已经看完的和很久没看的缓存，为新内容腾出空间。")
        }
    }

    private var musicPlaybackSettings: some View {
        SettingsSection(title: "音乐播放", subtitle: "设置音乐播放器、歌词、响度和过渡。", systemImage: "music.note") {
            SettingsRow(title: "音乐播放器", systemImage: "music.note") {
                Picker("音乐播放器", selection: Binding(get: {
                    appState.settings.musicDefaultPlayer
                }, set: { value in
                    withSettingsRevealAnimation {
                        appState.settings.musicDefaultPlayer = value
                    }
                    appState.saveSettings()
                })) {
                    ForEach(DefaultPlayer.allCases) { player in
                        Text(appState.localized(player.displayName)).tag(player)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.musicDefaultPlayer.displayName))
            }

            if appState.settings.musicDefaultPlayer == .external {
                SettingsRow(title: "音乐系统播放器", systemImage: "app.badge") {
                    SettingsPathText(text: appState.settings.musicExternalPlayerPath ?? "系统默认")
                    Button {
                        chooseExternalPlayer(forMusic: true)
                    } label: {
                        Label("选择…", systemImage: "app")
                    }
                    .settingsActionButton()
                }
            }

            SettingsRow(title: "系统默认音乐播放器", systemImage: "checkmark.seal") {
                Button {
                    registerAsSystemDefault(forMusic: true)
                } label: {
                    Label("设为默认", systemImage: "star")
                }
                .settingsActionButton()
            }

            SettingsRow(title: "歌词同步", systemImage: "text.badge.checkmark") {
                Picker("歌词同步", selection: binding(\.lyricSyncAlgorithm)) {
                    ForEach(LyricSyncAlgorithm.allCases) { algorithm in
                        Text(appState.localized(algorithm.displayName)).tag(algorithm)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.lyricSyncAlgorithm.displayName))
            }

            SettingsDescription(text: appState.settings.lyricSyncAlgorithm.description)

            if appState.settings.musicDefaultPlayer == .builtIn {
                SettingsRow(title: "播放器外观", systemImage: "square.stack.3d.up") {
                    Picker("播放器外观", selection: binding(\.musicPlayerVisualScheme)) {
                        // 临时隐藏「无界」入口（仅去设置选项，枚举与实现代码保留）。
                        ForEach(MusicPlayerVisualScheme.allCases.filter { $0 != .wujie }) { scheme in
                            Text(appState.localized(scheme.displayName)).tag(scheme)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuControl(selectedTitle: appState.localized(appState.settings.musicPlayerVisualScheme.displayName))
                }
                SettingsDescription(text: appState.settings.musicPlayerVisualScheme.description)

                SettingsToggleRow(title: "封面发光", systemImage: "sparkles", isOn: binding(\.musicAlbumCoverGlowEnabled))
                SettingsDescription(text: "开启时展开播放器使用封面原图的多层柔光；关闭后只保留主色的浅柔阴影，暂停时同样收起光效。")

                if showAdvancedOptions {
                    SettingsRow(title: "主题参数自定义", systemImage: "slider.horizontal.3") {
                        HStack(spacing: 8) {
                            Button("打开配置文件") { appState.revealMusicThemeConfigFile() }
                                .settingsActionButton(width: nil)
                            Button("重新加载") { appState.reloadMusicThemeConfig() }
                                .settingsActionButton(width: nil)
                            Button("恢复默认") { appState.resetMusicThemeConfig() }
                                .settingsActionButton(width: nil)
                        }
                    }
                    SettingsDescription(text: "高级：编辑 ~/Library/Application Support/MediaLib/Themes/music-theme.json 可微调三套主题（琉璃 / 无界 / 湖光）的玻璃浓度、发光、圆角、字号、间距等数值。改完点「重新加载」即时生效，无需重启；「恢复默认」清空全部自定义。极端数值可能影响观感或性能，随时可「恢复默认」还原。")
                }

                SettingsRow(title: "音乐响度均衡", systemImage: "waveform.badge.magnifyingglass") {
                    Picker("音乐响度均衡", selection: binding(\.musicLoudnessNormalization)) {
                        ForEach(MusicLoudnessNormalization.allCases) { mode in
                            Text(appState.localized(mode.displayName)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuControl(selectedTitle: appState.localized(appState.settings.musicLoudnessNormalization.displayName))
                }

                SettingsDescription(text: "按歌曲已有的 ReplayGain / R128 标签均衡音量，并保留峰值保护。不会修改音乐文件。")

                SettingsRow(title: "跨曲过渡", systemImage: "arrow.right.to.line.compact") {
                    Picker("跨曲过渡", selection: revealBinding(\.musicTransitionMode)) {
                        ForEach(MusicTransitionMode.allCases) { mode in
                            Text(appState.localized(mode.displayName)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuControl(selectedTitle: appState.localized(appState.settings.musicTransitionMode.displayName))
                }

                if appState.settings.musicTransitionMode == .softFade {
                    SettingsRow(title: "淡入时长", systemImage: "waveform.path") {
                        AppValueSlider(
                            value: binding(\.musicSoftFadeDuration),
                            bounds: 0.3...2,
                            step: 0.1,
                            accessibilityLabel: "淡入时长"
                        )
                        Text(String(format: "%.1f 秒", appState.settings.musicSoftFadeDuration))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }

                SettingsToggleRow(title: "均衡器", systemImage: "slider.vertical.3", isOn: binding(\.musicEqualizerEnabled))

                if appState.settings.musicEqualizerEnabled {
                    SettingsRow(title: "均衡器预设", systemImage: "dial.medium") {
                        Picker("均衡器预设", selection: binding(\.musicEqualizerPreset)) {
                            ForEach(MusicEqualizerPreset.allCases) { preset in
                                Text(appState.localized(preset.displayName)).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .settingsMenuControl(selectedTitle: appState.localized(appState.settings.musicEqualizerPreset.displayName))
                    }
                    SettingsDescription(text: "从低音到高音五段调节，对所有音乐生效；新的设置从下一首开始。")
                }
            }
        }
    }

    private var homeSettings: some View {
        SettingsSection(title: "首页入口", subtitle: "选择首页显示的内容。", systemImage: "square.grid.2x2") {
            SettingsDescription(text: "首页只显示已开启且有内容的分类，并始终保留至少一个选项卡。")
            HomeTabSettingsGrid()
        }
    }

    private var scanSettings: some View {
        SettingsSection(title: "媒体库更新", subtitle: "设置扫描频率、后台进度和完成提醒。", systemImage: "arrow.triangle.2.circlepath") {
            SettingsRow(title: "自动扫描", systemImage: "clock.arrow.circlepath") {
                Picker("自动扫描", selection: binding(\.automaticScanInterval)) {
                    ForEach(AutomaticScanInterval.allCases) { interval in
                        Text(appState.localized(interval.displayName)).tag(interval)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.automaticScanInterval.displayName))
            }

            SettingsDescription(text: "本机文件夹有变动会很快更新；移动硬盘和网络位置按固定间隔检查。暂时连不上的来源会先跳过，之后自动再试。")

            SettingsRow(title: "完成后发送通知", systemImage: "bell.badge") {
                Toggle("", isOn: Binding(get: {
                    appState.settings.notifyOnTaskCompletion
                }, set: { value in
                    appState.setTaskCompletionNotifications(value)
                }))
                .labelsHidden()
                .toggleStyle(AppSwitchToggleStyle())
            }

            SettingsDescription(text: "扫描或同步完成时，如果你不在 MediaLIB 里，会通过通知中心提醒你（首次开启会请求通知权限）。")
        }
    }

    private var thumbnailSettings: some View {
        SettingsSection(title: "封面与截图", subtitle: "设置缺失封面、视频帧截图和并发任务。", systemImage: "photo.on.rectangle") {
            SettingsRow(title: "系统照片图库", systemImage: "photo.stack") {
                HStack(spacing: 10) {
                    AppStatusBadge(
                        title: systemPhotoAuthorizationTitle,
                        systemImage: systemPhotoAuthorizationIcon,
                        tint: systemPhotoLibrary.isAuthorized ? .green : AppColors.selectedGlassTint
                    )

                    Button(systemPhotoLibrary.isAuthorized ? "刷新权限" : "授权访问") {
                        Task {
                            if systemPhotoLibrary.authorizationStatus == .notDetermined {
                                await systemPhotoLibrary.requestAccessAndLoad(collectionID: "all")
                            } else {
                                await systemPhotoLibrary.refreshAuthorizationAndReload()
                                if !systemPhotoLibrary.isAuthorized,
                                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                    .settingsActionButton(width: nil, prominent: !systemPhotoLibrary.isAuthorized)
                }
            }

            SettingsDescription(text: "系统照片现在固定显示在「相册」控制条中。MediaLIB 通过 PhotoKit 实时读取，不复制图库；喜欢与删除操作会同步修改系统「照片」App。")

            SettingsRow(title: "缺失封面处理", systemImage: "photo.badge.plus") {
                ArtworkFallbackModeCapsules(
                    selection: Binding(get: {
                        appState.settings.artworkFallbackMode
                    }, set: { mode in
                        appState.settings.artworkFallbackMode = mode
                        appState.settings.enableThumbnailFallback = mode != .none
                        appState.saveSettings()
                    })
                )
                .frame(width: SettingsControlMetrics.wideControlWidth, alignment: .trailing)
            }

            SettingsDescription(text: appState.settings.artworkFallbackMode.description)

            SettingsToggleRow(title: "避开黑屏", systemImage: "moon.zzz", isOn: binding(\.avoidBlackFrames))
                .disabled(appState.settings.artworkFallbackMode != .videoFrame)

            SettingsRow(title: "截图位置", systemImage: "timeline.selection") {
                AppValueSlider(
                    value: binding(\.thumbnailCaptureRatio),
                    bounds: 0.05...0.3,
                    step: 0.05,
                    accessibilityLabel: "截图位置"
                )
                Text("\(Int(appState.settings.thumbnailCaptureRatio * 100))%")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(appState.settings.artworkFallbackMode != .videoFrame)

            SettingsRow(title: "并发截图任务", systemImage: "cpu") {
                Picker("并发截图任务", selection: Binding(get: {
                    appState.settings.thumbnailConcurrency
                }, set: { value in
                    appState.settings.thumbnailConcurrency = max(1, min(value, 4))
                    appState.saveSettings()
                })) {
                    ForEach(1...4, id: \.self) { count in
                        Text("\(count) 个任务").tag(count)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: "\(appState.settings.thumbnailConcurrency) 个任务")
            }
            .disabled(appState.settings.artworkFallbackMode == .none)
        }
    }

    private var systemPhotoAuthorizationTitle: String {
        switch systemPhotoLibrary.authorizationStatus {
        case .authorized: return "已授权"
        case .limited: return "有限访问"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .notDetermined: return "尚未授权"
        @unknown default: return "未知状态"
        }
    }

    private var systemPhotoAuthorizationIcon: String {
        systemPhotoLibrary.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle"
    }

    private var metadataSettings: some View {
        SettingsSection(title: "元数据与匹配", subtitle: "管理影片、剧集和音乐的信息来源。", systemImage: "sparkles.rectangle.stack") {
            SettingsSubsectionHeader(title: "影片信息", systemImage: "film")
            SettingsDescription(text: "影片信息由 TMDB 提供；填写 API Key 或 Read Access Token 后即可匹配。")

            SettingsRow(title: "TMDB API", systemImage: "key") {
                SecureField("API Key 或 Read Access Token", text: Binding(get: {
                    appState.settings.tmdbAPIKey ?? ""
                }, set: { value in
                    appState.settings.tmdbAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    appState.saveSettings()
                }))
                .settingsTextInput(
                    text: appState.settings.tmdbAPIKey ?? "",
                    placeholder: "API Key 或 Read Access Token",
                    maxWidth: SettingsControlMetrics.wideControlWidth
                )
            }

            SettingsRow(title: "TMDB 语言", systemImage: "globe") {
                TextField("zh-CN", text: Binding(get: {
                    appState.settings.tmdbLanguage
                }, set: { value in
                    appState.settings.tmdbLanguage = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "zh-CN" : value
                    appState.saveSettings()
                }))
                .settingsTextInput(text: appState.settings.tmdbLanguage, maxWidth: SettingsControlMetrics.compactControlWidth)
            }

            SettingsRow(title: "影视匹配宽容度", systemImage: "scope") {
                Picker("影视匹配宽容度", selection: binding(\.metadataMatchTolerance)) {
                    ForEach(MetadataMatchTolerance.allCases) { mode in
                        Text(appState.localized(mode.displayName)).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.metadataMatchTolerance.displayName))
            }

            SettingsDescription(text: "决定自动匹配需要多大把握：\(appState.settings.metadataMatchTolerance.summary)。越宽松越容易自动配上信息，但偶尔可能认错；拿不准就保持默认。")

            SettingsRow(title: "剧集一键匹配", systemImage: "wand.and.stars") {
                Button {
                    appState.startTMDBMatchForTVSeries()
                } label: {
                    Label(
                        appState.isMatchingTMDB ? "匹配中…" : "立即匹配",
                        systemImage: appState.isMatchingTMDB ? "hourglass" : "wand.and.stars"
                    )
                }
                .settingsActionButton(prominent: true)
                .disabled(appState.isMatchingTMDB || (appState.settings.tmdbAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            SettingsRow(title: "自动拉取周期", systemImage: "clock.arrow.circlepath") {
                Picker("自动拉取周期", selection: binding(\.automaticTMDBMatchInterval)) {
                    ForEach(AutomaticScanInterval.allCases) { interval in
                        Text(appState.localized(interval.displayName)).tag(interval)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.automaticTMDBMatchInterval.displayName))
            }

            SettingsDescription(text: "立即匹配会补全尚未匹配的电视剧和动漫；自动拉取只处理之后新增且未匹配的内容。")

            SettingsSubsectionHeader(title: "音乐信息", systemImage: "music.note.list")

            SettingsRow(title: "音乐数据源", systemImage: "music.note.list") {
                Picker("音乐数据源", selection: revealBinding(\.musicMetadataProvider)) {
                    ForEach(MusicMetadataProvider.allCases) { provider in
                        Text(appState.localized(provider.displayName)).tag(provider)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.musicMetadataProvider.displayName))
            }

            if appState.settings.musicMetadataProvider.requiresAPIKey {
                SettingsRow(title: "Last.fm API Key", systemImage: "key") {
                    SecureField("Last.fm API Key", text: Binding(get: {
                        appState.settings.lastfmAPIKey ?? ""
                    }, set: { value in
                        appState.settings.lastfmAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                        appState.saveSettings()
                    }))
                    .settingsTextInput(
                        text: appState.settings.lastfmAPIKey ?? "",
                        placeholder: "Last.fm API Key",
                        maxWidth: SettingsControlMetrics.wideControlWidth
                    )
                }
            }

            SettingsDescription(text: "网易云音乐、QQ 音乐和 Deezer 可直接使用；MusicBrainz 会带回公开 genres/tags，iTunes 会带回 primary genre；Last.fm 需要 API Key，可额外拉取曲目 top tags。可在音乐元数据工作台或歌曲详情中补全信息。")

            SettingsRow(title: "音乐匹配宽容度", systemImage: "scope") {
                Picker("音乐匹配宽容度", selection: binding(\.musicMetadataMatchTolerance)) {
                    ForEach(MetadataMatchTolerance.allCases) { mode in
                        Text(appState.localized(mode.displayName)).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.musicMetadataMatchTolerance.displayName))
            }

            SettingsDescription(text: "决定自动补全音乐信息时需要多大把握：\(appState.settings.musicMetadataMatchTolerance.summary)。")

            SettingsRow(title: "音乐增量补充", systemImage: "sparkles") {
                if !appState.musicMetadataFetchProgress.isEmpty {
                    Text(appState.musicMetadataFetchProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("补充缺失信息") {
                    autoStartMusicMetadataConsole = true
                    showingMusicTagSheet = true
                }
                .settingsActionButton(width: 210, prominent: true)
                .disabled(appState.settings.musicMetadataProvider == .disabled || appState.musicTracks.isEmpty)
            }

            SettingsRow(title: "音乐元数据获取", systemImage: "tag") {
                Text("预览、编辑、写回")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    autoStartMusicMetadataConsole = false
                    showingMusicTagSheet = true
                } label: {
                    Label("打开控制台…", systemImage: "tag.circle")
                }
                .settingsActionButton(width: 166, prominent: true)
                .disabled(appState.musicTracks.isEmpty)
            }

            lastfmScrobblingRows
        }
    }

    @ViewBuilder
    private var lastfmScrobblingRows: some View {
        SettingsRow(title: "Last.fm 听歌打卡", systemImage: "waveform.badge.magnifyingglass") {
            Toggle("", isOn: Binding(get: {
                appState.settings.lastfmScrobblingEnabled
            }, set: { value in
                // 带通行证的动画事务：下方 API Key / Secret / 授权行随开关以行插入动画显隐。
                withSettingsRevealAnimation {
                    appState.settings.lastfmScrobblingEnabled = value
                }
                appState.saveSettings()
            }))
            .labelsHidden()
            .toggleStyle(AppSwitchToggleStyle())
        }

        if appState.settings.lastfmScrobblingEnabled {
            SettingsRow(title: "Last.fm API Key", systemImage: "key") {
                SecureField("API Key", text: Binding(get: {
                    appState.settings.lastfmAPIKey ?? ""
                }, set: { value in
                    appState.settings.lastfmAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    appState.saveSettings()
                }))
                .settingsTextInput(text: appState.settings.lastfmAPIKey ?? "", placeholder: "API Key", maxWidth: SettingsControlMetrics.wideControlWidth)
            }

            SettingsRow(title: "Shared Secret", systemImage: "lock") {
                SecureField("Shared Secret", text: Binding(get: {
                    appState.settings.lastfmSharedSecret ?? ""
                }, set: { value in
                    appState.settings.lastfmSharedSecret = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    appState.saveSettings()
                }))
                .settingsTextInput(text: appState.settings.lastfmSharedSecret ?? "", placeholder: "Shared Secret", maxWidth: SettingsControlMetrics.wideControlWidth)
            }

            SettingsRow(title: "账号连接", systemImage: "person.crop.circle") {
                if appState.isLastfmConnected {
                    Text(appState.settings.lastfmUsername.map { "已连接 \($0)" } ?? "已连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        appState.disconnectLastfm()
                    } label: {
                        Label("断开", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    .settingsActionButton(width: 120)
                } else {
                    Button {
                        appState.beginLastfmAuthorization()
                    } label: {
                        Label("授权", systemImage: "safari")
                    }
                    .settingsActionButton(width: 110, prominent: true)
                    .disabled(appState.isLastfmAuthorizing)

                    Button {
                        appState.completeLastfmAuthorization()
                    } label: {
                        Label("完成连接", systemImage: "checkmark.circle")
                    }
                    .settingsActionButton(width: 130)
                    .disabled(appState.isLastfmAuthorizing)
                }
            }

            SettingsDescription(text: "需要在 Last.fm 申请 API 账号获取 API Key 与 Shared Secret。点击「授权」会打开浏览器，确认后回来点「完成连接」。开启后播放本地/在线音乐会自动同步“正在收听”并在听满过半或 4 分钟后打卡。")
        }
    }

    private var subtitleSettings: some View {
        SettingsSection(title: "字幕下载", subtitle: "设置在线字幕来源与首选语言。", systemImage: "captions.bubble") {
            SettingsDescription(text: "播放器会搜索 Podnapisi 和 OpenSubtitles。下载的字幕保存在视频同目录并立即加载。")

            SettingsRow(title: "首选语言", systemImage: "globe") {
                TextField("zh-CN", text: Binding(get: {
                    appState.settings.subtitleLanguage
                }, set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.settings.subtitleLanguage = trimmed.isEmpty ? "zh-CN" : trimmed
                    appState.saveSettings()
                }))
                .settingsTextInput(text: appState.settings.subtitleLanguage, maxWidth: SettingsControlMetrics.compactControlWidth)
            }

            SettingsRow(title: "OpenSubtitles API Key", systemImage: "key") {
                SecureField("可选，opensubtitles.com 注册后免费获取", text: Binding(get: {
                    appState.settings.openSubtitlesAPIKey ?? ""
                }, set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.settings.openSubtitlesAPIKey = trimmed.isEmpty ? nil : trimmed
                    appState.saveSettings()
                }))
                .settingsTextInput(
                    text: appState.settings.openSubtitlesAPIKey ?? "",
                    placeholder: "可选，opensubtitles.com 注册后免费获取",
                    maxWidth: SettingsControlMetrics.wideControlWidth
                )
            }
        }
    }

    private var appearanceSettings: some View {
        SettingsSection(title: "外观与布局", subtitle: "调整界面语言、主题和海报尺寸。", systemImage: "paintbrush.pointed") {
            SettingsRow(title: "界面语言", systemImage: "globe") {
                Picker("界面语言", selection: Binding(get: {
                    appState.settings.appLanguage
                }, set: { language in
                    appState.setAppLanguage(language)
                })) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.appLanguage.displayName)
            }

            SettingsDescription(text: "切换后会在下次启动时完整生效，当前窗口会先更新设置页和提示文案。")

            SettingsRow(title: "主题", systemImage: "circle.lefthalf.filled") {
                Picker("主题", selection: Binding(get: {
                    appState.settings.theme
                }, set: {
                    appState.settings.theme = $0
                    appState.saveSettings()
                })) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(appState.localized(theme.displayName)).tag(theme)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.localized(appState.settings.theme.displayName))
            }

            SettingsRow(title: "海报最小宽度", systemImage: "rectangle.compress.vertical") {
                AppValueSlider(
                    value: binding(\.posterMinWidth),
                    bounds: 130...220,
                    step: 10,
                    accessibilityLabel: "海报最小宽度"
                )
                Text("\(Int(appState.settings.posterMinWidth))")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            SettingsRow(title: "海报最大宽度", systemImage: "rectangle.expand.vertical") {
                AppValueSlider(
                    value: binding(\.posterMaxWidth),
                    bounds: 180...300,
                    step: 10,
                    accessibilityLabel: "海报最大宽度"
                )
                Text("\(Int(appState.settings.posterMaxWidth))")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            SettingsRow(title: "新手引导", systemImage: "sparkles") {
                Button {
                    appState.replayOnboarding()
                } label: {
                    Label("重新查看引导…", systemImage: "play.circle")
                }
                .settingsActionButton(width: 180, prominent: true)
            }
        }
    }

    private var traktSettings: some View {
        SettingsSection(title: "Trakt 同步", subtitle: "同步已看 / 想看，并可从 Trakt 导入差异到冲突队列。", systemImage: "arrow.triangle.2.circlepath.circle") {
            SettingsRow(title: "Client ID", systemImage: "key") {
                SecureField("Client ID", text: Binding(get: {
                    appState.settings.traktClientID ?? ""
                }, set: { value in
                    appState.settings.traktClientID = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    appState.saveSettings()
                }))
                .settingsTextInput(text: appState.settings.traktClientID ?? "", placeholder: "Client ID", maxWidth: SettingsControlMetrics.wideControlWidth)
            }

            SettingsRow(title: "Client Secret", systemImage: "lock") {
                SecureField("Client Secret", text: Binding(get: {
                    appState.settings.traktClientSecret ?? ""
                }, set: { value in
                    appState.settings.traktClientSecret = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    appState.saveSettings()
                }))
                .settingsTextInput(text: appState.settings.traktClientSecret ?? "", placeholder: "Client Secret", maxWidth: SettingsControlMetrics.wideControlWidth)
            }

            SettingsRow(title: "账号连接", systemImage: "person.crop.circle") {
                if appState.isTraktConnected {
                    Text("已连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        appState.disconnectTrakt()
                    } label: {
                        Label("断开", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    .settingsActionButton(width: 120)
                } else {
                    Button {
                        appState.beginTraktConnect()
                    } label: {
                        Label(appState.isTraktConnecting ? "等待授权…" : "连接 Trakt", systemImage: "link")
                    }
                    .settingsActionButton(width: 150, prominent: true)
                    .disabled(appState.isTraktConnecting)
                }
            }

            if appState.isTraktConnected {
                SettingsRow(title: "启用同步", systemImage: "arrow.triangle.2.circlepath") {
                    Toggle("", isOn: Binding(get: {
                        appState.settings.traktSyncEnabled
                    }, set: { value in
                        appState.setTraktSyncEnabled(value)
                    }))
                    .labelsHidden()
                    .toggleStyle(AppSwitchToggleStyle())
                }

                SettingsRow(title: "从 Trakt 导入", systemImage: "tray.and.arrow.down") {
                    Button {
                        appState.importTraktState()
                    } label: {
                        Label(appState.isImportingTraktState ? "正在导入…" : "导入状态", systemImage: "tray.and.arrow.down")
                    }
                    .settingsActionButton(width: 132, prominent: true)
                    .disabled(!appState.settings.traktSyncEnabled || appState.isImportingTraktState)
                }
            }

            SettingsDescription(text: "在 trakt.tv 创建应用获取 Client ID 与 Secret，连接时会打开网页输入验证码。之后你的「已看」和「想看」会在两边保持同步；两边记录有出入时，会先放进同步冲突，由你决定以哪边为准。")
        }
    }

    private var connectorStateSettings: some View {
        SettingsSection(title: "账号与同步状态", subtitle: "查看远程账号、同步冲突和元数据历史。", systemImage: "arrow.triangle.2.circlepath") {
            SettingsRow(title: "远程账号", systemImage: "server.rack") {
                Text("\(appState.remoteConnectorAccounts.count) 个")
                    .foregroundStyle(.secondary)
            }
            SettingsRow(title: "同步冲突", systemImage: "arrow.triangle.branch") {
                Text("\(appState.pendingSyncConflictCount) 个待处理")
                    .foregroundStyle(appState.pendingSyncConflictCount > 0 ? Color.orange : Color.secondary)
                Button {
                    showingSyncConflictQueue = true
                } label: {
                    Label("查看", systemImage: "list.bullet.rectangle")
                }
                .settingsActionButton(width: 92)
                .disabled(appState.pendingSyncConflictCount == 0)
            }
            SettingsRow(title: "元数据历史", systemImage: "clock.arrow.circlepath") {
                Text("\(appState.metadataCorrectionRecordCount) 条可撤销记录")
                    .foregroundStyle(.secondary)
                Button {
                    showingMetadataHistory = true
                } label: {
                    Label("查看", systemImage: "clock.arrow.circlepath")
                }
                .settingsActionButton(width: 92)
                .disabled(appState.metadataCorrectionRecordCount == 0)
            }
            SettingsDescription(text: "在同步冲突里选「采用远端」，会把对方的已看、想看、喜欢和评分记到本机；选「保留本地」则把你这边的记录写回去。所有设备上的播放和评分记录共用同一份。")
        }
    }

    private var advancedOptionsSection: some View {
        SettingsSection(title: "高级选项", subtitle: "显示服务端预览、Trakt、账号同步和数据诊断等进阶设置。", systemImage: "wrench.and.screwdriver") {
            SettingsRow(title: "显示高级选项", systemImage: "slider.horizontal.3") {
                Toggle("", isOn: Binding(get: {
                    showAdvancedOptions
                }, set: { value in
                    withSettingsRevealAnimation {
                        showAdvancedOptions = value
                    }
                }))
                .labelsHidden()
                .toggleStyle(AppSwitchToggleStyle())
            }
            SettingsDescription(text: "这些功能面向进阶用户，或仍在完善中（如服务端预览）。关闭后会从设置里隐藏，不影响已保存的配置。")
        }
    }

    private var advancedSettings: some View {
        SettingsSection(title: "数据、存储与诊断", subtitle: "管理备份、存储位置、清理和性能记录。", systemImage: "externaldrive") {
            SettingsToggleRow(title: "性能记录", systemImage: "gauge.with.dots.needle.67percent", isOn: binding(\.debugLoggingEnabled))
            SettingsRow(title: "已忽略健康项", systemImage: "eye.slash") {
                Text("\(appState.settings.ignoredHealthIssueIDs.count) 项")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(appState.settings.ignoredHealthIssueIDs.isEmpty ? .secondary : AppColors.selectedGlassTint)
                Button {
                    appState.clearIgnoredHealthIssues()
                } label: {
                    Label("恢复显示", systemImage: "arrow.uturn.backward")
                }
                .settingsActionButton(width: 122, prominent: !appState.settings.ignoredHealthIssueIDs.isEmpty)
                .disabled(appState.settings.ignoredHealthIssueIDs.isEmpty)
            }
            SettingsDescription(text: "在仪表盘中点「忽略」的健康检查会永久隐藏；恢复后会重新参与统计和展示。")
            if let directories = appState.directories {
                SettingsRow(title: "数据库版本", systemImage: "number.square") {
                    Text("Schema v\(appState.databaseSchemaVersion)")
                        .foregroundStyle(.secondary)
                }
                SettingsRow(title: "数据库备份", systemImage: "externaldrive") {
                    Button {
                        appState.createDatabaseBackup()
                    } label: {
                        Label("立即备份", systemImage: "square.and.arrow.down")
                    }
                    .settingsActionButton(width: 126, prominent: true)

                    Button {
                        restoreDatabase()
                    } label: {
                        Label("从备份恢复…", systemImage: "arrow.counterclockwise")
                    }
                    .settingsActionButton(width: 142)

                    Button {
                        NSWorkspace.shared.open(directories.databaseBackups)
                    } label: {
                        Label("打开位置", systemImage: "folder")
                    }
                    .settingsActionButton(width: 116)
                }
                SettingsDescription(text: "备份包含 MediaLIB 的索引与使用记录，不包含媒体文件。升级和恢复前会自动创建安全备份。")
                SettingsRow(title: "数据库位置", systemImage: "cylinder.split.1x2") {
                    SettingsPathText(text: directories.database.path)
                }
                SettingsRow(title: "备份位置", systemImage: "folder.badge.gearshape") {
                    SettingsPathText(text: directories.databaseBackups.path)
                }
                SettingsRow(title: "缓存位置", systemImage: "externaldrive.connected.to.line.below") {
                    SettingsPathText(text: directories.cache.path)
                }
                SettingsRow(title: "空间整理", systemImage: "sparkles") {
                    Button {
                        appState.runOneClickCleanup()
                    } label: {
                        Label("一键清理", systemImage: "sparkles")
                    }
                    .settingsActionButton(width: 126, prominent: true)
                }
                SettingsDescription(text: "清理不再使用的缓存和过旧的任务记录，给磁盘腾点空间；你的媒体文件不会被删除、移动或改名。")
            }
        }
    }

    private var serverModeSettings: some View {
        SettingsSection(title: "服务端", subtitle: "启动 MediaLIB Web 服务；网页负责播放解码，桌面客户端只提供 Mlink 来源目录。", systemImage: "server.rack") {
            SettingsRow(title: "服务模式", systemImage: "power") {
                Toggle("服务模式", isOn: Binding(get: {
                    appState.serverModeConfiguration.isEnabled
                }, set: { enabled in
                    appState.setServerModeEnabled(enabled)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsRow(title: "局域网访问", systemImage: "network") {
                Toggle("局域网访问", isOn: Binding(get: {
                    appState.serverModeConfiguration.networkAccessMode == .lanHTTPS
                }, set: { enabled in
                    appState.setServerLANAccessEnabled(enabled)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!isBuiltInLANHTTPSAvailable)
                if !isBuiltInLANHTTPSAvailable {
                    Text("需要 macOS 14 或更高版本")
                        .font(.caption)
                        .foregroundStyle(AppColors.warning)
                }
            }

            SettingsRow(title: "轻量服务模式", systemImage: "leaf") {
                Toggle("轻量服务模式", isOn: Binding(get: {
                    appState.serverModeConfiguration.isLightweightMode
                }, set: { enabled in
                    appState.setServerLightweightModeEnabled(enabled)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!appState.serverModeConfiguration.isEnabled)
            }

            SettingsRow(title: "当前状态", systemImage: "circle.fill") {
                Text(appState.serverModeStatusDisplayTitle)
                    .foregroundStyle(serverModeStatusColor)
                if case .failed(let message) = appState.serverModeStatus {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            SettingsRow(title: "管理员账号", systemImage: "person.badge.key") {
                Text(serverAdministratorStatusText)
                    .font(.callout)
                    .foregroundStyle(
                        appState.serverAdministrationStore.requiresInitialPassword
                            ? AppColors.warning
                            : AppColors.success
                    )
                if appState.serverAdministrationStore.requiresInitialPassword {
                    Button("设置密码…") {
                        appState.serverAdministrationStore.clearError()
                        showingServerPasswordSetup = true
                    }
                    .settingsActionButton(prominent: true)
                    .disabled(!appState.serverAdministrationStore.isAvailable)
                } else {
                    Button("修改密码…") {
                        appState.serverAdministrationStore.clearError()
                        showingServerPasswordChange = true
                    }
                    .settingsActionButton()
                    .disabled(!appState.serverAdministrationStore.isAvailable)
                    Button("忘记密码…") {
                        appState.serverAdministrationStore.clearError()
                        showingServerPasswordRecovery = true
                    }
                    .settingsActionButton()
                    .disabled(!appState.serverAdministrationStore.isAvailable)
                }
            }

            if !appState.serverAdministrationStore.requiresInitialPassword {
                SettingsRow(title: "用户与权限", systemImage: "person.2.badge.gearshape") {
                    Text("\(appState.serverAdministrationStore.userCount) 个用户 · 按媒体库最小授权")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("管理…") {
                        showingServerUserManagement = true
                    }
                    .settingsActionButton()
                }

                SettingsRow(title: "设备与会话", systemImage: "laptopcomputer.and.iphone") {
                    Text("\(appState.serverAdministrationStore.activeDeviceCount) 台设备 · \(appState.serverAdministrationStore.activeSessionCount) 个会话")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("管理…") {
                        showingServerSessionManagement = true
                    }
                    .settingsActionButton()
                }
            }

            SettingsRow(title: "服务器名称", systemImage: "pencil.line") {
                TextField("MediaLIB Server", text: $serverModeNameDraft)
                .onSubmit {
                    appState.updateServerModeServerName(serverModeNameDraft)
                    serverModeNameDraft = appState.serverModeConfiguration.serverName
                }
                .settingsTextInput(
                    text: serverModeNameDraft,
                    maxWidth: SettingsControlMetrics.compactControlWidth
                )
            }

            SettingsRow(title: "本机端口", systemImage: "number") {
                TextField("8098", text: $serverModePortDraft)
                    .onSubmit {
                        let port = Int(serverModePortDraft) ?? ServerModeConfiguration.defaultPort
                        appState.updateServerModePort(port)
                        serverModePortDraft = String(appState.serverModeConfiguration.port)
                    }
                    .settingsTextInput(
                        text: serverModePortDraft,
                        maxWidth: SettingsControlMetrics.compactControlWidth
                    )
            }

            SettingsRow(
                title: appState.serverModeConfiguration.networkAccessMode == .lanHTTPS
                    ? "局域网地址"
                    : "本机地址",
                systemImage: "link"
            ) {
                Text(appState.serverModeEndpointDisplayText)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("打开 Web") {
                    NSWorkspace.shared.open(appState.serverModeConfiguration.effectiveBaseURL)
                }
                .settingsActionButton()
                .disabled(
                    appState.serverModeStatus != .running ||
                        appState.serverAdministrationStore.requiresInitialPassword
                )
                Button("复制地址") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        appState.serverModeEndpointDisplayText,
                        forType: .string
                    )
                }
                .settingsActionButton()
            }

            if appState.serverModeConfiguration.networkAccessMode == .lanHTTPS {
                SettingsRow(title: "设备信任证书", systemImage: "checkmark.shield") {
                    Text("其他设备首次访问前需要安装一次")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("导出证书…") {
                        exportServerCertificateAuthority()
                    }
                    .settingsActionButton(width: 116, prominent: true)
                    .disabled(appState.serverModeStatus != .running)
                }
                SettingsDescription(
                    text: "把导出的 MediaLIB-LAN-CA.cer 发送到同一局域网内的手机、平板或电脑并设为信任，然后使用上方 https 地址访问。证书只用于验证这台 MediaLIB 服务器，不包含管理员密码或媒体信息。"
                )
            } else {
                SettingsRow(title: "公开 HTTPS 地址", systemImage: "lock.shield") {
                    TextField("https://media.example.com", text: $serverModePublicOriginDraft)
                        .onSubmit {
                            appState.updateServerModePublicOrigin(serverModePublicOriginDraft)
                            serverModePublicOriginDraft = appState.serverModeConfiguration.publicOrigin ?? ""
                        }
                        .settingsTextInput(
                            text: serverModePublicOriginDraft,
                            maxWidth: SettingsControlMetrics.wideControlWidth
                        )
                }

                SettingsRow(title: "受信代理地址", systemImage: "arrow.triangle.branch") {
                    TextField("127.0.0.1", text: $serverModeTrustedProxiesDraft)
                        .onSubmit {
                            appState.updateServerModeTrustedProxyAddresses(serverModeTrustedProxiesDraft)
                            serverModeTrustedProxiesDraft = appState.serverModeConfiguration.trustedProxyAddresses.joined(separator: ", ")
                        }
                        .settingsTextInput(
                            text: serverModeTrustedProxiesDraft,
                            maxWidth: SettingsControlMetrics.wideControlWidth
                        )
                }
            }

            SettingsDescription(text: "轻量服务模式会停止桌面端封面/横版图等非必要视觉预热，并将服务子进程设为 utility QoS；扫描、索引、认证和媒体分发不会被关闭。名称、端口、局域网访问或轻量策略在服务运行时会安全重启。默认仅监听 127.0.0.1；开启局域网访问后会自动选取当前 Wi-Fi/有线私有 IPv4，并使用内建 HTTPS，绝不开放明文 HTTP。网页仍由浏览器通过受权 Range 媒体源原生解码，服务端不会启动网页转码。服务器身份与本机 CA 会持久化保存。")
        }
    }

    private var isBuiltInLANHTTPSAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    private func exportServerCertificateAuthority() {
        guard let source = appState.serverModeCertificateAuthorityURL else {
            appState.showFloatingNotice(
                title: "证书尚未生成",
                message: "请先启动局域网服务，待状态显示运行中后再导出。",
                kind: .warning
            )
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 MediaLIB 局域网信任证书"
        panel.message = "把证书安装并信任到需要访问 MediaLIB 的每台局域网设备。"
        panel.nameFieldStringValue = "MediaLIB-LAN-CA.cer"
        panel.allowedContentTypes = [UTType(filenameExtension: "cer") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try ServerModeCertificateSupport.exportCertificate(from: source, to: destination)
            appState.showFloatingNotice(
                title: "证书已导出",
                message: "请在每台访问设备上安装并设为信任，然后打开 \(appState.serverModeEndpointDisplayText)。",
                kind: .success
            )
        } catch {
            appState.showFloatingNotice(
                title: "证书导出失败",
                message: error.localizedDescription,
                kind: .error
            )
        }
    }

    private var serverAdministratorStatusText: String {
        let store = appState.serverAdministrationStore
        if !store.isAvailable { return "身份数据库不可用" }
        if store.isLoading && store.snapshot == nil { return "正在检查…" }
        return store.requiresInitialPassword ? "需要首次设置" : "admin 已保护"
    }

    /// 可授权的媒体源，**包含保险库**。
    ///
    /// 这里从前把 `.privateCollection` 过滤掉了，于是"给某个成员开放保险库"在界面
    /// 上根本不存在——不是权限不足，是那一行压根画不出来。保险库仍然是一个需要
    /// 明确勾选的授权，而且网页侧还要求这台机器上的 App 正解锁着，两个条件缺一
    /// 不可；把它排除在授权列表之外并不能提供这层保护，只是让它无法被管理。
    private var serverLibraryOptions: [ServerLibraryOption] {
        appState.sources
            .map {
                ServerLibraryOption(
                    id: $0.id,
                    name: $0.mediaType == .privateCollection
                        ? "\($0.name)（\(appState.settings.privacyVaultName)）"
                        : $0.name,
                    mediaType: $0.mediaType
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var serverModeStatusColor: Color {
        switch appState.serverModeStatus {
        case .running:
            return .green
        case .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private var aboutSettings: some View {
        SettingsSection(title: "关于软件", subtitle: "查看项目地址、作者和联系方式。", systemImage: "info.circle") {
            SettingsRow(title: "MediaLIB", systemImage: "app.badge") {
                Button {
                    showingAboutSoftware = true
                } label: {
                    Label("查看关于…", systemImage: "info.circle")
                }
                .settingsActionButton(width: 142, prominent: true)
            }

            SettingsRow(title: "软件更新", systemImage: "arrow.down.circle") {
                Text("当前版本 \(AppVersion.displayString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    appState.checkForUpdates(manual: true)
                } label: {
                    if appState.isCheckingForUpdates {
                        Label("检查中…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("检查更新", systemImage: "arrow.down.circle")
                    }
                }
                .settingsActionButton(width: 142)
                .disabled(appState.isCheckingForUpdates)
            }

            if appState.settings.updateSkippedVersion != nil {
                SettingsRow(title: "更新提醒", systemImage: "bell.badge") {
                    Button {
                        appState.settings.updateSkippedVersion = nil
                        appState.saveSettings()
                    } label: {
                        Label("恢复自动提醒", systemImage: "bell")
                    }
                    .settingsActionButton(width: 142)
                }
            }
        }
    }

    private var privacySettings: some View {
        SettingsSection(title: "保险库", subtitle: "管理私密内容的解锁方式。", systemImage: "lock.shield") {
            PrivacySettingsPanel()
        }
    }

    private func registerAsSystemDefault(forMusic: Bool) {
        guard SystemDefaultPlayerRegistrar.runningFromAppBundle else {
            appState.alert = AppAlert(
                title: "无法设置默认播放器",
                message: "请使用安装到「应用程序」的 MediaLIB.app 进行此操作。"
            )
            return
        }
        let extensions = forMusic
            ? SystemDefaultPlayerRegistrar.musicExtensions
            : SystemDefaultPlayerRegistrar.videoExtensions
        Task { @MainActor in
            let result = await SystemDefaultPlayerRegistrar.register(extensions: extensions)
            let kind = forMusic ? "音乐" : "视频"
            if result.succeeded > 0 {
                appState.alert = AppAlert(
                    title: "已设为默认\(kind)播放器",
                    message: "已接管 \(result.succeeded) 种常见\(kind)格式" + (result.failed > 0 ? "，另有 \(result.failed) 种格式未能设置（可能被系统保留）。" : "。现在在访达中双击这些文件会用 MediaLIB 打开。")
                )
            } else {
                appState.alert = AppAlert(
                    title: "设置默认\(kind)播放器失败",
                    message: "没有格式注册成功，请确认 MediaLIB.app 位于「应用程序」文件夹并重试。"
                )
            }
        }
    }

    private func chooseExternalPlayer(forMusic: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        panel.message = "请选择 IINA、VLC、Movist Pro 等 .app 播放器。"
        if panel.runModal() == .OK, let url = panel.url {
            appState.chooseExternalPlayer(url: url, forMusic: forMusic)
        }
    }

    private func chooseVideoCacheDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = appState.settings.videoCacheDirectoryPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? appState.directories?.cache
        panel.prompt = "选择"
        panel.message = "请选择离线视频缓存的保存位置。MediaLIB 会在其中创建 VideoCache 子目录。"
        if panel.runModal() == .OK, let url = panel.url {
            appState.chooseVideoCacheDirectory(url: url)
        }
    }

    private func restoreDatabase() {
        guard let backupDirectory = appState.directories?.databaseBackups else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.directoryURL = backupDirectory
        panel.prompt = "选择备份"
        panel.message = "恢复会替换 MediaLIB 内部索引、播放记录、喜欢、想看、视频集合、歌单和队列，不会修改媒体文件。"
        guard panel.runModal() == .OK, let backupURL = panel.url else { return }

        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "确认恢复数据库？"
        confirmation.informativeText = "当前数据库会先自动备份，然后从 \(backupURL.lastPathComponent) 恢复。正在播放的媒体和扫描任务会停止，用户媒体文件不会被修改。"
        confirmation.addButton(withTitle: "恢复")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        appState.restoreDatabase(from: backupURL)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding {
            appState.settings[keyPath: keyPath]
        } set: { newValue in
            appState.settings[keyPath: keyPath] = newValue
            appState.saveSettings()
        }
    }

    /// 会驱动条件子行显隐的设置写入：带通行证动画事务，联动行以行插入/移除动画出现。
    private func revealBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding {
            appState.settings[keyPath: keyPath]
        } set: { newValue in
            withSettingsRevealAnimation {
                appState.settings[keyPath: keyPath] = newValue
            }
            appState.saveSettings()
        }
    }

    /// 自定义配色颜色井：读 hex（或回退）→ Color，写时转 hex 并应用。
    private func customThemeBinding(
        _ keyPath: KeyPath<AppSettings, String?>,
        fallback: String,
        apply: @escaping (String) -> Void
    ) -> Binding<Color> {
        Binding(
            get: {
                let hex = appState.settings[keyPath: keyPath] ?? fallback
                return Color(nsColor: NSColor(appThemeHex: hex) ?? NSColor(appThemeHex: fallback) ?? NSColor(calibratedRed: 0.184, green: 0.490, blue: 0.882, alpha: 1))
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.deviceRGB) ?? NSColor(newColor)
                apply(ns.appThemeHexString)
            }
        )
    }

}

private struct AboutMediaLIBSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let githubURL = URL(string: "https://github.com/Again0521/MediaLib")!
    private let emailURL = URL(string: "mailto:zonn.l@foxmail.com")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sheetContent) {
            HStack(alignment: .center, spacing: 16) {
                AboutAppLogoView()
                    .frame(width: 78, height: 78, alignment: .center)

                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.localized("关于 MediaLIB"))
                        .font(.title3.weight(.semibold))
                    Text(appState.localized("MediaLIB 是一款面向 macOS 的个人影音媒体库应用，帮助你整理、播放和管理本地、Emby 与网络来源的视频和音乐收藏。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                AboutInfoRow(title: "GitHub", systemImage: "link") {
                    Link("Again0521/MediaLib", destination: githubURL)
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.selectedGlassTint)
                }
                AboutInfoRow(title: appState.localized("作者"), systemImage: "person.crop.circle") {
                    Text("ZonnL")
                }
                AboutInfoRow(title: "QQ群", systemImage: "bubble.left.and.bubble.right") {
                    Text("977808370")
                }
                AboutInfoRow(title: "Email", systemImage: "envelope") {
                    Link("zonn.l@foxmail.com", destination: emailURL)
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.selectedGlassTint)
                }
                AboutInfoRow(title: appState.localized("投喂作者"), systemImage: "heart") {
                    Link(appState.localized("请作者喝杯咖啡"), destination: appState.sponsorURL)
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.selectedGlassTint)
                }
            }
            .padding(14)
            .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 0.94)

            AppSheetActionFooter {
                Button {
                    dismiss()
                } label: {
                    Label(appState.localized("关闭"), systemImage: "xmark")
                }
                .settingsActionButton(width: 104, prominent: true)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.compactWidth)
    }
}

private struct AboutAppLogoView: View {
    private static let logo: NSImage? = {
        // 直接用运行中 App 的图标：零文件访问、不触发任何权限弹窗，也最快。
        // 旧实现走 Bundle.module，会在可执行文件同级目录（开发/解包时可能位于
        // ~/Documents 下）探测 *.bundle，从而弹出「请求访问文稿」的系统授权框。
        let appIcon = NSApplication.shared.applicationIconImage
        if let appIcon, appIcon.size.width > 1 {
            return appIcon
        }
        // 退回到 App 自身 Resources（不探测同级 bundle）。
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()

    var body: some View {
        Group {
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
            } else {
                PlayfulSymbolIcon(systemImage: "play.rectangle.on.rectangle", size: 62)
            }
        }
        .frame(width: 74, height: 74, alignment: .center)
    }
}

private struct AboutInfoRow<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28, alignment: .center)

            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)

            content
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 38, alignment: .center)
    }
}

struct SettingsSection<Content: View>: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.settingsSectionHeaderToCard) {
            HStack(spacing: 14) {
                SettingsBlueSectionIcon(systemImage: systemImage)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.localized(title))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                    Text(appState.localized(subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 0.94)
            .padding(.leading, AppSpacing.settingsSectionContentLeading)
        }
        .padding(.leading, AppSpacing.settingsSectionOuterLeading)
    }
}

private struct SettingsBlueSectionIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppColors.refIconChipBg.opacity(colorScheme == .dark ? 0.58 : 1))
            .overlay {
                AppGlyph(systemImage: systemImage, size: 24, lineWidth: 2.35)
                    .foregroundStyle(AppColors.refIconGlyph)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppColors.refIconGlyph.opacity(colorScheme == .dark ? 0.18 : 0.14), lineWidth: 0.8)
            }
            .shadow(color: AppColors.referenceBlue.opacity(colorScheme == .dark ? 0.08 : 0.10), radius: 8, x: 0, y: 4)
        .frame(width: 54, height: 54)
    }
}

struct SettingsSubsectionHeader: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            AppGlyph(systemImage: systemImage, size: 14, lineWidth: 2)
                .foregroundStyle(AppColors.refSubtle)
                .frame(width: 14)

            Text(appState.localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HomeTabSettingsGrid: View {
    @EnvironmentObject private var appState: AppState

    private let columns = [GridItem(.adaptive(minimum: 154), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(visibleTabs) { tab in
                HomeTabSettingsTile(
                    tab: tab,
                    isEnabled: isEnabled(tab),
                    action: { toggle(tab) }
                )
            }
        }
    }

    private var visibleTabs: [HomeTab] {
        HomeTab.allCases.filter { appState.availableHomeTabs.contains($0) }
    }

    private func isEnabled(_ tab: HomeTab) -> Bool {
        appState.settings.enabledHomeTabs.contains(tab)
    }

    private func toggle(_ tab: HomeTab) {
        var tabs = appState.settings.enabledHomeTabs
        if tabs.contains(tab) {
            guard tabs.count > 1 else { return }
            tabs.removeAll { $0 == tab }
        } else {
            tabs.append(tab)
        }
        appState.settings.enabledHomeTabs = tabs
        appState.saveSettings()
    }
}

private struct HomeTabSettingsTile: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: HomeTab
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let active = isEnabled || isHovering
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                AppGlyph(systemImage: tab.systemImage, size: 19, lineWidth: 2.1)
                    .foregroundStyle(AppColors.textPrimary.opacity(active ? 0.96 : 0.84))
                    .frame(width: 22, height: 22)

                Text(appState.localized(tab.displayName))
                    .lineLimit(1)
                    .foregroundStyle(AppColors.textPrimary)

                Spacer()

                ZStack {
                    Circle()
                        .fill(isEnabled ? AppColors.referenceBlue : Color.clear)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isEnabled ? AppColors.referenceBlue.opacity(0.90) : AppColors.border.opacity(colorScheme == .dark ? 0.40 : 0.62),
                                    lineWidth: 1.2
                                )
                        }
                    if isEnabled {
                        AppGlyph(systemImage: "checkmark", size: 10.5, lineWidth: 2.4)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .font(.callout.weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                shape.fill(
                    isEnabled
                        ? AppColors.referenceBlue.opacity(colorScheme == .dark ? 0.18 : 0.075)
                        : (colorScheme == .dark ? AppColors.refCardBg.opacity(0.86) : Color.white.opacity(0.92))
                )
            }
            .overlay {
                shape.strokeBorder(
                    isEnabled
                        ? AppColors.referenceBlue.opacity(colorScheme == .dark ? 0.34 : 0.24)
                        : AppColors.border.opacity(colorScheme == .dark ? 0.28 : 0.38),
                    lineWidth: 1
                )
            }
            .brightness(isHovering ? 0.008 : 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : AppMotion.listHover, value: isHovering)
        .help(appState.localized(tab.displayName))
    }
}

private struct ArtworkFallbackModeCapsules: View {
    @Binding var selection: ArtworkFallbackMode

    var body: some View {
        HStack(spacing: 7) {
            ForEach(ArtworkFallbackMode.allCases) { mode in
                Button {
                    withAnimation(AppMotion.fast) {
                        selection = mode
                    }
                } label: {
                    GlassCapsuleControl(isSelected: selection == mode, height: 30, horizontalPadding: 10, enablePointerEdge: false) {
                        Text(mode.displayName)
                    }
                }
                .buttonStyle(.plain)
                .help(mode.displayName)
            }
        }
        .padding(5)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 0.92)
    }
}

/// 「配色」选择器：把纯文字下拉升级为带色板小样的网格，每项展示该预设的底色·光线·高亮三段锚点，
/// 点选即时换肤（沿用 setThemePreset 的发布 + 防抖落盘），所见即所得。
private struct ThemePaletteSwatchGrid: View {
    @EnvironmentObject private var appState: AppState
    private let columns = [GridItem(.adaptive(minimum: 164), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(AppThemePreset.allCases) { preset in
                ThemePaletteSwatchTile(
                    preset: preset,
                    isSelected: appState.settings.themePreset == preset,
                    action: {
                        guard appState.settings.themePreset != preset else { return }
                        appState.setThemePreset(preset)
                    }
                )
            }
        }
    }
}

private struct ThemePaletteSwatchTile: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preset: AppThemePreset
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let active = isSelected || isHovering
        let anchors = paletteAnchors
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    palettePreview(anchors)

                    Spacer(minLength: 4)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? AppColors.selectedGlassTint.opacity(0.95) : Color.secondary.opacity(0.38))
                        .padding(5)
                        .background(
                            Circle()
                                .fill(isSelected ? AppColors.selectedGlassTint.opacity(0.10) : Color.primary.opacity(0.025))
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.localized(preset.displayName))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(appState.localized(preset.paletteDescription))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .staticSurfaceBackground(selected: isSelected, cornerRadius: 12, thickness: 0.94)
            .repeatedSurfaceHover(isHovering, cornerRadius: 12, intensity: active ? 0.74 : 0.62)
            .brightness(isHovering ? 0.006 : 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : AppMotion.listHover, value: isHovering)
        .animation(reduceMotion ? nil : AppMotion.standard, value: isSelected)
        .help("\(appState.localized(preset.displayName)) · \(appState.localized(preset.paletteDescription))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appState.localized(preset.displayName))
        .accessibilityValue(appState.localized(preset.paletteDescription))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func palettePreview(_ anchors: (base: Color, light: Color, highlight: Color)) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            shape.fill(anchors.base)

            Circle()
                .fill(anchors.light.opacity(colorScheme == .dark ? 0.78 : 0.92))
                .frame(width: 38, height: 38)
                .blur(radius: 2.5)
                .offset(x: -9, y: -8)

            Capsule()
                .fill(anchors.highlight)
                .frame(width: 27, height: 9)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.28 : 0.62), lineWidth: 0.7)
                )
                .shadow(color: anchors.highlight.opacity(0.22), radius: 4, y: 2)
                .offset(x: 11, y: 8)
        }
        .frame(width: 58, height: 34)
        .clipShape(shape)
        .overlay(shape.strokeBorder(AppColors.subtleBorder, lineWidth: 0.8))
    }

    private var paletteAnchors: (base: Color, light: Color, highlight: Color) {
        let isDark = colorScheme == .dark
        let seed = isDark ? preset.darkSeedHex : preset.seedHex
        if preset.isCustom {
            return (
                themeColor(appState.settings.themeBaseHex ?? seed.base),
                themeColor(appState.settings.themeLightHex ?? seed.light),
                themeColor(appState.settings.themeHighlightHex ?? seed.highlight)
            )
        }
        return (themeColor(seed.base), themeColor(seed.light), themeColor(seed.highlight))
    }

    private func themeColor(_ hex: String) -> Color {
        Color(nsColor: NSColor(appThemeHex: hex) ?? NSColor.gray)
    }
}

struct PrivacySettingsPanel: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin = ""
    @State private var confirmPIN = ""
    @State private var unlockPIN = ""

    var body: some View {
        SettingsDescription(text: "锁定时隐藏保险库内容。解锁后，播放记录会出现在“正在观看”或“已观看”，并可随时清除。")

        SettingsRow(title: "保险库名称", systemImage: "pencil.line") {
            TextField("保险库", text: Binding(get: {
                appState.settings.privacyVaultName
            }, set: { value in
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                appState.settings.privacyVaultName = cleaned.isEmpty ? "保险库" : cleaned
                appState.saveSettings()
            }))
            .settingsTextInput(text: appState.settings.privacyVaultName, maxWidth: 180)
        }

        SettingsRow(title: "当前状态", systemImage: appState.privacyPINConfigured ? "lock.fill" : "lock.open") {
            Text(appState.privacyPINConfigured ? (appState.privacyUnlocked ? "已解锁" : "已上锁") : "未设置密码")
                .foregroundStyle(appState.privacyPINConfigured ? Color.secondary : Color.orange)
        }

        if appState.privacyPINConfigured && !appState.privacyUnlocked {
            lockedControls
        } else {
            editablePINControls
        }

        SettingsRow(title: "Touch ID", systemImage: "touchid") {
            Text(appState.privacyBiometricsAvailable ? "可用于解锁" : "当前设备不可用")
                .foregroundStyle(.secondary)
        }
    }

    private var lockedControls: some View {
        Group {
            SettingsRow(title: "解锁密码", systemImage: "number", contentSpacing: 5) {
                SecureField("4-8 位数字", text: $unlockPIN)
                    .settingsTextInput(text: unlockPIN, placeholder: "4-8 位数字", minWidth: 128, maxWidth: 150)
                    .onChange(of: unlockPIN) { newValue in
                        unlockPIN = String(newValue.filter(\.isNumber).prefix(8))
                    }
                    .onSubmit(unlock)

                Button("解锁") {
                    unlock()
                }
                .settingsActionButton(width: 74, prominent: true)
                .disabled(!PrivacyLockService.isValidPIN(unlockPIN))

                if appState.privacyBiometricsAvailable {
                    Button {
                        appState.unlockPrivacyWithBiometrics()
                    } label: {
                        Label("Touch ID", systemImage: "touchid")
                    }
                    .settingsActionButton(width: 106)
                }
            }

            SettingsDescription(text: "解锁保险库后可更改或移除密码。")
        }
    }

    private var editablePINControls: some View {
        Group {
            SettingsRow(title: appState.privacyPINConfigured ? "新密码" : "设置密码", systemImage: "number") {
                SecureField("4-8 位数字", text: $pin)
                    .settingsTextInput(text: pin, maxWidth: 180)
                    .onChange(of: pin) { newValue in
                        pin = String(newValue.filter(\.isNumber).prefix(8))
                    }
            }

            SettingsRow(title: "确认密码", systemImage: "checkmark.seal") {
                SecureField("再次输入", text: $confirmPIN)
                    .settingsTextInput(text: confirmPIN, maxWidth: 180)
                    .onChange(of: confirmPIN) { newValue in
                        confirmPIN = String(newValue.filter(\.isNumber).prefix(8))
                    }
            }

            SettingsRow(title: "密码操作", systemImage: "key") {
                Button(appState.privacyPINConfigured ? "更新密码" : "设置密码") {
                    savePIN()
                }
                .settingsActionButton(width: 96, prominent: true)
                .disabled(!canSavePIN)

                if appState.privacyPINConfigured {
                    Button("立即锁定") {
                        appState.lockPrivacy()
                        pin = ""
                        confirmPIN = ""
                    }
                    .settingsActionButton(width: 96)

                    Button("移除密码", role: .destructive) {
                        Task { @MainActor in
                            await appState.removePrivacyPINAsync()
                            pin = ""
                            confirmPIN = ""
                        }
                    }
                    .settingsActionButton(width: 96)
                }
            }
        }
    }

    private var canSavePIN: Bool {
        PrivacyLockService.isValidPIN(pin) && pin == confirmPIN
    }

    private func unlock() {
        let submittedPIN = unlockPIN
        Task { @MainActor in
            if await appState.verifyPrivacyPINAsync(submittedPIN) {
                unlockPIN = ""
            }
        }
    }

    private func savePIN() {
        guard canSavePIN else {
            appState.alert = AppAlert(title: "密码无效", message: "请输入一致的 4 到 8 位数字密码。")
            return
        }
        let submittedPIN = pin
        Task { @MainActor in
            if await appState.setPrivacyPINAsync(submittedPIN) {
                pin = ""
                confirmPIN = ""
            }
        }
    }
}

struct SettingsHeader: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        PageHeader(
            title: appState.localized("设置"),
            subtitle: appState.localized("调整播放、媒体库、界面与隐私设置。"),
            systemImage: "gearshape"
        )
    }
}

struct SettingsRow<Content: View>: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let systemImage: String
    let contentSpacing: CGFloat
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        contentSpacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.contentSpacing = contentSpacing
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                rowLabel

                HStack(spacing: contentSpacing) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 10) {
                rowLabel

                HStack(spacing: contentSpacing) {
                    Spacer(minLength: 0)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(minHeight: AppControlMetrics.settingsRowHeight)
    }

    private var rowLabel: some View {
        HStack(spacing: 14) {
            // 系统页面 1:1：设置行图标统一为浅蓝芯片(#E7F0FD) + 蓝色线条(#2E90FA)。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.refIconChipBg)
                .frame(width: 34, height: 34)
                .overlay {
                    AppGlyph(systemImage: systemImage, size: 17, lineWidth: 2)
                        .foregroundStyle(AppColors.refIconGlyph)
                }

            Text(appState.localized(title))
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .frame(width: 148, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private extension View {
    @ViewBuilder
    func settingsTextInput(
        text: String = "",
        placeholder: String = "",
        minWidth: CGFloat = 92,
        maxWidth: CGFloat = 340
    ) -> some View {
        let width = settingsElasticInputWidth(
            for: text,
            placeholder: placeholder,
            minWidth: minWidth,
            maxWidth: maxWidth
        )
        let field = self
            .glassFormField()
            .multilineTextAlignment(.center)

        field.frame(width: width, alignment: .trailing)
    }

    func settingsMenuControl(selectedTitle: String) -> some View {
        adaptiveMenuControl(
            selectedTitle: selectedTitle,
            minWidth: 76,
            maxWidth: 260
        )
    }

    @ViewBuilder
    func settingsActionButton(
        width: CGFloat? = nil,
        prominent: Bool = false
    ) -> some View {
        // 系统页面 1:1：设置按钮统一为白描边(高亮则蓝渐变)、固定高 34、随文字自适应宽度、纯文字无图标
        // (参考页设置按钮均无图标)，同类按钮共享同一套设计语言。`width` 参数保留兼容但不再强制定宽。
        labelStyle(.titleOnly)
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 14, minHeight: 34, prominent: prominent, outlined: !prominent))
            .fixedSize(horizontal: true, vertical: false)
    }
}

private func settingsPlaybackRateTitle(_ rate: Double) -> String {
    switch rate {
    case 1: return "1.00x"
    case 1.5, 2: return String(format: "%.2fx", rate)
    default: return String(format: "%.2fx", rate)
    }
}

private func settingsVideoCacheLimitOptions(current: Double) -> [Double] {
    let presets: [Double] = [0, 20, 50, 100, 200, 500]
    let normalizedCurrent = max(0, current)
    if presets.contains(normalizedCurrent) {
        return presets
    }
    return (presets + [normalizedCurrent]).sorted()
}

private func settingsVideoCacheLimitTitle(_ value: Double) -> String {
    guard value > 0 else { return "不限制" }
    let rounded = value.rounded()
    if abs(value - rounded) < 0.01 {
        return "\(Int(rounded)) GB"
    }
    return String(format: "%.1f GB", value)
}

private func settingsElasticInputWidth(for text: String, placeholder: String, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
    let measuredText = [text, placeholder]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .max { lhs, rhs in weightedTextLength(lhs) < weightedTextLength(rhs) } ?? ""
    let weightedCharacters = weightedTextLength(measuredText)
    let contentWidth = max(weightedCharacters, 4) * 8.4 + 38
    return min(max(contentWidth, minWidth), maxWidth)
}

private func weightedTextLength(_ text: String) -> CGFloat {
    text.reduce(CGFloat(0)) { partial, character in
        partial + (character.unicodeScalars.contains { $0.value > 0x2E80 } ? 1.55 : 1.0)
    }
}

struct SettingsToggleRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImage: String
    var isOn: Binding<Bool>

    var body: some View {
        SettingsRow(title: title, systemImage: systemImage) {
            // 开关写入带通行证的动画事务：均衡器、封面发光等随开关显隐的子设置行
            // 以 List 行插入/移除动画出现（穿过设置 List 的隐式动画闸）；Reduce Motion 保持瞬时。
            Toggle("", isOn: Binding(get: { isOn.wrappedValue }, set: { value in
                if reduceMotion {
                    isOn.wrappedValue = value
                } else {
                    withSettingsRevealAnimation { isOn.wrappedValue = value }
                }
            }))
                .labelsHidden()
                .toggleStyle(AppSwitchToggleStyle())
        }
    }
}

struct SettingsDescription: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(appState.localized(text))
                .font(.caption.weight(.medium))
                .lineSpacing(1.5)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 与设置行标题文字左缘对齐：图标芯片 34 + 间距 14 = 48。
        .padding(.leading, 48)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.42 : 0.62))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.refCardBorder.opacity(colorScheme == .dark ? 0.12 : 0.30), lineWidth: 0.45)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsPathText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 9, thickness: 0.86)
    }
}

struct SettingsGlassCard: View {
    var body: some View {
        ReferenceCardSurface(cornerRadius: 18)
    }
}
