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
    @State private var showingAboutSoftware = false
    @State private var showingSyncConflictQueue = false
    @State private var showingMetadataHistory = false
    @State private var autoStartMusicMetadataConsole = false

    var body: some View {
        // 设置分组使用原生 List 虚拟化，每个分组作为一行，保留 860pt 居中最大宽度与 24pt 间距。
        List {
            settingsRow(topPadding: 30) { SettingsHeader() }
            settingsRow { homeSettings }
            settingsRow { appearanceSettings }
            settingsRow { videoPlaybackSettings }
            settingsRow { musicPlaybackSettings }
            settingsRow { scanSettings }
            settingsRow { metadataSettings }
            settingsRow { subtitleSettings }
            settingsRow { thumbnailSettings }
            settingsRow { connectorStateSettings }
            settingsRow { traktSettings }
            settingsRow { privacySettings }
            settingsRow { advancedSettings }
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
        .background(AppPageBackground())
        .navigationTitle("设置")
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

    private var videoPlaybackSettings: some View {
        SettingsSection(title: "视频播放与缓存", subtitle: "设置视频启动方式、观看规则和离线缓存。", systemImage: "play.rectangle") {
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
                .settingsMenuControl(selectedTitle: appState.settings.videoDefaultPlayer.displayName)
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

            SettingsDescription(text: "内置视频播放器的窗口宽度、预览图、默认倍速和跳转间隔可在播放窗口齿轮菜单中调整；这里保留默认启动方式，避免切到系统播放器后无法回到内置。")

            SettingsSubsectionHeader(title: "观看规则", systemImage: "slider.horizontal.3")

            SettingsToggleRow(title: "记忆播放进度", systemImage: "clock.arrow.circlepath", isOn: binding(\.rememberPlaybackPosition))
            SettingsToggleRow(title: "自动播放下一集", systemImage: "forward.end", isOn: binding(\.autoPlayNextEpisode))
            SettingsToggleRow(title: "播放完成自动标记已看", systemImage: "checkmark.circle", isOn: binding(\.autoMarkWatched))

            if appState.settings.videoDefaultPlayer == .builtIn {
                SettingsRow(title: "默认倍速", systemImage: "speedometer") {
                    Picker("默认倍速", selection: binding(\.defaultPlaybackRate)) {
                        Text("0.75x").tag(0.75)
                        Text("1.00x").tag(1.0)
                        Text("1.25x").tag(1.25)
                        Text("1.50x").tag(1.5)
                        Text("2.00x").tag(2.0)
                    }
                    .labelsHidden()
                    .settingsMenuControl(selectedTitle: settingsPlaybackRateTitle(appState.settings.defaultPlaybackRate))
                }

                SettingsRow(title: "快进/快退", systemImage: "gobackward.5") {
                    Slider(value: binding(\.skipInterval), in: 5...30, step: 5)
                    Text("\(Int(appState.settings.skipInterval)) 秒")
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
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

            SettingsDescription(text: "离线视频会保存到该位置的 VideoCache 子目录。删除缓存只会移除 MediaLIB 记录的缓存文件，不会改动媒体源。")

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

            SettingsDescription(text: "设置上限后，一键清理会优先整理失效记录和无引用文件，再回收已看或较久未播放的离线缓存。")
        }
    }

    private var musicPlaybackSettings: some View {
        SettingsSection(title: "音乐播放", subtitle: "设置音乐播放器、歌词、响度和过渡。", systemImage: "music.note") {
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
                .settingsMenuControl(selectedTitle: appState.settings.musicDefaultPlayer.displayName)
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

            SettingsRow(title: "歌词同步", systemImage: "text.badge.checkmark") {
                Picker("歌词同步", selection: binding(\.lyricSyncAlgorithm)) {
                    ForEach(LyricSyncAlgorithm.allCases) { algorithm in
                        Text(algorithm.displayName).tag(algorithm)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.lyricSyncAlgorithm.displayName)
            }

            SettingsDescription(text: appState.settings.lyricSyncAlgorithm.description)

            if appState.settings.musicDefaultPlayer == .builtIn {
                SettingsToggleRow(title: "封面发光", systemImage: "sparkles", isOn: binding(\.musicAlbumCoverGlowEnabled))
                SettingsDescription(text: "开启时展开播放器使用封面原图的多层柔光；关闭后只保留主色的浅柔阴影，暂停时同样收起光效。")

                SettingsRow(title: "音乐响度均衡", systemImage: "waveform.badge.magnifyingglass") {
                    Picker("音乐响度均衡", selection: binding(\.musicLoudnessNormalization)) {
                        ForEach(MusicLoudnessNormalization.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuControl(selectedTitle: appState.settings.musicLoudnessNormalization.displayName)
                }

                SettingsDescription(text: "按歌曲已有的 ReplayGain / R128 标签均衡音量，并保留峰值保护。不会修改音乐文件。")

                SettingsRow(title: "跨曲过渡", systemImage: "arrow.right.to.line.compact") {
                    Picker("跨曲过渡", selection: binding(\.musicTransitionMode)) {
                        ForEach(MusicTransitionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuControl(selectedTitle: appState.settings.musicTransitionMode.displayName)
                }

                if appState.settings.musicTransitionMode == .softFade {
                    SettingsRow(title: "淡入时长", systemImage: "waveform.path") {
                        Slider(value: binding(\.musicSoftFadeDuration), in: 0.3...2, step: 0.1)
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
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .settingsMenuControl(selectedTitle: appState.settings.musicEqualizerPreset.displayName)
                    }
                    SettingsDescription(text: "5 段均衡（60 / 230 / 910 / 3.6k / 14k Hz）作用于本地与在线音乐，调整在下一首切换时生效。")
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
                        Text(interval.displayName).tag(interval)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.automaticScanInterval.displayName)
            }

            SettingsDescription(text: "本机来源会优先增量更新，并按所选间隔完整校验。移动硬盘和网络挂载使用周期扫描；不可访问的来源会暂时跳过。")

            SettingsRow(title: "完成后发送通知", systemImage: "bell.badge") {
                Toggle("", isOn: Binding(get: {
                    appState.settings.notifyOnTaskCompletion
                }, set: { value in
                    appState.setTaskCompletionNotifications(value)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsDescription(text: "完整扫描或 Emby 同步结束、或出现错误时，在 App 切到后台时通过系统通知中心提醒（首次开启会请求通知权限）。")
        }
    }

    private var thumbnailSettings: some View {
        SettingsSection(title: "封面与截图", subtitle: "设置缺失封面、视频帧截图和并发任务。", systemImage: "photo.on.rectangle") {
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
                .settingsMenuControl(selectedTitle: "\(appState.settings.thumbnailConcurrency) 个任务")
            }
            .disabled(appState.settings.artworkFallbackMode == .none)
        }
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
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.metadataMatchTolerance.displayName)
            }

            SettingsDescription(text: "影视宽容度决定剧集 TMDB 自动套用所需置信度：\(appState.settings.metadataMatchTolerance.summary)。宽松模式会使用清洗后的剧名、原名和目录名变体搜索。")

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
                        Text(interval.displayName).tag(interval)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.automaticTMDBMatchInterval.displayName)
            }

            SettingsDescription(text: "立即匹配会补全尚未匹配的电视剧和动漫；自动拉取只处理之后新增且未匹配的内容。")

            SettingsSubsectionHeader(title: "音乐信息", systemImage: "music.note.list")

            SettingsRow(title: "音乐数据源", systemImage: "music.note.list") {
                Picker("音乐数据源", selection: binding(\.musicMetadataProvider)) {
                    ForEach(MusicMetadataProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.musicMetadataProvider.displayName)
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

            SettingsDescription(text: "网易云音乐、QQ 音乐和 Deezer 可直接使用；Last.fm 需要 API Key。可在音乐元数据工作台或歌曲详情中补全信息。")

            SettingsRow(title: "音乐匹配宽容度", systemImage: "scope") {
                Picker("音乐匹配宽容度", selection: binding(\.musicMetadataMatchTolerance)) {
                    ForEach(MetadataMatchTolerance.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.musicMetadataMatchTolerance.displayName)
            }

            SettingsDescription(text: "音乐宽容度仅影响自动补充和音乐工作台的候选置信度：\(appState.settings.musicMetadataMatchTolerance.summary)。")

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
                appState.settings.lastfmScrobblingEnabled = value
                appState.saveSettings()
            }))
            .labelsHidden()
            .toggleStyle(.switch)
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
        SettingsSection(title: "外观与布局", subtitle: "调整主题、配色和海报尺寸。", systemImage: "paintbrush.pointed") {
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
                .settingsMenuControl(selectedTitle: appState.settings.theme.displayName)
            }

            SettingsRow(title: "配色", systemImage: "paintpalette") {
                Picker("配色", selection: Binding(get: {
                    appState.settings.themePreset
                }, set: { appState.setThemePreset($0) })) {
                    ForEach(AppThemePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .settingsMenuControl(selectedTitle: appState.settings.themePreset.displayName)
            }

            if appState.settings.themePreset.isCustom {
                SettingsRow(title: "底色 / 卡片", systemImage: "rectangle.fill") {
                    ColorPicker("", selection: customThemeBinding(\.themeBaseHex, fallback: "F6F8FC", apply: { appState.setCustomThemeColor(base: $0) }), supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRow(title: "高亮色", systemImage: "sparkle") {
                    ColorPicker("", selection: customThemeBinding(\.themeHighlightHex, fallback: "2F7DE1", apply: { appState.setCustomThemeColor(highlight: $0) }), supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRow(title: "左上角光线", systemImage: "sun.max") {
                    ColorPicker("", selection: customThemeBinding(\.themeLightHex, fallback: "F1F7FF", apply: { appState.setCustomThemeColor(light: $0) }), supportsOpacity: false)
                        .labelsHidden()
                }
            }

            SettingsDescription(text: "配色作用于除音乐展开页以外的全部界面：页面底色、卡片、高亮选中色与左上角光线。预设已收敛为 5 套低饱和 macOS 原生风格，选「自定义」可分别调整三种颜色。")

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
                    .toggleStyle(.switch)
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

            SettingsDescription(text: "在 trakt.tv 创建应用获取 Client ID 与 Secret。连接时会打开网页让你输入验证码。仅处理已匹配 TMDB 的公开视频：本机改动会推送已看 / 想看；从 Trakt 导入会生成同步冲突，采用远端后写入 MediaLIB 内部索引。")
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
            SettingsDescription(text: "同步冲突队列中采用远端会把已看、想看、喜欢和用户评级写入 MediaLIB 内部索引；Trakt 冲突选择保留本地会把本机已看/想看写回 Trakt。Plex/Jellyfin/Emby 的更多远端写回、评分冲突来源接入和多字段合并仍由后续连接器执行。该分组不提供多档案隔离，所有播放记录、喜欢、想看和评分都使用全局本机索引。")
        }
    }

    private var advancedSettings: some View {
        SettingsSection(title: "数据、存储与诊断", subtitle: "管理备份、存储位置、清理和性能记录。", systemImage: "externaldrive") {
            SettingsToggleRow(title: "性能记录", systemImage: "gauge.with.dots.needle.67percent", isOn: binding(\.debugLoggingEnabled))
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
                SettingsDescription(text: "清理失效缓存记录、已不存在条目的离线缓存、无引用的缓存文件和过旧任务历史；不会删除、移动或改名媒体源里的文件。")
            }
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
        }
    }

    private var privacySettings: some View {
        SettingsSection(title: "保险库", subtitle: "管理私密内容的解锁方式。", systemImage: "lock.shield") {
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
    @Environment(\.dismiss) private var dismiss

    private let githubURL = URL(string: "https://github.com/Again0521/MediaLib")!
    private let emailURL = URL(string: "mailto:zonn.l@foxmail.com")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sheetContent) {
            HStack(alignment: .center, spacing: 16) {
                AboutAppLogoView()
                    .frame(width: 78, height: 78, alignment: .center)

                VStack(alignment: .leading, spacing: 6) {
                    Text("关于 MediaLIB")
                        .font(.title3.weight(.semibold))
                    Text("MediaLIB 是一款面向 macOS 的个人影音媒体库应用，帮助你整理、播放和管理本地、Emby 与网络来源的视频和音乐收藏。")
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
                AboutInfoRow(title: "作者", systemImage: "person.crop.circle") {
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
            }
            .padding(14)
            .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 0.94)

            AppSheetActionFooter {
                Button {
                    dismiss()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
                .settingsActionButton(width: 104, prominent: true)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.compactWidth)
    }
}

private struct AboutAppLogoView: View {
    private static let logo: NSImage? = {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
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
            .staticSurfaceBackground(cornerRadius: AppRadius.card)
            .padding(.leading, 42)
        }
        .padding(.leading, 28)
    }
}

struct SettingsSubsectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: HomeTab
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let active = isEnabled || isHovering
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .frame(width: 18)
                Text(tab.displayName)
                    .lineLimit(1)
                Spacer()
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isEnabled ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .staticSurfaceBackground(selected: isEnabled, cornerRadius: 12, thickness: 0.94)
            .repeatedSurfaceHover(isHovering, cornerRadius: 12, intensity: active ? 0.74 : 0.62)
            .brightness(isHovering ? 0.006 : 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : AppMotion.listHover, value: isHovering)
        .help(tab.displayName)
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
        PageHeader(title: "设置", subtitle: "调整播放、媒体库、界面与隐私设置。", systemImage: "gearshape")
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

    func settingsMenuControl(selectedTitle: String) -> some View {
        adaptiveMenuControl(
            selectedTitle: selectedTitle,
            minWidth: 76,
            maxWidth: 260
        )
    }

    func settingsActionButton(
        width: CGFloat = SettingsControlMetrics.actionButtonWidth,
        prominent: Bool = false
    ) -> some View {
        buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 10, minHeight: 30, prominent: prominent))
            .frame(width: width, alignment: .trailing)
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
        AppInfoNote(text: text)
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
