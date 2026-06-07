import AppKit
import SwiftUI

final class MediaLibAppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        // SwiftUI 可能在本回调前后才创建窗口；前几帧连续套用，确保第一帧可见时标题栏已透明、无标题。
        for delay in [0.0, 0.0, 0.02, 0.05, 0.12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    Self.makeTitlebarSeamless(window)
                }
            }
        }
    }

    static func makeTitlebarSeamless(_ window: NSWindow) {
        // 只处理主内容窗口。NSOpenPanel / NSSavePanel / NSAlert 都是 NSPanel；
        // 它们同样可能带标题栏和可改尺寸，若误改成透明窗口会直接透出后方页面。
        guard !(window is NSPanel),
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
        if window.contentView?.wantsLayer != true {
            window.contentView?.wantsLayer = true
        }
        if window.contentView?.layer?.backgroundColor != NSColor.clear.cgColor {
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(appState.settings.theme.colorScheme)
                // 不在 SwiftUI 层用 .frame(minWidth/minHeight) 限制最小尺寸：它会与音乐展开覆盖层的
                // ignoresSafeArea 叠加，导致每次展开把窗口最小内容尺寸顶大、收起又不缩回（窗口被撑大）。
                // 改为在 MainWindowToolbarVisibilityGuard 里用 AppKit 的 contentMinSize 固定最小尺寸。
                .onAppear {
                    appState.applyAppearance()
                    SystemMediaCommandCenter.shared.configure(appState: appState)
                }
                .onChange(of: appState.settings.theme) { _ in
                    appState.applyAppearance()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
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

                Button("快退 15 秒") {
                    appState.sendPlaybackCommand(.seekBackward)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .disabled(appState.activePlayerItem == nil)

                Button("快进 15 秒") {
                    appState.sendPlaybackCommand(.seekForward)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .disabled(appState.activePlayerItem == nil)

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
}
