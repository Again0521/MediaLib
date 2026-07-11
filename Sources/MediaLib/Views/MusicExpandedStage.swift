import MediaLibCore
import SwiftUI


enum MusicExpandedVariant {
    case liuli
    case wujie
    var isWujie: Bool { self == .wujie }
}

/// 琉璃 / 无界共享的展开页主题层（R2）。只读 `MusicPlaybackContext` + `variant`，
/// 不再访问 MusicPlayerView 的任何成员、不读 appState；变体由宿主按当前方案传入。
/// 本轮先与宿主同文件（private 视图基元仍可见）；拆到独立 LiuliStage/WujieStage 文件，
/// 需先把这些共享基元提升为 internal，留待后续一轮机械完成。
struct MusicExpandedStage: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: MusicPlaybackContext
    let variant: MusicExpandedVariant
    let transitionNamespace: Namespace.ID?
    @State private var wujieControlsBottom: CGFloat = 0

    // 名称别名：让搬运来的 body/面板代码对业务数据的引用保持原样，零改动、降低搬运风险。
    private var currentItem: MediaItem { context.item }
    private var albumPalette: AlbumColorPalette { context.palette }
    private var lyrics: String { context.lyrics }
    private var timedLyrics: [TimedLyricLine] { context.timedLyrics }
    private var lyricTimingSource: LyricTimingSource { context.lyricTimingSource }
    private var hasDisplayLyrics: Bool { context.hasDisplayLyrics }
    private var isFetchingLyrics: Bool { context.isFetchingLyrics }
    private var controller: MpvPlayerController { context.controller }
    private var entrancePhase: Int { context.entrancePhase }
    private var glassLayerReady: Bool { context.artworkReady }
    private var isWujie: Bool { variant.isWujie }
    /// 封面是展开/收起的唯一几何锚点，必须全程可见（matched geometry 依赖它承担空间连续性）；
    /// 标题/控制栏等其余组件在封面落位（phase>=1）后才渐显，收起时先于封面渐隐。
    private var identityContentVisible: Bool { reduceMotion || entrancePhase >= 1 }

    var body: some View {
        GeometryReader { geometry in
            let layout = MusicExpandedLayout(size: geometry.size)
            let lyricsPanelReady = reduceMotion || entrancePhase >= 1
            // 无界：整体下移左栏，让封面/标题让开顶部的「收起 / 更多」按钮；发光中心同步下移半个量保持对齐。
            let wujieContentDrop: CGFloat = (isWujie && !layout.stackedLayout) ? MusicWujieTokens.contentDrop : 0
            let wujieGlowDrop: CGFloat = wujieContentDrop * 0.5
            // 无界：左右两侧各加一点外边距——左栏（连同发光）右移、右侧歌词列右沿内收，整体更透气。
            let wujieSideInset: CGFloat = (isWujie && !layout.stackedLayout) ? MusicWujieTokens.sideInset : 0

            ZStack(alignment: .topLeading) {
                MetalAlbumBackdropView(
                    posterPath: currentItem.posterPath,
                    title: currentItem.title,
                    palette: albumPalette,
                    artworkReady: glassLayerReady,
                    albumLightCenter: layout.albumLightCenter,
                    glassIntensity: 1.0,
                    reduceMotion: reduceMotion,
                    dynamicEffectsEnabled: false,
                    colorScheme: colorScheme
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
                .zIndex(0)

                AlbumGlobalGlassVeil(palette: albumPalette, colorScheme: colorScheme)
                    .allowsHitTesting(false)
                    .zIndex(0.5)

                // 真·封面发光：放大封面 + 重高斯模糊 + 圆角方形羽化，铺在清晰封面正后方（见 AlbumGlowBlurCover）。
                // 无界方案把发光画布扩到整窗（fullScreenGlowSide），让封面柔光延伸至整个屏幕；
                // 琉璃方案保持原局部光程（glowBlurSide），互不影响。
                AlbumGlowBlurCover(
                    posterPath: currentItem.posterPath,
                    controller: controller,
                    displaySide: isWujie ? layout.fullScreenGlowSide : layout.glowBlurSide,
                    coverSide: layout.coverDisplaySide,
                    coverGlowEnabled: context.coverGlowEnabled,
                    intensity: isWujie ? 0.42 : 1.0,
                    saturation: isWujie ? 0.34 : 1.0
                )
                .position(x: layout.albumLightCenter.x + wujieSideInset, y: layout.albumLightCenter.y + wujieGlowDrop)
                .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                .allowsHitTesting(false)
                .zIndex(1)

                if isWujie {
                    WujieEnvironmentWash(palette: albumPalette)
                        .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                        .allowsHitTesting(false)
                        .zIndex(1.5)
                }

                ZStack(alignment: .topLeading) {
                    if layout.stackedLayout {
                        ScrollView {
                            VStack(spacing: 28) {
                                // 面板整体不再做入场透明度门控：封面必须从第一帧就可见（几何锚点），
                                // 标题/控制栏的渐显在面板内部各自完成。
                                schemeIdentityPanel(
                                    posterSize: min(layout.posterSize, 230),
                                    glowReach: layout.albumGlowReach,
                                    controlsLight: layout.controlsLight
                                )
                                    .frame(maxWidth: 360)

                                if lyricsPanelReady {
                                    schemeLyricsPanel(light: layout.lyricsLight)
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
                        // 面板整体不再做入场透明度门控：封面必须从第一帧就可见（几何锚点），
                        // 标题/控制栏的渐显在面板内部各自完成。
                        schemeIdentityPanel(
                            posterSize: layout.posterSize,
                            glowReach: layout.albumGlowReach,
                            controlsLight: layout.controlsLight
                        )
                            .frame(width: layout.leftRect.width, height: layout.leftRect.height - wujieContentDrop, alignment: .center)
                            .offset(x: layout.leftRect.minX + wujieSideInset, y: layout.leftRect.minY + wujieContentDrop)

                        if lyricsPanelReady {
                            let lyricsColumnWidth = layout.lyricsRect.width - wujieSideInset
                            // 频谱：基线（频谱/倒影分界）对齐隔空播放所在工具行的按钮底部。
                            // 歌词视口的下边界也对齐到这条基线，让最底部淡出歌词与频谱交界处视觉咬合。
                            let spectrumViewHeight: CGFloat = 132
                            let spectrumBaselineY = wujieControlsBottom
                            let spectrumTopY = spectrumBaselineY - spectrumViewHeight * WujieSpectrum.baselineFromTopFraction
                            let wujieLyricsTop = layout.albumLightCenter.y + wujieContentDrop - layout.coverDisplaySide * 0.5
                            let showSpectrum = isWujie && wujieControlsBottom > wujieLyricsTop + 280
                            // 无界：歌词视觉区顶部与展开封面顶部对齐，底部与工具行按钮底部 / 频谱基线对齐。
                            // `MusicTimedLyricsScrollView` 仍用视口中心锁定被播放行，因此被唱行留在该视觉区中部。
                            let wujieLyricsBottom = wujieControlsBottom > 1
                                ? spectrumBaselineY
                                : layout.lyricsRect.maxY
                            let wujieLyricsHeight = isWujie
                                ? max(wujieLyricsBottom - wujieLyricsTop, 300)
                                : layout.lyricsRect.height
                            let wujieLyricsY = wujieLyricsBottom - wujieLyricsHeight

                            schemeLyricsPanel(light: layout.lyricsLight)
                                .frame(width: lyricsColumnWidth, height: isWujie ? wujieLyricsHeight : layout.lyricsRect.height)
                                .offset(
                                    x: layout.lyricsRect.minX,
                                    y: isWujie ? wujieLyricsY : layout.lyricsRect.minY
                                )
                                .opacity(reduceMotion || entrancePhase >= 2 ? 1 : 0)
                                .scaleEffect(reduceMotion || entrancePhase >= 2 ? 1 : 0.986, anchor: .center)

                            if showSpectrum {
                                WujieSpectrum(controller: controller, palette: albumPalette)
                                    .frame(width: lyricsColumnWidth, height: spectrumViewHeight)
                                    .offset(x: layout.lyricsRect.minX, y: spectrumTopY)
                                    .opacity(reduceMotion || entrancePhase >= 2 ? 1 : 0)
                            }
                        }
                    }

                    floatingMinimizeButton
                        .frame(width: layout.minimizeButtonRect.width, height: layout.minimizeButtonRect.height)
                        .position(x: layout.minimizeButtonRect.midX, y: layout.minimizeButtonRect.midY)
                        .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                        .transition(.opacity)
                        .zIndex(40)

                    if isWujie {
                        WujieMoreButton(
                            item: currentItem,
                            palette: albumPalette,
                            onFetchLyrics: { context.fetchLyrics() }
                        )
                        .position(x: geometry.size.width - layout.minimizeButtonRect.minX - 20, y: layout.minimizeButtonRect.midY)
                        .opacity(reduceMotion || entrancePhase >= 1 ? 1 : 0)
                        .transition(.opacity)
                        .zIndex(41)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .coordinateSpace(name: "wujieContent")
                .onPreferenceChange(WujieControlsBottomKey.self) { value in
                    if abs(value - wujieControlsBottom) > 0.5 {
                        wujieControlsBottom = value
                    }
                }
                .glassPerformanceMode(.full)
                .zIndex(2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 外层不再重复铺同色全屏底：内部背景已完全覆盖，减少一层全窗绘制。
    }

    @ViewBuilder
    private func schemeIdentityPanel(posterSize: CGFloat, glowReach: CGFloat, controlsLight: AlbumComponentLight) -> some View {
        if isWujie {
            borderlessIdentityPanel(posterSize: posterSize, glowReach: glowReach, controlsLight: controlsLight)
        } else {
            musicIdentityPanel(posterSize: posterSize, glowReach: glowReach, controlsLight: controlsLight)
        }
    }

    @ViewBuilder
    private func schemeLyricsPanel(light: AlbumComponentLight) -> some View {
        if isWujie {
            borderlessLyricsPanel(light: light)
        } else {
            lyricsPanel(light: light)
        }
    }

    // MARK: - 无界（Borderless）方案

    /// 无界左栏（R1 重制）：委托给隔离的 `WujieIdentityColumn`——环境中的封面 + 影院级编辑标题 + 统一控制栈。
    /// glowReach / controlsLight 由共享布局保留传入，无界左栏当前不需要（封面发光由整窗 AlbumGlowBlurCover 提供）。
    /// 琉璃 `musicIdentityPanel` 与底栏 mini 播放器零改动。详见文件末尾「无界重做」区。
    private func borderlessIdentityPanel(posterSize: CGFloat, glowReach: CGFloat, controlsLight: AlbumComponentLight) -> some View {
        WujieIdentityColumn(
            item: currentItem,
            controller: controller,
            palette: albumPalette,
            posterSize: posterSize,
            coverGlowEnabled: context.coverGlowEnabled,
            contentVisible: identityContentVisible,
            transitionNamespace: transitionNamespace
        )
    }

    /// 无界右栏（R4 重制）：委托给隔离的 `WujieLyricsColumn`——歌词纯净悬浮于底板、左对齐、被唱行恒锁视口中心。
    /// 逐字歌词行为（居中/可见行数/无卡片）原样沿用、参数收口到 WujieDesignSystem.Lyrics。light 参数无界不需要（旧实现亦未用）。
    private func borderlessLyricsPanel(light: AlbumComponentLight) -> some View {
        WujieLyricsColumn(
            controller: controller,
            itemID: currentItem.id,
            lyrics: lyrics,
            timedLyrics: timedLyrics,
            timingSource: lyricTimingSource,
            hasDisplayLyrics: hasDisplayLyrics,
            isFetchingLyrics: isFetchingLyrics,
            palette: albumPalette,
            userIsBrowsingLyrics: context.userIsBrowsingLyrics,
            onFetchLyrics: {
                context.fetchLyrics()
            },
            onPauseAutoScroll: context.pauseLyricAutoScroll
        )
    }

    private func musicIdentityPanel(posterSize: CGFloat, glowReach: CGFloat, controlsLight: AlbumComponentLight) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            MusicExpandedArtwork(
                item: currentItem,
                controller: controller,
                palette: albumPalette,
                posterSize: posterSize,
                glowReach: glowReach,
                coverGlowEnabled: context.coverGlowEnabled,
                transitionNamespace: transitionNamespace
            )
            .frame(width: posterSize, height: posterSize)

            VStack(spacing: 7) {
                Text(currentItem.title)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                    .shadow(color: albumPalette.primary.color.opacity(colorScheme == .dark ? 0.18 : 0.10), radius: 10, y: 3)
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
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.04), radius: 5, y: 2)
            }
            .frame(maxHeight: 82)
            // 封面落位后标题才浮现（收起时先行渐隐），封面本体不参与门控。
            .opacity(identityContentVisible ? 1 : 0)
            .offset(y: identityContentVisible ? 0 : 14)

            MusicExpandedControls(item: currentItem, controller: controller, palette: albumPalette, light: controlsLight)
                .layoutPriority(1)
                .opacity(identityContentVisible ? 1 : 0)
                .offset(y: identityContentVisible ? 0 : 18)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private var floatingMinimizeButton: some View {
        Button {
            context.requestMinimize()
        } label: {
            MusicChromeButtonContent(systemImage: "chevron.down", palette: albumPalette, controller: controller)
        }
        .buttonStyle(MusicGlassPressStyle(pressScale: 0.95))
        .contentShape(Capsule())
        .help("最小化播放器")
        .accessibilityLabel("最小化播放器")
    }

    private func lyricsPanel(light: AlbumComponentLight) -> some View {
            MusicExpandedLyricsPanel(
                controller: controller,
                itemID: currentItem.id,
                lyrics: lyrics,
            timedLyrics: timedLyrics,
            timingSource: lyricTimingSource,
            hasDisplayLyrics: hasDisplayLyrics,
            isFetchingLyrics: isFetchingLyrics,
            palette: albumPalette,
            light: light,
            userIsBrowsingLyrics: context.userIsBrowsingLyrics,
            onFetchLyrics: {
                context.fetchLyrics()
            },
            onPauseAutoScroll: context.pauseLyricAutoScroll
        )
    }

}
