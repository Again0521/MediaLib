import AppKit
import AVFoundation
import Combine
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
    @State private var albumPalette = AlbumColorPalette.fallback
    @State private var isFetchingLyrics = false
    @State private var userIsBrowsingLyrics = false
    @State private var showVolumeControl = false
    @State private var lyricsLoadTask: Task<Void, Never>?
    @State private var paletteLoadTask: Task<Void, Never>?
    @State private var backdropAnimationTask: Task<Void, Never>?
    @State private var entranceAnimationTask: Task<Void, Never>?
    @State private var backdropAnimationReady = false
    @State private var glassLayerReady = false  // MusicFullScreenGlassLayer 延迟出现，避免展开动画期间全屏 blur
    @State private var entrancePhase = 0
    @State private var resumeAutoScrollTask: Task<Void, Never>?

    private var currentItem: MediaItem {
        if let active = appState.activePlayerItem, active.type == .music {
            return active
        }
        return item
    }

    private var activeLyricIndex: Int? {
        TimedLyricLine.activeIndex(in: timedLyrics, at: controller.currentTime)
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
        expandedPlayer
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startEntranceAnimation()
            scheduleBackdropAnimation()
            loadLyricsForCurrentItem()
            loadAlbumPalette()
        }
        .onChange(of: appState.activePlayerItem?.id) { _ in
            scheduleBackdropAnimation()
            loadLyricsForCurrentItem()
            loadAlbumPalette()
        }
        .onChange(of: currentItem.posterPath) { _ in
            loadAlbumPalette()
        }
        .onDisappear {
            lyricsLoadTask?.cancel()
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

            ZStack(alignment: .topLeading) {
                AlbumGlassBackdrop(
                    controller: controller,
                    posterPath: currentItem.posterPath,
                    title: currentItem.title,
                    palette: albumPalette,
                    animationReady: backdropAnimationReady,
                    albumLightCenter: layout.albumLightCenter
                )
                .transaction { transaction in
                    transaction.animation = nil
                }

                if glassLayerReady {
                    MusicFullScreenGlassLayer(palette: albumPalette)
                        .zIndex(0.4)
                        .transition(.opacity)
                }

                AlbumNearFieldIlluminationLayer(
                    controller: controller,
                    palette: albumPalette,
                    center: layout.albumLightCenter,
                    animationReady: backdropAnimationReady
                )
                .zIndex(1.1)

                if layout.stackedLayout {
                    ScrollView {
                        VStack(spacing: 28) {
                            musicIdentityPanel(posterSize: min(layout.posterSize, 230))
                                .frame(maxWidth: 360)
                                .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                                .offset(y: reduceMotion || entrancePhase >= 1 ? 0 : 18)
                                .scaleEffect(reduceMotion || entrancePhase >= 1 ? 1 : 0.982)

                            lyricsPanel
                                .frame(height: layout.stackedLyricsHeight)
                                .opacity(reduceMotion || entrancePhase >= 2 ? 1 : 0)
                                .offset(y: reduceMotion || entrancePhase >= 2 ? 0 : 22)
                                .scaleEffect(reduceMotion || entrancePhase >= 2 ? 1 : 0.986)
                        }
                        .padding(.horizontal, layout.sideInset)
                        .padding(.top, 82)
                        .padding(.bottom, layout.verticalInset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(2)
                } else {
                    musicIdentityPanel(posterSize: layout.posterSize)
                        .frame(width: layout.leftRect.width, height: layout.leftRect.height, alignment: .center)
                        .offset(x: layout.leftRect.minX, y: layout.leftRect.minY)
                        .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                        .scaleEffect(reduceMotion || entrancePhase >= 1 ? 1 : 0.982, anchor: .center)
                        .zIndex(2)

                    lyricsPanel
                        .frame(width: layout.lyricsRect.width, height: layout.lyricsRect.height)
                        .offset(x: layout.lyricsRect.minX, y: layout.lyricsRect.minY)
                        .opacity(reduceMotion || entrancePhase >= 2 ? 1 : 0)
                        .scaleEffect(reduceMotion || entrancePhase >= 2 ? 1 : 0.986, anchor: .center)
                        .zIndex(2)
                }

                floatingMinimizeButton
                    .frame(width: layout.minimizeButtonRect.width, height: layout.minimizeButtonRect.height)
                    .position(x: layout.minimizeButtonRect.midX, y: layout.minimizeButtonRect.midY)
                    .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                    .transition(.opacity)
                    .zIndex(40)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(albumPalette.backdropBaseColor(for: colorScheme))
    }

    private func musicIdentityPanel(posterSize: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ZStack {
                // 发光层：模糊放大的专辑封面本体。各方向溢出的光色与该侧封面边缘颜色一致
                // （如左上角为红色，则左上溢出光也呈红色），而不是全方位单一调色板色。
                PosterImage(path: currentItem.posterPath, title: currentItem.title, mediaType: currentItem.type)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: posterSize, height: posterSize)
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .scaleEffect(1.24)
                    .blur(radius: 48)
                    .opacity(colorScheme == .dark ? 0.74 : 0.64)
                    .allowsHitTesting(false)
                // 内层白色微光环 —— 唱片镜面感
                RoundedRectangle(cornerRadius: 31, style: .continuous)
                    .stroke(.white.opacity(colorScheme == .dark ? 0.18 : 0.26), lineWidth: 5)
                    .blur(radius: 8)
                    .scaleEffect(1.015)

                PosterImage(path: currentItem.posterPath, title: currentItem.title, mediaType: currentItem.type)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: posterSize, height: posterSize)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(.white.opacity(0.54), lineWidth: 1.2)
                    }
                    .pointerLiquidLight(cornerRadius: 30, tint: albumPalette.primary.color, intensity: 0.92)
            }
            .frame(width: posterSize, height: posterSize)
            // 深色专辑用提亮后的同色发光，避免深色专辑发出暗光。
            .shadow(color: albumPalette.glowPrimary.color.opacity(0.34), radius: 56, y: 26)
            .shadow(color: albumPalette.glowAccent.color.opacity(0.18), radius: 38, y: 16)
            .shadow(color: .black.opacity(0.24), radius: 22, y: 12)

            VStack(spacing: 7) {
                Text(currentItem.title)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                Text(currentItem.artistAlbumLine ?? "未知艺人")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.58))
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

    @ViewBuilder
    private var lyricsView: some View {
        if timedLyrics.isEmpty {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(Self.cleanedLyrics(lyrics))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineSpacing(9)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: max(geometry.size.height, 420), alignment: .center)
                        .padding(28)
                }
                .lyricsScrollActivity {
                    pauseLyricAutoScroll()
                }
            }
        } else {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    let currentActiveIndex = activeLyricIndex
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .center, spacing: 12) {
                            ForEach(timedLyrics.indices, id: \.self) { index in
                                let line = timedLyrics[index]
                                let distance = currentActiveIndex.map { abs(index - $0) } ?? 0
                                lyricLine(
                                    line,
                                    isActive: index == currentActiveIndex,
                                    progress: lyricProgress(for: index),
                                    distanceFromActive: distance,
                                    isBrowsing: userIsBrowsingLyrics
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
                            .onChanged { _ in pauseLyricAutoScroll() }
                    )
                    .lyricsScrollActivity {
                        pauseLyricAutoScroll()
                    }
                    .onAppear {
                        scrollToActiveLyric(proxy)
                    }
                    .onChange(of: activeLyricIndex) { _ in
                        scrollToActiveLyric(proxy)
                    }
                    .onChange(of: timedLyrics.count) { _ in
                        scrollToActiveLyric(proxy)
                    }
                    .onChange(of: userIsBrowsingLyrics) { browsing in
                        if !browsing {
                            scrollToActiveLyric(proxy)
                        }
                    }
                }
            }
        }
    }

    private var lyricsFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.30), location: 0.08),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .black.opacity(0.30), location: 0.92),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: TimedLyricLine,
        isActive: Bool,
        progress: Double,
        distanceFromActive: Int,
        isBrowsing: Bool
    ) -> some View {
        KaraokeLyricLine(
            line: line,
            currentTime: isActive ? controller.currentTime : line.time,
            palette: albumPalette,
            isActive: isActive,
            progress: progress
        )
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .scaleEffect(isActive ? 1.032 : 0.995, anchor: .center)
            .opacity(lyricOpacity(distanceFromActive: distanceFromActive, isActive: isActive, isBrowsing: isBrowsing))
            .blur(radius: lyricBlur(distanceFromActive: distanceFromActive, isActive: isActive, isBrowsing: isBrowsing))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.seek(to: line.time)
                userIsBrowsingLyrics = false
            }
            .animation(AppMotion.lyric, value: isActive)
            .animation(AppMotion.lyric, value: line.text)
            .animation(AppMotion.lyric, value: isBrowsing)
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

    private func lyricBlur(distanceFromActive distance: Int, isActive: Bool, isBrowsing: Bool) -> CGFloat {
        if isActive { return 0 }
        if isBrowsing {
            return min(CGFloat(max(distance - 1, 0)) * 0.34, 1.15)
        }
        return min(CGFloat(max(distance - 1, 0)) * 1.15, 5.5)
    }

    private func lyricProgress(for index: Int) -> Double {
        guard activeLyricIndex == index, timedLyrics.indices.contains(index) else { return 0 }
        let start = timedLyrics[index].time
        let end = timedLyrics.indices.contains(index + 1) ? timedLyrics[index + 1].time : start + 3.2
        let duration = max(end - start, 0.8)
        return min(max((controller.currentTime - start) / duration, 0), 1)
    }

    private var musicControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                MusicFavoriteButton(item: currentItem, palette: albumPalette, size: 34)
                    .fixedSize()

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    Text(controller.formattedCurrentTime)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)

                    MusicMiniSeekSlider(
                        currentTime: controller.currentTime,
                        duration: controller.duration,
                        isEnabled: controller.canControl && controller.duration > 0,
                        palette: albumPalette,
                        trackHeight: 7,
                        thumbSize: 16,
                        usesPaletteTint: true,
                        onSeek: { controller.seek(to: $0) }
                    )
                    .disabled(!controller.canControl || controller.duration <= 0)
                    .frame(minWidth: 132, idealWidth: 178, maxWidth: 238)

                    Text(controller.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                }
                .layoutPriority(3)

                Spacer(minLength: 10)

                MusicQueueButton(item: currentItem, palette: albumPalette, size: 34)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                AirPlayRoutePickerControl(
                    session: controller.routePickerSession,
                    player: controller.routePickerPlayer,
                    tintColor: NSColor(calibratedRed: 0.00, green: 0.30, blue: 0.68, alpha: 0.96),
                    activeTintColor: NSColor(calibratedRed: 0.00, green: 0.22, blue: 0.54, alpha: 1.0),
                    lightTint: Color(nsColor: NSColor(calibratedRed: 0.00, green: 0.34, blue: 0.76, alpha: 1.0)),
                    size: 34,
                    cornerRadius: 17,
                    onRoutesWillBegin: {
                        controller.prepareForMusicAirPlayRouteSelection()
                    },
                    onRoutesDidEnd: {
                        controller.refreshMusicAirPlayRoute(afterRoutePicker: true)
                    }
                )

                Spacer(minLength: 12)

                musicVolumeButton

                Spacer(minLength: 12)

                Button {
                    playPreviousTrack()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(!controller.canControl)

                Spacer(minLength: 12)

                Button {
                    if controller.canControl {
                        controller.togglePlay()
                    } else {
                        controller.configureMusic(item: currentItem, settings: appState.settings)
                    }
                } label: {
                    MusicPrimaryPlayButtonLabel(isPlaying: controller.isPlaying, palette: albumPalette)
                }
                .buttonStyle(.plain)
                .pointerLiquidEdge(cornerRadius: 17, tint: albumPalette.accent.color, intensity: 1.08)
                .disabled(controller.isPreparing)

                Spacer(minLength: 12)

                Button {
                    playNextTrack()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(!controller.canControl)

                Spacer(minLength: 12)

                MusicShuffleButton(size: 34, palette: albumPalette)
                    .fixedSize()

                Spacer(minLength: 12)

                MusicRepeatModeButton(size: 34, palette: albumPalette)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .font(.title3)
            .buttonStyle(MusicIconButtonStyle(palette: albumPalette, size: 34, cornerRadius: 17))

            if let error = controller.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .lineLimit(2)
                    Spacer()
                    Button("重试") {
                        controller.configureMusic(item: currentItem, settings: appState.settings)
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 28))
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else if controller.isPreparing {
                Label("正在准备播放器", systemImage: "progress.indicator")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MusicControlGlass(palette: albumPalette, cornerRadius: 24, tintStrength: 1.0))
    }

    private var musicVolumeButton: some View {
        Button {
            showVolumeControl.toggle()
        } label: {
            Image(systemName: volumeSystemImage)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(MusicIconButtonStyle(palette: albumPalette, size: 34, cornerRadius: 17))
        .disabled(!controller.canControl)
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
                Text("\(Int((controller.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: Binding(get: {
                Double(controller.volume)
            }, set: { newValue in
                controller.setVolume(Float(newValue))
            }), in: 0...1)
            .frame(width: 220)
        }
        .padding(16)
        .frame(width: 260)
        .modifier(MusicPopoverGlass(palette: albumPalette, cornerRadius: 18))
    }

    private var volumeSystemImage: String {
        if controller.volume == 0 {
            return "speaker.slash"
        }
        if controller.volume < 0.45 {
            return "speaker.wave.1"
        }
        return "speaker.wave.2"
    }

    private func close() {
        resumeAutoScrollTask?.cancel()
        Task { @MainActor in
            if appState.activePlayerItem?.id == currentItem.id {
                appState.activePlayerItem = nil
            }
        }
    }

    private func playPreviousTrack() {
        if appState.musicRepeatMode == .repeatOne {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: currentItem, direction: -1)
        }
    }

    private func playNextTrack() {
        if appState.musicRepeatMode == .repeatOne {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: currentItem, direction: 1)
        }
    }

    private func setLyrics(_ text: String) {
        lyrics = text
        timedLyrics = TimedLyricLine.parse(text)
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
        albumPalette = .fallback
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
            // Phase 1：展开主体动画结束后让全屏柔光层渐入，
            // 避免在 opacity 过渡期间运行昂贵的 .regularMaterial 全屏模糊
            do { try await Task.sleep(nanoseconds: 520_000_000) } catch { return }
            withAnimation(AppMotion.fast) { glassLayerReady = true }
            // Phase 2：动态 Canvas 进一步延后启动，
            // 确保在展开动画和玻璃层淡入都完成后再开始节奏脉冲渲染
            do { try await Task.sleep(nanoseconds: 210_000_000) } catch { return }
            backdropAnimationReady = true
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

    private func scrollToActiveLyric(_ proxy: ScrollViewProxy) {
        guard !userIsBrowsingLyrics, let activeLyricIndex else { return }
        withAnimation(AppMotion.lyric) {
            proxy.scrollTo(activeLyricIndex, anchor: .center)
        }
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

private struct MusicExpandedLyricsPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let controller: MpvPlayerController
    let lyrics: String
    let timedLyrics: [TimedLyricLine]
    let hasDisplayLyrics: Bool
    let isFetchingLyrics: Bool
    let palette: AlbumColorPalette
    @Binding var userIsBrowsingLyrics: Bool
    let onFetchLyrics: () -> Void
    let onPauseAutoScroll: () -> Void

    var body: some View {
        ZStack {
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
                        .background(.ultraThinMaterial, in: Circle())
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: 36))
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

private struct MusicTimedLyricsScrollView: View {
    @ObservedObject var controller: MpvPlayerController
    let timedLyrics: [TimedLyricLine]
    let palette: AlbumColorPalette
    @Binding var userIsBrowsingLyrics: Bool
    let onPauseAutoScroll: () -> Void

    private var activeLyricIndex: Int? {
        TimedLyricLine.activeIndex(in: timedLyrics, at: controller.currentTime)
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let currentActiveIndex = activeLyricIndex
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .center, spacing: 12) {
                        ForEach(timedLyrics.indices, id: \.self) { index in
                            let line = timedLyrics[index]
                            let distance = currentActiveIndex.map { abs(index - $0) } ?? 0
                            lyricLine(
                                line,
                                isActive: index == currentActiveIndex,
                                progress: lyricProgress(for: index),
                                distanceFromActive: distance,
                                isBrowsing: userIsBrowsingLyrics
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
                        .onChanged { _ in onPauseAutoScroll() }
                )
                .lyricsScrollActivity {
                    onPauseAutoScroll()
                }
                .onAppear {
                    scrollToActiveLyric(proxy)
                }
                .onChange(of: activeLyricIndex) { _ in
                    scrollToActiveLyric(proxy)
                }
                .onChange(of: timedLyrics.count) { _ in
                    scrollToActiveLyric(proxy)
                }
                .onChange(of: userIsBrowsingLyrics) { browsing in
                    if !browsing {
                        scrollToActiveLyric(proxy)
                    }
                }
            }
        }
    }

    private var lyricsFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.30), location: 0.08),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .black.opacity(0.30), location: 0.92),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: TimedLyricLine,
        isActive: Bool,
        progress: Double,
        distanceFromActive: Int,
        isBrowsing: Bool
    ) -> some View {
        KaraokeLyricLine(
            line: line,
            currentTime: isActive ? controller.currentTime : line.time,
            palette: palette,
            isActive: isActive,
            progress: progress
        )
        .lineLimit(nil)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .scaleEffect(isActive ? 1.032 : 0.995, anchor: .center)
        .opacity(lyricOpacity(distanceFromActive: distanceFromActive, isActive: isActive, isBrowsing: isBrowsing))
        .blur(radius: lyricBlur(distanceFromActive: distanceFromActive, isActive: isActive, isBrowsing: isBrowsing))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.seek(to: line.time)
            userIsBrowsingLyrics = false
        }
        .animation(AppMotion.lyric, value: isActive)
        .animation(AppMotion.lyric, value: line.text)
        .animation(AppMotion.lyric, value: isBrowsing)
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

    private func lyricBlur(distanceFromActive distance: Int, isActive: Bool, isBrowsing: Bool) -> CGFloat {
        if isActive { return 0 }
        if isBrowsing {
            return min(CGFloat(max(distance - 1, 0)) * 0.34, 1.15)
        }
        return min(CGFloat(max(distance - 1, 0)) * 1.15, 5.5)
    }

    private func lyricProgress(for index: Int) -> Double {
        guard activeLyricIndex == index, timedLyrics.indices.contains(index) else { return 0 }
        let start = timedLyrics[index].time
        let end = timedLyrics.indices.contains(index + 1) ? timedLyrics[index + 1].time : start + 3.2
        let duration = max(end - start, 0.8)
        return min(max((controller.currentTime - start) / duration, 0), 1)
    }

    private func scrollToActiveLyric(_ proxy: ScrollViewProxy) {
        guard !userIsBrowsingLyrics, let activeLyricIndex else { return }
        withAnimation(AppMotion.lyric) {
            proxy.scrollTo(activeLyricIndex, anchor: .center)
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
        VStack(spacing: 14) {
            MusicExpandedProgressRow(item: item, controller: controller, palette: palette)

            MusicExpandedTransportRow(item: item, controller: controller, palette: palette)

            MusicExpandedStatusLine(controller: controller, item: item)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(maxWidth: 468, alignment: .center)
        .modifier(MusicControlGlass(palette: palette, cornerRadius: 24, tintStrength: 1.0))
    }
}

private struct MusicExpandedProgressRow: View {
    @ObservedObject var controller: MpvPlayerController
    let item: MediaItem
    let palette: AlbumColorPalette

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.item = item
        self.controller = controller
        self.palette = palette
    }

    var body: some View {
        HStack(spacing: 14) {
            MusicFavoriteButton(item: item, palette: palette, size: 34)
                .fixedSize()

            HStack(spacing: 6) {
                Text(controller.formattedCurrentTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)

                MusicMiniSeekSlider(
                    currentTime: controller.currentTime,
                    duration: controller.duration,
                    isEnabled: controller.canControl && controller.duration > 0,
                    palette: palette,
                    trackHeight: 7,
                    thumbSize: 16,
                    usesPaletteTint: true,
                    onSeek: { controller.seek(to: $0) }
                )
                .disabled(!controller.canControl || controller.duration <= 0)
                .frame(minWidth: 150, idealWidth: 278, maxWidth: .infinity)

                Text(controller.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            .layoutPriority(3)

            MusicQueueButton(item: item, palette: palette, size: 34)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
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

        // 用 Spacer 在按钮间均匀撑开：首个按钮(AirPlay)贴左、末个按钮(循环)贴右，
        // 与上方进度行的首个(收藏)/末个(队列)按钮左右对齐；中间按钮均匀分布。
        HStack(spacing: 0) {
            AirPlayRoutePickerControl(
                session: controller.routePickerSession,
                player: controller.routePickerPlayer,
                tintColor: NSColor(calibratedRed: 0.00, green: 0.30, blue: 0.68, alpha: 0.96),
                activeTintColor: NSColor(calibratedRed: 0.00, green: 0.22, blue: 0.54, alpha: 1.0),
                lightTint: Color(nsColor: NSColor(calibratedRed: 0.00, green: 0.34, blue: 0.76, alpha: 1.0)),
                size: 34,
                cornerRadius: 17,
                onRoutesWillBegin: {
                    controller.prepareForMusicAirPlayRouteSelection()
                },
                onRoutesDidEnd: {
                    controller.refreshMusicAirPlayRoute(afterRoutePicker: true)
                }
            )

            Spacer(minLength: 8)

            MusicExpandedVolumeButton(controller: controller, palette: palette)

            Spacer(minLength: 8)

            Button {
                playPreviousTrack()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!state.canControl)

            Spacer(minLength: 8)

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

            Spacer(minLength: 8)

            Button {
                playNextTrack()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(!state.canControl)

            Spacer(minLength: 8)

            MusicShuffleButton(size: 34, palette: palette)
                .fixedSize()

            Spacer(minLength: 8)

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
    @ObservedObject var controller: MpvPlayerController
    let palette: AlbumColorPalette
    @State private var showVolumeControl = false

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
        .disabled(!controller.canControl)
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
                Text("\(Int((controller.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: Binding(get: {
                Double(controller.volume)
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
        if controller.volume == 0 {
            return "speaker.slash"
        }
        if controller.volume < 0.45 {
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

@MainActor
private final class MusicExpandedStatusStateObserver: ObservableObject {
    @Published private(set) var state: MusicExpandedStatusState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshIfNeeded()
            }
        }
    }

    private func refreshIfNeeded() {
        guard let controller else { return }
        let nextState = Self.makeState(from: controller)
        guard nextState != state else { return }
        state = nextState
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicExpandedStatusState {
        MusicExpandedStatusState(
            errorMessage: controller.errorMessage,
            isPreparing: controller.isPreparing
        )
    }
}

struct MusicPlaybackHost: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    @ObservedObject var controller: MpvPlayerController
    @State private var configuredItem: MediaItem?
    @State private var didAutoAdvance = false

    var body: some View {
        Color.clear
            .onAppear {
                configureIfNeeded(for: item)
            }
            .onChange(of: item.id) { _ in
                configureActiveItemIfNeeded()
            }
            .onChange(of: appState.settings.keepLocalAudioWithAirPlay) { keepLocal in
                controller.setAirPlayLocalMirrorEnabled(keepLocal)
            }
            .onChange(of: controller.currentTime) { time in
                let playbackItem = configuredItem ?? currentActiveMusicItem
                guard controller.duration > 0,
                      let playbackItem,
                      appState.musicRepeatMode != .repeatOne,
                      time >= controller.duration - 0.35,
                      !didAutoAdvance else { return }
                didAutoAdvance = true
                appState.playAdjacent(to: playbackItem, direction: 1)
            }
            .onDisappear {
                let previousItem = configuredItem
                let previousDuration = controller.duration
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
        controller.setAirPlayLocalMirrorEnabled(appState.settings.keepLocalAudioWithAirPlay)
        controller.onVolumeChange = { volume in
            appState.rememberPlayerVolume(volume, for: targetItem.type)
        }
        controller.onPlaybackFinished = {
            guard !didAutoAdvance else { return }
            if appState.musicRepeatMode == .repeatOne {
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
        if let previousItem {
            appState.updatePlayback(
                item: previousItem,
                position: 0,
                duration: previousDuration > 0 ? previousDuration : nil,
                reloadLibrary: false
            )
        }
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
}

struct MusicMiniPlayerBar: View {
    let item: MediaItem
    let controller: MpvPlayerController
    let leadingInset: CGFloat
    let transitionNamespace: Namespace.ID
    let onRequestExpand: () -> Void
    let onRequestClose: () -> Void
    @State private var albumPalette = AlbumColorPalette.fallback
    @State private var paletteLoadTask: Task<Void, Never>?

    var body: some View {
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
        .font(.headline)
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .background {
            MusicMiniPlayerGlassSurface(palette: albumPalette, cornerRadius: 18)
        }
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

    private func trackSummaryButton(showText: Bool) -> some View {
        Button {
            onRequestExpand()
        } label: {
            HStack(spacing: 12) {
                PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 46, height: 46)
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
        .pointerLiquidEdge(cornerRadius: 12, tint: albumPalette.primary.color, intensity: 0.82)
        .help("展开播放器")
    }

    private func loadAlbumPalette() {
        paletteLoadTask?.cancel()
        let targetItemID = item.id
        let targetPath = item.posterPath
        albumPalette = .fallback
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
            .opacity(colorScheme == .dark ? 0.78 : 0.66)
            .allowsHitTesting(false)
        }
    }
}

private struct MusicMiniPlayerGlassSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .fill(.thinMaterial)
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
                            palette.primary.color.opacity(colorScheme == .dark ? 0.075 : 0.060),
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
                            palette.accent.color.opacity(colorScheme == .dark ? 0.20 : 0.16),
                            .white.opacity(colorScheme == .dark ? 0.10 : 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: palette.primary.color.opacity(colorScheme == .dark ? 0.065 : 0.045), radius: 12, y: 5)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.13 : 0.035), radius: 10, y: 5)
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
        cancellable = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshIfNeeded()
            }
        }
    }

    private func refreshIfNeeded() {
        guard let controller else { return }
        let nextState = Self.makeState(from: controller)
        guard nextState != state else { return }
        state = nextState
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicMiniTransportState {
        MusicMiniTransportState(
            isPlaying: controller.isPlaying,
            canControl: controller.canControl,
            isPreparing: controller.isPreparing
        )
    }
}

private struct MusicMiniProgressControl: View {
    @ObservedObject var controller: MpvPlayerController
    let palette: AlbumColorPalette

    var body: some View {
        HStack(spacing: 7) {
            MusicRepeatModeButton(size: 30, palette: palette)

            MusicShuffleButton(size: 30, palette: palette)

            Text(controller.formattedCurrentTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            MusicMiniSeekSlider(
                currentTime: controller.currentTime,
                duration: controller.duration,
                isEnabled: controller.canControl && controller.duration > 0,
                palette: palette,
                usesPaletteTint: false,
                onSeek: { controller.seek(to: $0) }
            )
            .layoutPriority(2)

            Text(controller.formattedDuration)
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
                        draggingProgress = clamped(Double(value.location.x / width))
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
    @ObservedObject var controller: MpvPlayerController
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
    @ObservedObject var controller: MpvPlayerController
    let palette: AlbumColorPalette
    @State private var showVolumeControl = false

    var body: some View {
        Button {
            showVolumeControl.toggle()
        } label: {
            Image(systemName: volumeSystemImage)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: 30, cornerRadius: 15, glowStrength: 0.62))
        .disabled(!controller.canControl)
        .popover(isPresented: $showVolumeControl, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: volumeSystemImage)
                        .foregroundStyle(.secondary)
                    Text("音量")
                        .font(.headline)
                    Spacer()
                    Text("\(Int((controller.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            Slider(value: Binding(get: {
                Double(controller.volume)
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
        if controller.volume == 0 { return "speaker.slash" }
        if controller.volume < 0.45 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }
}

private struct MusicQueuePopover: View {
    @EnvironmentObject private var appState: AppState
    let currentItem: MediaItem
    var palette: AlbumColorPalette = .fallback
    @State private var draggedItem: MediaItem?
    @State private var playlistCreationRequest: MusicPlaylistCreationRequest?

    var body: some View {
        let queue = appState.musicQueue
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

                Button {
                    appState.clearMusicQueue(keepingCurrent: true)
                } label: {
                    Label("清空", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
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
                List {
                    ForEach(queue) { queueItem in
                        MusicQueueRow(
                            item: queueItem,
                            isCurrent: queueItem.id == currentItem.id,
                            onRemove: {
                                appState.removeFromMusicQueue(queueItem)
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.play(queueItem)
                        }
                        .onDrag {
                            draggedItem = queueItem
                            return NSItemProvider(object: queueItem.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: MusicQueueDropDelegate(
                                targetItem: queueItem,
                                items: queue,
                                draggedItem: $draggedItem,
                                move: appState.moveMusicQueueItems
                            )
                        )
                        .contextMenu {
                            Button("播放") { appState.play(queueItem) }
                            MusicPlaylistActionsMenu(
                                tracks: [queueItem],
                                suggestedName: queueItem.title,
                                onCreateNew: { playlistCreationRequest = $0 }
                            )
                            Button("移出队列") { appState.removeFromMusicQueue(queueItem) }
                                .disabled(queueItem.id == currentItem.id)
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
                .glassPerformanceMode(.balanced)
                .frame(width: 430, height: 320)
            }
        }
        .padding(16)
        .frame(width: 460)
        .modifier(MusicPopoverGlass(palette: palette, cornerRadius: 24))
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
}

private struct MusicQueueRow: View {
    let item: MediaItem
    let isCurrent: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.58))
                .frame(width: 18)

            PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(item.artistAlbumLine ?? "未知艺人")
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
            .pointerLiquidEdge(cornerRadius: 12, intensity: 0.78)
            .disabled(isCurrent)
            .help(isCurrent ? "正在播放的歌曲不能移出" : "移出队列")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
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
    @Binding var draggedItem: MediaItem?
    let move: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem.id != targetItem.id,
              let sourceIndex = items.firstIndex(where: { $0.id == draggedItem.id }),
              let targetIndex = items.firstIndex(where: { $0.id == targetItem.id }) else {
            return
        }
        withAnimation(AppMotion.fast) {
            move(IndexSet(integer: sourceIndex), targetIndex > sourceIndex ? targetIndex + 1 : targetIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
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
                .foregroundStyle(item.favorite ? palette.accent.color : Color.primary.opacity(0.66))
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
            .background(
                shape.fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.40))
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

private struct AlbumGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: MpvPlayerController
    let posterPath: String?
    let title: String
    let palette: AlbumColorPalette
    let animationReady: Bool
    let albumLightCenter: CGPoint

    @State private var clockReferenceTime: Double = 0
    @State private var clockReferenceDate = Date()

    var body: some View {
        // P3：尊重"减弱动态效果"。开启后暂停节奏律动 Canvas（保留静态专辑光板），TimelineView 不再驱动重绘。
        let isAnimating = animationReady && controller.isPlaying && !reduceMotion

        ZStack {
            AlbumBackdropStaticLayer(
                posterPath: posterPath,
                title: title,
                palette: palette,
                colorScheme: colorScheme,
                albumLightCenter: albumLightCenter
            )

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimating)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                let playbackClock = smoothPlaybackClock(at: timeline.date)
                let pulse = (sin(playbackClock * Double.pi * 1.92) + 1) / 2
                let subPulse = (sin(playbackClock * Double.pi * 0.96 + 0.65) + 1) / 2
                let shimmer = (sin(phase * 0.82 + playbackClock * 0.22) + 1) / 2
                let beat = isAnimating ? min(0.96, 0.40 + pow(pulse, 1.18) * 0.40 + subPulse * 0.11 + shimmer * 0.05) : 0.40
                let slow = isAnimating ? (sin(phase * 0.30 + playbackClock * 0.13) + 1) / 2 : 0.40
                backdrop(beat: beat, slow: slow)
            }
        }
        .onAppear {
            resetPlaybackClock(to: controller.currentTime)
        }
        .onChange(of: controller.currentTime) { newTime in
            synchronizePlaybackClock(with: newTime)
        }
        .onChange(of: isAnimating) { _ in
            resetPlaybackClock(to: controller.currentTime)
        }
    }

    private func smoothPlaybackClock(at date: Date) -> Double {
        max(clockReferenceTime + date.timeIntervalSince(clockReferenceDate), 0)
    }

    private func resetPlaybackClock(to time: Double) {
        clockReferenceTime = max(time, 0)
        clockReferenceDate = Date()
    }

    private func synchronizePlaybackClock(with time: Double) {
        let now = Date()
        let expected = smoothPlaybackClock(at: now)
        let clampedTime = max(time, 0)
        guard abs(expected - clampedTime) > 0.08 else { return }
        clockReferenceTime = clampedTime
        clockReferenceDate = now
    }

    private func backdrop(beat: Double, slow: Double) -> some View {
        AlbumBackdropLightCanvas(
            palette: palette,
            center: albumLightCenter,
            beat: beat,
            slow: slow,
            colorScheme: colorScheme
        )
        .ignoresSafeArea()
    }
}

private struct MusicFullScreenGlassLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .opacity(colorScheme == .dark ? 0.50 : 0.58)
            Rectangle()
                .fill(palette.backdropBaseColor(for: colorScheme).opacity(colorScheme == .dark ? 0.24 : 0.18))
                .overlay {
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.09 : 0.25),
                            palette.primary.color.opacity(colorScheme == .dark ? 0.08 : 0.11),
                            .white.opacity(colorScheme == .dark ? 0.030 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .overlay {
                    RadialGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.08 : 0.26),
                            palette.primary.color.opacity(colorScheme == .dark ? 0.075 : 0.095),
                            .clear
                        ],
                        center: UnitPoint(x: 0.28, y: 0.24),
                        startRadius: 0,
                        endRadius: 720
                    )
                }
                .overlay {
                    Rectangle()
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.22), lineWidth: 1)
                        .blendMode(.screen)
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct AlbumBackdropStaticLayer: View {
    let posterPath: String?
    let title: String
    let palette: AlbumColorPalette
    let colorScheme: ColorScheme
    let albumLightCenter: CGPoint

    var body: some View {
        ZStack {
            palette.backdropBaseColor(for: colorScheme)
            AlbumBlurredArtworkBackdrop(
                posterPath: posterPath,
                title: title,
                colorScheme: colorScheme
            )
            LinearGradient(
                colors: [
                    colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.52),
                    palette.primary.color.opacity(colorScheme == .dark ? 0.15 : 0.18),
                    colorScheme == .dark ? Color.black.opacity(0.12) : Color.white.opacity(0.24)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // 调色板对角渐变降透明度：只做轻微染色统一，不再盖住下层多彩封面。
            LinearGradient(
                colors: [
                    palette.primary.color.opacity(colorScheme == .dark ? 0.34 : 0.30),
                    palette.secondary.color.opacity(colorScheme == .dark ? 0.26 : 0.24),
                    palette.accent.color.opacity(colorScheme == .dark ? 0.24 : 0.22),
                    palette.primary.color.opacity(colorScheme == .dark ? 0.16 : 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    palette.primary.color.opacity(colorScheme == .dark ? 0.22 : 0.19),
                    palette.accent.color.opacity(colorScheme == .dark ? 0.12 : 0.11),
                    .clear
                ],
                center: UnitPoint(x: 0.28, y: 0.42),
                startRadius: 28,
                endRadius: 720
            )
            LinearGradient(
                colors: [
                    .white.opacity(colorScheme == .dark ? 0.10 : 0.34),
                    palette.primary.color.opacity(colorScheme == .dark ? 0.25 : 0.23),
                    .clear,
                    palette.secondary.color.opacity(colorScheme == .dark ? 0.20 : 0.19)
                ],
                startPoint: UnitPoint(x: 0.08, y: 0.03),
                endPoint: UnitPoint(x: 0.94, y: 0.98)
            )
            AlbumBackdropStaticGlowCanvas(
                palette: palette,
                center: albumLightCenter,
                colorScheme: colorScheme
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct AlbumBlurredArtworkBackdrop: View {
    let posterPath: String?
    let title: String
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { proxy in
            // 提高真实封面（高斯模糊）的占比与饱和度，让背景呈现封面本身丰富的多彩色，
            // 而不是被上层单调的调色板渐变盖住——更接近 Apple Music 正在播放的多彩流动背景。
            PosterImage(
                path: posterPath,
                title: title,
                mediaType: .music,
                cacheTargetSize: CGSize(width: 420, height: 420)
            )
            .frame(width: proxy.size.width * 1.22, height: proxy.size.height * 1.22)
            .position(x: proxy.size.width * 0.50, y: proxy.size.height * 0.50)
            .scaleEffect(1.12)
            .blur(radius: 90)
            .saturation(1.66)
            .contrast(1.05)
            .opacity(colorScheme == .dark ? 0.66 : 0.70)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

private struct AlbumBackdropStaticGlowCanvas: View {
    let palette: AlbumColorPalette
    let center: CGPoint
    let colorScheme: ColorScheme

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let canvasSpan = max(size.width, size.height)
            let longReach = max(canvasSpan * 0.82, 760)
            let midReach = max(canvasSpan * 0.52, 520)

            var radiance = context
            radiance.blendMode = .screen

            // 主光：更强的中心专辑色照射
            drawRadialGlow(
                in: &radiance,
                center: center,
                diameter: longReach,
                endRadius: longReach * 0.70,
                colors: [
                    palette.glowPrimary.color.opacity(colorScheme == .dark ? 0.42 : 0.36),
                    palette.glowPrimary.color.opacity(colorScheme == .dark ? 0.26 : 0.22),
                    palette.glowSecondary.color.opacity(colorScheme == .dark ? 0.16 : 0.14),
                    palette.glowAccent.color.opacity(colorScheme == .dark ? 0.090 : 0.078),
                    .clear
                ]
            )
            // 近场聚光：紧贴专辑封面的强光，形成"光晕正中"的立体感
            drawRadialGlow(
                in: &radiance,
                center: center,
                diameter: midReach * 0.58,
                endRadius: midReach * 0.38,
                colors: [
                    palette.glowPrimary.color.opacity(colorScheme == .dark ? 0.30 : 0.26),
                    palette.glowAccent.color.opacity(colorScheme == .dark ? 0.15 : 0.13),
                    .clear
                ]
            )
            drawRadialGlow(
                in: &radiance,
                center: CGPoint(x: center.x + 150, y: center.y + 54),
                diameter: midReach,
                endRadius: midReach * 0.66,
                colors: [
                    palette.accent.color.opacity(colorScheme == .dark ? 0.24 : 0.20),
                    palette.primary.color.opacity(colorScheme == .dark ? 0.10 : 0.09),
                    .clear
                ]
            )
            drawRadialGlow(
                in: &radiance,
                center: CGPoint(x: center.x + 245, y: center.y - 100),
                diameter: midReach * 0.86,
                endRadius: midReach * 0.58,
                colors: [
                    palette.secondary.color.opacity(colorScheme == .dark ? 0.18 : 0.15),
                    palette.accent.color.opacity(colorScheme == .dark ? 0.08 : 0.07),
                    .clear
                ]
            )
            drawRadialGlow(
                in: &radiance,
                center: CGPoint(x: center.x - 132, y: center.y + 172),
                diameter: midReach * 0.64,
                endRadius: midReach * 0.48,
                colors: [
                    palette.primary.color.opacity(colorScheme == .dark ? 0.15 : 0.13),
                    palette.accent.color.opacity(colorScheme == .dark ? 0.065 : 0.055),
                    .clear
                ]
            )

            let beamWidth = longReach * 1.02
            let beamHeight: CGFloat = 245
            var beamContext = radiance
            beamContext.translateBy(x: center.x + longReach * 0.26, y: center.y + 10)
            beamContext.rotate(by: .degrees(-9))
            let beamRect = CGRect(x: -beamWidth / 2, y: -beamHeight / 2, width: beamWidth, height: beamHeight)
            beamContext.fill(
                Path(roundedRect: beamRect, cornerRadius: beamHeight / 2),
                with: .linearGradient(
                    Gradient(colors: [
                        palette.primary.color.opacity(0.00),
                        palette.primary.color.opacity(colorScheme == .dark ? 0.12 : 0.105),
                        palette.accent.color.opacity(colorScheme == .dark ? 0.15 : 0.13),
                        palette.secondary.color.opacity(colorScheme == .dark ? 0.10 : 0.09),
                        .clear
                    ]),
                    startPoint: CGPoint(x: beamRect.minX, y: 0),
                    endPoint: CGPoint(x: beamRect.maxX, y: 0)
                )
            )
        }
        .allowsHitTesting(false)
    }

    private func drawRadialGlow(
        in context: inout GraphicsContext,
        center: CGPoint,
        diameter: CGFloat,
        endRadius: CGFloat,
        colors: [Color]
    ) {
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: colors),
                center: center,
                startRadius: 0,
                endRadius: endRadius
            )
        )
    }
}

private struct AlbumBackdropLightCanvas: View {
    let palette: AlbumColorPalette
    let center: CGPoint
    let beat: Double
    let slow: Double
    let colorScheme: ColorScheme

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let rectPath = Path(rect)

            var radiance = context
            radiance.blendMode = .screen

            let driftX = CGFloat(cos(slow * Double.pi * 2) * (30 + beat * 28))
            let driftY = CGFloat(sin((slow + beat * 0.16) * Double.pi * 2) * (22 + beat * 20))
            // 触发阈值降低 0.36→0.32，振幅 0.54→0.64 → 弱拍也能看到更明显的脉冲
            let localPulse = min(max((beat - 0.32) / 0.64, 0), 1)
            let localPulseValue = CGFloat(localPulse)

            // 主光：基础透明度提高，peak 振幅翻倍以上
            drawRadialGlow(
                in: &radiance,
                center: CGPoint(x: center.x + driftX * 0.70, y: center.y + driftY * 0.70),
                diameter: 360 + localPulseValue * 120,
                endRadius: 190 + localPulseValue * 68,
                colors: [
                    palette.primary.color.opacity((colorScheme == .dark ? 0.42 : 0.36) + localPulse * 0.22),
                    palette.accent.color.opacity(0.16 + localPulse * 0.090),
                    .clear
                ]
            )
            // 次光：扩展范围，随节拍漂移更明显
            drawRadialGlow(
                in: &radiance,
                center: CGPoint(x: center.x + 150 + driftX * 0.52, y: center.y + 18 - driftY * 0.28),
                diameter: 420 + localPulseValue * 100,
                endRadius: 220 + localPulseValue * 60,
                colors: [
                    palette.primary.color.opacity(0.20 + localPulse * 0.095),
                    palette.secondary.color.opacity(0.10 + slow * 0.040),
                    .clear
                ]
            )
            // 第三光球：更低位置，形成环绕感
            drawRadialGlow(
                in: &radiance,
                center: CGPoint(x: center.x + 44 - driftX * 0.20, y: center.y + 164 + driftY * 0.42),
                diameter: 320 + localPulseValue * 80,
                endRadius: 170 + localPulseValue * 48,
                colors: [
                    palette.accent.color.opacity(0.17 + localPulse * 0.065),
                    palette.primary.color.opacity(0.085 + slow * 0.028),
                    .clear
                ]
            )

            context.fill(rectPath, with: .color(colorScheme == .dark ? Color.black.opacity(0.06) : Color.white.opacity(0.14 - beat * 0.016)))
        }
        .allowsHitTesting(false)
    }

    private func drawRadialGlow(
        in context: inout GraphicsContext,
        center: CGPoint,
        diameter: CGFloat,
        endRadius: CGFloat,
        colors: [Color]
    ) {
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: colors),
                center: center,
                startRadius: 0,
                endRadius: endRadius
            )
        )
    }
}

private struct AlbumNearFieldIlluminationLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: MpvPlayerController
    let palette: AlbumColorPalette
    let center: CGPoint
    let animationReady: Bool

    @State private var clockReferenceTime: Double = 0
    @State private var clockReferenceDate = Date()

    var body: some View {
        let isAnimating = animationReady && controller.isPlaying && !reduceMotion

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimating)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            let playbackClock = smoothPlaybackClock(at: timeline.date)
            let pulse = (sin(playbackClock * Double.pi * 1.82) + 1) / 2
            let subPulse = (sin(playbackClock * Double.pi * 0.92 + 0.58) + 1) / 2
            let slow = (sin(phase * 0.42 + playbackClock * 0.10) + 1) / 2
            let beat = isAnimating ? min(1, 0.30 + pow(pulse, 1.34) * 0.48 + subPulse * 0.12) : 0.30
            nearField(beat: beat, slow: slow)
        }
        .onAppear {
            resetPlaybackClock(to: controller.currentTime)
        }
        .onChange(of: controller.currentTime) { newTime in
            synchronizePlaybackClock(with: newTime)
        }
        .onChange(of: isAnimating) { _ in
            resetPlaybackClock(to: controller.currentTime)
        }
        .allowsHitTesting(false)
    }

    private func nearField(beat: Double, slow: Double) -> some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            var radiance = context
            radiance.blendMode = .screen

            let beatValue = CGFloat(beat)
            let driftX = CGFloat(cos(slow * Double.pi * 2.0) * (18 + beat * 24))
            let driftY = CGFloat(sin((slow + beat * 0.14) * Double.pi * 2.0) * (14 + beat * 18))
            let localCenter = CGPoint(x: center.x + driftX, y: center.y + driftY)
            let rightWash = CGPoint(x: center.x + 168 + driftX * 0.56, y: center.y + 36 - driftY * 0.22)
            let lowerWash = CGPoint(x: center.x + 40 - driftX * 0.24, y: center.y + 166 + driftY * 0.36)

            drawRadialGlow(
                in: &radiance,
                center: localCenter,
                diameter: 360 + beatValue * 86,
                endRadius: 172 + beatValue * 52,
                colors: [
                    palette.primary.color.opacity((colorScheme == .dark ? 0.34 : 0.30) + beat * 0.15),
                    palette.accent.color.opacity(0.14 + beat * 0.070),
                    .clear
                ]
            )
            drawRadialGlow(
                in: &radiance,
                center: rightWash,
                diameter: 460 + beatValue * 92,
                endRadius: 230 + beatValue * 52,
                colors: [
                    palette.secondary.color.opacity(0.16 + beat * 0.060),
                    palette.primary.color.opacity(0.10 + slow * 0.035),
                    .clear
                ]
            )
            drawRadialGlow(
                in: &radiance,
                center: lowerWash,
                diameter: 320 + beatValue * 70,
                endRadius: 166 + beatValue * 40,
                colors: [
                    palette.accent.color.opacity(0.12 + beat * 0.055),
                    palette.primary.color.opacity(0.075 + slow * 0.025),
                    .clear
                ]
            )

            var beamContext = radiance
            beamContext.translateBy(x: center.x + 230 + driftX * 0.34, y: center.y + 12 + driftY * 0.16)
            beamContext.rotate(by: .degrees(-7 + beat * 3.2))
            let beamWidth = min(max(size.width * 0.34, 420), 620)
            let beamHeight: CGFloat = 112 + beatValue * 26
            let beamRect = CGRect(x: -beamWidth / 2, y: -beamHeight / 2, width: beamWidth, height: beamHeight)
            beamContext.fill(
                Path(roundedRect: beamRect, cornerRadius: beamHeight / 2),
                with: .linearGradient(
                    Gradient(colors: [
                        .clear,
                        palette.primary.color.opacity(0.055 + beat * 0.050),
                        palette.accent.color.opacity(0.075 + slow * 0.030),
                        .clear
                    ]),
                    startPoint: CGPoint(x: beamRect.minX, y: beamRect.midY),
                    endPoint: CGPoint(x: beamRect.maxX, y: beamRect.midY)
                )
            )
        }
        .ignoresSafeArea()
    }

    private func smoothPlaybackClock(at date: Date) -> Double {
        max(clockReferenceTime + date.timeIntervalSince(clockReferenceDate), 0)
    }

    private func resetPlaybackClock(to time: Double) {
        clockReferenceTime = max(time, 0)
        clockReferenceDate = Date()
    }

    private func synchronizePlaybackClock(with time: Double) {
        let now = Date()
        let expected = smoothPlaybackClock(at: now)
        let clampedTime = max(time, 0)
        guard abs(expected - clampedTime) > 0.08 else { return }
        clockReferenceTime = clampedTime
        clockReferenceDate = now
    }

    private func drawRadialGlow(
        in context: inout GraphicsContext,
        center: CGPoint,
        diameter: CGFloat,
        endRadius: CGFloat,
        colors: [Color]
    ) {
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: colors),
                center: center,
                startRadius: 0,
                endRadius: endRadius
            )
        )
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
    @State private var pointerLocation: CGPoint?
    @State private var lastPointerLocation: CGPoint?
    @State private var lastPointerUpdate = Date.distantPast
    @State private var globalFrame: CGRect = .zero

    private var samplesPointer: Bool {
        !reduceMotion &&
        !suppressHoverDuringScroll &&
        !preferStaticGlassSurfaces &&
        glassPerformanceMode.allowsPointerSampling
    }

    private var pointerContext: LiquidPointerContext? {
        guard samplesPointer,
              let pointerLocation,
              globalFrame.width > 0,
              globalFrame.height > 0 else { return nil }
        let globalLocation = CGPoint(
            x: globalFrame.minX + pointerLocation.x,
            y: globalFrame.minY + pointerLocation.y
        )
        let radius = min(max(max(globalFrame.width, globalFrame.height) * 0.30, 86), 210)
        return LiquidPointerContext(
            globalLocation: globalLocation,
            radius: radius,
            tint: palette.primary.color,
            intensity: 0.92 + 0.18 * tintStrength
        )
    }

    private func tintOpacity(_ value: Double) -> Double {
        value * tintStrength
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .environment(\.liquidPointerContext, samplesPointer ? pointerContext : nil)
            // 统一播放器浮层为单层薄玻璃透镜：系统 material 负责真实背景采样，
            // 专辑色只作为轻 tint / 边缘折射，不再叠出亚克力白板感。
            .background(
                shape.fill(.thinMaterial)
            )
            .background(
                shape.fill(palette.backdropBaseColor(for: colorScheme).opacity(colorScheme == .dark ? 0.10 : 0.075))
            )
            .background(
                shape.fill(Color.white.opacity(colorScheme == .dark ? 0.030 : 0.070))
            )
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.14 : 0.24),
                            .white.opacity(colorScheme == .dark ? 0.030 : 0.060),
                            palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.060 : 0.075))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.14 : 0.22),
                                palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.070 : 0.090)),
                                .white.opacity(colorScheme == .dark ? 0.030 : 0.052),
                                .clear
                            ],
                            startPoint: UnitPoint(x: -0.08, y: -0.12),
                            endPoint: UnitPoint(x: 0.72, y: 0.78)
                        )
                    )
                    .opacity(0.70)
                    .allowsHitTesting(false)
            )
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.46 : 0.78),
                            palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.24 : 0.36)),
                            .white.opacity(colorScheme == .dark ? 0.16 : 0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.4
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.34), lineWidth: 0.65)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                shape
                    .strokeBorder(palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.18 : 0.28)), lineWidth: 0.9)
                    .blur(radius: 0.6)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
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
            .contentShape(shape)
            // P0：歌词/控制玻璃原有 radius 72–80 的双重专辑色投影 = 巨幅离屏模糊，两块面板叠加是
            // 展开动画 <10fps 的主因之一。收敛为单层中等专辑色辉光 + 一层浅黑景深，视觉仍有发光感。
            .shadow(color: palette.primary.color.opacity(colorScheme == .dark ? 0.24 : 0.18), radius: 20, x: -6, y: 9)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.078), radius: 13, y: 7)
            .overlay(alignment: .leading) {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.38 : 0.48)),
                                palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.16 : 0.22)),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 2.2
                    )
                    .blur(radius: 1.6)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .overlay {
                GeometryReader { proxy in
                    if samplesPointer, let pointerLocation, proxy.size.width > 0, proxy.size.height > 0 {
                        let x = min(max(pointerLocation.x / proxy.size.width, 0), 1)
                        let y = min(max(pointerLocation.y / proxy.size.height, 0), 1)
                        let lightPoint = UnitPoint(x: x, y: y)
                        ZStack {
                            shape
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            .white.opacity(colorScheme == .dark ? 0.20 : 0.34),
                                            palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.16 : 0.24)),
                                            .clear
                                        ],
                                        center: lightPoint,
                                        startRadius: 0,
                                        endRadius: max(proxy.size.width, proxy.size.height) * 0.70
                                    )
                                )

                            shape
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(colorScheme == .dark ? 0.38 : 0.58),
                                            palette.primary.color.opacity(tintOpacity(colorScheme == .dark ? 0.18 : 0.30)),
                                            .white.opacity(colorScheme == .dark ? 0.10 : 0.18)
                                        ],
                                        startPoint: lightPoint,
                                        endPoint: UnitPoint(x: 1 - x, y: 1 - y)
                                    ),
                                    lineWidth: 1.05
                                )
                        }
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                    }
                }
            }
            .onContinuousHover { phase in
                guard samplesPointer else {
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
                        minInterval: glassPerformanceMode.pointerUpdateInterval,
                        minDistance: glassPerformanceMode.pointerMinDistance
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

private struct KaraokeLyricLine: View {
    let line: TimedLyricLine
    let currentTime: Double
    let palette: AlbumColorPalette
    let isActive: Bool
    let progress: Double

    var body: some View {
        if isActive {
            activeLine
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .lineSpacing(10)
                .shadow(color: palette.primary.color.opacity(0.22), radius: 18, y: 7)
                .shadow(color: palette.accent.color.opacity(0.12), radius: 10, y: 3)
                .animation(AppMotion.standard, value: progress)
        } else {
            Text(line.text)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.52))
                .lineSpacing(10)
        }
    }

    @ViewBuilder
    private var activeLine: some View {
        if !line.segments.isEmpty {
            segmentedHighlightedText
        } else {
            LyricProgressWrappingText(text: line.text, progress: progress, palette: palette)
        }
    }

    private var segmentedHighlightedText: Text {
        var text = Text("")
        let activeIndex = line.segments.indices.last { line.segments[$0].time <= currentTime + 0.05 } ?? 0
        for (index, segment) in line.segments.enumerated() {
            let nextTime = line.segments.indices.contains(index + 1) ? line.segments[index + 1].time : segment.time + 0.36
            let duration = max(nextTime - segment.time, 0.18)
            let localProgress = min(max((currentTime - segment.time) / duration, 0), 1)
            let color: Color
            if index < activeIndex {
                color = palette.playedLyric.color.opacity(0.98)
            } else if index == activeIndex {
                color = palette.playedLyric.color.opacity(0.50 + localProgress * 0.46)
            } else {
                color = Color.primary.opacity(0.32)
            }

            text = text
            + Text(segment.text)
                .foregroundColor(color)
        }
        return text
    }
}

private struct LyricGlyph: Identifiable {
    let id: Int
    let value: String
}

private struct LyricProgressWrappingText: View {
    let text: String
    let progress: Double
    let palette: AlbumColorPalette

    var body: some View {
        let glyphs = Array(text).enumerated().map { entry in
            LyricGlyph(id: entry.offset, value: String(entry.element))
        }
        let totalCount = glyphs.count

        LyricFlowLayout(spacing: 0, lineSpacing: 10) {
            ForEach(glyphs) { glyph in
                Text(glyph.value)
                    .foregroundStyle(color(for: glyph.id, totalCount: totalCount))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel(text)
    }

    private func color(for offset: Int, totalCount: Int) -> Color {
        guard totalCount > 0 else { return Color.primary.opacity(0.34) }
        let head = min(max(progress, 0), 1)
        let location = Double(offset) / Double(max(totalCount - 1, 1))
        let distance = location - head
        if distance <= -0.08 {
            return palette.playedLyric.color.opacity(0.98)
        }
        if distance <= 0.14 {
            let blend = 1 - min(max((distance + 0.08) / 0.22, 0), 1)
            return palette.playedLyric.color.opacity(0.56 + blend * 0.40)
        }
        return Color.primary.opacity(0.34)
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
            let nextWidth = current.isEmpty ? size.width : currentWidth + spacing + size.width
            if nextWidth > maxWidth, !current.isEmpty {
                commitRow()
            }
            current.append(index)
            currentWidth = current.count == 1 ? size.width : currentWidth + spacing + size.width
            currentHeight = max(currentHeight, size.height)
        }
        commitRow()

        var positions = Array(repeating: CGPoint.zero, count: subviews.count)
        var y: CGFloat = 0
        for rowIndex in rows.indices {
            var x = max((maxWidth - rowWidths[rowIndex]) / 2, 0)
            for itemIndex in rows[rowIndex] {
                positions[itemIndex] = CGPoint(x: x, y: y)
                x += sizes[itemIndex].width + spacing
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

private struct TimedLyricSegment: Identifiable, Hashable {
    let id = UUID()
    var time: Double
    var text: String
}

private struct TimedLyricLine: Identifiable, Hashable {
    let id = UUID()
    var time: Double
    var text: String
    var segments: [TimedLyricSegment] = []

    static func parse(_ text: String) -> [TimedLyricLine] {
        text
            .components(separatedBy: .newlines)
            .flatMap(parseLine)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time < $1.time }
    }

    static func activeIndex(in lines: [TimedLyricLine], at time: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        let targetTime = time + 0.15
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
        return active
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

private struct AlbumColorPalette: Equatable {
    var primary: AlbumPaletteColor
    var secondary: AlbumPaletteColor
    var accent: AlbumPaletteColor

    var playedLyric: AlbumPaletteColor {
        primary.deepenedForLyric()
    }

    // 发光专用色：深色专辑取其稍浅的版本（保色相、提亮），避免深色专辑发出"暗光/脏光"。
    var glowPrimary: AlbumPaletteColor { primary.lightenedForGlow() }
    var glowSecondary: AlbumPaletteColor { secondary.lightenedForGlow() }
    var glowAccent: AlbumPaletteColor { accent.lightenedForGlow() }

    func backdropBaseColor(for colorScheme: ColorScheme) -> Color {
        let whiteMix = colorScheme == .dark ? 0.06 : 0.54
        let primaryWeight = colorScheme == .dark ? 0.64 : 0.28
        let secondaryWeight = colorScheme == .dark ? 0.24 : 0.12
        let accentWeight = colorScheme == .dark ? 0.14 : 0.08
        let red = min(max(primary.red * primaryWeight + secondary.red * secondaryWeight + accent.red * accentWeight + whiteMix, 0), 1)
        let green = min(max(primary.green * primaryWeight + secondary.green * secondaryWeight + accent.green * accentWeight + whiteMix, 0), 1)
        let blue = min(max(primary.blue * primaryWeight + secondary.blue * secondaryWeight + accent.blue * accentWeight + whiteMix, 0), 1)
        return Color(red: red, green: green, blue: blue)
    }

    static let fallback = AlbumColorPalette(
        primary: AlbumPaletteColor(red: 0.12, green: 0.58, blue: 0.98),
        secondary: AlbumPaletteColor(red: 0.10, green: 0.78, blue: 0.86),
        accent: AlbumPaletteColor(red: 0.46, green: 0.36, blue: 0.98)
    )
}

private struct AlbumPaletteColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
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
        if saturation < 0.12 {
            let neutral = min(max(brightness, 0.22), 0.92)
            return AlbumPaletteColor(red: Double(neutral), green: Double(neutral), blue: Double(neutral))
        }

        let cleanedSaturation = min(max(saturation * 1.12, 0.20), 0.86)
        let cleanedBrightness = min(max(brightness * 1.08, 0.34), 0.95)
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

private enum AlbumPaletteCache {
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
                let saturationWeight = max(0.08, Double(saturation))
                let weight = pow(saturationWeight, 1.18) * (0.72 + Double(brightness) * 0.36)
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

        let hueRanks = rankedHues(in: samples)
        let dominantHue = hueRanks.first?.hue ?? dominantHue(in: samples)
        let primary = weightedAverage(
            samples,
            dominantHue: dominantHue,
            maxHueDistance: 0.11,
            includeNeutrals: true
        ) ?? weightedAverage(samples, dominantHue: nil, maxHueDistance: 1, includeNeutrals: true) ?? AlbumColorPalette.fallback.primary
        let primaryHue = dominantHue ?? Double(primary.hue)
        // 取图像中真实存在、且有一定权重的次要色相作为 secondary/accent（阈值放宽以更丰富多彩），
        // 仅在确实没有第二种主色时才退回到与主色相近的类比色（小幅相移，避免对蓝色封面凭空取绿）。
        let secondaryHue = distinctHue(in: hueRanks, avoiding: [primaryHue], minDistance: 0.07, minWeightFraction: 0.12)
            ?? wrappedHue(primaryHue + 0.06)
        let accentHue = distinctHue(in: hueRanks, avoiding: [primaryHue, secondaryHue], minDistance: 0.09, minWeightFraction: 0.11)
            ?? wrappedHue(primaryHue - 0.06)

        let secondary = (
            weightedAverage(
                samples,
                dominantHue: secondaryHue,
                maxHueDistance: 0.13,
                includeNeutrals: false,
                minSaturation: 0.10,
                minBrightness: 0.14
            ) ?? primary.shiftedHue(
                by: CGFloat(secondaryHue - primaryHue),
                saturationMultiplier: 0.88,
                brightnessMultiplier: 1.08,
                minSaturation: 0.18,
                maxSaturation: 0.66,
                minBrightness: 0.46,
                maxBrightness: 0.96
            )
        ).adjustedPreservingHue(
            saturationMultiplier: 0.88,
            brightnessMultiplier: 1.12,
            minSaturation: 0.12,
            maxSaturation: 0.70,
            minBrightness: 0.44,
            maxBrightness: 0.96
        )
        let accent = (
            weightedAverage(
                samples,
                dominantHue: accentHue,
                maxHueDistance: 0.15,
                includeNeutrals: false,
                minSaturation: max(0.14, Double(primary.saturation) * 0.58),
                minBrightness: 0.12
            ) ?? primary.shiftedHue(
                by: CGFloat(accentHue - primaryHue),
                saturationMultiplier: 1.16,
                brightnessMultiplier: 1.04,
                minSaturation: 0.24,
                maxSaturation: 0.88,
                minBrightness: 0.40,
                maxBrightness: 0.96
            )
        ).adjustedPreservingHue(
            saturationMultiplier: 1.14,
            brightnessMultiplier: 1.04,
            minSaturation: 0.20,
            maxSaturation: 0.86,
            minBrightness: 0.34,
            maxBrightness: 0.95
        )

        return AlbumColorPalette(
            primary: primary,
            secondary: secondary,
            accent: accent
        )
    }

    private static func rankedHues(in samples: [AlbumPaletteSample]) -> [(hue: Double, weight: Double)] {
        let bucketCount = 48
        var buckets = Array(repeating: 0.0, count: bucketCount)
        for sample in samples where sample.saturation >= 0.13 && sample.brightness >= 0.12 && sample.brightness <= 0.98 {
            let bucket = min(bucketCount - 1, max(0, Int(sample.hue * Double(bucketCount))))
            let vividness = pow(max(sample.saturation, 0.10), 1.34)
            let brightnessWeight = 0.60 + min(max(sample.brightness, 0), 1) * 0.44
            buckets[bucket] += sample.weight * vividness * brightnessWeight
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
            let neutralScale = neutral ? 0.22 : 1.0
            let brightnessScale = 0.70 + sample.brightness * 0.38
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
    private var accessOrder: [String] = []
    private let maxValues = 64

    func palette(for path: String) -> AlbumColorPalette? {
        guard let value = values[path] else { return nil }
        markRecentlyUsed(path)
        return value
    }

    func store(_ palette: AlbumColorPalette, for path: String) {
        values[path] = palette
        markRecentlyUsed(path)
        while values.count > maxValues, let oldestPath = accessOrder.first {
            accessOrder.removeFirst()
            values.removeValue(forKey: oldestPath)
        }
    }

    private func markRecentlyUsed(_ path: String) {
        accessOrder.removeAll { $0 == path }
        accessOrder.append(path)
    }
}
