import AppKit
import SwiftUI

final class MediaLibAppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []
    /// 双击文件/「打开方式」进入的媒体文件。SwiftUI 场景就绪前先缓存，就绪后由 App 拉取。
    var onOpenFiles: (([URL]) -> Void)?
    var pendingOpenFileURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        if let onOpenFiles {
            onOpenFiles(fileURLs)
        } else {
            pendingOpenFileURLs.append(contentsOf: fileURLs)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 启动白条根因：SwiftUI 的标题栏窗口在首帧是“不透明白底 + 显示 App 标题”，
        // 之后才被 SwiftUI 守卫改透明——中间那一帧就是顶部一闪而过的白条。
        // 这里在窗口一创建（becomeKey/变为可见之前）就立刻把标题栏改透明、隐藏标题，
        // 让第一帧起顶部就没有白底，从根上消除闪白。
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeScreenNotification
        ]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { note in
                guard let window = note.object as? NSWindow else { return }
                Self.makeTitlebarSeamless(window)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 在任何音乐播放器界面渲染前，把用户主题参数文件加载进 MusicThemeConfig.active
        // （无文件则写一份默认模板供编辑）。音乐界面仅在用户打开播放器时渲染，远晚于此回调。
        MusicThemeConfigStore.bootstrap()

        // SwiftUI 可能在本回调前后才创建窗口；前几帧连续套用，确保第一帧可见时标题栏已透明、无标题。
        for delay in [0.0, 0.0, 0.02, 0.05, 0.12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    Self.makeTitlebarSeamless(window)
                }
            }
        }
        LiveTitleIconDebugTool.scheduleWindowCaptureIfRequested()
        WindowMaterialDiagnostics.scheduleIfRequested()
        VividIconGridDebugTool.runAndExitIfRequested()
    }

    static func makeTitlebarSeamless(_ window: NSWindow) {
        // 只处理主内容窗口。NSOpenPanel / NSSavePanel / NSAlert 都是 NSPanel；
        // 它们同样可能带标题栏和可改尺寸，若误改成透明窗口会直接透出后方页面。
        // 视频播放器窗口（ImmersivePlayerWindow）自行管理外观且刻意保持不透明，跳过。
        guard !(window is NSPanel),
              !(window is ImmersivePlayerWindow),
              window.styleMask.contains(.titled),
              window.styleMask.contains(.resizable) else { return }
        if window.titlebarAppearsTransparent != true {
            window.titlebarAppearsTransparent = true
        }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if window.isOpaque {
            window.isOpaque = false
        }
        if window.backgroundColor != .clear {
            window.backgroundColor = .clear
        }
        // ★不要再给 contentView / frameView(NSThemeFrame) 强制 wantsLayer 或清 layer 背景：
        // 实机分级对照（B1/B2/B3 harness）证实这些 layer 改动会让 NSVisualEffectView 的
        // .behindWindow backdrop 完全失效（侧栏只剩平灰、无桌面透光模糊）。
        // 窗口级 isOpaque=false + backgroundColor=.clear 已足够消除启动白条。
        if #available(macOS 11.0, *) {
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }
        }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

@main
struct MediaLibApp: App {
    @NSApplicationDelegateAdaptor(MediaLibAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        LiveTitleIconDebugTool.prepareInitialSelectionIfRequested()
#if DEBUG
        TitleIconDebugTool.runAndExitIfRequested()
#endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(appState)
                .preferredColorScheme(preferredAppColorScheme)
                // 不在 SwiftUI 层用 .frame(minWidth/minHeight) 限制最小尺寸：它会与音乐展开覆盖层的
                // ignoresSafeArea 叠加，导致每次展开把窗口最小内容尺寸顶大、收起又不缩回（窗口被撑大）。
                // 改为在 MainWindowToolbarVisibilityGuard 里用 AppKit 的 contentMinSize 固定最小尺寸。
                .onAppear { [appState] in
                    appState.applyAppearance()
                    appState.restoreServerModeIfNeeded()
                    LiveTitleIconDebugTool.scheduleWindowCaptureIfRequested()
                    SystemMediaCommandCenter.shared.configure(appState: appState)
                    appDelegate.onOpenFiles = { [weak appState] urls in
                        appState?.playExternalFiles(urls)
                    }
                    if !appDelegate.pendingOpenFileURLs.isEmpty {
                        let pending = appDelegate.pendingOpenFileURLs
                        appDelegate.pendingOpenFileURLs = []
                        appState.playExternalFiles(pending)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--debug-show-notice-preview") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            appState.showFloatingNotice(title: "已是最新版本", message: "当前版本 1.5.1。", kind: .info)
                            appState.showFloatingNotice(title: "已复制链接", message: "https://example.com/video.mp4", kind: .success)
                            appState.showFloatingNotice(title: "写入会修改本地音频文件", message: "远程或不支持格式会逐条跳过。", kind: .warning)
                            appState.showFloatingNotice(title: "扫描失败", message: "无法访问媒体源路径。", kind: .error)
                        }
                    }
                }
                .onChange(of: appState.settings.theme) { _ in
                    appState.applyAppearance()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1088, height: 840)
        .commands {
            SidebarCommands()
            CommandMenu("播放") {
                Button("播放/暂停") {
                    appState.sendPlaybackCommand(.togglePlay)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(appState.activePlayerItem == nil)

                Button("上一首/上一集") {
                    appState.sendPlaybackCommand(.previous)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(appState.activePlayerItem == nil)

                Button("下一首/下一集") {
                    appState.sendPlaybackCommand(.next)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(appState.activePlayerItem == nil)

                Divider()

                Button("打开网络串流…") {
                    appState.showingNetworkStreamPrompt = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button(appState.musicShuffleEnabled ? "关闭随机播放" : "开启随机播放") {
                    appState.sendPlaybackCommand(.toggleShuffle)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("切换循环模式：\(appState.musicRepeatMode.title)") {
                    appState.sendPlaybackCommand(.cycleRepeat)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("媒体库") {
                Button(appState.isFetchingMusicMetadata ? "正在补充音乐信息" : "增量补充音乐信息") {
                    Task { await appState.fetchAllMusicMetadata() }
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(
                    appState.musicTracks.isEmpty ||
                    appState.settings.musicMetadataProvider == .disabled ||
                    appState.isFetchingMusicMetadata
                )
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
#if DEBUG
        if isMusicVisualDebugMode {
            MusicPlayerVisualDebugHarness()
        } else {
            ContentView()
        }
#else
        ContentView()
#endif
    }

    private var preferredAppColorScheme: ColorScheme? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--music-player-visual-debug-dark") {
            return .dark
        }
        if arguments.contains("--music-player-visual-debug-light") {
            return .light
        }
#endif
        return appState.settings.theme.colorScheme
    }

#if DEBUG
    private var isMusicVisualDebugMode: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--music-player-visual-debug") ||
            arguments.contains("--music-player-visual-debug-dark") ||
            arguments.contains("--music-player-visual-debug-light")
    }
#endif
}
