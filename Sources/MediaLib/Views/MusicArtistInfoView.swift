import SwiftUI

/// 音乐详情页的「艺术家简介」区（B4）：拉取并展示艺人头像、文字简介、风格标签与相似艺人。
/// 简介来自 Last.fm（需 API Key），头像来自 Deezer（免密钥）；无任何可展示内容时整块隐藏。
struct MusicArtistInfoView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let artistName: String

    @State private var info: ArtistInfo?
    @State private var isLoading = false
    @State private var loadedArtist: String?
    @State private var bioExpanded = false

    var body: some View {
        Group {
            if let info {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("艺术家", systemImage: "person.crop.square")
                            .font(.headline)
                        Spacer()
                        if appState.hasPlayableTracks(forArtist: info.name) {
                            Button {
                                appState.startArtistRadio(artistName: info.name)
                            } label: {
                                Label("艺人电台", systemImage: "dot.radiowaves.left.and.right")
                            }
                            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32, prominent: true))
                            .help("从本地曲库生成该艺人的连续电台")
                        }
                    }

                    HStack(alignment: .top, spacing: 16) {
                        avatar(info.imageURL)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(info.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                            if !info.tags.isEmpty {
                                tagFlow(info.tags)
                            }
                            if let bio = info.bio, !bio.isEmpty {
                                Text(bio)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(bioExpanded ? nil : 4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Button(bioExpanded ? "收起" : "展开全文") {
                                    withAnimation(AppMotion.fast) { bioExpanded.toggle() }
                                }
                                .buttonStyle(SubtleIconButtonStyle(minSize: 22))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AppColors.selectedGlassTint)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if !info.similar.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("相似艺人")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            tagFlow(Array(info.similar.prefix(8)))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .staticSurfaceBackground(cornerRadius: 18)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在获取艺术家简介…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: artistName) { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard loadedArtist != artistName else { return }
        loadedArtist = artistName
        info = nil
        bioExpanded = false
        isLoading = true
        defer { isLoading = false }
        let service = ArtistInfoService()
        info = try? await service.fetch(
            artist: artistName,
            lastfmAPIKey: appState.settings.lastfmAPIKey,
            language: appState.settings.tmdbLanguage
        )
    }

    private func avatar(_ url: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        avatarPlaceholder
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0.4), lineWidth: 0.8) }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "music.mic")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }

    private func tagFlow(_ items: [String]) -> some View {
        PosterBadgeFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(items, id: \.self) { tag in
                Text(tag)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppColors.cleanPanelFill, in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.10 : 0.30), lineWidth: 0.7) }
                    .foregroundStyle(.secondary)
            }
        }
    }
}
