import MediaLibCore
import SwiftUI

struct QuickPreviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem

    @StateObject private var controller = MpvPlayerController()

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            if item.filePath != nil {
                MpvPlayerView(controller: controller)
                    .background(Color.black)
                    .ignoresSafeArea()
            } else {
                EmptyStateView(title: "无法预览", systemImage: "eye.slash", message: "视频文件不可访问。")
                    .foregroundStyle(.white)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.episodeLabel)
                        .font(.headline)
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    dismiss()
                    appState.presentBuiltInPlayer(item)
                } label: {
                    Label("继续播放", systemImage: "play.fill")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 34, prominent: true))

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 10, minHeight: 34))
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(14)
            .surfaceBackground(cornerRadius: 18)
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 460)
        .background {
            RawKeyCaptureView { key in
                if key == .space || key == .escape {
                    dismiss()
                }
            }
            .frame(width: 0, height: 0)
        }
        .onAppear(perform: setupPlayer)
        .onDisappear {
            controller.teardown()
        }
    }

    private func setupPlayer() {
        guard let filePath = item.filePath,
              item.isRemoteResource || FileManager.default.fileExists(atPath: filePath) else {
            return
        }
        controller.configure(item: item, settings: appState.settings)
        if let duration = item.duration, duration > 0 {
            let start = duration * appState.settings.quickPreviewStartRatio
            controller.seek(to: start)
        }
        if appState.settings.quickPreviewMuted {
            controller.setVolume(0)
        }
    }
}
