import CoreGraphics
import Foundation

/// 内置音乐播放器主题的可配置参数（R3）。仅承载四个 token 枚举里【纯数值/布尔字面量】皮肤参数；
/// 派生值（引用其它 token）、字体粗细 / 动画曲线 / 颜色 / 数组等暂留各枚举硬编码。
/// 默认值与原枚举逐值一致（脚本逐字搬运 + 自动等值校验，零漂移）。渲染层经各枚举 facade 读
/// `MusicThemeConfig.active`，调用点零改动。R4 让 `active` 可由用户 JSON 覆盖、一键恢复默认。
struct MusicThemeConfig: Codable, Equatable {
    var visual = VisualConfig()
    var wujie = WujieTokensConfig()
    var wujieDesign = WujieDesignConfig()
    var shelf = ShelfConfig()

    /// 全局生效配置；R4 由文件加载覆盖，默认即各主题原始观感。
    static var active = MusicThemeConfig()

    struct VisualConfig: Codable, Equatable {
        var radius = Radius()
        var glow = Glow()
        var spill = Spill()
        var controls = Controls()
        var lyrics = Lyrics()
        var tint = Tint()
        var progress = Progress()
        var palette = Palette()
        var textScrim = TextScrim()
        struct Radius: Codable, Equatable {
            var card: CGFloat = 36
            var control: CGFloat = 24
            var chrome: CGFloat = 23
        }
        struct Glow: Codable, Equatable {
            var edgeOvershoot: CGFloat = 52
            var minReach: CGFloat = 2.14
            var maxReach: CGFloat = 6.4
            var bloomVisibleFraction: CGFloat = 1.0
            var lowVibrancyDamp: Double = 0.82
            var fallbackReach: CGFloat = 4.4
            var nearSaturationCap: Double = 1.18
            var pausedShadowSaturationFloor: Double = 0.45
        }
        struct Spill: Codable, Equatable {
            var lyricsIntensity: Double = 0.0
            var controlsIntensity: Double = 0.74
            var chromeIntensity: Double = 0.34
            var lyricsReach: Double = 0.245
            var controlsReach: Double = 0.31
            var chromeReach: Double = 0.21
            var chromaTravelBase: Double = 0.37
            var chromaTravelVibrancy: Double = 0.18
            var innerPeak: Double = 0.02
            var innerPrimary: Double = 0.064
            var innerSecondary: Double = 0.13
            var innerFade: Double = 0.22
            var pausedResidual: Double = 0.055
            var pauseNearFadeDuration: Double = 0.22
            var pauseFarDelay: UInt64 = 260_000_000
            var pauseFarFadeDuration: Double = 0.28
            var playRiseDuration: Double = 0.24
        }
        struct Controls: Codable, Equatable {
            var expandedHeight: CGFloat = 128
            var expandedMaxWidth: CGFloat = 424
        }
        struct Lyrics: Codable, Equatable {
            var distanceBlurMax: CGFloat = 8.6
            var edgeExtraBlur: CGFloat = 1.70
            var edgePositionStep: CGFloat = 0.18
            var clearWindowRatio: Double = 0.40
            var browseClearDuration: Double = 0.22
            var browseRecoverDuration: Double = 1.65
            var viewportStabilityDelay: UInt64 = 780_000_000
            var browseFallbackResumeDelay: UInt64 = 4_000_000_000
        }
        struct Tint: Codable, Equatable {
            var playSaturation: CGFloat = 1.10
            var playBrightness: CGFloat = 0.84
            var playMinSaturation: CGFloat = 0.30
            var playMaxSaturation: CGFloat = 0.96
            var playMinBrightness: CGFloat = 0.40
            var playMaxBrightness: CGFloat = 0.82
            var playPressedScale: CGFloat = 0.96
        }
        struct Progress: Codable, Equatable {
            var thumbActiveGrowth: CGFloat = 2
            var thumbGlowRadius: CGFloat = 7
            var sheenDuration: Double = 7.8
            var sheenWidthMin: CGFloat = 22
            var sheenWidthMax: CGFloat = 94
            var sheenWidthRatio: CGFloat = 0.34
        }
        struct Palette: Codable, Equatable {
            var colorfulFractionThreshold: Double = 0.10
            var vibrancyNormalizer: Double = 0.24
            var secondaryHueDistance: Double = 0.06
            var accentHueDistance: Double = 0.08
            var secondaryHueWeightFraction: Double = 0.12
            var accentHueWeightFraction: Double = 0.10
            var analogousSecondaryHueOffset: CGFloat = 0.040
            var analogousAccentHueOffset: CGFloat = -0.042
            var neutralColorHintFraction: Double = 0.11
            var neutralTopHueFraction: Double = 0.065
            var neutralSecondHueDistance: Double = 0.10
            var neutralAnalogousSecondaryHueOffset: CGFloat = 0.035
            var neutralAnalogousAccentHueOffset: CGFloat = -0.035
        }
        struct TextScrim: Codable, Equatable {
            var brightLuminanceStart: Double = 0.62
            var brightLuminanceEnd: Double = 0.82
            var lowVibrancyThreshold: Double = 0.38
            var lyricsMaxOpacity: Double = 0.052
            var controlsMaxOpacity: Double = 0.036
            var centerMultiplier: Double = 1.0
            var edgeMultiplier: Double = 0.30
        }
    }
    struct WujieTokensConfig: Codable, Equatable {
        var contentDrop: CGFloat = 38
        var sideInset: CGFloat = 26
    }
    struct WujieDesignConfig: Codable, Equatable {
        var space = Space()
        var fontSize = FontSize()
        var tracking = Tracking()
        var opacity = Opacity()
        var lyrics = Lyrics()
        struct Space: Codable, Equatable {
            var xxs: CGFloat = 4
            var xs: CGFloat = 8
            var sm: CGFloat = 12
            var md: CGFloat = 16
            var lg: CGFloat = 20
            var xl: CGFloat = 24
            var xxl: CGFloat = 28
            var xxxl: CGFloat = 32
        }
        struct FontSize: Codable, Equatable {
            var title: CGFloat = 34
            var eyebrow: CGFloat = 11
            var artist: CGFloat = 16
            var album: CGFloat = 16
            var time: CGFloat = 12
            var iconPrimary: CGFloat = 25
            var iconMode: CGFloat = 20
            var iconUtility: CGFloat = 18
        }
        struct Tracking: Codable, Equatable {
            var title: CGFloat = -0.5
            var eyebrow: CGFloat = 2.6
        }
        struct Opacity: Codable, Equatable {
            var textSecondary: Double = 0.62
            var eyebrow: Double = 0.42
            var artistName: Double = 0.74
            var albumName: Double = 0.5
            var separator: Double = 0.3
            var timeLabel: Double = 0.66
            var iconStrong: Double = 0.92
            var iconIdle: Double = 0.52
            var disabledControl: Double = 0.4
            var pressDim: Double = 0.6
            var hoverWash: Double = 0.06
        }
        struct Lyrics: Codable, Equatable {
            var fontSize: CGFloat = 27
            var rowSpacing: CGFloat = 18
            var fadeExpansion: CGFloat = 0.15
            var verticalPaddingFraction: CGFloat = 0.5
            var lineHorizontalPadding: CGFloat = 6
            var columnLeading: CGFloat = 46
            var columnTrailing: CGFloat = 22
            var columnTopPadding: CGFloat = 0
            var columnBottomPadding: CGFloat = 0
            var untimedFontSize: CGFloat = 27
            var untimedOpacity: Double = 0.84
            var untimedLineSpacing: CGFloat = 15
        }
    }
    struct ShelfConfig: Codable, Equatable {
        var plate = Plate()
        var row = Row()
        var angle = Angle()
        var card = Card()
        var light = Light()
        var perf = Perf()
        var elevation = Elevation()
        var pull = Pull()
        var gather = Gather()
        var dragon = Dragon()
        var browse = Browse()
        var fontSize = FontSize()
        struct Plate: Codable, Equatable {
            var cornerRadius: CGFloat = 14
            var widthFraction: CGFloat = 0.194
            var heightFraction: CGFloat = 0.50
            var minSide: CGFloat = 96
            var maxSide: CGFloat = 314
            var firstGapFraction: CGFloat = 1.04
            var edgeReachFraction: CGFloat = 0.83
            var edgeInsetFraction: CGFloat = 0.08
            var spineDecay: CGFloat = 6.8
            var visibleEachSide: Int = 14
            var reflectionFraction: CGFloat = 0.5
            var reflectionOpacity: Double = 0.26
            var reflectionGap: CGFloat = 4
            var scaleDecay: CGFloat = 3.6
            var farScaleFloor: CGFloat = 0.58
            var distFadeStart: CGFloat = 1.15
            var distFadePerStep: CGFloat = 0.125
            var distOpacityFloor: Double = 0.12
        }
        struct Row: Codable, Equatable {
            var edgeFadeStart: CGFloat = 11.4
            var edgeFadeEnd: CGFloat = 14.2
            var baselineFraction: CGFloat = 0.62
            var topSafeInset: CGFloat = 26
            var bottomSafeInset: CGFloat = 16
        }
        struct Angle: Codable, Equatable {
            var baseAngle: Double = 10
            var stepAngle: Double = 0.45
            var maxAngle: Double = 18
            var perspective: CGFloat = 0.42
            var flattenBand: CGFloat = 0.5
            var heroScale: CGFloat = 1.26
            var heroPausedScale: CGFloat = 1.18
            var heroDrop: CGFloat = 4
            var shelfRaise: CGFloat = 0
            var edgeCenterRise: CGFloat = 0.08
            var farDimPerStep: Double = 0.018
            var dimFloor: Double = 0.82
        }
        struct Card: Codable, Equatable {
            var cornerRadius: CGFloat = 10
            var edgeLineWidth: CGFloat = 1.1
            var heroEdgeLineWidth: CGFloat = 1.6
            var sheenOpacity: Double = 0.26
            var heroGlowOpacity: Double = 0.54
            var shelfGlowOpacity: Double = 0.18
        }
        struct Light: Codable, Equatable {
            var bloomOpacity: Double = 0.72
            var bloomWidthScale: CGFloat = 3.0
            var bloomHeightScale: CGFloat = 2.0
            var bloomRise: CGFloat = 0.56
            var skylightOpacity: Double = 0.18
            var rimCenter: Double = 0.92
            var rimFalloff: Double = 0.30
            var rimFloor: Double = 0.10
            var sheenCenter: Double = 1.0
        }
        struct Perf: Codable, Equatable {
            var premiumDetailBand: CGFloat = 4.5
            var dofStart: CGFloat = 1.0
            var dofFullDistance: CGFloat = 8.5
            var dofMaxBlur: CGFloat = 5.2
            var shadowBand: CGFloat = 3.0
            var reflectionBand: CGFloat = 1.25
            var hoverMoveThreshold: CGFloat = 6.0
            var fullCoverCacheSide: CGFloat = 360
            var liteCoverCacheSide: CGFloat = 180
            var reflectionCacheSide: CGFloat = 220
        }
        struct Elevation: Codable, Equatable {
            var surfaceRadius: CGFloat = 20
            var surfaceY: CGFloat = 10
            var floatingRadius: CGFloat = 9
            var floatingY: CGFloat = 3
        }
        struct Pull: Codable, Equatable {
            var threshold: CGFloat = 56
            var maxOffset: CGFloat = 124
            var resistance: CGFloat = 190
            var tapSlop: CGFloat = 6
        }
        struct Gather: Codable, Equatable {
            var longPress: Double = 0.32
            var pullCommitDown: CGFloat = 46
            var shakeWindow: TimeInterval = 0.45
            var shakeMinPath: CGFloat = 60
            var pickupMove: CGFloat = 14
        }
        struct Dragon: Codable, Equatable {
            var chainSpacing: CGFloat = 30
            var dirSmoothing: CGFloat = 0.28
            var tiltPerRank: Double = 1.2
            var tiltMax: Double = 9
            var springBase: Double = 0.18
            var springPerRank: Double = 0.05
            var damping: Double = 0.76
        }
        struct Browse: Codable, Equatable {
            var trackpadSensitivity: CGFloat = 0.011
            var wheelSensitivity: CGFloat = 0.34
            var overscroll: CGFloat = 0.5
            var returnDelay: UInt64 = 1_600_000_000
        }
        struct FontSize: Codable, Equatable {
            var title: CGFloat = 28
            var subtitle: CGFloat = 14
            var lyricActive: CGFloat = 34
            var lyricContext: CGFloat = 19
            var time: CGFloat = 12
            var hint: CGFloat = 11
        }
    }
}
