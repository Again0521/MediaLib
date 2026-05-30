import AppKit
import MediaLibCore
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsControlMetrics {
    static let compactControlWidth: CGFloat = 190
    static let actionButtonWidth: CGFloat = 96
    static let wideControlWidth: CGFloat = 430
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingMusicTagSheet = false
    @State private var autoStartMusicMetadataConsole = false

    var body: some View {
        // P1：原 ScrollView + LazyVStack 不回收（设置项随滚动累积驻留）。
        // 改为原生 List 真正虚拟化；每个分组作为一行，保留 860pt 居中最大宽度与 24pt 间距。
        List {
            settingsRow(topPadding: 30) { SettingsHeader() }
            settingsRow { playbackSettings }
            settingsRow { homeSettings }
            settingsRow { scanSettings }
            settingsRow { metadataSettings }
            settingsRow { subtitleSettings }
            settingsRow { thumbnailSettings }
            settingsRow { appearanceSettings }
            settingsRow { privacySettings }
            settingsRow { advancedSettings }
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
        .suppressListHighlight()
        .background(AppPageBackground())
        .navigationTitle("设置")
        .sheet(isPresented: $showingMusicTagSheet) {
            MusicTagScraperSheet(
                autoStart: autoStartMusicMetadataConsole,
                includeLyrics: autoStartMusicMetadataConsole
            )
                .environmentObject(appState)
        }
    }

    // 设置分组行：860pt 居中最大宽度 + 上下内边距构成 24pt 间距，清除 List 默认行样式。
    @ViewBuilder
    private func settingsRow<Content: View>(topPadding: CGFloat = 12, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 34)
            .listRowInsets(EdgeInsets(top: topPadding, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var playbackSettings: some View {
        SettingsSection(title: "播放", subtitle: "播放器、进度和外部应用", systemImage: "play.rectangle") {
            let usesBuiltInVideo = appState.settings.videoDefaultPlayer == .builtIn
            let usesAnyBuiltInPlayer = appState.settings.videoDefaultPlayer == .builtIn || appState.settings.musicDefaultPlayer == .builtIn
            let videoWidthRatio = Binding<Double>(
                get: {
                    VideoWindowSizing.screenWidthRatio(for: appState.settings.videoPlayerPreferredWidth)
                },
                set: { ratio in
                    appState.settings.videoPlayerPreferredWidth = VideoWindowSizing.preferredWidth(forScreenWidthRatio: ratio)
                    appState.saveSettings()
                }
            )

            SettingsRow(title: "视频播放器", systemImage: "play.rectangle") {
                Picker("视频播放器", selection: Binding(get: {
                    appState.settings.videoDefaultPlayer
                }, set: {
                    appState.settings.videoDefaultPlayer = $0
                    appState.saveSettings()
                })) {
                    ForEach(DefaultPlayer.allCases) { player in
                        Text(player.displayName).tag(player)
                    }
                }
                .labelsHidden()
                .settingsCompactControl()
            }

            if appState.settings.videoDefaultPlayer == .external {
                SettingsRow(title: "视频系统播放器", systemImage: "app.badge") {
                    SettingsPathText(text: appState.settings.videoExternalPlayerPath ?? "系统默认")
                    Button {
                        chooseExternalPlayer(forMusic: false)
                    } label: {
                        Label("选择", systemImage: "app")
                    }
                    .settingsActionButton()
                }
            }

            if usesBuiltInVideo {
                SettingsRow(title: "视频窗口宽度", systemImage: "arrow.left.and.right") {
                    Slider(
                        value: videoWidthRatio,
                        in: VideoWindowSizing.minimumScreenWidthRatio...VideoWindowSizing.maximumScreenWidthRatio,
                        step: 0.01
                    )
                    Text("\(Int((videoWidthRatio.wrappedValue * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            SettingsRow(title: "音乐播放器", systemImage: "music.note") {
                Picker("音乐播放器", selection: Binding(get: {
                    appState.settings.musicDefaultPlayer
                }, set: {
                    appState.settings.musicDefaultPlayer = $0
                    appState.saveSettings()
                })) {
                    ForEach(DefaultPlayer.allCases) { player in
                        Text(player.displayName).tag(player)
                    }
                }
                .labelsHidden()
                .settingsCompactControl()
            }

            if appState.settings.musicDefaultPlayer == .external {
                SettingsRow(title: "音乐系统播放器", systemImage: "app.badge") {
                    SettingsPathText(text: appState.settings.musicExternalPlayerPath ?? "系统默认")
                    Button {
                        chooseExternalPlayer(forMusic: true)
                    } label: {
                        Label("选择", systemImage: "app")
                    }
                    .settingsActionButton()
                }
            }

            if appState.settings.musicDefaultPlayer == .builtIn {
                SettingsToggleRow(title: "AirPlay 本机同播", systemImage: "hifispeaker.and.homepod", isOn: binding(\.keepLocalAudioWithAirPlay))
                SettingsDescription(text: "开启后，音乐投到隔空播放设备时会保留本机同步播放；关闭后遵循系统 AirPlay 的外部设备输出。")
            }

            SettingsToggleRow(title: "记忆播放进度", systemImage: "clock.arrow.circlepath", isOn: binding(\.rememberPlaybackPosition))
            SettingsToggleRow(title: "自动播放下一集", systemImage: "forward.end", isOn: binding(\.autoPlayNextEpisode))
            SettingsToggleRow(title: "播放完成自动标记已看", systemImage: "checkmark.circle", isOn: binding(\.autoMarkWatched))

            if usesAnyBuiltInPlayer {
                SettingsRow(title: "默认倍速", systemImage: "speedometer") {
                    Picker("默认倍速", selection: binding(\.defaultPlaybackRate)) {
                        Text("0.75x").tag(0.75)
                        Text("1.00x").tag(1.0)
                        Text("1.25x").tag(1.25)
                        Text("1.50x").tag(1.5)
                        Text("2.00x").tag(2.0)
                    }
                    .labelsHidden()
                    .settingsCompactControl()
                }

                SettingsRow(title: "快进/快退", systemImage: "gobackward.5") {
                    Slider(value: binding(\.skipInterval), in: 5...30, step: 5)
                    Text("\(Int(appState.settings.skipInterval)) 秒")
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            }

            if usesBuiltInVideo {
                SettingsDescription(text: "内置视频播放器使用 libmpv 核心和应用内液态玻璃控制栏；窗口宽度按当前屏幕可用宽度的百分比计算，并会按视频比例和可用区域自动收敛。字幕会自动匹配同目录文件，字幕和音轨可从播放器图标菜单切换。")
            }
        }
    }

    private var homeSettings: some View {
        SettingsSection(title: "首页", subtitle: "选择首页显示哪些选项卡", systemImage: "square.grid.2x2") {
            SettingsDescription(text: "关闭不常用内容后，首页只保留你选择的选项卡；至少会保留一个选项卡。")
            HomeTabSettingsGrid()
        }
    }

    private var scanSettings: some View {
        SettingsSection(title: "扫描", subtitle: "定时发现已添加路径中的新媒体", systemImage: "arrow.triangle.2.circlepath") {
            SettingsRow(title: "自动扫描", systemImage: "clock.arrow.circlepath") {
                Picker("自动扫描", selection: binding(\.automaticScanInterval)) {
                    ForEach(AutomaticScanInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .labelsHidden()
                .settingsCompactControl()
            }

            SettingsDescription(text: "开启后，MediaLIB 会按间隔扫描已添加且启用自动扫描的本地、移动硬盘和已挂载网络路径；不可访问的路径会跳过，媒体源页“扫描全部”仍可立即手动扫描。")
        }
    }

    private var thumbnailSettings: some View {
        SettingsSection(title: "封面", subtitle: "缺失海报时的生成方式", systemImage: "photo.on.rectangle") {
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
                Slider(value: binding(\.thumbnailCaptureRatio), in: 0.05...0.3, step: 0.05)
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
                .settingsCompactControl()
            }
            .disabled(appState.settings.artworkFallbackMode == .none)
        }
    }

    private var metadataSettings: some View {
        SettingsSection(title: "元数据", subtitle: "TMDB 与音乐索引服务", systemImage: "sparkles.rectangle.stack") {
            SettingsDescription(text: "TMDB 用于电影和剧集搜索；音乐可选择 MusicBrainz 或 iTunes Search。MusicBrainz 不需要 API Key。")

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

            SettingsRow(title: "音乐数据源", systemImage: "music.note.list") {
                Picker("音乐数据源", selection: binding(\.musicMetadataProvider)) {
                    ForEach(MusicMetadataProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .settingsCompactControl()
            }

            SettingsRow(title: "音乐自动匹配", systemImage: "sparkles") {
                if !appState.musicMetadataFetchProgress.isEmpty {
                    Text(appState.musicMetadataFetchProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("一键获取封面和歌词") {
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
                    Label("打开控制台", systemImage: "tag.circle")
                }
                .settingsActionButton(width: 166, prominent: true)
                .disabled(appState.musicTracks.isEmpty)
            }
        }
    }

    private var subtitleSettings: some View {
        SettingsSection(title: "字幕", subtitle: "在线字幕来源与首选语言", systemImage: "captions.bubble") {
            SettingsDescription(text: "播放器字幕弹出层会自动搜索 Podnapisi（无需 API Key）和 OpenSubtitles（需配置 API Key）。字幕文件下载后保存在视频同目录，并立即加载。")

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
        SettingsSection(title: "界面", subtitle: "主题和海报墙密度", systemImage: "paintbrush.pointed") {
            SettingsRow(title: "主题", systemImage: "circle.lefthalf.filled") {
                Picker("主题", selection: Binding(get: {
                    appState.settings.theme
                }, set: {
                    appState.settings.theme = $0
                    appState.saveSettings()
                })) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
                .settingsCompactControl()
            }

            SettingsRow(title: "海报最小宽度", systemImage: "rectangle.compress.vertical") {
                Slider(value: binding(\.posterMinWidth), in: 130...220, step: 10)
                Text("\(Int(appState.settings.posterMinWidth))")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            SettingsRow(title: "海报最大宽度", systemImage: "rectangle.expand.vertical") {
                Slider(value: binding(\.posterMaxWidth), in: 180...300, step: 10)
                Text("\(Int(appState.settings.posterMaxWidth))")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var advancedSettings: some View {
        SettingsSection(title: "高级", subtitle: "日志和本地数据位置", systemImage: "wrench.and.screwdriver") {
            SettingsToggleRow(title: "调试日志", systemImage: "ladybug", isOn: binding(\.debugLoggingEnabled))
            if let directories = appState.directories {
                SettingsRow(title: "数据库位置", systemImage: "cylinder.split.1x2") {
                    SettingsPathText(text: directories.database.path)
                }
                SettingsRow(title: "缓存位置", systemImage: "externaldrive.connected.to.line.below") {
                    SettingsPathText(text: directories.cache.path)
                }
            }
        }
    }

    private var privacySettings: some View {
        SettingsSection(title: "保险库", subtitle: "Touch ID 与 4 到 8 位数字密码", systemImage: "lock.shield") {
            PrivacySettingsPanel()
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

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding {
            appState.settings[keyPath: keyPath]
        } set: { newValue in
            appState.settings[keyPath: keyPath] = newValue
            appState.saveSettings()
        }
    }

}

struct SettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PlayfulSymbolIcon(systemImage: systemImage, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 18)
            .padding(.leading, 42)
        }
        .padding(.leading, 28)
    }
}

struct HomeTabSettingsGrid: View {
    @EnvironmentObject private var appState: AppState

    private let columns = [GridItem(.adaptive(minimum: 154), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(visibleTabs) { tab in
                Button {
                    toggle(tab)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.systemImage)
                            .frame(width: 18)
                        Text(tab.displayName)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: isEnabled(tab) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isEnabled(tab) ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .staticSurfaceBackground(selected: isEnabled(tab), cornerRadius: 12, thickness: 0.94)
                    .pointerLiquidEdge(cornerRadius: 12, intensity: isEnabled(tab) ? 1.0 : 0.86)
                }
                .buttonStyle(.plain)
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

struct PrivacySettingsPanel: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin = ""
    @State private var confirmPIN = ""
    @State private var unlockPIN = ""

    var body: some View {
        SettingsDescription(text: "保险库会从首页、最近播放、收藏和健康提示中隐藏；进入保险库时需要 Touch ID 或应用内数字密码解锁。")

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
            SettingsRow(title: "解锁密码", systemImage: "number", contentSpacing: 8) {
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
                    .settingsActionButton(width: 112)
                }
            }

            SettingsDescription(text: "锁定时隐藏更改密码和移除密码操作，解锁后才可管理保险库密码。")
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
                        appState.removePrivacyPIN()
                        pin = ""
                        confirmPIN = ""
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
        if appState.verifyPrivacyPIN(unlockPIN) {
            unlockPIN = ""
        }
    }

    private func savePIN() {
        guard canSavePIN else {
            appState.alert = AppAlert(title: "密码无效", message: "请输入一致的 4 到 8 位数字密码。")
            return
        }
        if appState.setPrivacyPIN(pin) {
            pin = ""
            confirmPIN = ""
        }
    }
}

struct SettingsHeader: View {
    var body: some View {
        PageHeader(title: "设置", subtitle: "调整播放、封面生成、界面密度、保险库和本地数据。", systemImage: "gearshape")
    }
}

struct SettingsRow<Content: View>: View {
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
        HStack(spacing: 14) {
            PlayfulSymbolIcon(systemImage: systemImage, size: 26)

            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 132, alignment: .leading)

            HStack(spacing: contentSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 34)
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

    func settingsCompactControl(width: CGFloat = SettingsControlMetrics.compactControlWidth) -> some View {
        frame(width: width, alignment: .trailing)
    }

    func settingsActionButton(
        width: CGFloat = SettingsControlMetrics.actionButtonWidth,
        prominent: Bool = false
    ) -> some View {
        buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 10, minHeight: 30, prominent: prominent))
            .frame(width: width, alignment: .trailing)
    }
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
    let title: String
    let systemImage: String
    var isOn: Binding<Bool>

    var body: some View {
        SettingsRow(title: title, systemImage: systemImage) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct SettingsDescription: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 10, thickness: 0.86)
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
        LiquidGlassSurfaceLayer(cornerRadius: 18)
    }
}
