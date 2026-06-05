import MediaLibCore
import SwiftUI

struct MusicPlaylistCreationRequest: Identifiable {
    let id = UUID()
    let tracks: [MediaItem]
    let suggestedName: String
}

struct MusicPlaylistRenameRequest: Identifiable {
    let playlist: MusicPlaylist

    var id: String { playlist.id }
}

struct MusicPlaylistCreationSheet: View {
    let request: MusicPlaylistCreationRequest
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(
        request: MusicPlaylistCreationRequest,
        onCreate: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onCreate = onCreate
        self.onCancel = onCancel
        _name = State(initialValue: request.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: request.tracks.isEmpty ? "新建歌单" : "新建歌单并添加歌曲",
                subtitle: summary,
                systemImage: "music.note.list"
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("歌单名称")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("新歌单", text: $name)
                    .textFieldStyle(.plain)
                    .glassFormField()
            }
            .padding(16)
            .staticSurfaceBackground(cornerRadius: 18)

            AppSheetActionFooter {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))

                Button {
                    onCreate(trimmedName)
                } label: {
                    Label("创建", systemImage: "plus")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(trimmedName.isEmpty)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.compactWidth)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var summary: String {
        if request.tracks.isEmpty {
            return "创建后可随时添加歌曲。"
        }
        return "创建歌单并加入 \(request.tracks.count) 首歌曲。"
    }
}

struct MusicPlaylistRenameSheet: View {
    let request: MusicPlaylistRenameRequest
    let onRename: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(
        request: MusicPlaylistRenameRequest,
        onRename: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onRename = onRename
        self.onCancel = onCancel
        _name = State(initialValue: request.playlist.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "重命名歌单",
                subtitle: "\(request.playlist.itemIDs.count) 首歌曲 · 不会修改歌曲文件",
                systemImage: "pencil.line"
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("歌单名称")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("歌单名称", text: $name)
                    .textFieldStyle(.plain)
                    .glassFormField()
            }
            .padding(16)
            .staticSurfaceBackground(cornerRadius: 18)

            AppSheetActionFooter {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))

                Button {
                    onRename(trimmedName)
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(trimmedName.isEmpty)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.compactWidth)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MusicPlaylistActionsMenu: View {
    @EnvironmentObject private var appState: AppState
    let tracks: [MediaItem]
    var title = "添加到歌单"
    var newPlaylistName = "新建歌单"
    var suggestedName = "新歌单"
    let onCreateNew: (MusicPlaylistCreationRequest) -> Void

    var body: some View {
        Menu(title) {
            // Default: favorite playlist
            Button {
                for track in tracks where !track.favorite {
                    appState.toggleFavorite(track)
                }
            } label: {
                Label("收藏", systemImage: "heart.fill")
            }
            .disabled(tracks.isEmpty)

            Divider()

            Button {
                onCreateNew(
                    MusicPlaylistCreationRequest(
                        tracks: tracks,
                        suggestedName: suggestedName
                    )
                )
            } label: {
                Label(newPlaylistName, systemImage: "plus")
            }

            if !appState.musicPlaylists.isEmpty {
                Divider()
                ForEach(appState.musicPlaylists) { playlist in
                    Button {
                        appState.addMusicTracks(tracks, to: playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                    .disabled(tracks.isEmpty)
                }
            }
        }
        .disabled(tracks.isEmpty && appState.musicPlaylists.isEmpty)
    }
}
