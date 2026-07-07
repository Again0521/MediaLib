import AppKit
import AVFoundation
import Combine
import CoreImage
import MediaLibCore
import SwiftUI
import UniformTypeIdentifiers

/// 音乐播放器展开界面的视觉可调参数集中管理（§6.1）。
/// §1–§5 新增/调整的可调数值统一引用此处，避免魔法数字散落各 struct，便于统一调参与回归。
/// 注意：色相一律严格保留（提亮/加深只改饱和度与亮度），封面光混合只用 screen / plusLighter。
enum MusicPlayerVisualTokens {
    /// 圆角：三块玻璃（歌词卡 / 控制栏 / 收起按钮）保留各自圆角差异，
    /// 但磨砂浓度、描边渐变、顶/底高光逻辑必须同源（见 FloatingLyricsGlass）。
    enum Radius {
        static var card: CGFloat { MusicThemeConfig.active.visual.radius.card }
        static var control: CGFloat { MusicThemeConfig.active.visual.radius.control }
        static var chrome: CGFloat { MusicThemeConfig.active.visual.radius.chrome }
    }

    /// 玻璃材质（明/暗双模式同源参数）。
    enum Glass {
        /// 白霜 = 玻璃的"提亮体"：比底板亮一档才有玻璃质感；但过高会变灰雾，
        /// 灰/透的平衡靠 material 模糊 + 专辑染色一起承担。
        // R2：浅色白霜上抬，给玻璃面更明确的"提亮体"，配合降低的 material 占比读作通透玻璃而非灰板。
        static func frostWhite(dark: Bool) -> Double { dark ? 0.058 : 0.165 }
        static func frostTexture(dark: Bool) -> Double { dark ? 0.012 : 0.010 }
        // R2：上沿镜面受光增强，让玻璃顶边有清晰的高光线（玻璃质感的关键反射）。
        static func topHighlight(dark: Bool) -> Double { dark ? 0.225 : 0.390 }
        /// §1.3 底沿内侧极淡暗线（仅最底 ~2pt 的 .black），与顶部高光形成"上受光、下背光"的厚度感。
        static func bottomShade(dark: Bool) -> Double { dark ? 0.028 : 0.0008 }
        /// 发丝描边渐变三色（白 → 专辑色 → 暗），方向 topLeading→bottomTrailing。
        static func strokeTopWhite(dark: Bool) -> Double { dark ? 0.66 : 1.0 }
        // R4：发丝描边中段的专辑色加重，让玻璃边缘明显带"歌曲的颜色"（描边氛围）。
        static func strokeMidAlbum(dark: Bool) -> Double { dark ? 0.29 : 0.26 }
        static func strokeBottomBlack(dark: Bool) -> Double { dark ? 0.056 : 0.0015 }
    }

    /// 封面发光（§2）。
    enum Glow {
        /// 外层环境光有效半径抵达歌词卡边缘后再多出的距离（pt），即"轻微触达并略超过"。
        static var edgeOvershoot: CGFloat { MusicThemeConfig.active.visual.glow.edgeOvershoot }
        /// 几何落点换算出的 reach 夹紧区间（相对 posterSize 的倍数）。
        static var minReach: CGFloat { MusicThemeConfig.active.visual.glow.minReach }
        static var maxReach: CGFloat { MusicThemeConfig.active.visual.glow.maxReach }
        /// SDF glow 使用整块 frame 做衰减画布，可见光程 ≈ frame半径。
        static var bloomVisibleFraction: CGFloat { MusicThemeConfig.active.visual.glow.bloomVisibleFraction }
        /// 低彩封面略收光程，避免白灰封面大面积雾化。
        static var lowVibrancyDamp: Double { MusicThemeConfig.active.visual.glow.lowVibrancyDamp }
        /// 几何不可用（stacked）时的兜底 reach（再经视图层 vibrancy 轻微缩放）。
        static var fallbackReach: CGFloat { MusicThemeConfig.active.visual.glow.fallbackReach }
        /// 近场 bloom 饱和度封顶，避免彩色封面近场霓虹感。
        static var nearSaturationCap: Double { MusicThemeConfig.active.visual.glow.nearSaturationCap }
        /// 暂停"掉色温"：glow 降到 0 时彩色投影饱和度向中性靠拢，最低保留比例。
        static var pausedShadowSaturationFloor: Double { MusicThemeConfig.active.visual.glow.pausedShadowSaturationFloor }
    }

    /// 封面光浸染到玻璃卡边缘（§2.3）。
    enum Spill {
        // 组件染色不再固定铺满整条边，而是再乘以布局计算出的真实入射强度。
        // 这些值只定义“玻璃吃到光后的材质反应”，光能不能到由 AlbumComponentLight 决定。
        // R4 氛围增强：让"歌曲发光"对控制栏/收起按钮的浸染更明显。
        static var lyricsIntensity: Double { MusicThemeConfig.active.visual.spill.lyricsIntensity }
        static var controlsIntensity: Double { MusicThemeConfig.active.visual.spill.controlsIntensity }
        static var chromeIntensity: Double { MusicThemeConfig.active.visual.spill.chromeIntensity }
        static var lyricsReach: Double { MusicThemeConfig.active.visual.spill.lyricsReach }
        static var controlsReach: Double { MusicThemeConfig.active.visual.spill.controlsReach }
        static var chromeReach: Double { MusicThemeConfig.active.visual.spill.chromeReach }
        // 主增益：同时放大三块玻璃的浸染漫入强度（含歌词卡右侧平衡光），让光"软软漫进卡片"更明显。
        static var chromaTravelBase: Double { MusicThemeConfig.active.visual.spill.chromaTravelBase }
        static var chromaTravelVibrancy: Double { MusicThemeConfig.active.visual.spill.chromaTravelVibrancy }
        static var innerPeak: Double { MusicThemeConfig.active.visual.spill.innerPeak }
        static var innerPrimary: Double { MusicThemeConfig.active.visual.spill.innerPrimary }
        static var innerSecondary: Double { MusicThemeConfig.active.visual.spill.innerSecondary }
        static var innerFade: Double { MusicThemeConfig.active.visual.spill.innerFade }
        static var pausedResidual: Double { MusicThemeConfig.active.visual.spill.pausedResidual }
        static var pauseNearFadeDuration: Double { MusicThemeConfig.active.visual.spill.pauseNearFadeDuration }
        static var pauseFarDelay: UInt64 { MusicThemeConfig.active.visual.spill.pauseFarDelay }
        static var pauseFarFadeDuration: Double { MusicThemeConfig.active.visual.spill.pauseFarFadeDuration }
        static var playRiseDuration: Double { MusicThemeConfig.active.visual.spill.playRiseDuration }
    }

    /// 展开页底部控制栏：高度必须固定，避免封面取色、文字状态或玻璃背景改变布局。
    enum Controls {
        static var expandedHeight: CGFloat { MusicThemeConfig.active.visual.controls.expandedHeight }
        static var expandedMaxWidth: CGFloat { MusicThemeConfig.active.visual.controls.expandedMaxWidth }
    }

    /// 歌词景深（§3）。
    enum Lyrics {
        /// 距当前行的距离模糊分段（index = distance，0 为当前行恒不模糊）。
        static let distanceBlur: [CGFloat] = [0, 1.1, 2.5, 4.1, 6.2]
        static var distanceBlurMax: CGFloat { MusicThemeConfig.active.visual.lyrics.distanceBlurMax }
        /// 距当前行 2~3 行起，叠加一点点固定模糊，强化"上下比中间更糊"的位置感（克制）。
        static var edgeExtraBlur: CGFloat { MusicThemeConfig.active.visual.lyrics.edgeExtraBlur }
        /// 按行距估算该行在卡片中窗外的归一化位置，避免只按距离导致边缘景深不稳定。
        static var edgePositionStep: CGFloat { MusicThemeConfig.active.visual.lyrics.edgePositionStep }
        /// 清晰中窗高度比（中间约 40% 高度保持全清晰，两端羽化）。
        static var clearWindowRatio: Double { MusicThemeConfig.active.visual.lyrics.clearWindowRatio }
        static var browseClearDuration: Double { MusicThemeConfig.active.visual.lyrics.browseClearDuration }
        static var browseRecoverDuration: Double { MusicThemeConfig.active.visual.lyrics.browseRecoverDuration }
        static var viewportStabilityDelay: UInt64 { MusicThemeConfig.active.visual.lyrics.viewportStabilityDelay }
        /// 手动浏览歌词后，保持 4 秒清晰阅读窗口，再恢复自动居中与景深。
        static var browseFallbackResumeDelay: UInt64 { MusicThemeConfig.active.visual.lyrics.browseFallbackResumeDelay }
    }

    /// 播放按钮 / 进度条主色加深（§5）：deepTint = 降亮 0.84、提饱和 1.10、亮度夹 0.40–0.82。
    enum Tint {
        static var playSaturation: CGFloat { MusicThemeConfig.active.visual.tint.playSaturation }
        static var playBrightness: CGFloat { MusicThemeConfig.active.visual.tint.playBrightness }
        static var playMinSaturation: CGFloat { MusicThemeConfig.active.visual.tint.playMinSaturation }
        static var playMaxSaturation: CGFloat { MusicThemeConfig.active.visual.tint.playMaxSaturation }
        static var playMinBrightness: CGFloat { MusicThemeConfig.active.visual.tint.playMinBrightness }
        static var playMaxBrightness: CGFloat { MusicThemeConfig.active.visual.tint.playMaxBrightness }
        static var playPressedScale: CGFloat { MusicThemeConfig.active.visual.tint.playPressedScale }
    }

    /// 进度条（§5.1）。
    enum Progress {
        static var thumbActiveGrowth: CGFloat { MusicThemeConfig.active.visual.progress.thumbActiveGrowth }
        static var thumbGlowRadius: CGFloat { MusicThemeConfig.active.visual.progress.thumbGlowRadius }
        static var sheenDuration: Double { MusicThemeConfig.active.visual.progress.sheenDuration }
        static func sheenOpacity(dark: Bool) -> Double { dark ? 0.16 : 0.20 }
        static var sheenWidthMin: CGFloat { MusicThemeConfig.active.visual.progress.sheenWidthMin }
        static var sheenWidthMax: CGFloat { MusicThemeConfig.active.visual.progress.sheenWidthMax }
        static var sheenWidthRatio: CGFloat { MusicThemeConfig.active.visual.progress.sheenWidthRatio }
    }

    /// 专辑取色（§4）：保证彩色封面优先取真实不同色相；接近单色时才退化为克制类比三色。
    enum Palette {
        // 真实封面常见"鲜艳色只占小块面积、其余是中性背景/肤色"（如制服+白墙）。
        // 阈值偏高 + normalizer 偏大会把这类封面判成中性→灰底板→封面不发光、发光没颜色。
        // 下调让"有明显鲜艳块"的封面走彩色方案并拿到足够 vibrancy，同时仍靠面积权重防止指甲油级别夺主色。
        static var colorfulFractionThreshold: Double { MusicThemeConfig.active.visual.palette.colorfulFractionThreshold }
        static var vibrancyNormalizer: Double { MusicThemeConfig.active.visual.palette.vibrancyNormalizer }
        static var secondaryHueDistance: Double { MusicThemeConfig.active.visual.palette.secondaryHueDistance }
        static var accentHueDistance: Double { MusicThemeConfig.active.visual.palette.accentHueDistance }
        static var secondaryHueWeightFraction: Double { MusicThemeConfig.active.visual.palette.secondaryHueWeightFraction }
        static var accentHueWeightFraction: Double { MusicThemeConfig.active.visual.palette.accentHueWeightFraction }
        static var analogousSecondaryHueOffset: CGFloat { MusicThemeConfig.active.visual.palette.analogousSecondaryHueOffset }
        static var analogousAccentHueOffset: CGFloat { MusicThemeConfig.active.visual.palette.analogousAccentHueOffset }
        static var neutralColorHintFraction: Double { MusicThemeConfig.active.visual.palette.neutralColorHintFraction }
        static var neutralTopHueFraction: Double { MusicThemeConfig.active.visual.palette.neutralTopHueFraction }
        static var neutralSecondHueDistance: Double { MusicThemeConfig.active.visual.palette.neutralSecondHueDistance }
        static var neutralAnalogousSecondaryHueOffset: CGFloat { MusicThemeConfig.active.visual.palette.neutralAnalogousSecondaryHueOffset }
        static var neutralAnalogousAccentHueOffset: CGFloat { MusicThemeConfig.active.visual.palette.neutralAnalogousAccentHueOffset }
    }

    /// 浅色 / 低彩专辑下的文字可读性 scrim（§6.5）。
    /// 只在文字层下方叠极淡中性暗化，不用 multiply/overlay，不参与专辑 glow 合成。
    enum TextScrim {
        static var brightLuminanceStart: Double { MusicThemeConfig.active.visual.textScrim.brightLuminanceStart }
        static var brightLuminanceEnd: Double { MusicThemeConfig.active.visual.textScrim.brightLuminanceEnd }
        static var lowVibrancyThreshold: Double { MusicThemeConfig.active.visual.textScrim.lowVibrancyThreshold }
        static var lyricsMaxOpacity: Double { MusicThemeConfig.active.visual.textScrim.lyricsMaxOpacity }
        static var controlsMaxOpacity: Double { MusicThemeConfig.active.visual.textScrim.controlsMaxOpacity }
        static var centerMultiplier: Double { MusicThemeConfig.active.visual.textScrim.centerMultiplier }
        static var edgeMultiplier: Double { MusicThemeConfig.active.visual.textScrim.edgeMultiplier }
    }
}

#if DEBUG
enum MusicPlayerVisualDebugVariant: String, CaseIterable {
    case quadrant
    case cool
    case warm
    case cream
    case black
    case whiteFrame = "whiteframe"
    /// 真实封面诊断：从固定临时路径加载真实专辑封面，并走真实取色管线（不用合成 palette），
    /// 用于复现"真机上真实封面发光"的观感（合成 fixture 太亮，会掩盖真实封面偏暗导致的弱发光问题）。
    case real

    static var fromArguments: MusicPlayerVisualDebugVariant {
        let arguments = ProcessInfo.processInfo.arguments
        return allCases.first { arguments.contains($0.argument) } ?? .quadrant
    }

    /// 真实封面诊断固定读取路径：把任意真实封面拷到这里即可在不重编译的情况下切换测试图。
    static let realCoverTestPath = "/tmp/medialib_real_cover_test.jpg"

    var argument: String {
        "--music-player-visual-debug-\(rawValue)"
    }

    var coverPath: String {
        if self == .real { return Self.realCoverTestPath }
        return "__MediaLIB_MUSIC_VISUAL_DEBUG_\(rawValue.uppercased())__"
    }

    var trackID: String {
        "medialib-debug-music-visual-\(rawValue)"
    }

    var title: String {
        switch self {
        case .quadrant:
            return "四象限 Glow 测试"
        case .cool:
            return "冷色空歌词测试"
        case .warm:
            return "暖黄歌词景深测试"
        case .cream:
            return "奶油英文歌词测试"
        case .black:
            return "黑底少量亮部测试"
        case .whiteFrame:
            return "白框浅蓝取色测试"
        case .real:
            return "真实封面发光诊断"
        }
    }

    var artist: String {
        switch self {
        case .quadrant:
            return "MediaLIB Visual QA"
        case .cool:
            return "No Lyrics Fixture"
        case .warm:
            return "Warm Cover Fixture"
        case .cream:
            return "Cream Cover Fixture"
        case .black:
            return "Black Glow Fixture"
        case .whiteFrame:
            return "White Frame Fixture"
        case .real:
            return "Real Cover Diagnostic"
        }
    }

    var album: String {
        switch self {
        case .quadrant:
            return "上红 · 右绿 · 下蓝 · 左黄"
        case .cool:
            return "冷蓝紫 · 空态歌词卡"
        case .warm:
            return "高饱和暖黄 · 中文同步"
        case .cream:
            return "低彩奶油 · 英文同步"
        case .black:
            return "黑色底色 · 少量青金亮部"
        case .whiteFrame:
            return "近白外框 · 浅蓝纸纹 · 黄色亮部"
        case .real:
            return "真实封面 · 真实取色管线"
        }
    }

    var palette: AlbumColorPalette {
        switch self {
        case .quadrant:
            return AlbumColorPalette(
                primary: AlbumPaletteColor(red: 0.95, green: 0.16, blue: 0.12),
                secondary: AlbumPaletteColor(red: 0.12, green: 0.74, blue: 0.22),
                accent: AlbumPaletteColor(red: 0.12, green: 0.34, blue: 0.96),
                vibrancy: 1
            )
        case .cool:
            return AlbumColorPalette(
                primary: AlbumPaletteColor(red: 0.24, green: 0.36, blue: 0.88),
                secondary: AlbumPaletteColor(red: 0.48, green: 0.28, blue: 0.72),
                accent: AlbumPaletteColor(red: 0.12, green: 0.70, blue: 0.86),
                vibrancy: 0.78
            )
        case .warm:
            return AlbumColorPalette(
                primary: AlbumPaletteColor(red: 0.96, green: 0.62, blue: 0.16),
                secondary: AlbumPaletteColor(red: 0.88, green: 0.30, blue: 0.12),
                accent: AlbumPaletteColor(red: 1.00, green: 0.78, blue: 0.24),
                vibrancy: 0.92
            )
        case .cream:
            return AlbumColorPalette(
                primary: AlbumPaletteColor(red: 0.82, green: 0.66, blue: 0.57),
                secondary: AlbumPaletteColor(red: 0.72, green: 0.58, blue: 0.70),
                accent: AlbumPaletteColor(red: 0.92, green: 0.74, blue: 0.58),
                vibrancy: 0.38
            )
        case .black:
            return AlbumColorPalette(
                primary: AlbumPaletteColor(red: 0.08, green: 0.66, blue: 0.78),
                secondary: AlbumPaletteColor(red: 0.90, green: 0.66, blue: 0.20),
                accent: AlbumPaletteColor(red: 0.58, green: 0.25, blue: 0.82),
                vibrancy: 0.46
            )
        case .whiteFrame:
            return AlbumColorPalette(
                primary: AlbumPaletteColor(red: 0.52, green: 0.82, blue: 0.90),
                secondary: AlbumPaletteColor(red: 0.94, green: 0.76, blue: 0.20),
                accent: AlbumPaletteColor(red: 0.40, green: 0.74, blue: 0.78),
                vibrancy: 0.36
            )
        case .real:
            // 仅作占位；.real 走真实取色管线（palette(for:) 对 .real 返回 nil 触发真实计算）。
            return .fallback
        }
    }

    var lyrics: String? {
        switch self {
        case .cool:
            return nil
        case .quadrant:
            return """
            [00:00.00]上方红光应该停在封面上沿
            [00:08.00]右侧绿色要沿着玻璃空气散开
            [00:16.00]底部蓝色不能翻到上方
            [00:24.00]左侧黄色应轻轻裹住歌词卡边缘
            [00:32.00]当前行保持清晰，远处歌词进入景深
            [00:40.00]拖动时整屏解糊，停手后慢慢恢复
            [00:48.00]进度条和播放按钮只使用专辑主色
            [00:56.00]整窗底板应该像一块厚玻璃盖在色场上
            [01:04.00]彩色空气感来自封面方向，不来自脏灰雾
            [01:12.00]Reduce Motion 下所有新增动效保持克制
            [01:20.00]浅色与深色都要保持文字可读
            [01:28.00]播放暂停切换时颜色不能突然变灰
            """
        case .warm:
            return """
            [00:00.00]暖黄色从封面中心慢慢铺开
            [00:08.00]玻璃卡左侧只被轻轻照亮
            [00:16.00]当前歌词停在中心并保持清晰
            [00:24.00]上下歌词按距离淡出进入景深
            [00:32.00]背景不能被白雾洗成一块亮板
            [00:40.00]播放按钮延续专辑主色但要足够深
            [00:48.00]控制条和歌词卡应该像同一种玻璃
            [00:56.00]暂停时封面光由近到远慢慢收住
            """
        case .cream:
            return """
            [00:00.00]Soft cream colors stay clean and quiet
            [00:08.00]The lyric card keeps its glass edge
            [00:16.00]Center words remain crisp and close
            [00:24.00]Distant lines fade without turning muddy
            [00:32.00]Low color covers should not become pink
            [00:40.00]The background is paint, not desktop blur
            [00:48.00]Highlights lift the surface gently
            [00:56.00]Motion can stop while depth remains
            """
        case .black:
            return """
            [00:00.00]黑色区域只提供深度，不应该自己发光
            [00:08.00]青色亮线可以柔和照到玻璃边缘
            [00:16.00]金色小块只作为轻微环境色
            [00:24.00]底板需要仍像来自封面，而不是凭空换色
            [00:32.00]暗部不能被抬成灰脏的雾
            [00:40.00]玻璃受光应有专辑色，不是白光
            [00:48.00]暂停时封面光由近到远自然收束
            """
        case .whiteFrame:
            return """
            [00:00.00]近白外框不能把整页洗成灰白
            [00:08.00]浅蓝纸纹应成为干净的底板主色
            [00:16.00]黄色亮部只作为柔和环境光
            [00:24.00]歌词卡顶部光照要短距离收束
            [00:32.00]右侧边界可以有很弱的主色受光
            [00:40.00]玻璃应该透亮而不是一整块灰板
            """
        case .real:
            return """
            [00:00.00]真实封面发光诊断
            [00:08.00]左侧光应漫到歌词卡边缘
            [00:16.00]当前行保持清晰
            [00:24.00]底板不应发脏
            [00:32.00]控制栏应像取色玻璃
            """
        }
    }
}

enum MusicPlayerVisualDebugFixtures {
    static let quadrantCoverPath = MusicPlayerVisualDebugVariant.quadrant.coverPath
    static let debugTrackID = MusicPlayerVisualDebugVariant.quadrant.trackID
    static let debugDuration: Double = 246

    static func debugTrackURL(for variant: MusicPlayerVisualDebugVariant = .quadrant) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MediaLIBMusicVisualDebug-\(variant.rawValue).mp3")
    }

    static func debugLyricsURL(for variant: MusicPlayerVisualDebugVariant = .quadrant) -> URL {
        debugTrackURL(for: variant).deletingPathExtension().appendingPathExtension("lrc")
    }

    static var palette: AlbumColorPalette {
        MusicPlayerVisualDebugVariant.quadrant.palette
    }

    static func palette(for path: String?) -> AlbumColorPalette? {
        // .real 走真实取色管线：返回 nil 让 AlbumPaletteCache 从真实封面计算 palette。
        guard let v = variant(for: path), v != .real else { return nil }
        return v.palette
    }

    static func writeLyricsSidecar(for variant: MusicPlayerVisualDebugVariant = .quadrant) {
        let url = debugLyricsURL(for: variant)
        guard let lyrics = variant.lyrics else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? lyrics.write(to: url, atomically: true, encoding: .utf8)
    }

    static func makeItem(for variant: MusicPlayerVisualDebugVariant = .quadrant) -> MediaItem {
        MediaItem(
            id: variant.trackID,
            type: .music,
            title: variant.title,
            artist: variant.artist,
            album: variant.album,
            posterPath: variant.coverPath,
            filePath: debugTrackURL(for: variant).path,
            duration: debugDuration
        )
    }

    static func quadrantCoverImage(size: Int) -> NSImage? {
        guard let cgImage = coverCGImage(for: .quadrant, size: size) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    static func quadrantCoverCGImage(size: Int) -> CGImage? {
        coverCGImage(for: .quadrant, size: size)
    }

    static func coverImage(forPath path: String?, size: Int) -> NSImage? {
        guard let variant = variant(for: path),
              let cgImage = coverCGImage(for: variant, size: size) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    static func coverCGImage(forPath path: String?, size: Int) -> CGImage? {
        guard let variant = variant(for: path) else { return nil }
        return coverCGImage(for: variant, size: size)
    }

    static func variant(for path: String?) -> MusicPlayerVisualDebugVariant? {
        guard let path else { return nil }
        return MusicPlayerVisualDebugVariant.allCases.first { $0.coverPath == path }
    }

    private static func coverCGImage(for variant: MusicPlayerVisualDebugVariant, size: Int) -> CGImage? {
        // .real 不合成封面：返回 nil 让烘焙/底板回退到 ArtworkImageCache 加载真实封面文件。
        if variant == .real { return nil }
        if variant == .quadrant {
            return quadrantCoverCGImageBody(size: size)
        }
        return abstractCoverCGImage(for: variant, size: size)
    }

    private static func quadrantCoverCGImageBody(size: Int) -> CGImage? {
        let side = max(size, 32)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let half = CGFloat(side) * 0.5
        let full = CGFloat(side)
        let center = CGPoint(x: half, y: half)
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)

        func fill(_ color: NSColor, _ points: [CGPoint]) {
            guard let first = points.first else { return }
            context.beginPath()
            context.move(to: first)
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.closePath()
            context.setFillColor(color.cgColor)
            context.fillPath()
        }

        fill(.systemRed, [CGPoint(x: 0, y: 0), CGPoint(x: full, y: 0), center])
        fill(.systemGreen, [CGPoint(x: full, y: 0), CGPoint(x: full, y: full), center])
        fill(.systemBlue, [CGPoint(x: full, y: full), CGPoint(x: 0, y: full), center])
        fill(.systemYellow, [CGPoint(x: 0, y: full), CGPoint(x: 0, y: 0), center])
        return context.makeImage()
    }

    private static func abstractCoverCGImage(for variant: MusicPlayerVisualDebugVariant, size: Int) -> CGImage? {
        let side = max(size, 32)
        let full = CGFloat(side)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        func cg(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
            NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha).cgColor
        }

        func linear(_ colors: [CGColor], start: CGPoint, end: CGPoint) {
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) else { return }
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        func radial(_ colors: [CGColor], center: CGPoint, radius: CGFloat) {
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) else { return }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
        }

        switch variant {
        case .cool:
            linear(
                [cg(0.09, 0.16, 0.42), cg(0.20, 0.34, 0.82), cg(0.42, 0.26, 0.70)],
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: full, y: full)
            )
            radial([cg(0.26, 0.78, 0.92, 0.84), cg(0.26, 0.78, 0.92, 0)], center: CGPoint(x: full * 0.30, y: full * 0.30), radius: full * 0.64)
            radial([cg(0.72, 0.44, 0.86, 0.72), cg(0.72, 0.44, 0.86, 0)], center: CGPoint(x: full * 0.78, y: full * 0.74), radius: full * 0.58)
        case .warm:
            linear(
                [cg(0.98, 0.76, 0.22), cg(0.94, 0.44, 0.13), cg(0.54, 0.18, 0.10)],
                start: CGPoint(x: 0, y: full * 0.10),
                end: CGPoint(x: full, y: full)
            )
            radial([cg(1.00, 0.88, 0.30, 0.94), cg(1.00, 0.88, 0.30, 0)], center: CGPoint(x: full * 0.34, y: full * 0.28), radius: full * 0.66)
            radial([cg(0.92, 0.20, 0.10, 0.62), cg(0.92, 0.20, 0.10, 0)], center: CGPoint(x: full * 0.78, y: full * 0.74), radius: full * 0.62)
        case .cream:
            linear(
                [cg(0.86, 0.76, 0.67), cg(0.96, 0.82, 0.67), cg(0.68, 0.58, 0.72)],
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: full, y: full)
            )
            radial([cg(1.00, 0.84, 0.70, 0.50), cg(1.00, 0.84, 0.70, 0)], center: CGPoint(x: full * 0.28, y: full * 0.26), radius: full * 0.62)
            radial([cg(0.62, 0.56, 0.74, 0.36), cg(0.62, 0.56, 0.74, 0)], center: CGPoint(x: full * 0.80, y: full * 0.72), radius: full * 0.60)
        case .black:
            linear(
                [cg(0.006, 0.008, 0.012), cg(0.020, 0.022, 0.032), cg(0.004, 0.005, 0.008)],
                start: CGPoint(x: full * 0.10, y: 0),
                end: CGPoint(x: full, y: full)
            )
            radial([cg(0.00, 0.86, 0.96, 0.92), cg(0.00, 0.86, 0.96, 0.0)], center: CGPoint(x: full * 0.30, y: full * 0.24), radius: full * 0.22)
            radial([cg(1.00, 0.72, 0.20, 0.74), cg(1.00, 0.72, 0.20, 0.0)], center: CGPoint(x: full * 0.73, y: full * 0.58), radius: full * 0.18)
            radial([cg(0.70, 0.26, 0.95, 0.52), cg(0.70, 0.26, 0.95, 0.0)], center: CGPoint(x: full * 0.56, y: full * 0.80), radius: full * 0.16)
            context.setStrokeColor(cg(0.00, 0.88, 0.96, 0.86))
            context.setLineWidth(max(2, full * 0.030))
            context.move(to: CGPoint(x: full * 0.18, y: full * 0.70))
            context.addLine(to: CGPoint(x: full * 0.42, y: full * 0.18))
            context.strokePath()
        case .whiteFrame:
            context.setFillColor(cg(0.98, 0.985, 0.97))
            context.fill(CGRect(x: 0, y: 0, width: full, height: full))
            let inset = full * 0.105
            let contentRect = CGRect(x: inset, y: inset, width: full - inset * 2, height: full - inset * 2)
            context.saveGState()
            context.clip(to: contentRect)
            linear(
                [cg(0.70, 0.91, 0.96), cg(0.50, 0.78, 0.88), cg(0.80, 0.90, 0.88)],
                start: CGPoint(x: contentRect.minX, y: contentRect.minY),
                end: CGPoint(x: contentRect.maxX, y: contentRect.maxY)
            )
            radial(
                [cg(1.00, 0.80, 0.13, 0.94), cg(1.00, 0.80, 0.13, 0.0)],
                center: CGPoint(x: full * 0.38, y: full * 0.52),
                radius: full * 0.22
            )
            radial(
                [cg(0.68, 0.92, 0.98, 0.58), cg(0.68, 0.92, 0.98, 0.0)],
                center: CGPoint(x: full * 0.26, y: full * 0.22),
                radius: full * 0.48
            )
            context.setStrokeColor(cg(0.18, 0.20, 0.23, 0.40))
            context.setLineWidth(max(1, full * 0.010))
            context.move(to: CGPoint(x: contentRect.maxX * 0.92, y: contentRect.minY + full * 0.06))
            context.addLine(to: CGPoint(x: contentRect.maxX * 0.95, y: contentRect.maxY - full * 0.10))
            context.strokePath()
            context.restoreGState()
        case .quadrant, .real:
            break
        }

        context.setBlendMode(.softLight)
        linear(
            [cg(1, 1, 1, 0.28), cg(1, 1, 1, 0.02), cg(0, 0, 0, 0.22)],
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: full, y: full)
        )
        return context.makeImage()
    }
}
#endif

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

    /// 业务 → 主题 的统一接口（R1）。每次 body 重算时从宿主 `@State` 直接构造，
    /// 把原先散落传给湖光的 15 个入参收敛成一个与主题无关的载体。
    /// 与改前逐参一一对应（含派生 artworkReady / entranceReady），行为等价。
    private var playbackContext: MusicPlaybackContext {
        MusicPlaybackContext(
            item: currentItem,
            palette: albumPalette,
            lyrics: lyrics,
            timedLyrics: timedLyrics,
            lyricTimingSource: lyricTimingSource,
            hasDisplayLyrics: hasDisplayLyrics,
            isFetchingLyrics: isFetchingLyrics,
            coverGlowEnabled: appState.settings.musicAlbumCoverGlowEnabled,
            artworkReady: glassLayerReady,
            entranceReady: reduceMotion || entrancePhase >= 1,
            entrancePhase: entrancePhase,
            reduceMotion: reduceMotion,
            colorScheme: colorScheme,
            userIsBrowsingLyrics: $userIsBrowsingLyrics,
            controller: controller,
            fetchLyrics: { Task { await fetchLyrics() } },
            requestMinimize: onRequestMinimize,
            pauseLyricAutoScroll: pauseLyricAutoScroll
        )
    }

    var body: some View {
        // 整窗底层由 MusicExpandedStage 内部的 MetalAlbumBackdropView 铺满：
        // 它是一块覆盖标题栏区域的【不透明】专辑取色底（符合原方案"第一层不透明"）。
        // 性能根因修复：之前用 behindWindow 整窗毛玻璃会让 WindowServer 为整窗持有一份模糊后的桌面副本，
        // 内存飙到 400M+ 并拖累系统。改为不透明底色后 WindowServer 不再做整窗离屏模糊；磨砂质感由上层
        // 歌词卡/控制栏的局部 material 提供（局部、面积小，开销可控）。底色不透明也彻底盖住标题栏白条。
        ZStack {
            // 主题渲染子树按 musicThemeRevision 重建：用户在设置里「重新加载 / 恢复默认」主题参数后
            // bump 该值即可让主题层重新读取 MusicThemeConfig.active（无需重启）。.id 只套在两个 Stage 上、
            // 不套在带 onAppear 的 ZStack 上——故宿主已加载的歌词/取色/入场状态保留，不会重放入场或重拉歌词。
            Group {
                if isShelf {
                    // 书架方案：完全隔离的根视图，自带底板/书架/歌词/进度/音量；
                    // 复用 MusicPlayerView 已加载的歌词与取色（经下面的 .onAppear/.onChange 维护）。
                    MusicShelfPlayerStage(context: playbackContext)
                } else {
                    MusicExpandedStage(context: playbackContext, variant: isWujie ? .wujie : .liuli, transitionNamespace: transitionNamespace)
                }
            }
            .id(appState.musicThemeRevision)
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
            resetLyricPlaybackViewportState()
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
            RawKeyCaptureView { key in
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

    private var isWujie: Bool {
        appState.settings.musicPlayerVisualScheme == .wujie
    }

    /// 书架方案（第三款主题）：整窗换成完全隔离的 `MusicShelfPlayerStage`，
    /// 琉璃/无界（`MusicExpandedStage` 内含 `isWujie` 全部逻辑）一字不改。详见 MusicShelfPlayerView.swift。
    private var isShelf: Bool {
        appState.settings.musicPlayerVisualScheme == .shelf
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

    private func resetLyricPlaybackViewportState() {
        resumeAutoScrollTask?.cancel()
        lyricsAlignmentTask?.cancel()
        userIsBrowsingLyrics = false
        lyricTimingSource = .estimated
        timedLyrics = []
        lyrics = "暂无歌词"
    }

    private func scheduleLyricAlignmentIfNeeded(lyricsText: String, parsedLines: [TimedLyricLine]) {
        let algorithm = appState.settings.lyricSyncAlgorithm
        guard algorithm.usesBackgroundAlignment,
              TimedLyricLine.bestTimingSource(in: parsedLines) == .estimated,
              !parsedLines.isEmpty,
              let filePath = currentItem.filePath,
              !currentItem.isRemoteResource else { return }

        let targetItem = currentItem
        lyricsAlignmentTask = Task {
            guard await MusicLyricsLoader.localFileExists(atPath: filePath),
                  !Task.isCancelled else { return }
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
            let text = await MusicLyricsLoader.loadLyrics(for: targetItem)
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
            // 重型 SwiftUI blur 已经迁到后台预烘焙贴图；首帧挂载能避免展开完成后再插入图层造成断层和拖动峰值。
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
                try await Task.sleep(nanoseconds: MusicPlayerVisualTokens.Lyrics.browseFallbackResumeDelay)
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

#if DEBUG
struct MusicPlayerVisualDebugHarness: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var controller = MpvPlayerController()
    @Namespace private var namespace
    @State private var item: MediaItem?
    @State private var playbackTask: Task<Void, Never>?
    @State private var snapshotTask: Task<Void, Never>?
    private let variant = MusicPlayerVisualDebugVariant.fromArguments

    var body: some View {
        Group {
            if let item {
                MusicPlayerView(
                    item: item,
                    controller: controller,
                    transitionNamespace: namespace,
                    onRequestMinimize: {}
                )
                .environmentObject(appState)
            } else {
                ZStack {
                    variant.palette.backdropBaseColor(for: .dark)
                        .ignoresSafeArea()
                    ProgressView("正在准备 \(variant.title)")
                        .controlSize(.large)
                }
            }
        }
        .background {
            MusicPlayerVisualDebugWindowSizer()
                .allowsHitTesting(false)
        }
        .onAppear(perform: prepare)
        .onDisappear {
            playbackTask?.cancel()
            playbackTask = nil
            snapshotTask?.cancel()
            snapshotTask = nil
            if appState.activePlayerItem?.id == variant.trackID {
                appState.activePlayerItem = nil
            }
        }
    }

    @MainActor
    private func prepare() {
        // 调试预览：--music-scheme-wujie 强制使用「无界」方案，便于本地截图核对（仅 DEBUG）。
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--music-scheme-wujie") {
            appState.settings.musicPlayerVisualScheme = .wujie
        } else if arguments.contains("--music-scheme-liuli") {
            appState.settings.musicPlayerVisualScheme = .liuli
        } else if arguments.contains("--music-scheme-shelf") {
            appState.settings.musicPlayerVisualScheme = .shelf
        }
        MusicPlayerVisualDebugFixtures.writeLyricsSidecar(for: variant)
        let debugItem = MusicPlayerVisualDebugFixtures.makeItem(for: variant)
        appState.activePlayerItem = debugItem
        item = debugItem
        // 书架方案预览：合成一条多封面队列（已播放在左·当前居中·待播在右），便于本地截图核对整排书架。
        if appState.settings.musicPlayerVisualScheme == .shelf {
            // 合成一条较长的队列（封面按 posterPath 解析，复制项用唯一 id 即可），便于核对整排书架铺开。
            let rackVariants: [MusicPlayerVisualDebugVariant] = [.cool, .warm, .cream, .black, .whiteFrame, .quadrant]
            var queue: [MediaItem] = (0..<45).map { i in
                let v = rackVariants[i % rackVariants.count]
                let base = MusicPlayerVisualDebugFixtures.makeItem(for: v)
                return MediaItem(
                    id: "\(base.id)-shelf\(i)",
                    type: .music,
                    title: base.title,
                    artist: base.artist,
                    album: base.album,
                    posterPath: base.posterPath,
                    filePath: base.filePath,
                    duration: base.duration
                )
            }
            // 把当前播放项放到队列中段，使两侧都能看到。
            queue[22] = debugItem
            appState.musicQueue = queue
        }
        startPlaybackLoop()
        scheduleDebugSnapshotIfNeeded()
    }

    @MainActor
    private func startPlaybackLoop() {
        playbackTask?.cancel()
        let duration = MusicPlayerVisualDebugFixtures.debugDuration
        let startTime = Date().timeIntervalSinceReferenceDate - 28
        let previewPaused = ProcessInfo.processInfo.arguments.contains("--shelf-preview-paused")
        playbackTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSinceReferenceDate - startTime
                let currentTime = previewPaused ? 28 : elapsed.truncatingRemainder(dividingBy: duration)
                controller.injectMusicVisualDebugState(
                    currentTime: currentTime,
                    duration: duration,
                    isPlaying: !previewPaused
                )
                do {
                    try await Task.sleep(nanoseconds: 180_000_000)
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    private func scheduleDebugSnapshotIfNeeded() {
        snapshotTask?.cancel()
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--music-visual-debug-snapshot") else { return }
        let outputDirectory = Self.snapshotOutputDirectory(arguments: arguments)
        let delay = Self.snapshotDelay(arguments: arguments)
        snapshotTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let fileName = Self.snapshotFileName(arguments: arguments, variant: variant)
            if let url = renderDebugSnapshot(outputDirectory: outputDirectory, fileName: fileName) {
                print("MediaLIB debug snapshot written: \(url.path)")
            } else {
                print("MediaLIB debug snapshot failed")
            }
            if arguments.contains("--music-visual-debug-exit") {
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    private func renderDebugSnapshot(outputDirectory: URL, fileName: String) -> URL? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
              let contentView = window.contentView,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let url = outputDirectory.appendingPathComponent(fileName)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            print("MediaLIB debug snapshot write error: \(error)")
            return nil
        }
    }

    private static func snapshotOutputDirectory(arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: "--music-visual-debug-output"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let value = ProcessInfo.processInfo.environment["MEDIALIB_MUSIC_VISUAL_DEBUG_OUTPUT"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("music-visual-debug", isDirectory: true)
    }

    private static func snapshotDelay(arguments: [String]) -> Double {
        if let index = arguments.firstIndex(of: "--music-visual-debug-delay"),
           arguments.indices.contains(index + 1),
           let value = Double(arguments[index + 1]) {
            return max(0.2, value)
        }
        return 1.8
    }

    private static func snapshotFileName(arguments: [String], variant: MusicPlayerVisualDebugVariant) -> String {
        if let index = arguments.firstIndex(of: "--music-visual-debug-name"),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            return arguments[index + 1].hasSuffix(".png") ? arguments[index + 1] : "\(arguments[index + 1]).png"
        }
        let scheme = arguments.contains("--music-scheme-shelf") ? "shelf" :
            (arguments.contains("--music-scheme-wujie") ? "wujie" : "liuli")
        return "MediaLIB_\(scheme)_\(variant.rawValue)_debug.png"
    }
}

private struct MusicPlayerVisualDebugWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            resizeWindow(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            resizeWindow(from: nsView)
        }
    }

    private func resizeWindow(from view: NSView) {
        guard let window = view.window else { return }
        let target = NSSize(width: 1280, height: 800)
        if abs(window.contentView?.bounds.width ?? 0 - target.width) > 2 ||
            abs(window.contentView?.bounds.height ?? 0 - target.height) > 2 {
            window.setContentSize(target)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

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

struct AlbumGlobalGlassVeil: View {
    let palette: AlbumColorPalette
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            AppKitVisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow)
                .opacity(colorScheme == .dark ? 0.18 : 0.16)

            Rectangle()
                .fill((colorScheme == .dark ? Color.black : Color.white).opacity(colorScheme == .dark ? 0.056 : 0.038))

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.060 : 0.062),
                    Color.white.opacity(colorScheme == .dark ? 0.020 : 0.020),
                    Color.black.opacity(colorScheme == .dark ? 0.066 : 0.006)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    palette.glowPrimary.color.opacity(colorScheme == .dark ? 0.070 : 0.046),
                    .clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 760
            )

            FrostedGlassTextureOverlay(opacity: colorScheme == .dark ? 0.010 : 0.012)
        }
        .allowsHitTesting(false)
    }
}

private struct SendableAlbumBackdropImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

// MARK: - 真·封面发光（iTunes/Apple Music 式：放大封面 + 重高斯模糊 + 边缘羽化，铺在封面正后方）

/// 把专辑封面本身放大到 ~2x、做重高斯模糊、并把边缘羽化成透明，铺在清晰封面的正后方。
/// 封面的真实颜色因此向四周柔和溢出，看起来"封面在发光"。不做低频色场/亮度门控等复杂处理——
/// 就是参考图里那种"封面底部叠一张模糊大封面"的直接做法。烘焙成静态图缓存，运行期只贴图，零逐帧成本。
struct AlbumGlowBlurCover: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let posterPath: String?
    let controller: MpvPlayerController
    /// 发光画布边长（= 清晰封面边长 × 几何 reach，光程刚好触达歌词卡左缘 / 控制栏并略超出）。
    let displaySide: CGFloat
    /// 真实封面显示边长：烘焙时据此对齐光源矩形与真实封面。
    let coverSide: CGFloat
    let coverGlowEnabled: Bool
    let intensity: Double
    let saturation: Double
    @StateObject private var playbackObserver: MusicMiniTransportStateObserver
    @State private var image: NSImage?
    @State private var loadedKey: String = ""
    @State private var glowOpacity: Double = 1
    @State private var glowScale: Double = 1
    @State private var farCollapseTask: Task<Void, Never>?

    init(
        posterPath: String?,
        controller: MpvPlayerController,
        displaySide: CGFloat,
        coverSide: CGFloat,
        coverGlowEnabled: Bool,
        intensity: Double = 1.0,
        saturation: Double = 1.0
    ) {
        self.posterPath = posterPath
        self.controller = controller
        self.displaySide = displaySide
        self.coverSide = coverSide
        self.coverGlowEnabled = coverGlowEnabled
        self.intensity = intensity
        self.saturation = saturation
        _playbackObserver = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    private var bakeKey: String {
        "blurred-cover-projection-v7|\(posterPath ?? "")|\(Int(displaySide.rounded()))|\(Int(coverSide.rounded()))"
    }

    var body: some View {
        let isPlaying = playbackObserver.state.isPlaying
        ZStack {
            if coverGlowEnabled, let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: displaySide, height: displaySide)
                    .saturation(saturation)
                    .opacity(glowOpacity * intensity * (colorScheme == .dark ? 0.82 : 0.78))
                    .scaleEffect(glowScale)
                    .blendMode(.normal)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: displaySide, height: displaySide)
                    .saturation(saturation)
                    .opacity(glowOpacity * intensity * (colorScheme == .dark ? 0.46 : 0.38))
                    .scaleEffect(glowScale)
                    .blendMode(.screen)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: displaySide, height: displaySide)
                    .saturation(saturation)
                    .opacity(glowOpacity * intensity * (colorScheme == .dark ? 0.13 : 0.095))
                    .scaleEffect(glowScale)
                    .blendMode(.plusLighter)
            }
        }
        .frame(width: displaySide, height: displaySide)
        .allowsHitTesting(false)
        .task(id: bakeKey) {
            await load()
        }
        .onAppear { applyPlayback(isPlaying: isPlaying, animated: false) }
        .onChange(of: isPlaying) { playing in
            applyPlayback(isPlaying: playing, animated: true)
        }
        .onDisappear { farCollapseTask?.cancel() }
    }

    /// 暂停时发光收回封面底下的目标 scale：略小于"暂停后缩小的封面"（封面暂停缩到 0.912），
    /// 让模糊大封面完全藏进清晰封面下方，不留出血边。
    private var tuckedScale: Double {
        guard displaySide > 1, coverSide > 1 else { return 0.28 }
        return Double(coverSide / displaySide) * 0.88
    }

    /// 播放：光快速升起铺满；暂停：光由近及远收拢——先收一半，再整体缩到封面底下并熄灭。
    private func applyPlayback(isPlaying: Bool, animated: Bool) {
        farCollapseTask?.cancel()
        guard animated, !reduceMotion else {
            glowOpacity = isPlaying ? 1.0 : 0.0
            glowScale = isPlaying ? 1.0 : tuckedScale
            return
        }
        if isPlaying {
            withAnimation(.easeOut(duration: 0.32)) {
                glowOpacity = 1.0
                glowScale = 1.0
            }
        } else {
            let tuck = tuckedScale
            withAnimation(.easeInOut(duration: 0.26)) {
                glowScale = min(tuck * 1.9, 0.62)
                glowOpacity = 0.42
            }
            farCollapseTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 220_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.40)) {
                    glowScale = tuck
                    glowOpacity = 0.0
                }
            }
        }
    }

    @MainActor
    private func load() async {
        guard coverGlowEnabled else { return }
        let key = bakeKey
        guard key != loadedKey || image == nil else { return }
        let path = posterPath
        let side = displaySide
        let fraction = coverSide > 1 && displaySide > 1 ? coverSide / displaySide : 0.3
        let baked = await Task.detached(priority: .userInitiated) {
            SendableAlbumBackdropImage(AlbumGlowBlurCoverBaker.bake(path: path, displaySide: side, coverFraction: fraction))
        }.value
        guard !Task.isCancelled else { return }
        image = baked.image
        loadedKey = key
    }
}

private enum AlbumGlowBlurCoverBaker {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let cacheLock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static var order: [String] = []
    private static let maxEntries = 8

    /// 封面发光烘焙：
    /// 物理模型 = 清晰封面下方垫一张“清洗后的封面副本”，再做重高斯模糊。
    /// 边缘仍参与，但白/灰边缘低权重；彩色中心与彩色边缘共同扩散，避免白边抢光和竖向光柱。
    /// - `coverFraction`：真实封面边长 / 发光画布边长（光程由几何 reach 决定）。
    static func bake(path: String?, displaySide: CGFloat, coverFraction: CGFloat) -> NSImage? {
        guard let path, !path.isEmpty, displaySide > 8 else { return nil }
        let fraction = min(max(coverFraction, 0.10), 0.90)
        let pixelSide = max(224, min(Int((displaySide * 0.70).rounded()), 1152))
        let key = "blurred-cover-projection-v7|\(path)|\(pixelSide)|\(Int((fraction * 100).rounded()))"
        cacheLock.lock()
        if let cached = cache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        guard let cover = loadCover(path: path) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(pixelSide), height: CGFloat(pixelSide))
        let coverSide = CGFloat(pixelSide) * fraction
        let coverRect = CGRect(
            x: (CGFloat(pixelSide) - coverSide) * 0.5,
            y: (CGFloat(pixelSide) - coverSide) * 0.5,
            width: coverSide,
            height: coverSide
        )

        guard let emissionSeed = makeEmissionSeed(cover: cover, pixelSide: pixelSide, coverRect: coverRect) else { return nil }
        debugWrite(emissionSeed, name: "01-seed", sourcePath: path, rect: canvas)

        // 多层真实封面投影：近场保留"底下还有一张大封面"的空间色彩，
        // 远场再负责柔化扩散。这样不会被平均成单色阴影。
        guard let lowFrequencyEmission = makeDistanceBlurredGlowField(seed: emissionSeed, pixelSide: pixelSide, coverRect: coverRect) else {
            return nil
        }
        debugWrite(lowFrequencyEmission, name: "02-low-frequency", sourcePath: path, rect: canvas)

        let directionalLight = lowFrequencyEmission
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(coverSide) * 0.085])
            .cropped(to: canvas)
        debugWrite(directionalLight, name: "03-light-field", sourcePath: path, rect: canvas)

        // R3：发光大封面副本提饱和 + 略增对比，让封面发光更绚丽不发灰（保色相，仍是封面本色）。
        let glowColor = directionalLight
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.14,
                kCIInputBrightnessKey: 0.004,
                kCIInputContrastKey: 0.98
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.0])
            .cropped(to: canvas)

        // 此时的图像就是一张柔化后的封面副本；运行期只负责贴图和播放/暂停淡入淡出。
        let feathered = applyCanvasEdgeFade(glowColor, pixelSide: pixelSide)
        debugWrite(feathered, name: "04-final", sourcePath: path, rect: canvas)

        guard let cg = ciContext.createCGImage(feathered, from: canvas) else { return nil }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: displaySide, height: displaySide))
        cacheLock.lock()
        cache[key] = nsImage
        order.append(key)
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cacheLock.unlock()
        return nsImage
    }

    private nonisolated static func makeCleanProjectionSource(cover: CGImage, pixelSide: Int) -> CIImage? {
        let n = max(pixelSide, 1)
        let bytesPerPixel = 4
        let bytesPerRow = n * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: n * n * bytesPerPixel)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: n,
                    height: n,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return }
            context.interpolationQuality = .high
            let src = CGSize(width: cover.width, height: cover.height)
            let scale = max(CGFloat(n) / max(src.width, 1), CGFloat(n) / max(src.height, 1))
            let drawSize = CGSize(width: src.width * scale, height: src.height * scale)
            let drawRect = CGRect(
                x: (CGFloat(n) - drawSize.width) * 0.5,
                y: (CGFloat(n) - drawSize.height) * 0.5,
                width: drawSize.width,
                height: drawSize.height
            )
            context.draw(cover, in: drawRect)
        }

        var weightedRed = 0.0
        var weightedGreen = 0.0
        var weightedBlue = 0.0
        var chromaWeightSum = 0.0
        var fallbackRed = 0.0
        var fallbackGreen = 0.0
        var fallbackBlue = 0.0
        var fallbackWeight = 0.0

        for y in 0..<n {
            for x in 0..<n {
                let index = (y * n + x) * bytesPerPixel
                let alpha = max(Double(pixels[index + 3]) / 255, 0.0001)
                let red = min(max((Double(pixels[index]) / 255) / alpha, 0), 1)
                let green = min(max((Double(pixels[index + 1]) / 255) / alpha, 0), 1)
                let blue = min(max((Double(pixels[index + 2]) / 255) / alpha, 0), 1)
                let maxComponent = max(red, green, blue)
                let minComponent = min(red, green, blue)
                let chroma = maxComponent - minComponent
                let saturation = maxComponent > 0.001 ? chroma / maxComponent : 0
                let value = maxComponent
                let chromaWeight = smoothstep(edge0: 0.035, edge1: 0.22, value: chroma) *
                    max(smoothstep(edge0: 0.08, edge1: 0.42, value: saturation), smoothstep(edge0: 0.10, edge1: 0.42, value: value) * 0.35)
                let darkColorWeight = smoothstep(edge0: 0.035, edge1: 0.18, value: chroma) *
                    smoothstep(edge0: 0.20, edge1: 0.62, value: saturation) *
                    (1 - smoothstep(edge0: 0.50, edge1: 0.90, value: value)) *
                    0.40
                let weight = max(chromaWeight, darkColorWeight) * alpha
                weightedRed += red * weight
                weightedGreen += green * weight
                weightedBlue += blue * weight
                chromaWeightSum += weight

                let fallback = alpha * (0.12 + value * 0.12)
                fallbackRed += red * fallback
                fallbackGreen += green * fallback
                fallbackBlue += blue * fallback
                fallbackWeight += fallback
            }
        }

        let globalRed: Double
        let globalGreen: Double
        let globalBlue: Double
        if chromaWeightSum > 0.001 {
            globalRed = weightedRed / chromaWeightSum
            globalGreen = weightedGreen / chromaWeightSum
            globalBlue = weightedBlue / chromaWeightSum
        } else if fallbackWeight > 0.001 {
            globalRed = fallbackRed / fallbackWeight
            globalGreen = fallbackGreen / fallbackWeight
            globalBlue = fallbackBlue / fallbackWeight
        } else {
            globalRed = 0.5
            globalGreen = 0.5
            globalBlue = 0.5
        }

        for y in 0..<n {
            for x in 0..<n {
                let index = (y * n + x) * bytesPerPixel
                let alpha = max(Double(pixels[index + 3]) / 255, 0.0001)
                let red = min(max((Double(pixels[index]) / 255) / alpha, 0), 1)
                let green = min(max((Double(pixels[index + 1]) / 255) / alpha, 0), 1)
                let blue = min(max((Double(pixels[index + 2]) / 255) / alpha, 0), 1)
                let maxComponent = max(red, green, blue)
                let minComponent = min(red, green, blue)
                let chroma = maxComponent - minComponent
                let saturation = maxComponent > 0.001 ? chroma / maxComponent : 0
                let value = maxComponent
                let colorWeight = smoothstep(edge0: 0.045, edge1: 0.24, value: chroma) *
                    max(smoothstep(edge0: 0.10, edge1: 0.45, value: saturation), smoothstep(edge0: 0.08, edge1: 0.35, value: value) * 0.35)
                let brightNeutral = smoothstep(edge0: 0.70, edge1: 0.98, value: value) *
                    (1 - smoothstep(edge0: 0.025, edge1: 0.12, value: chroma))
                let darkNeutral = (1 - smoothstep(edge0: 0.10, edge1: 0.28, value: value)) *
                    (1 - smoothstep(edge0: 0.030, edge1: 0.16, value: chroma))
                let originalMix = min(max(0.18 + colorWeight * 0.82 - brightNeutral * 0.16 - darkNeutral * 0.08, 0.10), 1.0)
                let mixedRed = globalRed * (1 - originalMix) + red * originalMix
                let mixedGreen = globalGreen * (1 - originalMix) + green * originalMix
                let mixedBlue = globalBlue * (1 - originalMix) + blue * originalMix
                let hsv = rgbToHSV(red: mixedRed, green: mixedGreen, blue: mixedBlue)
                let cleanedSaturation = min(max(hsv.saturation * (1.08 + colorWeight * 0.18), 0.08 + colorWeight * 0.22), 0.92)
                let cleanedValue = min(max(pow(max(hsv.value, 0), 0.86) * (0.92 + colorWeight * 0.16), 0.18), 0.98)
                let cleaned = hsvToRGB(hue: hsv.hue, saturation: cleanedSaturation, value: cleanedValue)
                pixels[index] = UInt8(min(max(cleaned.red * 255, 0), 255))
                pixels[index + 1] = UInt8(min(max(cleaned.green * 255, 0), 255))
                pixels[index + 2] = UInt8(min(max(cleaned.blue * 255, 0), 255))
                pixels[index + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: n,
                height: n,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private nonisolated static func applyProjectionFalloff(_ image: CIImage, pixelSide: Int, coverRect: CGRect) -> CIImage? {
        let n = max(pixelSide, 1)
        let bytesPerPixel = 4
        let bytesPerRow = n * bytesPerPixel
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n))
        guard let cgImage = ciContext.createCGImage(image, from: canvas) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var source = [UInt8](repeating: 0, count: n * n * bytesPerPixel)
        source.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: n,
                    height: n,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return }
            context.clear(canvas)
            context.interpolationQuality = .high
            context.draw(cgImage, in: canvas)
        }

        var output = [UInt8](repeating: 0, count: n * n * bytesPerPixel)
        let halfSide = max(Double(coverRect.width) * 0.5, 1)
        let reach = max(Double(n) * 0.5 - halfSide, 1)
        for y in 0..<n {
            let py = Double(y) + 0.5
            for x in 0..<n {
                let px = Double(x) + 0.5
                let projectedX = min(max(px, Double(coverRect.minX)), Double(coverRect.maxX))
                let projectedY = min(max(py, Double(coverRect.minY)), Double(coverRect.maxY))
                let outsideDistance = hypot(px - projectedX, py - projectedY)
                let normalizedDistance = min(max(outsideDistance / reach, 0), 1)
                let edgeDistance = min(min(px, Double(n) - px), min(py, Double(n) - py))
                let canvasFade = smoothstep(edge0: Double(n) * 0.006, edge1: Double(n) * 0.32, value: edgeDistance)
                let distanceWindow = max(1 - smoothstep(edge0: 0.82, edge1: 1.0, value: normalizedDistance), 0)
                let falloff = exp(-pow(normalizedDistance * 1.28, 1.78)) * distanceWindow * canvasFade
                let noise = ditherNoise(x: x, y: y) * (1.0 / 255.0)
                let index = (y * n + x) * bytesPerPixel
                let sourceAlpha = Double(source[index + 3]) / 255
                let alpha = min(max(sourceAlpha * falloff * 1.18, 0), 0.86)
                guard alpha > 0.0015 else { continue }
                let red = min(max((Double(source[index]) / 255) / max(sourceAlpha, 0.0001) + noise, 0), 1)
                let green = min(max((Double(source[index + 1]) / 255) / max(sourceAlpha, 0.0001) + noise, 0), 1)
                let blue = min(max((Double(source[index + 2]) / 255) / max(sourceAlpha, 0.0001) + noise, 0), 1)
                output[index] = UInt8(min(max(red * alpha * 255, 0), 255))
                output[index + 1] = UInt8(min(max(green * alpha * 255, 0), 255))
                output[index + 2] = UInt8(min(max(blue * alpha * 255, 0), 255))
                output[index + 3] = UInt8(min(max(alpha * 255, 0), 255))
            }
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let cgImage = CGImage(
                width: n,
                height: n,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private nonisolated static func makeDistanceBlurredGlowField(seed: CIImage, pixelSide: Int, coverRect: CGRect) -> CIImage? {
        let n = max(pixelSide, 1)
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n))
        let centerX = coverRect.midX
        let centerY = coverRect.midY
        let transparent = CIImage(color: .clear).cropped(to: canvas)

        let sourceFraction = min(max(coverRect.width / max(canvas.width, 1), 0.065), 0.72)

        func projectedLayer(
            targetFraction: CGFloat,
            radiusFraction: Double,
            strength: Double,
            saturation: Double,
            brightness: Double = 0.0
        ) -> CIImage {
            let target = min(max(targetFraction, sourceFraction), 1.35)
            let scale = min(max(target / sourceFraction, 1.0), 14.0)
            let blurRadius = max(Double(n) * Double(target) * radiusFraction, 1.0)
            let transform = CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: scale,
                tx: centerX * (1 - scale),
                ty: centerY * (1 - scale)
            )
            return attenuate(
                seed
                    .transformed(by: transform)
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                    .cropped(to: canvas)
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputSaturationKey: saturation,
                        kCIInputBrightnessKey: brightness,
                        kCIInputContrastKey: 1.0
                    ]),
                amount: strength
            )
        }

        // 近场必须像“底下还有一张被重度虚化的封面”，不能只是一圈阴影。
        // targetFraction 以整张发光画布计，按比例放大 seed，确保不同窗口和光程下投影仍有可见图像结构。
        let farAura = projectedLayer(targetFraction: 1.22, radiusFraction: 0.22, strength: 0.28, saturation: 0.98, brightness: 0.002)
        let broadProjection = projectedLayer(targetFraction: 0.96, radiusFraction: 0.115, strength: 0.48, saturation: 1.02)
        let coverProjection = projectedLayer(targetFraction: 0.72, radiusFraction: 0.058, strength: 0.76, saturation: 1.08)
        let contactProjection = projectedLayer(targetFraction: 0.42, radiusFraction: 0.026, strength: 0.44, saturation: 1.06)

        let combined = contactProjection
            .composited(over: coverProjection)
            .composited(over: broadProjection)
            .composited(over: farAura)
            .composited(over: transparent)
            .cropped(to: canvas)

        return combined
    }

    private nonisolated static func attenuate(_ image: CIImage, amount: Double) -> CIImage {
        let a = min(max(amount, 0), 1)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)
        ])
    }

    private nonisolated static func applyCanvasEdgeFade(_ image: CIImage, pixelSide: Int) -> CIImage {
        let n = max(pixelSide, 1)
        let bytesPerPixel = 4
        let bytesPerRow = n * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: n * n * bytesPerPixel)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let inner = Double(n) * 0.42
        let outer = Double(n) * 0.012

        for y in 0..<n {
            let py = Double(y) + 0.5
            for x in 0..<n {
                let px = Double(x) + 0.5
                let edgeDistance = min(min(px, Double(n) - px), min(py, Double(n) - py))
                let baseFactor = smoothstep(edge0: outer, edge1: inner, value: edgeDistance)
                let factor = baseFactor * baseFactor * (3 - 2 * baseFactor)
                let byte = UInt8(min(max(factor * 255, 0), 255))
                let index = (y * n + x) * bytesPerPixel
                pixels[index] = byte
                pixels[index + 1] = byte
                pixels[index + 2] = byte
                pixels[index + 3] = byte
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgMask = CGImage(
                width: n,
                height: n,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ),
              let filter = CIFilter(name: "CIBlendWithAlphaMask") else {
            return image
        }

        let canvas = CGRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n))
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIImage(color: .clear).cropped(to: canvas), forKey: kCIInputBackgroundImageKey)
        filter.setValue(CIImage(cgImage: cgMask), forKey: kCIInputMaskImageKey)
        return (filter.outputImage ?? image).cropped(to: canvas)
    }

    private nonisolated static func makeEmissionSeed(cover: CGImage, pixelSide: Int, coverRect: CGRect) -> CIImage? {
        let n = max(pixelSide, 1)
        let bytesPerPixel = 4
        let bytesPerRow = n * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: n * n * bytesPerPixel)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: n,
                    height: n,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return }
            context.clear(CGRect(x: 0, y: 0, width: n, height: n))
            context.interpolationQuality = .high
            context.saveGState()
            context.clip(to: coverRect)
            let src = CGSize(width: cover.width, height: cover.height)
            let scale = max(coverRect.width / max(src.width, 1), coverRect.height / max(src.height, 1))
            let drawSize = CGSize(width: src.width * scale, height: src.height * scale)
            let drawRect = CGRect(
                x: coverRect.midX - drawSize.width * 0.5,
                y: coverRect.midY - drawSize.height * 0.5,
                width: drawSize.width,
                height: drawSize.height
            )
            context.draw(cover, in: drawRect)
            context.restoreGState()
        }

        let minX = max(Int(floor(coverRect.minX)), 0)
        let maxX = min(Int(ceil(coverRect.maxX)), n)
        let minY = max(Int(floor(coverRect.minY)), 0)
        let maxY = min(Int(ceil(coverRect.maxY)), n)

        for y in 0..<n {
            for x in 0..<n {
                let index = (y * n + x) * bytesPerPixel
                guard x >= minX, x < maxX, y >= minY, y < maxY else {
                    pixels[index] = 0
                    pixels[index + 1] = 0
                    pixels[index + 2] = 0
                    pixels[index + 3] = 0
                    continue
                }

                let alpha = Double(pixels[index + 3]) / 255
                guard alpha > 0.01 else {
                    pixels[index] = 0
                    pixels[index + 1] = 0
                    pixels[index + 2] = 0
                    pixels[index + 3] = 0
                    continue
                }

                let red = min(max((Double(pixels[index]) / 255) / alpha, 0), 1)
                let green = min(max((Double(pixels[index + 1]) / 255) / alpha, 0), 1)
                let blue = min(max((Double(pixels[index + 2]) / 255) / alpha, 0), 1)
                let maxComponent = max(red, green, blue)
                let minComponent = min(red, green, blue)
                let chroma = maxComponent - minComponent
                let saturation = maxComponent > 0.001 ? chroma / maxComponent : 0
                let value = maxComponent

                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                let innerEdgeDistance = min(
                    min(px - Double(minX), Double(maxX) - px),
                    min(py - Double(minY), Double(maxY) - py)
                )
                let interiorWeight = smoothstep(
                    edge0: Double(coverRect.width) * 0.035,
                    edge1: Double(coverRect.width) * 0.22,
                    value: innerEdgeDistance
                )

                let chromaGate = smoothstep(edge0: 0.035, edge1: 0.205, value: chroma)
                let saturationGate = smoothstep(edge0: 0.08, edge1: 0.44, value: saturation)
                let visibleValueGate = smoothstep(edge0: 0.055, edge1: 0.22, value: value)
                let colorEnergy = min(max(chromaGate * max(saturationGate, visibleValueGate * 0.58), 0), 1)
                let darkColorLift = smoothstep(edge0: 0.045, edge1: 0.18, value: chroma) *
                    smoothstep(edge0: 0.20, edge1: 0.62, value: saturation) *
                    (1 - smoothstep(edge0: 0.58, edge1: 0.96, value: value))
                let colorfulEdgeLift = smoothstep(edge0: 0.08, edge1: 0.30, value: chroma) * 0.14
                let colorParticipation = min(max(0.44 + interiorWeight * 0.56 + colorfulEdgeLift, 0), 1)
                let neutralParticipation = pow(interiorWeight, 1.65)
                let neutralEnergy = smoothstep(edge0: 0.78, edge1: 0.98, value: value) *
                    (1 - smoothstep(edge0: 0.022, edge1: 0.095, value: chroma)) *
                    0.006 *
                    neutralParticipation
                let energy = min(max(((colorEnergy * 0.98 + darkColorLift * 0.44) * colorParticipation + neutralEnergy) * alpha, 0), 1)

                guard energy > 0.0015 else {
                    pixels[index] = 0
                    pixels[index + 1] = 0
                    pixels[index + 2] = 0
                    pixels[index + 3] = 0
                    continue
                }

                let hsv = rgbToHSV(red: red, green: green, blue: blue)
                let colorDominance = smoothstep(edge0: 0.08, edge1: 0.48, value: colorEnergy + darkColorLift * 0.45)
                let outputSaturation = colorDominance > 0.001
                    ? min(max(hsv.saturation * 1.28 + 0.075, 0.32), 0.88)
                    : min(max(hsv.saturation * 0.82, 0), 0.18)
                let outputValue = colorDominance > 0.001
                    ? min(max(pow(max(hsv.value, 0), 0.70) * 1.04, 0.54), 0.96)
                    : min(max(pow(max(hsv.value, 0), 0.82) * 0.99, 0.70), 0.94)
                let output = hsvToRGB(hue: hsv.hue, saturation: outputSaturation, value: outputValue)
                let alphaByte = UInt8(min(max(energy * 255, 0), 255))
                pixels[index] = UInt8(min(max(output.red * energy * 255, 0), 255))
                pixels[index + 1] = UInt8(min(max(output.green * energy * 255, 0), 255))
                pixels[index + 2] = UInt8(min(max(output.blue * energy * 255, 0), 255))
                pixels[index + 3] = alphaByte
            }
        }

        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                width: n,
                height: n,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private struct EmissionSample {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    private nonisolated static func makeDirectionalLightField(_ lowFrequency: CIImage, pixelSide: Int, coverRect: CGRect) -> CIImage? {
        let n = max(pixelSide, 1)
        let bytesPerPixel = 4
        let bytesPerRow = n * bytesPerPixel
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n))
        guard let cgImage = ciContext.createCGImage(lowFrequency, from: canvas) else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var source = [UInt8](repeating: 0, count: n * n * bytesPerPixel)
        source.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: n,
                    height: n,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return }
            context.clear(canvas)
            context.interpolationQuality = .high
            context.draw(cgImage, in: canvas)
        }

        let centerX = Double(coverRect.midX)
        let centerY = Double(coverRect.midY)
        let halfSide = max(Double(coverRect.width) * 0.5, 1)
        let reach = max(Double(n) * 0.5 - halfSide, 1)
        var output = [UInt8](repeating: 0, count: n * n * bytesPerPixel)

        let averageSample: EmissionSample = {
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var energy = 0.0
            let stops: [(Double, Double, Double)] = [
                (0.50, 0.50, 0.30),
                (0.34, 0.38, 0.18),
                (0.66, 0.38, 0.18),
                (0.34, 0.62, 0.18),
                (0.66, 0.62, 0.18),
                (0.50, 0.24, 0.08),
                (0.50, 0.76, 0.08)
            ]
            for stop in stops {
                let sx = Double(coverRect.minX) + Double(coverRect.width) * stop.0
                let sy = Double(coverRect.minY) + Double(coverRect.height) * stop.1
                accumulateSample(
                    sample(source, width: n, height: n, x: sx, y: sy),
                    weight: stop.2,
                    red: &red,
                    green: &green,
                    blue: &blue,
                    energy: &energy
                )
            }
            guard energy > 0.001 else {
                return sample(source, width: n, height: n, x: centerX, y: centerY)
            }
            return EmissionSample(red: red / energy, green: green / energy, blue: blue / energy, alpha: min(max(energy, 0), 1))
        }()

        for y in 0..<n {
            let py = Double(y) + 0.5
            for x in 0..<n {
                let px = Double(x) + 0.5
                let projectedX = min(max(px, Double(coverRect.minX)), Double(coverRect.maxX))
                let projectedY = min(max(py, Double(coverRect.minY)), Double(coverRect.maxY))
                let outsideDistance = hypot(px - projectedX, py - projectedY)
                let normalizedDistance = min(max(outsideDistance / reach, 0), 1)
                let edgeDistance = min(min(px, Double(n) - px), min(py, Double(n) - py))
                let canvasFade = smoothstep(edge0: Double(n) * 0.012, edge1: Double(n) * 0.070, value: edgeDistance)
                let distanceWindow = max(1 - smoothstep(edge0: 0.42, edge1: 1.0, value: normalizedDistance), 0)
                let distanceFalloff = exp(-pow(normalizedDistance * 1.28, 1.85)) * pow(distanceWindow, 1.18)
                let falloff = distanceFalloff * canvasFade
                guard falloff > 0.002 else { continue }

                let edgeBias = smoothstep(edge0: 0.02, edge1: 0.90, value: normalizedDistance)
                let dx = projectedX - centerX
                let dy = projectedY - centerY
                let inset = halfSide * (0.09 + 0.15 * edgeBias)
                let edgeX = min(max(projectedX, Double(coverRect.minX) + inset), Double(coverRect.maxX) - inset)
                let edgeY = min(max(projectedY, Double(coverRect.minY) + inset), Double(coverRect.maxY) - inset)
                let midX = centerX + dx * 0.66
                let midY = centerY + dy * 0.66
                let broadX = centerX + dx * 0.38
                let broadY = centerY + dy * 0.38

                var red = 0.0
                var green = 0.0
                var blue = 0.0
                var energy = 0.0
                accumulateSample(
                    sample(source, width: n, height: n, x: edgeX, y: edgeY),
                    weight: 0.50 * (1 - edgeBias) + 0.27 * edgeBias,
                    red: &red,
                    green: &green,
                    blue: &blue,
                    energy: &energy
                )
                accumulateSample(
                    sample(source, width: n, height: n, x: midX, y: midY),
                    weight: 0.30 * (1 - edgeBias) + 0.35 * edgeBias,
                    red: &red,
                    green: &green,
                    blue: &blue,
                    energy: &energy
                )
                accumulateSample(
                    sample(source, width: n, height: n, x: broadX, y: broadY),
                    weight: 0.14 + 0.19 * edgeBias,
                    red: &red,
                    green: &green,
                    blue: &blue,
                    energy: &energy
                )
                accumulateSample(
                    averageSample,
                    weight: 0.06 + 0.19 * edgeBias,
                    red: &red,
                    green: &green,
                    blue: &blue,
                    energy: &energy
                )

                guard energy > 0.001 else { continue }
                red /= energy
                green /= energy
                blue /= energy
                let liftedEnergy = min(max(pow(min(energy * 2.20, 1), 0.70), 0), 1)
                let alpha = min(max(falloff * liftedEnergy * 0.66, 0), 0.70)
                guard alpha > 0.002 else { continue }

                let index = (y * n + x) * bytesPerPixel
                output[index] = UInt8(min(max(red * alpha * 255, 0), 255))
                output[index + 1] = UInt8(min(max(green * alpha * 255, 0), 255))
                output[index + 2] = UInt8(min(max(blue * alpha * 255, 0), 255))
                output[index + 3] = UInt8(min(max(alpha * 255, 0), 255))
            }
        }

        let data = Data(output) as CFData
        guard let provider = CGDataProvider(data: data),
              let field = CGImage(
                width: n,
                height: n,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: field)
    }

    private nonisolated static func accumulateSample(
        _ sample: EmissionSample,
        weight: Double,
        red: inout Double,
        green: inout Double,
        blue: inout Double,
        energy: inout Double
    ) {
        let sampleWeight = weight * sample.alpha
        guard sampleWeight > 0.000_01 else { return }
        red += sample.red * sampleWeight
        green += sample.green * sampleWeight
        blue += sample.blue * sampleWeight
        energy += sampleWeight
    }

    private nonisolated static func sample(_ pixels: [UInt8], width: Int, height: Int, x: Double, y: Double) -> EmissionSample {
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(floor(clampedX))
        let y0 = Int(floor(clampedY))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = clampedX - Double(x0)
        let ty = clampedY - Double(y0)
        let a = sampleNearest(pixels, width: width, x: x0, y: y0)
        let b = sampleNearest(pixels, width: width, x: x1, y: y0)
        let c = sampleNearest(pixels, width: width, x: x0, y: y1)
        let d = sampleNearest(pixels, width: width, x: x1, y: y1)
        return mix(mix(a, b, tx), mix(c, d, tx), ty)
    }

    private nonisolated static func sampleNearest(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> EmissionSample {
        let index = (y * width + x) * 4
        let alpha = Double(pixels[index + 3]) / 255
        guard alpha > 0.000_1 else {
            return EmissionSample(red: 0, green: 0, blue: 0, alpha: 0)
        }
        let red = min(max((Double(pixels[index]) / 255) / alpha, 0), 1)
        let green = min(max((Double(pixels[index + 1]) / 255) / alpha, 0), 1)
        let blue = min(max((Double(pixels[index + 2]) / 255) / alpha, 0), 1)
        return EmissionSample(red: red, green: green, blue: blue, alpha: alpha)
    }

    private nonisolated static func mix(_ lhs: EmissionSample, _ rhs: EmissionSample, _ amount: Double) -> EmissionSample {
        let t = min(max(amount, 0), 1)
        return EmissionSample(
            red: lhs.red * (1 - t) + rhs.red * t,
            green: lhs.green * (1 - t) + rhs.green * t,
            blue: lhs.blue * (1 - t) + rhs.blue * t,
            alpha: lhs.alpha * (1 - t) + rhs.alpha * t
        )
    }

    private nonisolated static func ditherNoise(x: Int, y: Int) -> Double {
        var value = UInt32(truncatingIfNeeded: x &* 1973 ^ y &* 9277 ^ 0x9E37)
        value = (value ^ (value >> 13)) &* 1_274_126_177
        return (Double(value & 255) / 255) - 0.5
    }

    private nonisolated static func loadCover(path: String) -> CGImage? {
#if DEBUG
        if let debug = MusicPlayerVisualDebugFixtures.coverCGImage(forPath: path, size: 320) {
            return debug
        }
#endif
        guard let ns = ArtworkImageCache.image(path: path, targetSize: CGSize(width: 320, height: 320)) else { return nil }
        if let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        guard let tiff = ns.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.cgImage
    }

    private nonisolated static func debugWrite(_ image: CIImage, name: String, sourcePath: String, rect: CGRect) {
        guard let directory = ProcessInfo.processInfo.environment["MEDIALIB_GLOW_DEBUG_DIR"],
              !directory.isEmpty,
              let cgImage = ciContext.createCGImage(image, from: rect) else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceName = safeDebugName(sourcePath)
        let url = folder.appendingPathComponent("\(sourceName)-\(name).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func safeDebugName(_ path: String) -> String {
        let last = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let raw = last.isEmpty ? String(abs(path.hashValue)) : last
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let name = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return name.isEmpty ? String(abs(path.hashValue)) : String(name.prefix(42))
    }

    private nonisolated static func smoothstep(edge0: Double, edge1: Double, value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private nonisolated static func rgbToHSV(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double, value: Double) {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let delta = maxComponent - minComponent
        let hue: Double
        if delta < 0.000_001 {
            hue = 0
        } else if maxComponent == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maxComponent == green {
            hue = (((blue - red) / delta) + 2) / 6
        } else {
            hue = (((red - green) / delta) + 4) / 6
        }
        let normalizedHue = hue < 0 ? hue + 1 : hue
        let saturation = maxComponent <= 0 ? 0 : delta / maxComponent
        return (normalizedHue, saturation, maxComponent)
    }

    private nonisolated static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> (red: Double, green: Double, blue: Double) {
        let h = (hue - floor(hue)) * 6
        let c = value * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let rgb: (Double, Double, Double)
        switch h {
        case 0..<1: rgb = (c, x, 0)
        case 1..<2: rgb = (x, c, 0)
        case 2..<3: rgb = (0, c, x)
        case 3..<4: rgb = (0, x, c)
        case 4..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }

}

// MARK: - 封面高斯模糊发光层

struct MusicExpandedArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let posterSize: CGFloat
    let glowReach: CGFloat
    let coverGlowEnabled: Bool
    let transitionNamespace: Namespace.ID?
    @StateObject private var playbackStateObserver: MusicMiniTransportStateObserver
    @State private var coverVisualProgress: Double = 1
    @State private var glowVisualProgress: Double = 1
    @State private var glowCollapseTask: Task<Void, Never>?

    init(
        item: MediaItem,
        controller: MpvPlayerController,
        palette: AlbumColorPalette,
        posterSize: CGFloat,
        glowReach: CGFloat,
        coverGlowEnabled: Bool,
        transitionNamespace: Namespace.ID? = nil
    ) {
        self.item = item
        self.controller = controller
        self.palette = palette
        self.posterSize = posterSize
        self.glowReach = glowReach
        self.coverGlowEnabled = coverGlowEnabled
        self.transitionNamespace = transitionNamespace
        _playbackStateObserver = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let isPlaying = playbackStateObserver.state.isPlaying
        let coverProgress = smoothstep(coverVisualProgress)
        let glowProgress = smoothstep(glowVisualProgress)
        let glowStrength = pow(glowProgress, 1.5)
        // 暂停时缩小并后退；播放态本身由布局略微收小，避免左侧视觉重量过大。
        let coverScale = CGFloat(lerp(from: 0.912, to: 1.0, progress: coverProgress))
        let coverOffset = CGFloat(lerp(from: 15, to: 0, progress: coverProgress))
        // §2.2 关灯"掉色温"：彩色投影饱和度随 glow 下降而向中性靠拢（保色相），
        // 模拟"发光体关闭后只剩环境光"；重新播放反向恢复。
        let shadowSatFloor = MusicPlayerVisualTokens.Glow.pausedShadowSaturationFloor
        let shadowSatMul = CGFloat(shadowSatFloor + (1 - shadowSatFloor) * glowStrength)
        let shadowPrimary = palette.glowPrimary.adjustedPreservingHue(
            saturationMultiplier: shadowSatMul,
            brightnessMultiplier: 1.0,
            minSaturation: 0, maxSaturation: 1, minBrightness: 0, maxBrightness: 1
        ).nsColor
        let shadowAccent = palette.glowAccent.adjustedPreservingHue(
            saturationMultiplier: shadowSatMul,
            brightnessMultiplier: 1.0,
            minSaturation: 0, maxSaturation: 1, minBrightness: 0, maxBrightness: 1
        ).nsColor

        ZStack {
            if coverGlowEnabled {
                MusicExpandedArtworkShadowLayer(
                    primaryColor: shadowPrimary,
                    accentColor: shadowAccent,
                    glowStrength: glowStrength,
                    coverProgress: coverProgress,
                    cornerRadius: 30,
                    reduceMotion: reduceMotion
                )
                .frame(width: posterSize, height: posterSize)
                .allowsHitTesting(false)
            } else {
                AlbumPrimarySoftCoverShadow(
                    color: shadowPrimary,
                    glowStrength: glowStrength,
                    coverProgress: coverProgress,
                    cornerRadius: 30
                )
                .frame(width: posterSize, height: posterSize)
                .allowsHitTesting(false)
            }

            PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: posterSize, height: posterSize)
                .modifier(MusicCoverGeometryModifier(namespace: transitionNamespace))
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                // 封面发光统一交给铺在整层背后的「模糊大封面」(AlbumGlowBlurCover)，
                // 这里不再叠 image-based 三层封面色场，避免两套发光互相打架/发糊。
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(lerp(from: 0.32, to: 0.48, progress: coverProgress)), lineWidth: 1.1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.18 * coverProgress),
                                    palette.glowPrimary.color.opacity(0.028 * glowStrength),
                                    .white.opacity(0.12 * coverProgress)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                        .allowsHitTesting(false)
                }
                .pointerLiquidEdge(cornerRadius: 30, tint: .white, intensity: 0.72)
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
            withAnimation(.easeOut(duration: 0.26)) {
                glowVisualProgress = 1
            }
            withAnimation(AppMotion.musicPlayer.delay(0.06)) {
                coverVisualProgress = 1
            }
        } else {
            // 暂停：近端（封面）先退后，然后由近及远关闭光晕
            // 1. 封面立即退后缩小
            withAnimation(AppMotion.musicPlayer) {
                coverVisualProgress = 0
            }
            // 2. 近端光晕快速收缩到微弱
            withAnimation(.easeOut(duration: 0.20).delay(0.035)) {
                glowVisualProgress = 0.16
            }
            // 3. 远端光晕渐渐熄灭（延迟更长，由近及远）
            glowCollapseTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.36)) {
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

private struct MusicCoverGeometryModifier: ViewModifier {
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "music-mini-cover", in: namespace, properties: .frame, anchor: .center)
        } else {
            content
        }
    }
}

private struct AlbumPrimarySoftCoverShadow: NSViewRepresentable {
    let color: NSColor
    let glowStrength: Double
    let coverProgress: Double
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> ShadowView {
        let view = ShadowView(frame: .zero)
        view.update(color: color, glowStrength: glowStrength, coverProgress: coverProgress, cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: ShadowView, context: Context) {
        nsView.update(color: color, glowStrength: glowStrength, coverProgress: coverProgress, cornerRadius: cornerRadius)
    }

    final class ShadowView: NSView {
        private let nearLayer = CALayer()
        private let farLayer = CALayer()
        private var latestColor = NSColor.clear
        private var latestGlowStrength: Double = 0
        private var latestCoverProgress: Double = 1
        private var latestCornerRadius: CGFloat = 30
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

        func update(color: NSColor, glowStrength: Double, coverProgress: Double, cornerRadius: CGFloat) {
            latestColor = color
            latestGlowStrength = min(max(glowStrength, 0), 1)
            latestCoverProgress = min(max(coverProgress, 0), 1)
            latestCornerRadius = cornerRadius
            apply(animated: didApplyInitialState)
            didApplyInitialState = true
        }

        private func configure() {
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.backgroundColor = NSColor.clear.cgColor
            for shadowLayer in [farLayer, nearLayer] {
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
            CATransaction.setAnimationDuration(animated ? 0.26 : 0)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

            for shadowLayer in [farLayer, nearLayer] {
                shadowLayer.frame = bounds
                shadowLayer.cornerRadius = latestCornerRadius
                shadowLayer.shadowPath = path
                shadowLayer.shadowColor = latestColor.cgColor
                shadowLayer.rasterizationScale = scale
            }

            // Disabled cover-glow mode: a shallow primary-color shadow with a long, soft falloff.
            nearLayer.shadowOpacity = Float(lerp(from: 0.0, to: 0.080, progress: latestGlowStrength))
            nearLayer.shadowRadius = CGFloat(lerp(from: 8, to: 22, progress: latestGlowStrength))
            nearLayer.shadowOffset = CGSize(width: 0, height: -CGFloat(lerp(from: 4, to: 10, progress: latestGlowStrength)))

            farLayer.shadowOpacity = Float(lerp(from: 0.0, to: 0.045, progress: latestGlowStrength))
            farLayer.shadowRadius = CGFloat(lerp(from: 20, to: 46, progress: latestGlowStrength))
            farLayer.shadowOffset = CGSize(width: 0, height: -CGFloat(lerp(from: 10, to: 20, progress: latestGlowStrength)))

            let depthAlpha = Float(lerp(from: 0.10, to: 0.14, progress: latestCoverProgress))
            nearLayer.opacity = latestGlowStrength <= 0.001 ? depthAlpha : 1
            farLayer.opacity = latestGlowStrength <= 0.001 ? 0 : 1

            CATransaction.commit()
        }

        private func lerp(from start: Double, to end: Double, progress: Double) -> Double {
            start + (end - start) * progress
        }
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

            // 彩色接触光只做贴边定义：真正的封面颜色外延交给上层 AlbumGlowBlurCover。
            // 这里必须保持零偏移，否则会和大封面 glow 叠成“下方更亮”的非均匀光晕。
            primaryShadowLayer.shadowColor = latestPrimaryColor.cgColor
            primaryShadowLayer.shadowOpacity = Float(lerp(from: 0.0, to: 0.18, progress: latestGlowStrength))
            primaryShadowLayer.shadowRadius = CGFloat(lerp(from: 8, to: 28, progress: latestGlowStrength))
            primaryShadowLayer.shadowOffset = .zero

            accentShadowLayer.shadowColor = latestAccentColor.cgColor
            accentShadowLayer.shadowOpacity = Float(lerp(from: 0.0, to: 0.12, progress: latestGlowStrength))
            accentShadowLayer.shadowRadius = CGFloat(lerp(from: 10, to: 46, progress: latestGlowStrength))
            accentShadowLayer.shadowOffset = .zero

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

struct MusicExpandedLyricsPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let controller: MpvPlayerController
    let itemID: String
    let lyrics: String
    let timedLyrics: [TimedLyricLine]
    let timingSource: LyricTimingSource
    let hasDisplayLyrics: Bool
    let isFetchingLyrics: Bool
    let palette: AlbumColorPalette
    let light: AlbumComponentLight
    @Binding var userIsBrowsingLyrics: Bool
    let onFetchLyrics: () -> Void
    let onPauseAutoScroll: () -> Void

    var body: some View {
        ZStack {
            LyricStageLight(palette: palette)
                .allowsHitTesting(false)

            MusicAdaptiveTextScrim(
                palette: palette,
                cornerRadius: MusicPlayerVisualTokens.Radius.card,
                maxOpacity: MusicPlayerVisualTokens.TextScrim.lyricsMaxOpacity
            )
            .allowsHitTesting(false)

            // 需求3：歌词卡右侧回归"平衡光"——从右边界向卡内非常柔和地漫入，
            // 颜色取封面高斯模糊主色（glowPrimary，primaryOnly），给右边界一条
            // 均匀的轮廓受光 + 极淡染色；随播放与封面光同亮同灭（spillProgress←isPlaying）。
            AlbumLightSpillOverlay(
                palette: palette,
                controller: controller,
                cornerRadius: MusicPlayerVisualTokens.Radius.card,
                intensity: 2.05,
                reach: 0.68,
                sourceEdge: .trailing,
                primaryOnly: true,
                light: AlbumComponentLight(strength: 1.0, focus: 0.5, spread: 1.0)
            )
            .allowsHitTesting(false)

            LyricsCardEdgeFrost(palette: palette, cornerRadius: MusicPlayerVisualTokens.Radius.card)
                .allowsHitTesting(false)

            // 正在播放行的聚光灯必须位于文字正下方、其它柔化遮罩之上；
            // 否则会被上下景深/边缘霜层吃掉，看起来像完全没有亮起来。
            LyricCenterSpotlight(
                controller: controller,
                palette: palette,
                coverGlowEnabled: light.strength > 0.001
            )
                .allowsHitTesting(false)

            lyricsView
                .padding(.horizontal, 54)
                .padding(.vertical, 58)

            if !hasDisplayLyrics {
                Button {
                    onFetchLyrics()
                } label: {
                    LyricFetchIcon(isFetching: isFetchingLyrics)
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
        .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: MusicPlayerVisualTokens.Radius.card, role: .lyrics, centerClarity: true))
    }

    @ViewBuilder
    private var lyricsView: some View {
        if !hasDisplayLyrics {
            MusicEmptyLyricsStage(
                title: emptyLyricsTitle,
                subtitle: emptyLyricsSubtitle,
                palette: palette,
                isFetchingLyrics: isFetchingLyrics
            )
        } else if timedLyrics.isEmpty {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(MusicPlayerView.cleanedLyrics(lyrics))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineSpacing(9)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: max(geometry.size.height, 420), alignment: .center)
                        .padding(28)
                }
                // §6.4 纯文本歌词态：套用与逐句歌词一致的上下羽化遮罩。
                .mask(LyricsFadeMask())
                .lyricsScrollActivity {
                    onPauseAutoScroll()
                }
            }
        } else {
            MusicTimedLyricsScrollView(
                controller: controller,
                itemID: itemID,
                timedLyrics: timedLyrics,
                palette: palette,
                userIsBrowsingLyrics: $userIsBrowsingLyrics,
                onPauseAutoScroll: onPauseAutoScroll
            )
        }
    }

    private var cleanedLyricMessage: String {
        MusicPlayerView.cleanedLyrics(lyrics).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyLyricsTitle: String {
        if isFetchingLyrics { return "正在获取歌词" }
        if cleanedLyricMessage.hasPrefix("在线歌词获取失败") { return "歌词获取失败" }
        if cleanedLyricMessage.hasPrefix("没有获取到") || cleanedLyricMessage.hasPrefix("没有匹配") {
            return "没有匹配的在线歌词"
        }
        return "此歌曲暂无可显示歌词"
    }

    private var emptyLyricsSubtitle: String {
        if cleanedLyricMessage.hasPrefix("在线歌词获取失败") {
            return cleanedLyricMessage
        }
        if isFetchingLyrics {
            return "MediaLIB 正在匹配同步歌词"
        }
        return "可使用同名 .lrc 或 .txt 歌词文件，或从右上角在线获取。"
    }
}

/// 无界（Borderless）方案的**布局锚点** token（仅经 `isWujie` 门控生效，琉璃不受影响）。
/// 注：左栏的间距/字阶/排版已收口到「无界重做」区的 `WujieDesignSystem`；这里只保留 MusicExpandedStage 共享布局胶水用到的两个几何锚点。
enum MusicWujieTokens {
    /// 左栏整体下移量，让封面 / 标题让开顶部「收起 / 更多」按钮。
    static var contentDrop: CGFloat { MusicThemeConfig.active.wujie.contentDrop }
    /// 左右对称外边距：左栏（连同发光）右移、右侧歌词列右沿内收。
    static var sideInset: CGFloat { MusicThemeConfig.active.wujie.sideInset }
}




private struct MusicEmptyLyricsStage: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let subtitle: String
    let palette: AlbumColorPalette
    let isFetchingLyrics: Bool
    @State private var breathe = false

    var body: some View {
        let animating = isFetchingLyrics && !reduceMotion
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.white.opacity(colorScheme == .dark ? 0.055 : 0.18))
                    .overlay {
                        Circle()
                            .fill(palette.primary.color.opacity(colorScheme == .dark ? 0.08 : 0.11))
                            .blendMode(.screen)
                    }
                    .frame(width: 74, height: 74)

                Image(systemName: isFetchingLyrics ? "text.magnifyingglass" : "music.note")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(palette.playedLyric.color.opacity(0.82))
                    .scaleEffect(animating && breathe ? 1.06 : 1)
                    .opacity(animating && breathe ? 0.70 : 1)
                    .animation(
                        animating ? .easeInOut(duration: 0.86).repeatForever(autoreverses: true) : nil,
                        value: breathe
                    )
            }
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.30 : 0.55),
                                palette.glowPrimary.color.opacity(colorScheme == .dark ? 0.24 : 0.30),
                                .black.opacity(colorScheme == .dark ? 0.20 : 0.055)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: palette.primary.color.opacity(colorScheme == .dark ? 0.18 : 0.12), radius: 18, y: 8)

            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.84))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.48))
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .onAppear { breathe = isFetchingLyrics }
        .onChange(of: isFetchingLyrics) { breathe = $0 }
        .onChange(of: reduceMotion) { reduced in
            if reduced { breathe = false }
        }
    }
}

private struct MusicAdaptiveTextScrim: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat
    let maxOpacity: Double

    var body: some View {
        let opacity = palette.textScrimOpacity(for: colorScheme, maxOpacity: maxOpacity)
        if opacity > 0.001 {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(opacity * MusicPlayerVisualTokens.TextScrim.edgeMultiplier * 0.38), location: 0.0),
                            .init(color: .black.opacity(opacity * MusicPlayerVisualTokens.TextScrim.edgeMultiplier * 0.78), location: 0.12),
                            .init(color: .black.opacity(opacity * MusicPlayerVisualTokens.TextScrim.centerMultiplier), location: 0.34),
                            .init(color: .black.opacity(opacity * MusicPlayerVisualTokens.TextScrim.centerMultiplier), location: 0.66),
                            .init(color: .black.opacity(opacity * MusicPlayerVisualTokens.TextScrim.edgeMultiplier * 0.78), location: 0.88),
                            .init(color: .black.opacity(opacity * MusicPlayerVisualTokens.TextScrim.edgeMultiplier * 0.38), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.black.opacity(opacity * 0.10), lineWidth: 1)
                        .blur(radius: 10)
                        .opacity(0.55)
                }
        }
    }
}

private struct LyricsCardEdgeFrost: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        ZStack {
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(isDark ? 0.080 : 0.155), location: 0.00),
                            .init(color: Color.white.opacity(isDark ? 0.050 : 0.100), location: 0.11),
                            .init(color: Color.white.opacity(isDark ? 0.014 : 0.026), location: 0.27),
                            .init(color: .clear, location: 0.41),
                            .init(color: .clear, location: 0.59),
                            .init(color: Color.white.opacity(isDark ? 0.012 : 0.022), location: 0.73),
                            .init(color: Color.white.opacity(isDark ? 0.040 : 0.082), location: 0.89),
                            .init(color: Color.white.opacity(isDark ? 0.070 : 0.135), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: palette.albumGlassBaseColor(for: colorScheme).opacity(isDark ? 0.062 : 0.050), location: 0.00),
                            .init(color: palette.glowPrimary.color.opacity(isDark ? 0.045 : 0.036), location: 0.15),
                            .init(color: .clear, location: 0.36),
                            .init(color: .clear, location: 0.64),
                            .init(color: palette.glowSecondary.color.opacity(isDark ? 0.034 : 0.026), location: 0.86),
                            .init(color: palette.albumGlassBaseColor(for: colorScheme).opacity(isDark ? 0.052 : 0.040), location: 1.00)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)

            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(isDark ? 0.045 : 0.010), location: 0.0),
                            .init(color: .clear, location: 0.24),
                            .init(color: .clear, location: 0.76),
                            .init(color: .black.opacity(isDark ? 0.040 : 0.008), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .clipShape(shape)
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

/// 歌词获取按钮图标（§6.4）：获取中显示 hourglass 并做克制的呼吸微动效；reduceMotion 时静止。
private struct LyricFetchIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isFetching: Bool
    @State private var breathe = false

    var body: some View {
        let animating = isFetching && !reduceMotion
        Image(systemName: isFetching ? "hourglass" : "arrow.down.circle")
            .font(.system(size: 15, weight: .semibold))
            .scaleEffect(animating && breathe ? 1.06 : 1)
            .opacity(animating && breathe ? 0.62 : 1)
            .animation(
                animating ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : nil,
                value: breathe
            )
            .onAppear { breathe = isFetching }
            .onChange(of: isFetching) { breathe = $0 }
            .onChange(of: reduceMotion) { reduced in
                if reduced { breathe = false }
            }
    }
}

private struct LyricStageLight: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: AlbumColorPalette

    var body: some View {
        LyricStageLightLayer(palette: palette, colorScheme: colorScheme, cornerRadius: 36)
            .opacity(0.78)
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
    }
}

/// 正在播放行的聚光灯：卡片中心一束专辑色径向光（当前行恒在中心）。
/// 白色只保留很薄的镜面高光，主体受光跟随封面色，避免歌词卡中心被白光冲淡。
private struct LyricCenterSpotlight: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: MpvPlayerController
    let palette: AlbumColorPalette
    let coverGlowEnabled: Bool

    init(controller: MpvPlayerController, palette: AlbumColorPalette, coverGlowEnabled: Bool) {
        self.controller = controller
        self.palette = palette
        self.coverGlowEnabled = coverGlowEnabled
    }

    var body: some View {
        GeometryReader { geo in
            // 舞台光（需求7）：特别柔和——峰值压低、平台收窄、衰减拉到更长，
            // 看起来是"中心慢慢亮起来"而不是一束突然的光；只提亮背景，不冲淡歌词颜色。
            // 需求4：中心舞台光照亮当前播放行——主体用专辑色（提一档，让中心更亮），
            // 但白色镜面层保持很薄、不提高，避免把歌词中心冲成白雾、淡化字色；
            // 半径更大、羽化更长，使光"尽可能柔和"地铺开。
            let lightLevel = coverGlowEnabled && controller.isPlaying ? 1.0 : 0.0
            let radius = min(max(min(geo.size.width, geo.size.height) * 0.46, 190), 320)
            let peak = (colorScheme == .dark ? 0.046 : 0.064) * lightLevel
            let stagePeak = (colorScheme == .dark ? 0.052 : 0.072) * lightLevel
            // 白色均匀舞台光需要可见，但只在背景层用 plusLighter 提亮，不直接参与文字前景。
            let stageWhite = (colorScheme == .dark ? 0.030 : 0.044) * lightLevel
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: palette.glowPrimary.color.opacity(stagePeak), location: 0.00),
                                .init(color: palette.glowSecondary.color.opacity(stagePeak * 0.58), location: 0.40),
                                .init(color: palette.glowAccent.color.opacity(stagePeak * 0.18), location: 0.70),
                                .init(color: .clear, location: 1.00)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius * 0.72
                        )
                    )
                    .frame(
                        width: min(max(geo.size.width * 0.42, 240), 470),
                        height: min(max(geo.size.height * 0.16, 82), 138)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .blur(radius: 38)
                    .blendMode(.screen)

                RadialGradient(
                    stops: [
                        .init(color: palette.glowPrimary.color.opacity(peak), location: 0.00),
                        .init(color: palette.glowPrimary.color.opacity(peak * 0.94), location: 0.16),
                        .init(color: palette.glowSecondary.color.opacity(peak * 0.70), location: 0.38),
                        .init(color: palette.glowPrimary.color.opacity(peak * 0.40), location: 0.60),
                        .init(color: palette.glowAccent.color.opacity(peak * 0.15), location: 0.80),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
                .blendMode(.screen)

                // 白色均匀舞台光（反馈3）：宽平台保持亮度均匀（不是一个亮点），
                // 之后用很长的羽化淡出——画在文字层之下，screen 只提亮背景，不冲淡歌词颜色。
                RadialGradient(
                    stops: [
                        .init(color: .white.opacity(stageWhite), location: 0.00),
                        .init(color: .white.opacity(stageWhite * 0.98), location: 0.24),
                        .init(color: .white.opacity(stageWhite * 0.76), location: 0.50),
                        .init(color: .white.opacity(stageWhite * 0.32), location: 0.78),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius * 0.82
                )
                .blendMode(.plusLighter)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(AppMotion.musicPlayer, value: controller.isPlaying)
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
            // 柔和、低对比的专辑色径向光，避免中心过亮、泛白或边缘形成可见分界（需求7 再压一档）。
            radialLayer.colors = [
                palette.glowPrimary.nsColor.withAlphaComponent(colorScheme == .dark ? 0.086 : 0.104).cgColor,
                palette.glowSecondary.nsColor.withAlphaComponent(colorScheme == .dark ? 0.050 : 0.060).cgColor,
                NSColor.white.withAlphaComponent(colorScheme == .dark ? 0.007 : 0.009).cgColor,
                NSColor.clear.cgColor
            ]
            radialLayer.locations = [0, 0.46, 0.76, 1]

            // 去掉中部横向亮带：它在歌词卡中部形成可见的"断层"横条。整体只保留柔和径向光。
            beamLayer.colors = [
                NSColor.clear.cgColor,
                NSColor.clear.cgColor
            ]
            beamLayer.locations = [0, 1]
        }
    }
}

/// 封面发光照射到玻璃组件边缘的光晕渗入效果。
/// 播放时：封面光沿指定入射边浸染入内，并产生柔和的彩色边缘高光。
/// 暂停时：随封面收缩动画同步淡出（由 near-to-far 机制驱动）。
struct AlbumComponentLight: Equatable {
    let strength: Double
    /// 受光边上的相对焦点。leading/trailing = y，top = x。
    let focus: Double
    /// 受光边上的半宽度。数值越小，越像圆形光场只扫到边缘的一段。
    let spread: Double

    static let none = AlbumComponentLight(strength: 0, focus: 0.5, spread: 0.12)
    static let fallbackLyrics = AlbumComponentLight(strength: 0.16, focus: 0.38, spread: 0.18)
    static let fallbackControls = AlbumComponentLight(strength: 0.34, focus: 0.5, spread: 0.42)
    static let fallbackChrome = AlbumComponentLight(strength: 0.20, focus: 0.5, spread: 0.28)

    static func leading(rect: CGRect, center: CGPoint, radius: CGFloat, coverSide: CGFloat, overshoot: CGFloat) -> AlbumComponentLight {
        guard rect.width > 1, rect.height > 1, radius > 1 else { return .none }
        let dx = rect.minX - center.x
        guard dx > 0 else { return .none }
        let closestY = min(max(center.y, rect.minY), rect.maxY)
        let distance = hypot(dx, closestY - center.y)
        let focus = Double((center.y - rect.minY) / rect.height)
        let halfIntersection = sqrt(max(radius * radius - dx * dx, 0))
        let spread = Double(min(max((halfIntersection / rect.height) * 0.42, 0.055), 0.24))
        let rawStrength = strength(distance: distance, radius: radius, coverSide: coverSide, overshoot: overshoot)
        let edgeContact = smoothstep(Double((radius - distance) / max(overshoot + coverSide * 0.18, 1)))
        return AlbumComponentLight(
            strength: rawStrength * (0.34 + 0.28 * edgeContact),
            focus: min(max(focus, 0.04), 0.96),
            spread: spread
        )
    }

    static func top(rect: CGRect, center: CGPoint, radius: CGFloat, coverSide: CGFloat, overshoot: CGFloat) -> AlbumComponentLight {
        guard rect.width > 1, rect.height > 1, radius > 1 else { return .none }
        let dy = rect.minY - center.y
        guard dy > 0 else { return .none }
        let closestX = min(max(center.x, rect.minX), rect.maxX)
        let distance = hypot(closestX - center.x, dy)
        let focus = Double((center.x - rect.minX) / rect.width)
        let halfIntersection = sqrt(max(radius * radius - dy * dy, 0))
        let spread = Double(min(max((halfIntersection / rect.width) * 0.72, 0.12), 0.58))
        return AlbumComponentLight(
            strength: strength(distance: distance, radius: radius, coverSide: coverSide, overshoot: overshoot) * 0.82,
            focus: min(max(focus, 0.06), 0.94),
            spread: spread
        )
    }

    private static func strength(distance: CGFloat, radius: CGFloat, coverSide: CGFloat, overshoot: CGFloat) -> Double {
        guard distance < radius else { return 0 }
        let remaining = radius - distance
        let contactWindow = max(overshoot * 1.45, coverSide * 0.155, 1)
        let contact = smoothstep(Double(remaining / contactWindow))
        let near = max(coverSide * 0.92, 1)
        let falloff = pow(Double(min(max(near / max(distance, near), 0), 1)), 0.92)
        return min(max(contact * (0.30 + 0.42 * falloff), 0), 1)
    }

    private static func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

private enum AlbumLightSpillSourceEdge {
    case leading
    case trailing
    case top
    case topLeading

    var startPoint: UnitPoint {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .topLeading: return .topLeading
        }
    }

    var endPoint: UnitPoint {
        switch self {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .bottom
        case .topLeading: return .bottomTrailing
        }
    }
}

private struct AlbumLightSpillOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let palette: AlbumColorPalette
    let controller: MpvPlayerController
    let cornerRadius: CGFloat
    var intensity: Double = 1
    var reach: Double = MusicPlayerVisualTokens.Spill.lyricsReach
    var sourceEdge: AlbumLightSpillSourceEdge = .leading
    var primaryOnly: Bool = false
    var light: AlbumComponentLight = .fallbackLyrics
    @StateObject private var playbackObserver: MusicMiniTransportStateObserver
    @State private var spillProgress: Double = 0
    @State private var collapseTask: Task<Void, Never>?

    init(
        palette: AlbumColorPalette,
        controller: MpvPlayerController,
        cornerRadius: CGFloat,
        intensity: Double = 1,
        reach: Double = 0.36,
        sourceEdge: AlbumLightSpillSourceEdge = .leading,
        primaryOnly: Bool = false,
        light: AlbumComponentLight = .fallbackLyrics
    ) {
        self.palette = palette
        self.controller = controller
        self.cornerRadius = cornerRadius
        self.intensity = intensity
        self.reach = reach
        self.sourceEdge = sourceEdge
        self.primaryOnly = primaryOnly
        self.light = light
        _playbackObserver = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let isPlaying = playbackObserver.state.isPlaying
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let darkMode = colorScheme == .dark
        let glowColor = palette.glowPrimary.adjustedPreservingHue(
            saturationMultiplier: 0.94,
            brightnessMultiplier: 1.04,
            minSaturation: 0.14,
            maxSaturation: 0.56,
            minBrightness: darkMode ? 0.50 : 0.62,
            maxBrightness: darkMode ? 0.78 : 0.86
        ).color
        let secondaryColor = (primaryOnly ? palette.glowPrimary : palette.glowSecondary).adjustedPreservingHue(
            saturationMultiplier: 0.90,
            brightnessMultiplier: 1.02,
            minSaturation: 0.12,
            maxSaturation: 0.52,
            minBrightness: darkMode ? 0.48 : 0.60,
            maxBrightness: darkMode ? 0.76 : 0.84
        ).color
        let accentColor = (primaryOnly ? palette.glowPrimary : palette.glowAccent).adjustedPreservingHue(
            saturationMultiplier: 0.88,
            brightnessMultiplier: 1.00,
            minSaturation: 0.10,
            maxSaturation: 0.48,
            minBrightness: darkMode ? 0.46 : 0.58,
            maxBrightness: darkMode ? 0.74 : 0.82
        ).color
        let startPoint = sourceEdge.startPoint
        let endPoint = sourceEdge.endPoint
        let trailingPrimaryLight: Bool = {
            switch sourceEdge {
            case .trailing:
                return primaryOnly
            case .leading, .top, .topLeading:
                return false
            }
        }()
        let chromaTravel = MusicPlayerVisualTokens.Spill.chromaTravelBase +
            palette.vibrancy * MusicPlayerVisualTokens.Spill.chromaTravelVibrancy
        let spill = spillProgress * intensity * chromaTravel * light.strength
        let lateralEdge: Bool = {
            switch sourceEdge {
            case .leading, .trailing:
                return true
            case .top, .topLeading:
                return false
            }
        }()
        let nearStop = min(max(reach * 0.24, lateralEdge ? 0.040 : 0.060), lateralEdge ? 0.105 : 0.16)
        let midStop = min(max(reach * 0.48, lateralEdge ? 0.095 : 0.13), lateralEdge ? 0.22 : 0.31)
        // 放宽羽化终点上限，让更深的 reach 把浸染过渡铺得更长、更柔（向参考图的"光软软漫进卡片"靠拢）。
        let fadeStop = min(max(reach, trailingPrimaryLight ? 0.24 : (lateralEdge ? 0.18 : 0.24)), trailingPrimaryLight ? 0.52 : (lateralEdge ? 0.34 : 0.48))
        let tailStop = min(max(fadeStop + (trailingPrimaryLight ? 0.12 : (lateralEdge ? 0.08 : 0.13)), trailingPrimaryLight ? 0.40 : (lateralEdge ? 0.26 : 0.44)), trailingPrimaryLight ? 0.72 : (lateralEdge ? 0.46 : 0.68))
        let innerSoftStop = min(max(reach * 0.62, trailingPrimaryLight ? 0.26 : (lateralEdge ? 0.16 : 0.26)), trailingPrimaryLight ? 0.52 : (lateralEdge ? 0.34 : 0.50))
        let innerTailStop = min(max(reach * 0.88, trailingPrimaryLight ? 0.40 : (lateralEdge ? 0.24 : 0.38)), trailingPrimaryLight ? 0.72 : (lateralEdge ? 0.46 : 0.62))

        ZStack {
            // §2.3 裹边内发光：让光看起来是绕过玻璃边缘渗进内部，而非只在边线上。
            // 峰值略微内移，按指定入射方向向内平滑衰减。仅 .screen 加色，跟随 spillProgress。
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.150 : 0.118) * spill), location: MusicPlayerVisualTokens.Spill.innerPeak),
                            .init(color: glowColor.opacity((darkMode ? 0.168 : 0.135) * spill), location: MusicPlayerVisualTokens.Spill.innerPrimary),
                            .init(color: secondaryColor.opacity((darkMode ? 0.092 : 0.074) * spill), location: MusicPlayerVisualTokens.Spill.innerSecondary),
                            .init(color: secondaryColor.opacity((darkMode ? 0.042 : 0.034) * spill), location: innerSoftStop),
                            .init(color: .clear, location: innerTailStop)
                        ],
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                )
                .blendMode(.screen)

            // 方向浸染：只照亮朝向封面的边缘和少量内部，避免把整张玻璃染脏。
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.420 : 0.335) * spill), location: 0),
                            .init(color: secondaryColor.opacity((darkMode ? 0.225 : 0.178) * spill), location: nearStop),
                            .init(color: accentColor.opacity((darkMode ? 0.098 : 0.078) * spill), location: midStop),
                            .init(color: accentColor.opacity((darkMode ? 0.040 : 0.032) * spill), location: fadeStop),
                            .init(color: .clear, location: tailStop)
                        ],
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                )
                .blendMode(.screen)

            // 近白玻璃上单纯 screen 只会“变白”而不明显染色；额外叠一层很薄的 normal tint，
            // 让被光照到的边缘真正带上专辑高斯色，同时保持向内快速衰减。
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.072 : 0.052) * spill), location: 0),
                            .init(color: secondaryColor.opacity((darkMode ? 0.034 : 0.026) * spill), location: nearStop),
                            .init(color: accentColor.opacity((darkMode ? 0.012 : 0.009) * spill), location: midStop),
                            .init(color: .clear, location: fadeStop)
                        ],
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                )
                .blendMode(.normal)

            // 受光边缘细描边：被封面发光照亮的一小段边缘，快速淡出。
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.48 : 0.37) * spill), location: 0),
                            .init(color: secondaryColor.opacity((darkMode ? 0.24 : 0.19) * spill), location: nearStop + 0.035),
                            .init(color: accentColor.opacity((darkMode ? 0.092 : 0.070) * spill), location: midStop + 0.045),
                            .init(color: accentColor.opacity((darkMode ? 0.028 : 0.021) * spill), location: min(fadeStop + 0.075, 0.70)),
                            .init(color: .clear, location: min(tailStop + 0.02, 0.96)),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: startPoint,
                        endPoint: endPoint
                    ),
                    lineWidth: CGFloat(0.82 + 0.24 * spill)
                )
                .blendMode(.screen)

            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.145 : 0.110) * spill), location: 0),
                            .init(color: secondaryColor.opacity((darkMode ? 0.066 : 0.052) * spill), location: nearStop + 0.035),
                            .init(color: accentColor.opacity((darkMode ? 0.020 : 0.016) * spill), location: midStop + 0.045),
                            .init(color: .clear, location: min(fadeStop + 0.08, 0.76))
                        ],
                        startPoint: startPoint,
                        endPoint: endPoint
                    ),
                    lineWidth: CGFloat(0.90 + 0.22 * spill)
                )
                .blendMode(.normal)

            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity((darkMode ? 0.165 : 0.125) * spill), location: 0),
                            .init(color: glowColor.opacity((darkMode ? 0.078 : 0.056) * spill), location: 0.046),
                            .init(color: .white.opacity((darkMode ? 0.010 : 0.012) * spill), location: 0.072),
                            .init(color: glowColor.opacity((darkMode ? 0.026 : 0.019) * spill), location: 0.22),
                            .init(color: .clear, location: 0.42)
                        ],
                        startPoint: startPoint,
                        endPoint: endPoint
                    ),
                    lineWidth: 0.55
                )
                .blendMode(.plusLighter)
        }
        .clipShape(shape)
        .mask {
            AlbumLightSpillFocusMask(sourceEdge: sourceEdge, focus: light.focus, spread: light.spread)
        }
        .onAppear {
            spillProgress = isPlaying ? 1 : 0
        }
        .onChange(of: isPlaying) { playing in
            collapseTask?.cancel()
            if reduceMotion {
                spillProgress = playing ? 1 : 0
                return
            }
            if playing {
                withAnimation(.easeOut(duration: MusicPlayerVisualTokens.Spill.playRiseDuration)) {
                    spillProgress = 1
                }
            } else {
                // 随封面收缩同步淡出：先快降到微弱，再延迟熄灭（near-to-far）
                withAnimation(.easeInOut(duration: MusicPlayerVisualTokens.Spill.pauseNearFadeDuration)) {
                    spillProgress = MusicPlayerVisualTokens.Spill.pausedResidual
                }
                collapseTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: MusicPlayerVisualTokens.Spill.pauseFarDelay) } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: MusicPlayerVisualTokens.Spill.pauseFarFadeDuration)) {
                        spillProgress = 0
                    }
                }
            }
        }
        .onChange(of: reduceMotion) { enabled in
            collapseTask?.cancel()
            if enabled {
                spillProgress = isPlaying ? 1 : 0
            } else if !isPlaying {
                spillProgress = 0
            }
        }
        .onDisappear {
            collapseTask?.cancel()
        }
    }
}

private struct AlbumLightSpillFocusMask: View {
    let sourceEdge: AlbumLightSpillSourceEdge
    let focus: Double
    let spread: Double

    var body: some View {
        switch sourceEdge {
        case .leading, .trailing:
            focusedLinearMask(startPoint: .top, endPoint: .bottom)
        case .top:
            focusedLinearMask(startPoint: .leading, endPoint: .trailing)
        case .topLeading:
            RadialGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: min(max(spread, 0.10), 0.62)),
                    .init(color: .clear, location: 1.0)
                ],
                center: UnitPoint(x: min(max(focus, 0.05), 0.95), y: 0.0),
                startRadius: 0,
                endRadius: 220
            )
        }
    }

    private func focusedLinearMask(startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        let clampedFocus = min(max(focus, 0.0), 1.0)
        let clampedSpread = min(max(spread, 0.06), 1.0)
        let feather = min(max(clampedSpread * 0.28, 0.030), 0.12)
        let lower = max(clampedFocus - clampedSpread, 0)
        let upper = min(clampedFocus + clampedSpread, 1)
        let lowerFeather = max(lower - feather, 0)
        let upperFeather = min(upper + feather, 1)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: lowerFeather),
                .init(color: .white, location: lower),
                .init(color: .white, location: clampedFocus),
                .init(color: .white, location: upper),
                .init(color: .clear, location: upperFeather),
                .init(color: .clear, location: 1)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
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

/// 歌词滚动区上下羽化遮罩（§3.4 / §6.4）：逐句与纯文本歌词共用同一份，保证两种态风格一致。
/// 中间约 40% 高度（0.30~0.70）保持全清晰，两端更柔地羽化（参考 Apple Music）。
private struct LyricsFadeMask: View {
    /// 向上下各扩展可见区的比例（0=琉璃原样）。无界用它把完全清晰带从 0.30~0.70 外扩，多露上下各一行。
    var expansion: CGFloat = 0

    var body: some View {
        let e = min(max(expansion, 0), 0.18)
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black.opacity(0.05), location: 0.06),
                .init(color: .black.opacity(0.28), location: max(0.15 - e, 0.07)),
                .init(color: .black.opacity(0.70), location: max(0.24 - e, 0.12)),
                .init(color: .black, location: max(0.30 - e, 0.16)),
                .init(color: .black, location: min(0.70 + e, 0.84)),
                .init(color: .black.opacity(0.70), location: min(0.76 + e, 0.88)),
                .init(color: .black.opacity(0.28), location: min(0.85 + e, 0.93)),
                .init(color: .black.opacity(0.05), location: 0.94),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct MusicTimedLyricsScrollView: View {
    let controller: MpvPlayerController
    let itemID: String
    let timedLyrics: [TimedLyricLine]
    let palette: AlbumColorPalette
    var lineAlignment: LyricLineTextAlignment = .center
    var horizontalPadding: CGFloat = 34
    var lineFontSize: CGFloat = 23
    var rowSpacing: CGFloat = 12
    var fadeExpansion: CGFloat = 0
    /// 滚动内容上下留白占视口比例：决定首/末行能滚到多接近视口中心。
    /// 需要 ≥ 0.5 才能让第一行也精确落到视口正中（无界传 0.5；琉璃保持 0.46 不变）。
    var verticalPaddingFraction: CGFloat = 0.46
    /// 无界：放宽远处歌词行的可见度（更缓的透明度衰减），让更多被景深模糊的行也隐约可见。
    var extendedVisibility: Bool = false
    @Binding var userIsBrowsingLyrics: Bool
    let onPauseAutoScroll: () -> Void
    @StateObject private var renderObserver: MusicLyricRenderObserver
    @State private var lastAutoScrolledIndex: Int?
    @State private var lyricViewportAlignTask: Task<Void, Never>?
    @State private var lyricViewportStabilityTask: Task<Void, Never>?
    @State private var programmaticLyricScrollTask: Task<Void, Never>?
    @State private var lyricBrowseRecoveryTask: Task<Void, Never>?
    @State private var isProgrammaticLyricScroll = false
    @State private var userScrollRevision = 0
    // 1.0 = 正常模糊（播放状态），0.0 = 浏览状态（低模糊）
    @State private var lyricBrowseBlurProgress: Double = 1.0

    init(
        controller: MpvPlayerController,
        itemID: String,
        timedLyrics: [TimedLyricLine],
        palette: AlbumColorPalette,
        lineAlignment: LyricLineTextAlignment = .center,
        horizontalPadding: CGFloat = 34,
        lineFontSize: CGFloat = 23,
        rowSpacing: CGFloat = 12,
        fadeExpansion: CGFloat = 0,
        verticalPaddingFraction: CGFloat = 0.46,
        extendedVisibility: Bool = false,
        userIsBrowsingLyrics: Binding<Bool>,
        onPauseAutoScroll: @escaping () -> Void
    ) {
        self.controller = controller
        self.itemID = itemID
        self.timedLyrics = timedLyrics
        self.palette = palette
        self.lineAlignment = lineAlignment
        self.horizontalPadding = horizontalPadding
        self.lineFontSize = lineFontSize
        self.rowSpacing = rowSpacing
        self.fadeExpansion = fadeExpansion
        self.verticalPaddingFraction = verticalPaddingFraction
        self.extendedVisibility = extendedVisibility
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

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let currentActiveIndex = activeLyricIndex
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: lineAlignment.stackAlignment, spacing: rowSpacing) {
                        ForEach(timedLyrics.indices, id: \.self) { index in
                            let line = timedLyrics[index]
                            let isActiveLine = index == currentActiveIndex
                            let isTimestampCompanion = currentActiveIndex
                                .flatMap { timedLyrics.indices.contains($0) ? timedLyrics[$0] : nil }
                                .map { !isActiveLine && TimedLyricLine.sharesTimestampCluster(line, $0) } ?? false
                            let distance = currentActiveIndex.map { abs(index - $0) } ?? 0
                            lyricLine(
                                line,
                                index: index,
                                isActive: isActiveLine,
                                isTimestampCompanion: isTimestampCompanion,
                                distanceFromActive: distance,
                                highlightMode: highlightMode(for: index),
                                isBrowsing: userIsBrowsingLyrics,
                                browseBlurProgress: lyricBrowseBlurProgress
                            )
                            .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: max(geometry.size.height, 360), alignment: lineAlignment.frameAlignment)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, max(geometry.size.height * verticalPaddingFraction, 38))
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
                .onChange(of: itemID) { _ in
                    resetViewportForNewItem(proxy)
                }
                .onChange(of: userIsBrowsingLyrics) { browsing in
                    if browsing {
                        // 快速解除模糊（§3 token），让用户立刻能看清所有歌词。
                        withAnimation(.easeOut(duration: MusicPlayerVisualTokens.Lyrics.browseClearDuration)) {
                            lyricBrowseBlurProgress = 0
                        }
                    } else {
                        // 慢速恢复模糊（§3 token easeInOut）：仅在滚动真正停止后由稳定检查置回，
                        // 恢复同时把当前行平滑滚回中心，并做稳定性校正。
                        withAnimation(.easeInOut(duration: MusicPlayerVisualTokens.Lyrics.browseRecoverDuration)) {
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
                    lyricBrowseRecoveryTask?.cancel()
                    isProgrammaticLyricScroll = false
                }
            }
        }
    }

    private var lyricsFadeMask: some View { LyricsFadeMask(expansion: fadeExpansion) }

    private func lyricLine(
        _ line: TimedLyricLine,
        index: Int,
        isActive: Bool,
        isTimestampCompanion: Bool,
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
                    palette: palette,
                    alignment: lineAlignment,
                    fontSize: lineFontSize
                )
            } else {
                KaraokeLyricLine(
                    line: line,
                    currentTime: line.time,
                    palette: palette,
                    isActive: false,
                    highlightMode: highlightMode,
                    progress: 0,
                    alignment: lineAlignment,
                    fontSize: lineFontSize
                )
                .equatable()
            }
        }
        .allowsHitTesting(false)
        .lineLimit(nil)
        .multilineTextAlignment(lineAlignment.textAlignment)
        .frame(maxWidth: .infinity, alignment: lineAlignment.frameAlignment)
        // 所有行基础字号一致；当前行只做 1% 以内的视觉 scale，主要突出仍来自逐字上浮与色彩变化。
        .activeLyricMotion(active: isActive, isBrowsing: isBrowsing, palette: palette)
        .opacity(lyricOpacity(distanceFromActive: distanceFromActive, isActive: isActive, isTimestampCompanion: isTimestampCompanion, isBrowsing: isBrowsing))
        .blur(radius: lyricBlur(distanceFromActive: distanceFromActive, isActive: isActive, isTimestampCompanion: isTimestampCompanion, browseProgress: browseBlurProgress))
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

    private func lyricOpacity(distanceFromActive distance: Int, isActive: Bool, isTimestampCompanion: Bool, isBrowsing: Bool) -> Double {
        if isBrowsing {
            if isActive { return 1 }
            if isTimestampCompanion { return 0.96 }
            switch distance {
            case 0...1: return 0.94
            case 2: return 0.88
            case 3: return 0.80
            default: return 0.72
            }
        }
        if isActive { return 1 }
        if isTimestampCompanion { return 0.86 }
        if extendedVisibility {
            // 无界：远处行透明度衰减更缓，让更多（含被景深模糊的）歌词行隐约可见。
            switch distance {
            case 0...1: return 0.80
            case 2: return 0.66
            case 3: return 0.54
            case 4: return 0.45
            case 5: return 0.38
            case 6: return 0.32
            default: return 0.28
            }
        }
        switch distance {
        case 0...1: return 0.76
        case 2: return 0.58
        case 3: return 0.42
        case 4: return 0.30
        default: return 0.22
        }
    }

    private func lyricBlur(distanceFromActive distance: Int, isActive: Bool, isTimestampCompanion: Bool, browseProgress: Double) -> CGFloat {
        if isActive { return 0 }
        if isTimestampCompanion { return 0.18 * CGFloat(browseProgress) }
        // 正常播放状态：距离越远模糊越强（非线性），营造景深感（分段值集中到 token）。
        let curve = MusicPlayerVisualTokens.Lyrics.distanceBlur
        let maxBlur = MusicPlayerVisualTokens.Lyrics.distanceBlurMax
        var normalBlur: CGFloat
        if distance < curve.count {
            normalBlur = curve[distance]
        } else {
            normalBlur = min(curve[curve.count - 1] + CGFloat(distance - (curve.count - 1)) * 0.8, maxBlur)
        }
        // §3.1 位置感：用中窗比例估算行是否进入上/下羽化区，再叠加克制模糊；
        // 当前行恒为 0，中心清晰窗口基本不受影响，边缘 1~2 行会更像真实景深。
        let estimatedCenterOffset = min(CGFloat(distance) * MusicPlayerVisualTokens.Lyrics.edgePositionStep, 1)
        let clearHalf = CGFloat(MusicPlayerVisualTokens.Lyrics.clearWindowRatio) * 0.5
        if estimatedCenterOffset > clearHalf {
            let rawRamp = min(max((estimatedCenterOffset - clearHalf) / max(1 - clearHalf, 0.001), 0), 1)
            let edgeRamp = rawRamp * rawRamp * (3 - 2 * rawRamp)
            normalBlur = min(normalBlur + MusicPlayerVisualTokens.Lyrics.edgeExtraBlur * edgeRamp, maxBlur)
        }
        // 浏览状态：完全取消模糊（按 browseProgress 插值，0=浏览，1=正常播放）。
        return normalBlur * CGFloat(browseProgress)
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

    private func resetViewportForNewItem(_ proxy: ScrollViewProxy) {
        lyricViewportAlignTask?.cancel()
        lyricViewportStabilityTask?.cancel()
        programmaticLyricScrollTask?.cancel()
        lyricBrowseRecoveryTask?.cancel()
        isProgrammaticLyricScroll = false
        userScrollRevision &+= 1
        lastAutoScrolledIndex = nil
        lyricBrowseBlurProgress = 1
        if userIsBrowsingLyrics {
            userIsBrowsingLyrics = false
        }
        renderObserver.updateTimedLyrics(timedLyrics)
        scrollToActiveLyric(proxy, force: true, animated: false)
        scheduleLyricViewportStabilityCheck(proxy)
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
            do { try await Task.sleep(nanoseconds: MusicPlayerVisualTokens.Lyrics.viewportStabilityDelay) } catch { return }
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
        userScrollRevision &+= 1
        onPauseAutoScroll()
        scheduleBrowseRecoveryAfterStableScroll()
    }

    private func scheduleBrowseRecoveryAfterStableScroll() {
        lyricBrowseRecoveryTask?.cancel()
        let revision = userScrollRevision
        lyricBrowseRecoveryTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: MusicPlayerVisualTokens.Lyrics.browseFallbackResumeDelay) } catch { return }
            guard !Task.isCancelled,
                  revision == userScrollRevision,
                  userIsBrowsingLyrics else { return }
            withAnimation(AppMotion.standard) {
                userIsBrowsingLyrics = false
            }
            lyricBrowseRecoveryTask = nil
        }
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

// MARK: - 无界（Borderless）控制组件

/// 无界右上角「更多」菜单：复制歌曲信息 / 在访达显示 / 重新获取歌词。无边框磨砂玻璃圆。
struct WujieMoreButton: View {
    let item: MediaItem
    let palette: AlbumColorPalette
    var size: CGFloat = 44
    let onFetchLyrics: () -> Void

    var body: some View {
        Menu {
            Button {
                copyTrackInfo()
            } label: { Label("复制歌曲信息", systemImage: "doc.on.doc") }

            if let path = item.filePath, !item.isRemoteResource, FileManager.default.fileExists(atPath: path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("在访达中显示", systemImage: "folder") }
            }

            Button {
                onFetchLyrics()
            } label: { Label("重新获取歌词", systemImage: "text.magnifyingglass") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: size, height: size)
        .help("更多")
        .accessibilityLabel("更多")
    }

    private func copyTrackInfo() {
        var parts: [String] = [item.title]
        if let artist = item.artist, !artist.isEmpty { parts.append(artist) }
        if let album = item.album, !album.isEmpty { parts.append(album) }
        let text = parts.joined(separator: " · ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


/// 无界：上报控制栏底部在 "wujieContent" 坐标空间里的 maxY，供右侧频谱与之底对齐。
struct WujieControlsBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


/// 无界右侧频谱（底部对齐 + 倒影 + 白/主色双色峰值保持）。
/// 视觉：每条声柱从基线向上生长，柱体为减淡的专辑主题色，顶端有一段白色「峰帽」；
/// - 上升：白色峰帽瞬间冲到峰值（领先），主题色随后快速填充上来 → 白帽收窄成一条亮线；
/// - 回落：主题色快速下落（白帽白色区随之变大、像悬在上方），白色峰帽再缓慢跟着落下。
/// 基线下方是逐渐羽化消失的倒影；柱体顶端也用渐变淡出，不会"突然出现"。
/// 基线（频谱与倒影的分界）对齐左侧控制栏底部按钮。专用于无界。
struct WujieSpectrum: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var model: WujieSpectrumModel

    /// 基线到视图顶部的比例（其余为下方倒影区）。供外层定位基线对齐控制栏底部。
    static let baselineFromTopFraction: CGFloat = 0.64

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _model = StateObject(wrappedValue: WujieSpectrumModel(controller: controller))
    }

    var body: some View {
        // #1 颜色减淡：用提亮的主色（glowPrimary）作柱体色，并在绘制时压低不透明度。
        let tint = palette.glowPrimary.color
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                model.advance(to: timeline.date)
                model.draw(into: &context, size: size, tint: tint, baselineFromTop: Self.baselineFromTopFraction)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            model.attach(controller: controller)
            controller.setAudioSpectrumVisualizationActive(true)
        }
        .onDisappear { controller.setAudioSpectrumVisualizationActive(false) }
    }
}

// WujieSpectrumModel（无界频谱数据/动画模型，含 Canvas 绘制）已物理拆分到 WujieSpectrumModel.swift
// （逐字节原样搬运，零行为/零视觉变化）。


/// 无界状态行：错误 / 正在准备的提示。复用状态数据观察器（非视觉），不与琉璃共用视图。
private struct WujieStatusLine: View {
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
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                Text(error)
                    .lineLimit(1)
                    .foregroundStyle(.orange)
                Spacer()
                Button("重试") {
                    controller.configureMusic(item: item, settings: appState.settings)
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 22))
            }
            .font(.caption)
            .frame(maxHeight: 22)
            .clipped()
        } else if state.isPreparing {
            AppInlineNoticeLabel(text: "正在准备播放器", systemImage: "progress.indicator", lineLimit: 1)
                .frame(maxHeight: 18)
        }
    }
}






struct MusicExpandedControls: View {
    let controller: MpvPlayerController
    let item: MediaItem
    let palette: AlbumColorPalette
    let light: AlbumComponentLight

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette, light: AlbumComponentLight) {
        self.item = item
        self.controller = controller
        self.palette = palette
        self.light = light
    }

    var body: some View {
        ZStack {
            ZStack {
                MusicAdaptiveTextScrim(
                    palette: palette,
                    cornerRadius: MusicPlayerVisualTokens.Radius.control,
                    maxOpacity: MusicPlayerVisualTokens.TextScrim.controlsMaxOpacity
                )
                .allowsHitTesting(false)

                AlbumLightSpillOverlay(
                    palette: palette,
                    controller: controller,
                    cornerRadius: MusicPlayerVisualTokens.Radius.control,
                    intensity: MusicPlayerVisualTokens.Spill.controlsIntensity,
                    reach: MusicPlayerVisualTokens.Spill.controlsReach,
                    sourceEdge: .top,
                    light: light
                )
                .allowsHitTesting(false)

                VStack(spacing: 12) {
                    MusicExpandedProgressRow(item: item, controller: controller, palette: palette)

                    MusicExpandedTransportRow(item: item, controller: controller, palette: palette)

                    MusicExpandedStatusLine(controller: controller, item: item)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: MusicPlayerVisualTokens.Radius.control, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(maxWidth: MusicPlayerVisualTokens.Controls.expandedMaxWidth, alignment: .center)
        .frame(minHeight: MusicPlayerVisualTokens.Controls.expandedHeight, idealHeight: MusicPlayerVisualTokens.Controls.expandedHeight, maxHeight: MusicPlayerVisualTokens.Controls.expandedHeight)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MusicControlGlass(palette: palette, cornerRadius: MusicPlayerVisualTokens.Radius.control, tintStrength: 1.0))
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
                // §5.2 略提对比度：浅色 + 浅取色玻璃上 .secondary 偏弱，改用更可控的 primary 不透明度。
                .foregroundStyle(.primary.opacity(0.68))
                .frame(width: 34, alignment: .trailing)

            MusicMiniSeekSlider(
                currentTime: state.currentTime,
                duration: state.duration,
                isPlaying: state.isPlaying,
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
                .foregroundStyle(.primary.opacity(0.68))
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

        // 隔空投送按钮配色统一为播放按钮：播放按钮用 palette.primary 及其加深版 deepPlayTint（见 MusicPrimaryPlayButtonLabel），
        // 这里把 AirPlay 的图标 tint 也改用同一套专辑主色，不再是写死的蓝色。
        let deepPrimary = palette.deepPlayTint

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
            .buttonStyle(MusicGlassPressStyle(pressScale: MusicPlayerVisualTokens.Tint.playPressedScale))
            // §5.3 播放是唯一实心主色按钮：发光比次级 transport 按钮（≈1.10）更强一档，建立清晰操作层级。
            .pointerLiquidEdge(cornerRadius: 17, tint: palette.accent.color, intensity: 1.45)
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
        if shouldRestartCurrentTrackForAdjacentCommand {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: -1)
        }
    }

    private func playNextTrack() {
        if shouldRestartCurrentTrackForAdjacentCommand {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: 1)
        }
    }

    private var shouldRestartCurrentTrackForAdjacentCommand: Bool {
        appState.musicRepeatMode == .repeatOne ||
            (appState.musicRepeatMode == .repeatAll && appState.musicQueue.count <= 1)
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
                PerceptualVolumeScale.sliderValue(fromLinear: Double(volumeObserver.state.volume))
            }, set: { newValue in
                controller.setVolume(Float(PerceptualVolumeScale.linearVolume(fromSlider: newValue)))
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
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                Text(error)
                    .lineLimit(1)
                    .foregroundStyle(.orange)
                Spacer()
                Button("重试") {
                    controller.configureMusic(item: item, settings: appState.settings)
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 22))
            }
            .font(.caption)
            .frame(maxHeight: 22)
            .clipped()
        } else if state.isPreparing {
            AppInlineNoticeLabel(text: "正在准备播放器", systemImage: "progress.indicator", lineLimit: 1)
                .frame(maxHeight: 18)
        }
    }
}

// 音乐展开页进度/音量/状态投影观察者已物理拆分到 MusicExpandedStateObservers.swift（零行为变化）。

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
    @State private var handledFinishedItemID: String?

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
            handlePlaybackFinished()
        }
        guard configuredItem?.id != targetItem.id else { return }
        let previousItem = configuredItem
        let previousDuration = controller.duration
        configuredItem = targetItem
        handledFinishedItemID = nil
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

    private func handlePlaybackFinished() {
        guard let finishedItem = currentActiveMusicItem ?? configuredItem else { return }
        if appState.musicRepeatMode == .repeatOne ||
            (appState.musicRepeatMode == .repeatAll && appState.musicQueue.count <= 1) {
            handledFinishedItemID = nil
            controller.restartFromBeginning()
            refreshNextMusicPreload(for: finishedItem)
            return
        }
        guard handledFinishedItemID != finishedItem.id else { return }
        handledFinishedItemID = finishedItem.id
        appState.playAdjacent(to: finishedItem, direction: 1)
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
                .brightness(0.010)
                .scaleEffect(1.006)
        } else {
            content
        }
    }
}

// 歌词当前行投影观察者（含 LyricLineHighlightMode / MusicLyricRenderState / MusicLyricSeekRenderState）
// 已物理拆分到 MusicLyricObservers.swift（零行为变化）。

private struct MusicActiveKaraokeLyricLine: View {
    let controller: MpvPlayerController
    let timedLyrics: [TimedLyricLine]
    let line: TimedLyricLine
    let index: Int
    let palette: AlbumColorPalette
    var alignment: LyricLineTextAlignment = .center
    var fontSize: CGFloat = 23
    @StateObject private var progressObserver: MusicLyricActiveLineProgressObserver

    init(
        controller: MpvPlayerController,
        timedLyrics: [TimedLyricLine],
        line: TimedLyricLine,
        index: Int,
        palette: AlbumColorPalette,
        alignment: LyricLineTextAlignment = .center,
        fontSize: CGFloat = 23
    ) {
        self.controller = controller
        self.timedLyrics = timedLyrics
        self.line = line
        self.index = index
        self.palette = palette
        self.alignment = alignment
        self.fontSize = fontSize
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
            progress: state.progress,
            alignment: alignment,
            fontSize: fontSize
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

// 歌词逐字进度投影观察者（含 MusicLyricActiveLineProgressState）已物理拆分到 MusicLyricObservers.swift（零行为变化）。

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

    private var miniChromePalette: AlbumColorPalette {
        .fallback
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedCoverButton
                    .padding(5)
                    .frame(width: 72, height: 72, alignment: .center)
                    .background {
                        MusicMiniPlayerGlassSurface(palette: miniChromePalette, cornerRadius: 18)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .scale(scale: 0.985, anchor: .trailing))
                    ))
                    .zIndex(3)
            } else {
                expandedMiniBar
                    .background {
                        MusicMiniPlayerGlassSurface(palette: miniChromePalette, cornerRadius: 18)
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
            tint: AppColors.pointerLightTint,
            radius: isCollapsed ? 126 : 210,
            intensity: isCollapsed ? 0.54 : 0.62,
            updateInterval: isCollapsed ? 1.0 / 16.0 : 1.0 / 20.0,
            minDistance: isCollapsed ? 12.0 : 10.0
        ))
        .glassPerformanceMode(.full)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(true)
    }

    private var expandedMiniBar: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, 1)
            let showsTrackText = availableWidth >= 590

            ZStack {
                MusicMiniNeutralGlassLightLayer()

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
                        palette: miniChromePalette
                    )
                    .fixedSize()
                    .layoutPriority(3)

                    MusicMiniProgressControl(controller: controller, palette: miniChromePalette)
                        .frame(minWidth: 210, maxWidth: .infinity)
                        .layoutPriority(5)

                    MusicMiniUtilityControls(item: item, controller: controller, palette: miniChromePalette, onRequestClose: onRequestClose)
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
                MusicMiniCollapsedProgressRing(controller: controller, palette: miniChromePalette)
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

                MusicMiniPresetSpectrum(controller: controller, palette: miniChromePalette)
                    .padding(.bottom, 5)
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
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.72),
                                        AppColors.pointerLightTint.opacity(0.18),
                                        .white.opacity(0.20)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    }
                    .shadow(color: AppColors.pointerLightTint.opacity(0.10), radius: 8, y: 3)

                if showText {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(AppColors.refTitleText)
                            .lineLimit(1)
                        Text(item.artistAlbumLine ?? "未知艺人")
                            .font(.caption)
                            .foregroundStyle(AppColors.refSecondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [
                                AppColors.refSearchFill.opacity(0.72),
                                AppColors.refCardBg.opacity(0.48),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .help("展开播放器")
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

// 迷你条收起态进度投影观察者已物理拆分到 MusicMiniStateObservers.swift（零行为变化）。

private struct MusicMiniNeutralGlassLightLayer: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width * 0.72, 520)

            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.060 : 0.18),
                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.045 : 0.12),
                        AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.030 : 0.060),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.24),
                                AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.055 : 0.14),
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
            .opacity(colorScheme == .dark ? 0.36 : 0.48)
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
        // 底栏跟随首页卡片语义材质：真实窗口高斯模糊打底，上层用 refCardBg/refCardBorder
        // 建立稳定层级，避免暗色模式出现亮白玻璃压过文字。
        let isDark = colorScheme == .dark
        let material: NSVisualEffectView.Material = isDark ? .hudWindow : .popover
        let cardOpacity: Double = isDark ? 0.88 : 0.76
        let innerTintOpacity: Double = isDark ? 0.22 : 0.16
        let sheenGradient = LinearGradient(
            colors: [
                .white.opacity(isDark ? 0.070 : 0.30),
                AppColors.solarLightTint.opacity(isDark ? 0.040 : 0.095),
                palette.primary.color.opacity(isDark ? 0.028 : 0.036),
                .clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let strokeGradient = LinearGradient(
            colors: [
                .white.opacity(isDark ? 0.18 : 0.62),
                AppColors.refCardBorder.opacity(isDark ? 0.95 : 0.86),
                palette.accent.color.opacity(isDark ? 0.10 : 0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return AppKitVisualEffectBackground(material: material, blendingMode: .withinWindow)
            .clipShape(shape)
            .overlay {
                shape.fill(AppColors.refCardBg.opacity(cardOpacity))
            }
            .overlay {
                shape.fill(AppColors.refSearchFill.opacity(innerTintOpacity))
                    .blendMode(isDark ? .normal : .screen)
            }
            .overlay {
                shape.fill(sheenGradient)
                    .blendMode(.screen)
            }
            .overlay {
                shape.strokeBorder(strokeGradient, lineWidth: 1)
            }
            .overlay {
                if samplesPointer {
                    LyricsCardEffectLayerView(
                        cornerRadius: cornerRadius,
                        intensity: isDark ? 0.46 : 0.58,
                        colorScheme: colorScheme,
                        isEnabled: true,
                        edgeDepth: isDark ? 0.30 : 0.38,
                        tintColor: palette.primary.nsColor,
                        role: .mini
                    )
                    .allowsHitTesting(false)
                }
            }
            .background {
                GlassPanelShadowLayer(
                    palette: palette,
                    colorScheme: colorScheme,
                    cornerRadius: cornerRadius,
                    tintStrength: isDark ? 0.32 : 0.42,
                    role: .mini
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
        // 稍微加深的主色（降低亮度、略提饱和），用于更实的填充。集中到 palette.deepPlayTint。
        let deepTint = palette.deepPlayTint.color
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
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.26 : 0.34),
                                .clear,
                                .black.opacity(colorScheme == .dark ? 0.10 : 0.055)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
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
            .shadow(color: AppColors.selectedGlassTint.opacity(0.24), radius: 16, y: 6)
    }
}

private struct MusicMiniTransportControls: View {
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

        HStack(spacing: 8) {
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
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: 30, cornerRadius: 15))
    }

    private func playPreviousTrack() {
        if shouldRestartCurrentTrackForAdjacentCommand {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: -1)
        }
    }

    private func playNextTrack() {
        if shouldRestartCurrentTrackForAdjacentCommand {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: 1)
        }
    }

    private var shouldRestartCurrentTrackForAdjacentCommand: Bool {
        appState.musicRepeatMode == .repeatOne ||
            (appState.musicRepeatMode == .repeatAll && appState.musicQueue.count <= 1)
    }
}

// 迷你条传输状态投影观察者已物理拆分到 MusicMiniStateObservers.swift（零行为变化）。

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
            accentColor: NSColor.controlAccentColor
        )
        .frame(width: 34, height: 21, alignment: .bottom)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.black.opacity(0.36))
                .overlay {
                    Capsule()
                        .fill(.white.opacity(0.15))
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
            let spacing: CGFloat = 2.0
            let barWidth: CGFloat = 3.4
            let maxBarHeight: CGFloat = 20
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
                    bar.opacity = Float(isPlaying ? 1.0 : 0.64)
                    bar.colors = [
                        NSColor.white.withAlphaComponent(isPlaying ? 0.98 : 0.66).cgColor,
                        accentColor.withAlphaComponent(isPlaying ? 0.86 : 0.44).cgColor
                    ]
                }
                bar.transform = CATransform3DMakeScale(1, max(height / maxBarHeight, 0.16), 1)
            }
            CATransaction.commit()
            needsColorUpdate = false
            lastLaidOutBounds = bounds
            lastBarCount = count
        }

        private static let minimumBandBucket = 10
        private static let maximumBandBucket = 100

        private static func bucketedBands(_ bands: [CGFloat]) -> [Int] {
            guard !bands.isEmpty else { return [minimumBandBucket] }
            return bands.map { band in
                let clamped = min(max(band, 0.08), 1)
                let emphasized = pow(clamped, 0.62)
                return Int((emphasized * CGFloat(maximumBandBucket)).rounded())
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
                .foregroundStyle(AppColors.refSecondaryText)
                .frame(width: 38, alignment: .trailing)

            MusicMiniSeekSlider(
                currentTime: state.currentTime,
                duration: state.duration,
                isPlaying: state.isPlaying,
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
                .foregroundStyle(AppColors.refSecondaryText)
                .frame(width: 38, alignment: .leading)
        }
    }
}

private struct MusicMiniSeekSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let currentTime: Double
    let duration: Double
    var isPlaying = false
    let isEnabled: Bool
    let palette: AlbumColorPalette
    var trackHeight: CGFloat = 5
    var thumbSize: CGFloat = 14
    var usesPaletteTint = true
    /// 无界：未播放轨道底色改为透明液态磨砂玻璃（而非黑色凹槽）。默认 false 保持琉璃原样。
    var glassTrack = false
    let onScrubBegin: (Double) -> Void
    let onScrubChange: (Double) -> Void
    let onSeek: (Double) -> Void
    @State private var draggingProgress: Double?
    @State private var isHovering = false
    @State private var sheenPhase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = PlaybackTimelinePolicy.clampedUnit(draggingProgress ?? normalizedProgress)
            let fillWidth = max(width * CGFloat(progress), 0)
            let thumbRadius = thumbSize / 2
            let thumbX = min(max(fillWidth, thumbRadius), width - thumbRadius)
            let sheenActive = isEnabled && isPlaying && !reduceMotion && progress > 0.035
            // §5.1 thumb：白色圆点 + 极细 primary 描边；hover/拖动时略放大并加一圈 primary 柔光。
            let thumbActive = isEnabled && (draggingProgress != nil || isHovering)
            let thumbRingColor = usesPaletteTint ? palette.primary.color : Color.white
            let thumbRingOpacity = usesPaletteTint
                ? (colorScheme == .dark ? 0.82 : 0.88)
                : (colorScheme == .dark ? 0.32 : 0.84)
            let thumbRingWidth: CGFloat = usesPaletteTint ? 1.2 : 0.8

            ZStack(alignment: .leading) {
                Group {
                    if glassTrack {
                        // 透明液态玻璃槽：真实背景模糊 + 一层极淡白霜，不再是黑色凹槽。
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Capsule().fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.12))
                            }
                    } else {
                        Capsule()
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.32 : (usesPaletteTint ? 0.20 : 0.12)))
                    }
                }
                // 玻璃凹槽感：顶部内阴影(暗) → 底部内高光(亮)，轨道呈现下凹的玻璃槽，而非平面色条。
                .overlay {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .black.opacity(colorScheme == .dark ? 0.24 : (glassTrack ? 0.08 : 0.13)),
                                    .clear,
                                    .white.opacity(colorScheme == .dark ? 0.10 : 0.32)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.34), lineWidth: 0.6)
                }
                .frame(height: trackHeight)

                Capsule()
                    // 已播放段只使用专辑高斯主色本身，避免上下双色或白色顶沿把进度条切成两层。
                    .fill(progressFillColor(isEnabled: isEnabled))
                    .frame(width: fillWidth, height: trackHeight)
                    .overlay(alignment: .leading) {
                        if sheenActive {
                            playingSheen(fillWidth: fillWidth)
                        }
                    }

                Circle()
                    .fill(.white.opacity(isEnabled ? 0.96 : 0.70))
                    .overlay {
                        Circle()
                            .strokeBorder(thumbRingColor.opacity(thumbRingOpacity), lineWidth: thumbRingWidth)
                    }
                    // hover/拖动时围绕 thumb 的 primary 柔光（呼应封面发光，强度受控）。
                    .shadow(
                        color: palette.primary.color.opacity(thumbActive ? 0.42 : 0),
                        radius: thumbActive ? MusicPlayerVisualTokens.Progress.thumbGlowRadius : 0
                    )
                    .shadow(color: (usesPaletteTint ? palette.accent.color : AppColors.selectedGlassTint).opacity(isEnabled ? 0.16 : 0), radius: 6, y: 2)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 4, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .scaleEffect(thumbActive ? (thumbSize + MusicPlayerVisualTokens.Progress.thumbActiveGrowth) / thumbSize : 1)
                    .offset(x: thumbX - thumbRadius)
                    .animation(reduceMotion ? nil : AppMotion.fast, value: thumbActive)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard isEnabled else { isHovering = false; return }
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let progress = PlaybackTimelinePolicy.clampedUnit(Double(value.location.x / width))
                        let target = PlaybackTimelinePolicy.timelineTime(
                            forHorizontalPosition: Double(value.location.x),
                            width: Double(width),
                            duration: max(duration, 1)
                        )
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
                        draggingProgress = nil
                        onSeek(
                            PlaybackTimelinePolicy.timelineTime(
                                forHorizontalPosition: Double(value.location.x),
                                width: Double(width),
                                duration: max(duration, 1)
                            )
                        )
                    }
            )
            .onAppear {
                updateSheenAnimation(active: sheenActive)
            }
            .onChange(of: sheenActive) { active in
                updateSheenAnimation(active: active)
            }
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int((normalizedProgress * 100).rounded()))%")
    }

    @ViewBuilder
    private func playingSheen(fillWidth: CGFloat) -> some View {
        let sheenWidth = min(
            max(fillWidth * MusicPlayerVisualTokens.Progress.sheenWidthRatio, MusicPlayerVisualTokens.Progress.sheenWidthMin),
            MusicPlayerVisualTokens.Progress.sheenWidthMax
        )
        let sheenColor = usesPaletteTint ? palette.progressLight.color : AppColors.pointerLightTint
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        sheenColor.opacity(MusicPlayerVisualTokens.Progress.sheenOpacity(dark: colorScheme == .dark) * 0.78),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: sheenWidth, height: trackHeight)
            .offset(x: -sheenWidth + (fillWidth + sheenWidth) * sheenPhase)
            .blendMode(.screen)
            .mask(alignment: .leading) {
                Capsule().frame(width: fillWidth, height: trackHeight)
            }
            .allowsHitTesting(false)
    }

    private func updateSheenAnimation(active: Bool) {
        if active {
            sheenPhase = 0
            withAnimation(.linear(duration: MusicPlayerVisualTokens.Progress.sheenDuration).repeatForever(autoreverses: false)) {
                sheenPhase = 1
            }
        } else {
            sheenPhase = 0
        }
    }

    private var normalizedProgress: Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
        return currentTime / duration
    }

    private func progressFillColor(isEnabled: Bool) -> Color {
        if usesPaletteTint {
            return palette.primary.color.opacity(isEnabled ? 0.98 : 0.42)
        }
        return AppColors.selectedGlassTint.opacity(isEnabled ? 0.94 : 0.38)
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
                PerceptualVolumeScale.sliderValue(fromLinear: Double(volumeObserver.state.volume))
            }, set: { newValue in
                controller.setVolume(Float(PerceptualVolumeScale.linearVolume(fromSlider: newValue)))
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

struct MusicQueuePopover: View {
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
            HStack(spacing: 10) {
                AppSectionHeading(
                    title: "播放队列",
                    subtitle: queue.isEmpty ? "等待加入歌曲" : "拖动歌曲可调整播放顺序",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    badgeText: queue.isEmpty ? nil : "\(queue.count) 首"
                )

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
                            .opacity(draggedItem?.id == row.id ? 0.48 : 1)
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
                                Button {
                                    appState.musicQueueScrollAnchorID = row.id
                                    appState.play(row.track)
                                } label: {
                                    Label("播放", systemImage: "play.fill")
                                }
                                Button {
                                    appState.playNextInMusicQueue(row.track)
                                } label: {
                                    Label("下一曲播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                .disabled(row.id == currentItem.id)
                                MusicPlaylistActionsMenu(
                                    tracks: [row.track],
                                    suggestedName: row.titleText,
                                    onCreateNew: { playlistCreationRequest = $0 }
                                )
                                Button {
                                    appState.removeFromMusicQueue(row.track)
                                } label: {
                                    Label("移出队列", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
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

// MusicQueueDragCoordinator 已物理拆分到 MusicQueueDragCoordinator.swift（零行为变化）。

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
                HStack(spacing: 6) {
                    Text(row.titleText)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    if isCurrent {
                        MusicCompactStatusBadge(
                            title: "播放中",
                            systemImage: "speaker.wave.2.fill"
                        )
                    }
                }
                Text(row.subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if row.track.favorite {
                Image(systemName: "heart.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red.opacity(0.82))
                    .accessibilityLabel("喜欢")
            }
            if row.track.isRemoteResource {
                Image(systemName: "cloud")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("远程歌曲")
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
        .background(
            AppColors.cleanFieldFill.opacity(isCurrent ? 0.92 : 0.62),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isCurrent
                        ? AppColors.selectedGlassTint.opacity(0.30)
                        : AppColors.cleanPanelBorder.opacity(0.70),
                    lineWidth: 0.85
                )
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(AppColors.selectedGlassTint.opacity(isCurrent ? 0.88 : 0))
                .frame(width: 3, height: 26)
                .padding(.leading, 2)
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
                .foregroundStyle(item.favorite ? Color.red : AppColors.refSecondaryText)
                .frame(width: size, height: size)
        }
        .buttonStyle(MusicIconButtonStyle(palette: palette, size: size, cornerRadius: size / 2, glowStrength: glowStrength))
        .help(item.favorite ? "取消喜欢" : "我喜欢")
        .accessibilityLabel(item.favorite ? "取消喜欢" : "我喜欢")
    }
}

private struct MusicIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let palette: AlbumColorPalette
    var size: CGFloat = 30
    var cornerRadius: CGFloat = 15
    var glowStrength: Double = 1

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glow = min(max(glowStrength, 0.25), 1.45)

        configuration.label
            .frame(width: size, height: size)
            // 底栏和展开页有多枚图标按钮，逐个使用实时 material 会产生多块离屏 backdrop 模糊。
            // 这里改用实色磨砂底，保留接近的玻璃观感并避免额外离屏通道。
            .background(
                shape.fill(AppColors.refSearchFill.opacity(colorScheme == .dark ? 0.82 : 0.96))
            )
            .background(
                shape.fill(palette.albumGlassBaseColor(for: colorScheme).opacity((colorScheme == .dark ? 0.16 : 0.12) * glow))
            )
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.055 : 0.28),
                            palette.primary.color.opacity((colorScheme == .dark ? 0.13 : 0.14) * glow),
                            palette.accent.color.opacity((colorScheme == .dark ? 0.075 : 0.070) * glow)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.10 : 0.46), lineWidth: 0.9)
                    .blur(radius: 0.5)
                    .blendMode(.screen)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            AppColors.refCardBorder.opacity(colorScheme == .dark ? 0.95 : 0.78),
                            palette.primary.color.opacity((colorScheme == .dark ? 0.18 : 0.26) * glow),
                            palette.accent.color.opacity((colorScheme == .dark ? 0.16 : 0.18) * glow)
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
            // 按下反馈用玻璃高光（短暂提亮）+ 轻微缩放，而非简单降低不透明度。
            .brightness(configuration.isPressed ? (colorScheme == .dark ? 0.06 : 0.05) : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .animation(AppMotion.fast, value: configuration.isPressed)
    }
}

/// 形状无关的玻璃按压样式：按下时整块标签短暂提亮（玻璃高光）并轻微缩小，
/// 而非简单改透明度。用于自带完整玻璃外观的按钮（主播放键、收起键），与 MusicIconButtonStyle 的反馈语言一致。
struct MusicGlassPressStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressScale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? (colorScheme == .dark ? 0.06 : 0.05) : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressScale : 1)
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
        let accent = palette?.accent.color ?? AppColors.selectedGlassTint
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isActive ? accent : AppColors.refSecondaryText)
            .frame(width: size, height: size)
            // 循环/随机图标在底栏也会出现，使用实色磨砂底避免重复创建实时 material。
            .background(Circle().fill(AppColors.refSearchFill.opacity(colorScheme == .dark ? 0.82 : 0.96)))
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.055 : 0.34),
                                tint.opacity(colorScheme == .dark ? 0.12 : 0.12),
                                .white.opacity(colorScheme == .dark ? 0.025 : 0.18)
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
                                AppColors.refCardBorder.opacity(colorScheme == .dark ? 0.95 : 0.80),
                                tint.opacity(colorScheme == .dark ? 0.12 : 0.22),
                                AppColors.refOutlineBorder.opacity(colorScheme == .dark ? 0.72 : 1.0)
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

struct MusicChromeButtonContent: View {
    let systemImage: String
    let palette: AlbumColorPalette
    let controller: MpvPlayerController

    var body: some View {
        ZStack {
            AlbumLightSpillOverlay(
                palette: palette,
                controller: controller,
                cornerRadius: MusicPlayerVisualTokens.Radius.chrome,
                intensity: MusicPlayerVisualTokens.Spill.chromeIntensity,
                reach: MusicPlayerVisualTokens.Spill.chromeReach,
                sourceEdge: .topLeading,
                light: .fallbackChrome
            )
            .allowsHitTesting(false)

            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                Text("收起")
                    .font(.callout.weight(.semibold))
            }
        }
        .foregroundStyle(Color.primary.opacity(0.82))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: MusicPlayerVisualTokens.Radius.chrome, tintStrength: 1.0, role: .lyrics))
        .pointerLiquidEdge(cornerRadius: MusicPlayerVisualTokens.Radius.chrome, tint: .white, intensity: 0.72)
    }
}

struct MusicExpandedLayout {
    let stackedLayout: Bool
    let sideInset: CGFloat
    let verticalInset: CGFloat
    let leftRect: CGRect
    let lyricsRect: CGRect
    let controlsRect: CGRect
    let posterSize: CGFloat
    /// 实际显示的封面边长（stacked 布局下被压到 ≤230）。
    let coverDisplaySide: CGFloat
    /// 真·封面发光（模糊大封面）的画布边长 = coverDisplaySide × 几何 reach。
    let glowBlurSide: CGFloat
    /// 从封面光心到目标受光边界的真实半径，等于歌词卡左缘/控制栏上沿距离 + overshoot。
    let albumGlowRadius: CGFloat
    let minimizeButtonRect: CGRect
    let albumLightCenter: CGPoint
    let stackedLyricsHeight: CGFloat
    // §2.1 封面外层环境光的目标 reach（相对 posterSize 的倍数）：按"光心→歌词卡左缘 / 控制栏上边界"
    // 的较远几何距离驱动，让发光以同一半径自然触达关键玻璃面。
    let albumGlowReach: CGFloat
    let lyricsLight: AlbumComponentLight
    let controlsLight: AlbumComponentLight
    /// 无界方案专用：以封面光心为中心、足以铺满整窗的发光画布边长（= 光心到最远屏角距离 × 2 × 余量）。
    let fullScreenGlowSide: CGFloat

    init(size: CGSize) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let compactWidth = width < 1180

        sideInset = compactWidth ? 30 : 54
        let panelInset = min(max(height * 0.072, compactWidth ? 56 : 72), compactWidth ? 82 : 104)
        verticalInset = panelInset
        let contentLeadingInset = sideInset + (compactWidth ? 8 : 22)
        let trailingInset = contentLeadingInset
        let desiredGap = compactWidth ? 32.0 : 50.0
        let minimumGap = compactWidth ? 24.0 : 38.0
        let minimumLeftWidth = compactWidth ? 388.0 : 416.0
        let minimumLyricsWidth = compactWidth ? 360.0 : 460.0
        let availableColumnsWidth = width - contentLeadingInset - trailingInset
        let canFitColumns = availableColumnsWidth >= minimumLeftWidth + minimumLyricsWidth + minimumGap
        stackedLayout = !canFitColumns || height < 640

        let minimizeButtonSize = CGSize(width: compactWidth ? 72 : 82, height: 46)
        let minimizeLeadingInset = stackedLayout ? sideInset : contentLeadingInset
        let minimizeTopInset = stackedLayout ? 18.0 : panelInset
        minimizeButtonRect = CGRect(origin: CGPoint(x: minimizeLeadingInset, y: minimizeTopInset), size: minimizeButtonSize)

        let desiredLeftWidth = min(max(width * 0.318, minimumLeftWidth), compactWidth ? 452 : 512)
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

        // 视觉重心略向右侧歌词卡让渡：封面比上一版收小一点，避免左侧过重。
        let reservedForTitleAndControls = compactWidth ? 258.0 : 280.0
        let heightBoundedPoster = max(174.0, availableHeight - reservedForTitleAndControls)
        let resolvedPosterSize = min(leftWidth - 58.0, heightBoundedPoster, availableHeight * 0.455, compactWidth ? 404.0 : 458.0)
        posterSize = resolvedPosterSize
        let shownCoverSize = stackedLayout ? min(resolvedPosterSize, 230.0) : resolvedPosterSize
        coverDisplaySide = shownCoverSize

        let controlsEstimate = MusicPlayerVisualTokens.Controls.expandedHeight
        let posterBlockHeight = resolvedPosterSize + 16.0 + 82.0 + 16.0 + controlsEstimate
        let posterTop = leftFrame.minY + max(0, (availableHeight - posterBlockHeight) / 2)
        let controlsTop = posterTop + resolvedPosterSize + 16.0 + 82.0 + 16.0
        let controlsWidth = min(MusicPlayerVisualTokens.Controls.expandedMaxWidth, leftFrame.width)
        let controlsFrame = CGRect(
            x: leftFrame.midX - controlsWidth * 0.5,
            y: controlsTop,
            width: controlsWidth,
            height: controlsEstimate
        )
        controlsRect = controlsFrame
        let resolvedAlbumLightCenter: CGPoint
        if stackedLayout {
            resolvedAlbumLightCenter = CGPoint(x: width * 0.34, y: min(max(height * 0.32, 210), height * 0.50))
        } else {
            resolvedAlbumLightCenter = CGPoint(x: leftFrame.midX, y: posterTop + resolvedPosterSize / 2)
        }
        albumLightCenter = resolvedAlbumLightCenter

        // 几何落点：外层环境光半径 ≈ posterSize * reach / 2。取“歌词卡左缘”和“控制栏上边界”
        // 两个目标中的较远者，让封面光以同一圆形半径等距扩散，刚好触到最近的关键玻璃面。
        // stacked 布局下歌词卡随 ScrollView 浮动、位置不稳定，改用兜底倍数（vibrancy 增益仍在视图层叠加）。
        let overshoot = MusicPlayerVisualTokens.Glow.edgeOvershoot
        let resolvedAlbumGlowReach: CGFloat
        let resolvedAlbumGlowRadius: CGFloat
        if stackedLayout {
            resolvedAlbumGlowReach = MusicPlayerVisualTokens.Glow.fallbackReach
            resolvedAlbumGlowRadius = shownCoverSize * MusicPlayerVisualTokens.Glow.fallbackReach * 0.5
        } else {
            let horizontalGap = max(lyricsFrame.minX - resolvedAlbumLightCenter.x, resolvedPosterSize * 0.5)
            let verticalGap = max(controlsTop - resolvedAlbumLightCenter.y, resolvedPosterSize * 0.5)
            let targetDistance = max(horizontalGap, verticalGap) + overshoot
            let denom = max(resolvedPosterSize * MusicPlayerVisualTokens.Glow.bloomVisibleFraction, 1)
            let geometricReach = (2 * targetDistance) / denom
            resolvedAlbumGlowReach = min(max(geometricReach, MusicPlayerVisualTokens.Glow.minReach), MusicPlayerVisualTokens.Glow.maxReach)
            resolvedAlbumGlowRadius = targetDistance
        }
        albumGlowReach = resolvedAlbumGlowReach
        albumGlowRadius = resolvedAlbumGlowRadius
        let componentLightRadius = resolvedAlbumGlowRadius * 2.0
        lyricsLight = stackedLayout
            ? .fallbackLyrics
            : AlbumComponentLight.leading(
                rect: lyricsFrame,
                center: resolvedAlbumLightCenter,
                radius: componentLightRadius,
                coverSide: shownCoverSize,
                overshoot: overshoot
            )
        controlsLight = stackedLayout
            ? .fallbackControls
            : AlbumComponentLight.top(
                rect: controlsFrame,
                center: resolvedAlbumLightCenter,
                radius: componentLightRadius,
                coverSide: shownCoverSize,
                overshoot: overshoot
            )

        // 发光画布 = 封面边长 × 几何 reach（少量余量）：光程触达歌词卡左缘 / 控制栏并略超出，
        // 羽化衰减在烘焙阶段按同一几何完成，不再需要额外的投影光池层。
        glowBlurSide = shownCoverSize * min(max(resolvedAlbumGlowReach * 2.04, 3.8), 11.8)

        // 无界：发光铺满整窗。以封面光心为圆心，取到四个屏角的最远距离 × 2 × 余量作为画布边长，
        // 保证封面柔光从封面位置自然扩散并覆盖整个窗口（含右侧歌词区）。
        let glowCenter = resolvedAlbumLightCenter
        let cornerDistances = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: 0, y: height),
            CGPoint(x: width, y: height)
        ].map { hypot($0.x - glowCenter.x, $0.y - glowCenter.y) }
        let farthestCorner = cornerDistances.max() ?? max(width, height)
        fullScreenGlowSide = farthestCorner * 2 * 1.04
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
    var role: MusicGlassSurfaceRole = .lyrics
    var centerClarity: Bool = false

    private var samplesPointer: Bool {
        !reduceMotion &&
        !suppressHoverDuringScroll &&
        !preferStaticGlassSurfaces &&
        glassPerformanceMode.allowsPointerSampling
    }

    private func tintOpacity(_ value: Double) -> Double {
        value * tintStrength
    }

    private var frostTextureOpacity: Double {
        MusicPlayerVisualTokens.Glass.frostTexture(dark: colorScheme == .dark)
    }

    private var materialOpacity: Double {
        role.materialOpacity(dark: colorScheme == .dark, centerClarity: centerClarity)
    }

    private func centerAwareStops(color: Color, opacity: Double, centerMultiplier: Double) -> [Gradient.Stop] {
        let center = centerClarity ? centerMultiplier : 1.0
        return [
            .init(color: color.opacity(opacity), location: 0.0),
            .init(color: color.opacity(opacity * 0.96), location: 0.24),
            .init(color: color.opacity(opacity * center), location: 0.41),
            .init(color: color.opacity(opacity * center), location: 0.59),
            .init(color: color.opacity(opacity * 0.96), location: 0.76),
            .init(color: color.opacity(opacity), location: 1.0)
        ]
    }

    @ViewBuilder
    private func fillLayer(
        shape: RoundedRectangle,
        color: Color,
        opacity: Double,
        centerMultiplier: Double
    ) -> some View {
        if centerClarity {
            shape.fill(LinearGradient(
                stops: centerAwareStops(color: color, opacity: opacity, centerMultiplier: centerMultiplier),
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            shape.fill(color.opacity(opacity))
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        let usesNeutralMaterial = role.usesNeutralFloatingMaterial
        let neutralTint = isDark ? Color.black : Color.white
        let glassTint = neutralTint.opacity(role.neutralTintOpacity(dark: isDark))
        let albumTint = palette.albumGlassBaseColor(for: colorScheme)
            .opacity(role.albumTintOpacity(dark: isDark) * tintStrength)
        let material: NSVisualEffectView.Material = usesNeutralMaterial ? .popover : .hudWindow
        // R2：玻璃高光/镜面带的专辑色更饱和、更亮——让玻璃反射出"有颜色的光"，去灰。
        let albumEffectTint = palette.glowPrimary.adjustedPreservingHue(
            saturationMultiplier: 0.84,
            brightnessMultiplier: 1.06,
            minSaturation: 0.08,
            maxSaturation: isDark ? 0.48 : 0.44,
            minBrightness: isDark ? 0.52 : 0.68,
            maxBrightness: isDark ? 0.84 : 0.92
        )
        let effectTint = usesNeutralMaterial ? albumEffectTint.nsColor : palette.glowPrimary.nsColor
        // R4：三块琉璃玻璃（中性 material）的描边中段专辑色加重，让边缘明显"染上歌曲的颜色"。
        let strokeMidColor = usesNeutralMaterial
            ? albumEffectTint.color.opacity(isDark ? 0.27 : 0.31)
            : palette.glowPrimary.color.opacity(MusicPlayerVisualTokens.Glass.strokeMidAlbum(dark: isDark))
        // §需求3 玻璃受光彩色化：高光/描边的"白"统一替换为带封面主色的镜面色——
        // 光照在玻璃上呈现的是光本身的颜色，而不是无色相的白边。
        let specular = palette.glowPrimary.adjustedPreservingHue(
            saturationMultiplier: 0.66,
            brightnessMultiplier: 1.12,
            minSaturation: 0.10,
            maxSaturation: isDark ? 0.36 : 0.30,
            minBrightness: 0.84,
            maxBrightness: 0.97
        ).color

        let frostWhite = MusicPlayerVisualTokens.Glass.frostWhite(dark: isDark)
        let edgeFrostWhite = frostWhite * (centerClarity ? 1.14 : 1.0)
        let textureOpacity = frostTextureOpacity * role.textureMultiplier(centerClarity: centerClarity)
        return content
            .background {
                fillLayer(shape: shape, color: .white, opacity: edgeFrostWhite, centerMultiplier: centerClarity ? 0.38 : 0.62)
            }
            .background {
                // 统一玻璃面板：歌词卡与控制栏/收起按钮使用更干净的局部 popover material。
                // 颜色与质感完全一致——之前歌词卡用静态白色磨砂 fill 会比控制栏更灰更平，故回归 material 统一。
                // 中心通透感交给静态 fill 渐变与 CA effect layer；这里不再给 material 挂实时 mask，
                // 避免歌词卡大面积离屏合成重新拉高 WindowServer/GPU 压力。
                AppKitVisualEffectBackground(material: material, blendingMode: .withinWindow)
                    .opacity(materialOpacity)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
            .background {
                fillLayer(shape: shape, color: glassTint, opacity: 1, centerMultiplier: centerClarity ? 0.58 : 0.74)
            }
            .background {
                fillLayer(shape: shape, color: albumTint, opacity: 1, centerMultiplier: centerClarity ? 0.60 : 0.78)
            }
            .background {
                FrostedGlassTextureOverlay(opacity: textureOpacity)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
            .overlay {
                LyricsCardEffectLayerView(
                    cornerRadius: cornerRadius,
                    intensity: role.effectIntensity,
                    colorScheme: colorScheme,
                    isEnabled: samplesPointer,
                    edgeDepth: role.edgeDepth,
                    tintColor: effectTint,
                    centerClarity: centerClarity,
                    role: role
                )
                .allowsHitTesting(false)
            }
            // 顶部高光：很窄、只在最上方一点点，模拟玻璃上沿受光（token 统一三块玻璃逻辑）。
        .overlay(alignment: .top) {
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            // 顶部受光收窄成贴边细高光（之前 16.5% 高度的亮带 + 静态玻璃层顶部渐变
                            // 叠出一片"被照亮"的错误观感）：只保留玻璃上沿一条细的受光线。
                            .init(
                                    color: specular.opacity(MusicPlayerVisualTokens.Glass.topHighlight(dark: isDark) * 0.50),
                                    location: 0.00
                                ),
                                .init(
                                    color: palette.glowPrimary.color.opacity(MusicPlayerVisualTokens.Glass.topHighlight(dark: isDark) * 0.12),
                                    location: 0.026
                                ),
                                .init(
                                    color: specular.opacity(MusicPlayerVisualTokens.Glass.topHighlight(dark: isDark) * 0.045),
                                    location: 0.058
                                ),
                                .init(color: .clear, location: 0.105)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
            // §1.3 底沿内侧极淡暗线：仅最底一小段压暗，与顶部高光形成"上受光、下背光"的玻璃片厚度感。
            // 居中歌词文字不受影响（仅作用于卡片最底 ~6%），放在描边之下让发丝边仍清晰。
            .overlay(alignment: .bottom) {
                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .clear, location: 0.94),
                                .init(color: .black.opacity(MusicPlayerVisualTokens.Glass.bottomShade(dark: isDark)), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
            // 发丝描边：上亮下暗，给玻璃一个清晰但克制的边（token 统一三块玻璃描边方向与三色）。
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            specular.opacity(MusicPlayerVisualTokens.Glass.strokeTopWhite(dark: isDark)),
                            strokeMidColor,
                            .black.opacity(MusicPlayerVisualTokens.Glass.strokeBottomBlack(dark: isDark))
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
                    role: role
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
    let role: MusicGlassSurfaceRole

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView(frame: .zero)
        view.update(
            palette: palette,
            colorScheme: colorScheme,
            cornerRadius: cornerRadius,
            tintStrength: tintStrength,
            role: role
        )
        return view
    }

    func updateNSView(_ nsView: LayerView, context: Context) {
        nsView.update(
            palette: palette,
            colorScheme: colorScheme,
            cornerRadius: cornerRadius,
            tintStrength: tintStrength,
            role: role
        )
    }

    final class LayerView: NSView {
        private let colorShadowLayer = CALayer()
        private let depthShadowLayer = CALayer()
        private var palette = AlbumColorPalette.fallback
        private var colorScheme: ColorScheme = .light
        private var cornerRadius: CGFloat = 24
        private var tintStrength: Double = 1
        private var role: MusicGlassSurfaceRole = .lyrics

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
            role: MusicGlassSurfaceRole
        ) {
            self.palette = palette
            self.colorScheme = colorScheme
            self.cornerRadius = cornerRadius
            self.tintStrength = tintStrength
            self.role = role

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
            let isDark = colorScheme == .dark
            if role.usesNeutralFloatingMaterial {
                colorShadowLayer.shadowColor = (isDark ? NSColor.white : NSColor.black).cgColor
                colorShadowLayer.shadowOpacity = Float((isDark ? 0.040 : 0.026) * tint)
                colorShadowLayer.shadowRadius = role.shadowColorRadius * 0.82
                colorShadowLayer.shadowOffset = CGSize(width: -4, height: 7)
            } else {
                let colorOpacity = Float(role.shadowColorOpacity(dark: isDark) * tint)
                colorShadowLayer.shadowColor = palette.primary.nsColor.cgColor
                colorShadowLayer.shadowOpacity = colorOpacity
                colorShadowLayer.shadowRadius = role.shadowColorRadius
                colorShadowLayer.shadowOffset = CGSize(width: -6, height: 9)
            }

            depthShadowLayer.shadowColor = NSColor.black.cgColor
            depthShadowLayer.shadowOpacity = Float(role.shadowDepthOpacity(dark: isDark))
            depthShadowLayer.shadowRadius = role.shadowDepthRadius
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
            .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: cornerRadius, tintStrength: tintStrength, role: .lyrics))
    }
}

private struct MusicPopoverGlass: ViewModifier {
    let palette: AlbumColorPalette
    let cornerRadius: CGFloat
    var tintStrength: Double = 0.72

    func body(content: Content) -> some View {
        content
            .modifier(FloatingLyricsGlass(palette: palette, cornerRadius: cornerRadius, tintStrength: tintStrength, role: .popover))
    }
}


/// 歌词行的横向对齐方式。琉璃方案居中（卡片内），无界方案左对齐（右侧栏内贴左，参考 Apple Music）。
/// 当前行无论哪套方案都恒定锁在视口中心（由 ScrollView anchor: .center 保证）。
enum LyricLineTextAlignment: Equatable {
    case center
    case leading
    case trailing

    var textAlignment: TextAlignment {
        switch self {
        case .center: return .center
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .center: return .center
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    var stackAlignment: HorizontalAlignment {
        switch self {
        case .center: return .center
        case .leading: return .leading
        case .trailing: return .trailing
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
    var alignment: LyricLineTextAlignment = .center
    var fontSize: CGFloat = 23

    // R5-2 性能：歌词字符填充实际只按 progressBucket（48 级量化）变化，逐字片段按 segment 头位置变化。
    // 默认 Equatable 会比较原始 currentTime/progress，使每 0.18s 时钟 tick 都判定为“变化”→整行重渲染。
    // 这里改为按可见量化粒度比较：同一 bucket 内的时钟更新不再触发重绘，视觉完全一致但合成负担显著下降。
    static func == (lhs: KaraokeLyricLine, rhs: KaraokeLyricLine) -> Bool {
        lhs.isActive == rhs.isActive &&
        lhs.highlightMode == rhs.highlightMode &&
        lhs.line == rhs.line &&
        lhs.palette == rhs.palette &&
        lhs.alignment == rhs.alignment &&
        lhs.fontSize == rhs.fontSize &&
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
    private var baseFont: Font { Font.system(size: fontSize, weight: .bold, design: .rounded) }
    private var lineSpacingValue: CGFloat { fontSize * 0.35 }

    var body: some View {
        if isActive {
            activeLine
                .font(baseFont)
                .multilineTextAlignment(alignment.textAlignment)
                .lineSpacing(lineSpacingValue)
                .shadow(color: palette.primary.color.opacity(0.18), radius: 16, y: 6)
                .transition(.identity)
                .animation(AppMotion.lyricFlow, value: progressBucket)
        } else {
            Text(line.text)
                .font(baseFont)
                .foregroundStyle(Color.primary.opacity(0.60))
                .multilineTextAlignment(alignment.textAlignment)
                .lineSpacing(lineSpacingValue)
                .transition(.identity)
        }
    }

    @ViewBuilder
    private var activeLine: some View {
        if highlightMode == .fullLineDuringSeek {
            Text(line.text)
                .fontWeight(.heavy)
                .foregroundStyle(palette.playedLyric.color.opacity(1.0))
                .transition(.opacity)
        } else if !line.segments.isEmpty {
            SegmentedLyricFlowText(segments: line.segments, currentTime: currentTime, palette: palette, alignment: alignment)
        } else {
            LyricProgressWrappingText(
                text: line.text,
                timing: .estimated(line: line, progress: progress),
                palette: palette,
                alignment: alignment
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


private struct SegmentedLyricFlowText: View {
    let segments: [TimedLyricSegment]
    let currentTime: Double
    let palette: AlbumColorPalette
    var alignment: LyricLineTextAlignment = .center

    var body: some View {
        LyricFlowLayout(spacing: 0, lineSpacing: 7, alignment: alignment) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                Text(segment.text)
                    .foregroundStyle(color(for: index))
                    .fontWeight(weight(for: index))
                    .scaleEffect(segmentScale(for: index), anchor: .bottom)
                    .offset(y: verticalOffset(for: index))
                    .animation(AppMotion.lyricFlow, value: activeSegmentIndex)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
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
            return palette.playedLyric.color.opacity(1.0)
        }
        if index == activeSegmentIndex {
            let blend = localProgress(for: index)
            return palette.playedLyric.color.opacity(0.68 + blend * 0.30)
        }
        return Color.primary.opacity(0.54)
    }

    private func weight(for index: Int) -> Font.Weight {
        index == activeSegmentIndex ? .heavy : .bold
    }

    private func segmentScale(for index: Int) -> CGFloat {
        // 正在唱的词轻微放大(~1.08)，其余为原字号。
        guard index == activeSegmentIndex else { return 1.0 }
        let p = localProgress(for: index)
        let bump = sin(min(max(p, 0), 1) * .pi)  // 0→1→0
        return 1.0 + 0.075 * (0.55 + 0.45 * bump)
    }

    private func verticalOffset(for index: Int) -> CGFloat {
        // 未播放词略低、已播放词略上浮；继续收窄高低差，让同一行更像平滑流动。
        if index < activeSegmentIndex { return -1.25 }
        if index > activeSegmentIndex { return 1.25 }
        let eased = easeOutCubic(riseProgress(for: index))
        return CGFloat(1.25 - eased * 2.5)
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
    var alignment: LyricLineTextAlignment = .center

    var body: some View {
        let glyphs = Array(text).enumerated().map { entry in
            LyricGlyph(id: entry.offset, value: String(entry.element))
        }
        let totalCount = glyphs.count

        LyricFlowLayout(spacing: 0, lineSpacing: 7, alignment: alignment) {
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
        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
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
            return palette.playedLyric.color.opacity(1.0)
        }
        if distance <= 1.25 {
            let blend = 1 - min(max((distance + 0.35) / 1.60, 0), 1)
            return palette.playedLyric.color.opacity(0.70 + blend * 0.28)
        }
        return Color.primary.opacity(0.54)
    }

    private func weight(for offset: Int) -> Font.Weight {
        abs(Double(offset) - timing.headOriginalPosition) <= 1.25 ? .heavy : .bold
    }

    private func glyphScale(for offset: Int) -> CGFloat {
        // 仅正在唱的字附近放大（倍率收敛到 ~1.08），唱过/未唱均为 1.0。
        let distance = Double(offset) - timing.headOriginalPosition
        if distance > 0.6 { return 1.0 }
        if distance < -1.6 { return 1.0 }
        let proximity = 1 - min(max(abs(distance) / 1.6, 0), 1)
        let eased = proximity * proximity * (3 - 2 * proximity)
        return 1.0 + 0.075 * eased
    }

    private func verticalOffset(for offset: Int) -> CGFloat {
        // Apple Music 式：未播放字在基线附近，已播放字轻微上浮；
        // 播放头处平滑过渡。已播放的字保持上浮，不回落。
        let distance = Double(offset) - timing.headOriginalPosition
        let t = min(max((0.4 - distance) / 1.2, 0), 1)   // distance≤-0.8→1(已播放), ≥0.4→0(未播放)
        let eased = t * t * (3 - 2 * t)
        return CGFloat(1.25 - eased * 2.5)                // +1.25(未播放) → -1.25(已播放)
    }
}

private struct LyricFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var alignment: LyricLineTextAlignment = .center

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
            var x: CGFloat
            switch alignment {
            case .center:
                x = max((maxWidth - rowWidths[rowIndex]) / 2, 0)
            case .leading:
                x = 0
            case .trailing:
                x = max(maxWidth - rowWidths[rowIndex], 0)
            }
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

    /// 主操作（播放按钮/AirPlay tint）统一使用的加深主色：降亮、略提饱和、保色相。
    /// 收拢到一处（§5.3 / §6.1），原先散落在 MusicPrimaryPlayButtonLabel 与 MusicExpandedTransportRow 的同款计算。
    var deepPlayTint: AlbumPaletteColor {
        primary.adjustedPreservingHue(
            saturationMultiplier: MusicPlayerVisualTokens.Tint.playSaturation,
            brightnessMultiplier: MusicPlayerVisualTokens.Tint.playBrightness,
            minSaturation: MusicPlayerVisualTokens.Tint.playMinSaturation,
            maxSaturation: MusicPlayerVisualTokens.Tint.playMaxSaturation,
            minBrightness: MusicPlayerVisualTokens.Tint.playMinBrightness,
            maxBrightness: MusicPlayerVisualTokens.Tint.playMaxBrightness
        )
    }

    // 发光专用色：深色专辑取其稍浅的版本（保色相、提亮），避免深色专辑发出"暗光/脏光"。
    var glowPrimary: AlbumPaletteColor { primary.lightenedForGlow() }
    var glowSecondary: AlbumPaletteColor { secondary.lightenedForGlow() }
    var glowAccent: AlbumPaletteColor { accent.lightenedForGlow() }
    var progressDark: AlbumPaletteColor {
        primary.adjustedPreservingHue(
            saturationMultiplier: 1.10,
            brightnessMultiplier: 0.62,
            minSaturation: 0.30,
            maxSaturation: 0.86,
            minBrightness: 0.24,
            maxBrightness: 0.56
        )
    }
    var progressLight: AlbumPaletteColor {
        primary.adjustedPreservingHue(
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
        let primaryWeight = colorScheme == .dark ? 0.66 : 0.54
        let secondaryWeight = colorScheme == .dark ? 0.23 : 0.23
        let accentWeight = colorScheme == .dark ? 0.15 : 0.17
        let neutralLift = colorScheme == .dark ? 0.014 : 0.030
        let red = primary.red * primaryWeight + secondary.red * secondaryWeight + accent.red * accentWeight + neutralLift
        let green = primary.green * primaryWeight + secondary.green * secondaryWeight + accent.green * accentWeight + neutralLift
        let blue = primary.blue * primaryWeight + secondary.blue * secondaryWeight + accent.blue * accentWeight + neutralLift
        return cleanedBackdropComponents(red: red, green: green, blue: blue, colorScheme: colorScheme)
    }

    func albumGlassBaseColor(for colorScheme: ColorScheme) -> Color {
        let primaryWeight = colorScheme == .dark ? 0.64 : 0.50
        let secondaryWeight = colorScheme == .dark ? 0.24 : 0.24
        let accentWeight = colorScheme == .dark ? 0.18 : 0.20
        let neutralLift = colorScheme == .dark ? 0.010 : 0.026
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

    func textScrimOpacity(for colorScheme: ColorScheme, maxOpacity: Double) -> Double {
        guard colorScheme == .light, maxOpacity > 0 else { return 0 }
        let perceivedLuminance =
            primary.relativeLuminance * 0.56 +
            secondary.relativeLuminance * 0.24 +
            accent.relativeLuminance * 0.20
        let brightRisk = Self.smoothUnit(
            (perceivedLuminance - MusicPlayerVisualTokens.TextScrim.brightLuminanceStart) /
            max(MusicPlayerVisualTokens.TextScrim.brightLuminanceEnd - MusicPlayerVisualTokens.TextScrim.brightLuminanceStart, 0.001)
        )
        let lowVibrancyRisk = Self.smoothUnit(
            (MusicPlayerVisualTokens.TextScrim.lowVibrancyThreshold - vibrancy) /
            MusicPlayerVisualTokens.TextScrim.lowVibrancyThreshold
        )
        let risk = max(brightRisk, lowVibrancyRisk * 0.72)
        return maxOpacity * risk
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
        // 彩色封面：保留主/辅/强调混色的饱和度下限，底板更绚丽。
        // 低彩/白灰封面：不强行上色，避免少量暖色噪声被放大成粉/肉色底板。
        let lowVibrancy = vibrancy < 0.32
        if colorScheme == .dark {
            cleanedSaturation = lowVibrancy
                ? min(max(saturation * 0.72, 0.0), 0.16)
                : min(max(saturation * 0.82, 0.14), 0.32)
            cleanedBrightness = min(max(brightness, 0.16), 0.34)
        } else {
            // R1 清亮化：浅色底色整体上抬亮度并放宽饱和上限，去掉"发灰暗沉"的第一印象。
            // 仅动 S/V、不旋色相，仍落在封面高斯模糊色系内。
            cleanedSaturation = lowVibrancy
                ? min(max(saturation * 0.80, saturation < 0.028 ? saturation : 0.048), 0.20)
                : min(max(saturation * 0.82, saturation < 0.035 ? saturation : 0.14), 0.30)
            cleanedBrightness = lowVibrancy
                ? min(max(brightness * 1.04, 0.80), 0.93)
                : min(max(brightness * 1.03, 0.75), 0.90)
        }
        let cleaned = NSColor(calibratedHue: hue, saturation: cleanedSaturation, brightness: cleanedBrightness, alpha: 1)
        guard let rgb = cleaned.usingColorSpace(.sRGB) else {
            return (min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1))
        }
        return (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
    }

    private static func smoothUnit(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    static let fallback = AlbumColorPalette(
        primary: AlbumPaletteColor(red: 0.184, green: 0.490, blue: 0.882),
        secondary: AlbumPaletteColor(red: 0.435, green: 0.722, blue: 0.929),
        accent: AlbumPaletteColor(red: 0.231, green: 0.514, blue: 0.902),
        vibrancy: 0.62
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

    var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
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

    // 发光用：保持色相，确保最低亮度。低饱和封面不强行提饱和，避免白/灰封面被推成粉色或肉色光。
    func lightenedForGlow() -> AlbumPaletteColor {
        let nsColor = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // R3 绚丽化：彩色封面的发光色更饱和（地板 0.22→0.30、乘子 1.08→1.18、上限 0.78→0.82），
        // 保色相去灰，让"歌曲发光"读作有颜色的光而非灰光；低饱和(白/灰)封面仍克制，不凭空上色。
        let glowSaturation: CGFloat
        if saturation < 0.16 {
            glowSaturation = min(saturation * 1.10, 0.17)
        } else {
            glowSaturation = min(max(saturation * 1.18, 0.30), 0.82)
        }
        return Self.hsb(
            hue: hue,
            saturation: glowSaturation,
            brightness: min(max(brightness * 1.09, 0.70), 0.93)
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

        // 只轻补饱和度，防止底板比封面更艳；多色变化交给后续和声场而非单个 swatch。
        let cleanedSaturation = min(max(saturation * 1.16, 0.18), 0.74)
        let cleanedBrightness = min(max(brightness * 1.02, 0.32), 0.90)
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
#if DEBUG
        if let palette = MusicPlayerVisualDebugFixtures.palette(for: path) {
            return palette
        }
#endif

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
                guard color.alphaComponent > 0.2, brightness > 0.06, brightness < 0.985 else { continue }

                var hue: CGFloat = 0
                var hsbSaturation: CGFloat = 0
                var hsbBrightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(&hue, saturation: &hsbSaturation, brightness: &hsbBrightness, alpha: &alpha)
                // weight 改为"面积权重(prevalence)"：代表该颜色在封面中的占比。
                // 只做轻度中间调亮度偏好（过亮/过暗略降），不放大饱和度、不强罚白色——
                // 保留真实占比信息，供后续【按占比而非鲜艳度】排序，避免极少量鲜艳像素（如指甲油）夺取主色。
                let bri = Double(brightness)
                let brightnessPreference = 1.0 - min(abs(bri - 0.56) / 0.58, 1.0) * 0.26
                let emitter = lightEmitterWeight(
                    brightness: Double(hsbBrightness),
                    saturation: Double(hsbSaturation)
                )
                let weight = max(brightnessPreference * emitter, 0.018)
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
            .filter { $0.saturation >= 0.18 && $0.brightness >= 0.10 && $0.brightness <= 0.97 }
            .reduce(0.0) { $0 + $1.weight }
        let colorfulFraction = totalPrevalence > 0 ? colorfulPrevalence / totalPrevalence : 0
        let vibrancy = min(max(colorfulFraction / MusicPlayerVisualTokens.Palette.vibrancyNormalizer, 0), 1)

        let hueRanks = rankedHues(in: samples)
#if DEBUG
        if path == MusicPlayerVisualDebugVariant.realCoverTestPath {
            let neutral = colorfulFraction < MusicPlayerVisualTokens.Palette.colorfulFractionThreshold
            let topHue = hueRanks.first.map { String(format: "%.2f(w%.2f)", $0.hue, $0.weight) } ?? "none"
            NSLog("🎨REAL palette: colorfulFraction=\(String(format: "%.3f", colorfulFraction)) vibrancy=\(String(format: "%.2f", vibrancy)) regime=\(neutral ? "NEUTRAL" : "colorful") topHue=\(topHue)")
        }
#endif

        // 中性封面：用整体平均做柔和中性底色，不强行上色。阈值略放宽，避免白/灰封面里
        // 少量暖色噪声或印刷边缘被误判为彩色封面，导致底板偏粉/肉色。
        if colorfulFraction < MusicPlayerVisualTokens.Palette.colorfulFractionThreshold {
            return neutralPalette(
                samples: samples,
                hueRanks: hueRanks,
                colorfulFraction: colorfulFraction,
                vibrancy: vibrancy
            )
        }

        // ── 彩色封面：按占比排序选主色，少数派鲜艳色只能当点缀 ──
        let dominantHue = hueRanks.first?.hue ?? dominantHue(in: samples)
        // primary 取占比最大色相簇内的真实像素平均（颜色一定存在于封面中），逐级放宽兜底。
        let primaryBase = weightedAverage(
            samples,
            dominantHue: dominantHue,
            maxHueDistance: 0.11,
            includeNeutrals: false,
            minSaturation: 0.10
        )
            ?? weightedAverage(samples, dominantHue: dominantHue, maxHueDistance: 0.18, includeNeutrals: false, minSaturation: 0.08)
            ?? weightedAverage(samples, dominantHue: nil, maxHueDistance: 1, includeNeutrals: false, minSaturation: 0.06)
            ?? AlbumColorPalette.fallback.primary
        let primaryHue = dominantHue ?? Double(primaryBase.hue)
        // secondary/accent 必须是封面中真实存在、且占比达阈值的其他色相；
        // 否则退回主色的近似类比色。类比只在单色退化路径使用，且间距保持 0.03~0.05 级别，肉眼可分但仍属同一色族。
        let secondaryHue = distinctHue(
            in: hueRanks,
            avoiding: [primaryHue],
            minDistance: MusicPlayerVisualTokens.Palette.secondaryHueDistance,
            minWeightFraction: MusicPlayerVisualTokens.Palette.secondaryHueWeightFraction
        )
        let accentHue = distinctHue(
            in: hueRanks,
            avoiding: [primaryHue, secondaryHue ?? primaryHue],
            minDistance: MusicPlayerVisualTokens.Palette.accentHueDistance,
            minWeightFraction: MusicPlayerVisualTokens.Palette.accentHueWeightFraction
        )

        let secondary = (
            secondaryHue.flatMap {
                weightedAverage(samples, dominantHue: $0, maxHueDistance: 0.12, includeNeutrals: false, minSaturation: 0.12, minBrightness: 0.14)
            } ?? primaryBase.shiftedHue(
                // 单色封面（无第二主色）合成 secondary：色相只做克制类比偏移，保持同一色族。
                by: MusicPlayerVisualTokens.Palette.analogousSecondaryHueOffset,
                saturationMultiplier: 0.90,
                brightnessMultiplier: 1.10,
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
                // 同理 accent 只做反向类比偏移，保持同色族（更深一点的同色）。
                by: MusicPlayerVisualTokens.Palette.analogousAccentHueOffset,
                saturationMultiplier: 1.08,
                brightnessMultiplier: 0.94,
                minSaturation: 0.20,
                maxSaturation: 0.78,
                minBrightness: 0.34,
                maxBrightness: 0.90
            )
        ).adjustedPreservingHue(
            saturationMultiplier: 1.04,
            brightnessMultiplier: 1.02,
            minSaturation: 0.18,
            maxSaturation: 0.80,
            minBrightness: 0.32,
            maxBrightness: 0.94
        )

        // 主色只做温和补偿；更丰富的色彩由 Metal 底板的和声场承担，避免整窗比封面更艳。
        let vividPrimary = primaryBase.adjustedPreservingHue(
            saturationMultiplier: 1.14,
            brightnessMultiplier: 1.00,
            minSaturation: 0.22,
            maxSaturation: 0.76,
            minBrightness: 0.22,
            maxBrightness: 0.90
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
        colorfulFraction: Double,
        vibrancy: Double
    ) -> AlbumColorPalette {
        // 整体平均色（含中性）：代表封面真实的"主调"，白封面→近白、灰黑线条→银灰。
        // 不能复用 weightedAverage(includeNeutrals: true)，那条路径会把中性色权重降到 0.10，
        // 导致白/灰封面被少量暖色噪声支配，底板变成粉/肉色。
        let avg = neutralAverage(samples)
            ?? AlbumColorPalette.fallback.primary
        let avgHue = Double(avg.hue)
        // 低彩封面只允许占比足够明确的色相提示；没有足够彩色占比时保持中性，不凭空造色。
        let totalPrevalence = samples.reduce(0.0) { $0 + $1.weight }
        let topHueFraction = totalPrevalence > 0 ? (hueRanks.first?.weight ?? 0) / totalPrevalence : 0
        let hasColorHint = colorfulFraction >= MusicPlayerVisualTokens.Palette.neutralColorHintFraction &&
            topHueFraction >= MusicPlayerVisualTokens.Palette.neutralTopHueFraction
        let baseSaturation = hasColorHint ? min(0.045 + vibrancy * 0.12, 0.09) : min(0.020 + vibrancy * 0.035, 0.045)
        let baseBrightness = min(max(avg.brightness * 1.02, hasColorHint ? 0.70 : 0.74), hasColorHint ? 0.84 : 0.88)
        let primary: AlbumPaletteColor
        if hasColorHint {
            primary = AlbumPaletteColor.hsb(
                hue: CGFloat(avgHue),
                saturation: CGFloat(baseSaturation),
                brightness: baseBrightness
            )
        } else {
            primary = AlbumPaletteColor(
                red: Double(baseBrightness),
                green: Double(baseBrightness),
                blue: Double(baseBrightness)
            )
        }

        // 若封面里确有一点彩色（如指甲油），取占比最高的两个彩色相做极弱点缀；否则微类比。
        let accentHue1 = hueRanks.first(where: { $0.weight > 0 })?.hue
        let accentHue2 = accentHue1.flatMap { h1 in
            hueRanks.first(where: { hueDistance($0.hue, h1) >= MusicPlayerVisualTokens.Palette.neutralSecondHueDistance && $0.weight > 0 })?.hue
        }
        let secondary: AlbumPaletteColor = {
            if !hasColorHint {
                let neutral = min(max(baseBrightness * 1.03, 0.66), 0.86)
                return AlbumPaletteColor(red: Double(neutral), green: Double(neutral), blue: Double(neutral))
            }
            if let h = accentHue1,
               let c = weightedAverage(samples, dominantHue: h, maxHueDistance: 0.12, includeNeutrals: false, minSaturation: 0.18) {
                return c.adjustedPreservingHue(saturationMultiplier: 0.42, brightnessMultiplier: 1.02, minSaturation: 0.035, maxSaturation: 0.16, minBrightness: 0.62, maxBrightness: 0.86)
            }
            return primary.shiftedHue(by: MusicPlayerVisualTokens.Palette.neutralAnalogousSecondaryHueOffset, saturationMultiplier: 1.02, brightnessMultiplier: 1.03, minSaturation: 0.025, maxSaturation: 0.10, minBrightness: 0.64, maxBrightness: 0.86)
        }()
        let accent: AlbumPaletteColor = {
            if !hasColorHint {
                let neutral = min(max(baseBrightness * 0.92, 0.58), 0.80)
                return AlbumPaletteColor(red: Double(neutral), green: Double(neutral), blue: Double(neutral))
            }
            if let h = accentHue2 ?? accentHue1,
               let c = weightedAverage(samples, dominantHue: h, maxHueDistance: 0.13, includeNeutrals: false, minSaturation: 0.18) {
                return c.adjustedPreservingHue(saturationMultiplier: 0.46, brightnessMultiplier: 0.98, minSaturation: 0.040, maxSaturation: 0.18, minBrightness: 0.58, maxBrightness: 0.84)
            }
            return primary.shiftedHue(by: MusicPlayerVisualTokens.Palette.neutralAnalogousAccentHueOffset, saturationMultiplier: 1.08, brightnessMultiplier: 0.96, minSaturation: 0.030, maxSaturation: 0.11, minBrightness: 0.60, maxBrightness: 0.82)
        }()

        return AlbumColorPalette(primary: primary, secondary: secondary, accent: accent, vibrancy: min(vibrancy, 0.30))
    }

    private static func neutralAverage(_ samples: [AlbumPaletteSample]) -> AlbumPaletteColor? {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var total = 0.0

        for sample in samples {
            // 白/灰/黑封面的主调应该由面积决定；中性像素不降权，极端高亮只轻微降权。
            let brightnessScale = 1.0 - min(abs(sample.brightness - 0.72) / 0.72, 1.0) * 0.18
            let saturationScale = sample.saturation < 0.14 ? 1.0 : 0.28
            let weight = sample.weight * brightnessScale * saturationScale
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
        if saturation < 0.055 {
            let neutral = min(max(brightness * 1.02, 0.62), 0.90)
            return AlbumPaletteColor(red: Double(neutral), green: Double(neutral), blue: Double(neutral))
        }
        return AlbumPaletteColor.hsb(
            hue: hue,
            saturation: min(saturation * 0.50, 0.135),
            brightness: min(max(brightness * 1.02, 0.66), 0.88)
        )
    }

    private static func lightEmitterWeight(brightness: Double, saturation: Double) -> Double {
        // 近黑不是光源。平滑阈值保留夜景里的月光、灯光和金属字，
        // 但让黑底只贡献深度，避免被后续 glow / backdrop 误当成可发光颜色。
        let lightRamp = smoothstep((brightness - 0.135) / 0.285)
        // 饱和度因子加大：让鲜艳像素在"彩色判定 + 主色选择"里更有发言权，
        // 中性背景不至于把制服/霓虹等鲜艳块淹没成灰底（仍乘面积权重，纯小块鲜艳不会独占）。
        let colorRamp = 0.60 + min(max(saturation, 0), 1) * 0.62
        return max(0.012, lightRamp * colorRamp)
    }

    private static func rankedHues(in samples: [AlbumPaletteSample]) -> [(hue: Double, weight: Double)] {
        let bucketCount = 48
        var buckets = Array(repeating: 0.0, count: bucketCount)
        // 关键修复：按【占比(prevalence)】排序色相，而非鲜艳度。
        // 仅用很轻的饱和度因子（0.7~1.0）在占比相近时偏向更鲜明者；
        // 这样占据大面积的颜色稳居前列，极少量的高饱和像素（指甲油等）不会排到主色。
        for sample in samples where sample.saturation >= 0.18 && sample.brightness >= 0.12 && sample.brightness <= 0.97 {
            let bucket = min(bucketCount - 1, max(0, Int(sample.hue * Double(bucketCount))))
            // 饱和度偏好加强：占比相近时，更鲜艳的色相簇更可能成为主色，
            // 让发光取到封面里真正鲜艳的颜色（而非被大面积中性背景拉成灰）。
            let saturationNudge = 0.52 + min(max(sample.saturation, 0), 1) * 0.78
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

    private static func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
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

// MARK: - 无界重做（WujieNowPlaying · R1 起）
//
// 「沉浸双栏 · 重制」——保留功能完整骨架（左:封面+标题+全部控制 / 右:完整歌词），但前景视觉语言彻底重做：
// 去掉一切卡片/容器，专辑色满铺成「环境」；控制走统一状态系统（default/hover/pressed/disabled 一处统一）；
// 一个主 CTA（播放）+ 从属次级；影院级编辑标题。读 ui-ux-pro-max(design-system) 的三层 token 方法落到 SwiftUI。
//
// 隔离保证：本区全部以 `Wujie` 前缀命名，仅经 MusicExpandedStage 的 `isWujie` 分支生效（左栏入口 = schemeIdentityPanel 的无界分支）；
// 不改任何琉璃方案代码（musicIdentityPanel / lyricsPanel / MusicExpanded*）与底栏 mini 播放器；
// 复用的底层引擎（滑杆 MusicMiniSeekSlider / 频谱 WujieSpectrum / 数据观察器 / 状态行 WujieStatusLine）均为只读复用，不改其行为；封面已 fork 为 WujieArtwork。
//
// 轮次：R1 = 设计系统基座 + 统一控制系统 + 左栏重制（封面沿用、典型按钮走新交互、进度/标题/节奏 token 化）。
//       后续 R2 封面 hero/排版、R3 控制状态矩阵全量统一（含工具行）、R4 歌词舞台、R5 动效/氛围、R6 收尾+清理旧 MusicBorderless* 死码。

/// 无界设计系统：三层 token（primitive 原始刻度 → semantic 语义派生 → component 组件规格）。
/// 改这里 = 统一调整无界视觉节奏；与琉璃完全隔离。
enum WujieDesignSystem {

    // MARK: Primitive（原始刻度）

    /// 8pt 基准间距刻度。
    enum Space {
        static var xxs: CGFloat { MusicThemeConfig.active.wujieDesign.space.xxs }
        static var xs: CGFloat { MusicThemeConfig.active.wujieDesign.space.xs }
        static var sm: CGFloat { MusicThemeConfig.active.wujieDesign.space.sm }
        static var md: CGFloat { MusicThemeConfig.active.wujieDesign.space.md }
        static var lg: CGFloat { MusicThemeConfig.active.wujieDesign.space.lg }
        static var xl: CGFloat { MusicThemeConfig.active.wujieDesign.space.xl }
        static var xxl: CGFloat { MusicThemeConfig.active.wujieDesign.space.xxl }
        static var xxxl: CGFloat { MusicThemeConfig.active.wujieDesign.space.xxxl }
    }

    /// 字阶（pt）。无界为影院级大标题。
    enum FontSize {
        static var title: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.title } // 影院级大标题
        static var eyebrow: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.eyebrow } // 「正在播放」眉标
        static var artist: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.artist } // 艺人名（主，medium）
        static var album: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.album } // 专辑名（次，regular，更低对比）
        static var time: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.time } // 进度两端时间（tabular）
        static var iconPrimary: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.iconPrimary } // 上一/下一曲
        static var iconMode: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.iconMode } // 随机/循环
        static var iconUtility: CGFloat { MusicThemeConfig.active.wujieDesign.fontSize.iconUtility } // 喜欢/音量/隔空/队列
    }

    enum Weight {
        static let title: Font.Weight = .bold
        static let artist: Font.Weight = .medium
        static let icon: Font.Weight = .medium
    }

    enum Tracking {
        static var title: CGFloat { MusicThemeConfig.active.wujieDesign.tracking.title } // 大号粗体标题收紧字距，质感更精致
        static var eyebrow: CGFloat { MusicThemeConfig.active.wujieDesign.tracking.eyebrow } // 眉标加字距，编辑级气质
    }

    /// resting（语义）不透明度刻度。交互态（hover/press/disabled）一律交给 `WujieIconButtonStyle`。
    enum Opacity {
        static var textSecondary: Double { MusicThemeConfig.active.wujieDesign.opacity.textSecondary } // 副行兜底
        static var eyebrow: Double { MusicThemeConfig.active.wujieDesign.opacity.eyebrow } // 眉标
        static var artistName: Double { MusicThemeConfig.active.wujieDesign.opacity.artistName } // 艺人名（主）
        static var albumName: Double { MusicThemeConfig.active.wujieDesign.opacity.albumName } // 专辑名（次）
        static var separator: Double { MusicThemeConfig.active.wujieDesign.opacity.separator } // 中点分隔符
        static var timeLabel: Double { MusicThemeConfig.active.wujieDesign.opacity.timeLabel } // 进度时间
        static var iconStrong: Double { MusicThemeConfig.active.wujieDesign.opacity.iconStrong } // 上一/下一曲 resting
        static var iconIdle: Double { MusicThemeConfig.active.wujieDesign.opacity.iconIdle } // 模式键/工具键 未激活 resting
        static var disabledControl: Double { MusicThemeConfig.active.wujieDesign.opacity.disabledControl } // 禁用整控件透明度乘子（skill: 0.38~0.5）
        static var pressDim: Double { MusicThemeConfig.active.wujieDesign.opacity.pressDim } // 按下透明度乘子
        static var hoverWash: Double { MusicThemeConfig.active.wujieDesign.opacity.hoverWash } // hover 时极淡圆形高亮
    }

    /// 动效：统一节奏（skill: motion-consistency + spring-physics）。
    enum Motion {
        /// 控件交互（hover / press）弹簧。
        static let control = Animation.spring(response: 0.30, dampingFraction: 0.72)
        /// 环境色层的极缓慢呼吸（autoreverse 自反转），让氛围像活的。
        static let ambient = Animation.easeInOut(duration: 9).repeatForever(autoreverses: true)
    }

    /// 高程阴影刻度（skill: elevation-consistent）。
    struct Elevation {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    // MARK: Semantic（由专辑取色 + 明暗一处派生）

    /// 解析出无界各组件需要的语义色与高程，避免散落硬编码。
    struct Resolved {
        let palette: AlbumColorPalette
        let colorScheme: ColorScheme
        var isDark: Bool { colorScheme == .dark }

        /// 激活态控件主色（激活的随机/循环键）：浅色用更深主色、暗色用提亮主色，在环境上都清晰。
        var controlActive: Color { (isDark ? palette.glowPrimary : palette.deepPlayTint).color }
        /// 主 CTA 中央图标主色（同上策略）。
        var ctaIcon: Color { (isDark ? palette.glowPrimary : palette.deepPlayTint).color }
        /// 主 CTA 玻璃面里掺的一抹专辑色。
        var ctaTint: Color { palette.albumGlassBaseColor(for: colorScheme) }
        /// 主 CTA 高程。
        var ctaElevation: Elevation {
            Elevation(color: palette.primary.color.opacity(isDark ? 0.22 : 0.16), radius: 15, y: 6)
        }
    }

    // MARK: Component（歌词列）

    /// 歌词列组件规格。逐字歌词的「居中 / 可见行数 / 无卡片」行为是用户反复打磨过的，故 R4 原样沿用这些值（仅集中到此一处），不擅自改动。
    enum Lyrics {
        static var fontSize: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.fontSize } // 逐字歌词行基准字号
        static var rowSpacing: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.rowSpacing } // 歌词行之间的呼吸感
        static var fadeExpansion: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.fadeExpansion } // 清晰带外扩（露更多行）
        static var verticalPaddingFraction: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.verticalPaddingFraction } // 首/末行也能精确落视口中心
        static let extendedVisibility = true              // 放宽远处行透明度衰减
        static var lineHorizontalPadding: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.lineHorizontalPadding } // 行内水平 padding（传引擎）
        static var columnLeading: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.columnLeading } // 列左内边距（与封面/控制拉开）
        static var columnTrailing: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.columnTrailing } // 列右内边距（与左外边距对称）
        static var columnTopPadding: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.columnTopPadding } // 让淡出边界对齐封面顶部
        static var columnBottomPadding: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.columnBottomPadding } // 让底部淡出边界对齐频谱基线
        static var untimedFontSize: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.untimedFontSize } // 无逐字时间的纯文本歌词（R4 由 22 提到 27，与逐字一致）
        static var untimedOpacity: Double { MusicThemeConfig.active.wujieDesign.lyrics.untimedOpacity }
        static var untimedLineSpacing: CGFloat { MusicThemeConfig.active.wujieDesign.lyrics.untimedLineSpacing }
    }
}

/// 无界统一图标按钮交互态（skill 状态矩阵：default / hover / pressed / disabled 一处统一）。
/// resting 的语义色（激活/中性、强/弱）由调用方设定；本 style 只叠加「交互增量」，避免与 resting 冲突：
/// - hover：放大 + 极淡圆形高亮（短暂、非持久容器，契合「无界无卡片」）。
/// - pressed：缩小 + 压暗。
/// - disabled：整体压到禁用透明度，且不响应 hover。
/// 命中区 ≥ 44（skill: touch-target）。
struct WujieIconButtonStyle: ButtonStyle {
    var hitSize: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, hitSize: hitSize)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let hitSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            let scale: CGFloat = reduceMotion ? 1 : (pressed ? 0.9 : (hovering && isEnabled ? 1.06 : 1))
            configuration.label
                .frame(width: hitSize, height: hitSize)
                .background(
                    Circle().fill(
                        Color.primary.opacity(hovering && isEnabled && !pressed ? WujieDesignSystem.Opacity.hoverWash : 0)
                    )
                )
                .contentShape(Rectangle())
                .opacity(pressed ? WujieDesignSystem.Opacity.pressDim : 1)
                .opacity(isEnabled ? 1 : WujieDesignSystem.Opacity.disabledControl)
                .scaleEffect(scale)
                .animation(WujieDesignSystem.Motion.control, value: pressed)
                .animation(WujieDesignSystem.Motion.control, value: hovering)
                .onHover { hovering = isEnabled ? $0 : false }
        }
    }
}

/// 无界主 CTA：液态玻璃透明圆（真实背景模糊 + 白霜 + 一抹专辑色 + 顶部受光 + 发丝描边 + 高程阴影），
/// 中央播放/暂停图标用专辑主色。无任何实色块/卡片。token 驱动。
struct WujiePlayButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let isPlaying: Bool
    let palette: AlbumColorPalette
    var diameter: CGFloat = 64

    var body: some View {
        let isDark = colorScheme == .dark
        let r = WujieDesignSystem.Resolved(palette: palette, colorScheme: colorScheme)
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: diameter * 0.36, weight: .bold))
            .foregroundStyle(r.ctaIcon)
            // 播放三角光学居中：向右微移；暂停符号居中。
            .offset(x: isPlaying ? 0 : diameter * 0.025)
            .frame(width: diameter, height: diameter)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.white.opacity(isDark ? 0.05 : 0.16))
                    Circle().fill(r.ctaTint.opacity(isDark ? 0.14 : 0.10))
                    Circle().fill(
                        LinearGradient(
                            colors: [.white.opacity(isDark ? 0.20 : 0.40), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .blendMode(.screen)
                }
            }
            .overlay {
                // 发丝描边：上亮下暗，给玻璃片厚度感；带一点主色受光。
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isDark ? 0.45 : 0.70),
                            palette.glowPrimary.color.opacity(0.22),
                            .black.opacity(isDark ? 0.22 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.1
                )
            }
            .shadow(color: r.ctaElevation.color, radius: r.ctaElevation.radius, y: r.ctaElevation.y)
            .shadow(color: .black.opacity(isDark ? 0.22 : 0.07), radius: 7, y: 3)
            .contentShape(Circle())
    }
}

/// 无界进度行（重制）：两端等宽（tabular）时间 + 加粗玻璃槽。复用通用滑杆与进度观察器，不与琉璃共用视图。
struct WujieProgressBar: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var progress: MusicExpandedProgressStateObserver

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _progress = StateObject(wrappedValue: MusicExpandedProgressStateObserver(controller: controller))
    }

    var body: some View {
        let s = progress.state
        HStack(spacing: WujieDesignSystem.Space.sm) {
            Text(s.formattedCurrentTime)
                .font(.system(size: WujieDesignSystem.FontSize.time, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.timeLabel))
                .frame(width: 40, alignment: .leading)

            MusicMiniSeekSlider(
                currentTime: s.currentTime,
                duration: s.duration,
                isPlaying: s.isPlaying,
                isEnabled: s.canControl && s.duration > 0,
                palette: palette,
                trackHeight: 11,
                thumbSize: 19,
                usesPaletteTint: true,
                glassTrack: true,
                onScrubBegin: { controller.beginScrubbing(to: $0) },
                onScrubChange: { controller.updateScrubbing(to: $0) },
                onSeek: { controller.finishScrubbing(to: $0) }
            )
            .disabled(!s.canControl || s.duration <= 0)
            .frame(minWidth: 150, idealWidth: 300, maxWidth: .infinity)

            Text(s.formattedDuration)
                .font(.system(size: WujieDesignSystem.FontSize.time, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.timeLabel))
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// 无界主控行（重制）：随机 · 上一曲 · 主 CTA 播放 · 下一曲 · 循环。统一走 `WujieIconButtonStyle` 交互。
struct WujieTransportCluster: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var transport: MusicMiniTransportStateObserver

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.item = item
        self.controller = controller
        self.palette = palette
        _transport = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let s = transport.state
        let r = WujieDesignSystem.Resolved(palette: palette, colorScheme: colorScheme)

        HStack(spacing: WujieDesignSystem.Space.xl) {
            Button {
                appState.toggleMusicShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: WujieDesignSystem.FontSize.iconMode, weight: WujieDesignSystem.Weight.icon))
                    .foregroundStyle(appState.musicShuffleEnabled ? r.controlActive : .primary.opacity(WujieDesignSystem.Opacity.iconIdle))
            }
            .buttonStyle(WujieIconButtonStyle())
            .help(appState.musicShuffleEnabled ? "关闭随机播放" : "随机播放")
            .accessibilityLabel(appState.musicShuffleEnabled ? "关闭随机播放" : "随机播放")

            Button {
                playAdjacent(-1)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: WujieDesignSystem.FontSize.iconPrimary, weight: WujieDesignSystem.Weight.icon))
                    .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.iconStrong))
            }
            .buttonStyle(WujieIconButtonStyle(hitSize: 48))
            .disabled(!s.canControl)
            .help("上一曲")
            .accessibilityLabel("上一曲")

            Button {
                if s.canControl {
                    controller.togglePlay()
                } else {
                    controller.configureMusic(item: item, settings: appState.settings)
                }
            } label: {
                WujiePlayButton(isPlaying: s.isPlaying, palette: palette, diameter: 64)
            }
            .buttonStyle(MusicGlassPressStyle(pressScale: 0.95))
            .pointerLiquidEdge(cornerRadius: 32, tint: palette.accent.color, intensity: 1.45)
            .disabled(s.isPreparing)
            .help(s.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(s.isPlaying ? "暂停" : "播放")
            .padding(.horizontal, WujieDesignSystem.Space.xxs)

            Button {
                playAdjacent(1)
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: WujieDesignSystem.FontSize.iconPrimary, weight: WujieDesignSystem.Weight.icon))
                    .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.iconStrong))
            }
            .buttonStyle(WujieIconButtonStyle(hitSize: 48))
            .disabled(!s.canControl)
            .help("下一曲")
            .accessibilityLabel("下一曲")

            Button {
                appState.cycleMusicRepeatMode()
            } label: {
                Image(systemName: appState.musicRepeatMode.systemImage)
                    .font(.system(size: WujieDesignSystem.FontSize.iconMode, weight: WujieDesignSystem.Weight.icon))
                    .foregroundStyle(appState.musicRepeatMode != .sequential ? r.controlActive : .primary.opacity(WujieDesignSystem.Opacity.iconIdle))
            }
            .buttonStyle(WujieIconButtonStyle())
            .help(appState.musicRepeatMode.title)
            .accessibilityLabel(appState.musicRepeatMode.title)
        }
        .frame(maxWidth: .infinity)
    }

    private func playAdjacent(_ direction: Int) {
        if appState.musicRepeatMode == .repeatOne ||
            (appState.musicRepeatMode == .repeatAll && appState.musicQueue.count <= 1) {
            controller.restartFromBeginning()
        } else {
            appState.playAdjacent(to: item, direction: direction)
        }
    }
}

/// 无界音量按钮（R3）：裸图标走统一 `WujieIconButtonStyle` + 弹层音量条。复用音量观察器与感知音量映射，不与琉璃共用视图。
struct WujieVolumeButton: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @StateObject private var volume: MusicExpandedVolumeStateObserver
    @State private var showVolume = false

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _volume = StateObject(wrappedValue: MusicExpandedVolumeStateObserver(controller: controller))
    }

    var body: some View {
        Button {
            showVolume.toggle()
        } label: {
            Image(systemName: volumeSystemImage)
                .font(.system(size: WujieDesignSystem.FontSize.iconUtility, weight: .regular))
                .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.iconIdle))
        }
        .buttonStyle(WujieIconButtonStyle(hitSize: 44))
        .disabled(!volume.state.canControl)
        .popover(isPresented: $showVolume, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: volumeSystemImage)
                        .foregroundStyle(.secondary)
                    Text("音量")
                        .font(.headline)
                    Spacer()
                    Text("\(Int((volume.state.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: {
                    PerceptualVolumeScale.sliderValue(fromLinear: Double(volume.state.volume))
                }, set: { newValue in
                    controller.setVolume(Float(PerceptualVolumeScale.linearVolume(fromSlider: newValue)))
                }), in: 0...1)
                .frame(width: 220)
            }
            .padding(16)
            .frame(width: 260)
            .modifier(MusicPopoverGlass(palette: palette, cornerRadius: 18))
        }
        .help("音量")
        .accessibilityLabel("音量")
    }

    private var volumeSystemImage: String {
        let v = volume.state.volume
        if v == 0 { return "speaker.slash" }
        if v < 0.45 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }
}

/// 无界队列按钮（R3）：裸图标走统一 `WujieIconButtonStyle` + 队列弹层。
struct WujieQueueButton: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let palette: AlbumColorPalette
    @State private var showQueue = false

    var body: some View {
        Button {
            showQueue.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: WujieDesignSystem.FontSize.iconUtility, weight: .regular))
                .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.iconIdle))
        }
        .buttonStyle(WujieIconButtonStyle(hitSize: 44))
        .popover(isPresented: $showQueue, arrowEdge: .bottom) {
            MusicQueuePopover(currentItem: item, palette: palette)
                .environmentObject(appState)
        }
        .help("播放队列")
        .accessibilityLabel("播放队列")
    }
}

/// 无界 AirPlay（R3）：系统 route picker（native control，保留原生选路）外包一层与其它工具键一致的 hover 高亮，
/// 让整条工具行视觉统一。按压/缩放交互由原生控件自管，故仅叠 hover 高亮（onHover 若被 NSView 拦截则优雅降级，不影响功能）。
struct WujieAirPlayButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    @State private var hovering = false

    var body: some View {
        AirPlayRoutePickerControl(
            session: controller.routePickerSession,
            player: controller.routePickerPlayer,
            tintColor: NSColor(white: colorScheme == .dark ? 1 : 0, alpha: 0.58),
            activeTintColor: NSColor(white: colorScheme == .dark ? 1 : 0, alpha: 0.58),
            lightTint: palette.primary.color,
            size: 42,
            cornerRadius: 21,
            useGlassBackground: false,
            onRoutesWillBegin: {
                controller.prepareForMusicAirPlayRouteSelection()
            },
            onRoutesDidEnd: {
                controller.refreshMusicAirPlayRoute(afterRoutePicker: true)
            }
        )
        .frame(width: 44, height: 44)
        .background(
            Circle().fill(Color.primary.opacity(hovering ? WujieDesignSystem.Opacity.hoverWash : 0))
        )
        .onHover { hovering = $0 }
        .help("隔空投送")
        .accessibilityLabel("隔空投送")
    }
}

/// 无界次级工具行（R3 全量统一）：喜欢 · 音量 · 隔空投送 · 队列——保留琉璃全部次级功能键。
/// 上报 `WujieControlsBottomKey` 供右侧频谱底沿对齐（与原实现一致）。
/// 四键现统一走 `WujieIconButtonStyle`（喜欢/音量/队列）与同款 hover 高亮（AirPlay 原生控件外包）→ 与主控行同一交互语言。
struct WujieUtilityBar: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette

    var body: some View {
        HStack(spacing: 0) {
            Button {
                appState.toggleFavorite(item)
            } label: {
                Image(systemName: item.favorite ? "heart.fill" : "heart")
                    .font(.system(size: WujieDesignSystem.FontSize.iconUtility, weight: .regular))
                    .foregroundStyle(item.favorite ? Color.red.opacity(0.92) : .primary.opacity(WujieDesignSystem.Opacity.iconIdle))
            }
            .buttonStyle(WujieIconButtonStyle(hitSize: 44))
            .help(item.favorite ? "取消喜欢" : "我喜欢")
            .accessibilityLabel(item.favorite ? "取消喜欢" : "我喜欢")

            Spacer(minLength: WujieDesignSystem.Space.md)

            WujieVolumeButton(controller: controller, palette: palette)

            Spacer(minLength: WujieDesignSystem.Space.md)

            WujieAirPlayButton(controller: controller, palette: palette)

            Spacer(minLength: WujieDesignSystem.Space.md)

            WujieQueueButton(item: item, palette: palette)
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { g in
                Color.clear.preference(
                    key: WujieControlsBottomKey.self,
                    value: g.frame(in: .named("wujieContent")).maxY
                )
            }
        )
    }
}

/// 无界封面（R2 hero 重制）：方形（连续圆角）封面静止呈现 + 专辑色彩晕影（沿用 MusicExpandedArtworkShadowLayer /
/// AlbumPrimarySoftCoverShadow 引擎）+ **一道干脆的暗投影高程**，让封面像被托起浮于环境（与琉璃的卡片描边区分）；
/// 受光边强化顶部、收敛底部 → 像被环境光打亮的相纸。暂停轻微缩放 + 发光收回逻辑沿用成熟实现，零功能改变。
struct WujieArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let posterSize: CGFloat
    let coverGlowEnabled: Bool
    @StateObject private var playback: MusicMiniTransportStateObserver
    @State private var coverVisualProgress: Double = 1
    @State private var glowVisualProgress: Double = 1
    @State private var glowCollapseTask: Task<Void, Never>?

    private var cornerRadius: CGFloat { min(posterSize * 0.075, 28) }

    init(item: MediaItem, controller: MpvPlayerController, palette: AlbumColorPalette, posterSize: CGFloat, coverGlowEnabled: Bool) {
        self.item = item
        self.controller = controller
        self.palette = palette
        self.posterSize = posterSize
        self.coverGlowEnabled = coverGlowEnabled
        _playback = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let isPlaying = playback.state.isPlaying
        let coverProgress = smoothstep(coverVisualProgress)
        let glowProgress = smoothstep(glowVisualProgress)
        let glowStrength = pow(glowProgress, 1.5)
        let coverScale = CGFloat(lerp(from: 0.93, to: 1.0, progress: coverProgress))
        let radius = cornerRadius
        let isDark = colorScheme == .dark

        let shadowSatFloor = MusicPlayerVisualTokens.Glow.pausedShadowSaturationFloor
        let shadowSatMul = CGFloat(shadowSatFloor + (1 - shadowSatFloor) * glowStrength)
        let shadowPrimary = palette.glowPrimary.adjustedPreservingHue(
            saturationMultiplier: shadowSatMul, brightnessMultiplier: 1.0,
            minSaturation: 0, maxSaturation: 1, minBrightness: 0, maxBrightness: 1
        ).nsColor
        let shadowAccent = palette.glowAccent.adjustedPreservingHue(
            saturationMultiplier: shadowSatMul, brightnessMultiplier: 1.0,
            minSaturation: 0, maxSaturation: 1, minBrightness: 0, maxBrightness: 1
        ).nsColor

        ZStack {
            if coverGlowEnabled {
                MusicExpandedArtworkShadowLayer(
                    primaryColor: shadowPrimary, accentColor: shadowAccent,
                    glowStrength: glowStrength, coverProgress: coverProgress,
                    cornerRadius: radius, reduceMotion: reduceMotion
                )
                .frame(width: posterSize, height: posterSize)
                .allowsHitTesting(false)
            } else {
                AlbumPrimarySoftCoverShadow(
                    color: shadowPrimary, glowStrength: glowStrength,
                    coverProgress: coverProgress, cornerRadius: radius
                )
                .frame(width: posterSize, height: posterSize)
                .allowsHitTesting(false)
            }

            PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: posterSize, height: posterSize)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    // hero 受光印面边：顶部受光更亮、底部暗边收敛 → 像被环境光打亮的相纸而非卡片描边（专辑取色不变）。
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(lerp(from: 0.40, to: 0.64, progress: coverProgress)),
                                    palette.glowPrimary.color.opacity(0.05 * glowStrength),
                                    .white.opacity(lerp(from: 0.06, to: 0.12, progress: coverProgress)),
                                    .black.opacity(lerp(from: 0.03, to: 0.07, progress: coverProgress))
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1.0
                        )
                        .allowsHitTesting(false)
                }
                // hero 高程：干脆的暗投影把封面托离环境（彩色晕影由上面的 shadow 引擎提供，这里只补深度）。
                .shadow(color: .black.opacity(isDark ? 0.30 : 0.15), radius: 22, y: 14)
                .pointerLiquidEdge(cornerRadius: radius, tint: .white, intensity: 0.62)
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture {
            guard controller.canControl else { return }
            controller.togglePlay()
        }
        // 无障碍：封面点按可播放/暂停 → 暴露为 VoiceOver 按钮（之前是未标注的图片）。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("专辑封面")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isPlaying ? "点按暂停" : "点按播放")
        .scaleEffect(coverScale)
        .onAppear { syncPlaybackVisuals(isPlaying: isPlaying, animated: false) }
        .onChange(of: isPlaying) { syncPlaybackVisuals(isPlaying: $0, animated: true) }
        .onChange(of: item.id) { _ in syncPlaybackVisuals(isPlaying: isPlaying, animated: false) }
        .onDisappear { glowCollapseTask?.cancel() }
    }

    private func syncPlaybackVisuals(isPlaying: Bool, animated: Bool) {
        let target = isPlaying ? 1.0 : 0.0
        glowCollapseTask?.cancel()
        guard animated, !reduceMotion else {
            coverVisualProgress = target
            glowVisualProgress = target
            return
        }
        if isPlaying {
            withAnimation(.easeOut(duration: 0.26)) { glowVisualProgress = 1 }
            withAnimation(AppMotion.musicPlayer.delay(0.06)) { coverVisualProgress = 1 }
        } else {
            withAnimation(AppMotion.musicPlayer) { coverVisualProgress = 0 }
            withAnimation(.easeOut(duration: 0.20).delay(0.035)) { glowVisualProgress = 0.16 }
            glowCollapseTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.36)) { glowVisualProgress = 0 }
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

/// 无界「正在播放」眉标（editorial eyebrow）：小号 + 加字距 + 低对比，随播放状态切换文案。
/// 独立小视图（自带观察器）→ 仅它随播放态重绘，不牵动整列。
struct WujieNowPlayingEyebrow: View {
    let controller: MpvPlayerController
    @StateObject private var playback: MusicMiniTransportStateObserver

    init(controller: MpvPlayerController) {
        self.controller = controller
        _playback = StateObject(wrappedValue: MusicMiniTransportStateObserver(controller: controller))
    }

    var body: some View {
        let s = playback.state
        let label = s.isPreparing ? "正在载入" : (s.isPlaying ? "正在播放" : "已暂停")
        Text(label)
            .font(.system(size: WujieDesignSystem.FontSize.eyebrow, weight: .semibold))
            .tracking(WujieDesignSystem.Tracking.eyebrow)
            .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.eyebrow))
            .animation(WujieDesignSystem.Motion.control, value: s.isPlaying)
            .animation(WujieDesignSystem.Motion.control, value: s.isPreparing)
    }
}

/// 无界左栏（重制）：环境中的封面 hero + 影院级编辑标题（眉标 + 大标题 + 艺人/专辑层级）+ 统一控制栈。无任何卡片/容器。
/// 仅经 isWujie 生效；复用 WujieStatusLine（状态行）。琉璃 musicIdentityPanel 零改动。
struct WujieIdentityColumn: View {
    let item: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let posterSize: CGFloat
    let coverGlowEnabled: Bool

    var body: some View {
        VStack(spacing: WujieDesignSystem.Space.xl) {
            Spacer(minLength: 0)

            WujieArtwork(
                item: item,
                controller: controller,
                palette: palette,
                posterSize: posterSize,
                coverGlowEnabled: coverGlowEnabled
            )
            .frame(width: posterSize, height: posterSize)

            VStack(spacing: WujieDesignSystem.Space.xs) {
                VStack(spacing: 5) {
                    WujieNowPlayingEyebrow(controller: controller)
                    Text(item.title)
                        .font(.system(size: WujieDesignSystem.FontSize.title, weight: WujieDesignSystem.Weight.title))
                        .tracking(WujieDesignSystem.Tracking.title)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .multilineTextAlignment(.center)
                }
                subtitle
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: WujieDesignSystem.Space.lg) {
                WujieProgressBar(controller: controller, palette: palette)
                WujieTransportCluster(item: item, controller: controller, palette: palette)
                WujieUtilityBar(item: item, controller: controller, palette: palette)
                WujieStatusLine(controller: controller, item: item)
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    /// 艺人/专辑层级（skill: weight-hierarchy + visual-hierarchy）：艺人名 medium 偏亮为主，专辑名 regular 更低对比为次。
    @ViewBuilder
    private var subtitle: some View {
        let hasArtist = !(item.artist?.isEmpty ?? true)
        let hasAlbum = !(item.album?.isEmpty ?? true)
        HStack(spacing: WujieDesignSystem.Space.xs) {
            if let artist = item.artist, hasArtist {
                Text(artist)
                    .font(.system(size: WujieDesignSystem.FontSize.artist, weight: WujieDesignSystem.Weight.artist))
                    .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.artistName))
            }
            if hasArtist, hasAlbum {
                Text("·")
                    .font(.system(size: WujieDesignSystem.FontSize.album, weight: .regular))
                    .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.separator))
            }
            if let album = item.album, hasAlbum {
                Text(album)
                    .font(.system(size: WujieDesignSystem.FontSize.album, weight: .regular))
                    .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.albumName))
            }
            if !hasArtist, !hasAlbum {
                Text("未知艺人")
                    .font(.system(size: WujieDesignSystem.FontSize.artist, weight: WujieDesignSystem.Weight.artist))
                    .foregroundStyle(.primary.opacity(WujieDesignSystem.Opacity.artistName))
            }
        }
    }
}

/// 无界歌词列（R4 重制）：歌词纯净悬浮于专辑底板，左对齐，被唱行恒锁视口中心；逐字高亮复用共享引擎 `MusicTimedLyricsScrollView`。
/// **无任何卡片 / 柔光衬底**（用户明确否决过歌词侧的磨砂卡片）；上下虚化交给逐行透明度/景深。
/// 逐字歌词参数（居中/可见行数/无卡片）原样沿用、收口到 `WujieDesignSystem.Lyrics`。仅安全微调：无逐字时间的纯文本歌词放大到与逐字一致。
struct WujieLyricsColumn: View {
    @Environment(\.colorScheme) private var colorScheme
    let controller: MpvPlayerController
    let itemID: String
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
        ZStack(alignment: .topTrailing) {
            lyricsView
                .padding(.top, WujieDesignSystem.Lyrics.columnTopPadding)
                .padding(.bottom, WujieDesignSystem.Lyrics.columnBottomPadding)
                .padding(.leading, WujieDesignSystem.Lyrics.columnLeading)
                .padding(.trailing, WujieDesignSystem.Lyrics.columnTrailing)

            if !hasDisplayLyrics {
                fetchButton
                    .padding(.top, 6)
                    .padding(.trailing, 6)
            }

            if hasDisplayLyrics, !timedLyrics.isEmpty {
                LyricTimingSourceBadge(source: timingSource)
                    .padding(.bottom, 8)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var lyricsView: some View {
        if !hasDisplayLyrics {
            MusicEmptyLyricsStage(
                title: emptyLyricsTitle,
                subtitle: emptyLyricsSubtitle,
                palette: palette,
                isFetchingLyrics: isFetchingLyrics
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if timedLyrics.isEmpty {
            // 无逐字时间：纯文本歌词滚动。R4 安全微调——字号 22→27、行距与逐字一致，整体更接近舞台呈现。
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(MusicPlayerView.cleanedLyrics(lyrics))
                        .font(.system(size: WujieDesignSystem.Lyrics.untimedFontSize, weight: .semibold))
                        .foregroundStyle(.primary.opacity(WujieDesignSystem.Lyrics.untimedOpacity))
                        .lineSpacing(WujieDesignSystem.Lyrics.untimedLineSpacing)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: max(geometry.size.height, 420), alignment: .leading)
                        .padding(.vertical, 28)
                }
                .mask(LyricsFadeMask())
                .lyricsScrollActivity {
                    onPauseAutoScroll()
                }
            }
        } else {
            // 逐字歌词：参数原样沿用（用户已调好的居中/可见行/无卡片），仅集中到 token。
            MusicTimedLyricsScrollView(
                controller: controller,
                itemID: itemID,
                timedLyrics: timedLyrics,
                palette: palette,
                lineAlignment: .leading,
                horizontalPadding: WujieDesignSystem.Lyrics.lineHorizontalPadding,
                lineFontSize: WujieDesignSystem.Lyrics.fontSize,
                rowSpacing: WujieDesignSystem.Lyrics.rowSpacing,
                fadeExpansion: WujieDesignSystem.Lyrics.fadeExpansion,
                verticalPaddingFraction: WujieDesignSystem.Lyrics.verticalPaddingFraction,
                extendedVisibility: WujieDesignSystem.Lyrics.extendedVisibility,
                userIsBrowsingLyrics: $userIsBrowsingLyrics,
                onPauseAutoScroll: onPauseAutoScroll
            )
        }
    }

    /// 无歌词时的在线获取按钮：保留为可发现的玻璃圆（empty 态的主操作，不裸化），仅 token 化配色。
    private var fetchButton: some View {
        Button {
            onFetchLyrics()
        } label: {
            LyricFetchIcon(isFetching: isFetchingLyrics)
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
                .shadow(color: palette.primary.color.opacity(0.14), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(isFetchingLyrics)
        .help("在线获取歌词")
    }

    private var cleanedLyricMessage: String {
        MusicPlayerView.cleanedLyrics(lyrics).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyLyricsTitle: String {
        if isFetchingLyrics { return "正在获取歌词" }
        if cleanedLyricMessage.hasPrefix("在线歌词获取失败") { return "歌词获取失败" }
        if cleanedLyricMessage.hasPrefix("没有获取到") || cleanedLyricMessage.hasPrefix("没有匹配") {
            return "没有匹配的在线歌词"
        }
        return "此歌曲暂无可显示歌词"
    }

    private var emptyLyricsSubtitle: String {
        if cleanedLyricMessage.hasPrefix("在线歌词获取失败") {
            return cleanedLyricMessage
        }
        if isFetchingLyrics {
            return "MediaLIB 正在匹配同步歌词"
        }
        return "可使用同名 .lrc 或 .txt 歌词文件，或从右上角在线获取。"
    }
}

/// 无界环境色层（R5 重制）：在共享底板之上、于远离封面发光的一侧叠几团柔和的专辑辅色/强调色，让专辑色「满铺成环境」，
/// 再自底向上极淡加深给纵深与重心。**R5 增量 = 整体极缓慢呼吸**（scale 1.0↔1.05 + opacity 0.9↔1.0，~9s 自反转）→
/// 环境像活的氛围光；纯 Core Animation 变换/不透明度（廉价，不触发逐帧重绘），`reduceMotion` 时完全静止；明暗成对。
/// 仅无界使用（取代了原 ambient wash 实现），不改动共享底板。
struct WujieEnvironmentWash: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let palette: AlbumColorPalette
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let isDark = colorScheme == .dark
            let d = max(geo.size.width, geo.size.height)
            ZStack {
                // 右上：专辑辅色柔团。
                RadialGradient(
                    colors: [palette.glowSecondary.color.opacity(isDark ? 0.12 : 0.09), .clear],
                    center: UnitPoint(x: 0.80, y: 0.16),
                    startRadius: 0,
                    endRadius: d * 0.60
                )
                // 右下：专辑强调色柔团。
                RadialGradient(
                    colors: [palette.glowAccent.color.opacity(isDark ? 0.11 : 0.08), .clear],
                    center: UnitPoint(x: 0.94, y: 0.86),
                    startRadius: 0,
                    endRadius: d * 0.58
                )
                // 底部中央：专辑主色托底，与封面发光呼应。
                RadialGradient(
                    colors: [palette.glowPrimary.color.opacity(isDark ? 0.07 : 0.05), .clear],
                    center: UnitPoint(x: 0.5, y: 1.02),
                    startRadius: 0,
                    endRadius: d * 0.5
                )

                LinearGradient(
                    colors: [
                        palette.glowSecondary.color.opacity(isDark ? 0.055 : 0.038),
                        .clear,
                        palette.glowAccent.color.opacity(isDark ? 0.040 : 0.028)
                    ],
                    startPoint: UnitPoint(x: 0.12, y: 0.0),
                    endPoint: UnitPoint(x: 0.88, y: 1.0)
                )
                .blendMode(.screen)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .saturation(0.48)
            // 整体呼吸：scale 始终 ≥ 1.0（不会在边缘露出底板）+ 不透明度微动。CA 合成，廉价。
            .scaleEffect(reduceMotion ? 1 : (breathe ? 1.05 : 1.0), anchor: .center)
            .opacity(reduceMotion ? 1 : (breathe ? 1.0 : 0.9))
            .animation(reduceMotion ? nil : WujieDesignSystem.Motion.ambient, value: breathe)
            // 自底向上极淡加深给纵深——静止，不参与呼吸（作为稳定的重心/接地）。
            .overlay(
                LinearGradient(
                    colors: [.clear, Color.black.opacity(isDark ? 0.16 : 0.07)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .onAppear {
            if !reduceMotion { breathe = true }
        }
    }
}
