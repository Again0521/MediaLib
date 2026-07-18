import AppKit
import Combine
import MediaLibCore
import SwiftUI

// MARK: - 活力语义色彩固定调色板

/// 活力语义色彩固定品牌调色板。
///
/// 彻底脱离主题派生（主题系统后续将废弃）：这是一套设计好的、鲜明的固定色，浅/深外观各有取值，
/// 保证统计磁贴、区块标识、Hero、强调字等语义色彩发力点**鲜亮不发灰**，不随主题变浅变灰。
/// 注意：Hero / banner 的扩散光仍由当前海报高斯取色派生（见 `AuroraHeroCard`），与此固定盘是两条来源。
enum AuroraPalette {
    private static func dyn(_ light: String, _ dark: String) -> Color {
        let l = NSColor(appThemeHex: light) ?? .systemBlue
        let d = NSColor(appThemeHex: dark) ?? .systemBlue
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        })
    }

    // 品牌主轴
    static let blue = dyn("2F6BFF", "5B8CFF")
    static let indigo = dyn("5B5BF0", "8A8AFF")
    static let purple = dyn("8B3DEF", "B07CFF")
    static let magenta = dyn("E0379A", "FF6FB6")
    static let teal = dyn("0FB5A6", "33D6C6")
    static let orange = dyn("F59016", "FFB04A")
    static let cyan = dyn("0BA5C9", "45C9E6")

    /// 统计磁贴 / 区块标识用的鲜明多色家族（固定，不随主题）。
    static let family: [Color] = [blue, teal, orange, magenta, purple, cyan]

    // MARK: 语义四值（固定，浅/深各取值，鲜明不发灰）
    // 全 app 状态语义（成功 / 警告 / 错误 / 信息）唯一来源，供徽章 / 状态点 / 提示统一取用。
    // 与 AppColors.success/warning/error（主题派生，后续废弃）分离——语义色不应随浅灰主题变灰。
    static let semanticGood = dyn("1F9D57", "45D67F")
    static let semanticWarning = dyn("D98A00", "FFB84D")
    static let semanticDanger = dyn("D64545", "FF6B6B")
    static let semanticInfo = blue

    /// Hero 影院级深面与其上的前景色。
    static let heroSurface = dyn("1B1733", "0E0B1A")
    static let heroOn = Color.white

    /// Hero / 强调用品牌渐变（蓝 → 紫 → 品红）。
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [blue, purple, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 强调字渐变：浅色下用更深的停靠点保证可读性，深色下提亮。
    static var textGradient: LinearGradient {
        LinearGradient(
            colors: [
                dyn("1E4FD6", "6E9BFF"),
                dyn("7322C8", "BC8CFF"),
                dyn("C01F7E", "FF7DBD")
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    /// 页面底极薄氛围柔斑（低透明度，按需启用）。
    static var softWash: [Color] {
        [blue.opacity(0.12), purple.opacity(0.10), magenta.opacity(0.10)]
    }

    /// 区块标题竖条渐变：由区块语义色派生（不写死），上→下做轻微色相旋转 + 提亮，
    /// 呼应设计稿 `linear-gradient(#22d3a8,#36BFFA)` / `linear-gradient(#FF9F45,#FF5C8A)` 的双色竖条。
    static func accentBarGradient(_ base: Color) -> LinearGradient {
        let ns = (NSColor(base).usingColorSpace(.sRGB)) ?? NSColor.systemBlue
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // 灰度兜底：取色失败（s≈0）时退回纯色双停靠点，避免旋转出脏色。
        guard s > 0.05 else {
            return LinearGradient(colors: [base, base.opacity(0.86)], startPoint: .top, endPoint: .bottom)
        }
        let h2 = (h + 0.055).truncatingRemainder(dividingBy: 1)
        let top = Color(nsColor: NSColor(hue: h, saturation: min(s * 1.02, 1), brightness: b, alpha: 1))
        let bottom = Color(nsColor: NSColor(hue: h2, saturation: min(s * 0.92, 1), brightness: min(b * 1.12, 1), alpha: 1))
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 逐个精绘语义色彩图标

/// 首页 / 总览专用的参考图风格语义图标。
/// 每个 `systemName` 映射到单独手绘 glyph；统一的是圆角色块、柔和渐变和阴影语言。
struct VividSemanticIcon: View {
    let systemName: String
    var size: CGFloat = 22
    var color: Color? = nil
    var badgeSystemName: String? = nil

    private var tint: Color { color ?? AuroraPalette.blue }
    private var chipSize: CGFloat { size + 18 }
    private var kind: VividIconKind { VividIconKind(systemName: systemName) }

    var body: some View {
        Group {
            switch kind {
            case .film:
                ReferenceFilmIcon(size: chipSize, tint: tint)
            case .series:
                ReferenceSeriesIcon(size: chipSize, tint: tint)
            case .episode:
                ReferenceEpisodeIcon(size: chipSize, tint: tint)
            case .unseen:
                ReferenceEyeIcon(size: chipSize, tint: tint)
            case .favorite:
                ReferenceHeartIcon(size: chipSize, tint: tint)
            case .watched:
                ReferenceCheckIcon(size: chipSize, tint: tint)
            case .watchTime:
                ReferenceWatchTimeIcon(size: chipSize, tint: tint)
            case .dashboard:
                ReferenceDashboardIcon(size: chipSize, tint: tint)
            case .drive:
                ReferenceDriveIcon(size: chipSize, tint: tint)
            case .server:
                ReferenceServerIcon(size: chipSize, tint: tint)
            case .network:
                ReferenceNetworkIcon(size: chipSize, tint: tint)
            case .link:
                ReferenceLinkIcon(size: chipSize, tint: tint)
            case .featured:
                ReferenceFeaturedIcon(size: chipSize, tint: tint)
            case .play:
                ReferencePlayIcon(size: chipSize, tint: tint)
            case .next:
                ReferenceNextIcon(size: chipSize, tint: tint)
            case .music:
                ReferenceMusicIcon(size: chipSize, tint: tint)
            case .headphones:
                ReferenceHeadphonesIcon(size: chipSize, tint: tint)
            case .recent:
                ReferenceRecentIcon(size: chipSize, tint: tint)
            case .photo:
                ReferencePhotoIcon(size: chipSize, tint: tint)
            case .health:
                ReferenceHealthIcon(size: chipSize, tint: tint)
            case .tag:
                ReferenceTagIcon(size: chipSize, tint: tint)
            case .rating:
                ReferenceStarIcon(size: chipSize, tint: tint)
            case .watchlist:
                ReferenceBookmarkIcon(size: chipSize, tint: tint)
            case .download:
                ReferenceDownloadIcon(size: chipSize, tint: tint)
            case .scan:
                ReferenceScanIcon(size: chipSize, tint: tint)
            case .increment:
                ReferenceBoltIcon(size: chipSize, tint: tint)
            case .cleanup:
                ReferenceCleanupIcon(size: chipSize, tint: tint)
            case .marker:
                ReferenceMarkerIcon(size: chipSize, tint: tint)
            case .generic:
                ReferenceGenericIcon(size: chipSize, tint: tint)
            }
        }
        .frame(width: chipSize, height: chipSize)
        .accessibilityHidden(true)
    }
}

private enum VividIconKind {
    case film, series, episode, unseen, favorite, watched, watchTime
    case dashboard, drive, server, network, link, featured, play, next
    case music, headphones, recent, photo, health
    case tag, rating, watchlist, download, scan, increment, cleanup, marker, generic

    init(systemName: String) {
        switch systemName {
        case "film": self = .film
        case "rectangle.stack", "sparkles.rectangle.stack": self = .series
        case "play.square.stack": self = .episode
        case "eye": self = .unseen
        case "heart": self = .favorite
        case "checkmark.circle", "checkmark.seal": self = .watched
        case "clock.badge.checkmark": self = .watchTime
        case "chart.xyaxis.line", "checklist": self = .dashboard
        case "externaldrive", "externaldrive.badge.plus": self = .drive
        case "server.rack": self = .server
        case "network": self = .network
        case "link", "link.badge.plus": self = .link
        case "sparkles.tv": self = .featured
        case "play.circle": self = .play
        case "forward.end.circle": self = .next
        case "music.note", "music.note.list": self = .music
        case "headphones": self = .headphones
        case "clock.badge.plus", "clock.badge.star", "clock.arrow.circlepath": self = .recent
        case "photo.stack", "photo.on.rectangle": self = .photo
        case "stethoscope", "waveform.path.ecg": self = .health
        case "tag": self = .tag
        case "star.circle": self = .rating
        case "bookmark.circle": self = .watchlist
        case "arrow.down.circle": self = .download
        case "arrow.triangle.2.circlepath": self = .scan
        case "bolt.circle": self = .increment
        case "sparkles": self = .cleanup
        case "wand.and.stars": self = .marker
        default: self = .generic
        }
    }
}

private struct ReferenceIconPlate<Content: View>: View {
    let size: CGFloat
    let tint: Color
    var second: Color? = nil
    var disabled = false
    @ViewBuilder var content: Content

    private var end: Color { second ?? tint }
    private var radius: CGFloat { max(12, size * 0.24) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: disabled
                            ? [Color.gray.opacity(0.48), Color.gray.opacity(0.34)]
                            : [tint.opacity(0.92), end.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: radius * 0.82, style: .continuous)
                        .fill(.white.opacity(disabled ? 0.14 : 0.18))
                        .frame(width: size * 0.58, height: size * 0.42)
                        .offset(x: size * 0.08, y: size * 0.07)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(disabled ? 0.24 : 0.34), lineWidth: 0.8)
                )
                .shadow(color: (disabled ? Color.gray : tint).opacity(0.26), radius: size * 0.18, y: size * 0.10)

            content
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
        }
        .frame(width: size, height: size)
    }
}

private struct ReferenceFilmIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.blue) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.7, size * 0.045), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.48, height: size * 0.34)
                HStack(spacing: size * 0.30) {
                    filmHoles
                    filmHoles
                }
                PlayTriangle()
                    .fill(.white)
                    .frame(width: size * 0.13, height: size * 0.16)
                    .offset(x: size * 0.015)
            }
        }
    }

    private var filmHoles: some View {
        VStack(spacing: size * 0.055) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: size * 0.012, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.055, height: size * 0.04)
            }
        }
    }
}

private struct ReferenceSeriesIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.teal) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                    .stroke(.white.opacity(0.68), lineWidth: max(1.3, size * 0.035))
                    .frame(width: size * 0.36, height: size * 0.38)
                    .offset(x: -size * 0.09, y: -size * 0.055)
                RoundedRectangle(cornerRadius: size * 0.065, style: .continuous)
                    .stroke(.white, lineWidth: max(1.7, size * 0.045))
                    .frame(width: size * 0.42, height: size * 0.44)
                    .offset(x: size * 0.05, y: size * 0.04)
                Capsule()
                    .fill(.white)
                    .frame(width: size * 0.18, height: size * 0.045)
                    .offset(x: size * 0.05, y: size * 0.16)
            }
        }
    }
}

private struct ReferenceEpisodeIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.cyan) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                    .stroke(.white, lineWidth: max(1.8, size * 0.046))
                    .frame(width: size * 0.50, height: size * 0.34)
                PlayTriangle()
                    .fill(.white)
                    .frame(width: size * 0.15, height: size * 0.18)
                    .offset(x: size * 0.02)
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.22, height: size * 0.04)
                    .offset(y: size * 0.24)
            }
        }
    }
}

private struct ReferenceEyeIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.purple) {
            ZStack {
                EyeLensShape()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.8, size * 0.046), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.54, height: size * 0.34)
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.15, height: size * 0.15)
            }
        }
    }
}

private struct ReferenceHeartIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.magenta) {
            HeartShape()
                .fill(.white)
                .frame(width: size * 0.42, height: size * 0.38)
                .offset(y: size * 0.02)
        }
    }
}

private struct ReferenceCheckIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.teal) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: max(1.8, size * 0.048))
                    .frame(width: size * 0.46, height: size * 0.46)
                CheckStroke()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(2, size * 0.065), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.26, height: size * 0.20)
            }
        }
    }
}

private struct ReferenceWatchTimeIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.orange) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: max(1.8, size * 0.045))
                    .frame(width: size * 0.44, height: size * 0.44)
                Path { path in
                    path.move(to: CGPoint(x: size * 0.50, y: size * 0.31))
                    path.addLine(to: CGPoint(x: size * 0.50, y: size * 0.50))
                    path.addLine(to: CGPoint(x: size * 0.64, y: size * 0.50))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.8, size * 0.05), lineCap: .round, lineJoin: .round))
                CheckStroke()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.4, size * 0.04), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.16, height: size * 0.12)
                    .offset(x: size * 0.17, y: size * 0.16)
            }
        }
    }
}

private struct ReferenceDashboardIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.cyan) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                    .stroke(.white.opacity(0.92), lineWidth: max(1.6, size * 0.04))
                    .frame(width: size * 0.50, height: size * 0.42)
                HStack(alignment: .bottom, spacing: size * 0.055) {
                    ForEach([0.18, 0.30, 0.23], id: \.self) { height in
                        RoundedRectangle(cornerRadius: size * 0.018, style: .continuous)
                            .fill(.white)
                            .frame(width: size * 0.07, height: size * height)
                    }
                }
                .offset(y: size * 0.055)
            }
        }
    }
}

private struct ReferenceDriveIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.teal) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                    .stroke(.white, lineWidth: max(1.8, size * 0.046))
                    .frame(width: size * 0.48, height: size * 0.32)
                    .offset(y: size * 0.03)
                Capsule()
                    .fill(.white)
                    .frame(width: size * 0.32, height: size * 0.05)
                    .offset(y: -size * 0.04)
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.06, height: size * 0.06)
                    .offset(x: size * 0.15, y: size * 0.11)
            }
        }
    }
}

private struct ReferenceServerIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.orange) {
            VStack(spacing: size * 0.055) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: size * 0.035, style: .continuous)
                        .stroke(.white, lineWidth: max(1.5, size * 0.04))
                        .frame(width: size * 0.44, height: size * 0.105)
                        .overlay(alignment: .leading) {
                            Circle()
                                .fill(.white)
                                .frame(width: size * 0.035, height: size * 0.035)
                                .padding(.leading, size * 0.055)
                        }
                }
            }
        }
    }
}

private struct ReferenceNetworkIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.cyan) {
            ZStack {
                NetworkLinks()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.04), lineCap: .round))
                    .frame(width: size * 0.42, height: size * 0.34)
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(.white)
                        .frame(width: size * 0.10, height: size * 0.10)
                        .offset(nodeOffset(index))
                }
            }
        }
    }

    private func nodeOffset(_ index: Int) -> CGSize {
        switch index {
        case 0: return .zero
        case 1: return CGSize(width: -size * 0.17, height: -size * 0.13)
        case 2: return CGSize(width: size * 0.19, height: -size * 0.10)
        default: return CGSize(width: -size * 0.03, height: size * 0.18)
        }
    }
}

private struct ReferenceLinkIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.blue) {
            ZStack {
                Capsule(style: .continuous)
                    .stroke(.white, lineWidth: max(1.8, size * 0.052))
                    .frame(width: size * 0.30, height: size * 0.15)
                    .rotationEffect(.degrees(-34))
                    .offset(x: -size * 0.09)
                Capsule(style: .continuous)
                    .stroke(.white, lineWidth: max(1.8, size * 0.052))
                    .frame(width: size * 0.30, height: size * 0.15)
                    .rotationEffect(.degrees(-34))
                    .offset(x: size * 0.09)
            }
        }
    }
}

private struct ReferenceFeaturedIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.magenta) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                    .stroke(.white, lineWidth: max(1.7, size * 0.043))
                    .frame(width: size * 0.48, height: size * 0.32)
                SparkleShape()
                    .fill(.white)
                    .frame(width: size * 0.15, height: size * 0.15)
                    .offset(x: size * 0.19, y: -size * 0.17)
                PlayTriangle()
                    .fill(.white)
                    .frame(width: size * 0.13, height: size * 0.16)
                    .offset(x: size * 0.015)
            }
        }
    }
}

private struct ReferencePlayIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.blue) {
            Circle()
                .stroke(.white, lineWidth: max(1.8, size * 0.046))
                .frame(width: size * 0.44, height: size * 0.44)
                .overlay {
                    PlayTriangle()
                        .fill(.white)
                        .frame(width: size * 0.16, height: size * 0.19)
                        .offset(x: size * 0.025)
                }
        }
    }
}

private struct ReferenceNextIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.blue) {
            HStack(spacing: size * 0.035) {
                PlayTriangle().fill(.white).frame(width: size * 0.14, height: size * 0.18)
                PlayTriangle().fill(.white).frame(width: size * 0.14, height: size * 0.18)
                Capsule().fill(.white).frame(width: size * 0.035, height: size * 0.22)
            }
        }
    }
}

private struct ReferenceMusicIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.magenta) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: max(1.7, size * 0.043))
                    .frame(width: size * 0.32, height: size * 0.32)
                    .offset(x: -size * 0.12, y: size * 0.04)
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.08, height: size * 0.08)
                    .offset(x: -size * 0.12, y: size * 0.04)
                VStack(alignment: .leading, spacing: size * 0.055) {
                    Capsule().fill(.white).frame(width: size * 0.25, height: size * 0.042)
                    Capsule().fill(.white.opacity(0.86)).frame(width: size * 0.18, height: size * 0.042)
                }
                .offset(x: size * 0.17, y: size * 0.03)
                MusicStem()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.044), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.17, height: size * 0.28)
                    .offset(x: size * 0.12, y: -size * 0.12)
            }
        }
    }
}

private struct ReferenceHeadphonesIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.purple) {
            ZStack {
                ArcShape(startAngle: .degrees(205), endAngle: .degrees(335))
                    .stroke(.white, style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round))
                    .frame(width: size * 0.48, height: size * 0.48)
                RoundedRectangle(cornerRadius: size * 0.035, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.09, height: size * 0.22)
                    .offset(x: -size * 0.22, y: size * 0.09)
                RoundedRectangle(cornerRadius: size * 0.035, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.09, height: size * 0.22)
                    .offset(x: size * 0.22, y: size * 0.09)
            }
        }
    }
}

private struct ReferenceRecentIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.orange) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: max(1.8, size * 0.046))
                    .frame(width: size * 0.42, height: size * 0.42)
                Path { path in
                    path.move(to: CGPoint(x: size * 0.50, y: size * 0.34))
                    path.addLine(to: CGPoint(x: size * 0.50, y: size * 0.50))
                    path.addLine(to: CGPoint(x: size * 0.62, y: size * 0.50))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.8, size * 0.05), lineCap: .round, lineJoin: .round))
                PlusShape()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.4, size * 0.04), lineCap: .round))
                    .frame(width: size * 0.15, height: size * 0.15)
                    .offset(x: size * 0.18, y: size * 0.16)
            }
        }
    }
}

private struct ReferencePhotoIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.cyan) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: max(1.3, size * 0.035))
                    .frame(width: size * 0.40, height: size * 0.32)
                    .offset(x: -size * 0.055, y: -size * 0.045)
                RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                    .stroke(.white, lineWidth: max(1.8, size * 0.046))
                    .frame(width: size * 0.46, height: size * 0.35)
                    .offset(x: size * 0.05, y: size * 0.04)
                MountainShape()
                    .fill(.white)
                    .frame(width: size * 0.32, height: size * 0.16)
                    .offset(x: size * 0.05, y: size * 0.105)
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.055, height: size * 0.055)
                    .offset(x: size * 0.15, y: -size * 0.05)
            }
        }
    }
}

private struct ReferenceHealthIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.teal) {
            PulseLine()
                .stroke(.white, style: StrokeStyle(lineWidth: max(2, size * 0.06), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.48, height: size * 0.26)
        }
    }
}

private struct ReferenceTagIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.orange) {
            ZStack {
                TagShape()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.8, size * 0.046), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.42, height: size * 0.32)
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.055, height: size * 0.055)
                    .offset(x: -size * 0.105, y: -size * 0.045)
            }
        }
    }
}

private struct ReferenceStarIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.orange) {
            StarShape()
                .fill(.white)
                .frame(width: size * 0.40, height: size * 0.40)
        }
    }
}

private struct ReferenceBookmarkIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.purple) {
            BookmarkShape()
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.9, size * 0.052), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.30, height: size * 0.44)
        }
    }
}

private struct ReferenceDownloadIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.cyan) {
            ZStack {
                ArrowDownShape()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(2, size * 0.06), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.26, height: size * 0.30)
                    .offset(y: -size * 0.025)
                Capsule()
                    .fill(.white)
                    .frame(width: size * 0.34, height: size * 0.05)
                    .offset(y: size * 0.18)
            }
        }
    }
}

private struct ReferenceScanIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.blue) {
            ScanCornersShape()
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.8, size * 0.05), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.42, height: size * 0.42)
        }
    }
}

private struct ReferenceBoltIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.teal) {
            BoltShape()
                .fill(.white)
                .frame(width: size * 0.28, height: size * 0.42)
        }
    }
}

private struct ReferenceCleanupIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.purple) {
            ZStack {
                SparkleShape()
                    .fill(.white)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .offset(x: -size * 0.05, y: -size * 0.03)
                SparkleShape()
                    .fill(.white.opacity(0.86))
                    .frame(width: size * 0.13, height: size * 0.13)
                    .offset(x: size * 0.16, y: size * 0.15)
            }
        }
    }
}

private struct ReferenceMarkerIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.magenta) {
            ZStack {
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.10, height: size * 0.38)
                    .rotationEffect(.degrees(38))
                SparkleShape()
                    .fill(.white)
                    .frame(width: size * 0.13, height: size * 0.13)
                    .offset(x: size * 0.16, y: -size * 0.15)
            }
        }
    }
}

private struct ReferenceGenericIcon: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ReferenceIconPlate(size: size, tint: tint, second: AuroraPalette.blue) {
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .stroke(.white, lineWidth: max(1.8, size * 0.046))
                .frame(width: size * 0.38, height: size * 0.38)
                .overlay {
                    Circle()
                        .fill(.white)
                        .frame(width: size * 0.08, height: size * 0.08)
                }
        }
    }
}

private struct EyeLensShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control1: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY),
            control2: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY),
            control1: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.maxY),
            control2: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.maxY)
        )
        return path
    }
}

private struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + rect.height * 0.26
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: top),
            control1: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY * 0.86),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.58)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.24),
            control1: CGPoint(x: rect.minX, y: rect.minY),
            control2: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: top),
            control1: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.58),
            control2: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY * 0.86)
        )
        path.closeSubpath()
        return path
    }
}

private struct ScanCornersShape: Shape {
    func path(in rect: CGRect) -> Path {
        let l = min(rect.width, rect.height) * 0.28
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return path
    }
}

private struct BoltShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.48, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.38))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.38))
        path.closeSubpath()
        return path
    }
}

private struct VividIconShell<Content: View>: View {
    enum Silhouette { case rounded, circle, diamond, softRect }

    let size: CGFloat
    let tint: Color
    var secondary: Color = AuroraPalette.blue
    var silhouette: Silhouette = .rounded
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            plate

            content
        }
    }

    @ViewBuilder
    private var plate: some View {
        switch silhouette {
        case .rounded:
            plateShape(RoundedRectangle(cornerRadius: max(12, size * 0.32), style: .continuous))
        case .softRect:
            plateShape(RoundedRectangle(cornerRadius: max(10, size * 0.24), style: .continuous))
        case .circle:
            plateShape(Circle())
        case .diamond:
            plateShape(RoundedRectangle(cornerRadius: max(10, size * 0.24), style: .continuous))
                .scaleEffect(0.82)
                .rotationEffect(.degrees(45))
        }
    }

    private func plateShape<S: InsettableShape>(_ shape: S) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.94), secondary.opacity(0.78), tint.opacity(0.48)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(.white.opacity(0.34))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .offset(x: size * 0.11, y: size * 0.10)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(.black.opacity(0.10))
                    .frame(width: size * 0.58, height: size * 0.58)
                    .blur(radius: 3)
                    .offset(x: size * 0.12, y: size * 0.12)
                    .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(.white.opacity(0.34), lineWidth: 0.85))
            .shadow(color: tint.opacity(0.22), radius: 10, y: 5)
    }
}

private struct VividFilmIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.purple, silhouette: .softRect) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.58, height: size * 0.42)
                    .rotationEffect(.degrees(-7))
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
                HStack(spacing: size * 0.20) {
                    filmPerforations
                    filmPerforations
                }
                .rotationEffect(.degrees(-7))
                Circle()
                    .fill(tint.opacity(0.82))
                    .frame(width: size * 0.13, height: size * 0.13)
                Circle()
                    .stroke(.white.opacity(0.72), lineWidth: 1.4)
                    .frame(width: size * 0.30, height: size * 0.30)
                    .offset(x: size * 0.12, y: size * 0.03)
            }
        }
    }
    private var filmPerforations: some View {
        VStack(spacing: size * 0.06) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: size * 0.02)
                    .fill(tint.opacity(0.78))
                    .frame(width: size * 0.08, height: size * 0.045)
            }
        }
    }
}

private struct VividSeriesIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.teal) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: size * 0.10, style: .continuous)
                    .fill(index == 2 ? .white.opacity(0.94) : .white.opacity(0.38))
                    .frame(width: size * 0.46, height: size * 0.56)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: size * 0.03)
                            .fill((index == 2 ? tint : .white).opacity(index == 2 ? 0.85 : 0.34))
                            .frame(width: size * 0.26, height: size * 0.045)
                            .padding(.bottom, size * 0.07)
                    }
                    .rotationEffect(.degrees(Double(index - 1) * 8))
                    .offset(x: CGFloat(index - 1) * size * 0.10, y: CGFloat(1 - index) * size * 0.025)
                    .shadow(color: .black.opacity(index == 2 ? 0.13 : 0.05), radius: 3, y: 2)
            }
        }
    }
}

private struct VividEpisodeIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.cyan) {
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: size * 0.075, style: .continuous)
                        .fill(index == 2 ? .white.opacity(0.94) : .white.opacity(0.28))
                        .frame(width: size * 0.54, height: size * 0.38)
                        .offset(x: CGFloat(index - 1) * size * 0.055, y: CGFloat(1 - index) * size * 0.055)
                }
                PlayTriangle()
                    .fill(tint.opacity(0.90))
                    .frame(width: size * 0.18, height: size * 0.20)
                    .offset(x: size * 0.02)
            }
        }
    }
}

private struct VividEyeIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.cyan, silhouette: .circle) {
            ZStack {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.58, height: size * 0.34)
                Circle()
                    .fill(tint.opacity(0.88))
                    .frame(width: size * 0.25, height: size * 0.25)
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: size * 0.08, height: size * 0.08)
                    .offset(x: -size * 0.035, y: -size * 0.035)
            }
        }
    }
}

private struct VividHeartIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.magenta, silhouette: .circle) {
            ZStack {
                Circle().fill(.white.opacity(0.94)).frame(width: size * 0.24, height: size * 0.24).offset(x: -size * 0.095, y: -size * 0.05)
                Circle().fill(.white.opacity(0.94)).frame(width: size * 0.24, height: size * 0.24).offset(x: size * 0.095, y: -size * 0.05)
                RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                    .fill(.white.opacity(0.94))
                    .frame(width: size * 0.27, height: size * 0.27)
                    .rotationEffect(.degrees(45))
                    .offset(y: size * 0.055)
                Circle().fill(tint.opacity(0.90)).frame(width: size * 0.09, height: size * 0.09).offset(x: size * 0.12, y: -size * 0.09)
            }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }
}

private struct VividCheckIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.teal, silhouette: .circle) {
            ZStack {
                Circle().fill(.white.opacity(0.92)).frame(width: size * 0.52, height: size * 0.52)
                CheckStroke()
                    .stroke(tint, style: StrokeStyle(lineWidth: max(2, size * 0.075), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.30, height: size * 0.22)
            }
        }
    }
}

private struct VividWatchTimeIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.orange, silhouette: .circle) {
            ZStack {
                Circle().fill(.white.opacity(0.92)).frame(width: size * 0.52, height: size * 0.52)
                Circle().stroke(tint.opacity(0.90), lineWidth: size * 0.055).frame(width: size * 0.36, height: size * 0.36)
                Rectangle().fill(tint).frame(width: size * 0.045, height: size * 0.16).offset(y: -size * 0.06)
                Rectangle().fill(tint).frame(width: size * 0.14, height: size * 0.045).offset(x: size * 0.055)
                CheckStroke()
                    .stroke(.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.043), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.18, height: size * 0.13)
                    .padding(size * 0.05)
                    .background(tint, in: Circle())
                    .offset(x: size * 0.18, y: size * 0.17)
            }
        }
    }
}

private struct VividDashboardIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.cyan, silhouette: .softRect) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.58, height: size * 0.48)
                HStack(alignment: .bottom, spacing: size * 0.045) {
                    ForEach([0.34, 0.55, 0.42], id: \.self) { height in
                        RoundedRectangle(cornerRadius: size * 0.018)
                            .fill(tint.opacity(0.84))
                            .frame(width: size * 0.07, height: size * height)
                    }
                }
                .offset(x: -size * 0.13, y: size * 0.05)
                PulseLine()
                    .stroke(AuroraPalette.orange, style: StrokeStyle(lineWidth: max(1.5, size * 0.043), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.30, height: size * 0.22)
                    .offset(x: size * 0.11, y: -size * 0.035)
            }
        }
    }
}

private struct VividDriveIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.teal, silhouette: .softRect) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.54, height: size * 0.38)
                    .offset(y: size * 0.04)
                RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                    .fill(tint.opacity(0.85))
                    .frame(width: size * 0.42, height: size * 0.12)
                    .offset(y: -size * 0.08)
                Circle().fill(AuroraPalette.teal).frame(width: size * 0.075, height: size * 0.075).offset(x: size * 0.16, y: size * 0.07)
                Circle().fill(AuroraPalette.orange).frame(width: size * 0.055, height: size * 0.055).offset(x: size * 0.26, y: -size * 0.18)
            }
        }
    }
}

private struct VividServerIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.indigo, silhouette: .softRect) {
            VStack(spacing: size * 0.055) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                        .fill(.white.opacity(index == 1 ? 0.78 : 0.92))
                        .frame(width: size * 0.55, height: size * 0.13)
                        .overlay(alignment: .leading) {
                            Circle().fill(index == 2 ? AuroraPalette.orange : tint).frame(width: size * 0.045, height: size * 0.045).padding(.leading, size * 0.055)
                        }
                }
            }
        }
    }
}

private struct VividNetworkIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.cyan, silhouette: .circle) {
            ZStack {
                NetworkLinks()
                    .stroke(.white.opacity(0.88), style: StrokeStyle(lineWidth: max(1.5, size * 0.05), lineCap: .round))
                    .frame(width: size * 0.48, height: size * 0.40)
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index == 0 ? .white : tint.opacity(0.95))
                        .frame(width: index == 0 ? size * 0.16 : size * 0.12, height: index == 0 ? size * 0.16 : size * 0.12)
                        .offset(networkNodeOffset(index))
                }
            }
        }
    }
    private func networkNodeOffset(_ index: Int) -> CGSize {
        switch index {
        case 0: return .zero
        case 1: return CGSize(width: -size * 0.20, height: -size * 0.15)
        case 2: return CGSize(width: size * 0.22, height: -size * 0.12)
        default: return CGSize(width: -size * 0.03, height: size * 0.21)
        }
    }
}

private struct VividLinkIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.blue, silhouette: .rounded) {
            ZStack {
                Capsule(style: .continuous)
                    .stroke(.white.opacity(0.92), lineWidth: size * 0.075)
                    .frame(width: size * 0.34, height: size * 0.18)
                    .rotationEffect(.degrees(-32))
                    .offset(x: -size * 0.10)
                Capsule(style: .continuous)
                    .stroke(.white.opacity(0.92), lineWidth: size * 0.075)
                    .frame(width: size * 0.34, height: size * 0.18)
                    .rotationEffect(.degrees(-32))
                    .offset(x: size * 0.10)
                Circle().fill(AuroraPalette.orange).frame(width: size * 0.085, height: size * 0.085).offset(x: size * 0.20, y: -size * 0.16)
            }
        }
    }
}

private struct VividSparkTVIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.magenta, silhouette: .softRect) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.56, height: size * 0.38)
                    .overlay {
                        PlayTriangle().fill(tint).frame(width: size * 0.16, height: size * 0.18).offset(x: size * 0.02)
                    }
                Rectangle().fill(.white.opacity(0.80)).frame(width: size * 0.18, height: size * 0.04).offset(y: size * 0.25)
                SparkleShape().fill(AuroraPalette.orange).frame(width: size * 0.15, height: size * 0.15).offset(x: size * 0.25, y: -size * 0.22)
            }
        }
    }
}

private struct VividPlayIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.cyan, silhouette: .circle) {
            ZStack {
                Circle().fill(.white.opacity(0.92)).frame(width: size * 0.54, height: size * 0.54)
                Circle().stroke(tint.opacity(0.26), lineWidth: size * 0.055).frame(width: size * 0.38, height: size * 0.38)
                PlayTriangle().fill(tint).frame(width: size * 0.20, height: size * 0.23).offset(x: size * 0.02)
            }
        }
    }
}

private struct VividMusicListIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.magenta, silhouette: .rounded) {
            ZStack {
                Circle().fill(.white.opacity(0.92)).frame(width: size * 0.38, height: size * 0.38).offset(x: -size * 0.15)
                Circle().fill(tint.opacity(0.88)).frame(width: size * 0.14, height: size * 0.14).offset(x: -size * 0.15)
                VStack(alignment: .leading, spacing: size * 0.055) {
                    ForEach([0.30, 0.22, 0.27], id: \.self) { width in
                        Capsule().fill(.white.opacity(0.90)).frame(width: size * width, height: size * 0.045)
                    }
                }
                .offset(x: size * 0.17)
                MusicStem()
                    .stroke(.white.opacity(0.96), style: StrokeStyle(lineWidth: max(1.4, size * 0.045), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.20, height: size * 0.32)
                    .offset(x: size * 0.15, y: -size * 0.10)
            }
        }
    }
}

private struct VividHeadphonesIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.purple, silhouette: .circle) {
            ZStack {
                ArcShape(startAngle: .degrees(205), endAngle: .degrees(335))
                    .stroke(.white.opacity(0.94), style: StrokeStyle(lineWidth: max(2, size * 0.075), lineCap: .round))
                    .frame(width: size * 0.52, height: size * 0.52)
                RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.12, height: size * 0.24)
                    .offset(x: -size * 0.25, y: size * 0.10)
                RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.12, height: size * 0.24)
                    .offset(x: size * 0.25, y: size * 0.10)
                PulseLine().stroke(tint.opacity(0.9), lineWidth: size * 0.04).frame(width: size * 0.24, height: size * 0.14).offset(y: size * 0.10)
            }
        }
    }
}

private struct VividRecentIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.orange, silhouette: .circle) {
            ZStack {
                Circle().fill(.white.opacity(0.92)).frame(width: size * 0.50, height: size * 0.50)
                Circle().stroke(tint.opacity(0.88), lineWidth: size * 0.052).frame(width: size * 0.34, height: size * 0.34)
                Rectangle().fill(tint).frame(width: size * 0.04, height: size * 0.13).offset(y: -size * 0.045)
                Rectangle().fill(tint).frame(width: size * 0.12, height: size * 0.04).offset(x: size * 0.05)
                PlusShape().stroke(.white, style: StrokeStyle(lineWidth: max(1.6, size * 0.045), lineCap: .round))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .padding(size * 0.05)
                    .background(AuroraPalette.orange, in: Circle())
                    .offset(x: size * 0.18, y: size * 0.18)
            }
        }
    }
}

private struct VividPhotoStackIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.blue, silhouette: .softRect) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                    .fill(.white.opacity(0.38))
                    .frame(width: size * 0.48, height: size * 0.38)
                    .rotationEffect(.degrees(-9))
                    .offset(x: -size * 0.06, y: -size * 0.04)
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(.white.opacity(0.94))
                    .frame(width: size * 0.54, height: size * 0.42)
                    .overlay(alignment: .bottom) {
                        MountainShape().fill(tint.opacity(0.82)).frame(width: size * 0.42, height: size * 0.19).padding(.bottom, size * 0.055)
                    }
                Circle().fill(AuroraPalette.orange).frame(width: size * 0.10, height: size * 0.10).offset(x: size * 0.13, y: -size * 0.10)
            }
        }
    }
}

private struct VividHealthIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.orange, silhouette: .circle) {
            ZStack {
                PulseLine()
                    .stroke(.white.opacity(0.94), style: StrokeStyle(lineWidth: max(2, size * 0.075), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.48, height: size * 0.26)
                Circle().stroke(.white.opacity(0.86), lineWidth: size * 0.045).frame(width: size * 0.19, height: size * 0.19).offset(x: -size * 0.20, y: size * 0.16)
                Circle().fill(AuroraPalette.magenta).frame(width: size * 0.11, height: size * 0.11).offset(x: size * 0.22, y: -size * 0.18)
            }
        }
    }
}

private struct VividTagIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.orange, silhouette: .diamond) {
            ZStack {
                TagShape().fill(.white.opacity(0.92)).frame(width: size * 0.48, height: size * 0.38).rotationEffect(.degrees(-45))
                Circle().fill(tint).frame(width: size * 0.075, height: size * 0.075).offset(x: -size * 0.08, y: -size * 0.07)
            }
        }
    }
}

private struct VividStarIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.orange, silhouette: .circle) {
            StarShape().fill(.white.opacity(0.94)).frame(width: size * 0.50, height: size * 0.50)
        }
    }
}

private struct VividBookmarkIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.purple, silhouette: .softRect) {
            BookmarkShape().fill(.white.opacity(0.94)).frame(width: size * 0.36, height: size * 0.52)
            SparkleShape().fill(tint.opacity(0.9)).frame(width: size * 0.12, height: size * 0.12).offset(x: size * 0.13, y: -size * 0.12)
        }
    }
}

private struct VividDownloadIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.cyan, silhouette: .circle) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.46, height: size * 0.16)
                    .offset(y: size * 0.18)
                ArrowDownShape()
                    .stroke(tint, style: StrokeStyle(lineWidth: max(2, size * 0.07), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.30, height: size * 0.34)
                    .offset(y: -size * 0.02)
            }
        }
    }
}

private struct VividGenericIcon: View {
    let size: CGFloat
    let tint: Color
    var body: some View {
        VividIconShell(size: size, tint: tint, secondary: AuroraPalette.purple, silhouette: .rounded) {
            SparkleShape().fill(.white.opacity(0.94)).frame(width: size * 0.44, height: size * 0.44)
        }
    }
}

private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX * 0.88, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct PlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct PulseLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.48, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct NetworkLinks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let points = [
            CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12),
            CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18),
            CGPoint(x: rect.midX - rect.width * 0.06, y: rect.maxY)
        ]
        for point in points {
            path.move(to: center)
            path.addLine(to: point)
        }
        return path
    }
}

private struct MusicStem: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX * 0.72, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.72, y: rect.maxY * 0.72))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY * 0.80), control: CGPoint(x: rect.maxX * 0.32, y: rect.maxY * 0.55))
        path.move(to: CGPoint(x: rect.maxX * 0.72, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.10))
        return path
    }
}

private struct ArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.40))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.60))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.60))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.40))
        path.closeSubpath()
        return path
    }
}

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.50, y: rect.maxY * 0.82))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct TagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.76, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.76, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.45
        var path = Path()
        for index in 0..<10 {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat(index) * .pi / 5 - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct BookmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.22))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ArrowDownShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.72))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY * 0.48))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.82))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.48))
        return path
    }
}

/// 兼容旧调用名；首页图标现在统一委托给 `VividSemanticIcon`。
struct AuroraSymbolIcon: View {
    let systemName: String
    var size: CGFloat = 22
    var color: Color? = nil

    var body: some View {
        VividSemanticIcon(systemName: systemName, size: size, color: color)
    }
}

// MARK: - 海报取色复用

/// Hero / banner 的内容氛围色来源。
///
/// 直接复用音乐播放器已有的封面高斯取色管线（`AlbumPaletteCache` / `AlbumColorPalette`），
/// 保证「与海报高斯取色一致」（已内置降饱和、限亮度、滤近黑的清洁化与 LRU 缓存）。
/// 这里只做语义化别名，不复制取色实现，避免与播放器取色产生偏差。
typealias MediaArtworkPalette = AlbumColorPalette

// MARK: - 活力强调字

extension View {
    /// 标题关键词的活力渐变字（固定语义色板，已按浅/深外观调好对比度）。
    /// 仅用于少量强调词，不要整段文本套用。
    func auroraEmphasis() -> some View {
        foregroundStyle(AppColors.auroraTextGradient)
    }
}

// MARK: - 数字递增

/// 统计磁贴用的数字递增文本。Reduce Motion / 应用非前台时直接显示终值、不做动画。
struct CountingNumberText: View {
    let value: Int
    var font: Font = .title2.weight(.semibold)
    var color: Color = AppColors.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var shown: Double = 0

    var body: some View {
        Text(verbatim: " ")
            .modifier(CountUpEffect(number: shown, font: font, color: color))
            .onAppear { start() }
            .onChange(of: value) { _ in start() }
            .onChange(of: reduceMotion) { _ in start() }
    }

    private func start() {
        guard !reduceMotion, scenePhase == .active else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { shown = Double(value) }
            return
        }
        shown = 0
        withAnimation(AppMotion.countUp) { shown = Double(value) }
    }
}

private struct CountUpEffect: ViewModifier, Animatable {
    var number: Double
    var font: Font
    var color: Color

    var animatableData: Double {
        get { number }
        set { number = newValue }
    }

    func body(content _: Content) -> some View {
        Text(Self.formatted(Int(number.rounded())))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.58)
            .allowsTightening(true)
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func formatted(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - 元信息胶囊行

/// `★评分 · 类型 · 年份 · 集数` 这类紧凑元信息统一用小胶囊呈现，替代松散的「· 」文本横排。
/// `onDark` 用于 Hero 深面之上（浅色半透明胶囊 + 浅字）。
struct MetaChipRow: View {
    /// `capsule` 小胶囊（海报/区块用）；`inlineDots` 点分隔文本（Hero 用，呼应设计稿 `类型 · 年份 · 全 X 话`）。
    enum Style { case capsule, inlineDots }

    let items: [String]
    var onDark: Bool = false
    var style: Style = .capsule

    var body: some View {
        Group {
            switch style {
            case .capsule: capsuleRow
            case .inlineDots: inlineDotsRow
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var capsuleRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(onDark ? AppColors.heroOnColor.opacity(0.92) : Color.secondary)
                    .background(
                        Capsule(style: .continuous)
                            .fill(onDark
                                ? AppColors.heroOnColor.opacity(0.14)
                                : AppColors.cleanFieldFill.opacity(0.72))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                onDark
                                    ? AppColors.heroOnColor.opacity(0.18)
                                    : AppColors.cleanPanelBorder.opacity(0.70),
                                lineWidth: 0.7)
                    )
            }
        }
    }

    private var inlineDotsRow: some View {
        let primary = onDark ? AppColors.heroOnColor.opacity(0.92) : Color.secondary
        let dot = onDark ? AppColors.heroOnColor.opacity(0.45) : Color.secondary.opacity(0.5)
        return HStack(spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                if index > 0 {
                    Text("·").font(.caption.weight(.semibold)).foregroundStyle(dot)
                }
                Text(text)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(primary)
            }
        }
    }
}

// MARK: - 多色统计磁贴

/// 活力统计磁贴：语义色图标 + 与之同色的递增数字 + 标签。
/// `color` 由调用处从 `AppColors.accentFamily` 取（区块/序号稳定取色）。
struct AppStatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var color: Color = AppColors.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    @State private var isHovering = false

    private var numericValue: Int? {
        Int(value.replacingOccurrences(of: ",", with: ""))
    }

    var body: some View {
        let active = isHovering && !suppressHoverDuringScroll && !layoutTransitionActive
        HStack(spacing: 12) {
            // 无边框语义色彩图标（去掉旧的彩色圆角芯片）。
            AuroraSymbolIcon(systemName: systemImage, size: 26, color: color)
                .frame(
                    width: AppAuroraMetrics.statTileIconChipSize,
                    height: AppAuroraMetrics.statTileIconChipSize)

            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let numericValue {
                        CountingNumberText(value: numericValue, font: .system(size: 25, weight: .bold), color: color)
                    } else {
                        Text(value)
                            .font(.system(size: 25, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.58)
                            .allowsTightening(true)
                    }
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: AppAuroraMetrics.statTileCornerRadius)
        .repeatedCardChrome(active)
        .repeatedSurfaceHover(active, cornerRadius: AppAuroraMetrics.statTileCornerRadius, intensity: 0.54)
        .scaleEffect(!reduceMotion && active ? 1.022 : 1)
        .animation(reduceMotion ? nil : AppMotion.fast, value: active)
        .onHover { hovering in
            guard !suppressHoverDuringScroll, !layoutTransitionActive else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing { isHovering = false }
        }
        .onChange(of: layoutTransitionActive) { active in
            if active { isHovering = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

// MARK: - Hero 焦点卡

/// 首页焦点卡。背景 = App 左上打光（蓝）+ 当前海报高斯取色派生的扩散光（紫/品红），
/// 二者合成在影院级深面之上；无封面 / 取色未就绪时回退固定品牌渐变。
/// 该视图只接收显示数据与回调，不直接读取全局状态，便于首页与详情复用、及后续 iOS/iPadOS 移植。
struct AuroraHeroCard: View {
    let badge: String?
    let title: String
    let metaItems: [String]
    let subtitle: String?
    /// 横版剧照（TMDB / Emby backdrop）优先，作为实际展示的 banner 图，铺满裁切。
    let bannerPath: String?
    /// 取色用路径（海报），用于右上角内容氛围光；与展示图分离。
    let colorPath: String?
    var primaryTitle: String = "立即播放"
    var primarySystemImage: String = "play.fill"
    var secondaryTitle: String? = "加入想看"
    var secondarySystemImage: String = "plus"
    /// 右下角超大幽灵字水印；默认取标题首字（设计稿语言）。传空字符串可关闭。
    var watermark: String? = nil
    let onPrimary: () -> Void
    var onSecondary: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var palette: MediaArtworkPalette = .fallback

    private var hasColor: Bool { colorPath?.isEmpty == false }

    /// 取首个字符作幽灵水印；拉丁字母大写，CJK 原样。空串显式关闭。
    private var watermarkGlyph: String? {
        if let watermark { return watermark.isEmpty ? nil : watermark }
        guard let first = title.first else { return nil }
        let s = String(first)
        return first.isLetter && first.isASCII ? s.uppercased() : s
    }

    var body: some View {
        ZStack(alignment: .leading) {
            background
            content
        }
        .frame(maxWidth: .infinity, minHeight: AppAuroraMetrics.heroMinHeight, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: AppAuroraMetrics.heroCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppAuroraMetrics.heroCornerRadius, style: .continuous)
                .strokeBorder(AppColors.edgeLightStroke(colorScheme, depth: 0.8), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.16), radius: 16, y: 8)
        .task(id: colorPath) {
            guard hasColor else {
                palette = .fallback
                return
            }
            palette = await AlbumPaletteCache.palette(for: colorPath)
        }
        .accessibilityElement(children: .combine)
    }

    // 横版剧照铺满 + 左侧/底部压暗保证文字可读 + 右上角内容氛围光。
    private var background: some View {
        ZStack {
            AppColors.heroSurface

            // 横版剧照（backdrop）铺满裁切；无图时 PosterImage 回退到品牌渐变占位。
            PosterImage(path: bannerPath, title: title, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .allowsHitTesting(false)

            // 左侧压暗：标题 / 正文 / 按钮压在图左侧的深色一侧，右侧露出剧照。
            LinearGradient(
                colors: [
                    AppColors.heroSurface.opacity(0.95),
                    AppColors.heroSurface.opacity(0.60),
                    .clear
                ],
                startPoint: .leading, endPoint: UnitPoint(x: 0.74, y: 0.5))

            // 底部轻压暗，承托元信息与按钮。
            LinearGradient(
                colors: [.clear, .black.opacity(colorScheme == .dark ? 0.34 : 0.24)],
                startPoint: .center, endPoint: .bottom)

            // 内容呼应：右上角一缕由海报取色派生的氛围光，不盖住剧照。
            RadialGradient(
                colors: [
                    palette.glowAccent.color.opacity(colorScheme == .dark ? 0.28 : 0.24),
                    .clear
                ],
                center: UnitPoint(x: 0.97, y: 0.05),
                startRadius: 0, endRadius: 360)

            // 右下角超大幽灵字水印（设计稿签名元素）：取标题首字，极淡白，溢出裁切。
            if let watermarkGlyph {
                Text(watermarkGlyph)
                    .font(.system(size: 240, weight: .black, design: .rounded))
                    .foregroundStyle(AppColors.heroOnColor.opacity(0.08))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 26, y: 56)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let badge, !badge.isEmpty {
                Label(badge, systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.heroOnColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(AppColors.heroOnColor.opacity(0.16)))
                    .overlay(Capsule(style: .continuous).strokeBorder(AppColors.heroOnColor.opacity(0.22), lineWidth: 0.8))
            }

            Text(title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(AppColors.heroOnColor)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)

            if !metaItems.isEmpty {
                MetaChipRow(items: metaItems, onDark: true, style: .inlineDots)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(AppColors.heroOnColor.opacity(0.84))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(action: onPrimary) {
                    Label(primaryTitle, systemImage: primarySystemImage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.black.opacity(0.86))
                        .padding(.horizontal, 18)
                        .frame(minHeight: AppAuroraMetrics.touchTargetMin)
                        .background(Capsule(style: .continuous).fill(AppColors.heroOnColor))
                }
                .buttonStyle(.plain)

                if let secondaryTitle, let onSecondary {
                    Button(action: onSecondary) {
                        Label(secondaryTitle, systemImage: secondarySystemImage)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AppColors.heroOnColor)
                            .padding(.horizontal, 18)
                            .frame(minHeight: AppAuroraMetrics.touchTargetMin)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(reduceTransparency
                                        ? AppColors.heroOnColor.opacity(0.16)
                                        : AppColors.heroOnColor.opacity(0.12)))
                            .overlay(Capsule(style: .continuous).strokeBorder(AppColors.heroOnColor.opacity(0.30), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(AppAuroraMetrics.heroContentPadding)
        .frame(maxWidth: 560, alignment: .leading)
    }
}

// MARK: - Hero 轮播

/// 首页 banner 轮播：交叉淡入，自动每 5 秒切换；Reduce Motion / 应用非前台时不自动切换，
/// 仅保留手动圆点。每张优先展示横版剧照（TMDB / Emby backdrop），无则回退海报。
struct AuroraHeroCarousel: View {
    let items: [MediaItem]
    let localize: (String) -> String
    /// 同步可得的 banner 图（backdropPath / 已缓存详情快照横版图 / 竖版封面兜底）。
    let cachedBanner: (MediaItem) -> String?
    /// 当前显示张按需解析横版图（可能联网 loadDetailSnapshot），命中后替换。
    let resolveBanner: (MediaItem) async -> String?
    let onPrimary: (MediaItem) -> Void
    let onSecondary: (MediaItem) -> Void
    let onSelect: (MediaItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    @State private var isHovering = false
    @State private var resolvedBanner: [String: String] = [:]

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let slides = Array(items.prefix(7))
        let count = max(slides.count, 1)
        let cur = ((index % count) + count) % count
        let currentItem: MediaItem? = slides.indices.contains(cur) ? slides[cur] : nil
        ZStack {
            ForEach(Array(slides.enumerated()), id: \.element.id) { offset, item in
                if offset == cur {
                    card(for: item)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: cur)
        // 触控板双指滑动切换（横向为主才拦截，纵向滚动穿透）。
        .background(BannerSwipeCatcher { direction in step(direction, count: slides.count) })
        // 鼠标左右拖动切换（鼠标无双指）。
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    guard slides.count > 1,
                          abs(value.translation.width) > 44,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    step(value.translation.width < 0 ? 1 : -1, count: slides.count)
                }
        )
        // hover：放大一档 + 指针手型 + 显示左右切换箭头。
        .scaleEffect(isHovering && !reduceMotion ? 1.006 : 1)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .overlay(alignment: .center) {
            if slides.count > 1 {
                HStack {
                    chevron("chevron.left") { step(-1, count: slides.count) }
                    Spacer()
                    chevron("chevron.right") { step(1, count: slides.count) }
                }
                .padding(.horizontal, 12)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isHovering)
                .allowsHitTesting(isHovering)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if slides.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<slides.count, id: \.self) { dot in
                        Capsule(style: .continuous)
                            .fill(AuroraPalette.heroOn.opacity(dot == cur ? 0.95 : 0.42))
                            .frame(width: dot == cur ? 18 : 7, height: 7)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { index = dot }
                            }
                            .accessibilityLabel(Text(verbatim: "\(dot + 1)"))
                    }
                }
                .padding(16)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onReceive(timer) { _ in
            guard !reduceMotion, scenePhase == .active, slides.count > 1 else { return }
            step(1, count: slides.count)
        }
        .onDisappear { if isHovering { NSCursor.arrow.set(); isHovering = false } }
        // 仅为当前显示的那张按需解析横版剧照（命中后从竖版换横版）。
        .task(id: currentItem?.id) {
            guard let currentItem, resolvedBanner[currentItem.id] == nil else { return }
            if let resolved = await resolveBanner(currentItem) {
                resolvedBanner[currentItem.id] = resolved
            }
        }
    }

    private func step(_ delta: Int, count: Int) {
        guard count > 1 else { return }
        let current = ((index % count) + count) % count
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
            index = ((current + delta) % count + count) % count
        }
    }

    // 精致深色磨砂玻璃小钮，符合全局液态玻璃风格（缩小自旧版黑色实心圆）。
    private func chevron(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppAuroraMetrics.carouselArrowIcon, weight: .semibold))
                .foregroundStyle(AuroraPalette.heroOn)
                .frame(width: AppAuroraMetrics.carouselArrowSize, height: AppAuroraMetrics.carouselArrowSize)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .overlay(Circle().fill(.black.opacity(0.16)))
                )
                .overlay(Circle().strokeBorder(AuroraPalette.heroOn.opacity(0.42), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.26), radius: 4, y: 1)
        }
        .buttonStyle(CarouselArrowButtonStyle())
        .accessibilityLabel(Text(systemName == "chevron.left" ? "上一张" : "下一张"))
    }

    private func card(for item: MediaItem) -> some View {
        AuroraHeroCard(
            badge: localize("今日精选"),
            title: item.title,
            metaItems: meta(for: item),
            subtitle: item.genre,
            bannerPath: resolvedBanner[item.id] ?? cachedBanner(item),
            colorPath: item.posterPath,
            primaryTitle: localize("立即播放"),
            secondaryTitle: item.watchlist ? localize("已想看") : localize("加入想看"),
            secondarySystemImage: item.watchlist ? "checkmark" : "plus",
            onPrimary: { onPrimary(item) },
            onSecondary: { onSecondary(item) }
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item) }
    }

    private func meta(for item: MediaItem) -> [String] {
        var parts: [String] = []
        if let rating = item.rating, rating > 0 {
            parts.append("★ \(String(format: "%.1f", rating))")
        }
        parts.append(item.type == .episode ? item.episodeLabel : item.type.displayName)
        if item.year != nil {
            parts.append(item.displayYear)
        }
        return parts
    }
}

/// 轮播箭头按压反馈：仅绘制层缩放/降透明，不改外层布局尺寸。
private struct CarouselArrowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 触控板双指横向滑动切换。照搬 MediaImageViewer 的滚轮监听：仅在精确增量且横向为主时累计触发，
/// 其余一律 return event 让纵向页面滚动穿透，作用域限定在自身视图 bounds 内。
struct BannerSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSwipe = onSwipe
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSwipe: onSwipe) }

    final class Coordinator {
        weak var hostView: NSView?
        var onSwipe: (Int) -> Void
        private var monitor: Any?
        private var accumulatedX: CGFloat = 0
        private var didTrigger = false

        init(onSwipe: @escaping (Int) -> Void) { self.onSwipe = onSwipe }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.hasPreciseScrollingDeltas,
                      let hostView = self.hostView,
                      event.window === hostView.window else { return event }
                let point = hostView.convert(event.locationInWindow, from: nil)
                guard hostView.bounds.contains(point) else { return event }

                if event.phase == .began {
                    self.accumulatedX = 0
                    self.didTrigger = false
                }
                guard !self.didTrigger,
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.15 else {
                    if event.phase == .ended || event.momentumPhase == .ended {
                        self.accumulatedX = 0
                        self.didTrigger = false
                    }
                    return event
                }
                self.accumulatedX += event.scrollingDeltaX
                if abs(self.accumulatedX) >= 72 {
                    self.didTrigger = true
                    let direction = self.accumulatedX < 0 ? 1 : -1
                    DispatchQueue.main.async { self.onSwipe(direction) }
                }
                if event.phase == .ended || event.momentumPhase == .ended {
                    self.accumulatedX = 0
                    self.didTrigger = false
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

// MARK: - 活力海报卡（标题内置）

/// 活力海报卡：封面铺满 + 标题/副信息内置在卡内底部（深色 scrim），保留检视倾斜与放大 hover。
/// 用于首页推荐行（竖版剧集 / 方形音乐）与继续听歌等场景。
struct AuroraPosterCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let title: String
    let subtitle: String?
    let posterPath: String?
    let mediaType: MediaType?
    var aspect: CGFloat = 2.0 / 3.0
    /// 右上角评分徽章文本（如「9.4」）；nil 时不显示。hover 时淡出（呼应设计稿）。
    var rating: String? = nil
    /// 继续观看进度（0–1）；在 (0, 0.98) 区间显示底部细进度条。
    var progress: Double? = nil
    /// 评分徽章与进度条着色（区块语义色）。
    var accent: Color = AuroraPalette.blue
    let onSelect: () -> Void
    @State private var isHovering = false

    private var active: Bool { isHovering && !suppressHoverDuringScroll && !layoutTransitionActive }
    private var showsProgress: Bool {
        guard let progress else { return false }
        return progress > 0 && progress < 0.98
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay {
                        PosterImage(
                            path: posterPath,
                            title: title,
                            mediaType: mediaType,
                            cacheTargetSize: CGSize(width: 300, height: 300 / max(aspect, 0.01))
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.12), .black.opacity(0.74)],
                    startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    if showsProgress, let progress {
                        Capsule()
                            .fill(.white.opacity(0.22))
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(accent)
                                        .frame(width: max(2, geo.size.width * CGFloat(min(max(progress, 0), 1))))
                                }
                            }
                            .padding(.top, 1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 右上角评分徽章（hover 淡出，让位封面检视）。
            .overlay(alignment: .topTrailing) {
                if let rating, !rating.isEmpty {
                    Label(rating, systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.42), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
                        .padding(8)
                        .opacity(active ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
            // 居中圆形蓝播放键（hover 浮现，呼应设计稿）。
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        Circle().fill(
                            LinearGradient(colors: [AuroraPalette.cyan, AuroraPalette.blue],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.8))
                    .shadow(color: AuroraPalette.blue.opacity(0.6), radius: 12, y: 5)
                    .scaleEffect(active && !reduceMotion ? 1 : 0.55)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(active ? 0.5 : 0.18), lineWidth: active ? 1.1 : 0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .pointerInspectTilt(enabled: !reduceMotion, cornerRadius: 14)
            .scaleEffect(active && !reduceMotion ? 1.02 : 1)
            .shadow(color: active ? .black.opacity(0.22) : .black.opacity(0.10), radius: active ? 12 : 6, y: active ? 5 : 2)
        }
        .buttonStyle(.plain)
        .zIndex(active ? 1 : 0)
        .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
        .onHover { hovering in
            guard !suppressHoverDuringScroll, !layoutTransitionActive else { isHovering = false; return }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing { isHovering = false }
        }
        .onChange(of: layoutTransitionActive) { active in
            if active { isHovering = false }
        }
        .accessibilityLabel(Text(title))
    }
}

private struct HomeRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 首页整行分页海报

/// 当前视口只展示一整行，按固定节奏翻到下一整行。Reduce Motion 或应用不在前台时停止自动翻页。
struct HomePagedPosterRow<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var maxItems: Int = 24
    var minCardWidth: CGFloat = AppAuroraMetrics.recommendPortraitMinWidth
    var spacing: CGFloat = AppAuroraMetrics.recommendRowSpacing
    var pageTint: Color = AuroraPalette.blue
    var autoAdvanceInterval: TimeInterval = 7
    @ViewBuilder var card: (Item) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var availableWidth: CGFloat = 0
    @State private var pageIndex = 0

    private let timer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    private var visibleItems: [Item] {
        Array(items.prefix(maxItems))
    }

    private var itemKey: String {
        visibleItems.map { String(describing: $0.id) }.joined(separator: "|")
    }

    private var cardsPerPage: Int {
        guard availableWidth > 0 else { return 1 }
        return max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))
    }

    private var cardWidth: CGFloat {
        guard availableWidth > 0 else { return minCardWidth }
        let count = CGFloat(cardsPerPage)
        return max(1, (availableWidth - spacing * max(0, count - 1)) / count)
    }

    private var pageCount: Int {
        guard !visibleItems.isEmpty else { return 1 }
        return max(1, Int(ceil(Double(visibleItems.count) / Double(cardsPerPage))))
    }

    private var displayedPage: Int {
        min(pageIndex, pageCount - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: spacing) {
                ForEach(pageItems(for: displayedPage)) { item in
                    card(item)
                        .frame(width: cardWidth)
                }

                ForEach(0..<placeholderCount(for: displayedPage), id: \.self) { _ in
                    Color.clear
                        .frame(width: cardWidth)
                        .allowsHitTesting(false)
                }
            }
            .id("\(itemKey)-\(cardsPerPage)-\(displayedPage)")
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            if pageCount > 1 {
                pageControl
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HomeRowWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(HomeRowWidthKey.self) { width in
            availableWidth = width
            clampPageIndex()
        }
        .onChange(of: itemKey) { _ in
            pageIndex = 0
        }
        .onChange(of: availableWidth) { _ in
            clampPageIndex()
        }
        .onReceive(timer) { _ in
            guard !reduceMotion,
                  scenePhase == .active,
                  pageCount > 1,
                  autoAdvanceInterval > 0 else { return }
            withAnimation(AppMotion.page) {
                pageIndex = (displayedPage + 1) % pageCount
            }
        }
    }

    private var pageControl: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Button {
                    withAnimation(AppMotion.fast) {
                        pageIndex = index
                    }
                } label: {
                    Capsule(style: .continuous)
                        .fill(index == displayedPage ? pageTint : pageTint.opacity(0.18))
                        .frame(width: index == displayedPage ? 18 : 7, height: 7)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(pageTint.opacity(index == displayedPage ? 0.28 : 0.16), lineWidth: 0.7)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(index + 1) 页")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func pageItems(for page: Int) -> [Item] {
        let start = page * cardsPerPage
        guard start < visibleItems.count else { return [] }
        let end = min(start + cardsPerPage, visibleItems.count)
        return Array(visibleItems[start..<end])
    }

    private func placeholderCount(for page: Int) -> Int {
        max(0, cardsPerPage - pageItems(for: page).count)
    }

    private func clampPageIndex() {
        guard pageIndex >= pageCount else { return }
        pageIndex = max(0, pageCount - 1)
    }
}

// MARK: - 推荐行（单行占满宽度，整行分页展示更多）

/// 首页「推荐剧集 / 推荐音乐」单行：按可用宽度算出能放下的张数，等分占满整行、不横向滚动；
/// 窗口缩小时张数自动减少。竖版传 2:3，方形传 1。
struct HomeRecommendRow: View {
    let title: String
    let systemImage: String
    let accentColor: Color
    let items: [MediaItem]
    var aspect: CGFloat = 2.0 / 3.0
    var minCardWidth: CGFloat = AppAuroraMetrics.recommendPortraitMinWidth
    let subtitle: (MediaItem) -> String?
    let mediaType: (MediaItem) -> MediaType?
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeading(
                title: title,
                systemImage: systemImage,
                accentColor: accentColor,
                usesAuroraIcon: true
            )
            HomePagedPosterRow(
                items: items,
                maxItems: 24,
                minCardWidth: minCardWidth,
                spacing: AppAuroraMetrics.recommendRowSpacing,
                pageTint: accentColor
            ) { item in
                AuroraPosterCard(
                    title: item.cardTitle,
                    subtitle: subtitle(item),
                    posterPath: item.posterPath,
                    mediaType: mediaType(item),
                    aspect: aspect,
                    rating: item.rating.map { String(format: "%.1f", $0) },
                    accent: accentColor,
                    onSelect: { onSelect(item) }
                )
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 1.02)
        .repeatedCardChrome(false, cornerRadius: 20)
    }
}

// MARK: - 首页模块数据

struct HomeDashboardSourceSummary: Identifiable {
    let id: String
    let title: String
    let detail: String
    let statusTitle: String
    let systemImage: String
    let health: Double
    let tint: Color
}

struct HomeDashboardSpotlight {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var progress: Double?
    var primaryMetric: String?
    var primaryLabel: String?
    var secondaryMetric: String?
    var secondaryLabel: String?
}

struct HomePlaylistSummary: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let posterPaths: [String]
    var trackIDs: [String] = []
}

// MARK: - 首页模块容器

struct HomeModuleContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var accentColor: Color
    var badgeText: String?
    var badgeTint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeading(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                badgeText: badgeText,
                badgeTint: badgeTint,
                accentColor: accentColor,
                usesAuroraIcon: true
            )
            content
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 1.02)
        .repeatedCardChrome(false, cornerRadius: 20)
    }
}

// MARK: - 首页仪表盘

struct HomeDashboardModuleView: View {
    let sources: [HomeDashboardSourceSummary]
    let spotlight: HomeDashboardSpotlight
    let accentColor: Color
    let onOpenSources: () -> Void
    let onOpenSpotlight: () -> Void

    var body: some View {
        HomeModuleContainer(
            title: "运行状态",
            subtitle: "媒体源、片库状态和后台任务集中查看。",
            systemImage: "chart.xyaxis.line",
            accentColor: accentColor,
            badgeText: "实时",
            badgeTint: accentColor
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    sourceList
                    spotlightButton
                        .frame(width: 300)
                }

                VStack(spacing: 14) {
                    sourceList
                    spotlightButton
                }
            }
        }
    }

    private var sourceList: some View {
        VStack(spacing: 10) {
            if sources.isEmpty {
                dashboardEmptySources
            } else {
                ForEach(sources.prefix(4)) { source in
                    Button(action: onOpenSources) {
                        HomeDashboardSourceRow(source: source)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var spotlightButton: some View {
        Button(action: onOpenSpotlight) {
            HomeDashboardInsightCard(spotlight: spotlight)
        }
        .buttonStyle(.plain)
    }

    private var dashboardEmptySources: some View {
        HStack(spacing: 12) {
            AuroraSymbolIcon(systemName: "externaldrive.badge.plus", size: 24, color: accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("还没有媒体源")
                    .font(.callout.weight(.semibold))
                Text("添加来源后，这里会显示健康度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 0.92)
    }
}

private struct HomeDashboardSourceRow: View {
    let source: HomeDashboardSourceSummary

    var body: some View {
        HStack(spacing: 12) {
            AuroraSymbolIcon(systemName: source.systemImage, size: 24, color: source.tint)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(source.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(source.statusTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(source.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(source.tint.opacity(0.10), in: Capsule())
                }
                Text(source.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: source.health)
                    .tint(source.tint)
                    .controlSize(.small)
            }

            Text("\(Int((source.health * 100).rounded()))%")
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(source.tint)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 0.94)
        .accessibilityElement(children: .combine)
    }
}

/// 仪表盘环形进度表（呼应设计稿 84×84 内嵌圆芯环）：环用语义色派生渐变，中心显示百分比。
/// 浅/深面通用；Reduce Motion 下静态显示终值。
struct DashboardRingGauge: View {
    let progress: Double
    let tint: Color
    var onDark: Bool = false
    var diameter: CGFloat = 76

    private var clamped: Double { min(max(progress, 0), 1) }
    private var trackColor: Color { onDark ? .white.opacity(0.14) : tint.opacity(0.16) }
    private var centerColor: Color { onDark ? .white : AppColors.textPrimary }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: diameter * 0.12)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AuroraPalette.accentBarGradient(tint),
                    style: StrokeStyle(lineWidth: diameter * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((clamped * 100).rounded()))%")
                .font(.system(size: diameter * 0.26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(centerColor)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("\(Int((clamped * 100).rounded()))%")
    }
}

private struct HomeDashboardInsightCard: View {
    let spotlight: HomeDashboardSpotlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                AuroraSymbolIcon(systemName: spotlight.systemImage, size: 28, color: spotlight.tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(spotlight.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(spotlight.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = spotlight.progress {
                HStack(alignment: .center, spacing: 14) {
                    DashboardRingGauge(progress: progress, tint: spotlight.tint, onDark: true)
                    if let primaryLabel = spotlight.primaryLabel {
                        Text(primaryLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            } else if let primaryMetric = spotlight.primaryMetric,
                      let primaryLabel = spotlight.primaryLabel,
                      let secondaryMetric = spotlight.secondaryMetric,
                      let secondaryLabel = spotlight.secondaryLabel {
                HStack(spacing: 14) {
                    metric(primaryMetric, primaryLabel, tint: AuroraPalette.cyan)
                    Divider().overlay(.white.opacity(0.18))
                    metric(secondaryMetric, secondaryLabel, tint: AuroraPalette.orange)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 228, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppColors.heroSurface)
        )
        .overlay(alignment: .topTrailing) {
            RadialGradient(
                colors: [spotlight.tint.opacity(0.36), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 220
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(isHovering ? 0.32 : 0.18), lineWidth: 1)
        )
        .scaleEffect(isHovering && !reduceMotion ? 1.012 : 1)
        .animation(reduceMotion ? nil : AppMotion.listHover, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 首页音乐模块

struct HomeMusicRecommendationModule: View {
    let title: String
    let subtitle: String?
    let tracks: [MediaItem]
    let playlist: HomePlaylistSummary?
    let accentColor: Color
    let onTrackSelect: (MediaItem) -> Void
    let onPlaylistSelect: (HomePlaylistSummary) -> Void

    @State private var availableWidth: CGFloat = 0

    private var usesWideLayout: Bool {
        availableWidth == 0 || availableWidth >= 720
    }

    private var leftColumnWidth: CGFloat {
        min(max(availableWidth * 0.38, 286), 390)
    }

    private var effectivePlaylist: HomePlaylistSummary? {
        if let playlist { return playlist }
        let fallbackTracks = Array(tracks.prefix(4))
        guard !fallbackTracks.isEmpty else { return nil }
        return HomePlaylistSummary(
            id: "synthetic.recommend",
            title: "今日推荐",
            subtitle: "\(fallbackTracks.count) 首歌",
            posterPaths: fallbackTracks.compactMap(\.posterPath)
        )
    }

    var body: some View {
        HomeModuleContainer(
            title: title,
            subtitle: subtitle,
            systemImage: "music.note.list",
            accentColor: accentColor
        ) {
            if usesWideLayout {
                HStack(alignment: .top, spacing: 14) {
                    trackList
                        .frame(width: leftColumnWidth, alignment: .top)
                    if let effectivePlaylist {
                        playlistButton(effectivePlaylist)
                            .frame(maxWidth: .infinity, minHeight: 318)
                    }
                }
            } else {
                VStack(spacing: 14) {
                    trackList
                    if let effectivePlaylist {
                        playlistButton(effectivePlaylist)
                    }
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HomeRowWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(HomeRowWidthKey.self) { availableWidth = $0 }
    }

    private var trackList: some View {
        VStack(spacing: 8) {
            ForEach(Array(tracks.prefix(5).enumerated()), id: \.element.id) { offset, track in
                Button {
                    onTrackSelect(track)
                } label: {
                    HomeMusicMiniRow(track: track, tint: accentColor, index: offset + 1)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func playlistButton(_ playlist: HomePlaylistSummary) -> some View {
        Button {
            onPlaylistSelect(playlist)
        } label: {
            HomePlaylistPoster(summary: playlist, tint: accentColor)
        }
        .buttonStyle(.plain)
    }
}

struct HomeContinueListeningModule: View {
    let tracks: [MediaItem]
    let accentColor: Color
    let onTrackSelect: (MediaItem) -> Void

    var body: some View {
        HomeModuleContainer(
            title: "继续听",
            subtitle: "回到最近播放的音乐。",
            systemImage: "headphones",
            accentColor: accentColor
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(tracks.prefix(6)) { track in
                    Button {
                        onTrackSelect(track)
                    } label: {
                        HomeMusicMiniRow(track: track, tint: accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct HomeMusicMiniRow: View {
    let track: MediaItem
    let tint: Color
    /// 1 起的序号；为「为你推荐」榜单列表显示左侧序号（呼应设计稿）。nil 时不显示。
    var index: Int? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let index {
                Text("\(index)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            PosterImage(
                path: track.posterPath,
                title: track.title,
                mediaType: .music,
                cacheTargetSize: CGSize(width: 96, height: 96)
            )
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artistAlbumLine ?? "未知艺人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 0.92)
        .accessibilityElement(children: .combine)
    }
}

private struct HomePlaylistPoster: View {
    let summary: HomePlaylistSummary
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.88), AuroraPalette.magenta.opacity(0.74), AppColors.heroSurface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RadialGradient(
                colors: [.white.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260
            )
            .allowsHitTesting(false)

            playlistArtworkGrid
                .padding(22)
                .opacity(0.92)

            LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Label("推荐歌单", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Text(summary.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)

                // 「播放全部」胶囊（视觉，整卡点击即进入歌单并播放；呼应设计稿）。
                Label("播放全部", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.heroSurface)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(.white.opacity(0.94)))
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: 318)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var playlistArtworkGrid: some View {
        let paths = Array(summary.posterPaths.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                PosterImage(
                    path: paths.indices.contains(index) ? paths[index] : nil,
                    title: summary.title,
                    mediaType: .music,
                    cacheTargetSize: CGSize(width: 140, height: 140)
                )
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: 220)
        .rotationEffect(.degrees(-3))
        .offset(x: 120, y: -34)
    }
}

// MARK: - 首页照片墙

struct HomePhotoWallSection: View {
    let items: [MediaItem]
    var themeTitle: String = "照片墙"
    var badgeText: String? = nil
    let accentColor: Color
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeading(
                title: themeTitle,
                subtitle: nil,
                systemImage: "photo.stack",
                badgeText: badgeText ?? "最近 \(items.count) 张",
                badgeTint: accentColor,
                accentColor: accentColor,
                usesAuroraIcon: true
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: AppAuroraMetrics.albumWallThumbSide), spacing: 8)],
                spacing: 8
            ) {
                ForEach(items.prefix(12)) { item in
                    HomePhotoWallTile(item: item, onSelect: { onSelect(item) })
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct HomePhotoWallModule: View {
    let items: [MediaItem]
    var themeTitle: String = "照片墙"
    var badgeText: String? = nil
    let accentColor: Color
    let onSelect: (MediaItem) -> Void

    var body: some View {
        HomePhotoWallSection(items: items, themeTitle: themeTitle, badgeText: badgeText, accentColor: accentColor, onSelect: onSelect)
    }
}

private struct HomePhotoWallTile: View {
    let item: MediaItem
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @State private var isHovering = false

    private var active: Bool { isHovering && !suppressHoverDuringScroll }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomTrailing) {
                PosterImage(
                    path: item.posterPath,
                    title: item.title,
                    mediaType: item.type,
                    cacheTargetSize: CGSize(width: 180, height: 180)
                )
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if item.type != .photo {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.44), in: Circle())
                        .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(active ? 0.46 : 0.26), lineWidth: active ? 1.1 : 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .pointerInspectTilt(enabled: !reduceMotion, cornerRadius: 14)
            .scaleEffect(active && !reduceMotion ? 1.018 : 1)
            .shadow(color: .black.opacity(active ? 0.16 : 0.07), radius: active ? 10 : 4, y: active ? 4 : 1)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
        .onHover { hovering in
            guard !suppressHoverDuringScroll else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing { isHovering = false }
        }
        .accessibilityLabel(item.title)
    }
}
