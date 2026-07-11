import AppKit
import Combine
import MediaLibCore
import SwiftUI

enum HomeVividTokens {
    static var blue: Color { AppColors.referenceBlue }
    static var cyan: Color { AppColors.referenceCyan }
    static let mint = color("22D3A8")
    static let orange = color("FF9F45")
    static let pink = color("FF5C8A")
    static let violet = color("D946EF")
    static let indigo = color("5B6CFF")

    static var textPrimary: Color { AppColors.refTitleText }
    static var textSecondary: Color { AppColors.refSecondaryText }
    static var textTertiary: Color { AppColors.refSubtle }
    static var success: Color { AppColors.success }
    static var mutedData: Color { AppColors.refRowDivider }
    static var border: Color { AppColors.refCardBorder }
    static var controlBorder: Color { AppColors.refOutlineBorder }
    static var sidebarBackground: Color { AppColors.background }
    static var pageBackground: Color { AppColors.pageBackground }

    static let pageHorizontal: CGFloat = 36
    static let pageVertical: CGFloat = 28
    static let sectionTitleSize: CGFloat = 18
    static let cardRadius: CGFloat = 18
    static let largeCardRadius: CGFloat = 24
    static let posterWidth: CGFloat = 158
    static let posterHeight: CGFloat = 236
    static let compactPosterHeight: CGFloat = 226
    static let albumSide: CGFloat = 146
    static let rowGap: CGFloat = 14
    static let moduleSpacing: CGFloat = 22
    static let hoverShadowOpacity: Double = 0.18
    static let hoverShadowRadius: CGFloat = 22
    static let hoverShadowY: CGFloat = 8
    static let widgetQuarterHeight: CGFloat = AppWidgetGridMetrics.homeHeight(.quarter)
    static let widgetHalfHeight: CGFloat = AppWidgetGridMetrics.homeHeight(.half)
    static let widgetTwoThirdsHeight: CGFloat = AppWidgetGridMetrics.homeHeight(.twoThirds)
    static let widgetThreeQuartersHeight: CGFloat = AppWidgetGridMetrics.homeHeight(.threeQuarters)
    static let widgetFullHeight: CGFloat = AppWidgetGridMetrics.homeHeight(.full)
    static let widgetCompactHeight: CGFloat = widgetHalfHeight
    static let widgetRegularHeight: CGFloat = widgetHalfHeight
    static let widgetListHeight: CGFloat = widgetThreeQuartersHeight
    static let widgetTallHeight: CGFloat = widgetThreeQuartersHeight
    static let statCardHeight: CGFloat = widgetQuarterHeight * 0.75
    static let musicRecommendationContentHeight: CGFloat = widgetThreeQuartersHeight
    static let dashboardPanelHeight: CGFloat = widgetHalfHeight
    static let statCardMinWidth: CGFloat = AppWidgetGridMetrics.fractionalMinWidth(.quarter)
    static let dashboardPanelMinWidth: CGFloat = AppWidgetGridMetrics.fractionalMinWidth(.third)
    static let musicListMinWidth: CGFloat = AppWidgetGridMetrics.fractionalMinWidth(.twoThirds)
    static let playlistRailMinWidth: CGFloat = AppWidgetGridMetrics.fractionalMinWidth(.third)

    static func color(_ hex: String) -> Color {
        Color(nsColor: NSColor(appThemeHex: hex) ?? .labelColor)
    }

    static func gradient(_ colors: [Color], start: UnitPoint = .topLeading, end: UnitPoint = .bottomTrailing) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: start, endPoint: end)
    }

    static func accentPair(seed: Int) -> (Color, Color) {
        let pairs: [(Color, Color)] = [
            (blue, cyan),
            (cyan, mint),
            (orange, color("FFB86B")),
            (pink, color("FF8FB0")),
            (indigo, blue),
            (pink, violet),
            (mint, cyan)
        ]
        return pairs[abs(seed) % pairs.count]
    }
}

struct HomeVividPageBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HomeVividTokens.pageBackground
            RadialGradient(
                colors: [HomeVividTokens.cyan.opacity(0.07), .clear],
                center: UnitPoint(x: 0.06, y: -0.06),
                startRadius: 0,
                endRadius: 620
            )
            RadialGradient(
                colors: [HomeVividTokens.pink.opacity(0.055), .clear],
                center: UnitPoint(x: 0.99, y: 0.06),
                startRadius: 0,
                endRadius: 580
            )
            RadialGradient(
                colors: [HomeVividTokens.blue.opacity(0.035), .clear],
                center: UnitPoint(x: 0.52, y: 0.78),
                startRadius: 0,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

struct HomeVividHeroCarousel: View {
    let items: [MediaItem]
    let cachedBanner: (MediaItem) -> String?
    let subtitle: (MediaItem) -> String?
    let onPlay: (MediaItem) -> Void
    let onToggleWatchlist: (MediaItem) -> Void
    let onSelect: (MediaItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    @State private var hovering = false
    @State private var lastManualStepAt: Date = .distantPast

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let slides = Array(items.prefix(7))
        let count = max(slides.count, 1)
        let current = ((index % count) + count) % count

        ZStack {
            ForEach(Array(slides.enumerated()), id: \.element.id) { offset, item in
                if offset == current {
                    HomeVividHero(
                        item: item,
                        bannerPath: cachedBanner(item),
                        colorPath: item.posterPath,
                        subtitle: subtitle(item),
                        onPlay: { onPlay(item) },
                        onToggleWatchlist: { onToggleWatchlist(item) },
                        onSelect: { onSelect(item) }
                    )
                    .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: current)
        .overlay(alignment: .bottomTrailing) {
            if slides.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<slides.count, id: \.self) { dot in
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(dot == current ? 0.92 : 0.42))
                            .frame(width: dot == current ? 19 : 6, height: 6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                                    index = dot
                                }
                            }
                    }
                }
                .padding(.trailing, 18)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .trailing) {
            HomeVividHorizontalScrollBridge { delta in
                step(delta, count: slides.count)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(slides.count > 1)
        }
        .overlay {
            HomeVividSidePagerControls(
                hovering: $hovering,
                canGoPrevious: current > 0,
                canGoNext: current < slides.count - 1,
                onPrevious: { stepClamped(-1, current: current, count: slides.count) },
                onNext: { stepClamped(1, current: current, count: slides.count) },
                itemCount: slides.count
            )
            .padding(.horizontal, -24)
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    guard slides.count > 1,
                          abs(value.translation.width) > 42,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    step(value.translation.width < 0 ? 1 : -1, count: slides.count)
                }
        )
        .onHover { hovering = $0 }
        .onReceive(timer) { _ in
            guard !reduceMotion, scenePhase == .active, !hovering, slides.count > 1 else { return }
            step(1, count: slides.count)
        }
    }

    private func step(_ delta: Int, count: Int) {
        guard count > 1 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastManualStepAt) > 0.48 else { return }
        lastManualStepAt = now
        let current = ((index % count) + count) % count
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
            index = ((current + delta) % count + count) % count
        }
    }

    private func stepClamped(_ delta: Int, current: Int, count: Int) {
        guard count > 1 else { return }
        let target = min(max(current + delta, 0), count - 1)
        guard target != current else { return }
        lastManualStepAt = Date()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
            index = target
        }
    }
}

private struct HomeVividHorizontalScrollBridge: NSViewRepresentable {
    let onHorizontalStep: (Int) -> Void

    func makeNSView(context: Context) -> ScrollCatcherView {
        let view = ScrollCatcherView()
        view.onHorizontalStep = onHorizontalStep
        return view
    }

    func updateNSView(_ nsView: ScrollCatcherView, context: Context) {
        nsView.onHorizontalStep = onHorizontalStep
    }

    final class ScrollCatcherView: NSView {
        var onHorizontalStep: ((Int) -> Void)?
        private var accumulatedX: CGFloat = 0
        private var lastStepAt: TimeInterval = 0
        private var scrollMonitor: Any?

        // 对鼠标/悬停命中测试完全透明：否则这个覆盖在 banner 之上的 NSView 会被
        // SwiftUI 命中测试判为最上层，吞掉光标位置，使下方 banner 的 onHover/onTap
        // 只在未被遮挡的下方窄条才生效。横向滚动改由窗口级监听器按几何范围捕获。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self else { return event }
                    return self.handleScroll(event) ? nil : event
                }
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
            }
            scrollMonitor = nil
        }

        // 返回 true 表示已消费（拦截横向滚动，避免页面跟着滚）。
        private func handleScroll(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return false }
            guard event.momentumPhase == [] else {
                accumulatedX = 0
                return false
            }
            let horizontal = event.scrollingDeltaX
            guard abs(horizontal) > abs(event.scrollingDeltaY), abs(horizontal) > 0 else { return false }
            accumulatedX += horizontal
            guard abs(accumulatedX) > 42 else { return true }
            let now = event.timestamp
            guard now - lastStepAt > 0.48 else {
                accumulatedX = 0
                return true
            }
            lastStepAt = now
            onHorizontalStep?(accumulatedX < 0 ? 1 : -1)
            accumulatedX = 0
            return true
        }
    }
}

private struct HomeVividSidePagerControls: View {
    /// 与外层内容共享同一个悬停状态：外层容器只覆盖组件自身的原始宽度，
    /// 而箭头靠负 padding 视觉上"探出"到组件与页面边距之间的空白——那块区域
    /// 在 SwiftUI 的命中测试意义上落在外层 `.onHover` 的框之外，鼠标一移过去
    /// 外层 hover 就会先翻 false，箭头随即淡出、点不到。这里箭头自己也订阅
    /// `onHover` 写回同一个 binding，鼠标进入箭头自身范围时保持可见。
    @Binding var hovering: Bool
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let itemCount: Int

    private var visible: Bool { hovering && itemCount > 1 }

    var body: some View {
        HStack {
            sideButton(direction: .previous, enabled: canGoPrevious, action: onPrevious)
            Spacer(minLength: 0)
            sideButton(direction: .next, enabled: canGoNext, action: onNext)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: visible ? 0.16 : 0.28), value: visible)
        .allowsHitTesting(visible)
        .onHover { hovering = $0 }
    }

    private func sideButton(direction: HomeVividSidePagerLine.Direction, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HomeVividSidePagerLine(direction: direction)
                .stroke(
                    enabled ? HomeVividTokens.textPrimary.opacity(0.68) : HomeVividTokens.textTertiary.opacity(0.34),
                    style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round)
                )
                // 缩短箭头视觉长度（原 72pt 太长）；收紧命中区，让箭头能落在
                // 组件与页面边距正中间，而不是紧贴组件或探到边距外沿。
                .frame(width: 14, height: 40)
                .padding(.horizontal, 5)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct HomeVividSidePagerLine: Shape {
    enum Direction {
        case previous
        case next
    }

    let direction: Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetX = rect.width * 0.28
        let top = CGPoint(x: direction == .previous ? rect.maxX - insetX : rect.minX + insetX, y: rect.minY)
        let middle = CGPoint(x: direction == .previous ? rect.minX + insetX : rect.maxX - insetX, y: rect.midY)
        let bottom = CGPoint(x: direction == .previous ? rect.maxX - insetX : rect.minX + insetX, y: rect.maxY)
        path.move(to: top)
        path.addLine(to: middle)
        path.addLine(to: bottom)
        return path
    }
}

struct HomeVividHeader: View {
    let greeting: String
    @Binding var searchText: String
    let isScanning: Bool
    let scanQueueCount: Int
    let onSubmitSearch: () -> Void
    let onScan: () -> Void
    let scanDisabled: Bool
    var showsScanButton: Bool = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                titleBlock
                Spacer(minLength: 12)
                actions
            }

            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                actions
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(greeting)，欢迎回来")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HomeVividTokens.textSecondary)
            HStack(spacing: 0) {
                Text("今天，")
                Text("为你精选")
                    .foregroundStyle(
                        HomeVividTokens.gradient(
                            [HomeVividTokens.cyan, HomeVividTokens.blue, HomeVividTokens.orange, HomeVividTokens.pink],
                            start: .leading,
                            end: .trailing
                        )
                    )
                Text("了一份片单")
            }
            .font(.system(size: 29, weight: .black))
            .foregroundStyle(HomeVividTokens.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            HomeVividSearchControl(text: $searchText, onSubmit: onSubmitSearch)
                .frame(width: 230)
            if showsScanButton {
                Button(action: onScan) {
                    HStack(spacing: 7) {
                        Image(systemName: isScanning ? "list.bullet" : "paperplane.fill")
                            .font(.system(size: 12, weight: .black))
                        Text(isScanning ? "队列 \(max(scanQueueCount, 1))" : "扫描")
                    }
                }
                .buttonStyle(HomeVividPrimaryButtonStyle())
                .disabled(scanDisabled)
            }
        }
    }
}

private struct HomeVividSearchControl: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HomeVividLineIcon(name: "search", size: 16)
                .foregroundStyle(HomeVividTokens.textTertiary)
            TextField("搜索全部媒体", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(HomeVividTokens.textPrimary)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 15)
        .frame(height: 41)
        .background(AppColors.refCardBg, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(HomeVividTokens.controlBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)
    }
}

private struct HomeVividPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 41)
            .background(
                HomeVividTokens.gradient(
                    [HomeVividTokens.blue, HomeVividTokens.cyan],
                    start: .leading,
                    end: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(configuration.isPressed ? 0.34 : 0.20), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct HomeVividHero: View {
    let item: MediaItem
    let bannerPath: String?
    let colorPath: String?
    let subtitle: String?
    let onPlay: () -> Void
    let onToggleWatchlist: () -> Void
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette: MediaArtworkPalette = .fallback
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            heroBackground

            titleScrim

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text("★")
                    Text("今日精选")
                }
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(HomeVividTokens.color("FFD0DD"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.white.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .padding(.bottom, 8)

                Text(item.title)
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .shadow(color: .black.opacity(0.40), radius: 20, y: 4)

                HStack(spacing: 10) {
                    if let rating = item.rating, rating > 0 {
                        Text("★ \(String(format: "%.1f", rating))")
                            .foregroundStyle(HomeVividTokens.color("FFCE4A"))
                    }
                    metaDot
                    Text(item.type == .episode ? item.episodeLabel : item.type.displayName)
                    if item.year != nil {
                        metaDot
                        Text(item.displayYear)
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.top, 8)
                .padding(.bottom, 4)

                Text(subtitle?.isEmpty == false ? subtitle! : "据你近期常看的题材优先推荐，今天续看正合适。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: 460, alignment: .leading)
                    .lineLimit(1)
                    .padding(.bottom, 12)

                HStack(spacing: 12) {
                    Button(action: onPlay) {
                        HStack(spacing: 9) {
                            HomeVividPlayTriangle()
                                .fill(HomeVividTokens.color("1A0A2E"))
                                .frame(width: 13, height: 16)
                            Text("立即播放")
                        }
                    }
                    .buttonStyle(HomeHeroPrimaryButtonStyle())

                    Button(action: onToggleWatchlist) {
                        Text(item.watchlist ? "✓ 已想看" : "＋ 加入想看")
                    }
                    .buttonStyle(HomeHeroSecondaryButtonStyle())
                }
            }
            .padding(.leading, 30)
            .padding(.trailing, 30)
        }
        .frame(maxWidth: .infinity)
        .frame(height: HomeVividTokens.widgetRegularHeight)
        .clipShape(RoundedRectangle(cornerRadius: HomeVividTokens.largeCardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: HomeVividTokens.largeCardRadius, style: .continuous))
        .onTapGesture(perform: onSelect)
        .scaleEffect(hovering && !reduceMotion ? 1.008 : 1, anchor: .center)
        .shadow(color: Color.black.opacity(hovering ? 0.24 : 0.18), radius: hovering ? 32 : 24, y: hovering ? 12 : 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: hovering)
        .onHover { hovering = $0 }
        .task(id: colorPath) {
            palette = await AlbumPaletteCache.palette(for: colorPath)
        }
    }

    private var heroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    palette.backdropBaseColor(for: .light),
                    palette.glowPrimary.color.opacity(0.82),
                    palette.glowAccent.color.opacity(0.70)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let bannerPath {
                PosterImage(
                    path: bannerPath,
                    title: item.title,
                    mediaType: item.type,
                    cacheTargetSize: CGSize(width: 1200, height: 520),
                    contentMode: .fill
                )
                .scaleEffect(1.025)
                .opacity(0.99)
            }
            RadialGradient(
                colors: [palette.glowAccent.color.opacity(0.22), .clear],
                center: UnitPoint(x: 0.84, y: 0.16),
                startRadius: 0,
                endRadius: 360
            )
            RadialGradient(
                colors: [palette.glowPrimary.color.opacity(0.18), .clear],
                center: UnitPoint(x: 0.58, y: 0.94),
                startRadius: 0,
                endRadius: 420
            )
        }
    }

    private var metaDot: some View {
        Text("·").opacity(0.5)
    }

    private var titleScrim: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.76),
                    Color.black.opacity(0.48),
                    Color.black.opacity(0.16),
                    Color.black.opacity(0.04),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
    }
}

private struct HomeHeroPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .black))
            .foregroundStyle(HomeVividTokens.color("1A0A2E"))
            .padding(.horizontal, 24)
            .frame(height: 44)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.34), radius: 30, x: 0, y: 14)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct HomeHeroSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
    }
}

struct HomeVividStatsGrid: View {
    let tiles: [HomeVividStatTile]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(tiles.prefix(4).enumerated()), id: \.element.id) { index, tile in
                let accent = HomeVividTokens.accentPair(seed: index)
                HomeVividStatCard(tile: tile, pair: (tile.tint, accent.1))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct HomeVividStatTile: Identifiable {
    let id: String
    let title: String
    let value: String
    let iconName: String
    let tint: Color
}

private struct HomeVividStatCard: View {
    let tile: HomeVividStatTile
    let pair: (Color, Color)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(HomeVividTokens.gradient([pair.0, pair.1]))
                .frame(width: 42, height: 42)
                .overlay {
                    HomeVividLineIcon(name: tile.iconName, size: 21)
                        .foregroundStyle(.white)
                }
                .shadow(color: pair.0.opacity(0.42), radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(tile.value)
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(HomeVividTokens.gradient([pair.0, pair.1], start: .leading, end: .trailing))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(tile.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(HomeVividTokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: HomeVividTokens.statCardHeight, alignment: .leading)
        .background(AppColors.refCardBg, in: RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous)
                .strokeBorder(HomeVividTokens.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(hovering ? HomeVividTokens.hoverShadowOpacity : 0), radius: hovering ? HomeVividTokens.hoverShadowRadius : 0, y: hovering ? HomeVividTokens.hoverShadowY : 0)
        .offset(y: hovering && !reduceMotion ? -4 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct HomeVividSectionHeader<Trailing: View>: View {
    let title: String
    let barColors: [Color]
    var badgeText: String?
    var actionTitle: String?
    var actionTint: Color = HomeVividTokens.blue
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(
        title: String,
        barColors: [Color],
        badgeText: String? = nil,
        actionTitle: String? = nil,
        actionTint: Color = HomeVividTokens.blue,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.barColors = barColors
        self.badgeText = badgeText
        self.actionTitle = actionTitle
        self.actionTint = actionTint
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(HomeVividTokens.gradient(barColors, start: .top, end: .bottom))
                .frame(width: 5, height: 20)
            Text(title)
                .font(.system(size: HomeVividTokens.sectionTitleSize, weight: .black))
                .foregroundStyle(HomeVividTokens.textPrimary)
            if let badgeText {
                Text(badgeText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(HomeVividTokens.success)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(HomeVividTokens.mint.opacity(0.14), in: Capsule())
            }
            trailing
            Spacer(minLength: 8)
            if let actionTitle {
                Button(action: { action?() }) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HomeVividTokens.textSecondary)
                }
                .buttonStyle(.plain)
                .onHover { _ in }
            }
        }
    }
}

struct HomeVividPosterRow: View {
    let title: String
    let barColors: [Color]
    let actionTitle: String
    let actionTint: Color
    let items: [MediaItem]
    var variant: HomeVividPosterVariant = .poster
    var emptyMessage: String = "接入媒体源并完成扫描后，这里会出现内容。"
    let metadata: (MediaItem) -> String
    let onSelect: (MediaItem) -> Void
    var action: (() -> Void)? = nil
    var restoreAnchorID: String? = nil
    var onDidRestoreAnchor: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var autoScrollIndex = 0
    @State private var hovering = false
    @State private var dragging = false

    private var displayItems: [MediaItem] { Array(items.prefix(12)) }
    private var autoScrollKey: String { displayItems.map(\.id).joined(separator: "|") }
    private var pageStep: Int { variant.isLandscapeLike ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeVividSectionHeader(
                title: title,
                barColors: barColors,
                actionTitle: actionTitle,
                actionTint: actionTint,
                action: action
            )
            if displayItems.isEmpty {
                HomeVividEmptyCard(message: emptyMessage)
            } else {
                // 横向海报条：原生支持双指拖动 + 鼠标长按拖动；空闲时自动轮播，悬停/拖动即暂停。
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: HomeVividTokens.rowGap) {
                            ForEach(displayItems) { item in
                                HomeVividPosterCard(
                                    item: item,
                                    metadata: metadata(item),
                                    variant: variant,
                                    onSelect: { onSelect(item) }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                    }
                    .verticalScrollPassthroughFromNestedHorizontal()
                    .homeVividHorizontalMouseDragScroll { dragging = $0 }
                    .homeVividAllowsOverflowShadow()
                    .onHover { hovering = $0 }
                    .overlay {
                        HomeVividSidePagerControls(
                            hovering: $hovering,
                            canGoPrevious: autoScrollIndex > 0,
                            canGoNext: autoScrollIndex < displayItems.count - 1,
                            onPrevious: { scrollByPage(-1, proxy: proxy) },
                            onNext: { scrollByPage(1, proxy: proxy) },
                            itemCount: displayItems.count
                        )
                        .padding(.horizontal, -24)
                    }
                    .task(id: autoScrollKey) {
                        autoScrollIndex = 0
                        guard displayItems.count > 1, !reduceMotion else { return }
                        while !Task.isCancelled {
                            do { try await Task.sleep(nanoseconds: 4_800_000_000) } catch { return }
                            guard !Task.isCancelled, !hovering, !dragging, scenePhase == .active, displayItems.count > 1 else { continue }
                            autoScrollIndex = (autoScrollIndex + 1) % displayItems.count
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.55)) {
                                proxy.scrollTo(displayItems[autoScrollIndex].id, anchor: .leading)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { notifyRestoreIfNeeded() }
        .onChange(of: restoreAnchorID) { _ in notifyRestoreIfNeeded() }
    }

    private func notifyRestoreIfNeeded() {
        guard let restoreAnchorID, items.contains(where: { $0.id == restoreAnchorID }) else { return }
        onDidRestoreAnchor?()
    }

    private func scrollByPage(_ direction: Int, proxy: ScrollViewProxy) {
        guard !displayItems.isEmpty else { return }
        let target = min(max(autoScrollIndex + direction * pageStep, 0), displayItems.count - 1)
        guard target != autoScrollIndex else { return }
        autoScrollIndex = target
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.36)) {
            proxy.scrollTo(displayItems[target].id, anchor: .leading)
        }
    }
}

struct HomeVividPosterCollectionPage: View {
    let title: String
    let subtitle: String
    let barColors: [Color]
    let items: [MediaItem]
    let metadata: (MediaItem) -> String
    let onBack: () -> Void
    let onSelect: (MediaItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: HomeVividTokens.posterWidth), spacing: HomeVividTokens.rowGap, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Capsule()
                            .fill(HomeVividTokens.gradient(barColors))
                            .frame(width: 6, height: 32)
                        Text(title)
                            .font(.system(size: 29, weight: .black))
                            .foregroundStyle(HomeVividTokens.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    Text(subtitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(HomeVividTokens.textSecondary)
                        .padding(.leading, 16)
                }
                Spacer()
                Button(action: onBack) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .black))
                        Text("返回首页")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HomeVividTokens.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(AppColors.refCardBg, in: Capsule())
                    .overlay(Capsule().strokeBorder(HomeVividTokens.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .homeVividHoverLift(cornerRadius: 17)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    HomeVividPosterCard(
                        item: item,
                        metadata: metadata(item),
                        variant: .poster,
                        onSelect: { onSelect(item) }
                    )
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 28)
        }
    }
}

enum HomeVividPosterVariant: Equatable {
    case poster
    case progress
    case landscape

    var size: CGSize {
        switch self {
        case .poster:
            return CGSize(width: HomeVividTokens.posterWidth, height: HomeVividTokens.posterHeight)
        case .progress:
            return CGSize(width: 236, height: 138)
        case .landscape:
            return CGSize(width: 236, height: 138)
        }
    }

    var isLandscapeLike: Bool {
        self == .progress || self == .landscape
    }
}

private struct HomeVividPosterCard: View {
    let item: MediaItem
    let metadata: String
    let variant: HomeVividPosterVariant
    let onSelect: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @State private var hovering = false

    private var active: Bool { hovering && !suppressHoverDuringScroll }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                posterLayer
                LinearGradient(
                    colors: [.clear, .black.opacity(0.12), .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.cardTitle)
                        .font(.system(size: variant.isLandscapeLike ? 15 : 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(metadata)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(1)
                    if variant == .progress, item.playProgress > 0, item.playProgress < 0.98 {
                        progressBar
                    }
                }
                .padding(12)
            }
            .frame(width: variant.size.width, height: variant.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let rating = item.rating, rating > 0 {
                    Text("★ \(String(format: "%.1f", rating))")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(HomeVividTokens.color("FFCE4A"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.42), in: Capsule())
                        .padding(9)
                }
            }
        }
        .buttonStyle(.plain)
        .offset(y: active && !reduceMotion ? -5 : 0)
        .shadow(color: Color.black.opacity(active ? HomeVividTokens.hoverShadowOpacity : 0), radius: active ? HomeVividTokens.hoverShadowRadius : 0, y: active ? HomeVividTokens.hoverShadowY : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: active)
        .onHover { hovering = $0 }
        .onChange(of: suppressHoverDuringScroll) { if $0 { hovering = false } }
        .contextMenu {
            VideoItemContextMenuItems(item: item)
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private var posterLayer: some View {
        let artworkPath = variant.isLandscapeLike ? (item.backdropPath ?? item.posterPath) : item.posterPath
        if artworkPath == nil {
            glyphPlaceholder
        } else {
            PosterImage(
                path: artworkPath,
                title: item.title,
                mediaType: item.type,
                cacheTargetSize: CGSize(width: variant.size.width * 2, height: variant.size.height * 2),
                contentMode: .fill
            )
        }
    }

    private var glyphPlaceholder: some View {
        let pair = HomeVividTokens.accentPair(seed: item.id.hashValue)
        return ZStack {
            HomeVividTokens.gradient([pair.0.opacity(0.92), pair.1.opacity(0.76)])
            Text(String(item.title.prefix(1)))
                .font(.system(size: variant.isLandscapeLike ? 72 : 96, weight: .black))
                .foregroundStyle(.white.opacity(0.24))
        }
    }

    private var progressBar: some View {
        Capsule()
            .fill(.white.opacity(0.30))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(.white)
                        .frame(width: max(3, geo.size.width * CGFloat(min(max(item.playProgress, 0), 1))))
                }
            }
            .padding(.top, 2)
    }
}

struct HomeVividSourceGroup: Identifiable {
    let id: String
    let title: String
    let count: Int
    let tint: Color
    let isOnline: Bool
}

struct HomeVividTaskSummary: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let stateTitle: String
    let progress: Double?
    let isActive: Bool
    let tint: Color
}

private struct HomeVividPieSegment: Shape {
    var start: Double
    var end: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle.degrees(start * 360 - 90)
        let endAngle = Angle.degrees(end * 360 - 90)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct HomeVividDashboard: View {
    let sourceGroups: [HomeVividSourceGroup]
    let sourceOnlineCount: Int
    let sourceTotalCount: Int
    let healthScore: Int
    let sourceHealthPercent: Int
    let metadataHealthPercent: Int
    let tasks: [HomeVividTaskSummary]
    let onOpenSources: () -> Void
    let onOpenHealth: () -> Void
    let onOpenTasks: () -> Void

    private var safeSourceTotal: Int { max(sourceTotalCount, 1) }
    private var healthFraction: Double {
        min(max(Double(healthScore) / 100, 0), 1)
    }
    private var sourceSegments: [(start: Double, end: Double, tint: Color)] {
        let total = max(sourceGroups.map(\.count).reduce(0, +), sourceGroups.count)
        var cursor = 0.0
        return sourceGroups.map { group in
            let size = max(Double(group.count), 1) / Double(total)
            let segment = (start: cursor, end: min(cursor + size, 1), tint: group.isOnline ? group.tint : HomeVividTokens.mutedData)
            cursor = segment.end
            return segment
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeVividSectionHeader(
                title: "运行状态",
                barColors: [HomeVividTokens.mint, HomeVividTokens.cyan],
                badgeText: "实时",
                actionTitle: "进入仪表盘 ›",
                actionTint: HomeVividTokens.blue,
                action: onOpenHealth
            )

            HStack(alignment: .top, spacing: 16) {
                sourcePanel
                    .frame(maxWidth: .infinity)
                healthPanel
                    .frame(maxWidth: .infinity)
                taskPanel
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var sourcePanel: some View {
        Button(action: onOpenSources) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("媒体源")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(HomeVividTokens.textPrimary)
                    Spacer()
                    Text("\(sourceTotalCount) 个")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HomeVividTokens.textTertiary)
                }

                if sourceGroups.isEmpty {
                    Text("还没有媒体源")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HomeVividTokens.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 122, alignment: .center)
                } else {
                    GeometryReader { geo in
                        sourceContent(width: geo.size.width)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .homeVividInteractivePanel(height: HomeVividTokens.dashboardPanelHeight)
        }
        .buttonStyle(.plain)
    }

    private func sourceContent(width: CGFloat) -> some View {
        let compact = width < 340
        let pieSide = min(compact ? 76 : 86, max(68, width * (compact ? 0.24 : 0.26)))
        let gap: CGFloat = compact ? 12 : 16
        return HStack(alignment: .center, spacing: gap) {
            VStack(spacing: 7) {
                sourcePie
                    .frame(width: pieSide, height: pieSide)
                VStack(spacing: 0) {
                    Text("\(sourceOnlineCount)/\(safeSourceTotal)")
                        .font(.system(size: compact ? 20 : 23, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HomeVividTokens.textPrimary)
                    Text("在线")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(HomeVividTokens.textTertiary)
                }
            }
            .frame(width: max(pieSide, 92), alignment: .center)
            .frame(maxHeight: .infinity, alignment: .center)

            sourceList(compact: compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(width: width, alignment: .center)
    }

    @ViewBuilder
    private func sourceList(compact: Bool) -> some View {
        if sourceGroups.count <= 5 {
            LazyVStack(spacing: 8) {
                ForEach(sourceGroups) { group in
                    sourceGroupRow(group, compact: compact)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(sourceGroups) { group in
                        sourceGroupRow(group, compact: compact)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private var sourcePie: some View {
        ZStack {
            Circle()
                .fill(HomeVividTokens.border)
            ForEach(Array(sourceSegments.enumerated()), id: \.offset) { _, segment in
                HomeVividPieSegment(start: segment.start, end: max(segment.start + 0.01, segment.end))
                    .fill(segment.tint)
            }
        }
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.56), lineWidth: 1)
        }
    }

    private func sourceGroupRow(_ group: HomeVividSourceGroup, compact: Bool = false) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(group.tint.opacity(group.isOnline ? 0.15 : 0.08))
                .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
                .overlay {
                    Circle()
                        .fill(group.isOnline ? group.tint : HomeVividTokens.textTertiary.opacity(0.68))
                        .frame(width: compact ? 8 : 9, height: compact ? 8 : 9)
                }
            Text(group.title)
                .font(.system(size: compact ? 12 : 13, weight: .heavy))
                .foregroundStyle(HomeVividTokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 8)
            Text(group.count.formatted())
                .font(.system(size: compact ? 11.5 : 12.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HomeVividTokens.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var healthPanel: some View {
        Button(action: onOpenHealth) {
            VStack(alignment: .leading, spacing: 0) {
                Text("健康度总评分")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(HomeVividTokens.textPrimary)
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .stroke(HomeVividTokens.border, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: healthFraction)
                        .stroke(
                            HomeVividTokens.gradient([HomeVividTokens.cyan, HomeVividTokens.blue, HomeVividTokens.mint]),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text("\(healthScore)")
                            .font(.system(size: 27, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(HomeVividTokens.textPrimary)
                        Text("健康度")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(HomeVividTokens.textTertiary)
                    }
                }
                .frame(width: 96, height: 96)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
                VStack(spacing: 5) {
                    healthLine(title: "媒体源健康度", value: sourceHealthPercent, tint: HomeVividTokens.mint)
                    healthLine(title: "元数据健康度", value: metadataHealthPercent, tint: HomeVividTokens.blue)
                }
            }
            .homeVividInteractivePanel(height: HomeVividTokens.dashboardPanelHeight)
        }
        .buttonStyle(.plain)
    }

    private var taskPanel: some View {
        Button(action: onOpenTasks) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("任务中心")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(HomeVividTokens.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if tasks.contains(where: \.isActive) {
                        Text("\(tasks.filter(\.isActive).count) 进行中")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HomeVividTokens.success)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(HomeVividTokens.mint.opacity(0.15), in: Capsule())
                    }
                }

                if tasks.isEmpty {
                    VStack(spacing: 8) {
                        HomeVividLineIcon(name: "tasks", size: 22)
                            .foregroundStyle(HomeVividTokens.blue.opacity(0.68))
                        Text("无任务")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(HomeVividTokens.textPrimary)
                        Text("扫描和整理任务会显示在这里")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HomeVividTokens.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 128)
                } else {
                    VStack(spacing: 10) {
                        ForEach(tasks.prefix(3)) { task in
                            taskRow(task)
                        }
                    }
                }
            }
            .homeVividInteractivePanel(height: HomeVividTokens.dashboardPanelHeight)
        }
        .buttonStyle(.plain)
    }

    private func healthLine(title: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(HomeVividTokens.gradient([tint, HomeVividTokens.color("7FD0FF")]))
                .frame(width: 9, height: 9)
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(HomeVividTokens.textPrimary)
            Spacer()
            Text("\(value)%")
                .font(.system(size: 12.5, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HomeVividTokens.textSecondary)
        }
    }

    private func taskRow(_ task: HomeVividTaskSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(HomeVividTokens.gradient([task.tint, HomeVividTokens.color("7FD0FF")]))
                    .frame(width: 9, height: 9)
                Text(task.title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(HomeVividTokens.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(task.stateTitle)
                    .font(.system(size: 11.5, weight: .black))
                    .foregroundStyle(task.isActive ? HomeVividTokens.success : HomeVividTokens.textTertiary)
            }
            Text(task.detail)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(HomeVividTokens.textTertiary)
                .lineLimit(1)
            if let progress = task.progress {
                GeometryReader { geo in
                    Capsule()
                        .fill(HomeVividTokens.border)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(HomeVividTokens.gradient([task.tint, HomeVividTokens.color("7FD0FF")], start: .leading, end: .trailing))
                                .frame(width: max(4, geo.size.width * CGFloat(min(max(progress, 0), 1))))
                        }
                }
                .frame(height: 5)
            }
        }
    }
}

private extension View {
    func homeVividPanel(minHeight: CGFloat = 196, height: CGFloat? = nil) -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .background(AppColors.refCardBg, in: RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous)
                    .strokeBorder(HomeVividTokens.border, lineWidth: 1)
            }
    }

    func homeVividInteractivePanel(minHeight: CGFloat = 196, height: CGFloat? = nil) -> some View {
        modifier(HomeVividInteractivePanelModifier(minHeight: minHeight, height: height))
    }
}

private struct HomeVividInteractivePanelModifier: ViewModifier {
    let minHeight: CGFloat
    let height: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .background(AppColors.refCardBg, in: RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous)
                    .strokeBorder(HomeVividTokens.border, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(hovering ? HomeVividTokens.hoverShadowOpacity : 0), radius: hovering ? HomeVividTokens.hoverShadowRadius : 0, y: hovering ? HomeVividTokens.hoverShadowY : 0)
            .offset(y: hovering && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct HomeVividMusicRecommendation: View {
    let tracks: [MediaItem]
    let playlist: HomePlaylistSummary?
    let onTrackSelect: (MediaItem) -> Void
    let onPlaylistSelect: (HomePlaylistSummary) -> Void
    let onOpenMusic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeVividSectionHeader(
                title: "音乐推荐",
                barColors: [HomeVividTokens.pink, HomeVividTokens.violet],
                actionTitle: "进入音乐 ›",
                actionTint: HomeVividTokens.pink,
                action: onOpenMusic
            )
            GeometryReader { geo in
                let gap: CGFloat = 16
                let available = max(0, geo.size.width - gap)
                let railWidth = min(max(210, available / 3), max(210, available * 0.38))
                let listWidth = max(0, available - railWidth)
                HStack(alignment: .top, spacing: gap) {
                    trackList
                        .frame(width: listWidth)
                    playlistStack
                        .frame(width: railWidth)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: HomeVividTokens.musicRecommendationContentHeight)
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今日推荐")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(HomeVividTokens.textPrimary)
                Spacer()
                Text("\(min(tracks.count, 30)) 首")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(HomeVividTokens.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.prefix(30).enumerated()), id: \.element.id) { index, track in
                    Button {
                        onTrackSelect(track)
                    } label: {
                        HomeVividTrackRow(index: index + 1, track: track)
                    }
                    .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity)
            .homeVividDelayedScrollUnlock()
        }
        .padding(8)
        .frame(height: HomeVividTokens.musicRecommendationContentHeight)
        .background(AppColors.refCardBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(HomeVividTokens.border, lineWidth: 1)
        }
        .homeVividHoverLift(cornerRadius: 20)
    }

    private var playlistStack: some View {
        let summaries = playlistSummaries
        return VStack(spacing: 14) {
            ForEach(summaries) { summary in
                Button {
                    onPlaylistSelect(summary)
                } label: {
                    HomeVividPlaylistCard(summary: summary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: HomeVividTokens.musicRecommendationContentHeight, alignment: .top)
    }

    private var playlistSummaries: [HomePlaylistSummary] {
        var result: [HomePlaylistSummary] = []
        if let playlist {
            result.append(playlist)
        }
        // 「标签电台」用与「今日推荐」不同的稳定排序派生（按 id 倒序），保证封面与播放队列
        // 都与上面那张卡片有差异，避免两张卡内容完全一样。
        let usedIDs = Set(playlist?.trackIDs ?? [])
        let radioOrder = tracks.sorted { $0.id > $1.id }
        // 优先选用「今日推荐」未覆盖的曲目，真正错开两张卡片的歌单。
        let radioTracks = (radioOrder.filter { !usedIDs.contains($0.id) } + radioOrder)
        let radioCovers = Array(radioTracks.prefix(6))
        if !radioCovers.isEmpty {
            result.append(
                HomePlaylistSummary(
                    id: "synthetic.home.vivid.radio",
                    title: playlist?.title.contains("推荐") == true ? "标签电台" : "每日歌单",
                    subtitle: "\(max(radioTracks.count, 1)) 首 · 随心律动",
                    posterPaths: radioCovers.compactMap(\.posterPath),
                    trackIDs: Array(radioTracks.prefix(30)).map(\.id)
                )
            )
        }
        if result.isEmpty {
            result.append(HomePlaylistSummary(id: "empty", title: "深夜 · 治愈循环", subtitle: "等待音乐入库", posterPaths: []))
        }
        return Array(result.prefix(2))
    }
}

private struct HomeVividTrackRow: View {
    let index: Int
    let track: MediaItem
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 13) {
            Text("\(index)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(HomeVividTokens.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 26, alignment: .trailing)
            PosterImage(
                path: track.posterPath,
                title: track.title,
                mediaType: .music,
                cacheTargetSize: CGSize(width: 84, height: 84)
            )
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(HomeVividTokens.textPrimary)
                    .lineLimit(1)
                Text(track.artistAlbumLine ?? "未知艺人")
                    .font(.system(size: 11.5))
                    .foregroundStyle(HomeVividTokens.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(durationText(for: track))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(HomeVividTokens.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .modifier(HomeVividRowHoverModifier(cornerRadius: 13))
        .contextMenu {
            Button { appState.play(track) } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button { appState.startRadio(seed: track) } label: {
                Label("开始电台", systemImage: "dot.radiowaves.left.and.right")
            }
            Button { appState.playNextInMusicQueue(track) } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { appState.addToMusicQueue(track) } label: {
                Label("加入播放队列", systemImage: "text.badge.plus")
            }
            Button { appState.toggleFavorite(track) } label: {
                Label(track.favorite ? "取消收藏" : "收藏", systemImage: track.favorite ? "heart.slash" : "heart")
            }
        }
    }

    private func durationText(for item: MediaItem) -> String {
        guard let runtime = item.runtime, runtime > 0 else { return "· ·" }
        let minutes = max(0, runtime / 60)
        let seconds = max(0, runtime % 60)
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct HomeVividPlaylistCard: View {
    let summary: HomePlaylistSummary
    @EnvironmentObject private var appState: AppState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            playlistCover
                .frame(width: 96, height: 94)
            // 去掉右侧播放圆钮（整卡可点即播放，右键菜单亦可），文字垂直居中重新排版、占满余宽。
            VStack(alignment: .leading, spacing: 7) {
                Text(summary.title)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary.subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(hovering ? HomeVividTokens.hoverShadowOpacity : 0), radius: hovering ? HomeVividTokens.hoverShadowRadius : 0, y: hovering ? HomeVividTokens.hoverShadowY : 0)
        .offset(y: hovering ? -4 : 0)
        .animation(.easeOut(duration: 0.24), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button {
                let tracks = summary.trackIDs.compactMap { appState.item(withID: $0) }
                appState.replaceMusicQueueAndPlay(tracks)
            } label: {
                Label("播放歌单", systemImage: "play.fill")
            }
            Button {
                let tracks = summary.trackIDs.compactMap { appState.item(withID: $0) }
                tracks.forEach(appState.addToMusicQueue)
            } label: {
                Label("加入播放队列", systemImage: "text.badge.plus")
            }
        }
    }

    private var cardBackground: some View {
        let swatch = MediaPlaceholderPalette.posterSwatch(for: "\(summary.id)|\(summary.title)", mediaType: .music)
        return ZStack {
            LinearGradient(
                colors: [
                    swatch.base,
                    swatch.depth
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [swatch.accent.opacity(0.38), .clear],
                center: UnitPoint(x: 0.82, y: 0.12),
                startRadius: 0,
                endRadius: 220
            )
            RadialGradient(
                colors: [.white.opacity(0.12), .clear],
                center: UnitPoint(x: 0.18, y: 0.18),
                startRadius: 0,
                endRadius: 170
            )
            Text(summary.id.contains("synthetic.recommend") || summary.title.contains("推荐") ? "30" : String(summary.title.prefix(1)))
                .font(.system(size: 108, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 18, y: 28)
        }
    }

    private var playlistCover: some View {
        ZStack {
            let paths = Array(summary.posterPaths.prefix(4))
            if paths.isEmpty {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(HomeVividTokens.gradient([HomeVividTokens.pink, HomeVividTokens.violet, HomeVividTokens.blue]))
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(.white.opacity(0.86))
                    }
                    .rotationEffect(.degrees(-6))
            } else {
                ForEach(Array(paths.enumerated()), id: \.offset) { offset, path in
                    let cardWidth: CGFloat = 64
                    let cardHeight: CGFloat = 78
                    let rotations: [Double] = [-12, -4, 5, 12]
                    let offsets: [CGSize] = [
                        CGSize(width: -18, height: 8),
                        CGSize(width: -5, height: -4),
                        CGSize(width: 11, height: 3),
                        CGSize(width: 24, height: 12)
                    ]
                    PosterImage(
                        path: path,
                        title: summary.title,
                        mediaType: .music,
                        cacheTargetSize: CGSize(width: 128, height: 156),
                        contentMode: .fill
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(.white.opacity(0.36), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                    .rotationEffect(.degrees(rotations[min(offset, rotations.count - 1)]))
                    .offset(offsets[min(offset, offsets.count - 1)])
                    .zIndex(Double(offset))
                }
            }
        }
    }
}

private struct HomeVividRowHoverModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(hovering ? hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: hovering)
    }

    private var hoverFill: Color {
        colorScheme == .dark
            ? AppColors.refSearchFill.opacity(0.86)
            : HomeVividTokens.color("F6F9FD")
    }
}

private struct HomeVividHoverLiftModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(hovering ? HomeVividTokens.hoverShadowOpacity : 0), radius: hovering ? HomeVividTokens.hoverShadowRadius : 0, y: hovering ? HomeVividTokens.hoverShadowY : 0)
            .offset(y: hovering && !reduceMotion ? -4 : 0)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: hovering)
            .onHover { hovering = $0 }
    }
}

private extension View {
    func homeVividHoverLift(cornerRadius: CGFloat) -> some View {
        modifier(HomeVividHoverLiftModifier(cornerRadius: cornerRadius))
    }

    func homeVividHorizontalMouseDragScroll(
        onDraggingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        horizontalMouseDragScroll(onDraggingChanged: onDraggingChanged)
    }

    func homeVividDelayedScrollUnlock(delay: UInt64 = 520_000_000) -> some View {
        modifier(HomeVividDelayedScrollUnlockModifier(delay: delay))
    }

    func homeVividAllowsOverflowShadow() -> some View {
        background(HomeVividScrollViewResolver { scrollView in
            guard let scrollView else { return }
            scrollView.wantsLayer = true
            scrollView.layer?.masksToBounds = false
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.layer?.masksToBounds = false
            scrollView.documentView?.wantsLayer = true
            scrollView.documentView?.layer?.masksToBounds = false
        })
    }
}

private struct HomeVividDelayedScrollUnlockModifier: ViewModifier {
    let delay: UInt64
    @State private var unlocked = false
    @State private var unlockTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollDisabled(!unlocked)
            .onHover { hovering in
                unlockTask?.cancel()
                if hovering {
                    unlockTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled else { return }
                        unlocked = true
                    }
                } else {
                    unlocked = false
                }
            }
            .onDisappear {
                unlockTask?.cancel()
                unlocked = false
            }
    }
}

private struct HomeVividScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.enclosingScrollView)
        }
    }
}

struct HomeVividContinueListening: View {
    let tracks: [MediaItem]
    let onTrackSelect: (MediaItem) -> Void
    let onOpenMusic: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var autoScrollIndex = 0
    @State private var hovering = false
    @State private var dragging = false

    private var displayTracks: [MediaItem] { Array(tracks.prefix(8)) }
    private var autoScrollKey: String { displayTracks.map(\.id).joined(separator: "|") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeVividSectionHeader(
                title: "继续听",
                barColors: [HomeVividTokens.cyan, HomeVividTokens.blue],
                actionTitle: "查看全部 ›",
                actionTint: HomeVividTokens.blue,
                action: onOpenMusic
            )
            // 空闲时自动轮播，悬停/拖动暂停；双指 + 鼠标长按拖动均可。
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(displayTracks) { track in
                            Button { onTrackSelect(track) } label: {
                                HomeVividAlbumCard(track: track)
                            }
                            .buttonStyle(.plain)
                            .id(track.id)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .verticalScrollPassthroughFromNestedHorizontal()
                .homeVividHorizontalMouseDragScroll { dragging = $0 }
                .onHover { hovering = $0 }
                .overlay {
                    HomeVividSidePagerControls(
                        hovering: $hovering,
                        canGoPrevious: autoScrollIndex > 0,
                        canGoNext: autoScrollIndex < displayTracks.count - 1,
                        onPrevious: { scrollByPage(-1, proxy: proxy) },
                        onNext: { scrollByPage(1, proxy: proxy) },
                        itemCount: displayTracks.count
                    )
                    .padding(.horizontal, -24)
                }
                .task(id: autoScrollKey) {
                    autoScrollIndex = 0
                    guard displayTracks.count > 1, !reduceMotion else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 4_800_000_000) } catch { return }
                        guard !Task.isCancelled, !hovering, !dragging, scenePhase == .active, displayTracks.count > 1 else { continue }
                        autoScrollIndex = (autoScrollIndex + 1) % displayTracks.count
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.55)) {
                            proxy.scrollTo(displayTracks[autoScrollIndex].id, anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    private func scrollByPage(_ direction: Int, proxy: ScrollViewProxy) {
        guard !displayTracks.isEmpty else { return }
        let target = min(max(autoScrollIndex + direction * 3, 0), displayTracks.count - 1)
        guard target != autoScrollIndex else { return }
        autoScrollIndex = target
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.36)) {
            proxy.scrollTo(displayTracks[target].id, anchor: .leading)
        }
    }
}

private struct HomeVividAlbumCard: View {
    let track: MediaItem
    @EnvironmentObject private var appState: AppState
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                PosterImage(
                    path: track.posterPath,
                    title: track.title,
                    mediaType: .music,
                    cacheTargetSize: CGSize(width: 328, height: 328),
                    contentMode: .fill
                )
                .frame(width: HomeVividTokens.albumSide, height: HomeVividTokens.albumSide)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if track.playProgress > 0, track.playProgress < 0.98 {
                    Capsule()
                        .fill(.white.opacity(0.30))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(.white)
                                    .frame(width: max(3, geo.size.width * CGFloat(track.playProgress)))
                            }
                        }
                        .padding(12)
                }
            }
            Text(track.title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(HomeVividTokens.textPrimary)
                .lineLimit(1)
            Text(track.artistAlbumLine ?? "未知艺人")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(HomeVividTokens.textTertiary)
                .lineLimit(1)
        }
        .frame(width: HomeVividTokens.albumSide, alignment: .leading)
        .offset(y: hovering ? -5 : 0)
        .animation(.easeOut(duration: 0.24), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button { appState.play(track) } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button { appState.startRadio(seed: track) } label: {
                Label("开始电台", systemImage: "dot.radiowaves.left.and.right")
            }
            Button { appState.playNextInMusicQueue(track) } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { appState.addToMusicQueue(track) } label: {
                Label("加入播放队列", systemImage: "text.badge.plus")
            }
            Button { appState.toggleFavorite(track) } label: {
                Label(track.favorite ? "取消收藏" : "收藏", systemImage: track.favorite ? "heart.slash" : "heart")
            }
        }
    }
}

struct HomeVividPhotoWall: View {
    let items: [MediaItem]
    var themeTitle: String = "照片墙"
    var badgeText: String? = nil
    let onOpenAlbum: () -> Void
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeVividSectionHeader(
                title: themeTitle,
                barColors: [HomeVividTokens.orange, HomeVividTokens.pink],
                badgeText: badgeText ?? "本组 \(items.count) 张",
                actionTitle: "进入相册 ›",
                actionTint: HomeVividTokens.pink,
                action: onOpenAlbum
            )
            GeometryReader { geo in
                collage(for: geo.size)
            }
            .frame(height: photoWallHeight)
        }
    }

    private var photoWallHeight: CGFloat {
        items.count <= 4 ? HomeVividTokens.widgetCompactHeight : HomeVividTokens.widgetTallHeight
    }

    @ViewBuilder
    private func collage(for size: CGSize) -> some View {
        let spacing: CGFloat = 12
        if size.width < 680 {
            let tileWidth = (size.width - spacing) / 2
            let visible = arrangedItems(for: Array(repeating: tileWidth / 118, count: min(items.count, 12)))
            let columns = [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    photoButton(item: item, index: index, width: tileWidth, height: 118)
                }
            }
        } else {
            let tallWidth = min(196, max(156, size.width * 0.17))
            let focusWidth = min(252, max(208, size.width * 0.22))
            let midWidth = max(128, (size.width - tallWidth - focusWidth - spacing * 4) / 3)
            let bottomWidth = max(120, (size.width - spacing * 3) / 4)
            let hasBottomRow = items.count > 8
            let topRowHeight = hasBottomRow ? max(220, (size.height - spacing) * 0.72) : size.height
            let bottomRowHeight = hasBottomRow ? max(86, size.height - topRowHeight - spacing) : 0
            let stackItemHeight = max(96, (topRowHeight - spacing) / 2)
            let visible = arrangedItems(for: [
                tallWidth / topRowHeight,
                midWidth / stackItemHeight,
                midWidth / stackItemHeight,
                midWidth / stackItemHeight,
                midWidth / stackItemHeight,
                focusWidth / topRowHeight,
                midWidth / stackItemHeight,
                midWidth / stackItemHeight,
                bottomRowHeight > 0 ? bottomWidth / bottomRowHeight : 1,
                bottomRowHeight > 0 ? bottomWidth / bottomRowHeight : 1,
                bottomRowHeight > 0 ? bottomWidth / bottomRowHeight : 1,
                bottomRowHeight > 0 ? bottomWidth / bottomRowHeight : 1
            ])
            VStack(spacing: spacing) {
                HStack(alignment: .top, spacing: spacing) {
                    if visible.indices.contains(0) {
                        photoButton(item: visible[0], index: 0, width: tallWidth, height: topRowHeight)
                    }
                    photoStack(items: visible, indices: [1, 2], width: midWidth, height: stackItemHeight)
                    photoStack(items: visible, indices: [3, 4], width: midWidth, height: stackItemHeight)
                    if visible.indices.contains(5) {
                        photoButton(item: visible[5], index: 5, width: focusWidth, height: topRowHeight)
                    }
                    photoStack(items: visible, indices: [6, 7], width: midWidth, height: stackItemHeight)
                }
                if visible.count > 8 {
                    HStack(spacing: spacing) {
                        ForEach(Array(visible.dropFirst(8).prefix(4).enumerated()), id: \.element.id) { offset, item in
                            photoButton(
                                item: item,
                                index: offset + 8,
                                width: bottomWidth,
                                height: bottomRowHeight
                            )
                        }
                    }
                }
            }
            .frame(height: size.height, alignment: .top)
        }
    }

    private func arrangedItems(for targetRatios: [CGFloat]) -> [MediaItem] {
        var remaining = Array(items.prefix(max(targetRatios.count * 2, targetRatios.count)))
        var arranged: [MediaItem] = []
        for targetRatio in targetRatios {
            guard !remaining.isEmpty else { break }
            let bestIndex = remaining.indices.min { lhs, rhs in
                let left = aspectDistance(itemAspectRatio(remaining[lhs]), targetRatio: targetRatio)
                let right = aspectDistance(itemAspectRatio(remaining[rhs]), targetRatio: targetRatio)
                if abs(left - right) > 0.0001 { return left < right }
                return lhs < rhs
            } ?? remaining.startIndex
            arranged.append(remaining.remove(at: bestIndex))
        }
        return arranged
    }

    private func itemAspectRatio(_ item: MediaItem) -> CGFloat {
        if let cached = ArtworkImageCache.cachedAspectRatio(path: item.posterPath) {
            return cached
        }
        if let ratio = resolutionAspectRatio(item.resolution) {
            return ratio
        }
        return 1
    }

    private func resolutionAspectRatio(_ resolution: String?) -> CGFloat? {
        guard let resolution else { return nil }
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else { return nil }
        return CGFloat(min(max(width / height, 0.35), 3.5))
    }

    private func aspectDistance(_ ratio: CGFloat, targetRatio: CGFloat) -> CGFloat {
        abs(log(max(ratio, 0.01) / max(targetRatio, 0.01)))
    }

    private func photoStack(items: [MediaItem], indices: [Int], width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 12) {
            ForEach(indices, id: \.self) { index in
                if items.indices.contains(index) {
                    photoButton(item: items[index], index: index, width: width, height: height)
                } else {
                    Color.clear.frame(width: width, height: height)
                }
            }
        }
    }

    private func photoButton(item: MediaItem, index: Int, width: CGFloat, height: CGFloat) -> some View {
        Button { onSelect(item) } label: {
            HomeVividPhotoTile(
                item: item,
                index: index,
                width: width,
                height: height,
                onOpen: { onSelect(item) }
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HomeVividPhotoTile: View {
    let item: MediaItem
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let onOpen: () -> Void
    @EnvironmentObject private var appState: AppState
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if item.posterPath == nil {
                let pair = HomeVividTokens.accentPair(seed: index + 2)
                HomeVividTokens.gradient([pair.0, pair.1])
            } else {
                PosterImage(
                    path: item.posterPath,
                    title: item.title,
                    mediaType: item.type,
                    cacheTargetSize: CGSize(width: width * 2, height: height * 2),
                    contentMode: .fill
                )
            }
            RadialGradient(
                colors: [.white.opacity(0.30), .clear],
                center: UnitPoint(x: 0.22, y: 0.12),
                startRadius: 0,
                endRadius: 160
            )
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(hovering ? HomeVividTokens.hoverShadowOpacity : 0), radius: hovering ? HomeVividTokens.hoverShadowRadius : 0, y: hovering ? HomeVividTokens.hoverShadowY : 0)
        .scaleEffect(hovering ? 1.018 : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.24), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(action: onOpen) {
                Label(item.type == .homeVideo ? "查看视频" : "查看图片", systemImage: item.type == .homeVideo ? "play.rectangle" : "photo")
            }
            if item.type == .homeVideo {
                Button { appState.play(item) } label: {
                    Label("播放", systemImage: "play.fill")
                }
            }
            Button { appState.toggleFavorite(item) } label: {
                Label(item.favorite ? "取消喜欢" : "喜欢", systemImage: item.favorite ? "heart.slash" : "heart")
            }
        }
    }
}

private struct HomeVividEmptyCard: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HomeVividTokens.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(AppColors.refCardBg, in: RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HomeVividTokens.cardRadius, style: .continuous)
                    .strokeBorder(HomeVividTokens.border, lineWidth: 1)
            }
    }
}

private struct HomeVividPlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct HomeVividLineIcon: View {
    let name: String
    var size: CGFloat = 17

    var body: some View {
        HomeVividLineIconShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
    }
}

private struct HomeVividLineIconShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offsetX = rect.midX - 12 * scale
        let offsetY = rect.midY - 12 * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
        var path = Path()
        switch name {
        case "search":
            path.addEllipse(in: CGRect(x: 4, y: 4, width: 14, height: 14))
            path.move(to: CGPoint(x: 16.8, y: 16.8))
            path.addLine(to: CGPoint(x: 21, y: 21))
        case "scan":
            path.move(to: CGPoint(x: 21, y: 12))
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 8.5, startAngle: .degrees(0), endAngle: .degrees(310), clockwise: true)
            path.move(to: CGPoint(x: 21, y: 4))
            path.addLine(to: CGPoint(x: 21, y: 9))
            path.addLine(to: CGPoint(x: 16, y: 9))
        case "tasks":
            path.addEllipse(in: CGRect(x: 4, y: 5, width: 4.6, height: 4.6))
            path.move(to: CGPoint(x: 12, y: 7.3))
            path.addLine(to: CGPoint(x: 20, y: 7.3))
            path.addEllipse(in: CGRect(x: 4, y: 14.4, width: 4.6, height: 4.6))
            path.move(to: CGPoint(x: 12, y: 16.7))
            path.addLine(to: CGPoint(x: 20, y: 16.7))
        case "movie":
            path.addRoundedRect(in: CGRect(x: 4, y: 6, width: 16, height: 12), cornerSize: CGSize(width: 3, height: 3))
            path.move(to: CGPoint(x: 7, y: 6))
            path.addLine(to: CGPoint(x: 7, y: 18))
            path.move(to: CGPoint(x: 17, y: 6))
            path.addLine(to: CGPoint(x: 17, y: 18))
            path.move(to: CGPoint(x: 4, y: 10))
            path.addLine(to: CGPoint(x: 20, y: 10))
        case "series":
            path.addRoundedRect(in: CGRect(x: 5, y: 6, width: 14, height: 11), cornerSize: CGSize(width: 3, height: 3))
            path.move(to: CGPoint(x: 9, y: 19))
            path.addLine(to: CGPoint(x: 15, y: 19))
            path.move(to: CGPoint(x: 12, y: 17))
            path.addLine(to: CGPoint(x: 12, y: 19))
            path.move(to: CGPoint(x: 8, y: 9))
            path.addLine(to: CGPoint(x: 16, y: 9))
        case "episodes":
            path.addRoundedRect(in: CGRect(x: 5, y: 5, width: 14, height: 14), cornerSize: CGSize(width: 3, height: 3))
            path.move(to: CGPoint(x: 10, y: 9))
            path.addLine(to: CGPoint(x: 15, y: 12))
            path.addLine(to: CGPoint(x: 10, y: 15))
            path.closeSubpath()
        case "unwatched":
            path.addEllipse(in: CGRect(x: 4, y: 7, width: 16, height: 10))
            path.addEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
            path.move(to: CGPoint(x: 18, y: 5))
            path.addLine(to: CGPoint(x: 6, y: 19))
        case "chevronLeft":
            path.move(to: CGPoint(x: 15, y: 5))
            path.addLine(to: CGPoint(x: 8, y: 12))
            path.addLine(to: CGPoint(x: 15, y: 19))
        case "chevronRight":
            path.move(to: CGPoint(x: 9, y: 5))
            path.addLine(to: CGPoint(x: 16, y: 12))
            path.addLine(to: CGPoint(x: 9, y: 19))
        default:
            path.addRoundedRect(in: CGRect(x: 4, y: 4, width: 16, height: 16), cornerSize: CGSize(width: 4, height: 4))
        }
        return path.applying(transform)
    }
}
