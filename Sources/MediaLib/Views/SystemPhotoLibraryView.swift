import AppKit
import AVKit
import MediaLibCore
import Photos
import SwiftUI

/// PhotoKit 图片视图。所有请求通过场景级 store 的共享 PHCachingImageManager，
/// 单元离屏时取消请求，iCloud 下载失败时给出明确重试入口。
struct PhotoKitImage: View {
    @EnvironmentObject private var library: SystemPhotoLibraryStore
    let assetID: String
    let targetSize: CGSize
    var contentMode: PHImageContentMode = .aspectFill

    @State private var phase: SystemPhotoResourcePhase = .placeholder
    @State private var requestToken: UUID?
    @State private var retryRevision = 0

    var body: some View {
        ZStack {
            switch phase {
            case .ready(let image, _):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode == .aspectFit ? .fit : .fill)
            case .failed:
                AppColors.cleanPanelFill
                VStack(spacing: 7) {
                    Image(systemName: "icloud.slash")
                        .font(.title3)
                    Button("重试") { retryRevision &+= 1 }
                        .buttonStyle(RepeatedGlassButtonStyle())
                }
                .foregroundStyle(.secondary)
            case .placeholder, .loading:
                AppColors.cleanPanelFill
                VStack(spacing: 7) {
                    if case .loading(let progress) = phase, let progress {
                        ProgressView(value: progress)
                            .frame(width: 58)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if case .loading(let progress) = phase, progress != nil {
                        Text("正在从 iCloud 下载")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: requestKey) { request() }
        .onDisappear {
            library.cancelImageRequest(requestToken)
            requestToken = nil
        }
    }

    private var requestKey: String {
        "\(assetID)|\(Int(targetSize.width))x\(Int(targetSize.height))|\(contentMode.rawValue)|\(retryRevision)"
    }

    private func request() {
        library.cancelImageRequest(requestToken)
        requestToken = library.requestImage(
            assetID: assetID,
            targetSize: targetSize,
            contentMode: contentMode
        ) { nextPhase in
            phase = nextPhase
        }
    }
}

/// 系统照片库录像快速预览。获取 iCloud 视频时显示进度和失败重试，
/// 不改变完整 libmpv 播放器的窗口或设置。
struct SystemPhotoVideoView: View {
    @EnvironmentObject private var library: SystemPhotoLibraryStore
    let assetID: String
    var playbackToggleRevision = 0

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double?
    @State private var errorMessage: String?
    @State private var retryRevision = 0

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.play()
                        isPlaying = true
                    }
                    .onDisappear {
                        player.pause()
                        player.replaceCurrentItem(with: nil)
                        isPlaying = false
                    }
            } else if errorMessage != nil {
                VStack(spacing: 12) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 34))
                    Text("无法读取这段录像")
                        .font(.headline)
                    Text(errorMessage ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("重新下载") { retryRevision &+= 1 }
                        .buttonStyle(LiquidGlassButtonStyle(
                            cornerRadius: 12,
                            horizontalPadding: 14,
                            minHeight: 34,
                            prominent: true
                        ))
                }
                .foregroundStyle(.white)
            } else {
                VStack(spacing: 10) {
                    if let progress {
                        ProgressView(value: progress)
                            .frame(width: 180)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text(progress == nil ? "正在准备录像…" : "正在从 iCloud 下载…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .tint(.white)
            }
        }
        .task(id: "\(assetID)|\(retryRevision)") { await load() }
        .onChange(of: playbackToggleRevision) { _ in
            guard let player else { return }
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
        }
    }

    private func load() async {
        player?.pause()
        player = nil
        progress = nil
        errorMessage = nil
        do {
            let item = try await library.requestPlayerItem(assetID: assetID) { value in
                progress = value
            }
            guard !Task.isCancelled else { return }
            player = AVPlayer(playerItem: item)
            progress = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            progress = nil
        }
    }
}

/// 系统照片内容区。授权、来源选择和批量操作由 AlbumLibraryView 的统一控制条负责。
struct SystemPhotoGridView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: SystemPhotoLibraryStore

    let assets: [SystemPhotoAsset]
    let section: AlbumLibrarySection
    let containerWidth: CGFloat
    let layoutStyle: AlbumLayoutStyle
    let thumbnailSize: AlbumThumbnailSize
    let sortOrder: AlbumSortOrder
    let selectionMode: Bool
    let selectedIDs: Set<String>
    let onActivate: (SystemPhotoAsset) -> Void

    var body: some View {
        Group {
            if !library.isAuthorized {
                authorizationPrompt
            } else if library.isLoading && assets.isEmpty {
                ProgressView("正在读取系统照片…")
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else if assets.isEmpty {
                EmptyStateView(
                    title: "系统照片为空",
                    systemImage: section.systemImage,
                    message: "当前相簿里暂无可显示的\(section == .videos ? "录像" : "照片")。"
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                grid
            }
        }
        .onDisappear { library.stopPreheating() }
    }

    private var grid: some View {
        let groups = library.timelineGroups(for: section, sortOrder: sortOrder)
        return LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title).font(.headline)
                    if layoutStyle == .square {
                        LazyVGrid(columns: squareColumns, spacing: 3) {
                            ForEach(group.assets) { asset in
                                SystemPhotoGridCell(
                                    asset: asset,
                                    cacheTargetSize: squareCacheSize,
                                    selectionMode: selectionMode,
                                    isSelected: selectedIDs.contains(asset.id),
                                    onOpen: { onActivate(asset) }
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .onAppear { preheat(around: asset) }
                            }
                        }
                    } else {
                        JustifiedPhotoGrid(
                            items: group.assets,
                            containerWidth: containerWidth,
                            aspectRatio: Self.aspectRatio(for:),
                            targetRowHeight: thumbnailSize.rowHeight
                        ) { asset, size in
                            SystemPhotoGridCell(
                                asset: asset,
                                cacheTargetSize: CGSize(width: size.width * 2, height: size.height * 2),
                                selectionMode: selectionMode,
                                isSelected: selectedIDs.contains(asset.id),
                                onOpen: { onActivate(asset) }
                            )
                            .onAppear { preheat(around: asset) }
                        }
                    }
                }
            }
        }
    }

    private var squareColumns: [GridItem] {
        [GridItem(.adaptive(
            minimum: thumbnailSize.squareMin,
            maximum: thumbnailSize.squareMin * 1.6
        ), spacing: 3)]
    }

    private var squareCacheSize: CGSize {
        CGSize(width: thumbnailSize.squareMin * 2, height: thumbnailSize.squareMin * 2)
    }

    private func preheat(around asset: SystemPhotoAsset) {
        guard let index = assets.firstIndex(of: asset) else { return }
        let lower = max(index - 12, 0)
        let upper = min(index + 28, assets.count)
        let size = layoutStyle == .square
            ? squareCacheSize
            : CGSize(width: thumbnailSize.rowHeight * 3, height: thumbnailSize.rowHeight * 2)
        library.preheat(
            assetIDs: Array(assets[lower..<upper]).map(\.id),
            targetSize: size,
            contentMode: .aspectFill
        )
    }

    static func aspectRatio(for asset: SystemPhotoAsset) -> Double {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return 1 }
        return Double(asset.pixelWidth) / Double(asset.pixelHeight)
    }

    private var authorizationPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(library.authorizationStatus == .denied
                 ? "未获得照片访问权限"
                 : "接入系统照片图库")
                .font(.title3.weight(.semibold))
            Text(library.authorizationStatus == .denied
                 ? "请在「系统设置 → 隐私与安全性 → 照片」中允许 MediaLIB 访问。返回应用后会自动刷新。"
                 : "授权后即可直接浏览和管理系统「照片」App 中的照片与录像。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if library.authorizationStatus == .denied || library.authorizationStatus == .restricted {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("打开系统设置", systemImage: "gearshape")
                }
                .buttonStyle(LiquidGlassButtonStyle(
                    cornerRadius: 12,
                    horizontalPadding: 16,
                    minHeight: 36,
                    prominent: true
                ))
            } else {
                Button {
                    Task { await library.requestAccessAndLoad(collectionID: library.selectedCollection.id) }
                } label: {
                    Label("允许访问照片", systemImage: "checkmark.shield")
                }
                .buttonStyle(LiquidGlassButtonStyle(
                    cornerRadius: 12,
                    horizontalPadding: 16,
                    minHeight: 36,
                    prominent: true
                ))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

private struct SystemPhotoGridCell: View {
    let asset: SystemPhotoAsset
    let cacheTargetSize: CGSize
    let selectionMode: Bool
    let isSelected: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                PhotoKitImage(assetID: asset.id, targetSize: cacheTargetSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(shape)
                    .overlay { if hovering { shape.fill(.white.opacity(0.16)) } }

                if asset.isVideo {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        if let label = durationLabel {
                            Text(label).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(7)
                }

                if selectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? AppColors.selectedGlassTint : .white)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(7)
                } else if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.pink)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var durationLabel: String? {
        guard asset.duration > 0 else { return nil }
        let total = Int(asset.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
