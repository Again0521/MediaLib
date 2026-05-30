import SwiftUI

final class MediaLibAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        .windowStyle(.titleBar)
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
                Button(appState.isFetchingMusicMetadata ? "正在获取音乐封面和歌词" : "获取音乐封面和歌词") {
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
