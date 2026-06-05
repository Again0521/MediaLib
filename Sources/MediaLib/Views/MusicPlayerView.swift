import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import MediaLibCore
import SwiftUI
import UniformTypeIdentifiers

struct MusicPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let controller: MpvPlayerController
    let transitionNamespace: Namespace.ID
    let onRequestMinimize: () -> Void

    @State private var lyrics: String = "暂无歌词"
    @State private var timedLyrics: [TimedLyricLine] = []
    @State private var lyricTimingSource: LyricTimingSource = .estimated
    @State private var albumPalette = AlbumColorPalette.fallback
    @State private var isFetchingLyrics = false
    @State private var userIsBrowsingLyrics = false
    @State private var lyricsLoadTask: Task<Void, Never>?
    @State private var lyricsAlignmentTask: Task<Void, Never>?
    @State private var paletteLoadTask: Task<Void, Never>?
    @State private var backdropAnimationTask: Task<Void, Never>?
    @State private var entranceAnimationTask: Task<Void, Never>?
    @State private var backdropAnimationReady = false
    @State private var glassLayerReady = false  // 重型封面纹理延迟出现；轻量玻璃底从首帧常驻，避免断层
    @State private var entrancePhase = 0
    @State private var resumeAutoScrollTask: Task<Void, Never>?

    private var currentItem: MediaItem {
        if let active = appState.activePlayerItem, active.type == .music {
            return active
        }
        return item
    }

    private var hasDisplayLyrics: Bool {
        if !timedLyrics.isEmpty { return true }
        let cleaned = Self.cleanedLyrics(lyrics).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        return !cleaned.hasPrefix("暂无歌词") &&
        !cleaned.hasPrefix("没有获取到") &&
        !cleaned.hasPrefix("没有匹配") &&
        !cleaned.hasPrefix("在线歌词获取失败")
    }

    var body: some View {
        // 整窗底层由 expandedPlayer 内部的 MetalAlbumBackdropView 铺满：
        // 它是一块覆盖标题栏区域的【不透明】专辑取色底（符合原方案"第一层不透明"）。
        // 性能根因修复：之前用 behindWindow 整窗毛玻璃会让 WindowServer 为整窗持有一份模糊后的桌面副本，
        // 内存飙到 400M+ 并拖累系统。改为不透明底色后 WindowServer 不再做整窗离屏模糊；磨砂质感由上层
        // 歌词卡/控制栏的局部 material 提供（局部、面积小，开销可控）。底色不透明也彻底盖住标题栏白条。
        ZStack {
            expandedPlayer
        }
        .ignoresSafeArea(.all)
        .onAppear {
            startEntranceAnimation()
            scheduleBackdropAnimation()
            loadLyricsForCurrentItem()
            loadAlbumPalette()
        }
        .onChange(of: appState.activePlayerItem?.id) { _ in
            // 切歌不再重跑 scheduleBackdropAnimation：它会把 glassLayerReady 先置 false 再置 true，
            // 令整窗封面/玻璃底层瞬间卸载再挂载，正是切歌时顶部颜色断层（取色色斑随之闪没再现）的来源。
            // 玻璃底层全程常驻，封面与取色由下面的 loadAlbumPalette / .task(id: posterPath) 直接平滑换图。
            loadLyricsForCurrentItem()
            loadAlbumPalette()
        }
        .onChange(of: currentItem.posterPath) { _ in
            loadAlbumPalette()
        }
        .onChange(of: appState.settings.lyricSyncAlgorithm) { _ in
            setLyrics(lyrics)
        }
        .onDisappear {
            lyricsLoadTask?.cancel()
            lyricsAlignmentTask?.cancel()
            paletteLoadTask?.cancel()
            backdropAnimationTask?.cancel()
            entranceAnimationTask?.cancel()
            resumeAutoScrollTask?.cancel()
            glassLayerReady = false
            backdropAnimationReady = false
            entrancePhase = 0
        }
        .overlay {
            KeyCaptureView { key in
                if key == .escape {
                    close()
                } else if key == .space {
                    controller.togglePlay()
                } else if key == .leftArrow {
                    controller.seek(by: -15)
                } else if key == .rightArrow {
                    controller.seek(by: 15)
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    private var expandedPlayer: some View {
        GeometryReader { geometry in
            let layout = MusicExpandedLayout(size: geometry.size)
            let lyricsPanelReady = reduceMotion || entrancePhase >= 1

            ZStack(alignment: .topLeading) {
                MetalAlbumBackdropView(
                    posterPath: currentItem.posterPath,
                    title: currentItem.title,
                    palette: albumPalette,
                    artworkReady: glassLayerReady,
                    albumLightCenter: layout.albumLightCenter,
                    glassIntensity: glassLayerReady ? 1.0 : 0.78,
                    reduceMotion: reduceMotion,
                    dynamicEffectsEnabled: false,
                    colorScheme: colorScheme
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
                .zIndex(0)

                ZStack(alignment: .topLeading) {
                    if layout.stackedLayout {
                        ScrollView {
                            VStack(spacing: 28) {
                                musicIdentityPanel(posterSize: min(layout.posterSize, 230))
                                    .frame(maxWidth: 360)
                                    .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                                    .offset(y: reduceMotion || entrancePhase >= 1 ? 0 : 18)
                                    .scaleEffect(reduceMotion || entrancePhase >= 1 ? 1 : 0.982)

                                if lyricsPanelReady {
                                    lyricsPanel
                                        .frame(height: layout.stackedLyricsHeight)
                                        .opacity(reduceMotion || entrancePhase >= 2 ? 1 : 0)
                                        .offset(y: reduceMotion || entrancePhase >= 2 ? 0 : 22)
                                        .scaleEffect(reduceMotion || entrancePhase >= 2 ? 1 : 0.986)
                                } else {
                                    Color.clear
                                        .frame(height: layout.stackedLyricsHeight)
                                }
                            }
                            .padding(.horizontal, layout.sideInset)
                            .padding(.top, 82)
                            .padding(.bottom, layout.verticalInset)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        musicIdentityPanel(posterSize: layout.posterSize)
                            .frame(width: layout.leftRect.width, height: layout.leftRect.height, alignment: .center)
                            .offset(x: layout.leftRect.minX, y: layout.leftRect.minY)
                            .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                            .scaleEffect(reduceMotion || entrancePhase >= 1 ? 1 : 0.982, anchor: .center)

                        if lyricsPanelReady {
                            lyricsPanel
                                .frame(width: layout.lyricsRect.width, height: layout.lyricsRect.height)
                                .offset(x: layout.lyricsRect.minX, y: layout.lyricsRect.minY)
                                .opacity(reduceMotion || entrancePhase >= 2 ? 1 : 0)
                                .scaleEffect(reduceMotion || entrancePhase >= 2 ? 1 : 0.986, anchor: .center)
                        }
                    }

                    floatingMinimizeButton
                        .frame(width: layout.minimizeButtonRect.width, height: layout.minimizeButtonRect.height)
                        .position(x: layout.minimizeButtonRect.midX, y: layout.minimizeButtonRect.midY)
                        .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                        .transition(.opacity)
                        .zIndex(40)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .glassPerformanceMode(.full)
                .zIndex(2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 外层不再重复铺同色全屏底：内部背景已完全覆盖，减少一层全窗绘制。
    }

    private func musicIdentityPanel(posterSize: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            MusicExpandedArtwork(
                item: currentItem,
                controller: controller,
                palette: albumPalette,
                posterSize: posterSize
            )
            .frame(width: posterSize, height: posterSize)

            VStack(spacing: 7) {
                Text(currentItem.title)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    if let artist = currentItem.artist, !artist.isEmpty {
                        Text(artist)
                    }
                    if currentItem.artist?.isEmpty == false, currentItem.album?.isEmpty == false {
                        Text("·").foregroundStyle(.primary.opacity(0.4))
                    }
                    if let album = currentItem.album, !album.isEmpty {
                        Text(album)
                    }
                    if (currentItem.artist?.isEmpty ?? true) && (currentItem.album?.isEmpty ?? true) {
                        Text("未知艺人")
                    }
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            }
            .frame(maxHeight: 82)

            MusicExpandedControls(item: currentItem, controller: controller, palette: albumPalette)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private var floatingMinimizeButton: some View {
        Button {
            onRequestMinimize()
        } label: {
            MusicChromeButtonContent(systemImage: "chevron.down", palette: albumPalette)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help("最小化播放器")
        .accessibilityLabel("最小化播放器")
    }

    private var lyricsPanel: some View {
        MusicExpandedLyricsPanel(
            controller: controller,
            lyrics: lyrics,
            timedLyrics: timedLyrics,
            timingSource: lyricTimingSource,
            hasDisplayLyrics: hasDisplayLyrics,
            isFetchingLyrics: isFetchingLyrics,
            palette: albumPalette,
            userIsBrowsingLyrics: $userIsBrowsingLyrics,
            onFetchLyrics: {
                Task { await fetchLyrics() }
            },
            onPauseAutoScroll: pauseLyricAutoScroll
        )
    }

    private func close() {
        resumeAutoScrollTask?.cancel()
        Task { @MainActor in
            if appState.activePlayerItem?.id == currentItem.id {
                appState.activePlayerItem = nil
            }
        }
    }

    private func setLyrics(_ text: String) {
        lyricsAlignmentTask?.cancel()
        lyrics = text
        let parsed = TimedLyricLine.parse(text)
        let displayLines = LyricEstimatedTimingBuilder.lines(
            from: parsed,
            algorithm: appState.settings.lyricSyncAlgorithm
        )
        timedLyrics = displayLines
        lyricTimingSource = TimedLyricLine.bestTimingSource(in: displayLines)
        scheduleLyricAlignmentIfNeeded(lyricsText: text, parsedLines: parsed)
    }

    private func scheduleLyricAlignmentIfNeeded(lyricsText: String, parsedLines: [TimedLyricLine]) {
        let algorithm = appState.settings.lyricSyncAlgorithm
        guard algorithm.usesBackgroundAlignment,
              TimedLyricLine.bestTimingSource(in: parsedLines) == .estimated,
              !parsedLines.isEmpty,
              let filePath = currentItem.filePath,
              !currentItem.isRemoteResource,
              FileManager.default.fileExists(atPath: filePath) else { return }

        let targetItem = currentItem
        lyricsAlignmentTask = Task {
            let aligned = await Task.detached(priority: .utility) {
                await LyricAlignmentService.alignedLines(
                    for: targetItem,
                    lyricsText: lyricsText,
                    estimatedLines: parsedLines,
                    algorithm: algorithm
                )
            }.value
            guard let aligned else { return }
            await MainActor.run {
                guard !Task.isCancelled,
                      appState.activePlayerItem?.id == targetItem.id,
                      appState.settings.lyricSyncAlgorithm == algorithm,
                      lyrics == lyricsText else { return }
                withAnimation(AppMotion.standard) {
                    timedLyrics = aligned
                    lyricTimingSource = TimedLyricLine.bestTimingSource(in: aligned)
                }
            }
        }
    }

    private func loadLyricsForCurrentItem() {
        lyricsLoadTask?.cancel()
        let targetItem = currentItem
        lyricsLoadTask = Task { @MainActor in
            setLyrics("暂无歌词")
            let text = await Task.detached(priority: .utility) {
                await Self.loadLyrics(for: targetItem)
            }.value
            guard !Task.isCancelled,
                  appState.activePlayerItem?.id == targetItem.id else {
                return
            }
            setLyrics(text)
            if text.hasPrefix("暂无歌词") {
                await fetchLyrics()
            }
        }
    }

    private func loadAlbumPalette() {
        paletteLoadTask?.cancel()
        let targetItem = currentItem
        let targetItemID = targetItem.id
        let targetPath = targetItem.posterPath
        // 切歌时不再先把取色重置成 .fallback——那会让整窗取色（含顶部多彩色斑）瞬间塌成灰底再恢复，
        // 正是“顶部颜色断层”。改为保留上一首取色直到新取色就绪，再平滑过渡，缺图时缓存自然返回 .fallback。
        paletteLoadTask = Task {
            let palette = await AlbumPaletteCache.palette(for: targetPath)
            await MainActor.run {
                guard !Task.isCancelled,
                      appState.activePlayerItem?.id == targetItemID else { return }
                withAnimation(AppMotion.standard) {
                    albumPalette = palette
                }
            }
        }
    }

    private func startEntranceAnimation() {
        entranceAnimationTask?.cancel()
        guard !reduceMotion else {
            entrancePhase = 2
            return
        }
        entrancePhase = 0
        entranceAnimationTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
            withAnimation(AppMotion.panel) {
                entrancePhase = 1
            }
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            withAnimation(AppMotion.panel) {
                entrancePhase = 2
            }
        }
    }

    private func scheduleBackdropAnimation() {
        backdropAnimationTask?.cancel()
        backdropAnimationReady = false
        glassLayerReady = false
        backdropAnimationTask = Task { @MainActor in
            // 重型 SwiftUI blur 已经降为低分辨率 CA 纹理；首帧挂载能避免展开完成后再插入图层造成断层和拖动峰值。
            await Task.yield()
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                glassLayerReady = true
                backdropAnimationReady = true
            }
        }
    }

    nonisolated private static func loadLyrics(for item: MediaItem) async -> String {
        guard let filePath = item.filePath else { return "暂无歌词" }
        let url = URL(fileURLWithPath: filePath)
        let directory = url.deletingLastPathComponent()
        let basename = url.deletingPathExtension().lastPathComponent
        let candidates = [
            directory.appendingPathComponent("\(basename).lrc"),
            directory.appendingPathComponent("\(basename).txt")
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let text = try? String(contentsOf: candidate, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        let metadata = await AudioMetadataReader().metadata(for: url)
        if let embeddedLyrics = metadata.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !embeddedLyrics.isEmpty {
            return embeddedLyrics
        }

        return "暂无歌词\n\n可将同名 .lrc 或 .txt 歌词文件放在歌曲旁边，MediaLIB 会自动显示。"
    }

    fileprivate static func cleanedLyrics(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"\[[0-9:.]+\]"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"<[0-9:.]+>"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    private func pauseLyricAutoScroll() {
        if !userIsBrowsingLyrics {
            withAnimation(AppMotion.hover) {
                userIsBrowsingLyrics = true
            }
        }
        resumeAutoScrollTask?.cancel()
        resumeAutoScrollTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            withAnimation(AppMotion.standard) {
                userIsBrowsingLyrics = false
            }
        }
    }

    @MainActor
    private func fetchLyrics() async {
        let item = currentItem
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        isFetchingLyrics = true
        defer { isFetchingLyrics = false }

        do {
            var components = URLComponents(string: "https://lrclib.net/api/search")
            components?.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: item.artist),
                URLQueryItem(name: "album_name", value: item.album)
            ].filter { $0.value?.isEmpty == false }
            guard let url = components?.url else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("MediaLIB/1.0 local macOS media library", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                setLyrics("没有获取到在线歌词。")
                return
            }
            let results = try JSONDecoder().decode([LRCLibLyrics].self, from: data)
            guard let best = results.first,
                  let lyricText = best.syncedLyrics ?? best.plainLyrics,
                  !lyricText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                setLyrics("没有匹配的在线歌词。")
                return
            }
            setLyrics(lyricText)
            saveLyricsSidecar(lyricText)
        } catch {
            setLyrics("在线歌词获取失败：\(error.localizedDescription)")
        }
    }

    private func saveLyricsSidecar(_ text: String) {
        guard let filePath = currentItem.filePath else { return }
        let url = URL(fileURLWithPath: filePath)
        let outputURL = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).lrc")
        try? text.write(to: outputURL, atomically: true, encoding: .utf8)
    }
}

private struct MusicPlayerPointerLightScope: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color
    let radius: CGFloat
    let intensity: Double
    var updateInterval: TimeInterval = 1.0 / 30.0
    var minDistance: CGFloat = 6.0
    @State private var pointerLocation: CGPoint?
    @State private var globalFrame: CGRect = .zero
    @State private var lastPointerLocation: CGPoint?
    @State private var lastPointerUpdate = Date.distantPast

    private var pointerContext: LiquidPointerContext? {
        guard !reduceMotion,
              let pointerLocation,
              globalFrame.width > 0,
              globalFrame.height > 0 else { return nil }
        return LiquidPointerContext(
            globalLocation: CGPoint(
                x: globalFrame.minX + pointerLocation.x,
                y: globalFrame.minY + pointerLocation.y
            ),
            radius: radius,
            tint: tint,
            intensity: intensity
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(\.liquidPointerContext, pointerContext)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            globalFrame = proxy.frame(in: .global)
                        }
                        .onChange(of: proxy.size) { _ in
                            globalFrame = proxy.frame(in: .global)
                        }
                }
                .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                guard !reduceMotion else {
                    pointerLocation = nil
                    lastPointerLocation = nil
                    return
                }
                switch phase {
                case .active(let point):
                    let now = Date()
                    guard PointerHoverThrottle.shouldUpdate(
                        from: lastPointerLocation,
                        previousUpdate: lastPointerUpdate,
                        to: point,
                        now: now,
                        minInterval: updateInterval,
                        minDistance: minDistance
                    ) else { return }
                    pointerLocation = point
                    lastPointerLocation = point
                    lastPointerUpdate = now
                case .ended:
                    withAnimation(AppMotion.fast) {
                        pointerLocation = nil
                        lastPointerLocation = nil
                    }
                }
            }
    }
}

/// 封面柔光：多层不同色相的径向光斑叠加 + 高斯模糊，向四周自然扩散，模拟封面在发光。
/// 不裁剪、远大于封面，呈现真实柔和的 bloom，而不是一个方框。
/// 封面发光：把封面本身放大、强模糊后作为光源铺在封面四周，并用径向蒙版让光从封面边缘
/// 向外均匀、柔和地渐隐。这样每个方向发出的光自动等于该侧封面的颜色（物理正确、不单调、
/// 四周均匀），而不是固定几个色斑。封面缺失时回退到调色板多色光。
private struct AlbumSoftBloomGlow: View {
    let posterPath: String?
    let palette: AlbumColorPalette
    let glowStrength: Double
    let glowOpacity: Double
    let colorScheme: ColorScheme
    @State private var bloomImage: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            if let bloomImage {
                bloomContent(image: bloomImage, side: side)
            } else {
                fallbackContent(side: side)
                    .blur(radius: side * 0.06)
            }
        }
        .task(id: posterPath ?? "") { await loadBloom() }
    }

    private func bloomContent(image: NSImage, side: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .opacity(glowOpacity)
            .blendMode(.screen)
            .shadow(color: palette.glowPrimary.color.opacity(glowOpacity * 0.55), radius: side * 0.028)
    }

    private func fallbackContent(side: CGFloat) -> some View {
        fallbackGradient
            .opacity(glowOpacity)
            .mask(bloomMask(side: side))
            .blendMode(.plusLighter)
    }

    private func bloomMask(side: CGFloat) -> some View {
        // 断层根因：原 endRadius = side*0.70，而方形发光图在 side*0.5（四边中点）处就被图像边界裁断，
        // 此时蒙版仍约 36% 不透明 → 四边出现明显硬切（断层）。把 endRadius 收到 side*0.5，让发光在抵达
        // 方框边界前就完全淡出到透明（四角在 0.707*side > endRadius 也已透明），整圈无硬边、无断层。
        RadialGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black.opacity(0.92), location: 0.34),
                .init(color: .black.opacity(0.60), location: 0.58),
                .init(color: .black.opacity(0.28), location: 0.78),
                .init(color: .black.opacity(0.08), location: 0.92),
                .init(color: .clear, location: 1.0)
            ],
            center: .center,
            startRadius: side * 0.04,
            endRadius: side * 0.5
        )
    }

    private var fallbackGradient: some View {
        ZStack {
            RadialGradient(colors: [palette.glowPrimary.color, .clear], center: .center, startRadius: 0, endRadius: 260)
            RadialGradient(colors: [palette.glowSecondary.color.opacity(0.7), .clear], center: UnitPoint(x: 0.7, y: 0.32), startRadius: 0, endRadius: 240)
            RadialGradient(colors: [palette.glowAccent.color.opacity(0.7), .clear], center: UnitPoint(x: 0.3, y: 0.7), startRadius: 0, endRadius: 240)
        }
    }

    @MainActor
    private func loadBloom() async {
        guard loadedPath != posterPath else { return }
        let path = posterPath
        loadedPath = path
        // 同理：保留上一首的封面柔光直到新图就绪再替换，切歌不闪。仅新歌无封面时清空。
        guard let path else { bloomImage = nil; return }
        let texture = await Task.detached(priority: .utility) {
            // 预先生成更细腻的低分辨率柔光纹理，避免给大尺寸展开页重新挂实时 blur，
            // 同时把运行时 saturation 和径向 alpha 蒙版烤进图片，减少展开页持续合成层。
            let base = ArtworkImageCache.image(path: path, targetSize: CGSize(width: 240, height: 240))
            return SendableMusicBackdropArtworkImage(AlbumBloomImageBake.bakedGlowImage(from: base) ?? base)
        }.value
        guard loadedPath == path else { return }
        bloomImage = texture.image
    }
}

private struct AlbumGlowRGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color {
        Color(red: r, green: g, blue: b)
    }

    static func from(_ color: NSColor) -> AlbumGlowRGB {
        let device = color.usingColorSpace(.deviceRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        device.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return AlbumGlowRGB(r: Double(red), g: Double(green), b: Double(blue)).cleanedForGlow()
    }

    func cleanedForGlow() -> AlbumGlowRGB {
        let nsColor = NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let boostedSaturation: CGFloat
        if saturation < 0.055 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(max(saturation * 1.18, 0.12), 0.78)
        }
        let cleanedBrightness = min(max(brightness, 0.42), 0.92)
        let cleaned = NSColor(deviceHue: hue, saturation: boostedSaturation, brightness: cleanedBrightness, alpha: 1)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        cleaned.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return AlbumGlowRGB(r: Double(red), g: Double(green), b: Double(blue))
    }
}

private struct AlbumEdgeGlowSample: Equatable, Sendable {
    var top: AlbumGlowRGB
    var bottom: AlbumGlowRGB
    var left: AlbumGlowRGB
    var right: AlbumGlowRGB
    var topLeft: AlbumGlowRGB
    var topRight: AlbumGlowRGB
    var bottomLeft: AlbumGlowRGB
    var bottomRight: AlbumGlowRGB

    static func fallback(from palette: AlbumColorPalette) -> AlbumEdgeGlowSample {
        AlbumEdgeGlowSample(
            top: AlbumGlowRGB.from(palette.glowSecondary.nsColor),
            bottom: AlbumGlowRGB.from(palette.glowAccent.nsColor),
            left: AlbumGlowRGB.from(palette.glowPrimary.nsColor),
            right: AlbumGlowRGB.from(palette.glowSecondary.nsColor),
            topLeft: AlbumGlowRGB.from(palette.glowPrimary.nsColor),
            topRight: AlbumGlowRGB.from(palette.glowSecondary.nsColor),
            bottomLeft: AlbumGlowRGB.from(palette.glowAccent.nsColor),
            bottomRight: AlbumGlowRGB.from(palette.glowPrimary.nsColor)
        )
    }
}

private enum AlbumEdgeGlowSampler {
    static func sample(from image: NSImage?) -> AlbumEdgeGlowSample? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 4, extent.height > 4 else { return nil }
        let strip = max(4, min(extent.width, extent.height) * 0.14)
        let corner = max(strip, min(extent.width, extent.height) * 0.24)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

        func average(_ rect: CGRect) -> AlbumGlowRGB {
            let clamped = rect.intersection(extent)
            guard !clamped.isNull, let filter = CIFilter(name: "CIAreaAverage") else {
                return AlbumGlowRGB(r: 0.7, g: 0.7, b: 0.7)
            }
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: clamped), forKey: kCIInputExtentKey)
            var pixel = [UInt8](repeating: 0, count: 4)
            if let output = filter.outputImage {
                context.render(
                    output,
                    toBitmap: &pixel,
                    rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
            }
            return AlbumGlowRGB(
                r: Double(pixel[0]) / 255.0,
                g: Double(pixel[1]) / 255.0,
                b: Double(pixel[2]) / 255.0
            )
            .cleanedForGlow()
        }

        return AlbumEdgeGlowSample(
            top: average(CGRect(x: extent.minX, y: extent.maxY - strip, width: extent.width, height: strip)),
            bottom: average(CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: strip)),
            left: average(CGRect(x: extent.minX, y: extent.minY, width: strip, height: extent.height)),
            right: average(CGRect(x: extent.maxX - strip, y: extent.minY, width: strip, height: extent.height)),
            topLeft: average(CGRect(x: extent.minX, y: extent.maxY - corner, width: corner, height: corner)),
            topRight: average(CGRect(x: extent.maxX - corner, y: extent.maxY - corner, width: corner, height: corner)),
            bottomLeft: average(CGRect(x: extent.minX, y: extent.minY, width: corner, height: corner)),
            bottomRight: average(CGRect(x: extent.maxX - corner, y: extent.minY, width: corner, height: corner))
        )
    }
}

private enum AlbumDirectionalGlowBake {
    static func bakedEdgeGlowImage(from image: NSImage?) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return nil }

        let source = CIImage(cgImage: cgImage)
        let sourceExtent = source.extent
        guard sourceExtent.width > 4, sourceExtent.height > 4 else { return nil }
        let cropSide = min(sourceExtent.width, sourceExtent.height)
        let square = source.cropped(to: CGRect(
            x: sourceExtent.midX - cropSide / 2,
            y: sourceExtent.midY - cropSide / 2,
            width: cropSide,
            height: cropSide
        ))

        let canvasSide: CGFloat = 760
        let coverSide: CGFloat = 220
        let strip: CGFloat = 22
        let scale = coverSide / cropSide
        let origin = CGPoint(x: (canvasSide - coverSide) / 2, y: (canvasSide - coverSide) / 2)
        let placed = square
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        let canvasExtent = CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide)
        var emission = CIImage(color: .clear).cropped(to: canvasExtent)

        func composite(_ image: CIImage, over base: CIImage) -> CIImage {
            image.composited(over: base)
        }

        let topStrip = placed.cropped(to: CGRect(x: origin.x, y: origin.y + coverSide - strip, width: coverSide, height: strip))
        let bottomStrip = placed.cropped(to: CGRect(x: origin.x, y: origin.y, width: coverSide, height: strip))
        let leftStrip = placed.cropped(to: CGRect(x: origin.x, y: origin.y, width: strip, height: coverSide))
        let rightStrip = placed.cropped(to: CGRect(x: origin.x + coverSide - strip, y: origin.y, width: strip, height: coverSide))

        for step in 0..<7 {
            let distance = CGFloat(step) * strip * 1.9
            let alpha = max(0.10, 1.0 - CGFloat(step) * 0.13)
            let filter = CIFilter.colorMatrix()
            filter.rVector = CIVector(x: alpha, y: 0, z: 0, w: 0)
            filter.gVector = CIVector(x: 0, y: alpha, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: alpha, w: 0)
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
            filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)

            filter.inputImage = topStrip.transformed(by: CGAffineTransform(translationX: 0, y: distance))
            if let output = filter.outputImage { emission = composite(output, over: emission) }
            filter.inputImage = bottomStrip.transformed(by: CGAffineTransform(translationX: 0, y: -distance))
            if let output = filter.outputImage { emission = composite(output, over: emission) }
            filter.inputImage = leftStrip.transformed(by: CGAffineTransform(translationX: -distance, y: 0))
            if let output = filter.outputImage { emission = composite(output, over: emission) }
            filter.inputImage = rightStrip.transformed(by: CGAffineTransform(translationX: distance, y: 0))
            if let output = filter.outputImage { emission = composite(output, over: emission) }
        }

        let saturated: CIImage
        let colorFilter = CIFilter.colorControls()
        colorFilter.inputImage = emission
        colorFilter.saturation = 1.22
        colorFilter.brightness = -0.035
        colorFilter.contrast = 1.02
        saturated = colorFilter.outputImage ?? emission

        let blurred: CIImage
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = saturated
        blurFilter.radius = 42
        blurred = (blurFilter.outputImage ?? saturated).cropped(to: canvasExtent)

        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        guard let output = context.createCGImage(blurred, from: canvasExtent) else { return nil }
        return NSImage(cgImage: output, size: CGSize(width: canvasSide, height: canvasSide))
    }
}

/// 封面物理发光场：从封面四边与四角采样颜色，让每个方向按该侧真实颜色向外扩散。
/// 这是局部封面层效果，不参与整页 blend，也不依赖全屏鼠标状态。
// MARK: - 封面高斯模糊发光层

/// 将专辑封面经重度高斯模糊 + 径向 alpha 渐隐后放在封面后方，产生与专辑色调完全匹配的物理柔光。
/// 关键：烘焙阶段已把"中心不透明→边缘透明"的径向渐隐烤进图片的 alpha 通道，
/// 因此放大显示时光从中心向四周平滑淡出，绝不出现硬边/放射状断层。颜色直接来自封面本身，零偏移。
/// 播放时展开（glowScale→1.0），暂停时收起（glowScale→0.5），配合 syncPlaybackVisuals 级联动画。
private struct AlbumBlurredCoverGlowLayer: View {
    let posterPath: String?
    let palette: AlbumColorPalette
    let glowStrength: Double
    let colorScheme: ColorScheme
    @State private var blurredImage: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // 白色封面（vibrancy 低）整体调暗发光，避免白光过曝；彩色封面保持明亮。
            let vib = palette.vibrancy
            let normalDamp = 0.42 + vib * 0.58
            // plusLighter 自发光层只在彩色封面启用（白色封面用它会直接叠白过曝）。
            let bloomDamp = vib * vib
            Group {
                if let blurredImage {
                    // 双层：normal 提供准确专辑色染色 + plusLighter 极轻叠加模拟"自发光"的亮度提升。
                    // 因图片自带径向 alpha（边缘已透明），plusLighter 只在封面四周的有色区轻微提亮，
                    // 远处透明不会叠白；近封面处更通透明亮，physical glow 感更强。
                    Image(nsImage: blurredImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: side, height: side)
                        .opacity((colorScheme == .dark ? 1.0 : 0.92) * glowStrength * normalDamp)
                    Image(nsImage: blurredImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: side, height: side)
                        .opacity((colorScheme == .dark ? 0.22 : 0.16) * glowStrength * bloomDamp)
                        .blendMode(.plusLighter)
                } else {
                    // 图像未加载前用调色板径向渐变兜底（同样平滑淡出）
                    RadialGradient(
                        colors: [
                            palette.glowPrimary.color.opacity(0.50),
                            palette.glowSecondary.color.opacity(0.26),
                            .clear
                        ],
                        center: .center, startRadius: 0, endRadius: side * 0.46
                    )
                    .frame(width: side, height: side)
                    .opacity(glowStrength)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: posterPath ?? "") { await loadBlurredImage() }
    }

    @MainActor
    private func loadBlurredImage() async {
        let path = posterPath
        guard loadedPath != path else { return }
        loadedPath = path
        guard let path else { blurredImage = nil; return }
        let result = await Task.detached(priority: .utility) {
            let base = ArtworkImageCache.image(
                path: path,
                targetSize: CGSize(width: 320, height: 320)
            )
            return SendableMusicBackdropArtworkImage(AlbumGlowBlurBake.baked(from: base) ?? base)
        }.value
        guard loadedPath == path else { return }
        blurredImage = result.image
    }
}

/// 封面发光纹理烘焙：饱和度提升 → 重度高斯模糊 → 径向 alpha 渐隐蒙版。
/// 径向渐隐是消除断层的核心：中心保持原色不透明，向边缘 smoothstep 平滑淡到透明，
/// 放大后光晕自然消散，无任何硬边。预生成静态纹理，运行时零开销。
private enum AlbumGlowBlurBake {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func baked(from image: NSImage?) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }

        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 8, extent.height > 8 else { return image }

        // 1) 提升饱和度，让发光颜色更鲜明（避免低饱和专辑发出平淡的灰光），不改变色相
        let saturated: CIImage
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(input, forKey: kCIInputImageKey)
            colorFilter.setValue(1.46, forKey: kCIInputSaturationKey)
            colorFilter.setValue(0.02, forKey: kCIInputBrightnessKey)
            colorFilter.setValue(1.0, forKey: kCIInputContrastKey)
            saturated = colorFilter.outputImage ?? input
        } else {
            saturated = input
        }

        // 2) 重度高斯模糊（半径相对图宽，保证不同尺寸一致的柔和度）
        let blurred: CIImage
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(saturated.clampedToExtent(), forKey: kCIInputImageKey)
            blurFilter.setValue(Double(extent.width) * 0.15, forKey: kCIInputRadiusKey)
            blurred = (blurFilter.outputImage ?? saturated).cropped(to: extent)
        } else {
            blurred = saturated
        }

        // 3) 径向渐变蒙版（白心→黑边），用 CIBlendWithMask 按亮度抠出柔和光晕：
        //    radius0 中心保持原色，radius1 处淡到透明；四角（>0.5*width 半径）已完全透明。
        let masked: CIImage
        if let gradient = CIFilter(name: "CIRadialGradient"),
           let blend = CIFilter(name: "CIBlendWithMask") {
            gradient.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
            gradient.setValue(Double(extent.width) * 0.12, forKey: "inputRadius0")
            gradient.setValue(Double(extent.width) * 0.54, forKey: "inputRadius1")
            gradient.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
            gradient.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor1")
            let mask = (gradient.outputImage ?? CIImage(color: .white)).cropped(to: extent)
            blend.setValue(blurred, forKey: kCIInputImageKey)
            blend.setValue(CIImage(color: .clear).cropped(to: extent), forKey: kCIInputBackgroundImageKey)
            blend.setValue(mask, forKey: kCIInputMaskImageKey)
            masked = (blend.outputImage ?? blurred).cropped(to: extent)
        } else {
            masked = blurred
        }

        guard let output = context.createCGImage(masked, from: extent) else { return image }
        return NSImage(cgImage: output, size: extent.size)
    }
}

// MARK: - 原始边缘取色发光（保留供参考，不再用于主发光层）

private struct AlbumPhysicalEdgeGlow: View {
    let posterPath: String?
    let palette: AlbumColorPalette
    let glowStrength: Double
    let glowOpacity: Double
    let colorScheme: ColorScheme
    @State private var sample: AlbumEdgeGlowSample?
    @State private var edgeGlowImage: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        GeometryReader { geo in
            // 宽帧时 side 以宽度为准，让右侧有充足空间
            let side = min(geo.size.width, geo.size.height)
            let wideSide = geo.size.width  // 用于烘焙图全帧铺开
            let colors = sample ?? .fallback(from: palette)
            ZStack {
                if let edgeGlowImage {
                    // 改用 plusLighter：在亮色暖金背景上 screen 几乎不可见；plusLighter 直接叠加亮度，
                    // 无论背景亮度如何都能产生可见的光晕。降低不透明度避免过曝。
                    Image(nsImage: edgeGlowImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: wideSide, height: side)
                        .opacity(glowOpacity * glowStrength * (colorScheme == .dark ? 0.54 : 0.42))
                        .blendMode(.plusLighter)
                }
                glowField(sample: colors, side: side, wideSide: wideSide)
            }
            .frame(width: wideSide, height: side)
        }
        .task(id: posterPath ?? "") { await loadSample() }
    }

    private func glowField(sample: AlbumEdgeGlowSample, side: CGFloat, wideSide: CGFloat) -> some View {
        // 以帧的实际宽度推算封面位置：封面大小固定（帧高的 1/3.6），但帧更宽让右侧有延伸空间。
        let coverSide = side / 3.6
        let centerX = wideSide / 2
        let centerY = side / 2
        // reach 基于高度计算，但向右的 sideGlow 会利用额外的宽度
        let reach = side * 0.46
        let nearReach = side * 0.22
        let baseOpacity = glowOpacity * (colorScheme == .dark ? 1.10 : 0.98)
        // 向右的光应更强（方向是歌词卡），乘以 1.5 加强右侧定向照射
        let rightOpacity = baseOpacity * 1.52
        return ZStack {
            sideGlow(sample.top.color, edge: .top, side: side, coverSide: coverSide, reach: reach, opacity: baseOpacity * 0.86)
                .position(x: centerX, y: centerY - coverSide / 2 - reach * 0.42)
            sideGlow(sample.bottom.color, edge: .bottom, side: side, coverSide: coverSide, reach: reach, opacity: baseOpacity * 0.92)
                .position(x: centerX, y: centerY + coverSide / 2 + reach * 0.42)
            sideGlow(sample.left.color, edge: .left, side: side, coverSide: coverSide, reach: reach, opacity: baseOpacity * 0.72)
                .position(x: centerX - coverSide / 2 - reach * 0.42, y: centerY)
            // 右侧：更强的定向发光，模拟封面光照射向歌词卡
            sideGlow(sample.right.color, edge: .right, side: side, coverSide: coverSide, reach: reach * 1.35, opacity: rightOpacity)
                .position(x: centerX + coverSide / 2 + reach * 0.52, y: centerY)

            cornerGlow(sample.topLeft.color, side: side, reach: nearReach, opacity: baseOpacity * 0.62)
                .position(x: centerX - coverSide / 2, y: centerY - coverSide / 2)
            cornerGlow(sample.topRight.color, side: side, reach: nearReach, opacity: baseOpacity * 0.68)
                .position(x: centerX + coverSide / 2, y: centerY - coverSide / 2)
            cornerGlow(sample.bottomLeft.color, side: side, reach: nearReach, opacity: baseOpacity * 0.64)
                .position(x: centerX - coverSide / 2, y: centerY + coverSide / 2)
            cornerGlow(sample.bottomRight.color, side: side, reach: nearReach, opacity: baseOpacity * 0.70)
                .position(x: centerX + coverSide / 2, y: centerY + coverSide / 2)

            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            sample.topLeft.color.opacity(baseOpacity * 0.72),
                            sample.top.color.opacity(baseOpacity * 0.58),
                            sample.right.color.opacity(baseOpacity * 0.78),
                            sample.bottom.color.opacity(baseOpacity * 0.68)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(6, coverSide * 0.030)
                )
                .frame(width: coverSide * 1.04, height: coverSide * 1.04)
                .blur(radius: side * 0.018)
                .position(x: centerX, y: centerY)
                .blendMode(.plusLighter)
        }
        .frame(width: wideSide, height: side)
        .opacity(glowStrength)
        .allowsHitTesting(false)
    }

    private enum GlowEdge {
        case top
        case bottom
        case left
        case right
    }

    private func sideGlow(_ color: Color, edge: GlowEdge, side: CGFloat, coverSide: CGFloat, reach: CGFloat, opacity: Double) -> some View {
        let wide = coverSide * 1.52  // 稍宽覆盖面
        let tall = reach * 1.28
        let gradient: LinearGradient
        let size: CGSize
        switch edge {
        case .top:
            gradient = LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: color.opacity(opacity * 0.14), location: 0.28), .init(color: color.opacity(opacity), location: 1)],
                startPoint: .top, endPoint: .bottom)
            size = CGSize(width: wide, height: tall)
        case .bottom:
            gradient = LinearGradient(
                stops: [.init(color: color.opacity(opacity), location: 0), .init(color: color.opacity(opacity * 0.16), location: 0.72), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom)
            size = CGSize(width: wide, height: tall)
        case .left:
            gradient = LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: color.opacity(opacity * 0.14), location: 0.28), .init(color: color.opacity(opacity * 0.88), location: 1)],
                startPoint: .leading, endPoint: .trailing)
            size = CGSize(width: tall, height: wide)
        case .right:
            // 右侧用三段渐变：封面右边缘峰值 → 中段平台 → 远端淡出，模拟光线向歌词卡辐射
            gradient = LinearGradient(
                stops: [
                    .init(color: color.opacity(opacity), location: 0),
                    .init(color: color.opacity(opacity * 0.62), location: 0.38),
                    .init(color: color.opacity(opacity * 0.24), location: 0.72),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading, endPoint: .trailing)
            size = CGSize(width: tall, height: wide)
        }
        return RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.46, style: .continuous)
            .fill(gradient)
            .frame(width: size.width, height: size.height)
            .blur(radius: side * 0.058)
            .blendMode(.screen)
    }

    private func cornerGlow(_ color: Color, side: CGFloat, reach: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: color.opacity(opacity), location: 0),
                        .init(color: color.opacity(opacity * 0.38), location: 0.52),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: reach
                )
            )
            .frame(width: reach * 2, height: reach * 2)
            .blur(radius: side * 0.044)
            .blendMode(.screen)
    }

    @MainActor
    private func loadSample() async {
        guard loadedPath != posterPath else { return }
        let path = posterPath
        loadedPath = path
        guard let path else {
            sample = nil
            edgeGlowImage = nil
            return
        }
        let result = await Task.detached(priority: .utility) {
            let base = ArtworkImageCache.image(path: path, targetSize: CGSize(width: 180, height: 180))
            return (
                AlbumEdgeGlowSampler.sample(from: base),
                SendableMusicBackdropArtworkImage(AlbumDirectionalGlowBake.bakedEdgeGlowImage(from: base))
            )
        }.value
        guard loadedPath == path else { return }
        sample = result.0
        edgeGlowImage = result.1.image
    }
}

private struct MusicExpandedArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let posterSize: CGFloat
    @StateObject private var playbackStateObserver: MusicMiniTransportStateObserver
    @State private var coverVisualProgress: Double = 1
    @State private var glowVisualProgress: Double = 1
    @State private var glowCollapseTask: Task<Void, Never>?

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette, posterSize: CGFloat) {
        self.item = item
        self.controller = controller
        self.palette = palette
        self.posterSize = posterSize
        _playbackStateObserver = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let isPlaying = playbackStateObserver.state.isPlaying
        let coverProgress = smoothstep(coverVisualProgress)
        let glowProgress = smoothstep(glowVisualProgress)
        let glowStrength = pow(glowProgress, 1.5)
        // 暂停时更明显的缩小+后退效果（0.918→1.0, 偏移 11→0），模拟封面"退回"感
        let coverScale = CGFloat(lerp(from: 0.918, to: 1.0, progress: coverProgress))
        let coverOffset = CGFloat(lerp(from: 11, to: 0, progress: coverProgress))
        // 暂停时光晕收得更小（0.5），播放时铺满到 1.0；范围由外层 frame 决定。
        let glowScale = CGFloat(lerp(from: 0.5, to: 1.0, progress: glowStrength))

        ZStack {
            MusicExpandedArtworkShadowLayer(
                primaryColor: palette.glowPrimary.nsColor,
                accentColor: palette.glowAccent.nsColor,
                glowStrength: glowStrength,
                coverProgress: coverProgress,
                cornerRadius: 30,
                reduceMotion: reduceMotion
            )
            .frame(width: posterSize, height: posterSize)
            .allowsHitTesting(false)

            PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: posterSize, height: posterSize)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .background {
                    if glowStrength > 0.01 {
                        // 高斯模糊封面 + 烘焙径向 alpha 渐隐：颜色天然准确、向四周平滑淡出，无断层。
                        // 白色封面（vibrancy 低）缩短传播距离（2.7×→3.4×）并在层内调暗，避免白光过曝。
                        let reach = CGFloat(2.7 + palette.vibrancy * 0.7)
                        AlbumBlurredCoverGlowLayer(
                            posterPath: item.posterPath,
                            palette: palette,
                            glowStrength: glowStrength,
                            colorScheme: colorScheme
                        )
                        .frame(width: posterSize * reach, height: posterSize * reach)
                        .scaleEffect(glowScale)
                        .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(lerp(from: 0.38, to: 0.54, progress: coverProgress)), lineWidth: 1.2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    palette.glowPrimary.color.opacity(0.16 * glowStrength),
                                    palette.glowAccent.color.opacity(0.10 * glowStrength),
                                    .white.opacity(0.18 * coverProgress)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                        .allowsHitTesting(false)
                }
                .pointerLiquidEdge(cornerRadius: 30, tint: palette.glowPrimary.color, intensity: 1.22)
        }
        // 点击封面 = 点击播放/暂停按钮：与主控制按钮完全等效（canControl 时切换播放）。
        // contentShape 限定在封面方形内，避免误触发光晕区域。
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .onTapGesture {
            guard controller.canControl else { return }
            controller.togglePlay()
        }
        .scaleEffect(coverScale)
        .offset(y: coverOffset)
        .onAppear {
            syncPlaybackVisuals(isPlaying: isPlaying, animated: false)
        }
        .onChange(of: isPlaying) { playing in
            syncPlaybackVisuals(isPlaying: playing, animated: true)
        }
        .onChange(of: item.id) { _ in
            syncPlaybackVisuals(isPlaying: isPlaying, animated: false)
        }
        .onDisappear {
            glowCollapseTask?.cancel()
        }
    }

    private func syncPlaybackVisuals(isPlaying: Bool, animated: Bool) {
        let target = isPlaying ? 1.0 : 0.0
        glowCollapseTask?.cancel()
        guard animated else {
            coverVisualProgress = target
            glowVisualProgress = target
            return
        }

        if reduceMotion {
            coverVisualProgress = target
            glowVisualProgress = target
            return
        }

        if isPlaying {
            // 播放：远端光晕先升起（glow扩散），再封面弹起
            withAnimation(.easeOut(duration: 0.20)) {
                glowVisualProgress = 1
            }
            withAnimation(AppMotion.musicPlayer.delay(0.04)) {
                coverVisualProgress = 1
            }
        } else {
            // 暂停：近端（封面）先退后，然后由近及远关闭光晕
            // 1. 封面立即退后缩小
            withAnimation(AppMotion.musicPlayer) {
                coverVisualProgress = 0
            }
            // 2. 近端光晕快速收缩到微弱
            withAnimation(.easeOut(duration: 0.22).delay(0.04)) {
                glowVisualProgress = 0.12
            }
            // 3. 远端光晕渐渐熄灭（延迟更长，由近及远）
            glowCollapseTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 240_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    glowVisualProgress = 0
                }
            }
        }
    }

    private func lerp(from start: Double, to end: Double, progress: Double) -> Double {
        start + (end - start) * progress
    }

    private func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

private struct MusicExpandedArtworkShadowLayer: NSViewRepresentable {
    let primaryColor: NSColor
    let accentColor: NSColor
    let glowStrength: Double
    let coverProgress: Double
    let cornerRadius: CGFloat
    let reduceMotion: Bool

    func makeNSView(context: Context) -> ShadowView {
        let view = ShadowView(frame: .zero)
        view.update(
            primaryColor: primaryColor,
            accentColor: accentColor,
            glowStrength: glowStrength,
            coverProgress: coverProgress,
            cornerRadius: cornerRadius,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: ShadowView, context: Context) {
        nsView.update(
            primaryColor: primaryColor,
            accentColor: accentColor,
            glowStrength: glowStrength,
            coverProgress: coverProgress,
            cornerRadius: cornerRadius,
            reduceMotion: reduceMotion
        )
    }

    final class ShadowView: NSView {
        private let primaryShadowLayer = CALayer()
        private let accentShadowLayer = CALayer()
        private let depthShadowLayer = CALayer()
        private var latestPrimaryColor = NSColor.clear
        private var latestAccentColor = NSColor.clear
        private var latestGlowStrength: Double = 0
        private var latestCoverProgress: Double = 1
        private var latestCornerRadius: CGFloat = 30
        private var latestReduceMotion = false
        private var didApplyInitialState = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        override func layout() {
            super.layout()
            apply(animated: false)
        }

        func update(
            primaryColor: NSColor,
            accentColor: NSColor,
            glowStrength: Double,
            coverProgress: Double,
            cornerRadius: CGFloat,
            reduceMotion: Bool
        ) {
            latestPrimaryColor = primaryColor
            latestAccentColor = accentColor
            latestGlowStrength = min(max(glowStrength, 0), 1)
            latestCoverProgress = min(max(coverProgress, 0), 1)
            latestCornerRadius = cornerRadius
            latestReduceMotion = reduceMotion
            apply(animated: didApplyInitialState && !reduceMotion)
            didApplyInitialState = true
        }

        private func configure() {
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.backgroundColor = NSColor.clear.cgColor
            for shadowLayer in [depthShadowLayer, primaryShadowLayer, accentShadowLayer] {
                shadowLayer.backgroundColor = NSColor.clear.cgColor
                shadowLayer.masksToBounds = false
                shadowLayer.shouldRasterize = true
                shadowLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
                layer?.addSublayer(shadowLayer)
            }
        }

        private func apply(animated: Bool) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let path = CGPath(
                roundedRect: bounds,
                cornerWidth: latestCornerRadius,
                cornerHeight: latestCornerRadius,
                transform: nil
            )

            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(animated ? 0.22 : 0)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

            for shadowLayer in [depthShadowLayer, primaryShadowLayer, accentShadowLayer] {
                shadowLayer.frame = bounds
                shadowLayer.cornerRadius = latestCornerRadius
                shadowLayer.shadowPath = path
                shadowLayer.rasterizationScale = scale
            }

            // 注意坐标系：ShadowView 为非翻转 NSView（y 向上），CALayer 的 shadowOffset 正 y 会向【上】投影。
            // 原 SwiftUI `.shadow(y: 正值)` 是向【下】投影，因此这里取负，保持阴影朝下（与封面落地阴影一致）。
            primaryShadowLayer.shadowColor = latestPrimaryColor.cgColor
            primaryShadowLayer.shadowOpacity = Float(lerp(from: 0.0, to: 0.34, progress: latestGlowStrength))
            primaryShadowLayer.shadowRadius = CGFloat(lerp(from: 4, to: 22, progress: latestGlowStrength))
            primaryShadowLayer.shadowOffset = CGSize(
                width: 0,
                height: -CGFloat(lerp(from: 2, to: 12, progress: latestGlowStrength))
            )

            accentShadowLayer.shadowColor = latestAccentColor.cgColor
            accentShadowLayer.shadowOpacity = Float(lerp(from: 0.0, to: 0.18, progress: latestGlowStrength))
            accentShadowLayer.shadowRadius = CGFloat(lerp(from: 3, to: 14, progress: latestGlowStrength))
            accentShadowLayer.shadowOffset = CGSize(
                width: 0,
                height: -CGFloat(lerp(from: 1, to: 7, progress: latestGlowStrength))
            )

            depthShadowLayer.shadowColor = NSColor.black.cgColor
            depthShadowLayer.shadowOpacity = Float(lerp(from: 0.18, to: 0.24, progress: latestCoverProgress))
            depthShadowLayer.shadowRadius = CGFloat(lerp(from: 18, to: 22, progress: latestCoverProgress))
            depthShadowLayer.shadowOffset = CGSize(
                width: 0,
                height: -CGFloat(lerp(from: 16, to: 12, progress: latestCoverProgress))
            )

            CATransaction.commit()
        }

        private func lerp(from start: Double, to end: Double, progress: Double) -> Double {
            start + (end - start) * progress
        }
    }
}

private struct MusicExpandedLyricsPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let controller: MpvPlayerController
    let lyrics: String
    let timedLyrics: [TimedLyricLine]
    let timingSource: LyricTimingSource
    let hasDisplayLyrics: Bool
    let isFetchingLyrics: Bool
    let palette: AlbumColorPalette
    @Binding var userIsBrowsingLyrics: Bool
    let onFetchLyrics: () -> Void
    let onPauseAutoScroll: () -> Void

    var body: some View {
            ZStack {
                LyricStageLight(palette: palette)
                    .allowsHitTesting(false)

                // 正在播放行的聚光灯：当前行始终自动滚到卡片中心，故在中心放一束半径受控的柔光，
                // 让卡片中心更亮、聚焦当前行。放在文字层之下（plusLighter 只提亮背景），文字在其上渲染，
                // 字体颜色完全不受影响，也不会被冲淡。
                LyricCenterSpotlight()
                    .allowsHitTesting(false)

                lyricsView
                    .padding(.horizontal, 54)
                    .padding(.vertical, 58)

            if !hasDisplayLyrics {
                Button {
                    onFetchLyrics()
                } label: {
                    Image(systemName: isFetchingLyrics ? "hourglass" : "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background {
                            Circle()
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28))
                                .overlay {
                                    Circle()
                                        .fill(palette.primary.color.opacity(colorScheme == .dark ? 0.055 : 0.075))
                                }
                                .allowsHitTesting(false)
                        }
                        .overlay {
                            Circle().stroke(.white.opacity(colorScheme == .dark ? 0.24 : 0.54), lineWidth: 1)
                        }
                        .shadow(color: palette.primary.color.opacity(0.14), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(isFetchingLyrics)
                .help("在线获取歌词")
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if hasDisplayLyrics, !timedLyrics.isEmpty {
                LyricTimingSourceBadge(source: timingSource)
                    .padding(22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: 36, isLyricsCard: true))
        .overlay {
            LyricEdgeTintOverlay(palette: palette, cornerRadius: 36)
        }
        .overlay {
            LyricCardEdgeDepthOverlay(cornerRadius: 36)
                .allowsHitTesting(false)
        }
        // 封面发光照到歌词卡左边缘：播放时用专辑主色从左侧渗入，产生边缘染色 + 浸染效果
        .overlay {
            AlbumLightSpillOverlay(palette: palette, controller: controller, cornerRadius: 36)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var lyricsView: some View {
        if timedLyrics.isEmpty {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(MusicPlayerView.cleanedLyrics(lyrics))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineSpacing(9)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: max(geometry.size.height, 420), alignment: .center)
                        .padding(28)
                }
                .lyricsScrollActivity {
                    onPauseAutoScroll()
                }
            }
        } else {
            MusicTimedLyricsScrollView(
                controller: controller,
                timedLyrics: timedLyrics,
                palette: palette,
                userIsBrowsingLyrics: $userIsBrowsingLyrics,
                onPauseAutoScroll: onPauseAutoScroll
            )
        }
    }
}

private struct LyricTimingSourceBadge: View {
    let source: LyricTimingSource

    var body: some View {
        Text(source.displayTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.46))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.white.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.20), lineWidth: 0.7)
            }
            .help(source.helpText)
            .accessibilityLabel(source.helpText)
    }
}

private struct LyricStageLight: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette

    var body: some View {
        LyricStageLightLayer(palette: palette, colorScheme: colorScheme, cornerRadius: 36)
            .opacity(0.72)
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
    }
}

/// 正在播放行的聚光灯：卡片中心一束柔和的白色径向光（当前行恒在中心）。
/// 半径受控（不超过卡片较短边的约 0.30），仅纯白、plusLighter 提亮背景，不染色、不冲淡文字。
private struct LyricCenterSpotlight: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            // 扩散更大：较短边的 0.56，夹在 [200, 320]，让光晕铺得更开。
            let radius = min(max(min(geo.size.width, geo.size.height) * 0.56, 200), 320)
            // 中心更均匀（前 ~0.34 半径保持峰值平台，不再是一个尖亮的中心点）+ 峰值更低，
            // 之后用近高斯的多 stop 做更长、更柔的衰减，避免中心过亮与可见的硬环。
            let peak = colorScheme == .dark ? 0.058 : 0.098
            RadialGradient(
                stops: [
                    .init(color: .white.opacity(peak), location: 0.00),
                    .init(color: .white.opacity(peak), location: 0.20),
                    .init(color: .white.opacity(peak * 0.94), location: 0.34),
                    .init(color: .white.opacity(peak * 0.78), location: 0.48),
                    .init(color: .white.opacity(peak * 0.56), location: 0.62),
                    .init(color: .white.opacity(peak * 0.34), location: 0.74),
                    .init(color: .white.opacity(peak * 0.16), location: 0.85),
                    .init(color: .white.opacity(peak * 0.05), location: 0.94),
                    .init(color: .clear, location: 1.00)
                ],
                center: .center,
                startRadius: 0,
                endRadius: radius
            )
            .frame(width: geo.size.width, height: geo.size.height)
            // plusLighter：只把中心区域提亮（叠加白光），不覆盖、不改变其上文字的颜色。
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

private struct LyricStageLightLayer: NSViewRepresentable {
    let palette: AlbumColorPalette
    let colorScheme: ColorScheme
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView(frame: .zero)
        view.update(palette: palette, colorScheme: colorScheme, cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: LayerView, context: Context) {
        nsView.update(palette: palette, colorScheme: colorScheme, cornerRadius: cornerRadius)
    }

    final class LayerView: NSView {
        private let radialLayer = CAGradientLayer()
        private let beamLayer = CAGradientLayer()
        private var palette = AlbumColorPalette.fallback
        private var colorScheme: ColorScheme = .light
        private var cornerRadius: CGFloat = 36

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        override func layout() {
            super.layout()
            applyLayout()
        }

        func update(palette: AlbumColorPalette, colorScheme: ColorScheme, cornerRadius: CGFloat) {
            self.palette = palette
            self.colorScheme = colorScheme
            self.cornerRadius = cornerRadius
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateColors()
            applyLayout()
            CATransaction.commit()
        }

        private func configure() {
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.cornerCurve = .continuous

            radialLayer.type = .radial
            radialLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
            radialLayer.endPoint = CGPoint(x: 1, y: 1)
            radialLayer.compositingFilter = "screenBlendMode"
            layer?.addSublayer(radialLayer)

            beamLayer.type = .axial
            beamLayer.startPoint = CGPoint(x: 0, y: 0.5)
            beamLayer.endPoint = CGPoint(x: 1, y: 0.5)
            beamLayer.compositingFilter = "screenBlendMode"
            layer?.addSublayer(beamLayer)
        }

        private func applyLayout() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let span = max(bounds.width, bounds.height)
            let diameter = max(span * 1.18, 620)
            radialLayer.frame = CGRect(
                x: bounds.midX - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            radialLayer.cornerRadius = diameter / 2

            let beamHeight = max(120, span * 0.32)
            beamLayer.frame = CGRect(
                x: bounds.minX,
                y: bounds.midY - beamHeight / 2,
                width: bounds.width,
                height: beamHeight
            )
            beamLayer.cornerRadius = beamHeight / 2

            layer?.cornerRadius = cornerRadius
        }

        private func updateColors() {
            // 柔和、低对比的径向光，避免中心过亮与边缘形成可见分界。
            radialLayer.colors = [
                NSColor.white.withAlphaComponent(colorScheme == .dark ? 0.14 : 0.18).cgColor,
                NSColor.white.withAlphaComponent(colorScheme == .dark ? 0.07 : 0.10).cgColor,
                palette.glowPrimary.nsColor.withAlphaComponent(colorScheme == .dark ? 0.04 : 0.045).cgColor,
                NSColor.clear.cgColor
            ]
            radialLayer.locations = [0, 0.40, 0.7, 1]

            // 去掉中部横向亮带：它在歌词卡中部形成可见的"断层"横条。整体只保留柔和径向光。
            beamLayer.colors = [
                NSColor.clear.cgColor,
                NSColor.clear.cgColor
            ]
            beamLayer.locations = [0, 1]
        }
    }
}

/// 封面发光照射到歌词卡左边缘的光晕渗入效果。
/// 播放时：专辑主色从左边缘浸染入内，沿边缘产生彩色描边，模拟封面发光照亮左边界。
/// 暂停时：随封面收缩动画同步淡出（由 near-to-far 机制驱动）。
private struct AlbumLightSpillOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette
    let controller: MpvPlayerController
    let cornerRadius: CGFloat
    @StateObject private var playbackObserver: MusicMiniTransportStateObserver
    @State private var spillProgress: Double = 0
    @State private var collapseTask: Task<Void, Never>?

    init(palette: AlbumColorPalette, controller: MpvPlayerController, cornerRadius: CGFloat) {
        self.palette = palette
        self.controller = controller
        self.cornerRadius = cornerRadius
        _playbackObserver = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let isPlaying = playbackObserver.state.isPlaying
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glowColor = palette.glowPrimary.color
        let accentColor = palette.glowAccent.color
        let darkMode = colorScheme == .dark

        ZStack {
            // 左侧浸染：专辑主色从左边缘柔和渗入，宽度约卡片的 1/3，平滑衰减（无明显边界）
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.30 : 0.22) * spillProgress), location: 0),
                            .init(color: glowColor.opacity((darkMode ? 0.17 : 0.13) * spillProgress), location: 0.09),
                            .init(color: accentColor.opacity((darkMode ? 0.08 : 0.06) * spillProgress), location: 0.22),
                            .init(color: .clear, location: 0.40)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blendMode(.screen)

            // 左边缘细描边：被封面发光"照亮"的边缘高光，仅最左侧一小段，快速淡出
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.50 : 0.38) * spillProgress), location: 0),
                            .init(color: glowColor.opacity((darkMode ? 0.26 : 0.20) * spillProgress), location: 0.14),
                            .init(color: .clear, location: 0.40),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1.0
                )
                .blendMode(.screen)
        }
        .onAppear {
            spillProgress = isPlaying ? 1 : 0
        }
        .onChange(of: isPlaying) { playing in
            collapseTask?.cancel()
            if playing {
                withAnimation(.easeOut(duration: 0.24)) {
                    spillProgress = 1
                }
            } else {
                // 随封面收缩同步淡出：先快降到微弱，再延迟熄灭（near-to-far）
                withAnimation(.easeInOut(duration: 0.22)) {
                    spillProgress = 0.12
                }
                collapseTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 260_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.28)) {
                        spillProgress = 0
                    }
                }
            }
        }
        .onDisappear {
            collapseTask?.cancel()
        }
    }
}

private struct LyricEdgeTintOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            palette.glowPrimary.color.opacity(colorScheme == .dark ? 0.16 : 0.12),
                            .clear,
                            palette.glowAccent.color.opacity(colorScheme == .dark ? 0.12 : 0.08)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blendMode(.screen)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            palette.primary.color.opacity(colorScheme == .dark ? 0.42 : 0.28),
                            .white.opacity(colorScheme == .dark ? 0.18 : 0.30),
                            palette.accent.color.opacity(colorScheme == .dark ? 0.22 : 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
                .blendMode(.screen)

            // 去掉顶部/底部固定高度(102/96)的色块——它们在卡片上/下部形成可见的横向分界(断层)。
            // 卡片边缘质感由上面的描边与卡片自身的玻璃高光提供，已足够。
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

private struct LyricCardEdgeDepthOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    stops: [
                        // 上沿白色略提一点点（亮 0.105→0.125），向中部自然淡出到 clear。
                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.055 : 0.125), location: 0.00),
                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.034 : 0.084), location: 0.13),
                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.013 : 0.036), location: 0.28),
                        .init(color: .clear, location: 0.42),
                        .init(color: .clear, location: 0.58),
                        // 下沿由原来的“变暗(黑)”改为同样的一点点白色，与上沿对称、向中部自然过渡。
                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.022 : 0.052), location: 0.76),
                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.034 : 0.078), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.22 : 0.42),
                            .clear,
                            .black.opacity(colorScheme == .dark ? 0.16 : 0.055)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
            .clipShape(shape)
            .allowsHitTesting(false)
    }
}

private struct AppKitVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.drawsAsynchronously = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
        if nsView.state != state {
            nsView.state = state
        }
        nsView.isEmphasized = false
    }
}

private struct MusicTimedLyricsScrollView: View {
    let controller: MpvPlayerController
    let timedLyrics: [TimedLyricLine]
    let palette: AlbumColorPalette
    @Binding var userIsBrowsingLyrics: Bool
    let onPauseAutoScroll: () -> Void
    @StateObject private var renderObserver: MusicLyricRenderObserver
    @State private var lastAutoScrolledIndex: Int?
    @State private var lyricViewportAlignTask: Task<Void, Never>?
    @State private var lyricViewportStabilityTask: Task<Void, Never>?
    @State private var programmaticLyricScrollTask: Task<Void, Never>?
    @State private var isProgrammaticLyricScroll = false
    // 1.0 = 正常模糊（播放状态），0.0 = 浏览状态（低模糊）
    @State private var lyricBrowseBlurProgress: Double = 1.0

    init(
        controller: MpvPlayerController,
        timedLyrics: [TimedLyricLine],
        palette: AlbumColorPalette,
        userIsBrowsingLyrics: Binding<Bool>,
        onPauseAutoScroll: @escaping () -> Void
    ) {
        self.controller = controller
        self.timedLyrics = timedLyrics
        self.palette = palette
        _userIsBrowsingLyrics = userIsBrowsingLyrics
        self.onPauseAutoScroll = onPauseAutoScroll
        _renderObserver = StateObject(wrappedValue: MusicLyricRenderObserver(controller: controller, timedLyrics: timedLyrics))
    }

    private var renderState: MusicLyricRenderState {
        renderObserver.state
    }

    private var isSeekPreviewActive: Bool {
        renderState.isSeekPreviewActive
    }

    private var activeLyricIndex: Int? {
        renderState.activeLineIndex
    }
    private static let viewportStabilityDelay: UInt64 = 780_000_000

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let currentActiveIndex = activeLyricIndex
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .center, spacing: 12) {
                        ForEach(timedLyrics.indices, id: \.self) { index in
                            let line = timedLyrics[index]
                            let isActiveLine = index == currentActiveIndex
                            let distance = currentActiveIndex.map { abs(index - $0) } ?? 0
                            lyricLine(
                                line,
                                index: index,
                                isActive: isActiveLine,
                                distanceFromActive: distance,
                                highlightMode: highlightMode(for: index),
                                isBrowsing: userIsBrowsingLyrics,
                                browseBlurProgress: lyricBrowseBlurProgress
                            )
                            .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: max(geometry.size.height, 360), alignment: .center)
                    .padding(.horizontal, 34)
                    .padding(.vertical, max(geometry.size.height * 0.46, 38))
                }
                .mask(lyricsFadeMask)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in handleUserLyricScrollActivity() }
                )
                .lyricsScrollActivity {
                    handleUserLyricScrollActivity()
                }
                .onAppear {
                    renderObserver.updateTimedLyrics(timedLyrics)
                    scrollToActiveLyric(proxy, animated: false)
                }
                .onChange(of: activeLyricIndex) { _ in
                    if userIsBrowsingLyrics {
                        withAnimation(AppMotion.standard) {
                            userIsBrowsingLyrics = false
                        }
                    }
                    scrollToActiveLyric(
                        proxy,
                        force: true,
                        animated: !isSeekPreviewActive
                    )
                    scheduleLyricViewportStabilityCheck(proxy)
                }
                .onChange(of: renderState.seekState) { state in
                    applySeekState(state, proxy: proxy)
                }
                .onChange(of: timedLyrics) { _ in
                    renderObserver.updateTimedLyrics(timedLyrics)
                    lastAutoScrolledIndex = nil
                    lyricViewportStabilityTask?.cancel()
                    scrollToActiveLyric(proxy, force: true)
                    scheduleLyricViewportStabilityCheck(proxy)
                }
                .onChange(of: userIsBrowsingLyrics) { browsing in
                    if browsing {
                        // 快速解除模糊（0.22s），让用户立刻能看清所有歌词
                        withAnimation(.easeOut(duration: 0.22)) {
                            lyricBrowseBlurProgress = 0
                        }
                    } else {
                        // 慢速恢复模糊（1.4s easeInOut），渐渐回到播放状态的模糊效果
                        withAnimation(.easeInOut(duration: 1.4)) {
                            lyricBrowseBlurProgress = 1
                        }
                        scrollToActiveLyric(proxy, force: true)
                        scheduleLyricViewportStabilityCheck(proxy)
                    }
                }
                .onDisappear {
                    lyricViewportAlignTask?.cancel()
                    lyricViewportStabilityTask?.cancel()
                    programmaticLyricScrollTask?.cancel()
                    isProgrammaticLyricScroll = false
                }
            }
        }
    }

    private var lyricsFadeMask: some View {
        // 上下部分更快淡出（0~0.38 / 0.62~1.0 为过渡区），中心留出更宽的清晰窗口。
        // 上下边缘的不透明度低 + 每行本身的距离模糊叠加 = 自然的"边缘更模糊、中心清晰"效果。
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black.opacity(0.04), location: 0.05),
                .init(color: .black.opacity(0.24), location: 0.13),
                .init(color: .black.opacity(0.66), location: 0.23),
                .init(color: .black.opacity(0.92), location: 0.33),
                .init(color: .black, location: 0.42),
                .init(color: .black, location: 0.58),
                .init(color: .black.opacity(0.92), location: 0.67),
                .init(color: .black.opacity(0.66), location: 0.77),
                .init(color: .black.opacity(0.24), location: 0.87),
                .init(color: .black.opacity(0.04), location: 0.95),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: TimedLyricLine,
        index: Int,
        isActive: Bool,
        distanceFromActive: Int,
        highlightMode: LyricLineHighlightMode,
        isBrowsing: Bool,
        browseBlurProgress: Double = 1.0
    ) -> some View {
        Group {
            if isActive {
                MusicActiveKaraokeLyricLine(
                    controller: controller,
                    timedLyrics: timedLyrics,
                    line: line,
                    index: index,
                    palette: palette
                )
            } else {
                KaraokeLyricLine(
                    line: line,
                    currentTime: line.time,
                    palette: palette,
                    isActive: false,
                    highlightMode: highlightMode,
                    progress: 0
                )
                .equatable()
            }
        }
        .allowsHitTesting(false)
        .lineLimit(nil)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        // 所有行基础字号一致，不再整行缩放（之前 active 1.04 / 非 active 0.94 会让滚到当前行时整行放大，
        // 看起来像"跑过去突然变小/变大"）。突出效果只保留在被播放行内部"已播放字"的逐字放大上（见 KaraokeLyricLine）。
        .activeLyricMotion(active: isActive, isBrowsing: isBrowsing, palette: palette)
        .opacity(lyricOpacity(distanceFromActive: distanceFromActive, isActive: isActive, isBrowsing: isBrowsing))
        .blur(radius: lyricBlur(distanceFromActive: distanceFromActive, isActive: isActive, browseProgress: browseBlurProgress))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.seek(to: line.time)
            userIsBrowsingLyrics = false
        }
        .animation(AppMotion.lyricFlow, value: isActive)
        .animation(AppMotion.lyricFlow, value: line.text)
        .animation(AppMotion.lyricFlow, value: isBrowsing)
    }

    private func lyricOpacity(distanceFromActive distance: Int, isActive: Bool, isBrowsing: Bool) -> Double {
        if isBrowsing {
            if isActive { return 1 }
            switch distance {
            case 0...1: return 0.88
            case 2: return 0.74
            default: return 0.60
            }
        }
        if isActive { return 1 }
        switch distance {
        case 0...1: return 0.70
        case 2: return 0.48
        case 3: return 0.34
        default: return 0.22
        }
    }

    private func lyricBlur(distanceFromActive distance: Int, isActive: Bool, browseProgress: Double) -> CGFloat {
        if isActive { return 0 }
        // 正常播放状态：距离越远模糊越强（非线性），营造景深感
        let normalBlur: CGFloat
        switch distance {
        case 1: normalBlur = 0.9
        case 2: normalBlur = 3.8
        case 3: normalBlur = 7.5
        case 4: normalBlur = 12.0
        default: normalBlur = min(12.0 + CGFloat(distance - 4) * 2.5, 22.0)
        }
        // 浏览状态：轻度模糊，仅做深度提示，让用户可以阅读歌词
        let browsingBlur: CGFloat = min(CGFloat(max(distance - 1, 0)) * 0.42, 2.0)
        // 按 browseProgress 插值（0=浏览，1=正常播放）
        return browsingBlur + (normalBlur - browsingBlur) * CGFloat(browseProgress)
    }

    private func highlightMode(for index: Int) -> LyricLineHighlightMode {
        if isSeekPreviewActive,
           activeLyricIndex == index {
            return .fullLineDuringSeek
        }
        return .normal
    }

    private func applySeekState(_ state: MusicLyricSeekRenderState?, proxy: ScrollViewProxy) {
        guard let state, !timedLyrics.isEmpty else {
            scrollToActiveLyric(proxy, force: true)
            scheduleLyricViewportStabilityCheck(proxy)
            return
        }
        if userIsBrowsingLyrics {
            withAnimation(AppMotion.standard) {
                userIsBrowsingLyrics = false
            }
        }
        lastAutoScrolledIndex = nil
        guard let lineIndex = state.targetLineIndex,
              timedLyrics.indices.contains(lineIndex) else {
            scrollToActiveLyric(proxy, force: true, animated: false)
            scheduleLyricViewportStabilityCheck(proxy)
            return
        }
        forceAlignLyricViewport(proxy, to: lineIndex, animated: false)
        scheduleLyricViewportStabilityCheck(proxy, targetIndex: lineIndex)
    }

    private func scrollToActiveLyric(_ proxy: ScrollViewProxy, force: Bool = false, animated: Bool = true) {
        guard !userIsBrowsingLyrics, let activeLyricIndex else { return }
        scrollToLyricIndex(activeLyricIndex, proxy, force: force, animated: animated)
    }

    private func forceAlignLyricViewport(
        _ proxy: ScrollViewProxy,
        to index: Int,
        animated: Bool
    ) {
        guard timedLyrics.indices.contains(index), !userIsBrowsingLyrics else { return }
        lastAutoScrolledIndex = nil
        scrollToLyricIndex(index, proxy, force: true, animated: animated)
        lyricViewportAlignTask?.cancel()
        let targetIndex = index
        let settleDelay: UInt64 = animated ? 320_000_000 : 18_000_000
        lyricViewportAlignTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if !animated {
                scrollToLyricIndex(targetIndex, proxy, force: true, animated: false)
            }
            do { try await Task.sleep(nanoseconds: settleDelay) } catch { return }
            guard !Task.isCancelled else { return }
            guard activeLyricIndex == targetIndex || isSeekPreviewActive else { return }
            scrollToLyricIndex(targetIndex, proxy, force: true, animated: false)
            do { try await Task.sleep(nanoseconds: 24_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            guard activeLyricIndex == targetIndex || isSeekPreviewActive else { return }
            scrollToLyricIndex(targetIndex, proxy, force: true, animated: false)
        }
    }

    private func scheduleLyricViewportStabilityCheck(
        _ proxy: ScrollViewProxy,
        targetIndex: Int? = nil
    ) {
        guard !userIsBrowsingLyrics else { return }
        let requestedIndex = targetIndex ?? activeLyricIndex
        guard let requestedIndex,
              timedLyrics.indices.contains(requestedIndex) else { return }
        lyricViewportStabilityTask?.cancel()
        lyricViewportStabilityTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: Self.viewportStabilityDelay) } catch { return }
            defer { lyricViewportStabilityTask = nil }
            guard !Task.isCancelled,
                  !userIsBrowsingLyrics,
                  timedLyrics.indices.contains(requestedIndex),
                  activeLyricIndex == requestedIndex || isSeekPreviewActive else { return }
            scrollToLyricIndex(requestedIndex, proxy, force: true, animated: false)
            lyricViewportStabilityTask = nil
        }
    }

    private func scrollToLyricIndex(
        _ index: Int,
        _ proxy: ScrollViewProxy,
        force: Bool = false,
        animated: Bool = true
    ) {
        guard timedLyrics.indices.contains(index), !userIsBrowsingLyrics else { return }
        guard force || index != lastAutoScrolledIndex else { return }
        lastAutoScrolledIndex = index
        markProgrammaticLyricScroll()
        if animated {
            // R6-F：滚动用无过冲缓动曲线，呈现平移而非抛掷回弹。
            withAnimation(AppMotion.lyricScroll) {
                proxy.scrollTo(index, anchor: .center)
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func handleUserLyricScrollActivity() {
        guard !isProgrammaticLyricScroll else { return }
        onPauseAutoScroll()
    }

    private func markProgrammaticLyricScroll() {
        isProgrammaticLyricScroll = true
        programmaticLyricScrollTask?.cancel()
        programmaticLyricScrollTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            isProgrammaticLyricScroll = false
            programmaticLyricScrollTask = nil
        }
    }
}

private struct MusicExpandedControls: View {
    let controller: MpvPlayerController
    let item: MediaItem
    let palette: AlbumColorPalette

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.item = item
        self.controller = controller
        self.palette = palette
    }

    var body: some View {
        VStack(spacing: 12) {
            MusicExpandedProgressRow(item: item, controller: controller, palette: palette)

            MusicExpandedTransportRow(item: item, controller: controller, palette: palette)

            MusicExpandedStatusLine(controller: controller, item: item)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(maxWidth: 424, alignment: .center)
        .modifier(MusicControlGlass(palette: palette, cornerRadius: 24, tintStrength: 1.0))
    }
}

private struct MusicExpandedProgressRow: View {
    let controller: MpvPlayerController
    let item: MediaItem
    let palette: AlbumColorPalette

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.item = item
        self.controller = controller
        self.palette = palette
    }

    var body: some View {
        HStack(spacing: 8) {
            MusicFavoriteButton(item: item, palette: palette, size: 34)
                .fixedSize()

            MusicExpandedProgressTimeline(controller: controller, palette: palette)
                .layoutPriority(3)

            MusicQueueButton(item: item, palette: palette, size: 34)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MusicExpandedProgressTimeline: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var progressObserver: MusicExpandedProgressStateObserver

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _progressObserver = StateObject(wrappedValue: MusicExpandedProgressStateObserver(controller: controller))
    }

    var body: some View {
        let state = progressObserver.state

        HStack(spacing: 5) {
            Text(state.formattedCurrentTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            MusicMiniSeekSlider(
                currentTime: state.currentTime,
                duration: state.duration,
                isEnabled: state.canControl && state.duration > 0,
                palette: palette,
                trackHeight: 7,
                thumbSize: 16,
                usesPaletteTint: true,
                onScrubBegin: { controller.beginScrubbing(to: $0) },
                onScrubChange: { controller.updateScrubbing(to: $0) },
                onSeek: { controller.finishScrubbing(to: $0) }
            )
            .disabled(!state.canControl || state.duration <= 0)
            .frame(minWidth: 150, idealWidth: 278, maxWidth: .infinity)

            Text(state.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }
}

private struct MusicExpandedTransportRow: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var stateObserver: MusicMiniTransportStateObserver

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.item = item
        self.controller = controller
        self.palette = palette
        _stateObserver = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let state = stateObserver.state

        // 隔空投送按钮配色统一为播放按钮：播放按钮用 palette.primary 及其加深版 deepTint（见 MusicPrimaryPlayButtonLabel），
        // 这里把 AirPlay 的图标 tint 也改用同一套专辑主色，不再是写死的蓝色。
        let deepPrimary = palette.primary.adjustedPreservingHue(
            saturationMultiplier: 1.10,
            brightnessMultiplier: 0.84,
            minSaturation: 0.30,
            maxSaturation: 0.96,
            minBrightness: 0.40,
            maxBrightness: 0.82
        )

        // 用 Spacer 在按钮间均匀撑开：首个按钮(AirPlay)贴左、末个按钮(循环)贴右，
        // 与上方进度行的首个(收藏)/末个(队列)按钮左右对齐；中间按钮均匀分布。
        HStack(spacing: 0) {
            AirPlayRoutePickerControl(
                session: controller.routePickerSession,
                player: controller.routePickerPlayer,
                tintColor: palette.primary.nsColor,
                activeTintColor: deepPrimary.nsColor,
                lightTint: palette.primary.color,
                size: 34,
                cornerRadius: 17,
                onRoutesWillBegin: {
                    controller.prepareForMusicAirPlayRouteSelection()
                },
                onRoutesDidEnd: {
                    controller.refreshMusicAirPlayRoute(afterRoutePicker: true)
                }
            )

            Spacer(minLength: 2)

            MusicExpandedVolumeButton(controller: controller, palette: palette)

            Spacer(minLength: 2)

            Button {
                playPreviousTrack()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!state.canControl)

            Spacer(minLength: 2)

            Button {
                if state.canControl {
                    controller.togglePlay()
                } else {
                    controller.configureMusic(item: item, settings: appState.settings)
                }
            } label: {
                MusicPrimaryPlayButtonLabel(isPlaying: state.isPlaying, palette: palette)
            }
            .buttonStyle(.plain)
            .pointerLiquidEdge(cornerRadius: 17, tint: palette.accent.color, intensity: 1.08)
            .disabled(state.isPreparing)

            Spacer(minLength: 2)

            Button {
                playNextTrack()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(!state.canControl)

            Spacer(minLength: 2)

            MusicShuffleButton(size: 34, palette: palette)
                .fixedSize()

            Spacer(minLength: 2)

            MusicRepeatModeButton(size: 34, palette: palette)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .font(.title3)
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: 34, cornerRadius: 17))
    }

    private func playPreviousTrack() {
        if appState.musicRepeatMode == .repeatOne {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: -1)
        }
    }

    private func playNextTrack() {
        if appState.musicRepeatMode == .repeatOne {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: 1)
        }
    }
}

private struct MusicExpandedVolumeButton: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var volumeObserver: MusicExpandedVolumeStateObserver
    @State private var showVolumeControl = false

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _volumeObserver = StateObject(wrappedValue: MusicExpandedVolumeStateObserver(controller: controller))
    }

    var body: some View {
        musicVolumeButton
    }

    private var musicVolumeButton: some View {
        Button {
            showVolumeControl.toggle()
        } label: {
            Image(systemName: volumeSystemImage)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: 34, cornerRadius: 17))
        .disabled(!volumeObserver.state.canControl)
        .popover(isPresented: $showVolumeControl, arrowEdge: .bottom) {
            musicVolumePopover
        }
        .help("音量")
        .accessibilityLabel("音量")
    }

    private var musicVolumePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: volumeSystemImage)
                    .foregroundStyle(.secondary)
                Text("音量")
                    .font(.headline)
                Spacer()
                Text("\(Int((volumeObserver.state.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: Binding(get: {
                Double(volumeObserver.state.volume)
            }, set: { newValue in
                controller.setVolume(Float(newValue))
            }), in: 0...1)
            .frame(width: 220)
        }
        .padding(16)
        .frame(width: 260)
        .modifier(MusicPopoverGlass(palette: palette, cornerRadius: 18))
    }

    private var volumeSystemImage: String {
        let volume = volumeObserver.state.volume
        if volume == 0 {
            return "speaker.slash"
        }
        if volume < 0.45 {
            return "speaker.wave.1"
        }
        return "speaker.wave.2"
    }
}

private struct MusicExpandedStatusLine: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let item: MediaItem
    @StateObject private var stateObserver: MusicExpandedStatusStateObserver

    init(controller: MpvPlayerController, item: MediaItem) {
        self.controller = controller
        self.item = item
        _stateObserver = StateObject(wrappedValue: MusicExpandedStatusStateObserver(controller: controller))
    }

    var body: some View {
        let state = stateObserver.state

        if let error = state.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(error)
                    .lineLimit(2)
                Spacer()
                Button("重试") {
                    controller.configureMusic(item: item, settings: appState.settings)
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 28))
            }
            .font(.caption)
            .foregroundStyle(.orange)
        } else if state.isPreparing {
            Label("正在准备播放器", systemImage: "progress.indicator")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MusicExpandedStatusState: Equatable {
    let errorMessage: String?
    let isPreparing: Bool
}

private struct MusicExpandedProgressState: Equatable {
    let currentTime: Double
    let duration: Double
    let canControl: Bool
    let formattedCurrentTime: String
    let formattedDuration: String
}

@MainActor
private final class MusicExpandedProgressStateObserver: ObservableObject {
    @Published private(set) var state: MusicExpandedProgressState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest4(
            controller.$currentTime,
            controller.$duration,
            controller.$isPreparing,
            controller.$errorMessage
        ).sink { [weak self] currentTime, duration, isPreparing, errorMessage in
            guard let self else { return }
            let nextState = Self.makeState(
                currentTime: currentTime,
                duration: duration,
                isPreparing: isPreparing,
                errorMessage: errorMessage
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicExpandedProgressState {
        makeState(
            currentTime: controller.currentTime,
            duration: controller.duration,
            isPreparing: controller.isPreparing,
            errorMessage: controller.errorMessage
        )
    }

    private static func makeState(
        currentTime: Double,
        duration: Double,
        isPreparing: Bool,
        errorMessage: String?
    ) -> MusicExpandedProgressState {
        MusicExpandedProgressState(
            currentTime: currentTime,
            duration: duration,
            canControl: errorMessage == nil && !isPreparing,
            formattedCurrentTime: formatTime(currentTime),
            formattedDuration: duration > 0 ? formatTime(duration) : "--:--"
        )
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct MusicExpandedVolumeState: Equatable {
    let volume: Float
    let canControl: Bool
}

@MainActor
private final class MusicExpandedVolumeStateObserver: ObservableObject {
    @Published private(set) var state: MusicExpandedVolumeState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest3(
            controller.$volume,
            controller.$isPreparing,
            controller.$errorMessage
        ).sink { [weak self] volume, isPreparing, errorMessage in
            guard let self else { return }
            let nextState = MusicExpandedVolumeState(
                volume: volume,
                canControl: errorMessage == nil && !isPreparing
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicExpandedVolumeState {
        MusicExpandedVolumeState(
            volume: controller.volume,
            canControl: controller.canControl
        )
    }
}

@MainActor
private final class MusicExpandedStatusStateObserver: ObservableObject {
    @Published private(set) var state: MusicExpandedStatusState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest(
            controller.$errorMessage,
            controller.$isPreparing
        ).sink { [weak self] errorMessage, isPreparing in
            guard let self else { return }
            let nextState = MusicExpandedStatusState(
                errorMessage: errorMessage,
                isPreparing: isPreparing
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicExpandedStatusState {
        MusicExpandedStatusState(
            errorMessage: controller.errorMessage,
            isPreparing: controller.isPreparing
        )
    }
}

/// 监听所在窗口的拖动（didMove）与缩放（live resize），用尾随去抖把“正在交互”状态回调出去：
/// 每次 move/resize 事件把 dragging 置 true 并重置 0.18s 定时器，静止 0.18s 后置回 false。
/// 用于在拖窗期间临时挂起昂贵的频谱解码，拖动结束立即恢复——拖动中肉眼不可见，零观感牺牲。
private struct WindowDragMonitor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.teardown()
    }

    final class MonitorView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?
        private var resetTimer: Timer?
        private var isDragging = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerObservers(for: window)
        }

        private func registerObservers(for newWindow: NSWindow?) {
            guard newWindow !== observedWindow else { return }
            removeObservers()
            observedWindow = newWindow
            guard let newWindow else { return }
            let center = NotificationCenter.default
            let names: [NSNotification.Name] = [
                NSWindow.didMoveNotification,
                NSWindow.willStartLiveResizeNotification,
                NSWindow.didResizeNotification
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                    self?.markInteracting()
                })
            }
            observers.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: newWindow, queue: .main) { [weak self] _ in
                self?.endInteractingSoon()
            })
        }

        private func markInteracting() {
            if !isDragging {
                isDragging = true
                onChange?(true)
            }
            // 尾随去抖：静止 0.18s 后判定拖动结束。
            resetTimer?.invalidate()
            resetTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                self?.endInteracting()
            }
        }

        private func endInteractingSoon() {
            resetTimer?.invalidate()
            resetTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                self?.endInteracting()
            }
        }

        private func endInteracting() {
            resetTimer?.invalidate()
            resetTimer = nil
            guard isDragging else { return }
            isDragging = false
            onChange?(false)
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            observedWindow = nil
        }

        func teardown() {
            resetTimer?.invalidate()
            resetTimer = nil
            removeObservers()
            // 兜底：确保不会把频谱永久挂起。
            if isDragging {
                isDragging = false
                onChange?(false)
            }
        }

        deinit {
            resetTimer?.invalidate()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

struct MusicPlaybackHost: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let controller: MpvPlayerController
    @State private var configuredItem: MediaItem?
    @State private var didAutoAdvance = false

    var body: some View {
        Color.clear
            .background {
                // 窗口拖动/缩放期间挂起频谱解码（见 controller.setSpectrumSuppressedDuringWindowDrag）。
                WindowDragMonitor { dragging in
                    controller.setSpectrumSuppressedDuringWindowDrag(dragging)
                }
                .frame(width: 0, height: 0)
            }
            .onAppear {
                configureIfNeeded(for: item)
            }
            .onChange(of: item.id) { _ in
                configureActiveItemIfNeeded()
            }
            .onChange(of: appState.musicQueue.map(\.id)) { _ in
                refreshNextMusicPreload()
            }
            .onChange(of: appState.musicRepeatMode) { _ in
                refreshNextMusicPreload()
            }
            .onChange(of: appState.musicShuffleEnabled) { _ in
                refreshNextMusicPreload()
            }
            .onChange(of: appState.settings.musicLoudnessNormalization) { _ in
                controller.updateMusicOutputSettings(settings: appState.settings)
            }
            .onChange(of: appState.settings.musicTransitionMode) { _ in
                controller.updateMusicOutputSettings(settings: appState.settings)
                refreshNextMusicPreload()
            }
            .onChange(of: appState.settings.musicSoftFadeDuration) { _ in
                controller.updateMusicOutputSettings(settings: appState.settings)
            }
            .onDisappear {
                let previousItem = configuredItem
                let previousDuration = controller.duration
                controller.reportPlaybackStopped()
                appState.finalizeScrobble()
                controller.teardown()
                if let previousItem {
                    appState.updatePlayback(
                        item: previousItem,
                        position: 0,
                        duration: previousDuration > 0 ? previousDuration : nil,
                        reloadLibrary: false
                    )
                }
                controller.onVolumeChange = nil
                controller.onPlaybackFinished = nil
                controller.onPlaybackReport = nil
            }
    }

    private var currentActiveMusicItem: MediaItem? {
        guard let active = appState.activePlayerItem, active.type == .music else { return nil }
        return active
    }

    private func configureActiveItemIfNeeded() {
        guard let active = currentActiveMusicItem else { return }
        configureIfNeeded(for: active)
    }

    private func configureIfNeeded(for targetItem: MediaItem) {
        controller.onVolumeChange = { volume in
            appState.rememberPlayerVolume(volume, for: targetItem.type)
        }
        controller.onPlaybackReport = { report in
            appState.syncEmbyPlayback(report)
        }
        controller.onPlaybackFinished = {
            guard !didAutoAdvance else { return }
            if appState.musicRepeatMode == .repeatOne ||
                (appState.musicRepeatMode == .repeatAll && appState.musicQueue.count == 1) {
                controller.restartFromBeginning()
                return
            }
            didAutoAdvance = true
            appState.playAdjacent(to: targetItem, direction: 1)
        }
        guard configuredItem?.id != targetItem.id else { return }
        let previousItem = configuredItem
        let previousDuration = controller.duration
        configuredItem = targetItem
        didAutoAdvance = false
        controller.configureMusic(item: targetItem, settings: appState.settings)
        refreshNextMusicPreload(for: targetItem)
        if let previousItem {
            appState.updatePlayback(
                item: previousItem,
                position: 0,
                duration: previousDuration > 0 ? previousDuration : nil,
                reloadLibrary: false
            )
        }
    }

    private func refreshNextMusicPreload(for item: MediaItem? = nil) {
        guard let current = item ?? currentActiveMusicItem else {
            controller.preloadNextMusicItem(nil)
            return
        }
        controller.preloadNextMusicItem(appState.nextMusicItemForPreloading(after: current))
    }
}

private struct LyricsScrollActivityModifier: ViewModifier {
    let onScroll: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                LyricsScrollActivityMonitor(onScroll: onScroll)
                    .allowsHitTesting(false)
            }
    }
}

private struct ActiveLyricMotionModifier: ViewModifier {
    let active: Bool
    let isBrowsing: Bool
    let palette: AlbumColorPalette

    @ViewBuilder
    func body(content: Content) -> some View {
        if active && !isBrowsing {
            content
                .brightness(0.006)
        } else {
            content
        }
    }
}

private enum LyricLineHighlightMode: Equatable {
    case normal
    case fullLineDuringSeek
}

private struct MusicLyricRenderState: Equatable {
    var activeLineIndex: Int?
    var seekState: MusicLyricSeekRenderState?

    var isSeekPreviewActive: Bool {
        guard let phase = seekState?.phase else { return false }
        return phase == .scrubbing || phase == .seeking
    }
}

private struct MusicLyricSeekRenderState {
    var revision: Int
    var phase: PlaybackSeekState.Phase
    var targetLineIndex: Int?
    var presentationTime: Double
}

extension MusicLyricSeekRenderState: Equatable {
    static func == (lhs: MusicLyricSeekRenderState, rhs: MusicLyricSeekRenderState) -> Bool {
        lhs.revision == rhs.revision &&
        lhs.phase == rhs.phase &&
        lhs.targetLineIndex == rhs.targetLineIndex
    }
}

@MainActor
private final class MusicLyricRenderObserver: ObservableObject {
    @Published private(set) var state: MusicLyricRenderState
    private weak var controller: MpvPlayerController?
    private var timedLyrics: [TimedLyricLine]
    private var cancellable: AnyCancellable?
    private(set) var latestLyricTime: Double
    private(set) var latestSeekState: PlaybackSeekState?

    init(controller: MpvPlayerController, timedLyrics: [TimedLyricLine]) {
        self.controller = controller
        self.timedLyrics = timedLyrics
        latestLyricTime = controller.lyricTime
        latestSeekState = controller.seekState
        state = Self.makeState(
            lyricTime: controller.lyricTime,
            seekState: controller.seekState,
            timedLyrics: timedLyrics
        )
        cancellable = Publishers.CombineLatest(
            controller.$lyricTime,
            controller.$seekState
        ).sink { [weak self] lyricTime, seekState in
            guard let self else { return }
            latestLyricTime = lyricTime
            latestSeekState = seekState
            let nextState = Self.makeState(
                lyricTime: lyricTime,
                seekState: seekState,
                timedLyrics: self.timedLyrics
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    func updateTimedLyrics(_ timedLyrics: [TimedLyricLine]) {
        self.timedLyrics = timedLyrics
        let nextState = Self.makeState(
            lyricTime: latestLyricTime,
            seekState: latestSeekState,
            timedLyrics: timedLyrics
        )
        if nextState != state {
            state = nextState
        }
    }

    private static func makeState(
        lyricTime: Double,
        seekState: PlaybackSeekState?,
        timedLyrics: [TimedLyricLine]
    ) -> MusicLyricRenderState {
        let isSeekPreviewActive: Bool
        if let phase = seekState?.phase {
            isSeekPreviewActive = phase == .scrubbing || phase == .seeking
        } else {
            isSeekPreviewActive = false
        }
        let selectionTime = isSeekPreviewActive ? (seekState?.presentationTime ?? lyricTime) : max(lyricTime, 0)
        let activeLineIndex = TimedLyricLine.playbackPosition(in: timedLyrics, at: selectionTime)?.lineIndex
        let seekRenderState = seekState.map { state in
            MusicLyricSeekRenderState(
                revision: state.revision,
                phase: state.phase,
                targetLineIndex: TimedLyricLine.playbackPosition(in: timedLyrics, at: state.presentationTime)?.lineIndex,
                presentationTime: state.presentationTime
            )
        }
        return MusicLyricRenderState(
            activeLineIndex: activeLineIndex,
            seekState: seekRenderState
        )
    }
}

private struct MusicActiveKaraokeLyricLine: View {
    let controller: MpvPlayerController
    let timedLyrics: [TimedLyricLine]
    let line: TimedLyricLine
    let index: Int
    let palette: AlbumColorPalette
    @StateObject private var progressObserver: MusicLyricActiveLineProgressObserver

    init(
        controller: MpvPlayerController,
        timedLyrics: [TimedLyricLine],
        line: TimedLyricLine,
        index: Int,
        palette: AlbumColorPalette
    ) {
        self.controller = controller
        self.timedLyrics = timedLyrics
        self.line = line
        self.index = index
        self.palette = palette
        _progressObserver = StateObject(
            wrappedValue: MusicLyricActiveLineProgressObserver(
                controller: controller,
                timedLyrics: timedLyrics,
                index: index
            )
        )
    }

    var body: some View {
        let state = progressObserver.state
        KaraokeLyricLine(
            line: line,
            currentTime: state.displayTime,
            palette: palette,
            isActive: true,
            highlightMode: state.highlightMode,
            progress: state.progress
        )
        .onAppear {
            progressObserver.configure(timedLyrics: timedLyrics, index: index)
        }
        .onChange(of: index) { newIndex in
            progressObserver.configure(timedLyrics: timedLyrics, index: newIndex)
        }
        .onChange(of: timedLyrics) { newLines in
            progressObserver.configure(timedLyrics: newLines, index: index)
        }
    }
}

private struct MusicLyricActiveLineProgressState: Equatable {
    var displayTime: Double
    var progress: Double
    var wordProgressBucket: Int
    var highlightMode: LyricLineHighlightMode

    static func == (lhs: MusicLyricActiveLineProgressState, rhs: MusicLyricActiveLineProgressState) -> Bool {
        lhs.wordProgressBucket == rhs.wordProgressBucket &&
        lhs.highlightMode == rhs.highlightMode
    }
}

@MainActor
private final class MusicLyricActiveLineProgressObserver: ObservableObject {
    @Published private(set) var state: MusicLyricActiveLineProgressState
    private weak var controller: MpvPlayerController?
    private var timedLyrics: [TimedLyricLine]
    private var index: Int
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController, timedLyrics: [TimedLyricLine], index: Int) {
        self.controller = controller
        self.timedLyrics = timedLyrics
        self.index = index
        state = Self.makeState(
            timedLyrics: timedLyrics,
            index: index,
            lyricTime: controller.lyricTime,
            seekState: controller.seekState
        )
        cancellable = Publishers.CombineLatest(
            controller.$lyricTime,
            controller.$seekState
        ).sink { [weak self] lyricTime, seekState in
            guard let self else { return }
            let nextState = Self.makeState(
                timedLyrics: self.timedLyrics,
                index: self.index,
                lyricTime: lyricTime,
                seekState: seekState
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    func configure(timedLyrics: [TimedLyricLine], index: Int) {
        self.timedLyrics = timedLyrics
        self.index = index
        guard let controller else { return }
        let nextState = Self.makeState(
            timedLyrics: timedLyrics,
            index: index,
            lyricTime: controller.lyricTime,
            seekState: controller.seekState
        )
        state = nextState
    }

    private static func makeState(
        timedLyrics: [TimedLyricLine],
        index: Int,
        lyricTime: Double,
        seekState: PlaybackSeekState?
    ) -> MusicLyricActiveLineProgressState {
        let isSeekPreviewActive: Bool
        if let phase = seekState?.phase {
            isSeekPreviewActive = phase == .scrubbing || phase == .seeking
        } else {
            isSeekPreviewActive = false
        }
        let displayTime = isSeekPreviewActive ? (seekState?.presentationTime ?? lyricTime) : lyricTime
        let progress = timedLyrics.indices.contains(index)
            ? TimedLyricLine.progress(in: timedLyrics, index: index, currentTime: displayTime)
            : 0
        let bucket = Int((min(max(progress, 0), 1) * 180).rounded())
        let highlightMode: LyricLineHighlightMode = isSeekPreviewActive ? .fullLineDuringSeek : .normal
        return MusicLyricActiveLineProgressState(
            displayTime: displayTime,
            progress: progress,
            wordProgressBucket: bucket,
            highlightMode: highlightMode
        )
    }
}

private struct LyricsScrollActivityMonitor: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window,
                      event.window === window else {
                    return event
                }
                let location = convert(event.locationInWindow, from: nil)
                if bounds.contains(location) {
                    onScroll?()
                }
                return event
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

private extension View {
    func lyricsScrollActivity(_ onScroll: @escaping () -> Void) -> some View {
        modifier(LyricsScrollActivityModifier(onScroll: onScroll))
    }

    func activeLyricMotion(active: Bool, isBrowsing: Bool, palette: AlbumColorPalette) -> some View {
        modifier(ActiveLyricMotionModifier(active: active, isBrowsing: isBrowsing, palette: palette))
    }
}

struct MusicMiniPlayerBar: View {
    let item: MediaItem
    let controller: MpvPlayerController
    let leadingInset: CGFloat
    let transitionNamespace: Namespace.ID
    let isCollapsed: Bool
    let onRequestReveal: () -> Void
    let onRequestExpand: () -> Void
    let onRequestClose: () -> Void
    @State private var albumPalette = AlbumColorPalette.fallback
    @State private var paletteLoadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isCollapsed {
                collapsedCoverButton
                    .padding(5)
                    .frame(width: 72, height: 72, alignment: .center)
                    .background {
                        MusicMiniPlayerGlassSurface(palette: albumPalette, cornerRadius: 18)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .scale(scale: 0.985, anchor: .trailing))
                    ))
                    .zIndex(3)
            } else {
                expandedMiniBar
                    .background {
                        MusicMiniPlayerGlassSurface(palette: albumPalette, cornerRadius: 18)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .trailing)),
                        removal: .opacity.combined(with: .scale(scale: 0.965, anchor: .trailing))
                    ))
                    .zIndex(2)
            }
        }
        .font(.headline)
        .frame(height: 72)
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .trailing : .bottomLeading)
        .modifier(MusicPlayerPointerLightScope(
            tint: albumPalette.primary.color,
            radius: isCollapsed ? 126 : 210,
            intensity: isCollapsed ? 0.72 : 0.82,
            updateInterval: isCollapsed ? 1.0 / 18.0 : 1.0 / 24.0,
            minDistance: isCollapsed ? 10.0 : 8.5
        ))
        .glassPerformanceMode(.full)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(true)
        .onAppear {
            loadAlbumPalette()
        }
        .onChange(of: item.id) { _ in
            loadAlbumPalette()
        }
        .onChange(of: item.posterPath) { _ in
            loadAlbumPalette()
        }
        .onDisappear {
            paletteLoadTask?.cancel()
        }
    }

    private var expandedMiniBar: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, 1)
            let showsSkipButtons = availableWidth >= 830
            let showsTrackText = availableWidth >= 590

            ZStack {
                MusicMiniAlbumGlowLayer(palette: albumPalette)

                HStack(spacing: 12) {
                    trackSummaryButton(showText: showsTrackText)
                        .frame(
                            minWidth: showsTrackText ? 170 : 54,
                            idealWidth: showsTrackText ? 238 : 54,
                            maxWidth: showsTrackText ? 300 : 58,
                            alignment: .leading
                        )
                        .layoutPriority(1)

                    MusicMiniTransportControls(
                        item: item,
                        controller: controller,
                        palette: albumPalette,
                        showsSkipButtons: showsSkipButtons
                    )
                    .fixedSize()
                    .layoutPriority(3)

                    MusicMiniProgressControl(controller: controller, palette: albumPalette)
                        .frame(minWidth: showsSkipButtons ? 260 : 210, maxWidth: .infinity)
                        .layoutPriority(5)

                    MusicMiniUtilityControls(item: item, controller: controller, palette: albumPalette, onRequestClose: onRequestClose)
                        .fixedSize()
                        .layoutPriority(2)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .frame(width: availableWidth, height: proxy.size.height, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var collapsedCoverButton: some View {
        Button {
            onRequestReveal()
        } label: {
            ZStack {
                MusicMiniCollapsedProgressRing(controller: controller, palette: albumPalette)
                    .frame(width: 62, height: 62)

                PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 54, height: 54)
                    .matchedGeometryEffect(id: "music-mini-cover", in: transitionNamespace)
                    .brightness(-0.10)
                    .saturation(0.82)
                    .overlay(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.42), lineWidth: 0.9)
                    }

                MusicMiniPresetSpectrum(controller: controller, palette: albumPalette)
                    .padding(.bottom, 7)
                    .frame(width: 54, height: 54, alignment: .bottom)
            }
            .frame(width: 62, height: 62)
        }
        .buttonStyle(.plain)
        .help("展开底部播放器")
    }

    private func trackSummaryButton(showText: Bool) -> some View {
        Button {
            onRequestExpand()
        } label: {
            HStack(spacing: 12) {
                PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .matchedGeometryEffect(id: "music-mini-cover", in: transitionNamespace)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if showText {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(item.artistAlbumLine ?? "未知艺人")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .help("展开播放器")
    }

    private func loadAlbumPalette() {
        paletteLoadTask?.cancel()
        let targetItemID = item.id
        let targetPath = item.posterPath
        // 与全屏一致：切歌保留旧取色直到新取色就绪，避免底栏取色瞬间塌成 fallback 再恢复的闪烁。
        paletteLoadTask = Task {
            let palette = await AlbumPaletteCache.palette(for: targetPath)
            await MainActor.run {
                guard !Task.isCancelled, item.id == targetItemID else { return }
                withAnimation(AppMotion.standard) {
                    albumPalette = palette
                }
            }
        }
    }
}

private struct MusicMiniCollapsedProgressRing: View {
    @StateObject private var progressObserver: MusicMiniCollapsedProgressObserver
    let palette: AlbumColorPalette

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        _progressObserver = StateObject(wrappedValue: MusicMiniCollapsedProgressObserver(controller: controller))
        self.palette = palette
    }

    var body: some View {
        let state = progressObserver.state
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

        ZStack {
            shape
                .inset(by: 2.0)
                .stroke(palette.progressLight.color.opacity(state.isEnabled ? 0.62 : 0.32), lineWidth: 3.0)

            shape
                .inset(by: 2.0)
                .trim(from: 0, to: CGFloat(state.progress))
                .stroke(
                    LinearGradient(
                        colors: [
                            palette.progressDark.color.opacity(state.isEnabled ? 0.98 : 0.46),
                            palette.progressDark.color.opacity(state.isEnabled ? 0.82 : 0.36)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 3.3, lineCap: .round, lineJoin: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .shadow(color: palette.progressDark.color.opacity(state.isEnabled ? 0.20 : 0), radius: 4, y: 1)
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.18), value: state.progressBucket)
    }
}

private struct MusicMiniCollapsedProgressState: Equatable {
    var progress: Double
    var progressBucket: Int
    var isEnabled: Bool
}

@MainActor
private final class MusicMiniCollapsedProgressObserver: ObservableObject {
    @Published private(set) var state: MusicMiniCollapsedProgressState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest(
            controller.$currentTime,
            controller.$duration
        ).sink { [weak self] currentTime, duration in
            guard let self else { return }
            let next = Self.makeState(currentTime: currentTime, duration: duration)
            guard next != self.state else { return }
            self.state = next
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicMiniCollapsedProgressState {
        makeState(currentTime: controller.currentTime, duration: controller.duration)
    }

    private static func makeState(currentTime: Double, duration: Double) -> MusicMiniCollapsedProgressState {
        let progress: Double
        if duration.isFinite, duration > 0, currentTime.isFinite {
            progress = min(max(currentTime / duration, 0), 1)
        } else {
            progress = 0
        }
        return MusicMiniCollapsedProgressState(
            progress: progress,
            progressBucket: Int((progress * 360).rounded()),
            isEnabled: duration > 0
        )
    }
}

private struct MusicMiniAlbumGlowLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette

    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width * 0.72, 520)

            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [
                        palette.primary.color.opacity(colorScheme == .dark ? 0.30 : 0.22),
                        palette.accent.color.opacity(colorScheme == .dark ? 0.18 : 0.13),
                        palette.secondary.color.opacity(colorScheme == .dark ? 0.12 : 0.09),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [
                                palette.primary.color.opacity(colorScheme == .dark ? 0.42 : 0.30),
                                palette.accent.color.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                .clear
                            ],
                            center: UnitPoint(x: 0.07, y: 0.06),
                            startRadius: 0,
                            endRadius: reach * 0.48
                        )
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .blendMode(.screen)
            .opacity(colorScheme == .dark ? 0.58 : 0.46)
            .allowsHitTesting(false)
        }
    }
}

private struct MusicMiniPlayerGlassSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.preferStaticGlassSurfaces) private var preferStaticGlassSurfaces
    @Environment(\.glassPerformanceMode) private var glassPerformanceMode
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat

    private var samplesPointer: Bool {
        !reduceMotion &&
        !suppressHoverDuringScroll &&
        !preferStaticGlassSurfaces &&
        glassPerformanceMode.allowsPointerSampling
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        AppKitVisualEffectBackground(material: .popover, blendingMode: .withinWindow)
            .clipShape(shape)
            .overlay {
                shape.fill(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.54))
            }
            .background(
                shape.fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12))
            )
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.28 : 0.66),
                            palette.primary.color.opacity(colorScheme == .dark ? 0.038 : 0.030),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.070 : 0.105),
                            .white.opacity(colorScheme == .dark ? 0.08 : 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.36 : 0.82),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.10 : 0.16),
                            palette.accent.color.opacity(colorScheme == .dark ? 0.10 : 0.075),
                            .white.opacity(colorScheme == .dark ? 0.10 : 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .overlay {
                LyricsCardEffectLayerView(
                    cornerRadius: cornerRadius,
                    intensity: 0.72,
                    colorScheme: colorScheme,
                    isEnabled: samplesPointer
                )
                .allowsHitTesting(false)
            }
            .background {
                GlassPanelShadowLayer(
                    palette: palette,
                    colorScheme: colorScheme,
                    cornerRadius: cornerRadius,
                    tintStrength: 0.48,
                    isLyricsCard: false
                )
                .allowsHitTesting(false)
            }
    }
}

private struct MusicPrimaryPlayButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let isPlaying: Bool
    var palette: AlbumColorPalette?
    var width: CGFloat = 42
    var height: CGFloat = 34

    var body: some View {
        if let palette {
            glassBody(palette: palette)
        } else {
            gradientBody
        }
    }

    // 展开界面：比其他玻璃按钮更厚的磨砂玻璃，单色（取自专辑主色）。
    // 相比其它按钮颜色更深一点、透明度更低（更实），以突出主操作。
    private func glassBody(palette: AlbumColorPalette) -> some View {
        let tint = palette.primary.color
        // 稍微加深的主色（降低亮度、略提饱和），用于更实的填充。
        let deepTint = palette.primary.adjustedPreservingHue(
            saturationMultiplier: 1.10,
            brightnessMultiplier: 0.84,
            minSaturation: 0.30,
            maxSaturation: 0.96,
            minBrightness: 0.40,
            maxBrightness: 0.82
        ).color
        return Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: width + 8, height: height + 4)
            .background {
                ZStack {
                    Capsule().fill(.white.opacity(colorScheme == .dark ? 0.10 : 0.22))
                    // 更深、更不透明的主色填充（之前 0.50 偏透明、偏浅）。
                    Capsule().fill(deepTint.opacity(colorScheme == .dark ? 0.86 : 0.80))
                    Capsule().fill(
                        LinearGradient(
                            colors: [.white.opacity(colorScheme == .dark ? 0.28 : 0.40), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .blendMode(.screen)
                }
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.80), tint.opacity(0.46), .white.opacity(0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.3
                    )
            }
            .shadow(color: deepTint.opacity(0.46), radius: 16, y: 7)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 7, y: 3)
    }

    private var gradientBody: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(AppColors.accentGradient, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.44), lineWidth: 0.9)
                    .blendMode(.screen)
            }
            .shadow(color: Color(nsColor: NSColor.systemCyan).opacity(0.26), radius: 16, y: 6)
    }
}

private struct MusicMiniTransportControls: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let showsSkipButtons: Bool
    @StateObject private var stateObserver: MusicMiniTransportStateObserver

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette, showsSkipButtons: Bool) {
        self.item = item
        self.controller = controller
        self.palette = palette
        self.showsSkipButtons = showsSkipButtons
        _stateObserver = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let state = stateObserver.state

        HStack(spacing: 8) {
            if showsSkipButtons {
                Button {
                    controller.seek(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .disabled(!state.canControl)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            Button {
                playPreviousTrack()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!state.canControl)

            Button {
                if state.canControl {
                    controller.togglePlay()
                } else {
                    controller.configureMusic(item: item, settings: appState.settings)
                }
            } label: {
                MusicPrimaryPlayButtonLabel(isPlaying: state.isPlaying)
            }
            .buttonStyle(.plain)
            .pointerLiquidEdge(cornerRadius: 17, tint: palette.accent.color, intensity: 1.08)
            .disabled(state.isPreparing)

            Button {
                playNextTrack()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(!state.canControl)

            if showsSkipButtons {
                Button {
                    controller.seek(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                }
                .disabled(!state.canControl)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: 30, cornerRadius: 15))
        .animation(AppMotion.fast, value: showsSkipButtons)
    }

    private func playPreviousTrack() {
        if appState.musicRepeatMode == .repeatOne {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: -1)
        }
    }

    private func playNextTrack() {
        if appState.musicRepeatMode == .repeatOne {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: 1)
        }
    }
}

private struct MusicMiniTransportState: Equatable {
    let isPlaying: Bool
    let canControl: Bool
    let isPreparing: Bool
}

@MainActor
private final class MusicMiniTransportStateObserver: ObservableObject {
    @Published private(set) var state: MusicMiniTransportState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest3(
            controller.$isPlaying,
            controller.$isPreparing,
            controller.$errorMessage
        ).sink { [weak self] isPlaying, isPreparing, errorMessage in
            guard let self else { return }
            let nextState = MusicMiniTransportState(
                isPlaying: isPlaying,
                canControl: errorMessage == nil && !isPreparing,
                isPreparing: isPreparing
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicMiniTransportState {
        MusicMiniTransportState(
            isPlaying: controller.isPlaying,
            canControl: controller.canControl,
            isPreparing: controller.isPreparing
        )
    }
}

private struct MusicMiniPresetSpectrum: View {
    private let controller: MpvPlayerController
    let palette: AlbumColorPalette

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
    }

    var body: some View {
        MusicMiniSpectrumLayerView(
            controller: controller,
            accentColor: palette.accent.nsColor
        )
        .frame(width: 25, height: 16, alignment: .bottom)
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.black.opacity(0.28))
                .overlay {
                    Capsule()
                        .fill(.white.opacity(0.12))
                        .blendMode(.screen)
                }
        }
        .allowsHitTesting(false)
        .onAppear {
            controller.setAudioSpectrumVisualizationActive(true)
        }
        .onDisappear {
            controller.setAudioSpectrumVisualizationActive(false)
        }
    }
}

private struct MusicMiniSpectrumLayerView: NSViewRepresentable {
    let controller: MpvPlayerController
    let accentColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SpectrumBarsView {
        let view = SpectrumBarsView(frame: .zero)
        context.coordinator.attach(controller: controller, view: view, accentColor: accentColor)
        view.update(
            bands: controller.audioSpectrumBands,
            isPlaying: controller.isPlaying,
            accentColor: accentColor,
            animated: false
        )
        return view
    }

    func updateNSView(_ nsView: SpectrumBarsView, context: Context) {
        context.coordinator.attach(controller: controller, view: nsView, accentColor: accentColor)
        nsView.updateAccentColor(accentColor)
    }

    @MainActor
    final class Coordinator {
        private weak var controller: MpvPlayerController?
        private weak var view: SpectrumBarsView?
        private var cancellable: AnyCancellable?
        private var accentColor = NSColor.systemBlue

        func attach(controller: MpvPlayerController, view: SpectrumBarsView, accentColor: NSColor) {
            self.view = view
            self.accentColor = accentColor
            guard self.controller !== controller else {
                view.updateAccentColor(accentColor)
                return
            }
            self.controller = controller
            cancellable = Publishers.CombineLatest(
                controller.$audioSpectrumBands,
                controller.$isPlaying
            ).sink { [weak self] bands, isPlaying in
                guard let self, let view = self.view else { return }
                view.update(
                    bands: bands,
                    isPlaying: isPlaying,
                    accentColor: self.accentColor,
                    animated: true
                )
            }
        }
    }

    final class SpectrumBarsView: NSView {
        private var barLayers: [CAGradientLayer] = []
        private var bandBuckets: [Int] = []
        private var isPlaying = false
        private var accentColor = NSColor.systemBlue
        private var needsColorUpdate = true
        private var lastLaidOutBounds: CGRect = .zero
        private var lastBarCount = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // 频谱条必须裁剪在小框内：收起态迷你卡里若不裁剪，异常尺寸的条会溢出卡片。
            layer?.masksToBounds = true
            rebuildLayers(count: 8)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.masksToBounds = true
            rebuildLayers(count: 8)
        }

        override func layout() {
            super.layout()
            layoutBarsIfNeeded(animated: false, forceGeometry: true)
        }

        func update(bands: [CGFloat], isPlaying: Bool, accentColor: NSColor, animated: Bool) {
            let nextBuckets = Self.bucketedBands(bands)
            let nextCount = max(nextBuckets.count, 1)
            if barLayers.count != nextCount {
                rebuildLayers(count: nextCount)
            }

            let playingChanged = self.isPlaying != isPlaying
            let colorChanged = self.accentColor != accentColor || playingChanged
            let bandsChanged = bandBuckets != nextBuckets

            self.bandBuckets = nextBuckets
            self.isPlaying = isPlaying
            if self.accentColor != accentColor {
                self.accentColor = accentColor
            }
            needsColorUpdate = needsColorUpdate || colorChanged

            guard bandsChanged || playingChanged || colorChanged || bounds != lastLaidOutBounds || barLayers.count != lastBarCount else {
                return
            }
            layoutBarsIfNeeded(animated: animated, forceGeometry: false)
        }

        func updateAccentColor(_ accentColor: NSColor) {
            guard self.accentColor != accentColor else { return }
            self.accentColor = accentColor
            needsColorUpdate = true
            layoutBarsIfNeeded(animated: false, forceGeometry: false)
        }

        private func rebuildLayers(count: Int) {
            barLayers.forEach { $0.removeFromSuperlayer() }
            barLayers = (0..<count).map { _ in
                let layer = CAGradientLayer()
                layer.cornerRadius = 1.6
                layer.masksToBounds = true
                // 底部锚点（非翻转 NSView 为 y-up，y=0 即底边）；高度通过 transform 缩放。
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.0)
                layer.startPoint = CGPoint(x: 0.5, y: 1)
                layer.endPoint = CGPoint(x: 0.5, y: 0)
                // 不在此设置非单位 transform：否则首次 layout 设置几何时会被 transform 污染尺寸。
                self.layer?.addSublayer(layer)
                return layer
            }
            needsColorUpdate = true
            lastLaidOutBounds = .zero
            lastBarCount = 0
        }

        private func layoutBarsIfNeeded(animated: Bool, forceGeometry: Bool) {
            guard bounds.width > 0, bounds.height > 0, !barLayers.isEmpty else { return }
            let count = barLayers.count
            let spacing: CGFloat = 2.2
            let barWidth: CGFloat = 3.2
            let maxBarHeight: CGFloat = 16
            let totalWidth = CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * spacing
            let originX = max((bounds.width - totalWidth) / 2, 0)
            let geometryChanged = forceGeometry || bounds != lastLaidOutBounds || count != lastBarCount

            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(animated ? 0.12 : 0)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            for index in barLayers.indices {
                let bucket = index < bandBuckets.count ? bandBuckets[index] : Self.minimumBandBucket
                let clamped = Self.bandLevel(from: bucket)
                let activeHeight = 4 + clamped * 12
                let height = isPlaying ? activeHeight : max(4, activeHeight * 0.48)
                let x = originX + CGFloat(index) * (barWidth + spacing)
                let bar = barLayers[index]
                if geometryChanged {
                    // 关键：设置 bounds/position 前先把 transform 复位为单位矩阵，
                    // 否则在非单位 scale 下设 frame/bounds 会被 CA 反算放大尺寸，导致频谱条溢出卡片。
                    bar.transform = CATransform3DIdentity
                    bar.anchorPoint = CGPoint(x: 0.5, y: 0.0)
                    bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: maxBarHeight)
                    bar.position = CGPoint(x: x + barWidth / 2, y: 0)
                }
                if needsColorUpdate {
                    bar.opacity = Float(isPlaying ? 1.0 : 0.58)
                    bar.colors = [
                        NSColor.white.withAlphaComponent(isPlaying ? 0.92 : 0.58).cgColor,
                        accentColor.withAlphaComponent(isPlaying ? 0.72 : 0.38).cgColor
                    ]
                }
                bar.transform = CATransform3DMakeScale(1, max(height / maxBarHeight, 0.12), 1)
            }
            CATransaction.commit()
            needsColorUpdate = false
            lastLaidOutBounds = bounds
            lastBarCount = count
        }

        private static let minimumBandBucket = 12
        private static let maximumBandBucket = 100

        private static func bucketedBands(_ bands: [CGFloat]) -> [Int] {
            guard !bands.isEmpty else { return [minimumBandBucket] }
            return bands.map { band in
                let clamped = min(max(band, 0.12), 1)
                return Int((clamped * CGFloat(maximumBandBucket)).rounded())
            }
        }

        private static func bandLevel(from bucket: Int) -> CGFloat {
            let clamped = min(max(bucket, minimumBandBucket), maximumBandBucket)
            return CGFloat(clamped) / CGFloat(maximumBandBucket)
        }
    }
}

private struct MusicMiniProgressControl: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
    }

    var body: some View {
        HStack(spacing: 7) {
            MusicRepeatModeButton(size: 30, palette: palette)

            MusicShuffleButton(size: 30, palette: palette)

            MusicMiniProgressTimeline(controller: controller, palette: palette)
                .layoutPriority(2)
        }
    }
}

private struct MusicMiniProgressTimeline: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var progressObserver: MusicExpandedProgressStateObserver

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _progressObserver = StateObject(wrappedValue: MusicExpandedProgressStateObserver(controller: controller))
    }

    var body: some View {
        let state = progressObserver.state

        HStack(spacing: 7) {
            Text(state.formattedCurrentTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            MusicMiniSeekSlider(
                currentTime: state.currentTime,
                duration: state.duration,
                isEnabled: state.canControl && state.duration > 0,
                palette: palette,
                usesPaletteTint: false,
                onScrubBegin: { controller.beginScrubbing(to: $0) },
                onScrubChange: { controller.updateScrubbing(to: $0) },
                onSeek: { controller.finishScrubbing(to: $0) }
            )
            .layoutPriority(2)

            Text(state.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
        }
    }
}

private struct MusicMiniSeekSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    let currentTime: Double
    let duration: Double
    let isEnabled: Bool
    let palette: AlbumColorPalette
    var trackHeight: CGFloat = 5
    var thumbSize: CGFloat = 14
    var usesPaletteTint = true
    let onScrubBegin: (Double) -> Void
    let onScrubChange: (Double) -> Void
    let onSeek: (Double) -> Void
    @State private var draggingProgress: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = clamped(draggingProgress ?? normalizedProgress)
            let fillWidth = max(width * CGFloat(progress), 0)
            let thumbRadius = thumbSize / 2
            let thumbX = min(max(fillWidth, thumbRadius), width - thumbRadius)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.30 : (usesPaletteTint ? 0.18 : 0.12)))
                    .overlay {
                        Capsule()
                            .fill(.white.opacity(colorScheme == .dark ? 0.08 : (usesPaletteTint ? 0.16 : 0.30)))
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.28), lineWidth: 0.6)
                    }
                    .frame(height: trackHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: fillColors(isEnabled: isEnabled),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: trackHeight)

                Circle()
                    .fill(.white.opacity(isEnabled ? 0.96 : 0.70))
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(colorScheme == .dark ? 0.32 : 0.84), lineWidth: 0.8)
                    }
                    .shadow(color: (usesPaletteTint ? palette.accent.color : Color(nsColor: NSColor.systemBlue)).opacity(isEnabled ? 0.16 : 0), radius: 6, y: 2)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 4, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: thumbX - thumbRadius)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let progress = clamped(Double(value.location.x / width))
                        let target = progress * max(duration, 1)
                        let wasDragging = draggingProgress != nil
                        draggingProgress = progress
                        if wasDragging {
                            onScrubChange(target)
                        } else {
                            onScrubBegin(target)
                        }
                    }
                    .onEnded { value in
                        guard isEnabled else {
                            draggingProgress = nil
                            return
                        }
                        let progress = clamped(Double(value.location.x / width))
                        draggingProgress = nil
                        onSeek(progress * max(duration, 1))
                    }
            )
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int((normalizedProgress * 100).rounded()))%")
    }

    private var normalizedProgress: Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
        return currentTime / duration
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func fillColors(isEnabled: Bool) -> [Color] {
        if usesPaletteTint {
            // 单色：进度条只用专辑主色，不再用主色→accent 的多色渐变。
            let base = palette.primary.color.opacity(isEnabled ? 0.98 : 0.42)
            return [base, base]
        }
        return [
            Color(nsColor: NSColor.systemBlue).opacity(isEnabled ? 0.94 : 0.38),
            Color(nsColor: NSColor.systemCyan).opacity(isEnabled ? 0.78 : 0.30)
        ]
    }
}

private struct MusicMiniUtilityControls: View {
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let onRequestClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MusicQueueButton(item: item, palette: palette, size: 30, glowStrength: 1.12)

            AirPlayRoutePickerControl(
                session: controller.routePickerSession,
                player: controller.routePickerPlayer,
                tintColor: NSColor(calibratedRed: 0.00, green: 0.30, blue: 0.68, alpha: 0.96),
                activeTintColor: NSColor(calibratedRed: 0.00, green: 0.22, blue: 0.54, alpha: 1.0),
                lightTint: Color(nsColor: NSColor(calibratedRed: 0.00, green: 0.34, blue: 0.76, alpha: 1.0)),
                size: 30,
                cornerRadius: 15,
                glowStrength: 0.92,
                onRoutesWillBegin: {
                    controller.prepareForMusicAirPlayRouteSelection()
                },
                onRoutesDidEnd: {
                    controller.refreshMusicAirPlayRoute(afterRoutePicker: true)
                }
            )

            MusicFavoriteButton(item: item, palette: palette, size: 30, glowStrength: 0.78)

            MusicMiniVolumeButton(controller: controller, palette: palette)

            Button {
                onRequestClose()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(MusicIconButtonStyle(palette: palette, size: 30, cornerRadius: 15, glowStrength: 0.48))
            .help("关闭播放器")
        }
    }
}

private struct MusicMiniVolumeButton: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var volumeObserver: MusicExpandedVolumeStateObserver
    @State private var showVolumeControl = false

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _volumeObserver = StateObject(wrappedValue: MusicExpandedVolumeStateObserver(controller: controller))
    }

    var body: some View {
        Button {
            showVolumeControl.toggle()
        } label: {
            Image(systemName: volumeSystemImage)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: 30, cornerRadius: 15, glowStrength: 0.62))
        .disabled(!volumeObserver.state.canControl)
        .popover(isPresented: $showVolumeControl, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: volumeSystemImage)
                        .foregroundStyle(.secondary)
                    Text("音量")
                        .font(.headline)
                    Spacer()
                    Text("\(Int((volumeObserver.state.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            Slider(value: Binding(get: {
                Double(volumeObserver.state.volume)
            }, set: { newValue in
                controller.setVolume(Float(newValue))
            }), in: 0...1)
            .frame(width: 220)
        }
        .padding(16)
        .frame(width: 260)
        .modifier(MusicPopoverGlass(palette: palette, cornerRadius: 18))
    }
        .help("音量")
    }

    private var volumeSystemImage: String {
        let volume = volumeObserver.state.volume
        if volume == 0 { return "speaker.slash" }
        if volume < 0.45 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }
}

private struct MusicQueuePopover: View {
    @EnvironmentObject private var appState: AppState
    let currentItem: MediaItem
    var palette: AlbumColorPalette = .fallback
    @State private var draggedItem: MediaItem?
    @State private var playlistCreationRequest: MusicPlaylistCreationRequest?
    @State private var didRestoreScroll = false
    @StateObject private var dragCoordinator = MusicQueueDragCoordinator()
    // 滑动停留位置只记在本地 @State，滚动时不写 @Published AppState（否则每出现一行就触发整树重算→卡顿），
    // 仅在弹层关闭时回写一次。
    @State private var pendingScrollAnchorID: String?

    var body: some View {
        let queue = appState.musicQueue
        let rows = MusicQueueRowModel.models(from: queue)
        let queueIDs = queue.map(\.id)
        let queueIndexByID = Dictionary(
            queue.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("播放队列")
                    .font(.headline)
                Spacer()
                MusicPlaylistActionsMenu(
                    tracks: queue,
                    title: "存入歌单",
                    newPlaylistName: "新建歌单",
                    suggestedName: "播放队列",
                    onCreateNew: { playlistCreationRequest = $0 }
                )
                .disabled(queue.isEmpty)

                Button(role: .destructive) {
                    appState.clearMusicQueue(keepingCurrent: true)
                } label: {
                    Label("清空", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 28, thickness: 1.22))
                .disabled(!queue.contains { $0.id != currentItem.id })
            }
            .padding(.horizontal, 2)

            if queue.isEmpty {
                Text("队列为空")
                    .foregroundStyle(.secondary)
                    .frame(width: 420, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(rows) { row in
                            MusicQueueRow(
                                row: row,
                                isCurrent: row.id == currentItem.id,
                                onRemove: {
                                    appState.removeFromMusicQueue(row.track)
                                }
                            )
                            .equatable()
                            .id(row.id)
                            .onAppear {
                                guard didRestoreScroll, draggedItem == nil else { return }
                                // 只更新本地状态，不触碰 @Published（避免滚动时整树重算）。
                                pendingScrollAnchorID = row.id
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                pendingScrollAnchorID = row.id
                                appState.musicQueueScrollAnchorID = row.id
                                appState.play(row.track)
                            }
                            .onDrag {
                                draggedItem = row.track
                                return NSItemProvider(object: row.id as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: MusicQueueDropDelegate(
                                    targetItem: row.track,
                                    items: queue,
                                    indexByID: queueIndexByID,
                                    draggedItem: $draggedItem,
                                    coordinator: dragCoordinator,
                                    move: appState.moveMusicQueueItems
                                )
                            )
                            .contextMenu {
                                Button("播放") {
                                    appState.musicQueueScrollAnchorID = row.id
                                    appState.play(row.track)
                                }
                                MusicPlaylistActionsMenu(
                                    tracks: [row.track],
                                    suggestedName: row.titleText,
                                    onCreateNew: { playlistCreationRequest = $0 }
                                )
                                Button("移出队列") { appState.removeFromMusicQueue(row.track) }
                                    .disabled(row.id == currentItem.id)
                            }
                            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .suppressHoverEffectsDuringScroll()
                    .suppressListHighlight()
                    .glassPerformanceMode(.minimal)
                    .preferStaticGlassSurfaces(true)
                    .environment(\.defaultMinListRowHeight, 0)
                    .frame(width: 430, height: 320)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .onAppear {
                        restoreQueueScroll(proxy: proxy, queue: queue)
                    }
                    .onChange(of: queueIDs) { _ in
                        guard draggedItem == nil else { return }
                        restoreQueueScroll(proxy: proxy, queue: queue)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .modifier(MusicPopoverGlass(palette: palette, cornerRadius: 24))
        // 去掉队列弹出层的鼠标光效：移除 MusicPlayerPointerLightScope 后，弹层内 FloatingLyricsGlass 的
        // 继承式光晕拿不到指针上下文→不再渲染；同时少了每次指针/滚动移动对整张弹层玻璃的重合成，滚动更顺。
        .glassPerformanceMode(.minimal)
        .environment(\.suppressPointerHoverDuringScroll, true)
        .onDisappear {
            // 弹层关闭时一次性回写滑动停留位置。
            if let pendingScrollAnchorID {
                appState.musicQueueScrollAnchorID = pendingScrollAnchorID
            }
        }
        .sheet(item: $playlistCreationRequest) { request in
            MusicPlaylistCreationSheet(
                request: request,
                onCreate: { name in
                    appState.createMusicPlaylist(name: name, tracks: request.tracks)
                    playlistCreationRequest = nil
                },
                onCancel: {
                    playlistCreationRequest = nil
                }
            )
            .environmentObject(appState)
        }
    }

    private func restoreQueueScroll(proxy: ScrollViewProxy, queue: [MediaItem]) {
        guard draggedItem == nil else { return }
        didRestoreScroll = false
        let targetID: String
        if let savedID = appState.musicQueueScrollAnchorID,
           queue.contains(where: { $0.id == savedID }) {
            targetID = savedID
        } else {
            targetID = currentItem.id
            appState.musicQueueScrollAnchorID = targetID
        }
        pendingScrollAnchorID = targetID
        DispatchQueue.main.async {
            proxy.scrollTo(targetID, anchor: .top)
            didRestoreScroll = true
        }
    }
}

@MainActor
private final class MusicQueueDragCoordinator: ObservableObject {
    private var lastMoveDate = Date.distantPast
    private var lastTargetID: String?

    func shouldMove(to targetID: String) -> Bool {
        let now = Date()
        defer {
            lastMoveDate = now
            lastTargetID = targetID
        }
        if lastTargetID == targetID {
            return false
        }
        return now.timeIntervalSince(lastMoveDate) >= 0.115
    }

    func reset() {
        lastMoveDate = .distantPast
        lastTargetID = nil
    }
}

private struct MusicQueueRowModel: Identifiable, Equatable {
    let track: MediaItem
    let titleText: String
    let subtitleText: String
    let posterPath: String?

    var id: String { track.id }

    static func models(from queue: [MediaItem]) -> [MusicQueueRowModel] {
        queue.map { item in
            MusicQueueRowModel(
                track: item,
                titleText: item.title,
                subtitleText: item.artistAlbumLine ?? "未知艺人",
                posterPath: item.posterPath
            )
        }
    }
}

private struct MusicQueueRow: View, Equatable {
    let row: MusicQueueRowModel
    let isCurrent: Bool
    let onRemove: () -> Void
    private static let artworkCacheSize = CGSize(width: 76, height: 76)

    static func == (lhs: MusicQueueRow, rhs: MusicQueueRow) -> Bool {
        lhs.row == rhs.row && lhs.isCurrent == rhs.isCurrent
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.58))
                .frame(width: 18)

            PosterImage(path: row.posterPath, title: row.titleText, mediaType: row.track.type, cacheTargetSize: Self.artworkCacheSize)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.titleText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(row.subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary.opacity(isCurrent ? 0.28 : 0.62))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)
            .help(isCurrent ? "正在播放的歌曲不能移出" : "移出队列")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 48)
        .background(.white.opacity(isCurrent ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(isCurrent ? 0.28 : 0.14), lineWidth: 1)
        }
    }
}

private struct MusicQueueDropDelegate: DropDelegate {
    let targetItem: MediaItem
    let items: [MediaItem]
    let indexByID: [String: Int]
    @Binding var draggedItem: MediaItem?
    let coordinator: MusicQueueDragCoordinator
    let move: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem.id != targetItem.id,
              coordinator.shouldMove(to: targetItem.id),
              let sourceIndex = indexByID[draggedItem.id],
              let targetIndex = indexByID[targetItem.id],
              sourceIndex < items.count,
              targetIndex < items.count else {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            move(IndexSet(integer: sourceIndex), targetIndex > sourceIndex ? targetIndex + 1 : targetIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        coordinator.reset()
        draggedItem = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if draggedItem == nil {
            coordinator.reset()
        }
    }
}

private struct MusicQueueButton: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let palette: AlbumColorPalette
    var size: CGFloat = 30
    var glowStrength: Double = 1
    @State private var showQueue = false

    var body: some View {
        Button {
            showQueue.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: size, cornerRadius: size / 2, glowStrength: glowStrength))
        .popover(isPresented: $showQueue, arrowEdge: .bottom) {
            MusicQueuePopover(currentItem: item, palette: palette)
                .environmentObject(appState)
        }
        .help("播放队列")
        .accessibilityLabel("播放队列")
    }
}

private struct MusicShuffleButton: View {
    @EnvironmentObject private var appState: AppState
    var size: CGFloat = 30
    var palette: AlbumColorPalette?

    var body: some View {
        Button {
            appState.toggleMusicShuffle()
        } label: {
            MusicModeIcon(
                systemImage: "shuffle",
                isActive: appState.musicShuffleEnabled,
                size: size,
                palette: palette
            )
        }
        .buttonStyle(.plain)
        .help(appState.musicShuffleEnabled ? "关闭随机播放" : "随机播放")
        .accessibilityLabel(appState.musicShuffleEnabled ? "关闭随机播放" : "随机播放")
    }
}

private struct MusicRepeatModeButton: View {
    @EnvironmentObject private var appState: AppState
    var size: CGFloat = 30
    var palette: AlbumColorPalette?

    var body: some View {
        Button {
            appState.cycleMusicRepeatMode()
        } label: {
            MusicModeIcon(
                systemImage: appState.musicRepeatMode.systemImage,
                isActive: appState.musicRepeatMode != .sequential,
                size: size,
                palette: palette
            )
        }
        .buttonStyle(.plain)
        .help(appState.musicRepeatMode.title)
        .accessibilityLabel(appState.musicRepeatMode.title)
    }
}

private struct MusicFavoriteButton: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let palette: AlbumColorPalette
    var size: CGFloat = 30
    var glowStrength: Double = 1

    var body: some View {
        Button {
            appState.toggleFavorite(item)
        } label: {
            Image(systemName: item.favorite ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.favorite ? Color.red : Color.primary.opacity(0.66))
                .frame(width: size, height: size)
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: size, cornerRadius: size / 2, glowStrength: glowStrength))
        .help(item.favorite ? "取消喜欢" : "我喜欢")
        .accessibilityLabel(item.favorite ? "取消喜欢" : "我喜欢")
    }
}

private struct MusicIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette
    var size: CGFloat = 30
    var cornerRadius: CGFloat = 15
    var glowStrength: Double = 1

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glow = min(max(glowStrength, 0.25), 1.45)

        configuration.label
            .frame(width: size, height: size)
            // P0：去掉 .regularMaterial 实时模糊（底栏/展开页有 7+ 个图标按钮，
            // 每个 material 都是一块离屏 backdrop 模糊）。改用实色磨砂底，视觉接近但零离屏通道。
            // 略降灰度：白底更实一点（亮 0.40→0.46，暗 0.10→0.12），减少灰背景透出的灰感。
            .background(
                shape.fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.46))
            )
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.15 : 0.56),
                            palette.primary.color.opacity((colorScheme == .dark ? 0.14 : 0.10) * glow),
                            .white.opacity(colorScheme == .dark ? 0.05 : 0.26)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.58), lineWidth: 0.9)
                    .blur(radius: 0.5)
                    .blendMode(.screen)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.30 : 0.80),
                            palette.accent.color.opacity((colorScheme == .dark ? 0.18 : 0.26) * glow),
                            .white.opacity(colorScheme == .dark ? 0.10 : 0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: palette.primary.color.opacity((colorScheme == .dark ? 0.10 : 0.075) * glow), radius: 8 + 5 * glow, y: 5)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.052), radius: 10, y: 5)
            .pointerLiquidEdge(cornerRadius: cornerRadius, tint: palette.primary.color, intensity: 1.10 * glow)
            .opacity(configuration.isPressed ? 0.90 : 1)
            .animation(AppMotion.fast, value: configuration.isPressed)
    }
}

private struct MusicModeIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let isActive: Bool
    var size: CGFloat = 30
    var palette: AlbumColorPalette?

    var body: some View {
        let tint = palette?.primary.color ?? AppColors.pointerLightTint
        let accent = palette?.accent.color ?? Color.accentColor
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isActive ? accent : .secondary)
            .frame(width: size, height: size)
            // P0：去掉 .regularMaterial（循环/随机图标在底栏也会出现），改实色磨砂底。
            .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.42)))
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.15 : 0.58),
                                tint.opacity(colorScheme == .dark ? 0.15 : 0.12),
                                .white.opacity(colorScheme == .dark ? 0.05 : 0.26)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                Circle().stroke(
                    LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.30 : 0.78),
                                tint.opacity(colorScheme == .dark ? 0.12 : 0.22),
                                AppColors.cleanPanelBorder
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                    lineWidth: 1
                )
            }
            .shadow(color: tint.opacity(colorScheme == .dark ? 0.050 : 0.045), radius: 9, y: 4)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.13 : 0.045), radius: 8, y: 4)
            .pointerLiquidEdge(cornerRadius: size / 2, tint: tint, intensity: 0.96)
    }
}

private struct LRCLibLyrics: Decodable {
    var plainLyrics: String?
    var syncedLyrics: String?
}

private struct MusicChromeButtonContent: View {
    let systemImage: String
    let palette: AlbumColorPalette

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
            Text("收起")
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(Color.primary.opacity(0.82))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: 23, tintStrength: 1.0))
        .pointerLiquidEdge(cornerRadius: 23, tint: palette.primary.color, intensity: 1.1)
    }
}

private struct MusicExpandedLayout {
    let stackedLayout: Bool
    let sideInset: CGFloat
    let verticalInset: CGFloat
    let leftRect: CGRect
    let lyricsRect: CGRect
    let posterSize: CGFloat
    let minimizeButtonRect: CGRect
    let albumLightCenter: CGPoint
    let stackedLyricsHeight: CGFloat

    init(size: CGSize) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let compactWidth = width < 1180

        sideInset = compactWidth ? 30 : 54
        let panelInset = min(max(height * 0.072, compactWidth ? 56 : 72), compactWidth ? 82 : 104)
        verticalInset = panelInset
        let contentLeadingInset = sideInset + (compactWidth ? 8 : 22)
        let trailingInset = contentLeadingInset
        let desiredGap = compactWidth ? 30.0 : 46.0
        let minimumGap = compactWidth ? 22.0 : 34.0
        let minimumLeftWidth = compactWidth ? 404.0 : 432.0
        let minimumLyricsWidth = compactWidth ? 360.0 : 460.0
        let availableColumnsWidth = width - contentLeadingInset - trailingInset
        let canFitColumns = availableColumnsWidth >= minimumLeftWidth + minimumLyricsWidth + minimumGap
        stackedLayout = !canFitColumns || height < 640

        let minimizeButtonSize = CGSize(width: compactWidth ? 72 : 82, height: 46)
        let minimizeLeadingInset = stackedLayout ? sideInset : contentLeadingInset
        let minimizeTopInset = stackedLayout ? 18.0 : panelInset
        minimizeButtonRect = CGRect(origin: CGPoint(x: minimizeLeadingInset, y: minimizeTopInset), size: minimizeButtonSize)

        let desiredLeftWidth = min(max(width * 0.34, minimumLeftWidth), compactWidth ? 472 : 540)
        let maximumLeftWidth = max(minimumLeftWidth, availableColumnsWidth - minimumLyricsWidth - minimumGap)
        let leftWidth = min(desiredLeftWidth, maximumLeftWidth)
        let remainingAfterLeft = max(0, availableColumnsWidth - leftWidth)
        let gap = min(desiredGap, max(minimumGap, remainingAfterLeft - minimumLyricsWidth))
        let lyricsWidth = max(minimumLyricsWidth, remainingAfterLeft - gap)
        let availableHeight = max(320.0, height - panelInset * 2)
        stackedLyricsHeight = min(max(height * 0.58, 320), 520)

        let leftFrame = CGRect(
            x: contentLeadingInset,
            y: panelInset,
            width: leftWidth,
            height: availableHeight
        )
        leftRect = leftFrame

        let lyricsX = width - trailingInset - lyricsWidth
        let lyricsFrame = CGRect(
            x: lyricsX,
            y: panelInset,
            width: lyricsWidth,
            height: availableHeight
        )
        lyricsRect = lyricsFrame

        let reservedForTitleAndControls = compactWidth ? 252.0 : 274.0
        let heightBoundedPoster = max(174.0, availableHeight - reservedForTitleAndControls)
        let resolvedPosterSize = min(leftWidth - 64.0, heightBoundedPoster, availableHeight * 0.43, compactWidth ? 390.0 : 440.0)
        posterSize = resolvedPosterSize

        let controlsEstimate = compactWidth ? 132.0 : 142.0
        let posterBlockHeight = resolvedPosterSize + 16.0 + 82.0 + 16.0 + controlsEstimate
        let posterTop = leftFrame.minY + max(0, (availableHeight - posterBlockHeight) / 2)
        if stackedLayout {
            albumLightCenter = CGPoint(x: width * 0.34, y: min(max(height * 0.32, 210), height * 0.50))
        } else {
            albumLightCenter = CGPoint(x: leftFrame.midX, y: posterTop + resolvedPosterSize / 2)
        }
    }
}

/// 一次性预渲染封面高斯模糊：在后台线程把低分辨率封面糊成柔光底，结果缓存进 NSImage，
/// 之后只作为静态 CALayer 内容铺底，没有任何逐帧成本。
private enum MusicBackdropBlur {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func blurred(_ image: NSImage?, radius: Double = 22.0) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }

        let input = CIImage(cgImage: cgImage)
        // clamp 避免模糊在边缘出现透明衰减；半径相对 96px 取较大值，糊到看不出原图轮廓。
        let clamped = input.clampedToExtent()
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(clamped, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = blurFilter.outputImage else { return image }

        // 轻微提升饱和度，让取色更鲜明（与设计的“封面取色光效”一致）。
        let colored: CIImage
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(blurred, forKey: kCIInputImageKey)
            colorFilter.setValue(1.25, forKey: kCIInputSaturationKey)
            colored = colorFilter.outputImage ?? blurred
        } else {
            colored = blurred
        }

        let extent = input.extent
        guard let outputCG = context.createCGImage(colored, from: extent) else { return image }
        return NSImage(cgImage: outputCG, size: extent.size)
    }
}

private enum AlbumBloomImageBake {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func bakedGlowImage(from image: NSImage?) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }

        let canvasSide = 720
        let coverSide = CGFloat(canvasSide) / 3.3
        let coverRect = CGRect(
            x: (CGFloat(canvasSide) - coverSide) / 2,
            y: (CGFloat(canvasSide) - coverSide) / 2,
            width: coverSide,
            height: coverSide
        )
        guard let sourceCanvas = centeredArtworkCanvas(
            cgImage: cgImage,
            canvasSide: canvasSide,
            coverRect: coverRect
        ) else { return image }

        let input = CIImage(cgImage: sourceCanvas)
        let extent = input.extent
        let saturated: CIImage
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(input, forKey: kCIInputImageKey)
            colorFilter.setValue(1.28, forKey: kCIInputSaturationKey)
            colorFilter.setValue(-0.10, forKey: kCIInputBrightnessKey)
            colorFilter.setValue(1.02, forKey: kCIInputContrastKey)
            saturated = colorFilter.outputImage ?? input
        } else {
            saturated = input
        }

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(saturated.clampedToExtent(), forKey: kCIInputImageKey)
        blurFilter.setValue(54.0, forKey: kCIInputRadiusKey)
        let blurred = (blurFilter.outputImage ?? saturated).cropped(to: extent)

        guard let mask = bloomAlphaMask(size: extent.size, coverRect: coverRect) else { return image }
        let transparent = CIImage(color: .clear).cropped(to: extent)
        let masked: CIImage
        if let maskFilter = CIFilter(name: "CIBlendWithAlphaMask") {
            maskFilter.setValue(blurred, forKey: kCIInputImageKey)
            maskFilter.setValue(transparent, forKey: kCIInputBackgroundImageKey)
            maskFilter.setValue(CIImage(cgImage: mask), forKey: kCIInputMaskImageKey)
            masked = maskFilter.outputImage ?? blurred
        } else {
            masked = blurred
        }

        guard let output = context.createCGImage(masked, from: extent) else { return image }
        return NSImage(cgImage: output, size: extent.size)
    }

    private static func centeredArtworkCanvas(cgImage: CGImage, canvasSide: Int, coverRect: CGRect) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: canvasSide,
            height: canvasSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide))
        context.interpolationQuality = .high
        context.draw(cgImage, in: coverRect)
        return context.makeImage()
    }

    private static func bloomAlphaMask(size: CGSize, coverRect: CGRect) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cornerRadius = coverRect.width * 0.12
        let fadeDistance = min(size.width, size.height) * 0.36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let distance = roundedRectDistance(point: point, rect: coverRect, radius: cornerRadius)
                let normalized = min(max(distance / fadeDistance, 0), 1)
                let alpha: CGFloat = distance < 0 ? 0 : pow(1 - normalized, 2.15) * 0.82
                let value = UInt8((alpha * 255).rounded())
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = value
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func roundedRectDistance(point: CGPoint, rect: CGRect, radius: CGFloat) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let qx = abs(point.x - center.x) - (rect.width / 2 - radius)
        let qy = abs(point.y - center.y) - (rect.height / 2 - radius)
        let outsideX = max(qx, 0)
        let outsideY = max(qy, 0)
        let outside = hypot(outsideX, outsideY)
        let inside = min(max(qx, qy), 0)
        return outside + inside - radius
    }
}

private struct SendableMusicBackdropArtworkImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

private struct AlbumArtworkGlowLayer: View {
    let posterPath: String?
    let palette: AlbumColorPalette
    let glowScale: CGFloat
    let glowOpacity: Double
    let glowStrength: Double
    let colorScheme: ColorScheme
    @State private var artworkImage: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        LowResolutionArtworkGlowLayer(
            image: artworkImage,
            palette: palette,
            glowScale: glowScale,
            glowOpacity: glowOpacity,
            glowStrength: glowStrength,
            colorScheme: colorScheme
        )
        .task(id: posterPath ?? "") {
            await loadArtworkTexture()
        }
    }

    @MainActor
    private func loadArtworkTexture() async {
        let path = posterPath
        guard loadedPath != path else { return }
        loadedPath = path
        artworkImage = nil
        guard let path else { return }
        let texture = await Task.detached(priority: .utility) {
            SendableMusicBackdropArtworkImage(
                ArtworkImageCache.image(
                    path: path,
                    targetSize: CGSize(width: 88, height: 88)
                )
            )
        }.value
        guard loadedPath == path else { return }
        artworkImage = texture.image
    }
}

private struct LowResolutionArtworkGlowLayer: NSViewRepresentable {
    let image: NSImage?
    let palette: AlbumColorPalette
    let glowScale: CGFloat
    let glowOpacity: Double
    let glowStrength: Double
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView(frame: .zero)
        view.update(
            image: image,
            palette: palette,
            glowScale: glowScale,
            glowOpacity: glowOpacity,
            glowStrength: glowStrength,
            colorScheme: colorScheme
        )
        return view
    }

    func updateNSView(_ nsView: LayerView, context: Context) {
        nsView.update(
            image: image,
            palette: palette,
            glowScale: glowScale,
            glowOpacity: glowOpacity,
            glowStrength: glowStrength,
            colorScheme: colorScheme
        )
    }

    final class LayerView: NSView {
        private let imageLayer = CALayer()
        private let colorLayer = CAGradientLayer()
        private let ringLayer = CAShapeLayer()
        private weak var currentImage: NSImage?
        private var palette = AlbumColorPalette.fallback
        private var glowScale: CGFloat = 1
        private var glowOpacity: Double = 0
        private var glowStrength: Double = 0
        private var colorScheme: ColorScheme = .light

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        override func layout() {
            super.layout()
            applyLayout()
        }

        func update(
            image: NSImage?,
            palette: AlbumColorPalette,
            glowScale: CGFloat,
            glowOpacity: Double,
            glowStrength: Double,
            colorScheme: ColorScheme
        ) {
            self.palette = palette
            self.glowScale = glowScale
            self.glowOpacity = glowOpacity
            self.glowStrength = glowStrength
            self.colorScheme = colorScheme

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if currentImage !== image {
                currentImage = image
                imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            updateColors()
            applyLayout()
            CATransaction.commit()
        }

        private func configure() {
            wantsLayer = true
            layer?.masksToBounds = false

            // 修复“封面背后还有个封面”：发光层不再绘制原始封面图，只用专辑取色的径向光晕。
            // imageLayer 保留但恒定隐藏，避免重建图层结构。
            imageLayer.isHidden = true
            imageLayer.opacity = 0

            colorLayer.type = .radial
            colorLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
            colorLayer.endPoint = CGPoint(x: 1, y: 1)
            colorLayer.compositingFilter = "screenBlendMode"
            layer?.addSublayer(colorLayer)

            ringLayer.fillColor = NSColor.clear.cgColor
            ringLayer.lineWidth = 5
            ringLayer.compositingFilter = "screenBlendMode"
            layer?.addSublayer(ringLayer)
        }

        private func applyLayout() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let side = min(bounds.width, bounds.height)
            let glowSide = side * glowScale
            let rect = CGRect(
                x: (bounds.width - glowSide) / 2,
                y: (bounds.height - glowSide) / 2,
                width: glowSide,
                height: glowSide
            )
            // 光晕比封面更大，向四周扩散，呈现“照亮周围”的柔光而非第二张封面。
            let colorRect = rect.insetBy(dx: -side * 0.42, dy: -side * 0.42)

            colorLayer.frame = colorRect
            colorLayer.cornerRadius = colorRect.width / 2
            colorLayer.opacity = Float(min(max(glowStrength, 0), 1))

            let ringRect = rect.insetBy(dx: -side * 0.018, dy: -side * 0.018)
            ringLayer.frame = bounds
            ringLayer.path = CGPath(
                roundedRect: ringRect,
                cornerWidth: max(24, 34 * glowScale),
                cornerHeight: max(24, 34 * glowScale),
                transform: nil
            )
            ringLayer.opacity = Float(glowStrength)
        }

        private func updateColors() {
            // 多色径向光晕：主色→辅色→强调色→透明，染上专辑多彩光，避免单调。
            colorLayer.colors = [
                palette.glowPrimary.nsColor.withAlphaComponent((colorScheme == .dark ? 0.24 : 0.18) * glowOpacity).cgColor,
                palette.glowSecondary.nsColor.withAlphaComponent((colorScheme == .dark ? 0.16 : 0.12) * glowOpacity).cgColor,
                palette.glowAccent.nsColor.withAlphaComponent((colorScheme == .dark ? 0.10 : 0.075) * glowOpacity).cgColor,
                NSColor.clear.cgColor
            ]
            colorLayer.locations = [0, 0.34, 0.6, 1]
            ringLayer.strokeColor = palette.glowPrimary.nsColor
                .withAlphaComponent((colorScheme == .dark ? 0.14 : 0.12) * glowStrength)
                .cgColor
        }
    }
}

private struct FloatingLyricsGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.preferStaticGlassSurfaces) private var preferStaticGlassSurfaces
    @Environment(\.glassPerformanceMode) private var glassPerformanceMode
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat
    var tintStrength: Double = 1
    var isLyricsCard: Bool = false

    private var samplesPointer: Bool {
        !reduceMotion &&
        !suppressHoverDuringScroll &&
        !preferStaticGlassSurfaces &&
        glassPerformanceMode.allowsPointerSampling
    }

    private func tintOpacity(_ value: Double) -> Double {
        value * tintStrength
    }

    private var whiteFillOpacity: Double {
        // 降低白色填充，让 material 的磨砂透明感透出（之前几乎不透明，毫无层次）。
        colorScheme == .dark ? 0.020 : 0.055
    }

    private var baseTintOpacity: Double {
        // 专辑色 tint 大幅降低：只做轻染色，保留玻璃透明度，能隐约看到下层。
        colorScheme == .dark ? 0.26 : 0.18
    }

    private var topGlassOpacity: Double {
        if isLyricsCard {
            return colorScheme == .dark ? 0.12 : 0.22
        }
        return colorScheme == .dark ? 0.12 : 0.22
    }

    private var frostTextureOpacity: Double {
        // 以控制栏为准统一：歌词卡不再额外加重磨砂纹理（原 0.090/0.070），与控制栏取同值。
        colorScheme == .dark ? 0.060 : 0.080
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // 厚玻璃质感（非亚克力白板）：
        // 1) 真实窗口材质做磨砂底，透出下层专辑色与桌面；
        // 2) 一层中性偏冷的暗色 tint（不是白）压住亮度，避免发白发灰像亚克力；
        // 3) 顶部一条很窄的高光 + 一圈细发丝描边，制造“玻璃边缘”的厚度感；
        // 不再堆叠 8 层白色渐变。
        // 降低灰度：压暗的中性 tint 调淡（亮 0.10→0.055，暗 0.28→0.19），让卡片更通透、少一层灰膜，
        // 玻璃磨砂质感仍由下方 material 提供。
        // 再降一档灰度（亮 0.055→0.038，暗 0.19→0.15）：卡片/控制栏更通透、灰膜更薄。
        let glassTint = colorScheme == .dark
            ? Color.black.opacity(isLyricsCard ? 0.12 : 0.13)
            : Color(red: 0.10, green: 0.12, blue: 0.16).opacity(isLyricsCard ? 0.024 : 0.030)
        let albumTint = palette.albumGlassBaseColor(for: colorScheme)
            .opacity((colorScheme == .dark ? 0.18 : 0.105) * tintStrength)

        return content
            .background {
                // 统一玻璃面板：歌词卡与控制栏/收起按钮用同一份真实 material（.hudWindow/.withinWindow），
                // 颜色与质感完全一致——之前歌词卡用静态白色磨砂 fill 会比控制栏更灰更平，故回归 material 统一。
                AppKitVisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
            .background(shape.fill(glassTint))
            .background(shape.fill(albumTint))
            .overlay {
                LyricsCardEffectLayerView(
                    cornerRadius: cornerRadius,
                    intensity: isLyricsCard ? 0.70 : 0.95,
                    colorScheme: colorScheme,
                    isEnabled: samplesPointer
                )
                .allowsHitTesting(false)
            }
            // 顶部高光：很窄、只在最上方一点点，模拟玻璃上沿受光。
            .overlay(alignment: .top) {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.12 : 0.30),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            }
            // 发丝描边：上亮下暗，给玻璃一个清晰但克制的边。
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.34 : 0.68),
                            .white.opacity(colorScheme == .dark ? 0.08 : 0.18),
                            .black.opacity(colorScheme == .dark ? 0.16 : 0.045)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .background {
                GlassPanelShadowLayer(
                    palette: palette,
                    colorScheme: colorScheme,
                    cornerRadius: cornerRadius,
                    tintStrength: tintStrength,
                    isLyricsCard: isLyricsCard
                )
                .allowsHitTesting(false)
            }
    }
}

private struct GlassPanelShadowLayer: NSViewRepresentable {
    let palette: AlbumColorPalette
    let colorScheme: ColorScheme
    let cornerRadius: CGFloat
    let tintStrength: Double
    let isLyricsCard: Bool

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView(frame: .zero)
        view.update(
            palette: palette,
            colorScheme: colorScheme,
            cornerRadius: cornerRadius,
            tintStrength: tintStrength,
            isLyricsCard: isLyricsCard
        )
        return view
    }

    func updateNSView(_ nsView: LayerView, context: Context) {
        nsView.update(
            palette: palette,
            colorScheme: colorScheme,
            cornerRadius: cornerRadius,
            tintStrength: tintStrength,
            isLyricsCard: isLyricsCard
        )
    }

    final class LayerView: NSView {
        private let colorShadowLayer = CALayer()
        private let depthShadowLayer = CALayer()
        private var palette = AlbumColorPalette.fallback
        private var colorScheme: ColorScheme = .light
        private var cornerRadius: CGFloat = 24
        private var tintStrength: Double = 1
        private var isLyricsCard = false

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        override func layout() {
            super.layout()
            applyLayout()
        }

        func update(
            palette: AlbumColorPalette,
            colorScheme: ColorScheme,
            cornerRadius: CGFloat,
            tintStrength: Double,
            isLyricsCard: Bool
        ) {
            self.palette = palette
            self.colorScheme = colorScheme
            self.cornerRadius = cornerRadius
            self.tintStrength = tintStrength
            self.isLyricsCard = isLyricsCard

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateShadowStyle()
            applyLayout()
            CATransaction.commit()
        }

        private func configure() {
            wantsLayer = true
            layer?.masksToBounds = false
            for shadowLayer in [colorShadowLayer, depthShadowLayer] {
                shadowLayer.masksToBounds = false
                shadowLayer.shouldRasterize = true
                shadowLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
                shadowLayer.backgroundColor = NSColor.white.withAlphaComponent(0.002).cgColor
                layer?.addSublayer(shadowLayer)
            }
        }

        private func applyLayout() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let shadowRect = bounds.insetBy(dx: 1, dy: 1)
            let shadowPath = CGPath(
                roundedRect: shadowRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            colorShadowLayer.frame = bounds
            depthShadowLayer.frame = bounds
            colorShadowLayer.cornerRadius = cornerRadius
            depthShadowLayer.cornerRadius = cornerRadius
            colorShadowLayer.shadowPath = shadowPath
            depthShadowLayer.shadowPath = shadowPath
        }

        private func updateShadowStyle() {
            let tint = max(0.35, min(tintStrength, 1.4))
            let colorOpacity = Float((colorScheme == .dark ? 0.24 : 0.18) * tint)
            colorShadowLayer.shadowColor = palette.primary.nsColor.cgColor
            colorShadowLayer.shadowOpacity = colorOpacity
            colorShadowLayer.shadowRadius = isLyricsCard ? 20 : 17
            colorShadowLayer.shadowOffset = CGSize(width: -6, height: 9)

            depthShadowLayer.shadowColor = NSColor.black.cgColor
            depthShadowLayer.shadowOpacity = Float(colorScheme == .dark ? 0.18 : 0.078)
            depthShadowLayer.shadowRadius = isLyricsCard ? 13 : 11
            depthShadowLayer.shadowOffset = CGSize(width: 0, height: 7)
        }
    }
}

private enum FrostedGlassTexture {
    static let image: NSImage = {
        let side = 96
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()

        for y in 0..<side {
            for x in 0..<side {
                let seed = (x &* 73 &+ y &* 151 &+ x &* y &* 17) & 255
                if seed % 9 == 0 {
                    let alpha = 0.030 + Double(seed % 5) * 0.006
                    NSColor.white.withAlphaComponent(alpha).setFill()
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                } else if seed % 37 == 0 {
                    let alpha = 0.018 + Double(seed % 3) * 0.004
                    NSColor.black.withAlphaComponent(alpha).setFill()
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }()
}

private struct FrostedGlassTextureOverlay: View {
    let opacity: Double

    var body: some View {
        Image(nsImage: FrostedGlassTexture.image)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

private struct MusicControlGlass: ViewModifier {
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat
    var tintStrength: Double = 1

    func body(content: Content) -> some View {
        content
            .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: cornerRadius, tintStrength: tintStrength))
    }
}

private struct MusicPopoverGlass: ViewModifier {
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat
    var tintStrength: Double = 0.72

    func body(content: Content) -> some View {
        content
            .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: cornerRadius, tintStrength: tintStrength))
    }
}

enum LyricTimingSource: String, Codable, Hashable, Sendable {
    case exact
    case aligned
    case estimated

    var rank: Int {
        switch self {
        case .exact: return 3
        case .aligned: return 2
        case .estimated: return 1
        }
    }

    var displayTitle: String {
        switch self {
        case .exact: return "原词逐字"
        case .aligned: return "音频对齐"
        case .estimated: return "估算同步"
        }
    }

    var systemImage: String {
        switch self {
        case .exact: return "waveform.badge.checkmark"
        case .aligned: return "waveform.path.ecg"
        case .estimated: return "textformat.abc"
        }
    }

    var helpText: String {
        switch self {
        case .exact: return "歌词源自带逐字时间戳"
        case .aligned: return "已根据本地音频分析生成逐字时间"
        case .estimated: return "按歌词文字权重估算逐字进度"
        }
    }
}

private struct KaraokeLyricLine: View, Equatable {
    let line: TimedLyricLine
    let currentTime: Double
    let palette: AlbumColorPalette
    let isActive: Bool
    let highlightMode: LyricLineHighlightMode
    let progress: Double

    // R5-2 性能：歌词字符填充实际只按 progressBucket（48 级量化）变化，逐字片段按 segment 头位置变化。
    // 默认 Equatable 会比较原始 currentTime/progress，使每 0.18s 时钟 tick 都判定为“变化”→整行重渲染。
    // 这里改为按可见量化粒度比较：同一 bucket 内的时钟更新不再触发重绘，视觉完全一致但合成负担显著下降。
    static func == (lhs: KaraokeLyricLine, rhs: KaraokeLyricLine) -> Bool {
        lhs.isActive == rhs.isActive &&
        lhs.highlightMode == rhs.highlightMode &&
        lhs.line == rhs.line &&
        lhs.palette == rhs.palette &&
        lhs.progressBucket == rhs.progressBucket &&
        lhs.segmentTimeBucket == rhs.segmentTimeBucket
    }

    private var segmentTimeBucket: Int {
        guard isActive, !line.segments.isEmpty else { return 0 }
        // 逐字片段按 ~40ms 量化，足以驱动逐字推进又不会每帧都判变。
        return Int((max(currentTime, 0) * 25).rounded())
    }

    // 所有行（含被播放行）共用完全相同的字号与字重，杜绝"激活时整行放大、播放完突然缩小"的跳变。
    // 被播放行的突出感只来自字级 scaleEffect（见 LyricProgressWrappingText / SegmentedLyricFlowText）。
    private static let baseFont = Font.system(size: 22, weight: .semibold, design: .rounded)

    var body: some View {
        if isActive {
            activeLine
                .font(Self.baseFont)
                .lineSpacing(8)
                .shadow(color: palette.primary.color.opacity(0.18), radius: 16, y: 6)
                .transition(.identity)
                .animation(AppMotion.lyricFlow, value: progressBucket)
        } else {
            Text(line.text)
                .font(Self.baseFont)
                .foregroundStyle(Color.primary.opacity(0.52))
                .lineSpacing(8)
                .transition(.identity)
        }
    }

    @ViewBuilder
    private var activeLine: some View {
        if highlightMode == .fullLineDuringSeek {
            Text(line.text)
                .foregroundStyle(palette.playedLyric.color.opacity(0.98))
                .transition(.opacity)
        } else if !line.segments.isEmpty {
            SegmentedLyricFlowText(segments: line.segments, currentTime: currentTime, palette: palette)
        } else {
            LyricProgressWrappingText(
                text: line.text,
                timing: .estimated(line: line, progress: progress),
                palette: palette
            )
        }
    }

    private var progressBucket: Int {
        Int((min(max(progress, 0), 1) * 48).rounded())
    }
}

private struct LyricGlyph: Identifiable {
    let id: Int
    let value: String
}

struct LyricHighlightTiming: Equatable {
    var progress: Double
    var activeOriginalIndex: Int
    var headOriginalPosition: Double
    var activeWeightRatio: Double
    var progressBucket: Int

    static func estimated(line: TimedLyricLine, progress: Double) -> LyricHighlightTiming {
        LyricHighlightEstimator.timing(for: line.text, progress: progress)
    }
}

struct LyricTimingUnit {
    var originalIndices: [Int]
    var weight: Double
}

enum LyricHighlightEstimator {
    static let latinWordScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "'’-"))

    static func timing(for text: String, progress rawProgress: Double) -> LyricHighlightTiming {
        let progress = min(max(rawProgress, 0), 1)
        let units = timingUnits(for: text)
        guard !units.isEmpty else {
            let lastIndex = max(Array(text).count - 1, 0)
            return LyricHighlightTiming(
                progress: progress,
                activeOriginalIndex: lastIndex,
                headOriginalPosition: Double(lastIndex),
                activeWeightRatio: 1,
                progressBucket: 0
            )
        }

        let totalWeight = units.reduce(0) { $0 + $1.weight }
        let averageWeight = max(totalWeight / Double(max(units.count, 1)), 0.001)
        let target = progress * max(totalWeight, 0.001)
        var accumulated = 0.0

        for (unitIndex, unit) in units.enumerated() {
            let next = accumulated + unit.weight
            if target <= next || unitIndex == units.indices.last {
                let local = min(max((target - accumulated) / max(unit.weight, 0.001), 0), 1)
                let indexInUnit = min(max(Int((local * Double(unit.originalIndices.count)).rounded(.down)), 0), unit.originalIndices.count - 1)
                let activeIndex = unit.originalIndices[indexInUnit]
                let head = Double(unit.originalIndices.first ?? activeIndex)
                    + (Double(unit.originalIndices.last ?? activeIndex) - Double(unit.originalIndices.first ?? activeIndex)) * local
                return LyricHighlightTiming(
                    progress: progress,
                    activeOriginalIndex: activeIndex,
                    headOriginalPosition: head,
                    activeWeightRatio: unit.weight / averageWeight,
                    progressBucket: Int((progress * 48).rounded())
                )
            }
            accumulated = next
        }

        let last = units.last?.originalIndices.last ?? max(Array(text).count - 1, 0)
        return LyricHighlightTiming(
            progress: progress,
            activeOriginalIndex: last,
            headOriginalPosition: Double(last),
            activeWeightRatio: units.last.map { $0.weight / averageWeight } ?? 1,
            progressBucket: 48
        )
    }

    static func conservativeDuration(for text: String) -> Double {
        let count = max(timingUnits(for: text).count, 1)
        return min(max(Double(count) * 0.24 + 0.65, 2.2), 6.8)
    }

    static func timingUnits(for text: String) -> [LyricTimingUnit] {
        var units: [LyricTimingUnit] = []
        var latinWordIndices: [Int] = []

        func flushLatinWord() {
            guard !latinWordIndices.isEmpty else { return }
            units.append(LyricTimingUnit(originalIndices: latinWordIndices, weight: 1.08))
            latinWordIndices.removeAll(keepingCapacity: true)
        }

        for (index, character) in Array(text).enumerated() {
            if character.isLyricTimingIgnored {
                flushLatinWord()
                continue
            }

            if character.isLatinLyricWordCharacter {
                latinWordIndices.append(index)
            } else {
                flushLatinWord()
                units.append(LyricTimingUnit(originalIndices: [index], weight: 1.0))
            }
        }
        flushLatinWord()

        if let lastIndex = units.indices.last {
            units[lastIndex].weight *= 1.16
        }
        return units
    }
}

extension Character {
    var isLyricTimingIgnored: Bool {
        unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ||
            CharacterSet.punctuationCharacters.contains(scalar) ||
            CharacterSet.symbols.contains(scalar)
        }
    }

    var isLatinLyricWordCharacter: Bool {
        guard !unicodeScalars.isEmpty else { return false }
        return unicodeScalars.allSatisfy { scalar in
            scalar.value <= 0x02AF && LyricHighlightEstimator.latinWordScalars.contains(scalar)
        }
    }
}

private struct SegmentedLyricFlowText: View {
    let segments: [TimedLyricSegment]
    let currentTime: Double
    let palette: AlbumColorPalette

    var body: some View {
        LyricFlowLayout(spacing: 0, lineSpacing: 7) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                Text(segment.text)
                    .foregroundStyle(color(for: index))
                    .fontWeight(weight(for: index))
                    .scaleEffect(segmentScale(for: index), anchor: .bottom)
                    .offset(y: verticalOffset(for: index))
                    .animation(AppMotion.lyricFlow, value: activeSegmentIndex)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel(segments.map(\.text).joined())
        .transaction { transaction in
            transaction.animation = AppMotion.lyricFlow
        }
        .animation(AppMotion.lyricFlow, value: activeSegmentIndex)
        .animation(AppMotion.lyricFlow, value: progressBucket)
    }

    private var activeSegmentIndex: Int {
        segments.indices.last { segments[$0].time <= max(currentTime - 0.015, 0) } ?? 0
    }

    private var progressBucket: Int {
        Int((riseProgress(for: activeSegmentIndex) * 12).rounded())
    }

    private func color(for index: Int) -> Color {
        if index < activeSegmentIndex {
            return palette.playedLyric.color.opacity(0.98)
        }
        if index == activeSegmentIndex {
            let blend = localProgress(for: index)
            return palette.playedLyric.color.opacity(0.50 + blend * 0.46)
        }
        return Color.primary.opacity(0.32)
    }

    private func weight(for index: Int) -> Font.Weight {
        .semibold
    }

    private func segmentScale(for index: Int) -> CGFloat {
        // 正在唱的词放大(~1.10)，其余为原字号。
        guard index == activeSegmentIndex else { return 1.0 }
        let p = localProgress(for: index)
        let bump = sin(min(max(p, 0), 1) * .pi)  // 0→1→0
        return 1.0 + 0.10 * (0.55 + 0.45 * bump)
    }

    private func verticalOffset(for index: Int) -> CGFloat {
        // 未播放词在基线(+2.5)，已播放词整体上浮(-2.5)，当前词按进度平滑过渡并保持上浮。
        if index < activeSegmentIndex { return -2.5 }
        if index > activeSegmentIndex { return 2.5 }
        let eased = easeOutCubic(riseProgress(for: index))
        return CGFloat(2.5 - eased * 5.0)
    }

    private func localProgress(for index: Int) -> Double {
        guard segments.indices.contains(index) else { return 0 }
        let segment = segments[index]
        let nextTime = segmentEndTime(for: index)
        let duration = max(nextTime - segment.time, 0.18)
        return min(max((currentTime - segment.time) / duration, 0), 1)
    }

    private func riseProgress(for index: Int) -> Double {
        let progress = localProgress(for: index)
        let duration = max(segmentEndTime(for: index) - (segments.indices.contains(index) ? segments[index].time : 0), 0.18)
        let longHold = min(max((duration - 0.44) / 1.45, 0), 1)
        return pow(progress, 1.0 + longHold * 1.22)
    }

    private func segmentEndTime(for index: Int) -> Double {
        guard segments.indices.contains(index) else { return 0 }
        let segment = segments[index]
        if let duration = segment.durationHint, duration > 0 {
            return segment.time + duration
        }
        if segments.indices.contains(index + 1) {
            return segments[index + 1].time
        }
        return segment.time + 0.42
    }

    private func easeOutCubic(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
}

private struct LyricProgressWrappingText: View {
    let text: String
    let timing: LyricHighlightTiming
    let palette: AlbumColorPalette

    var body: some View {
        let glyphs = Array(text).enumerated().map { entry in
            LyricGlyph(id: entry.offset, value: String(entry.element))
        }
        let totalCount = glyphs.count

        LyricFlowLayout(spacing: 0, lineSpacing: 7) {
            ForEach(glyphs) { glyph in
                Text(glyph.value)
                    .foregroundStyle(color(for: glyph.id))
                    .fontWeight(weight(for: glyph.id))
                    // 已播放/正在播放的字微微放大并上浮，唱过去后平滑回到原字号（突出效果只在字级，不动整行）。
                    .scaleEffect(glyphScale(for: glyph.id), anchor: .bottom)
                    .offset(y: verticalOffset(for: glyph.id))
                    .animation(AppMotion.lyricFlow, value: timing.activeOriginalIndex)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel(text)
        .transaction { transaction in
            transaction.animation = AppMotion.lyricFlow
        }
        .animation(AppMotion.lyricFlow, value: timing.progressBucket)
        .animation(AppMotion.lyricFlow, value: timing.activeOriginalIndex)
        .animation(AppMotion.lyricFlow, value: text)
        .animation(AppMotion.lyricFlow, value: totalCount)
    }

    private func color(for offset: Int) -> Color {
        let distance = Double(offset) - timing.headOriginalPosition
        if offset <= timing.activeOriginalIndex - 1 {
            return palette.playedLyric.color.opacity(0.98)
        }
        if distance <= 1.25 {
            let blend = 1 - min(max((distance + 0.35) / 1.60, 0), 1)
            return palette.playedLyric.color.opacity(0.56 + blend * 0.40)
        }
        return Color.primary.opacity(0.34)
    }

    private func weight(for offset: Int) -> Font.Weight {
        .semibold
    }

    private func glyphScale(for offset: Int) -> CGFloat {
        // 仅正在唱的字附近放大（倍率略缩小到 ~1.10），唱过/未唱均为 1.0。
        let distance = Double(offset) - timing.headOriginalPosition
        if distance > 0.6 { return 1.0 }
        if distance < -1.6 { return 1.0 }
        let proximity = 1 - min(max(abs(distance) / 1.6, 0), 1)
        let eased = proximity * proximity * (3 - 2 * proximity)
        return 1.0 + 0.10 * eased
    }

    private func verticalOffset(for offset: Int) -> CGFloat {
        // Apple Music 式：未播放字在基线（略低，+2.5），已播放字整体上浮（-2.5），
        // 播放头处平滑过渡。已播放的字保持上浮，不回落。
        let distance = Double(offset) - timing.headOriginalPosition
        let t = min(max((0.4 - distance) / 1.2, 0), 1)   // distance≤-0.8→1(已播放), ≥0.4→0(未播放)
        let eased = t * t * (3 - 2 * t)
        return CGFloat(2.5 - eased * 5.0)                 // +2.5(未播放) → -2.5(已播放)
    }
}

private struct LyricFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arrange(subviews: subviews, proposal: proposal, boundsWidth: proposal.width)
        return arrangement.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, proposal: proposal, boundsWidth: bounds.width)
        for (index, position) in arrangement.positions.enumerated() {
            guard subviews.indices.contains(index) else { continue }
            let size = arrangement.sizes[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func arrange(subviews: Subviews, proposal: ProposedViewSize, boundsWidth: CGFloat?) -> (size: CGSize, positions: [CGPoint], sizes: [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return (.zero, [], []) }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        let maxWidth = max(1, boundsWidth ?? proposal.width ?? naturalWidth)
        let layoutWidth = maxWidth * 0.992

        var rows: [[Int]] = []
        var rowWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        func commitRow() {
            guard !current.isEmpty else { return }
            rows.append(current)
            rowWidths.append(currentWidth)
            rowHeights.append(currentHeight)
            current = []
            currentWidth = 0
            currentHeight = 0
        }

        for index in sizes.indices {
            let size = sizes[index]
            let reserve: CGFloat = size.width > 0 ? min(max(size.width * 0.045, 0.55), 3.4) : 0
            let nextWidth = current.isEmpty ? size.width + reserve : currentWidth + spacing + size.width + reserve
            if nextWidth > layoutWidth, !current.isEmpty {
                commitRow()
            }
            current.append(index)
            currentWidth = current.count == 1 ? size.width + reserve : currentWidth + spacing + size.width + reserve
            currentHeight = max(currentHeight, size.height)
        }
        commitRow()

        var positions = Array(repeating: CGPoint.zero, count: subviews.count)
        var y: CGFloat = 0
        for rowIndex in rows.indices {
            var x = max((maxWidth - rowWidths[rowIndex]) / 2, 0)
            for itemIndex in rows[rowIndex] {
                positions[itemIndex] = CGPoint(x: x, y: y)
                let reserve = sizes[itemIndex].width > 0 ? min(max(sizes[itemIndex].width * 0.045, 0.55), 3.4) : 0
                x += sizes[itemIndex].width + reserve + spacing
            }
            y += rowHeights[rowIndex]
            if rowIndex < rows.count - 1 {
                y += lineSpacing
            }
        }

        return (
            CGSize(width: boundsWidth ?? proposal.width ?? min(maxWidth, naturalWidth), height: y),
            positions,
            sizes
        )
    }
}

struct TimedLyricSegment: Identifiable, Hashable {
    let id = UUID()
    var time: Double
    var text: String
    var source: LyricTimingSource = .exact
    var durationHint: Double? = nil
}

struct LyricPlaybackPosition: Equatable {
    var lineIndex: Int
    var startTime: Double
    var endTime: Double
    var referenceTime: Double
}

struct TimedLyricLine: Identifiable, Hashable {
    let id = UUID()
    var time: Double
    var text: String
    var segments: [TimedLyricSegment] = []
    var source: LyricTimingSource = .estimated

    static func parse(_ text: String) -> [TimedLyricLine] {
        LyricSourceParser.parse(text)
    }

    static func activeIndex(in lines: [TimedLyricLine], at time: Double) -> Int? {
        playbackPosition(in: lines, at: time)?.lineIndex
    }

    static func playbackPosition(in lines: [TimedLyricLine], at time: Double) -> LyricPlaybackPosition? {
        guard !lines.isEmpty else { return nil }
        let targetTime = max(time, 0)
        var lowerBound = 0
        var upperBound = lines.count - 1
        var active = 0
        while lowerBound <= upperBound {
            let mid = (lowerBound + upperBound) / 2
            if lines[mid].time <= targetTime {
                active = mid
                lowerBound = mid + 1
            } else {
                upperBound = mid - 1
            }
        }
        let start = lines[active].time
        let end = endTime(in: lines, index: active)
        return LyricPlaybackPosition(
            lineIndex: active,
            startTime: start,
            endTime: end,
            referenceTime: min(max(targetTime, start), end)
        )
    }

    static func firstTimestampIndex(after time: Double, in lines: [TimedLyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let targetTime = max(time, 0)
        var lowerBound = 0
        var upperBound = lines.count - 1
        var candidate: Int?
        while lowerBound <= upperBound {
            let mid = (lowerBound + upperBound) / 2
            if lines[mid].time > targetTime {
                candidate = mid
                upperBound = mid - 1
            } else {
                lowerBound = mid + 1
            }
        }
        return candidate
    }

    static func progress(in lines: [TimedLyricLine], index: Int, currentTime: Double) -> Double {
        guard let active = activeIndex(in: lines, at: currentTime),
              active == index,
              lines.indices.contains(index) else { return 0 }
        let start = lines[index].time
        let end = endTime(in: lines, index: index)
        let duration = max(end - start, 0.8)
        return min(max((currentTime - start) / duration, 0), 1)
    }

    static func endTime(in lines: [TimedLyricLine], index: Int) -> Double {
        let start = lines[index].time
        if lines.indices.contains(index + 1) {
            return max(lines[index + 1].time, start + 0.8)
        }

        let previousDurations = lines.indices
            .filter { $0 < index && lines.indices.contains($0 + 1) }
            .map { max(lines[$0 + 1].time - lines[$0].time, 0.8) }
            .suffix(4)
        let average = previousDurations.isEmpty
            ? nil
            : previousDurations.reduce(0, +) / Double(previousDurations.count)
        let conservative = LyricHighlightEstimator.conservativeDuration(for: lines[index].text)
        let duration = max(min(max(average ?? conservative, 1.8), 7.4), conservative)
        return start + duration
    }

    static func visualEndTime(in lines: [TimedLyricLine], index: Int) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        if let lastSegment = line.segments.last {
            let segmentEnd = lastSegment.time + max(lastSegment.durationHint ?? 0.24, 0.12)
            return min(max(segmentEnd, line.time + 0.35), endTime(in: lines, index: index))
        }
        return endTime(in: lines, index: index)
    }

    var firstRenderableTime: Double? {
        guard let first = segments.first else { return nil }
        return first.time
    }

    static func bestTimingSource(in lines: [TimedLyricLine]) -> LyricTimingSource {
        lines
            .map(\.effectiveSource)
            .max { $0.rank < $1.rank } ?? .estimated
    }

    var effectiveSource: LyricTimingSource {
        if !segments.isEmpty {
            return segments
                .map(\.source)
                .max { $0.rank < $1.rank } ?? source
        }
        return source
    }

    private static func parseLine(_ line: String) -> [TimedLyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: range)
        guard !matches.isEmpty else { return [] }

        let lyricBody = regex
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = parseSegments(in: lyricBody)
        let lyricText = segments.isEmpty ? lyricBody : segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        return matches.compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: line),
                let secondRange = Range(match.range(at: 2), in: line),
                let minutes = Double(line[minuteRange]),
                let seconds = Double(line[secondRange])
            else { return nil }
            var fraction = 0.0
            if let fractionRange = Range(match.range(at: 3), in: line) {
                let raw = String(line[fractionRange])
                fraction = (Double(raw) ?? 0) / pow(10, Double(raw.count))
            }
            return TimedLyricLine(time: minutes * 60 + seconds + fraction, text: lyricText, segments: segments)
        }
    }

    private static func parseSegments(in text: String) -> [TimedLyricSegment] {
        let pattern = #"<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>([^<]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: text),
                let secondRange = Range(match.range(at: 2), in: text),
                let wordRange = Range(match.range(at: 4), in: text),
                let minutes = Double(text[minuteRange]),
                let seconds = Double(text[secondRange])
            else { return nil }
            var fraction = 0.0
            if let fractionRange = Range(match.range(at: 3), in: text) {
                let raw = String(text[fractionRange])
                fraction = (Double(raw) ?? 0) / pow(10, Double(raw.count))
            }
            let segmentText = String(text[wordRange])
            guard !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimedLyricSegment(time: minutes * 60 + seconds + fraction, text: segmentText)
        }
        .sorted { $0.time < $1.time }
    }
}

struct AlbumColorPalette: Equatable {
    var primary: AlbumPaletteColor
    var secondary: AlbumPaletteColor
    var accent: AlbumPaletteColor
    // 封面"彩色度"(0~1)：彩色像素占比。白/灰度封面接近 0，鲜艳封面接近 1。
    // 用于：白色封面调暗发光、缩短传播距离，避免白光过曝（见 AlbumBlurredCoverGlowLayer）。
    var vibrancy: Double = 1

    var playedLyric: AlbumPaletteColor {
        primary.deepenedForLyric()
    }

    // 发光专用色：深色专辑取其稍浅的版本（保色相、提亮），避免深色专辑发出"暗光/脏光"。
    var glowPrimary: AlbumPaletteColor { primary.lightenedForGlow() }
    var glowSecondary: AlbumPaletteColor { secondary.lightenedForGlow() }
    var glowAccent: AlbumPaletteColor { accent.lightenedForGlow() }
    var progressDark: AlbumPaletteColor {
        primary.shiftedHue(
            by: -0.018,
            saturationMultiplier: 1.10,
            brightnessMultiplier: 0.62,
            minSaturation: 0.30,
            maxSaturation: 0.86,
            minBrightness: 0.24,
            maxBrightness: 0.56
        )
    }
    var progressLight: AlbumPaletteColor {
        primary.shiftedHue(
            by: 0.022,
            saturationMultiplier: 0.86,
            brightnessMultiplier: 1.24,
            minSaturation: 0.18,
            maxSaturation: 0.66,
            minBrightness: 0.56,
            maxBrightness: 0.88
        )
    }

    func backdropBaseColor(for colorScheme: ColorScheme) -> Color {
        let components = backdropBaseComponents(for: colorScheme)
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    func backdropBaseNSColor(for colorScheme: ColorScheme) -> NSColor {
        let components = backdropBaseComponents(for: colorScheme)
        return NSColor(
            calibratedRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1
        )
    }

    private func backdropBaseComponents(for colorScheme: ColorScheme) -> (red: Double, green: Double, blue: Double) {
        let primaryWeight = colorScheme == .dark ? 0.70 : 0.58
        let secondaryWeight = colorScheme == .dark ? 0.22 : 0.20
        let accentWeight = colorScheme == .dark ? 0.14 : 0.12
        // 降低浅色 neutralLift（0.11→0.05）：少往每个通道注入灰色，避免把专辑色调冲淡发白。
        let neutralLift = colorScheme == .dark ? 0.018 : 0.05
        let red = primary.red * primaryWeight + secondary.red * secondaryWeight + accent.red * accentWeight + neutralLift
        let green = primary.green * primaryWeight + secondary.green * secondaryWeight + accent.green * accentWeight + neutralLift
        let blue = primary.blue * primaryWeight + secondary.blue * secondaryWeight + accent.blue * accentWeight + neutralLift
        return cleanedBackdropComponents(red: red, green: green, blue: blue, colorScheme: colorScheme)
    }

    func albumGlassBaseColor(for colorScheme: ColorScheme) -> Color {
        let primaryWeight = colorScheme == .dark ? 0.68 : 0.54
        let secondaryWeight = colorScheme == .dark ? 0.24 : 0.22
        let accentWeight = colorScheme == .dark ? 0.18 : 0.16
        let neutralLift = colorScheme == .dark ? 0.012 : 0.045
        let components = cleanedBackdropComponents(
            red: primary.red * primaryWeight + secondary.red * secondaryWeight + accent.red * accentWeight + neutralLift,
            green: primary.green * primaryWeight + secondary.green * secondaryWeight + accent.green * accentWeight + neutralLift,
            blue: primary.blue * primaryWeight + secondary.blue * secondaryWeight + accent.blue * accentWeight + neutralLift,
            colorScheme: colorScheme
        )
        let red = components.red
        let green = components.green
        let blue = components.blue
        return Color(red: red, green: green, blue: blue)
    }

    private func cleanedBackdropComponents(red: Double, green: Double, blue: Double, colorScheme: ColorScheme) -> (red: Double, green: Double, blue: Double) {
        let color = NSColor(
            calibratedRed: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1),
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let cleanedSaturation: CGFloat
        let cleanedBrightness: CGFloat
        // 降低饱和度上限：底板颜色不应太鲜艳、太"脏"，保持色相不变，只压低饱和度到更柔和的区间。
        // 浅色：饱和度上限 0.34 → 0.22（仅保留淡淡的色调，背景更素雅）
        // 深色：饱和度上限 0.48 → 0.36（深色本身饱和感更强，稍压即可）
        // 不调整 hue（色相严格保留），不向其他色系偏移。
        // 过曝核心修复：给浅色底板设"饱和度下限"，即便混色偏灰也强制保留专辑色调（绝不变灰白）。
        // 下限 0.14（真灰度封面 saturation<0.04 时才放行纯灰），上限 0.26 兼顾干净与耐看；
        // 亮度上限 0.86→0.83，避免顶部过亮发白。色相严格不变。
        if colorScheme == .dark {
            cleanedSaturation = min(max(saturation, 0.16), 0.38)
            cleanedBrightness = min(max(brightness, 0.16), 0.32)
        } else {
            cleanedSaturation = min(max(saturation, saturation < 0.04 ? saturation : 0.14), 0.26)
            cleanedBrightness = min(max(brightness, 0.68), 0.83)
        }
        let cleaned = NSColor(calibratedHue: hue, saturation: cleanedSaturation, brightness: cleanedBrightness, alpha: 1)
        guard let rgb = cleaned.usingColorSpace(.sRGB) else {
            return (min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1))
        }
        return (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
    }

    static let fallback = AlbumColorPalette(
        primary: AlbumPaletteColor(red: 0.12, green: 0.58, blue: 0.98),
        secondary: AlbumPaletteColor(red: 0.10, green: 0.78, blue: 0.86),
        accent: AlbumPaletteColor(red: 0.46, green: 0.36, blue: 0.98),
        vibrancy: 0.7
    )
}

struct AlbumPaletteColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    func alpha(_ alpha: Double) -> NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: min(max(alpha, 0), 1)
        )
    }

    var hue: CGFloat {
        hsbComponents.hue
    }

    var saturation: CGFloat {
        hsbComponents.saturation
    }

    var brightness: CGFloat {
        hsbComponents.brightness
    }

    private var hsbComponents: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let nsColor = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness)
    }

    func deepenedForLyric() -> AlbumPaletteColor {
        let nsColor = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Self.hsb(
            hue: hue,
            saturation: min(max(saturation * 1.12, 0.38), 0.82),
            brightness: min(max(brightness * 0.62, 0.34), 0.60)
        )
    }

    // 发光用：保持色相，确保最低亮度（深色专辑提亮为"稍浅的同色"），略降过高饱和避免刺眼。
    func lightenedForGlow() -> AlbumPaletteColor {
        let nsColor = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Self.hsb(
            hue: hue,
            saturation: min(saturation, 0.80),
            brightness: max(brightness, 0.66)
        )
    }

    static func hsb(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> AlbumPaletteColor {
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return AlbumColorPalette.fallback.primary
        }
        return AlbumPaletteColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }

    static func cleanedHSB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> AlbumPaletteColor {
        // 仅在几乎完全无色（真灰度）时才返回纯灰；阈值从 0.12 降到 0.05，避免白色封面主色坍成灰。
        if saturation < 0.05 {
            let neutral = min(max(brightness, 0.22), 0.92)
            return AlbumPaletteColor(red: Double(neutral), green: Double(neutral), blue: Double(neutral))
        }

        // 更积极地补回饱和度（×1.35、下限 0.22），弥补去白阶段的损失，但严格保色相。
        let cleanedSaturation = min(max(saturation * 1.35, 0.22), 0.86)
        let cleanedBrightness = min(max(brightness * 1.06, 0.34), 0.95)
        return hsb(hue: hue, saturation: cleanedSaturation, brightness: cleanedBrightness)
    }

    func adjustedPreservingHue(
        saturationMultiplier: CGFloat,
        brightnessMultiplier: CGFloat,
        minSaturation: CGFloat,
        maxSaturation: CGFloat,
        minBrightness: CGFloat,
        maxBrightness: CGFloat
    ) -> AlbumPaletteColor {
        if saturation < 0.12 {
            let neutral = min(max(brightness * brightnessMultiplier, minBrightness), maxBrightness)
            return AlbumPaletteColor(red: Double(neutral), green: Double(neutral), blue: Double(neutral))
        }
        return Self.hsb(
            hue: hue,
            saturation: min(max(saturation * saturationMultiplier, minSaturation), maxSaturation),
            brightness: min(max(brightness * brightnessMultiplier, minBrightness), maxBrightness)
        )
    }

    func shiftedHue(
        by delta: CGFloat,
        saturationMultiplier: CGFloat,
        brightnessMultiplier: CGFloat,
        minSaturation: CGFloat,
        maxSaturation: CGFloat,
        minBrightness: CGFloat,
        maxBrightness: CGFloat
    ) -> AlbumPaletteColor {
        let shifted = hue + delta
        let wrappedHue = shifted - floor(shifted)
        return Self.hsb(
            hue: wrappedHue,
            saturation: min(max(saturation * saturationMultiplier, minSaturation), maxSaturation),
            brightness: min(max(brightness * brightnessMultiplier, minBrightness), maxBrightness)
        )
    }
}

enum AlbumPaletteCache {
    private static let store = AlbumPaletteStore()

    static func palette(for path: String?) async -> AlbumColorPalette {
        guard let path, !path.isEmpty else {
            return .fallback
        }

        if let cached = await store.palette(for: path) {
            return cached
        }

        let palette = await Task.detached(priority: .utility) {
            makePalette(path: path)
        }.value

        await store.store(palette, for: path)
        return palette
    }

    private static func makePalette(path: String) -> AlbumColorPalette {
        guard let image = ArtworkImageCache.image(path: path),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            return .fallback
        }

        let stepX = max(1, bitmap.pixelsWide / 36)
        let stepY = max(1, bitmap.pixelsHigh / 36)
        var samples: [AlbumPaletteSample] = []

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let brightness = max(color.redComponent, max(color.greenComponent, color.blueComponent))
                let darkness = min(color.redComponent, min(color.greenComponent, color.blueComponent))
                let saturation = brightness > 0 ? (brightness - darkness) / brightness : 0
                guard color.alphaComponent > 0.2, brightness > 0.08, brightness < 0.985 else { continue }

                var hue: CGFloat = 0
                var hsbSaturation: CGFloat = 0
                var hsbBrightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(&hue, saturation: &hsbSaturation, brightness: &hsbBrightness, alpha: &alpha)
                // weight 改为"面积权重(prevalence)"：代表该颜色在封面中的占比。
                // 只做轻度中间调亮度偏好（过亮/过暗略降），不放大饱和度、不强罚白色——
                // 保留真实占比信息，供后续【按占比而非鲜艳度】排序，避免极少量鲜艳像素（如指甲油）夺取主色。
                let bri = Double(brightness)
                let brightnessPreference = 1.0 - min(abs(bri - 0.5) / 0.55, 1.0) * 0.30
                let weight = max(brightnessPreference, 0.05)
                samples.append(
                    AlbumPaletteSample(
                        red: Double(color.redComponent),
                        green: Double(color.greenComponent),
                        blue: Double(color.blueComponent),
                        hue: Double(hue),
                        saturation: Double(hsbSaturation),
                        brightness: Double(hsbBrightness),
                        weight: weight
                    )
                )
            }
        }

        guard !samples.isEmpty else {
            return .fallback
        }

        // ── 彩色度判定（regime split）──
        // 按【占比】统计彩色像素比例：彩色封面走多色方案；中性/白/灰度封面走柔和中性方案，
        // 既避免白色过曝，也避免极少量鲜艳像素（指甲油等）被当成底色。
        let totalPrevalence = samples.reduce(0.0) { $0 + $1.weight }
        let colorfulPrevalence = samples
            .filter { $0.saturation >= 0.22 && $0.brightness >= 0.12 && $0.brightness <= 0.97 }
            .reduce(0.0) { $0 + $1.weight }
        let colorfulFraction = totalPrevalence > 0 ? colorfulPrevalence / totalPrevalence : 0
        let vibrancy = min(max(colorfulFraction / 0.42, 0), 1)

        let hueRanks = rankedHues(in: samples)

        // 中性封面（彩色像素占比 < 16%）：用整体平均做柔和中性底色，不强行上色。
        if colorfulFraction < 0.16 {
            return neutralPalette(samples: samples, hueRanks: hueRanks, vibrancy: vibrancy)
        }

        // ── 彩色封面：按占比排序选主色，少数派鲜艳色只能当点缀 ──
        let dominantHue = hueRanks.first?.hue ?? dominantHue(in: samples)
        // primary 取占比最大色相簇内的真实像素平均（颜色一定存在于封面中），逐级放宽兜底。
        let primaryBase = weightedAverage(
            samples,
            dominantHue: dominantHue,
            maxHueDistance: 0.11,
            includeNeutrals: false,
            minSaturation: 0.12
        )
            ?? weightedAverage(samples, dominantHue: dominantHue, maxHueDistance: 0.18, includeNeutrals: false, minSaturation: 0.08)
            ?? weightedAverage(samples, dominantHue: nil, maxHueDistance: 1, includeNeutrals: false, minSaturation: 0.06)
            ?? AlbumColorPalette.fallback.primary
        let primaryHue = dominantHue ?? Double(primaryBase.hue)
        // secondary/accent 必须是封面中真实存在、且占比达阈值的其他色相（minWeightFraction 提高到 0.18/0.14），
        // 否则退回主色的近似类比色——绝不凭空取一个封面里不存在的颜色。
        let secondaryHue = distinctHue(in: hueRanks, avoiding: [primaryHue], minDistance: 0.06, minWeightFraction: 0.18)
        let accentHue = distinctHue(in: hueRanks, avoiding: [primaryHue, secondaryHue ?? primaryHue], minDistance: 0.08, minWeightFraction: 0.14)

        let secondary = (
            secondaryHue.flatMap {
                weightedAverage(samples, dominantHue: $0, maxHueDistance: 0.12, includeNeutrals: false, minSaturation: 0.12, minBrightness: 0.14)
            } ?? primaryBase.shiftedHue(
                by: 0.05,
                saturationMultiplier: 0.92,
                brightnessMultiplier: 1.06,
                minSaturation: 0.16,
                maxSaturation: 0.62,
                minBrightness: 0.42,
                maxBrightness: 0.94
            )
        ).adjustedPreservingHue(
            saturationMultiplier: 0.94,
            brightnessMultiplier: 1.06,
            minSaturation: 0.14,
            maxSaturation: 0.66,
            minBrightness: 0.40,
            maxBrightness: 0.94
        )
        let accent = (
            accentHue.flatMap {
                weightedAverage(samples, dominantHue: $0, maxHueDistance: 0.13, includeNeutrals: false, minSaturation: 0.14, minBrightness: 0.12)
            } ?? primaryBase.shiftedHue(
                by: -0.05,
                saturationMultiplier: 1.06,
                brightnessMultiplier: 1.02,
                minSaturation: 0.20,
                maxSaturation: 0.78,
                minBrightness: 0.38,
                maxBrightness: 0.94
            )
        ).adjustedPreservingHue(
            saturationMultiplier: 1.04,
            brightnessMultiplier: 1.02,
            minSaturation: 0.18,
            maxSaturation: 0.80,
            minBrightness: 0.32,
            maxBrightness: 0.94
        )

        // 主色仅做温和的饱和度补偿（×1.08），尽量忠实于封面真实颜色，不再大幅拔高导致"封面里没有的颜色"。
        let vividPrimary = primaryBase.adjustedPreservingHue(
            saturationMultiplier: 1.08,
            brightnessMultiplier: 1.0,
            minSaturation: 0.16,
            maxSaturation: 0.80,
            minBrightness: 0.20,
            maxBrightness: 0.95
        )
        return AlbumColorPalette(
            primary: vividPrimary,
            secondary: secondary,
            accent: accent,
            vibrancy: vibrancy
        )
    }

    /// 中性/白/灰度封面的配色：用整体平均色派生一个柔和、低饱和的中性底色，
    /// 不强行上色（避免凭空造色），也不被白色冲爆（控制亮度上限）。
    /// secondary/accent 取封面里仅有的一点点彩色作为极弱点缀，没有则用主色的微类比色。
    private static func neutralPalette(
        samples: [AlbumPaletteSample],
        hueRanks: [(hue: Double, weight: Double)],
        vibrancy: Double
    ) -> AlbumColorPalette {
        // 整体平均色（含中性）：代表封面真实的"主调"，白封面→近白、暖灰封面→暖灰。
        let avg = weightedAverage(samples, dominantHue: nil, maxHueDistance: 1, includeNeutrals: true)
            ?? AlbumColorPalette.fallback.primary
        let avgHue = Double(avg.hue)
        // 极低饱和度（随彩色度略增，但封顶很低）+ 中性偏亮的亮度 → 柔和"有色纸"质感，不发灰死也不过曝。
        let baseSaturation = min(0.05 + vibrancy * 0.10, 0.15)
        let primary = AlbumPaletteColor.hsb(hue: CGFloat(avgHue), saturation: CGFloat(baseSaturation), brightness: 0.60)

        // 若封面里确有一点彩色（如指甲油），取占比最高的两个彩色相做极弱点缀；否则微类比。
        let accentHue1 = hueRanks.first(where: { $0.weight > 0 })?.hue
        let accentHue2 = accentHue1.flatMap { h1 in
            hueRanks.first(where: { hueDistance($0.hue, h1) >= 0.10 && $0.weight > 0 })?.hue
        }
        let secondary: AlbumPaletteColor = {
            if let h = accentHue1,
               let c = weightedAverage(samples, dominantHue: h, maxHueDistance: 0.12, includeNeutrals: false, minSaturation: 0.18) {
                return c.adjustedPreservingHue(saturationMultiplier: 0.62, brightnessMultiplier: 1.0, minSaturation: 0.12, maxSaturation: 0.40, minBrightness: 0.46, maxBrightness: 0.86)
            }
            return primary.shiftedHue(by: 0.04, saturationMultiplier: 1.0, brightnessMultiplier: 1.04, minSaturation: 0.05, maxSaturation: 0.18, minBrightness: 0.52, maxBrightness: 0.84)
        }()
        let accent: AlbumPaletteColor = {
            if let h = accentHue2 ?? accentHue1,
               let c = weightedAverage(samples, dominantHue: h, maxHueDistance: 0.13, includeNeutrals: false, minSaturation: 0.18) {
                return c.adjustedPreservingHue(saturationMultiplier: 0.66, brightnessMultiplier: 1.0, minSaturation: 0.14, maxSaturation: 0.44, minBrightness: 0.44, maxBrightness: 0.86)
            }
            return primary.shiftedHue(by: -0.04, saturationMultiplier: 1.0, brightnessMultiplier: 0.98, minSaturation: 0.05, maxSaturation: 0.18, minBrightness: 0.50, maxBrightness: 0.82)
        }()

        return AlbumColorPalette(primary: primary, secondary: secondary, accent: accent, vibrancy: vibrancy)
    }

    private static func rankedHues(in samples: [AlbumPaletteSample]) -> [(hue: Double, weight: Double)] {
        let bucketCount = 48
        var buckets = Array(repeating: 0.0, count: bucketCount)
        // 关键修复：按【占比(prevalence)】排序色相，而非鲜艳度。
        // 仅用很轻的饱和度因子（0.7~1.0）在占比相近时偏向更鲜明者；
        // 这样占据大面积的颜色稳居前列，极少量的高饱和像素（指甲油等）不会排到主色。
        for sample in samples where sample.saturation >= 0.18 && sample.brightness >= 0.12 && sample.brightness <= 0.97 {
            let bucket = min(bucketCount - 1, max(0, Int(sample.hue * Double(bucketCount))))
            let saturationNudge = 0.70 + min(max(sample.saturation, 0), 1) * 0.30
            buckets[bucket] += sample.weight * saturationNudge
        }
        return buckets.enumerated()
            .map { index, weight in
                (hue: (Double(index) + 0.5) / Double(bucketCount), weight: weight)
            }
            .filter { $0.weight > 0 }
            .sorted { $0.weight > $1.weight }
    }

    private static func distinctHue(
        in rankedHues: [(hue: Double, weight: Double)],
        avoiding usedHues: [Double],
        minDistance: Double,
        minWeightFraction: Double = 0
    ) -> Double? {
        guard let topWeight = rankedHues.first?.weight, topWeight > 0 else { return nil }
        return rankedHues.first { candidate in
            candidate.weight >= topWeight * minWeightFraction &&
            usedHues.allSatisfy { hueDistance(candidate.hue, $0) >= minDistance }
        }?.hue
    }

    private static func dominantHue(in samples: [AlbumPaletteSample]) -> Double? {
        let bucketCount = 36
        var buckets = Array(repeating: 0.0, count: bucketCount)
        for sample in samples where sample.saturation >= 0.16 && sample.brightness >= 0.16 && sample.brightness <= 0.96 {
            let bucket = min(bucketCount - 1, max(0, Int(sample.hue * Double(bucketCount))))
            buckets[bucket] += sample.weight * max(sample.saturation, 0.12)
        }
        guard let maxValue = buckets.max(), maxValue > 0,
              let index = buckets.firstIndex(of: maxValue) else { return nil }
        return (Double(index) + 0.5) / Double(bucketCount)
    }

    private static func weightedAverage(
        _ samples: [AlbumPaletteSample],
        dominantHue: Double?,
        maxHueDistance: Double,
        includeNeutrals: Bool,
        minSaturation: Double = 0,
        minBrightness: Double = 0,
        maxBrightness: Double = 1
    ) -> AlbumPaletteColor? {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var total = 0.0

        for sample in samples {
            guard sample.brightness >= minBrightness, sample.brightness <= maxBrightness else { continue }
            let neutral = sample.saturation < 0.12
            if neutral {
                guard includeNeutrals else { continue }
            } else {
                guard sample.saturation >= minSaturation else { continue }
                if let dominantHue {
                    guard hueDistance(sample.hue, dominantHue) <= maxHueDistance else { continue }
                }
            }
            // 中性色权重再降（0.22→0.10）；亮度不再奖励高亮，改为偏好中间调（峰值 0.55，过亮/过暗都降）。
            let neutralScale = neutral ? 0.10 : 1.0
            let brightnessScale = 1.0 - min(abs(sample.brightness - 0.55) / 0.55, 1.0) * 0.45
            let weight = sample.weight * neutralScale * brightnessScale
            red += sample.red * weight
            green += sample.green * weight
            blue += sample.blue * weight
            total += weight
        }

        guard total > 0 else { return nil }
        let average = NSColor(calibratedRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return AlbumPaletteColor.cleanedHSB(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func hueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }

    private static func wrappedHue(_ hue: Double) -> Double {
        let value = hue.truncatingRemainder(dividingBy: 1)
        return value >= 0 ? value : value + 1
    }
}

private struct AlbumPaletteSample {
    let red: Double
    let green: Double
    let blue: Double
    let hue: Double
    let saturation: Double
    let brightness: Double
    let weight: Double
}

private actor AlbumPaletteStore {
    private var values: [String: AlbumColorPalette] = [:]
    private var accessTick: [String: Int] = [:]
    private var tickCounter = 0
    private let maxValues = 64

    func palette(for path: String) -> AlbumColorPalette? {
        guard let value = values[path] else { return nil }
        markRecentlyUsed(path)
        return value
    }

    func store(_ palette: AlbumColorPalette, for path: String) {
        values[path] = palette
        markRecentlyUsed(path)
        while values.count > maxValues,
              let oldestPath = accessTick.min(by: { $0.value < $1.value })?.key {
            values.removeValue(forKey: oldestPath)
            accessTick.removeValue(forKey: oldestPath)
        }
    }

    private func markRecentlyUsed(_ path: String) {
        tickCounter &+= 1
        accessTick[path] = tickCounter
    }
}
