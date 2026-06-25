import AppKit
import Combine
import MediaLibCore
import SwiftUI

// MARK: - 书架式沉浸播放器（Shelf · 第三款音乐主题）
//
// 设计目标（需求以用户描述为准，资料包/参考图仅作灵感）：
//   · 无任何播放控制按钮：操作全部长在「唱片实体」上。
//   · 上部一排参考效果图的薄玻璃封面墙：已播放在左 · 当前居中直立发光 · 待播在右。
//   · 自上而下：唱片架 → 歌词 → 进度条；音量在右上轻量位。
//
// 隔离保证：本文件全部类型以 `Shelf` 前缀命名，仅经 `MusicPlayerView` 顶层 `isShelf` 分支接入
// （body 中 `if isShelf { MusicShelfPlayerStage(...) }`）。琉璃 / 无界 代码一字不改。
// 复用的引擎层（MetalAlbumBackdropView 取色底板 / PosterImage 封面 / ArtworkImageCache 缓存 /
// AlbumColorPalette / MpvPlayerController / AppState.musicQueue）均为只读复用，不改其行为。
//
// 轮次（见「书架沉浸播放器主题_实现规划.md」）：
//   R1（本轮）：枚举 + 设置项 + DEBUG 参数；静态沉浸布局（底板 / 书架时间轴 / 薄玻璃封面墙 / 倒影 /
//               歌词聚焦 / 进度条 / 音量 / 手势提示）；已含：点当前唱片→播放暂停、hover 其它唱片→平放、点其它→播放。
//   R2：向下拉→单曲循环 + 玻璃质感精修。R3：长按聚拢 + 晃动洗牌。R4：滚动时间轴浏览历史。R5：虚拟化 + 边界 + 收尾。

// MARK: - 控制器投影（仅在变化时才触发对应叶子视图重绘，避免 currentTime 高频刷新拖垮整树）

/// 把 `MpvPlayerController` 的某个派生值投影成独立 `ObservableObject`：订阅 controller 的 objectWillChange，
/// 但只有当映射出的 Equatable 值真正变化时才 `value =`，从而把高频 currentTime 的影响限制在用到它的那个叶子视图里。
/// （与 PlayerView 内部 `PlayerControllerProjection` 同源思路；那个是 private，这里为书架隔离独立实现。）
@MainActor
final class ShelfControllerProjection<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value
    private weak var controller: MpvPlayerController?
    private let map: @MainActor (MpvPlayerController) -> Value
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController, map: @escaping @MainActor (MpvPlayerController) -> Value) {
        self.controller = controller
        self.map = map
        self.value = map(controller)
        // 单跳：objectWillChange → Task(@MainActor) → 直接 refresh（去掉额外的 DispatchQueue 合并跳）。
        // refresh 幂等（仅在映射值真变时才发布），无需合并；少一跳 → 播放/暂停等状态变化的视觉响应更快。
        self.cancellable = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard let controller else { return }
        let next = map(controller)
        guard next != value else { return }
        value = next
    }
}

/// 进度条/歌词共用的时间快照。
struct ShelfTimelineSnapshot: Equatable {
    var currentTime: Double
    var duration: Double
    var isPlaying: Bool
}

// MARK: - 设计系统 token（改这里 = 统一调整书架视觉节奏；与琉璃/无界完全隔离）

enum ShelfDesignSystem {
    /// 唱片几何。书架整体放大（封面 ×1.5）、铺满窗口宽度成一长排（排版：hero 居中 + 身后一长排薄玻璃封面）。
    enum Plate {
        static var cornerRadius: CGFloat { MusicThemeConfig.active.shelf.plate.cornerRadius }
        /// 唱片边长占可用宽/高的比例与上下限（R1 ×1.5；R12 再 ×1.1，整体更大）。
        static var widthFraction: CGFloat { MusicThemeConfig.active.shelf.plate.widthFraction }
        static var heightFraction: CGFloat { MusicThemeConfig.active.shelf.plate.heightFraction }
        // 下限降到 96：窄/矮窗口里唱片随可用空间收缩以**完整放进书架区**（旧 152 会强行撑大→溢出窗口顶部被裁切）。
        static var minSide: CGFloat { MusicThemeConfig.active.shelf.plate.minSide }
        static var maxSide: CGFloat { MusicThemeConfig.active.shelf.plate.maxSide }
        /// 第一张邻居相对中心的水平间距（占边长比例）：贴近效果图，中心卡两侧露出大封面。
        static var firstGapFraction: CGFloat { MusicThemeConfig.active.shelf.plate.firstGapFraction }
        /// 第 2 张起按窗口半宽展开，歌曲足够多时书架能贯穿整个播放器左右边缘。
        static var edgeReachFraction: CGFloat { MusicThemeConfig.active.shelf.plate.edgeReachFraction }
        static var edgeInsetFraction: CGFloat { MusicThemeConfig.active.shelf.plate.edgeInsetFraction }
        static var spineDecay: CGFloat { MusicThemeConfig.active.shelf.plate.spineDecay }
        /// 渲染窗口：中心两侧最多渲染多少张（具体数量再按窗口宽度自适应）。
        /// 性能：湖光唱片墙最重的是每张卡的图片、玻璃、倒影和离屏合成；远端卡已经小且靠近边缘，
        /// 收到 11 后仍能铺满常见窗口，同时少挂 6 张左右的实时卡片。
        static var visibleEachSide: Int { MusicThemeConfig.active.shelf.plate.visibleEachSide }
        /// 倒影高度占边长比例 / 不透明度 / 与唱片底缘的间隙。
        static var reflectionFraction: CGFloat { MusicThemeConfig.active.shelf.plate.reflectionFraction }
        static var reflectionOpacity: Double { MusicThemeConfig.active.shelf.plate.reflectionOpacity }
        static var reflectionGap: CGFloat { MusicThemeConfig.active.shelf.plate.reflectionGap }
        /// 近大远小：scale 随 |diffF| 指数衰减（中心≈1，远处收小到 farScaleFloor）。
        static var scaleDecay: CGFloat { MusicThemeConfig.active.shelf.plate.scaleDecay }
        static var farScaleFloor: CGFloat { MusicThemeConfig.active.shelf.plate.farScaleFloor }
        /// 一阶邻卡(|diff|=1)的近大远小 scale —— 作为"行中线"参照：
        /// hero 放大后用它反推竖直落点，使中心与两侧封面中心严格齐平（与上面的 scale 公式同源）。
        static let neighborScale: CGFloat = farScaleFloor + (1 - farScaleFloor) * CGFloat(exp(-1.0 / Double(scaleDecay)))
        /// 近清远淡：distFadeStart 张内全清晰，之后每张线性变淡，distOpacityFloor 封底。
        static var distFadeStart: CGFloat { MusicThemeConfig.active.shelf.plate.distFadeStart }
        static var distFadePerStep: CGFloat { MusicThemeConfig.active.shelf.plate.distFadePerStep }
        static var distOpacityFloor: Double { MusicThemeConfig.active.shelf.plate.distOpacityFloor }
    }

    /// 横向排布的边缘羽化与基线（斜放书架同样复用这些字段）。
    enum Row {
        static var edgeFadeStart: CGFloat { MusicThemeConfig.active.shelf.row.edgeFadeStart } // 书架重新贯穿屏幕：只让最外缘 2~3 张柔化淡出，避免中段变空
        static var edgeFadeEnd: CGFloat { MusicThemeConfig.active.shelf.row.edgeFadeEnd }
        static var baselineFraction: CGFloat { MusicThemeConfig.active.shelf.row.baselineFraction } // 唱片竖直中心占书架区高度比：偏下陈列、给顶部留余量（实际再被 top/bottom 限位钳制）
        static var topSafeInset: CGFloat { MusicThemeConfig.active.shelf.row.topSafeInset }
        static var bottomSafeInset: CGFloat { MusicThemeConfig.active.shelf.row.bottomSafeInset }
    }

    /// 效果图式封面墙：中心外的唱片仍是薄封面卡，只做轻微 Y 轴透视和密集重叠；
    /// 正在播放的那张 = hero，平放正对 + 前置 + 柔光边缘。
    enum Angle {
        static var baseAngle: Double { MusicThemeConfig.active.shelf.angle.baseAngle } // 第一张邻居只轻微透视，贴近效果图的正面封面墙
        static var stepAngle: Double { MusicThemeConfig.active.shelf.angle.stepAngle } // 越远越略侧，但不再转成实体侧面
        static var maxAngle: Double { MusicThemeConfig.active.shelf.angle.maxAngle } // 薄封面卡的透视上限
        static var perspective: CGFloat { MusicThemeConfig.active.shelf.angle.perspective } // 轻透视，避免厚砖感
        static var flattenBand: CGFloat { MusicThemeConfig.active.shelf.angle.flattenBand } // |diffF| 小于此值视为中心 hero（平放）
        static var heroScale: CGFloat { MusicThemeConfig.active.shelf.angle.heroScale } // hero 抽出后的放大（播放时）
        static var heroPausedScale: CGFloat { MusicThemeConfig.active.shelf.angle.heroPausedScale } // 暂停时略小
        static var heroDrop: CGFloat { MusicThemeConfig.active.shelf.angle.heroDrop } // hero 底边基本贴合架面，只略微压前
        static var shelfRaise: CGFloat { MusicThemeConfig.active.shelf.angle.shelfRaise } // 两侧封面与中心共享同一架面
        /// 两侧封面中心相对中心唱片的**轻微上扬**量（×plateSize×(1−scale)）：
        /// 0 = 所有中心严格水平；>0 = 越远的封面中心越往上抬一点点，连线读作"轻轻上扬的翼线"而非下坠。
        static var edgeCenterRise: CGFloat { MusicThemeConfig.active.shelf.angle.edgeCenterRise }
        static var farDimPerStep: Double { MusicThemeConfig.active.shelf.angle.farDimPerStep } // 每远离一张压暗多少（R1 减弱：靠 opacity 表达"远=淡"，不靠压黑）
        static var dimFloor: Double { MusicThemeConfig.active.shelf.angle.dimFloor } // 压暗下限（抬高：远卡淡而不脏，避免两侧发黑）
    }

    /// 薄玻璃封面卡：不再画正四棱柱，只用封面、柔光棱线、镜面反光和浅倒影贴近效果图。
    enum Card {
        static var cornerRadius: CGFloat { MusicThemeConfig.active.shelf.card.cornerRadius }
        static var edgeLineWidth: CGFloat { MusicThemeConfig.active.shelf.card.edgeLineWidth }
        static var heroEdgeLineWidth: CGFloat { MusicThemeConfig.active.shelf.card.heroEdgeLineWidth }
        static var sheenOpacity: Double { MusicThemeConfig.active.shelf.card.sheenOpacity }
        static var heroGlowOpacity: Double { MusicThemeConfig.active.shelf.card.heroGlowOpacity }
        static var shelfGlowOpacity: Double { MusicThemeConfig.active.shelf.card.shelfGlowOpacity }
    }

    /// 顶部白色柔和面光源（物理光照）：一束位于书架正上方、略偏前的柔光，
    /// 给中心封面最强的顶沿高光描边，越靠两侧（离光心越远、越斜）描边越淡。
    /// 光也影响：顶部 bloom、玻璃 sheen 方向（朝向光心）、地面倒影亮度。
    enum Light {
        static var bloomOpacity: Double { MusicThemeConfig.active.shelf.light.bloomOpacity } // 书架上方面光源 bloom 强度（.screen）
        static var bloomWidthScale: CGFloat { MusicThemeConfig.active.shelf.light.bloomWidthScale } // bloom 椭圆宽度（相对 hero 边长）
        static var bloomHeightScale: CGFloat { MusicThemeConfig.active.shelf.light.bloomHeightScale } // bloom 椭圆高度
        static var bloomRise: CGFloat { MusicThemeConfig.active.shelf.light.bloomRise } // bloom 中心相对 hero 顶沿再上移（×plateSize；下移=更明显照到 hero）
        static var skylightOpacity: Double { MusicThemeConfig.active.shelf.light.skylightOpacity } // 全窗顶部天光（.screen，仅上半）
        static var rimCenter: Double { MusicThemeConfig.active.shelf.light.rimCenter } // 中心封面顶沿高光强度
        static var rimFalloff: Double { MusicThemeConfig.active.shelf.light.rimFalloff } // 每远离一张高光衰减
        static var rimFloor: Double { MusicThemeConfig.active.shelf.light.rimFloor } // 远卡仍保留极弱顶沿光
        static var sheenCenter: Double { MusicThemeConfig.active.shelf.light.sheenCenter } // 中心 sheen 系数；两侧按 rim 比例缩
    }

    /// 性能分级：远处又小又淡的卡降级渲染（视觉几乎无损，省大量离屏/混合层）。
    /// 近景带（|diffF|≤premiumDetailBand）保持全玻璃高光；之外渲染精简卡（仅封面+一层柔光+细描边）。
    enum Perf {
        static var premiumDetailBand: CGFloat { MusicThemeConfig.active.shelf.perf.premiumDetailBand } // 此距离内=全玻璃高光（hero/邻卡）；之外=精简卡
        static var dofStart: CGFloat { MusicThemeConfig.active.shelf.perf.dofStart } // 景深从一阶邻卡外开始，不让中心/近邻变糊
        static var dofFullDistance: CGFloat { MusicThemeConfig.active.shelf.perf.dofFullDistance } // 到该距离达到最大模糊，之后保持，不再归零
        static var dofMaxBlur: CGFloat { MusicThemeConfig.active.shelf.perf.dofMaxBlur } // 远处稳定保持最糊，修复“中间糊、最远清”
        static var shadowBand: CGFloat { MusicThemeConfig.active.shelf.perf.shadowBand } // 仅近景带投影（远卡阴影在 0.12 透明度下不可见）
        static var reflectionBand: CGFloat { MusicThemeConfig.active.shelf.perf.reflectionBand } // 仅中心与一阶邻卡保留倒影；二阶以上水面镜像几乎不可辨
        static var hoverMoveThreshold: CGFloat { MusicThemeConfig.active.shelf.perf.hoverMoveThreshold } // 鼠标移动超过该距离才重新命中唱片
        static let hoverSampleInterval: TimeInterval = 1.0 / 30.0
        static let auroraFrameInterval: TimeInterval = 1.0 / 20.0 // 极光底板是低频漂移，20Hz 比逐层 repeatForever 更稳
        static let lightFieldFrameInterval: TimeInterval = 1.0 / 24.0 // 单 Canvas 水光的受控刷新率；慢速光效 24Hz 足够平滑
        static var fullCoverCacheSide: CGFloat { MusicThemeConfig.active.shelf.perf.fullCoverCacheSide } // hero/近景封面保持高分辨率
        static var liteCoverCacheSide: CGFloat { MusicThemeConfig.active.shelf.perf.liteCoverCacheSide } // 远卡显示尺寸约 90~170pt，半分辨率视觉无损且少解码/内存
        static var reflectionCacheSide: CGFloat { MusicThemeConfig.active.shelf.perf.reflectionCacheSide } // 倒影独立低清晰度，保持水面柔化观感
    }

    /// 前景悬浮 chrome 的统一高程刻度（skill §4 elevation-consistent / effects-match-style）：
    /// 中性黑投影分两级，让"浮在湖面上的玻璃"共享同一套景深语言，而非各自随手取阴影值。
    /// 仅用于中性界面 chrome（Dock / 顶部提示胶囊）；唱片接触阴影、专辑色辉光、文字描边等"艺术光影"不归此管。
    enum Elevation {
        /// surface：主控制面（Dock）—— 更高更沉。
        static let surfaceColor = Color.black.opacity(0.26)
        static var surfaceRadius: CGFloat { MusicThemeConfig.active.shelf.elevation.surfaceRadius }
        static var surfaceY: CGFloat { MusicThemeConfig.active.shelf.elevation.surfaceY }
        /// floating：轻浮元素（顶部提示胶囊）—— 浅浅托起、与背景拉开层次即可。
        static let floatingColor = Color.black.opacity(0.18)
        static var floatingRadius: CGFloat { MusicThemeConfig.active.shelf.elevation.floatingRadius }
        static var floatingY: CGFloat { MusicThemeConfig.active.shelf.elevation.floatingY }
    }

    enum Motion {
        /// 布局重排（hover / 切歌）弹簧。
        static let layout = Animation.interactiveSpring(response: 0.48, dampingFraction: 0.82, blendDuration: 0.12)
        static let hover = Animation.spring(response: 0.32, dampingFraction: 0.74)
        /// 下拉松手回弹：带一点 Q 弹的弹簧。
        static let pullBack = Animation.spring(response: 0.42, dampingFraction: 0.62)
        /// 拾起 / 散开（进入或退出拖动态）。
        static let gather = Animation.spring(response: 0.46, dampingFraction: 0.80)
        /// 播放放大 / 暂停还原。
        static let playingPop = Animation.spring(response: 0.40, dampingFraction: 0.74)
        /// 播放/暂停瞬间的状态切换：很快很利落（response 0.15 + 几乎不回弹），点下即响应。
        static let playPause = Animation.spring(response: 0.15, dampingFraction: 0.9)

        // —— 微交互统一节奏（skill §7 motion-consistency）：把散落的 hover/press/淡入收敛到统一命名刻度，
        //    让全部控件共享同一手感；各值与原值几乎一致（±20ms / 弹簧 0.28↔0.3），仅消除相邻控件的不一致。
        /// 控件 hover 浮起/落下（统一原 0.16 与 0.18）。
        static let controlHover = Animation.easeOut(duration: 0.18)
        /// 控件按压回弹（统一原 0.28 / 0.3，dampingFraction 0.6）。
        static let controlPress = Animation.spring(response: 0.3, dampingFraction: 0.6)
        /// 状态/提示文字交叉淡入（统一原 0.25 / 0.28 / 0.3）。
        static let contentFade = Animation.easeInOut(duration: 0.28)
        /// 正在播放大标题切歌交叉淡入：保留更舒缓的层级节奏（比 contentFade 略慢）。
        static let titleFade = Animation.easeInOut(duration: 0.38)
    }

    /// 「向下拉当前唱片 → 单曲循环」手势。
    enum Pull {
        static var threshold: CGFloat { MusicThemeConfig.active.shelf.pull.threshold } // 实际竖直位移超过此值即触发
        static var maxOffset: CGFloat { MusicThemeConfig.active.shelf.pull.maxOffset } // 橡皮筋下拉位移上限
        static var resistance: CGFloat { MusicThemeConfig.active.shelf.pull.resistance } // 越大越「沉」
        static var tapSlop: CGFloat { MusicThemeConfig.active.shelf.pull.tapSlop } // 位移小于此视为点击（播放/暂停）
    }

    /// 「长按当前唱片 → 再晃动 → 唱片跟随鼠标，拖出卡片长龙」。
    enum Gather {
        static var longPress: Double { MusicThemeConfig.active.shelf.gather.longPress } // 长按多久后进入「待拾起」
        // 早期明确下拉的竖直阈值：调大以免长按期间手指微微下飘被误判成下拉（导致长按被取消、拾不起来）。
        static var pullCommitDown: CGFloat { MusicThemeConfig.active.shelf.gather.pullCommitDown }
        static var shakeWindow: TimeInterval { MusicThemeConfig.active.shelf.gather.shakeWindow } // 晃动判定的时间窗
        static var shakeMinPath: CGFloat { MusicThemeConfig.active.shelf.gather.shakeMinPath } // 窗内最小路径长度（放宽，更易晃动拾起）
        static let shakeMinReversals = 2                // 窗内最小方向反转次数
        /// 待拾起(primed)后，指针移动超过此距离即拾起（晃动的兜底——保证「长按后一拖就跟手」不会拾不起来）。
        static var pickupMove: CGFloat { MusicThemeConfig.active.shelf.gather.pickupMove }
    }

    /// 跟随鼠标的「卡片长龙」（参考手机多选图标后拖动：所有卡片排成一列跟着手指走，靠后的越滞后）。
    enum Dragon {
        static var chainSpacing: CGFloat { MusicThemeConfig.active.shelf.dragon.chainSpacing } // 每张沿「运动反方向」相对前一张的堆叠间距（拖尾长龙）
        static var dirSmoothing: CGFloat { MusicThemeConfig.active.shelf.dragon.dirSmoothing } // 拖动方向平滑系数（越小越跟手但越抖）
        static var tiltPerRank: Double { MusicThemeConfig.active.shelf.dragon.tiltPerRank } // 每张多一点 Z 倾斜，长龙更灵动
        static var tiltMax: Double { MusicThemeConfig.active.shelf.dragon.tiltMax }
        static var springBase: Double { MusicThemeConfig.active.shelf.dragon.springBase } // 领头卡跟手弹簧
        static var springPerRank: Double { MusicThemeConfig.active.shelf.dragon.springPerRank } // 越靠后弹簧越慢 → 拖尾「长龙」
        static var damping: Double { MusicThemeConfig.active.shelf.dragon.damping }
    }

    /// 「滚动 → 沿时间轴翻看历史/待播」。
    enum Browse {
        static var trackpadSensitivity: CGFloat { MusicThemeConfig.active.shelf.browse.trackpadSensitivity } // 触控板精确像素 → 卡片单位
        static var wheelSensitivity: CGFloat { MusicThemeConfig.active.shelf.browse.wheelSensitivity } // 鼠标滚轮行 → 卡片单位
        static var overscroll: CGFloat { MusicThemeConfig.active.shelf.browse.overscroll } // 首/末卡片外的回弹余量
        static var returnDelay: UInt64 { MusicThemeConfig.active.shelf.browse.returnDelay } // 无操作多久后回弹到当前曲（ns）
    }

    /// 文字层级。
    enum FontSize {
        static var title: CGFloat { MusicThemeConfig.active.shelf.fontSize.title } // 正在播放曲名（加大）
        static var subtitle: CGFloat { MusicThemeConfig.active.shelf.fontSize.subtitle } // 艺术家 · 专辑
        static var lyricActive: CGFloat { MusicThemeConfig.active.shelf.fontSize.lyricActive }
        static var lyricContext: CGFloat { MusicThemeConfig.active.shelf.fontSize.lyricContext }
        static var time: CGFloat { MusicThemeConfig.active.shelf.fontSize.time }
        static var hint: CGFloat { MusicThemeConfig.active.shelf.fontSize.hint }
    }
}

// MARK: - 单张唱片在书架时间轴上的视觉布点

/// 由「相对当前曲的偏移 diff」纯函数推导出一张唱片的全部视觉参数。集中在此便于后续轮次微调。
struct ShelfSlot {
    var xOffset: CGFloat
    var scale: CGFloat
    var rotationY: Double
    var rotationZ: Double
    var opacity: Double
    var blur: CGFloat
    var brightness: Double
    var zIndex: Double
    var isCenter: Bool
}

/// 斜放书架布点：`diffF` = 该唱片相对**视口中心**的偏移（= 相对当前曲的整数偏移 − 浏览平移量 browseOffset）。
/// **所有唱片同尺寸**（`scale` 恒 1，斜放靠 3D 透视天然收窄投影，物理仍同尺寸）；
/// 中心带（|diffF|<flattenBand）平放正对（rotationY→0）= 从架子抽出来的那张；其余统一斜侧向放置
/// （左面朝右 +side / 右面朝左 −side）。水平位移累进（近邻 firstGap、远处渐进压缩成密集封面墙）。
/// 远处轻微压暗加纵深、最外缘羽化防硬切——都不改尺寸。
/// `flattenCenter`：是否让中心带平放（idle 时 true = 当前曲抽出平放正对；浏览时 false = 整架斜放平移，
/// 中间唱片同样转为侧向放置，呼应需求 3e）。
func shelfAngledSlot(diffF: CGFloat, plateSize: CGFloat, rackWidth: CGFloat, flattenCenter: Bool = true) -> ShelfSlot {
    let a = abs(diffF)
    let s: CGFloat = diffF == 0 ? 0 : (diffF > 0 ? 1 : -1)
    let band = ShelfDesignSystem.Angle.flattenBand
    let isHero = flattenCenter && a < band

    // 水平位移：a≤1 线性铺到第一张邻居 firstGap，让邻居按效果图从 hero 两侧露出；
    // 之后按窗口半宽自适应展开，歌曲足够多时书架能真正贯穿左右边缘。
    let first = ShelfDesignSystem.Plate.firstGapFraction
    let edgeReach = max(
        plateSize * (first + 0.4),
        rackWidth * ShelfDesignSystem.Plate.edgeReachFraction - plateSize * ShelfDesignSystem.Plate.edgeInsetFraction
    )
    let span = max(edgeReach / max(plateSize, 1) - first, 0.2)
    let decay = ShelfDesignSystem.Plate.spineDecay
    let units: CGFloat = a <= 1
        ? a * first
        : first + span * (1 - CGFloat(exp(-Double(a - 1) / Double(decay))))
    let x = s * units * plateSize

    // 斜角：hero 平放(0)；其余随距离增大越来越侧（baseAngle + step·(a−1)，封顶 maxAngle）。
    // 浏览态(flattenCenter=false)中心也斜放。左面朝右(+)/右面朝左(−)。
    let turn = isHero ? 0
        : min(ShelfDesignSystem.Angle.maxAngle,
              ShelfDesignSystem.Angle.baseAngle + max(0, Double(a) - 1) * ShelfDesignSystem.Angle.stepAngle)
    let rotationY = Double(-s) * turn

    // 近大远小：中心≈1，远处指数收小到 farScaleFloor（物理纵深，不靠透视假象）。
    let sFloor = ShelfDesignSystem.Plate.farScaleFloor
    let sDecay = ShelfDesignSystem.Plate.scaleDecay
    let scale = sFloor + (1 - sFloor) * CGFloat(exp(-Double(a) / Double(sDecay)))

    // 远处轻微压暗（纵深），下限抬高 → 远卡淡而不脏。
    let dim = max(ShelfDesignSystem.Angle.dimFloor,
                  1 - Double(max(0, a - band)) * ShelfDesignSystem.Angle.farDimPerStep)

    // 封面不透明：远近一律实色，靠 zIndex 前后遮挡（近卡盖住远卡的被挡部分）+ 近大远小 scale + 远处轻压暗表达纵深，
    // 不再用 opacity 淡出制造"透视玻璃"观感（用户要求：封面不透明，被遮挡部分不显示即可）。
    // 仅保留最外缘羽化：渲染上限附近的 2~3 张软淡出，避免书架在渲染边界处硬切。
    let edgeFade = max(0.0, min(1, (ShelfDesignSystem.Row.edgeFadeEnd - a) /
        max(ShelfDesignSystem.Row.edgeFadeEnd - ShelfDesignSystem.Row.edgeFadeStart, 0.001)))
    let opacity = Double(edgeFade)

    return ShelfSlot(
        xOffset: x, scale: scale, rotationY: rotationY, rotationZ: 0,
        opacity: opacity, blur: 0, brightness: dim,
        zIndex: 1000 - Double(a), isCenter: isHero
    )
}

/// 鼠标晃动判定：长按后采样指针轨迹，用「时间窗内路径长度 + 方向反转次数」判断是否在晃动（→ 拾起卡片长龙）。
/// 用 class 持有，挂在 `@State` 上时改动内部数组不触发视图失效（避免每次 mousemove 重渲染）。
final class ShelfShakeDetector {
    private var samples: [(x: CGFloat, y: CGFloat, t: TimeInterval)] = []

    func reset() { samples.removeAll() }

    func push(x: CGFloat, y: CGFloat, at time: TimeInterval) {
        samples.append((x, y, time))
        let window = ShelfDesignSystem.Gather.shakeWindow
        samples.removeAll { time - $0.t > window }
    }

    func isShaking() -> Bool {
        guard samples.count >= 5 else { return false }
        var distance: CGFloat = 0
        var reversals = 0
        var lastDir: CGFloat = 0
        for i in 1..<samples.count {
            let dx = samples[i].x - samples[i - 1].x
            let dy = samples[i].y - samples[i - 1].y
            distance += (dx * dx + dy * dy).squareRoot()
            let dir: CGFloat = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
            if dir != 0, lastDir != 0, dir != lastDir { reversals += 1 }
            if dir != 0 { lastDir = dir }
        }
        return distance > ShelfDesignSystem.Gather.shakeMinPath && reversals >= ShelfDesignSystem.Gather.shakeMinReversals
    }
}

/// 捕获滚轮/触控板滚动事件（窗口级本地监听，不消费事件、不干扰点击与拖拽）。
/// 仅在书架界面挂载；回调给出已换算的「卡片单位」增量（含触控板/滚轮灵敏度差异）。
struct ShelfScrollMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.onScroll = onScroll
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.hostView = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onScroll: ((CGFloat) -> Void)?
        weak var hostView: NSView?
        private var monitor: Any?

        func start() {
            stop()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                // 仅响应书架所在主窗口的滚动；底部队列弹层(NSPopover 独立 window)内的滚动不带动唱片架。
                if let host = self.hostView, let hostWindow = host.window, event.window !== hostWindow {
                    return event
                }
                // 向上滚 / 向右滑 = 看历史(负方向)；向下滚 / 向左滑 = 看待播(正方向)。
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                let raw = abs(dx) > abs(dy) ? dx : dy
                let sensitivity = event.hasPreciseScrollingDeltas
                    ? ShelfDesignSystem.Browse.trackpadSensitivity
                    : ShelfDesignSystem.Browse.wheelSensitivity
                let delta = -raw * sensitivity
                if abs(delta) > 0.0001 {
                    DispatchQueue.main.async { self.onScroll?(delta) }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - 根视图

struct MusicShelfPlayerStage: View {
    @EnvironmentObject private var appState: AppState

    let currentItem: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let lyrics: String
    let timedLyrics: [TimedLyricLine]
    let lyricTimingSource: LyricTimingSource
    let hasDisplayLyrics: Bool
    let isFetchingLyrics: Bool
    let coverGlowEnabled: Bool
    let artworkReady: Bool
    let entranceReady: Bool
    let reduceMotion: Bool
    let colorScheme: ColorScheme
    let onFetchLyrics: () -> Void
    /// 收起播放界面（Dock 的收起按钮）。由 MusicPlayerView 的 onRequestMinimize 透传。
    let onMinimize: () -> Void

    /// 仅观察 isPlaying（投影只在播放/暂停翻转时才发布，currentTime 高频变化不触发整窗重绘）。
    @StateObject private var playbackFlag: ShelfControllerProjection<Bool>
    /// 下拉/洗牌等操作的瞬时提示（顶部胶囊临时替换），用于在无按钮界面里反馈状态变化。
    @State private var transientMessage: String?
    @State private var transientTask: Task<Void, Never>?
    /// 当前是否处于「长按聚拢」态（驱动顶部胶囊提示文案）。
    @State private var isGathered = false
    /// 当前是否在滚动浏览时间轴（驱动顶部胶囊提示文案）。
    @State private var isBrowsing = false
    /// SwiftUI 窗口在系统恢复尺寸或 AppKit 调整 contentSize 后，GeometryProxy 会先变，
    /// 但闭包里的纯局部布局值不一定立即重算。显式保存尺寸，确保 ShelfStageLayout 随窗口更新。
    @State private var stageSize: CGSize = .zero

    /// R1：业务数据统一经 `MusicPlaybackContext` 注入；内部仍解包到原有存储属性，
    /// body 与所有用法零改动（纯接口收敛、等价重构）。
    init(context: MusicPlaybackContext) {
        self.currentItem = context.item
        self.controller = context.controller
        self.palette = context.palette
        self.lyrics = context.lyrics
        self.timedLyrics = context.timedLyrics
        self.lyricTimingSource = context.lyricTimingSource
        self.hasDisplayLyrics = context.hasDisplayLyrics
        self.isFetchingLyrics = context.isFetchingLyrics
        self.coverGlowEnabled = context.coverGlowEnabled
        self.artworkReady = context.artworkReady
        self.entranceReady = context.entranceReady
        self.reduceMotion = context.reduceMotion
        self.colorScheme = context.colorScheme
        self.onFetchLyrics = context.fetchLyrics
        self.onMinimize = context.requestMinimize
        _playbackFlag = StateObject(wrappedValue: ShelfControllerProjection(controller: context.controller) { $0.isPlaying })
    }

    /// 本次队列全量（已播放不出队）：空队列时退化为仅当前曲。
    private var tracks: [MediaItem] {
        appState.musicQueue.isEmpty ? [currentItem] : appState.musicQueue
    }

    private var currentIndex: Int {
        appState.musicQueue.firstIndex(where: { $0.id == currentItem.id }) ?? 0
    }

    /// 正在播放副标题：艺术家为主，专辑仅在与曲名不同时追加（避免单曲出现"YOASOBI · 優しい彗星"这种与标题重复）。
    private var nowPlayingSubtitle: String? {
        let title = currentItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = currentItem.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = currentItem.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let artist, !artist.isEmpty { parts.append(artist) }
        if let album, !album.isEmpty, album != title { parts.append(album) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedSize = stageSize.width > 0 && stageSize.height > 0 ? stageSize : geometry.size
            let isPlaying = playbackFlag.value
            let layout = ShelfStageLayout(size: resolvedSize)

            ZStack {
                // 固定整窗舞台的布局尺寸。背景层使用 ignoresSafeArea，若让它参与
                // ZStack 固有尺寸计算，外层再套固定 frame 时会把标题、歌词、进度和 Dock 一起向上居中。
                Color.clear
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)

                // L0/L1：专辑取色底板 + 暗色玻璃 veil（保证歌词/进度可读，不直接铺大模糊封面）。
                ShelfBackdropLayer(
                    item: currentItem,
                    palette: palette,
                    artworkReady: artworkReady,
                    reduceMotion: reduceMotion,
                    colorScheme: colorScheme,
                    center: CGPoint(x: geometry.size.width / 2, y: layout.rackBaselineY),
                    isPlaying: isPlaying
                )
                .ignoresSafeArea()

                // 全窗顶部天光：与书架面光源同源的环境光，只洗亮上半部，让整屏光照方向一致。
                LinearGradient(
                    colors: [.white.opacity(ShelfDesignSystem.Light.skylightOpacity), .white.opacity(ShelfDesignSystem.Light.skylightOpacity * 0.32), .clear],
                    startPoint: .top, endPoint: .center
                )
                .blendMode(.screen)
                .allowsHitTesting(false)
                .ignoresSafeArea()

                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)

                    // 唱片架按整窗几何定位：中心唱片与标题/歌词共用同一视觉锚点，
                    // 避免 VStack 剩余高度在高窗口里把唱片推到顶部、标题留在中部。
                    ShelfRackView(
                        tracks: tracks,
                        currentIndex: currentIndex,
                        palette: palette,
                        isPlaying: isPlaying,
                        coverGlowEnabled: coverGlowEnabled,
                        reduceMotion: reduceMotion,
                        fixedPlateSize: layout.plateSize,
                        fixedBaselineY: layout.rackBaselineY,
                        onToggleCenter: { controller.togglePlay() },
                        onSelect: { track in
                            if track.id == currentItem.id { controller.togglePlay() }
                            else { appState.play(track) }
                        },
                        onPullDownLoop: { toggleRepeatOne() },
                        onShuffle: { shuffleQueue() },
                        onGatherChange: { gathered in withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.contentFade) { isGathered = gathered } },
                        onBrowseChange: { browsing in withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.contentFade) { isBrowsing = browsing } }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    // 顶部：手势胶囊（居中）。音量已移入底部 Dock。
                    ShelfHintPill(
                        isPlaying: isPlaying,
                        repeatOne: appState.musicRepeatMode == .repeatOne,
                        gathered: isGathered,
                        browsing: isBrowsing,
                        override: transientMessage
                    )
                    .frame(width: layout.hintFrame.width, height: layout.hintFrame.height)
                    .position(x: layout.hintFrame.midX, y: layout.hintFrame.midY)
                    .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.contentFade, value: isPlaying)
                    .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.contentFade, value: appState.musicRepeatMode)

                    // 歌曲标题 + 艺术家：跟随中心唱片底边，而不是跟随唱片架容器底边。
                    ShelfNowPlayingTitle(
                        title: currentItem.title,
                        subtitle: nowPlayingSubtitle,
                        reduceMotion: reduceMotion,
                        isPlaying: isPlaying,
                        tint: palette.glowPrimary.color
                    )
                    .frame(width: layout.titleFrame.width, height: layout.titleFrame.height)
                    .position(x: layout.titleFrame.midX, y: layout.titleFrame.midY)

                    // 歌词聚焦（自包含、独立刷新）。
                    ShelfLyricsFocusView(
                        controller: controller,
                        timedLyrics: timedLyrics,
                        lyrics: lyrics,
                        hasDisplayLyrics: hasDisplayLyrics,
                        isFetchingLyrics: isFetchingLyrics,
                        palette: palette,
                        reduceMotion: reduceMotion,
                        onFetchLyrics: onFetchLyrics
                    )
                    .frame(width: layout.lyricsFrame.width, height: layout.lyricsFrame.height)
                    .position(x: layout.lyricsFrame.midX, y: layout.lyricsFrame.midY)

                    // 进度条（自包含、独立刷新、可拖动 seek）。
                    ShelfProgressRail(controller: controller, palette: palette)
                        .frame(width: layout.progressFrame.width, height: layout.progressFrame.height)
                        .position(x: layout.progressFrame.midX, y: layout.progressFrame.midY)

                    // 底部 Dock：磨砂控制栏。上排图标（收藏/列表/隔空/音量/收起），底部内嵌一条极窄三段横条（上一首/暂停/下一首）。
                    ShelfDock(
                        currentItem: currentItem,
                        controller: controller,
                        palette: palette,
                        isPlaying: isPlaying,
                        reduceMotion: reduceMotion,
                        onMinimize: onMinimize
                    )
                    .frame(height: layout.dockFrame.height)
                    .position(x: layout.dockFrame.midX, y: layout.dockFrame.midY)
                }
                // 电影入场：整组内容自湖面下方升起 + 渐显 + 轻微放大归位（reduceMotion 直接显示）。
                .opacity(entranceReady ? 1 : 0)
                .offset(y: (entranceReady || reduceMotion) ? 0 : 34)
                .scaleEffect((entranceReady || reduceMotion) ? 1 : 0.985, anchor: .center)
                .animation(reduceMotion ? nil : .spring(response: 0.85, dampingFraction: 0.86), value: entranceReady)

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                if stageSize != geometry.size {
                    stageSize = geometry.size
                }
            }
            .onChange(of: geometry.size) { newSize in
                if stageSize != newSize {
                    stageSize = newSize
                }
            }
        }
        .onDisappear { transientTask?.cancel() }
    }

    /// 下拉当前唱片：在「单曲循环 / 顺序」之间切换（无按钮界面下唯一的开关入口）。
    private func toggleRepeatOne() {
        let newMode: MusicRepeatMode = appState.musicRepeatMode == .repeatOne ? .sequential : .repeatOne
        appState.setMusicRepeatMode(newMode)
        showTransient(newMode == .repeatOne ? "已开启单曲循环" : "已关闭单曲循环")
    }

    /// 聚拢态晃动 → 随机重排队列（保持当前曲位置不变）。
    private func shuffleQueue() {
        appState.shuffleMusicQueueKeepingCurrent()
        showTransient("已随机排序")
    }

    private func showTransient(_ text: String) {
        withAnimation(ShelfDesignSystem.Motion.contentFade) { transientMessage = text }
        transientTask?.cancel()
        transientTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(ShelfDesignSystem.Motion.contentFade) { transientMessage = nil }
        }
    }

}

/// 湖光主题的整窗几何锚点。唱片、标题、歌词、进度和 Dock 都从同一套窗口尺寸推导，
/// 避免唱片架使用剩余空间时在高窗口里跑到上方、标题和歌词却留在中下部。
private struct ShelfStageLayout {
    let plateSize: CGFloat
    let rackBaselineY: CGFloat
    let hintFrame: CGRect
    let titleFrame: CGRect
    let lyricsFrame: CGRect
    let progressFrame: CGRect
    let dockFrame: CGRect

    init(size: CGSize) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)

        plateSize = Self.plateSide(for: size)
        // 书架基线必须与播放状态无关。始终按 hero 的最大显示尺寸预留，
        // 否则播放/暂停在 1.26× 与 1.18× 间切换时会把整排唱片一起上下搬移。
        let heroHalf = plateSize * ShelfDesignSystem.Angle.heroScale * 0.5
        let heroDrop = ShelfDesignSystem.Angle.heroDrop

        let dockHeight = min(max(height * 0.088, 62), 70)
        let dockBottomInset = min(max(height * 0.024, 14), 26)
        let dockFrameValue = CGRect(
            x: (width - 304) * 0.5,
            y: height - dockBottomInset - dockHeight,
            width: 304,
            height: dockHeight
        )
        dockFrame = dockFrameValue

        let progressHeight: CGFloat = 26
        let progressGapToDock = min(max(height * 0.014, 8), 14)
        let progressInset = min(max(width * 0.10, 44), 150)
        let progressWidth = max(260, width - progressInset * 2)
        let progressFrameValue = CGRect(
            x: (width - progressWidth) * 0.5,
            y: dockFrameValue.minY - progressGapToDock - progressHeight,
            width: progressWidth,
            height: progressHeight
        )
        progressFrame = progressFrameValue

        let lyricsHeight = min(150, max(88, height * 0.165))
        let lyricsGapToProgress = min(max(height * 0.010, 4), 9)
        let lyricsWidth = min(max(width * 0.54, 440), width - 72)
        let lyricsFrameValue = CGRect(
            x: (width - lyricsWidth) * 0.5,
            y: progressFrameValue.minY - lyricsGapToProgress - lyricsHeight,
            width: lyricsWidth,
            height: lyricsHeight
        )
        lyricsFrame = lyricsFrameValue

        let titleHeight = min(max(height * 0.082, 48), 66)
        let titleGapToLyrics = min(max(height * 0.022, 10), 18)
        let titleWidth = min(max(width * 0.46, 340), 640)
        let titleFrameValue = CGRect(
            x: (width - titleWidth) * 0.5,
            y: lyricsFrameValue.minY - titleGapToLyrics - titleHeight,
            width: titleWidth,
            height: titleHeight
        )
        titleFrame = titleFrameValue

        let coverTitleGap = min(max(height * 0.050, 42), 68)
        let topLimit = ShelfDesignSystem.Row.topSafeInset + heroHalf
        let titleAnchoredBaseline = titleFrameValue.minY - coverTitleGap - heroHalf - heroDrop
        rackBaselineY = max(topLimit, titleAnchoredBaseline)

        let hintHeight: CGFloat = 44
        let hintWidth = min(max(width * 0.34, 260), 420)
        hintFrame = CGRect(
            x: (width - hintWidth) * 0.5,
            y: min(max(height * 0.018, 12), 18),
            width: hintWidth,
            height: hintHeight
        )
    }

    private static func plateSide(for size: CGSize) -> CGFloat {
        let raw = min(size.width * ShelfDesignSystem.Plate.widthFraction, size.height * ShelfDesignSystem.Plate.heightFraction)
        return min(ShelfDesignSystem.Plate.maxSide, max(ShelfDesignSystem.Plate.minSide, raw))
    }
}

// MARK: - 氛围动画按需循环（暂停时缓停到静止，让整窗真正空闲）

/// 把一个 repeatForever 氛围动画做成「按需运行」：active（播放中且非 reduceMotion）时启动循环把 phase 推向 activeValue；
/// 非 active 时用一段短动画落回 restValue 并停转 → 暂停时不再有任何常驻动画逼整窗每帧重绘（GPU 归零、更省电）。
/// 播放中视觉与原先完全一致；仅「暂停 → 静止 / 继续 → 复动」是新增行为。
private struct ShelfAmbientLoop<V: Equatable>: ViewModifier {
    @Binding var phase: V
    let active: Bool
    let activeValue: V
    let restValue: V
    let loop: Animation
    var settle: Animation = .easeOut(duration: 0.6)

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: active) { _ in apply() }
    }

    private func apply() {
        if active {
            withAnimation(loop) { phase = activeValue }
        } else {
            withAnimation(settle) { phase = restValue }
        }
    }
}

private extension View {
    func shelfAmbientLoop<V: Equatable>(_ phase: Binding<V>, active: Bool, activeValue: V, restValue: V,
                                        loop: Animation, settle: Animation = .easeOut(duration: 0.6)) -> some View {
        modifier(ShelfAmbientLoop(phase: phase, active: active, activeValue: activeValue,
                                  restValue: restValue, loop: loop, settle: settle))
    }
}

// MARK: - 底板层

private struct ShelfBackdropLayer: View {
    let item: MediaItem
    let palette: AlbumColorPalette
    let artworkReady: Bool
    let reduceMotion: Bool
    let colorScheme: ColorScheme
    let center: CGPoint
    /// 播放中才让极光/光尘流动；暂停时静止 → 整窗空闲。
    let isPlaying: Bool

    var body: some View {
        ZStack {
            // 流动极光色场（湖光专属·华丽重构）：调色板生成的柔光色斑慢速漂移成「活的极光」，
            // 虹彩微光/顶部天幕/光尘/vignette 统一在单 Canvas 中绘制；不碰 Metal 底板、不影响其它主题。
            ShelfAuroraField(palette: palette, colorScheme: colorScheme, reduceMotion: reduceMotion, isPlaying: isPlaying)

            // 暗色玻璃 veil：自上而下加深，保证下半部歌词/进度可读，整体更沉浸。
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.06), location: 0.0),
                    .init(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.12), location: 0.42),
                    .init(color: Color.black.opacity(colorScheme == .dark ? 0.44 : 0.20), location: 0.74),
                    .init(color: Color.black.opacity(colorScheme == .dark ? 0.54 : 0.28), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

        }
    }
}

/// 湖光底板：由专辑调色板生成的**流动极光色场**——超大柔和色斑慢速漂移（活的极光），
/// 叠虹彩微光 + 顶部天幕辉光 + 上浮光尘 + 边缘 vignette。渐变极缓无色带；reduceMotion 时静态。
private enum ShelfCanvasSoftLight {
    /// 在全画布上绘制软径向光。不要用非透明的 ellipse/roundedRect 边界裁剪光斑，否则动画时会露出硬断层。
    static func radial(in context: inout GraphicsContext,
                       center: CGPoint,
                       radiusX: CGFloat,
                       radiusY: CGFloat,
                       stops: [Gradient.Stop],
                       overscan: CGFloat = 1.12) {
        guard radiusX > 0, radiusY > 0 else { return }
        let baseRadius = max(radiusX, 1)
        let safeOverscan = max(overscan, 1.02)
        var layer = context
        layer.translateBy(x: center.x, y: center.y)
        layer.scaleBy(x: 1, y: radiusY / baseRadius)
        let drawRadius = baseRadius * safeOverscan
        let rect = CGRect(x: -drawRadius, y: -drawRadius, width: drawRadius * 2, height: drawRadius * 2)
        layer.fill(
            Path(rect),
            with: .radialGradient(Gradient(stops: stops), center: .zero, startRadius: 0, endRadius: baseRadius)
        )
    }
}

private struct ShelfAuroraField: View {
    let palette: AlbumColorPalette
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let isPlaying: Bool

    private var isDark: Bool { colorScheme == .dark }
    private var animates: Bool { isPlaying && !reduceMotion }

    /// 不透明基底：专辑主色按明暗模式压暗/提亮。
    private var baseColor: Color {
        let ns = palette.primary.nsColor.usingColorSpace(.sRGB) ?? .gray
        let mixed = isDark
            ? (ns.blended(withFraction: 0.74, of: .black) ?? .black)
            : (ns.blended(withFraction: 0.5, of: .white) ?? .white)
        return Color(nsColor: mixed)
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if animates {
                    TimelineView(.animation(minimumInterval: ShelfDesignSystem.Perf.auroraFrameInterval)) { timeline in
                        canvas(size: geo.size, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    canvas(size: geo.size, time: nil)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func canvas(size: CGSize, time: TimeInterval?) -> some View {
        Canvas(rendersAsynchronously: true) { context, canvasSize in
            var context = context
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(baseColor))

            var screen = context
            screen.blendMode = .screen
            drawAuroraBlobs(in: &screen, size: canvasSize, time: time)
            drawIridescence(in: &screen, size: canvasSize)
            drawTopGlow(in: &screen, size: canvasSize)
            if animates {
                drawParticles(in: &screen, size: canvasSize, time: time ?? 0)
            }

            drawVignette(in: &context, size: canvasSize)
            drawDither(in: &context, size: canvasSize)
        }
        .frame(width: size.width, height: size.height)
    }

    private func drawAuroraBlobs(in context: inout GraphicsContext, size: CGSize, time: TimeInterval?) {
        let w = size.width
        let h = size.height
        let d = max(w, h)
        drawBlob(in: &context, color: palette.glowPrimary.color,
                 baseCenter: CGPoint(x: w * 0.50, y: h * 0.24), diameter: d * 1.12,
                 opacity: isDark ? 0.80 : 0.58, drift: CGSize(width: w * 0.05, height: h * 0.05), period: 26, time: time)
        drawBlob(in: &context, color: palette.primary.color,
                 baseCenter: CGPoint(x: w * 0.14, y: h * 0.82), diameter: d * 0.98,
                 opacity: isDark ? 0.62 : 0.48, drift: CGSize(width: w * 0.07, height: h * 0.04), period: 34, time: time)
        drawBlob(in: &context, color: palette.accent.color,
                 baseCenter: CGPoint(x: w * 0.88, y: h * 0.72), diameter: d * 0.98,
                 opacity: isDark ? 0.58 : 0.44, drift: CGSize(width: w * 0.06, height: h * 0.05), period: 38, time: time)
        drawBlob(in: &context, color: palette.glowPrimary.color,
                 baseCenter: CGPoint(x: w * 0.52, y: h * 1.08), diameter: d * 0.84,
                 opacity: isDark ? 0.42 : 0.34, drift: CGSize(width: w * 0.05, height: h * 0.03), period: 30, time: time)
    }

    private func drawBlob(in context: inout GraphicsContext, color: Color,
                          baseCenter: CGPoint, diameter: CGFloat, opacity: Double,
                          drift: CGSize, period: Double, time: TimeInterval?) {
        let phase = time.map { CGFloat(sin($0 * 2 * .pi / period)) } ?? -1
        let center = CGPoint(x: baseCenter.x + phase * drift.width,
                             y: baseCenter.y + phase * drift.height)
        let gradient = Gradient(stops: [
            .init(color: color.opacity(opacity), location: 0),
            .init(color: color.opacity(opacity * 0.62), location: 0.32),
            .init(color: color.opacity(opacity * 0.28), location: 0.58),
            .init(color: color.opacity(opacity * 0.09), location: 0.8),
            .init(color: color.opacity(0), location: 1)
        ])
        ShelfCanvasSoftLight.radial(in: &context,
                                    center: center,
                                    radiusX: diameter / 2,
                                    radiusY: diameter / 2,
                                    stops: gradient.stops)
    }

    private func drawIridescence(in context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: Color(hue: 0.55, saturation: 0.5, brightness: 1).opacity(isDark ? 0.08 : 0.05), location: 0),
            .init(color: .clear, location: 0.5),
            .init(color: Color(hue: 0.85, saturation: 0.5, brightness: 1).opacity(isDark ? 0.07 : 0.045), location: 1)
        ])
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
    }

    private func drawTopGlow(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.0)
        let gradient = Gradient(stops: [
            .init(color: Color.white.opacity(isDark ? 0.13 : 0.18), location: 0),
            .init(color: Color.white.opacity(isDark ? 0.050 : 0.070), location: 0.38),
            .init(color: Color.white.opacity(isDark ? 0.016 : 0.024), location: 0.70),
            .init(color: .clear, location: 1)
        ])
        ShelfCanvasSoftLight.radial(in: &context,
                                    center: center,
                                    radiusX: size.width * 0.78,
                                    radiusY: size.height * 0.46,
                                    stops: gradient.stops)
    }

    private func drawParticles(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        for index in 0..<6 {
            let xBase = CGFloat(Self.pseudoRandom(index: index, salt: 1)) * size.width
            let radius = 2.0 + CGFloat(Self.pseudoRandom(index: index, salt: 2)) * 4.0
            let duration = 9.0 + Self.pseudoRandom(index: index, salt: 3) * 9.0
            let delay = Self.pseudoRandom(index: index, salt: 4) * 8.0
            let sway = CGFloat(Self.pseudoRandom(index: index, salt: 5)) * 26 - 13
            let progress = Self.loopProgress((time + delay) / duration)
            let eased = 1 - pow(1 - progress, 1.6)
            let soft = radius + 2.5
            let x = xBase + sway * sin(progress * 2 * .pi)
            let y = size.height + 12 - eased * (size.height + 22)
            let opacity = 0.7 * pow(1 - progress, 1.25)
            guard opacity > 0.01 else { continue }
            let gradient = Gradient(stops: [
                .init(color: palette.glowPrimary.color.opacity(0.55 * opacity), location: 0),
                .init(color: palette.glowPrimary.color.opacity(0.55 * opacity), location: 0.5),
                .init(color: palette.glowPrimary.color.opacity(0), location: 1)
            ])
            ShelfCanvasSoftLight.radial(in: &context,
                                        center: CGPoint(x: x, y: y),
                                        radiusX: soft,
                                        radiusY: soft,
                                        stops: gradient.stops)
        }
    }

    private func drawVignette(in context: inout GraphicsContext, size: CGSize) {
        let d = max(size.width, size.height)
        let rect = CGRect(x: size.width / 2 - d * 0.72, y: size.height / 2 - d * 0.72,
                          width: d * 1.44, height: d * 1.44)
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0.39),
            .init(color: Color.black.opacity(isDark ? 0.30 : 0.16), location: 1)
        ])
        context.fill(Path(ellipseIn: rect),
                     with: .radialGradient(gradient, center: CGPoint(x: size.width / 2, y: size.height / 2),
                                           startRadius: d * 0.28, endRadius: d * 0.72))
    }

    private func drawDither(in context: inout GraphicsContext, size: CGSize) {
        var dither = context
        dither.blendMode = .overlay
        dither.opacity = isDark ? 0.05 : 0.04
        let tile: CGFloat = 128
        let columns = Int(ceil(size.width / tile))
        let rows = Int(ceil(size.height / tile))
        for y in 0...rows {
            for x in 0...columns {
                let rect = CGRect(x: CGFloat(x) * tile, y: CGFloat(y) * tile, width: tile, height: tile)
                dither.draw(Image(nsImage: ShelfNoiseTexture.shared.image), in: rect)
            }
        }
    }

    private static func pseudoRandom(index: Int, salt: Int) -> Double {
        let value = sin(Double(index * 928371 + salt * 1299709)) * 43758.5453
        return value - floor(value)
    }

    private static func loopProgress(_ value: Double) -> Double {
        value - floor(value)
    }
}

/// 一次性生成的细噪点纹理，平铺到底板上做 dither，抹平渐变色带。生成一次后缓存复用。
private final class ShelfNoiseTexture {
    static let shared = ShelfNoiseTexture()
    let image: NSImage

    private init() {
        let size = 128
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32
        )!
        if let data = rep.bitmapData {
            var rng = SystemRandomNumberGenerator()
            for i in 0..<(size * size) {
                let v = UInt8.random(in: 0...255, using: &rng)
                let o = i * 4
                data[o] = v; data[o + 1] = v; data[o + 2] = v; data[o + 3] = 255
            }
        }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        self.image = img
    }
}

// MARK: - 唱片架

private struct ShelfRackView: View {
    let tracks: [MediaItem]
    let currentIndex: Int
    let palette: AlbumColorPalette
    let isPlaying: Bool
    let coverGlowEnabled: Bool
    let reduceMotion: Bool
    let fixedPlateSize: CGFloat?
    let fixedBaselineY: CGFloat?
    let onToggleCenter: () -> Void
    let onSelect: (MediaItem) -> Void
    let onPullDownLoop: () -> Void
    let onShuffle: () -> Void
    let onGatherChange: (Bool) -> Void
    let onBrowseChange: (Bool) -> Void

    private enum Phase { case idle, primed, floating }

    private static let rackSpace = "shelfRack"

    @State private var hoveredIndex: Int?
    @State private var lastHoverSampleTime: TimeInterval = 0
    @State private var lastHoverLocation: CGPoint?
    /// 当前唱片被向下拉的位移（橡皮筋）；松手回弹到 0。
    @State private var centerDragY: CGFloat = 0
    @State private var phase: Phase = Self.initialPhase

    /// 默认 idle；仅 DEBUG 下 `--shelf-preview-gathered` 起拾起态(卡片长龙)、`--shelf-preview-primed` 起待拾起态，便于截图核对。
    private static var initialPhase: Phase {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--shelf-preview-gathered") { return .floating }
        if args.contains("--shelf-preview-primed") { return .primed }
        return .idle
        #else
        return .idle
        #endif
    }
    @State private var isPressing = false
    @State private var pulling = false               // 本次按压已判定为「下拉」
    @State private var longPressTask: Task<Void, Never>?
    @State private var shake = ShelfShakeDetector()
    /// 拖动态下鼠标在书架坐标系里的位置（卡片长龙的领头落点）。
    @State private var cursorRackPos: CGPoint = .zero
    /// 拖动方向单位向量（平滑）。卡片长龙拖尾在**运动反方向**（往左拖→尾巴甩在右边，符合物理）。
    @State private var dragUnit: CGVector = CGVector(dx: -0.82, dy: -0.34)
    /// 浏览平移量（卡片单位）：负=看历史(左)、正=看待播(右)、0=当前曲居中。空闲后回弹到 0。
    @State private var browseOffset: CGFloat = Self.initialBrowseOffset
    @State private var browseReturnTask: Task<Void, Never>?
    /// 在湖面激起的涟漪计数（每自增一次播放一道涟漪）+ 本次涟漪力度（0…1，随下拉深度而定）。
    @State private var rippleTrigger = 0
    @State private var rippleStrength: CGFloat = 0.4
    /// 正在播放的唱片在湖面上的轻柔呼吸浮动（正弦上下，repeatForever）。
    @State private var heroFloatUp = false

    /// 仅 DEBUG：`--shelf-preview-browse` 直接起一个浏览平移，便于截图核对历史平移布局。
    private static var initialBrowseOffset: CGFloat {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--shelf-preview-browse") ? -1.6 : 0
        #else
        return 0
        #endif
    }

    private var browsing: Bool { abs(browseOffset) > 0.5 }
    private var engaged: Bool { phase == .primed || phase == .floating }

    var body: some View {
        GeometryReader { geometry in
            let plateSize = fixedPlateSize ?? plateSide(for: geometry.size)
            let centerX = geometry.size.width / 2
            // 唱片竖直中心：按书架区高度偏下放置，并按 hero 顶部/唱片底部边界钳制，避免贴顶或压住标题。
            let baselineY = fixedBaselineY ?? rackBaselineY(for: geometry.size, plateSize: plateSize)
            // 按窗口宽度自适应渲染数量：让长书架仍铺满边缘，但窄/中等窗口不挂屏外卡。
            let side = sideLimit(for: geometry.size.width, plateSize: plateSize)

            ZStack(alignment: .topLeading) {
                // 先用与窗口同尺寸的透明布局底板固定 ZStack 坐标系。
                // 下面的唱片、涟漪和调试标记大量使用绝对 `.position(x:y:)`；
                // 若没有这块底板，ZStack 会按这些子视图的固有尺寸先求自身大小，
                // 外层再 `.frame` 时会把整组内容居中搬移，声明的 baselineY 就不再是窗口坐标。
                Color.clear
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)

                // 顶部柔光、体积光、湖面波光、焦散线和月光竖反光合并为单个 Canvas：
                // 视觉层次仍在唱片后方，但避免 5 个常驻大面积 blend/blur SwiftUI 层持续参与合成。
                ShelfWaterLightField(rackSize: geometry.size,
                                     centerX: centerX,
                                     baselineY: baselineY,
                                     plateSize: plateSize,
                                     tint: palette.glowPrimary.color,
                                     reduceMotion: reduceMotion,
                                     isPlaying: isPlaying)
                    // 光场需要向书架下方溢出，但它的超高绘制画布不能参与 ZStack 的布局尺寸；
                    // 否则 ZStack 会先按光场高度居中，再被外层固定 frame 裁回窗口高，
                    // 所有使用绝对 `.position(y:)` 的唱片都会被整体向上平移。
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)

                ForEach(visibleIndices(side: side, plateSize: plateSize, rackWidth: geometry.size.width, centerX: centerX), id: \.self) { index in
                    plate(
                        index: index,
                        plateSize: plateSize,
                        rackWidth: geometry.size.width,
                        centerX: centerX,
                        baselineY: baselineY
                    )
                }

                // 湖面涟漪（点击/下拉激起，扩散大小随力度而定）。
                // 不再 .zIndex(1800)：默认 z=0（在水光之上、但在所有唱片 z≥986 之下）→ 实色封面自然遮挡涟漪，
                // 涟漪只在唱片之间/底部露出的"水面"上可见（需求②：不画在封面之上）。
                ShelfRipple(trigger: rippleTrigger,
                            strength: rippleStrength,
                            center: CGPoint(x: centerX, y: baselineY + plateSize * 0.5),
                            baseWidth: plateSize,
                            tint: palette.glowPrimary.color,
                            reduceMotion: reduceMotion)

                // 悬停名称标签：在被掠过的唱片下方显示曲名（需求②）。
                if let hi = hoveredIndex, phase == .idle, !browsing, tracks.indices.contains(hi) {
                    hoverNameLabel(index: hi, plateSize: plateSize, rackWidth: geometry.size.width,
                                   centerX: centerX, baselineY: baselineY)
                        .zIndex(4000)
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: Self.rackSpace)
            .background(ShelfScrollMonitor(onScroll: handleScroll).allowsHitTesting(false))
            // 鼠标 x 映射悬停：把光标横坐标映射到最近的唱片，使在整排封面上滑动都能逐张抽出+显示名称
            // （取代逐卡 onHover——重叠遮挡下只有最外露的那张可命中，导致"仅下一首响应"）。
            .onContinuousHover(coordinateSpace: .local) { hoverPhase in
                guard phase == .idle, !browsing else {
                    if hoveredIndex != nil { withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.hover) { hoveredIndex = nil } }
                    lastHoverLocation = nil
                    return
                }
                switch hoverPhase {
                case .active(let loc):
                    guard shouldSampleHover(at: loc) else { return }
                    let idx = hoverIndex(at: loc, plateSize: plateSize, centerX: centerX, baselineY: baselineY,
                                         rackWidth: geometry.size.width, side: side)
                    if idx != hoveredIndex { withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.hover) { hoveredIndex = idx } }
                case .ended:
                    if hoveredIndex != nil { withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.hover) { hoveredIndex = nil } }
                    lastHoverLocation = nil
                }
            }
            .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.layout, value: currentIndex)
            .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.layout, value: tracks.count)
            .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.gather, value: phase)
            .onChange(of: currentIndex) { _ in
                // 切歌后回到「当前曲居中」，并取消待回弹任务。
                browseReturnTask?.cancel()
                browseOffset = 0
            }
            // 连点播放/暂停时，若某次手势的 onEnded 被新点击抢断（isPressing 卡在 true），hero 会卡在 0.965 按压缩放、
            // 看似"放大缩小不响应"。每次播放态翻转都强制清掉按压态，确保 hero 缩放恢复随播放态正常响应。
            .onChange(of: isPlaying) { _ in
                if isPressing { isPressing = false }
                if pulling { pulling = false }
                longPressTask?.cancel()
            }
            .onChange(of: browsing) { onBrowseChange($0) }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--shelf-preview-gathered") {
                    cursorRackPos = CGPoint(x: centerX - plateSize * 0.4, y: baselineY - plateSize * 0.2)
                    phase = .floating
                    onGatherChange(true)
                }
                if ProcessInfo.processInfo.arguments.contains("--shelf-preview-hover") {
                    hoveredIndex = currentIndex + 2
                }
                #endif
            }
            // 正在播放唱片的呼吸浮动：仅播放中循环，暂停时缓停（窗口可空闲）。
            .shelfAmbientLoop($heroFloatUp, active: isPlaying && !reduceMotion, activeValue: true, restValue: false,
                              loop: .easeInOut(duration: 3.4).repeatForever(autoreverses: true),
                              settle: .easeInOut(duration: 1.0))
        }
        .onDisappear {
            longPressTask?.cancel()
            browseReturnTask?.cancel()
        }
    }

    @ViewBuilder
    private func plate(index: Int, plateSize: CGFloat, rackWidth: CGFloat, centerX: CGFloat, baselineY: CGFloat) -> some View {
        let diff = index - currentIndex
        let isNowPlaying = diff == 0
        let floating = phase == .floating
        // 当前曲在「未被浏览推开」时承接手势（拾起态也算）。
        let anchorCenter = isNowPlaying && (engaged || !browsing)
        let diffF = CGFloat(diff) - browseOffset
        // 浏览时整架斜放平移（中心也转侧放，需求 3e）；idle 时中心 hero 平放抽出。
        let slot = shelfAngledSlot(
            diffF: diffF,
            plateSize: plateSize,
            rackWidth: rackWidth,
            flattenCenter: !browsing
        )
        let isHovered = hoveredIndex == index
        // 待拾起(primed)：长按已到点、等待晃动/拖动拾起 → 抬得更高 + 放大 + 发光，明确「已拿起，可拖动」。
        let isPrimed = isNowPlaying && phase == .primed && !floating
        // hero = 正在播放那张从书架**抽出来**：平放正对 + 前置（更大/更低/最上/发光）。浏览态不抽出。
        let isHero = slot.isCenter && !floating && !browsing
        // hero 把封面 tiltY 归零（平放正对）。悬停不再平放/抽出，保持原朝向（需求②：仅在原位放大）。
        let baseRotationY = isHero ? 0 : slot.rotationY
        let heroScale = isPlaying ? ShelfDesignSystem.Angle.heroScale : ShelfDesignSystem.Angle.heroPausedScale
        // 悬停预览：仅在原位把该封面放大到自身的 1.15×（不抽出、不平放、不抬高），并提到最前层便于查看。
        let extraScale: CGFloat = floating ? 1.0
            : (isPrimed ? heroScale * 1.04
            : (isHero ? heroScale
            : (isHovered ? 1.15 : 1.0)))
        // 竖直落点：让**所有封面的视觉中心连成一条水平线**（默认）、两侧再轻微上扬，而不是随近大远小往下坠。
        // 缩放锚点在底边(.bottom) → 越小的远卡缩放后中心被压得越低（连起来一条下坠弧）。这里按各卡**总缩放系数**
        // factor 反推落点抵消下坠，把视觉中心拉回 baselineY；再按距离(1−slot.scale)给两侧一点上扬(edgeCenterRise)，
        // 读作"轻轻上扬的翼线"。hero(slot.scale=1)上扬量=0、恒落在中线；primed(拾起)仍在此基础上抬起。
        let plateFactor = slot.scale * extraScale
        let flatCenterY = baselineY
            + plateSize * 0.5 * (plateFactor - 1)
            - ShelfDesignSystem.Angle.edgeCenterRise * plateSize * (1 - slot.scale)
        let restY: CGFloat = isPrimed
            ? flatCenterY - (ShelfDesignSystem.Angle.heroDrop + 34)
            : flatCenterY
        let showsReflection = !floating && (isHero || isHovered || abs(diffF) <= ShelfDesignSystem.Perf.reflectionBand)
        // 电影景深 DoF：聚焦中心，越远越模糊；达到最大后保持，不再归零。
        // 前一轮为了省合成把 cutoff 后的 blur 归零，会造成“中间糊、最远清”的反常景深。
        let dofBlur: CGFloat = {
            guard !(isHero || isHovered || floating) else { return 0 }
            let distance = abs(diffF)
            let start = ShelfDesignSystem.Perf.dofStart
            guard distance > start else { return 0 }
            let t = min(1, max(0, (distance - start) / max(ShelfDesignSystem.Perf.dofFullDistance - start, 0.001)))
            let eased = t * t * (3 - 2 * t)
            return ShelfDesignSystem.Perf.dofMaxBlur * eased
        }()
        // 性能分级：近景带（含 hero/primed/hover）走全玻璃高光，远处小淡卡走精简卡。
        let liteCard = !(isHero || isPrimed || isHovered || abs(diffF) <= ShelfDesignSystem.Perf.premiumDetailBand)
        // 投影只留近景带：远卡阴影在低透明度下不可见，省 ~大半离屏阴影层。
        let castsShadow = isHero || isPrimed || isHovered || abs(diffF) <= ShelfDesignSystem.Perf.shadowBand
        // 卡片长龙：领头=当前曲(rank0)，其余按队列就近交替排在身后，靠后弹簧越慢→拖尾。
        let rank = dragonRank(diff: diff)
        let effectiveCursor = cursorRackPos == .zero ? CGPoint(x: centerX, y: baselineY) : cursorRackPos
        // 拖尾在**运动反方向**（dragUnit 是运动方向）：往左拖 → 尾巴甩到右边（物理正确）。
        let chain = ShelfDesignSystem.Dragon.chainSpacing
        let floatPos = CGPoint(
            x: effectiveCursor.x - dragUnit.dx * CGFloat(rank) * chain,
            y: effectiveCursor.y - dragUnit.dy * CGFloat(rank) * chain
        )
        let restPos = CGPoint(x: centerX + slot.xOffset, y: restY)

        // 顶部光源命中度：中心≈1，越远（|diffF|）越小，下限 rimFloor。hover/hero 的卡视为最受光。
        let centeredLight = max(ShelfDesignSystem.Light.rimFloor,
                                1 - Double(abs(diffF)) * ShelfDesignSystem.Light.rimFalloff)
        let topLight = (isHero || isHovered) ? max(centeredLight, ShelfDesignSystem.Light.rimCenter) : centeredLight
        // sheen 锚点朝向光心：右侧卡受光自左上(.topLeading)，左侧卡自右上(.topTrailing)，中心自正上。
        let lightAnchor: UnitPoint = (isHero || abs(diffF) < 0.35) ? .top : (diffF > 0 ? .topLeading : .topTrailing)

        let styled = ShelfCoverPlate(
            item: tracks[index],
            plateSize: plateSize,
            palette: palette,
            slot: slot,
            tiltY: floating ? 0 : baseRotationY,
            isHero: isHero || isPrimed,
            isNowPlaying: isNowPlaying,
            isPlaying: isPlaying,
            coverGlowEnabled: coverGlowEnabled,
            showsReflection: showsReflection,
            topLight: topLight,
            lightAnchor: lightAnchor,
            glowPulse: (isNowPlaying && isPlaying && !reduceMotion) ? (heroFloatUp ? 1.0 : 0.74) : 1.0,
            lite: liteCard,
            castsShadow: castsShadow,
            reduceMotion: reduceMotion
        )
        // 所有尺寸变化都以湖面接触边为锚点：播放/暂停只改变 hero 向上的高度，
        // 不再让底边、倒影起点和整架视觉基线跟着漂移。
        .scaleEffect(slot.scale * extraScale, anchor: .bottom)
        // 封面卡的 Y 透视由内部绘制；这里只在拖动态加 Z 微倾。
        .rotationEffect(.degrees(floating ? dragonTilt(rank: rank) : 0))
        // 远处轻微压暗加纵深（不改尺寸）；被悬停抽出的那张回满亮度。
        .brightness(floating || isHovered ? 0 : (slot.brightness - 1.0))
        .blur(radius: dofBlur)   // 电影景深：远卡失焦
        // 待拾起发光：抬离书架后一圈专辑色光晕，提示「已拿起，晃动/拖动即可」。
        .shadow(color: isPrimed ? palette.glowPrimary.color.opacity(0.6) : .clear, radius: isPrimed ? 30 : 0)
        // 悬停抽出的封面回满不透明度，避免远处淡出影响预览。
        .opacity(isHovered ? 1.0 : slot.opacity)
        .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.playingPop, value: isHero)
        // 播放/暂停时 hero 的 scale(1.26↔1.18)与发光随之**利落**过渡（snappy，消除迟钝感）。
        .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.playPause, value: isPlaying)
        .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.hover, value: isHovered)
        .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.gather, value: isPrimed)

        // 点按触感：手指压在中心唱片上、尚未转为下拉/拾起时，轻轻下沉一档，松手回弹（每次点击都有反馈）。
        let pressedCenter = anchorCenter && isPressing && phase == .idle && !pulling
        // 正在播放的 hero 在湖面轻柔上下浮动（呼吸感；播放时幅度更明显，暂停收敛）。
        let heroFloat: CGFloat = (isHero && isPlaying && !reduceMotion) ? (heroFloatUp ? -5.5 : 5.5) : 0
        if anchorCenter {
            styled
                .scaleEffect(pressedCenter && !reduceMotion ? 0.965 : 1.0, anchor: .bottom)
                .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlPress, value: pressedCenter)
                .offset(y: (floating ? 0 : centerDragY) + heroFloat)
                // 播放/暂停时浮动幅度变化利落过渡（snappy，消除迟钝感）。
                .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.playPause, value: isPlaying)
                .zIndex(3000)
                .position(floating ? floatPos : restPos)
                .gesture(centerGesture())
                .animation(reduceMotion ? nil : dragonSpring(rank: rank), value: cursorRackPos)
                .accessibilityLabel(Text("正在播放 \(tracks[index].title)，点击暂停或继续，向下拉切换单曲循环，长按后晃动鼠标可拖动唱片"))
                .accessibilityAddTraits(.isButton)
        } else {
            styled
                // 层级：拖动态按 rank；hover 最前；正在播放仅在**非浏览**时上提（浏览时必须回归
                // 纯扇形顺序 slot.zIndex，否则正在播放的唱片会错误地压在/钻到邻居下方——修复左右滑动层级 bug）。
                .zIndex(floating ? 2800 - Double(rank) : (isHovered ? 2500 : ((isNowPlaying && !browsing) ? 2000 : slot.zIndex)))
                .position(floating ? floatPos : restPos)
                .allowsHitTesting(phase == .idle)
                .animation(reduceMotion ? nil : dragonSpring(rank: rank), value: cursorRackPos)
                .onTapGesture { if phase == .idle { emitRipple(strength: 0.45); onSelect(tracks[index]) } }
                .accessibilityLabel(Text(isNowPlaying ? "正在播放 \(tracks[index].title)" : "播放 \(tracks[index].title)"))
                .accessibilityAddTraits(.isButton)
        }
    }

    /// 卡片长龙的单列序号：当前曲领头(0)，随后交替排上待播(1,3,5…)与历史(2,4,6…)。
    private func dragonRank(diff: Int) -> Int {
        if diff == 0 { return 0 }
        return diff > 0 ? diff * 2 - 1 : -diff * 2
    }

    private func dragonTilt(rank: Int) -> Double {
        min(Double(rank) * ShelfDesignSystem.Dragon.tiltPerRank, ShelfDesignSystem.Dragon.tiltMax)
    }

    private func dragonSpring(rank: Int) -> Animation {
        .spring(
            response: ShelfDesignSystem.Dragon.springBase + Double(rank) * ShelfDesignSystem.Dragon.springPerRank,
            dampingFraction: ShelfDesignSystem.Dragon.damping
        )
    }

    /// 滚轮/触控板浏览：平移时间轴（负=历史/正=待播），空闲后回弹到当前曲。
    private func handleScroll(_ delta: CGFloat) {
        guard phase == .idle, !isPressing else { return }
        let lowerBound = -(CGFloat(currentIndex) + ShelfDesignSystem.Browse.overscroll)
        let upperBound = CGFloat(max(0, tracks.count - 1 - currentIndex)) + ShelfDesignSystem.Browse.overscroll
        browseOffset = min(max(browseOffset + delta, lowerBound), upperBound)
        scheduleBrowseReturn()
    }

    private func scheduleBrowseReturn() {
        browseReturnTask?.cancel()
        browseReturnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ShelfDesignSystem.Browse.returnDelay)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : ShelfDesignSystem.Motion.gather) {
                browseOffset = 0
            }
        }
    }

    /// 当前唱片统一手势：
    /// · 点击（位移极小）= 播放/暂停。
    /// · 早期明确下拉 = 下拉态，松手超阈值切换单曲循环。
    /// · 按住到 longPress = 待拾起(primed)；再晃动 = 拾起跟随鼠标(floating)的卡片长龙；松手 = 随机重排并散开。
    private func centerGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rackSpace))
            .onChanged { value in
                if !isPressing { beginPress() }
                let t = value.translation
                switch phase {
                case .floating:
                    // 更新拖动方向（平滑）：拖尾甩在运动反方向。
                    let dx = value.location.x - cursorRackPos.x
                    let dy = value.location.y - cursorRackPos.y
                    let len = hypot(dx, dy)
                    if len > 0.6 {
                        let k = ShelfDesignSystem.Dragon.dirSmoothing
                        var nx = dragUnit.dx * (1 - k) + (dx / len) * k
                        var ny = dragUnit.dy * (1 - k) + (dy / len) * k
                        let nl = hypot(nx, ny)
                        if nl > 0.0001 { nx /= nl; ny /= nl }
                        dragUnit = CGVector(dx: nx, dy: ny)
                    }
                    cursorRackPos = value.location
                case .primed:
                    let now = Date().timeIntervalSinceReferenceDate
                    shake.push(x: value.location.x, y: value.location.y, at: now)
                    // 晃动命中 或 已明确拖动（兜底）→ 拾起，唱片开始跟随鼠标（卡片长龙）。
                    let moved = hypot(t.width, t.height)
                    if shake.isShaking() || moved > ShelfDesignSystem.Gather.pickupMove {
                        cursorRackPos = value.location
                        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : ShelfDesignSystem.Motion.gather) {
                            phase = .floating
                        }
                    }
                case .idle:
                    if pulling || (t.height > ShelfDesignSystem.Gather.pullCommitDown && t.height > abs(t.width) * 1.1) {
                        pulling = true
                        longPressTask?.cancel()
                        centerDragY = rubberBand(t.height)
                    }
                }
            }
            .onEnded { value in
                longPressTask?.cancel()
                let distance = hypot(value.translation.width, value.translation.height)
                switch phase {
                case .floating:
                    // 松手：随机重排队列 + 卡片长龙散开归位。
                    onShuffle()
                    settle()
                case .primed:
                    // 长按了但没晃动 → 取消拾起。
                    settle()
                case .idle:
                    if pulling {
                        // 向下拉松手 → 唱片回落湖面，激起按下拉深度（力度）而定的涟漪（需求⑤）。
                        emitRipple(strength: min(1, max(0.25, centerDragY / ShelfDesignSystem.Pull.maxOffset)))
                        if value.translation.height > ShelfDesignSystem.Pull.threshold { onPullDownLoop() }
                    } else if distance < ShelfDesignSystem.Pull.tapSlop {
                        emitRipple(strength: 0.4)
                        onToggleCenter()
                    }
                }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : ShelfDesignSystem.Motion.pullBack) { centerDragY = 0 }
                isPressing = false
                pulling = false
            }
    }

    private func settle() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : ShelfDesignSystem.Motion.gather) { phase = .idle }
        cursorRackPos = .zero
        onGatherChange(false)
    }

    /// 激起一道涟漪：先设力度再自增触发，让 ShelfRipple 按力度决定扩散大小/亮度。
    private func emitRipple(strength: CGFloat) {
        rippleStrength = strength
        rippleTrigger += 1
    }

    /// 精确命中：仅当光标真正落在某张封面的**显示矩形**内才返回该卡（重叠时取最前=离中心最近的一张）。
    /// 取代旧的"光标 x 距卡心 < 1.4×plateSize"宽松判定（鼠标尚未接触封面就触发）。命中 hero → 返回 nil（其自身手势处理）。
    private func hoverIndex(at loc: CGPoint, plateSize: CGFloat, centerX: CGFloat, baselineY: CGFloat, rackWidth: CGFloat, side: Int) -> Int? {
        // 由近及远（前→后）遍历：第一张其显示矩形包含光标的卡 = 当前可见、未被遮挡的那张。
        let ordered = visibleIndices(side: side, plateSize: plateSize, rackWidth: rackWidth, centerX: centerX)
            .sorted { abs($0 - currentIndex) < abs($1 - currentIndex) }
        for index in ordered {
            let isHeroCard = index == currentIndex
            let slot = shelfAngledSlot(diffF: CGFloat(index - currentIndex), plateSize: plateSize, rackWidth: rackWidth, flattenCenter: true)
            let extra: CGFloat = isHeroCard ? (isPlaying ? ShelfDesignSystem.Angle.heroScale : ShelfDesignSystem.Angle.heroPausedScale) : 1.0
            let h = plateSize * slot.scale * extra
            // 斜放卡投影宽度按 cos 收窄，使命中区贴合真实可见封面。
            let w = h * CGFloat(abs(cos(slot.rotationY * .pi / 180)))
            let cx = centerX + slot.xOffset
            // 命中区跟随渲染的「水平中心线 + 两侧轻微上扬」：每卡视觉中心 = baselineY − rise×(1−scale)
            // （与 plate() 的 flatCenterY 同源，factor 项在底边锚点缩放后正好抵消，故与 hover/播放放大无关）。
            let cy = baselineY - ShelfDesignSystem.Angle.edgeCenterRise * plateSize * (1 - slot.scale)
            let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            if rect.contains(loc) {
                return isHeroCard ? nil : index
            }
        }
        return nil
    }

    /// 被悬停唱片下方的曲名标签（玻璃胶囊），随抽出的封面定位。
    @ViewBuilder
    private func hoverNameLabel(index: Int, plateSize: CGFloat, rackWidth: CGFloat, centerX: CGFloat, baselineY: CGFloat) -> some View {
        let slot = shelfAngledSlot(diffF: CGFloat(index - currentIndex), plateSize: plateSize, rackWidth: rackWidth, flattenCenter: true)
        let labelX = max(110, min(rackWidth - 110, centerX + slot.xOffset))
        // 悬停只放大 1.15×、不抬高：标签落在该封面下方（按其实际缩放高度定位）。
        let labelY = baselineY + plateSize * slot.scale * 0.5 * 1.15 + 16
        // 仅亮白文字、只显示标题、无底框（需求②）。
        Text(tracks[index].title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
            .fixedSize()
            .position(x: labelX, y: labelY)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    /// 按压开始：复位状态并起长按计时；计时到点且仍按住、未下拉、仍 idle 则进入「待拾起」。
    private func beginPress() {
        isPressing = true
        pulling = false
        shake.reset()
        longPressTask?.cancel()
        longPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ShelfDesignSystem.Gather.longPress * 1_000_000_000))
            guard !Task.isCancelled, isPressing, !pulling, phase == .idle else { return }
            phase = .primed
            onGatherChange(true)
        }
    }

    /// 橡皮筋阻尼：下拉越深增益越小，逼近 maxOffset。
    private func rubberBand(_ height: CGFloat) -> CGFloat {
        ShelfDesignSystem.Pull.maxOffset * (1 - exp(-height / ShelfDesignSystem.Pull.resistance))
    }

    private func plateSide(for size: CGSize) -> CGFloat {
        let raw = min(size.width * ShelfDesignSystem.Plate.widthFraction, size.height * ShelfDesignSystem.Plate.heightFraction)
        return min(ShelfDesignSystem.Plate.maxSide, max(ShelfDesignSystem.Plate.minSide, raw))
    }

    private func rackBaselineY(for size: CGSize, plateSize: CGFloat) -> CGFloat {
        let heroHalf = plateSize * ShelfDesignSystem.Angle.heroScale * 0.5
        let topLimit = ShelfDesignSystem.Row.topSafeInset + heroHalf        // 唱片顶沿不高于此 → 不贴/裁窗口顶
        let bottomLimit = size.height - heroHalf - ShelfDesignSystem.Row.bottomSafeInset  // 唱片本体底沿不越书架区底
        let target = size.height * ShelfDesignSystem.Row.baselineFraction   // 期望竖直中心（偏下陈列）
        // 唱片本体放得下：在 [topLimit, bottomLimit] 内取 target（偏下，给顶部留充足余量、倒影向下淡出）。
        // 放不下（极矮窗口）：顶沿对齐 topLimit，**绝不裁切到窗口顶部**（倒影/底沿溢出到标题区，影响更小）。
        guard bottomLimit >= topLimit else { return topLimit }
        return min(max(target, topLimit), bottomLimit)
    }

    private func sideLimit(for width: CGFloat, plateSize: CGFloat) -> Int {
        let maxSide = ShelfDesignSystem.Plate.visibleEachSide
        guard width >= 760 else { return min(maxSide, 6) }
        let halfWindowInPlates = max(width / max(plateSize, 1) * 0.5, 1)
        let needed = Int(ceil(halfWindowInPlates * 2.25))
        return min(maxSide, max(9, needed))
    }

    private func shouldSampleHover(at location: CGPoint) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        defer {
            lastHoverSampleTime = now
            lastHoverLocation = location
        }
        guard let previous = lastHoverLocation else { return true }
        let moved = hypot(location.x - previous.x, location.y - previous.y)
        return moved >= ShelfDesignSystem.Perf.hoverMoveThreshold ||
            now - lastHoverSampleTime >= ShelfDesignSystem.Perf.hoverSampleInterval
    }

    /// 轻量虚拟化：只渲染**视口中心**两侧各 side 张（浏览时视口中心随 browseOffset 移动）。
    private func visibleIndices(side: Int) -> [Int] {
        let viewCenter = currentIndex + Int(browseOffset.rounded())
        let lower = max(0, viewCenter - side)
        let upper = min(tracks.count - 1, viewCenter + side)
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }

    /// 在上面的基础上，再按尺寸剔除**完全超出窗口**的封面（其投影矩形与窗口 [0, rackWidth] 不相交）：
    /// 长书架里靠近 spineDecay 渐近线的远卡 x 位移已越出窗口边缘，渲染了也看不到——剔除以省合成开销。
    /// 拖动/拾起态(phase != .idle)卡片跟随鼠标，不能按静止位剔除，故跳过。
    private func visibleIndices(side: Int, plateSize: CGFloat, rackWidth: CGFloat, centerX: CGFloat) -> [Int] {
        let base = visibleIndices(side: side)
        guard phase == .idle else { return base }
        let margin = plateSize * 0.3   // 留少量余量：半露/正滑入的卡仍渲染，仅剔除完全在窗外的
        return base.filter { index in
            let diffF = CGFloat(index - currentIndex) - browseOffset
            let slot = shelfAngledSlot(diffF: diffF, plateSize: plateSize, rackWidth: rackWidth, flattenCenter: !browsing)
            let w = plateSize * slot.scale
            let cx = centerX + slot.xOffset
            return (cx + w / 2) > -margin && (cx - w / 2) < rackWidth + margin
        }
    }
}

// MARK: - 湖面波光 / 涟漪

/// 湖光常驻光场：把顶部柔光、丁达尔光、水面波光、焦散线和中心月光合到一个 Canvas。
/// 这些元素都在唱片后方、都只做慢速 screen 光，因此合并后视觉层级基本不变，但少了多层 SwiftUI blur/blend 状态链。
private struct ShelfWaterLightField: View {
    let rackSize: CGSize
    let centerX: CGFloat
    let baselineY: CGFloat
    let plateSize: CGFloat
    let tint: Color
    let reduceMotion: Bool
    let isPlaying: Bool

    private var animates: Bool { isPlaying && !reduceMotion }

    var body: some View {
        Group {
            if animates {
                TimelineView(.animation(minimumInterval: ShelfDesignSystem.Perf.lightFieldFrameInterval)) { timeline in
                    canvas(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(time: nil)
            }
        }
        .frame(width: rackSize.width, height: rackSize.height + plateSize * 1.15)
        .offset(y: -plateSize * 0.08)
        .blendMode(.screen)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.68),
                    .init(color: .white.opacity(0.48), location: 0.86),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }

    private func canvas(time: TimeInterval?) -> some View {
        Canvas(rendersAsynchronously: true) { context, size in
            var context = context
            context.blendMode = .screen
            drawTopBloom(in: &context)
            drawGodRay(in: &context, time: time)
            drawWaterShimmer(in: &context, size: size, time: time)
            drawCaustics(in: &context, width: size.width, time: time)
            drawMoonlight(in: &context, time: time)
        }
    }

    private func drawTopBloom(in context: inout GraphicsContext) {
        let center = CGPoint(x: centerX, y: baselineY - plateSize * (ShelfDesignSystem.Light.bloomRise + 0.22))
        let gradient = Gradient(stops: [
            .init(color: Color.white.opacity(ShelfDesignSystem.Light.bloomOpacity * 0.34), location: 0.0),
            .init(color: Color.white.opacity(ShelfDesignSystem.Light.bloomOpacity * 0.16), location: 0.34),
            .init(color: Color.white.opacity(ShelfDesignSystem.Light.bloomOpacity * 0.042), location: 0.68),
            .init(color: .clear, location: 1.0)
        ])
        ShelfCanvasSoftLight.radial(in: &context,
                                    center: center,
                                    radiusX: plateSize * ShelfDesignSystem.Light.bloomWidthScale * 2.75,
                                    radiusY: plateSize * ShelfDesignSystem.Light.bloomHeightScale * 1.58,
                                    stops: gradient.stops)
    }

    private func drawGodRay(in context: inout GraphicsContext, time: TimeInterval?) {
        let startY = baselineY - plateSize * (ShelfDesignSystem.Light.bloomRise + 0.52)
        let endY = baselineY + plateSize * 0.72
        let height = max(endY - startY, plateSize)
        let sway = time.map { CGFloat(sin($0 * 2 * .pi / 18.0)) * plateSize * 0.018 } ?? 0

        var rayContext = context
        rayContext.opacity = 0.78

        godRayLine(in: &rayContext,
                   from: CGPoint(x: centerX - plateSize * 0.34 + sway, y: startY),
                   to: CGPoint(x: centerX - plateSize * 0.50 - sway * 0.5, y: endY),
                   height: height,
                   lineWidth: plateSize * 0.34,
                   opacity: 0.038)
        godRayLine(in: &rayContext,
                   from: CGPoint(x: centerX + plateSize * 0.18 - sway, y: startY + plateSize * 0.04),
                   to: CGPoint(x: centerX + plateSize * 0.42 + sway * 0.4, y: endY - plateSize * 0.10),
                   height: height,
                   lineWidth: plateSize * 0.27,
                   opacity: 0.032)
        godRayLine(in: &rayContext,
                   from: CGPoint(x: centerX + sway * 0.35, y: startY + plateSize * 0.02),
                   to: CGPoint(x: centerX + plateSize * 0.06 - sway * 0.2, y: endY - plateSize * 0.16),
                   height: height,
                   lineWidth: plateSize * 0.18,
                   opacity: 0.043)
    }

    private func godRayLine(in context: inout GraphicsContext,
                            from start: CGPoint,
                            to end: CGPoint,
                            height: CGFloat,
                            lineWidth: CGFloat,
                            opacity: Double) {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + (end.x - start.x) * 0.24, y: start.y + height * 0.28),
                      control2: CGPoint(x: start.x + (end.x - start.x) * 0.78, y: start.y + height * 0.62))
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: Color.white.opacity(opacity), location: 0.18),
            .init(color: Color.white.opacity(opacity * 0.56), location: 0.48),
            .init(color: .clear, location: 1.0)
        ])
        context.stroke(path,
                       with: .linearGradient(gradient, startPoint: start, endPoint: end),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func drawWaterShimmer(in context: inout GraphicsContext, size: CGSize, time: TimeInterval?) {
        let width = size.width
        let y = baselineY + plateSize * 0.62
        let phase = time.map { CGFloat(sin($0 * 2 * .pi / 22.0)) * 0.6 } ?? -0.6
        let center = CGPoint(x: width / 2 + phase * width * 0.34, y: y)
        let gradient = Gradient(stops: [
            .init(color: Color.white.opacity(0.056), location: 0.0),
            .init(color: Color.white.opacity(0.028), location: 0.38),
            .init(color: Color.white.opacity(0.008), location: 0.68),
            .init(color: .clear, location: 1.0)
        ])
        ShelfCanvasSoftLight.radial(in: &context,
                                    center: center,
                                    radiusX: width * 0.66,
                                    radiusY: plateSize * 0.78,
                                    stops: gradient.stops)
    }

    private func drawCaustics(in context: inout GraphicsContext, width: CGFloat, time: TimeInterval?) {
        let waterY = baselineY + plateSize * 0.56
        let drift = time.map { CGFloat(sin($0 * 2 * .pi / 32.0)) } ?? -1
        causticLine(in: &context, width: width, y: waterY + plateSize * 0.16, lineWidth: width * 0.5, dir: 1, drift: drift, opacity: 0.10)
        causticLine(in: &context, width: width, y: waterY + plateSize * 0.34, lineWidth: width * 0.4, dir: -1, drift: drift, opacity: 0.075)
    }

    private func causticLine(in context: inout GraphicsContext, width: CGFloat, y: CGFloat,
                             lineWidth: CGFloat, dir: CGFloat, drift: CGFloat, opacity: Double) {
        let x = width / 2 + drift * dir * width * 0.16
        var path = Path()
        path.move(to: CGPoint(x: x - lineWidth / 2, y: y))
        path.addCurve(to: CGPoint(x: x + lineWidth / 2, y: y),
                      control1: CGPoint(x: x - lineWidth * 0.22, y: y - 3.0),
                      control2: CGPoint(x: x + lineWidth * 0.18, y: y + 2.6))
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: Color.white.opacity(opacity), location: 0.5),
            .init(color: .clear, location: 1.0)
        ])
        context.stroke(path,
                       with: .linearGradient(gradient,
                                             startPoint: CGPoint(x: x - lineWidth / 2, y: y),
                                             endPoint: CGPoint(x: x + lineWidth / 2, y: y)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }

    private func drawMoonlight(in context: inout GraphicsContext, time: TimeInterval?) {
        let breath = time.map { (sin($0 * 2 * .pi / 7.2) + 1) * 0.5 } ?? 0
        let width = plateSize * (reduceMotion ? 0.30 : 0.25 + CGFloat(breath) * 0.11)
        let height = plateSize * 1.3
        let opacity = reduceMotion ? 0.5 : 0.52 + breath * 0.33
        let topY = baselineY + plateSize * 0.5
        let center = CGPoint(x: centerX, y: topY + height * 0.42)

        let softGradient = Gradient(stops: [
            .init(color: Color.white.opacity(0.11 * opacity), location: 0.0),
            .init(color: tint.opacity(0.08 * opacity), location: 0.36),
            .init(color: .clear, location: 1.0)
        ])
        ShelfCanvasSoftLight.radial(in: &context,
                                    center: CGPoint(x: center.x, y: topY + height * 0.22),
                                    radiusX: width * 1.7,
                                    radiusY: height * 0.62,
                                    stops: softGradient.stops)

        let gradient = Gradient(stops: [
            .init(color: Color.white.opacity(0.14 * opacity), location: 0.0),
            .init(color: tint.opacity(0.10 * opacity), location: 0.34),
            .init(color: tint.opacity(0.035 * opacity), location: 0.66),
            .init(color: .clear, location: 1.0)
        ])
        ShelfCanvasSoftLight.radial(in: &context,
                                    center: center,
                                    radiusX: width * 0.95,
                                    radiusY: height * 0.56,
                                    stops: gradient.stops)
    }
}

/// 湖面涟漪：点击/下拉激起，扁椭圆水环由小扩大、淡出。扩散大小/亮度/环数随力度 strength(0…1) 而定，
/// 强力下拉产生更大、更亮、带第二圈尾随的涟漪（拟真水波）。
private struct ShelfRipple: View {
    let trigger: Int
    let strength: CGFloat
    let center: CGPoint
    let baseWidth: CGFloat
    let tint: Color
    let reduceMotion: Bool

    @State private var shown = -1
    // 每圈一个 0→1 进度（错峰起跑）：scale 随进度扩张、opacity 随进度淡出 → 连续向外荡开的真实水环。
    @State private var p1: CGFloat = 1
    @State private var p2: CGFloat = 1
    @State private var p3: CGFloat = 1
    @State private var splashP: CGFloat = 1
    @State private var firedStrength: CGFloat = 0.4

    private var maxScale: CGFloat { 1.5 + firedStrength * 2.6 }
    // 扁椭圆（水面透视）。基准宽度随力度略增。
    private var ringW: CGFloat { baseWidth * (0.66 + firedStrength * 0.55) }
    // 关键：用 frame 放大、stroke 宽度恒定 → 水环越荡越细，而非 scaleEffect 把环越拉越粗（更拟真）。
    private var lineWidth: CGFloat { 1.1 + firedStrength * 1.3 }

    var body: some View {
        ZStack {
            splash(p: splashP)
            ring(p: p3, peak: 0.20 + Double(firedStrength) * 0.18)   // 外圈：最迟、最淡
            ring(p: p2, peak: 0.32 + Double(firedStrength) * 0.26)   // 中圈
            ring(p: p1, peak: 0.50 + Double(firedStrength) * 0.34)   // 内圈：最先、最亮
        }
        .position(center)
        .allowsHitTesting(false)
        .onChange(of: trigger) { newValue in
            guard !reduceMotion, newValue != shown, newValue > 0 else { return }
            shown = newValue
            firedStrength = strength
            // 力度越大 → 荡得越远、越久。
            let dur = 0.95 + Double(strength) * 0.85
            p1 = 0; p2 = 0; p3 = 0; splashP = 0
            withAnimation(.easeOut(duration: dur)) { p1 = 1 }
            withAnimation(.easeOut(duration: dur).delay(0.14)) { p2 = 1 }
            withAnimation(.easeOut(duration: dur).delay(0.28)) { p3 = 1 }
            withAnimation(.easeOut(duration: 0.42)) { splashP = 1 }   // 入水点高光快速散开
        }
    }

    /// 单圈水环：恒定细描边 + 随进度扩张/淡出，screen 叠在暗色水面上发亮。
    private func ring(p: CGFloat, peak: Double) -> some View {
        let scale = 0.3 + p * (maxScale - 0.3)
        let w = ringW * scale
        return Ellipse()
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(0.85), tint.opacity(0.5), .white.opacity(0.22)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: lineWidth
            )
            .frame(width: w, height: max(0.5, w * 0.22))
            .opacity(peak * Double(1 - p))
            .blendMode(.screen)
    }

    /// 入水点：一抹扁椭圆柔光快速亮起即散（"噗"的一下）。
    private func splash(p: CGFloat) -> some View {
        let w = baseWidth * 0.6 * (0.4 + p * 0.95)
        return Ellipse()
            .fill(RadialGradient(colors: [.white.opacity(0.5), tint.opacity(0.2), .clear],
                                 center: .center, startRadius: 0, endRadius: baseWidth * 0.3))
            .frame(width: w, height: max(0.5, w * 0.22))
            .opacity((0.45 + Double(firedStrength) * 0.35) * Double(1 - p))
            .blendMode(.screen)
    }
}

// MARK: - 单张唱片 = 效果图式薄玻璃封面卡

private extension View {
    /// 按需套 compositingGroup（精简卡不套，省离屏目标）。
    @ViewBuilder
    func shelfCompositingGroup(_ active: Bool) -> some View {
        if active { self.compositingGroup() } else { self }
    }
}

private struct ShelfCoverPlate: View {
    let item: MediaItem
    let plateSize: CGFloat
    let palette: AlbumColorPalette
    let slot: ShelfSlot
    /// 封面卡实际施加的 Y 斜角（已含 hover/hero 归零）。仅用于薄卡透视，不再画棱柱厚度。
    let tiltY: Double
    /// 是否是被抽出的 hero（更强的发光/接触阴影）。
    let isHero: Bool
    let isNowPlaying: Bool
    let isPlaying: Bool
    let coverGlowEnabled: Bool
    let showsReflection: Bool
    /// 顶部光源命中强度（0…1）：中心≈1、越靠两侧越小。驱动顶沿高光描边与 sheen。
    let topLight: Double
    /// sheen 受光锚点（朝向光心）：中心 .top、右侧卡 .topLeading、左侧卡 .topTrailing。
    let lightAnchor: UnitPoint
    /// 正在播放唱片边缘自发光的呼吸系数（与 hero 浮动同相，0.7…1）。其它卡恒 1。
    var glowPulse: Double = 1.0
    /// 性能分级：远处又小又淡的卡走精简卡（仅封面+一层普通柔光+细描边，无 .screen / 无 compositingGroup）。
    var lite: Bool = false
    /// 是否投影（仅近景带）。远卡阴影在低透明度下不可见，关掉省离屏阴影层。
    var castsShadow: Bool = true
    let reduceMotion: Bool

    private var radius: CGFloat { ShelfDesignSystem.Card.cornerRadius }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    private var coverCacheTargetSize: CGSize {
        let side = lite ? ShelfDesignSystem.Perf.liteCoverCacheSide : ShelfDesignSystem.Perf.fullCoverCacheSide
        return CGSize(width: side, height: side)
    }
    /// sheen 渐变的对角终点：受光锚点的对侧（背光面）。
    private var oppositeAnchor: UnitPoint {
        switch lightAnchor {
        case .topLeading: return .bottomTrailing
        case .topTrailing: return .bottomLeading
        default: return .bottom
        }
    }

    var body: some View {
        ZStack {
            // 湖面倒影：水面镜像（顶部最亮、向下淡出），不随前面板旋转。只画近中心。
            if showsReflection {
                reflection
                    .frame(width: plateSize, height: plateSize * ShelfDesignSystem.Plate.reflectionFraction)
                    .offset(y: plateSize * 0.5
                        + plateSize * ShelfDesignSystem.Plate.reflectionFraction * 0.5 + ShelfDesignSystem.Plate.reflectionGap)
                    .allowsHitTesting(false)

                // 入水接触线：唱片底沿与湖面相接处的一道柔光，强化「立于湖面」的水光感（湖光主题）。
                Capsule()
                    .fill(LinearGradient(
                        colors: [.clear, .white.opacity(0.55 * topLight), .clear],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: plateSize * 0.94, height: 2.2)
                    .blur(radius: 1.6)
                    .offset(y: plateSize * 0.5 + ShelfDesignSystem.Plate.reflectionGap * 0.4)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }

            glassCard
        }
        .frame(width: plateSize, height: plateSize)
        .contentShape(shape)
        // 接触阴影：柔和、偏下（y≈radius）= 唱片"坐"在地面上，而非旧版两侧的硬黑光晕团。
        // 仅近景带投影（castsShadow）：远卡阴影在低透明度下不可见 → color:.clear+radius:0 不建离屏阴影层。
        .shadow(color: castsShadow ? .black.opacity(isHero ? 0.26 : 0.13) : .clear,
                radius: castsShadow ? (isHero ? 20 : 8) : 0, x: 0, y: castsShadow ? (isHero ? 15 : 7) : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isPlaying)
    }

    /// 薄玻璃封面卡：封面铺满 + 柔光棱线 + 顶部镜面反光；严格不再绘制棱柱侧/底/背面。
    private var glassCard: some View {
        ZStack {
            PosterImage(
                path: item.posterPath,
                title: item.title,
                mediaType: item.type,
                cacheTargetSize: coverCacheTargetSize
            )
            .frame(width: plateSize, height: plateSize)
            .clipShape(shape)

            if lite {
                // 精简卡（远处小淡卡）：仅一层**普通混合**顶光，不用 .screen / 不建 compositingGroup。
                // 该距离上全玻璃的方向 sheen / 镜面热点 / 虹彩描边等细节本就不可辨，省 6 个混合层。
                shape.fill(LinearGradient(colors: [.white.opacity(0.16 * topLight), .clear], startPoint: .top, endPoint: .center))
            } else {
            // ① 顶部柔光：自上而下的镜面反光，强度随顶部光源命中度（中心强、两侧弱）。
            shape.fill(LinearGradient(colors: [.white.opacity(0.22 * topLight), .clear], startPoint: .top, endPoint: .center))
                .blendMode(.screen)

            // ② 方向性 sheen：受光侧（朝向光心）更亮，背光侧暗。锚点 lightAnchor 让左右卡的高光朝中心倾。
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity(ShelfDesignSystem.Card.sheenOpacity * topLight), .clear, .white.opacity(0.06 * topLight)],
                    startPoint: lightAnchor,
                    endPoint: oppositeAnchor
                )
            )
            .blendMode(.screen)

            // ②b 镜面热点：玻璃顶部一小块更亮的高光斑，随光位偏向受光侧 → 高级"玻璃在反光"质感。
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(0.5 * topLight), .white.opacity(0.12 * topLight), .clear],
                                     center: .center, startRadius: 0, endRadius: plateSize * 0.24))
                .frame(width: plateSize * 0.52, height: plateSize * 0.28)
                .offset(x: lightAnchor == .topLeading ? -plateSize * 0.17 : (lightAnchor == .topTrailing ? plateSize * 0.17 : 0),
                        y: -plateSize * 0.3)
                .blur(radius: plateSize * 0.02)
                .blendMode(.screen)

            // ③ 玻璃边缘受光描边（整圈），含一点专辑色，hero 更亮。
            shape.fill(
                LinearGradient(
                    colors: [
                        .white.opacity((isHero ? 0.62 : 0.38) * topLight),
                        palette.glowPrimary.color.opacity((isHero ? 0.20 : 0.10) * topLight),
                        .white.opacity((isHero ? 0.20 : 0.10) * topLight)
                    ],
                    startPoint: lightAnchor,
                    endPoint: oppositeAnchor
                )
            )
            .mask(shape.strokeBorder(lineWidth: isHero ? ShelfDesignSystem.Card.heroEdgeLineWidth : ShelfDesignSystem.Card.edgeLineWidth))
            .blendMode(.screen)

            // ④ 顶沿高光描边（任务③核心）：顶部一道亮白棱线向两肩淡出，强度 = topLight。
            //    中心封面 = 清晰明亮的顶沿高光；越靠两侧越淡，模拟光从正上方照下的物理效果。
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(topLight), .white.opacity(topLight * 0.34), .clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: isHero ? 1.6 : 1.2
                )
                .blendMode(.screen)
                .blur(radius: 0.4)

            // ④b 边缘虹彩色散：极淡全息描边，玻璃边缘分光（premium iridescent）。
            shape
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(hue: 0.52, saturation: 0.7, brightness: 1),
                            Color(hue: 0.78, saturation: 0.7, brightness: 1),
                            Color(hue: 0.95, saturation: 0.7, brightness: 1),
                            Color(hue: 0.13, saturation: 0.7, brightness: 1),
                            Color(hue: 0.52, saturation: 0.7, brightness: 1)
                        ].map { $0.opacity((isHero ? 0.22 : 0.13) * topLight) },
                        center: .center
                    ),
                    lineWidth: isHero ? 1.4 : 1.0
                )
                .blendMode(.screen)
            }

            // ⑤ 正在播放：封面**内边缘自发光**——取封面自身画面在四边一圈提亮+加饱和后叠加(plusLighter)，
            //    使边缘的"自身颜色"变亮而发光，且严格 mask 在内边缘环、不向外溢出一圈光晕（需求④）。
            if isNowPlaying && coverGlowEnabled {
                PosterImage(
                    path: item.posterPath,
                    title: item.title,
                    mediaType: item.type,
                    cacheTargetSize: coverCacheTargetSize
                )
                .frame(width: plateSize, height: plateSize)
                .clipShape(shape)
                .brightness(0.5)
                .saturation(1.3)
                .blendMode(.plusLighter)
                .mask(
                    // 封面亮边再减半（R12 已 0.085→0.024；本轮 0.024→0.012 / blur 0.012→0.006）。
                    shape.strokeBorder(lineWidth: plateSize * 0.012)
                        .blur(radius: plateSize * 0.006)
                )
                .opacity((isPlaying ? (isHero ? 0.95 : 0.7) : 0.34) * glowPulse)
            }
        }
        .frame(width: plateSize, height: plateSize)
        .overlay {
            // 外缘白描边只给全玻璃卡：远处精简卡又小又淡，这道 0.7px 发丝描边不可辨 → 省 ~20 个描边+blur 叠层。
            if !lite {
                shape
                    .inset(by: -0.5)
                    .stroke(Color.white.opacity(isHero ? 0.28 : 0.12), lineWidth: isHero ? 1.0 : 0.7)
                    .blur(radius: isHero ? 0.2 : 0.0)
            }
        }
        .rotation3DEffect(
            .degrees(tiltY),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            perspective: ShelfDesignSystem.Angle.perspective
        )
        // 仅全玻璃卡需要 compositingGroup 来正确缩放其内部 .screen 混合；精简卡无 .screen → 省一个离屏目标。
        .shelfCompositingGroup(!lite)
        .allowsHitTesting(false)
    }

    private var reflection: some View {
        PosterImage(
            path: item.posterPath,
            title: item.title,
            mediaType: item.type,
            cacheTargetSize: CGSize(
                width: ShelfDesignSystem.Perf.reflectionCacheSide,
                height: ShelfDesignSystem.Perf.reflectionCacheSide
            )
        )
        // 先渲染完整方形封面并施加与正面相同的透视，再沿水平轴翻转；
        // 最后只裁取镜像顶部。旧实现先把图片压进半高 frame 再翻转，
        // 得到的是变形的上半张图，并非从封面底边连续向下的真实倒影。
        .frame(width: plateSize, height: plateSize)
        .clipShape(shape)
        .rotation3DEffect(
            .degrees(tiltY),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            perspective: ShelfDesignSystem.Angle.perspective
        )
        .scaleEffect(x: 1, y: -1, anchor: .center)
        .frame(
            width: plateSize,
            height: plateSize * ShelfDesignSystem.Plate.reflectionFraction,
            alignment: .top
        )
        .clipped()
        // 湖水冷调：倒影叠一层极淡的湖青，向下渐深，读作"沉入水里"（湖光主题）。
        .overlay(
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.58, blue: 0.72).opacity(0.10),
                         Color(red: 0.30, green: 0.50, blue: 0.66).opacity(0.26)],
                startPoint: .top, endPoint: .bottom
            )
            .blendMode(.softLight)
            .clipShape(shape)
        )
        // 倒影亮度随顶部光照：光心下方（中心封面）倒影更亮，越往两侧越淡 → 物理一致。
        .opacity(ShelfDesignSystem.Plate.reflectionOpacity * (0.55 + 0.45 * topLight))
        .blur(radius: 1.5)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white.opacity(0.62), location: 0.16),
                    .init(color: .white.opacity(0.24), location: 0.48),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

// MARK: - 歌词聚焦

private struct ShelfLyricsFocusView: View {
    let controller: MpvPlayerController
    let timedLyrics: [TimedLyricLine]
    let lyrics: String
    let hasDisplayLyrics: Bool
    let isFetchingLyrics: Bool
    let palette: AlbumColorPalette
    let reduceMotion: Bool
    let onFetchLyrics: () -> Void

    /// DEBUG：`--shelf-preview-lyrics` 注入一段合成逐字歌词，便于截图核对滚动卡拉OK（真机用实际 timedLyrics）。
    private var effectiveTimedLyrics: [TimedLyricLine] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shelf-preview-lyrics") {
            return ShelfKaraoke.debugSampleLines()
        }
        #endif
        return timedLyrics
    }

    var body: some View {
        let timed = effectiveTimedLyrics
        return Group {
            if !timed.isEmpty {
                // 逐字滚动卡拉OK：当前行居中、随播放滚动；未唱银灰、已唱发光亮白（需求③）。
                ShelfKaraokeScroll(controller: controller, lines: timed, palette: palette, reduceMotion: reduceMotion)
            } else if hasDisplayLyrics {
                untimedFocus
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }

    private var untimedFocus: some View {
        // 无逐字时间：取前若干非空行静态居中（已清理 lrc 元信息/头部行，避免"曲名 - 艺术家/词曲"被当歌词）。
        let lines = ShelfLyrics.cleanedLines(from: lyrics).prefix(4)
        return VStack(spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { entry in
                Text(entry.element)
                    .font(.system(size: 21, weight: entry.offset == 0 ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(entry.offset == 0 ? 0.9 : 0.5))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private var placeholder: some View {
        Button(action: onFetchLyrics) {
            Text(isFetchingLyrics ? "正在获取歌词…" : "暂无歌词 · 点击获取")
                .font(.system(size: ShelfDesignSystem.FontSize.lyricContext, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(isFetchingLyrics)
    }
}

// MARK: - 逐字滚动卡拉OK歌词（湖光）

/// 歌词随播放垂直滚动：当前行恒居视口中心、按绝对行位定位 → 切行时整列上移（真滚动）。
/// 性能：容器只投影「当前行下标」（行切换才重渲染）；逐字填充隔离在当前行子视图里（按量化进度自更新）。
private struct ShelfKaraokeScroll: View {
    let controller: MpvPlayerController
    let lines: [TimedLyricLine]
    let palette: AlbumColorPalette
    let reduceMotion: Bool

    @StateObject private var activeLine: ShelfControllerProjection<Int>

    init(controller: MpvPlayerController, lines: [TimedLyricLine], palette: AlbumColorPalette, reduceMotion: Bool) {
        self.controller = controller
        self.lines = lines
        self.palette = palette
        self.reduceMotion = reduceMotion
        let l = lines
        _activeLine = StateObject(wrappedValue: ShelfControllerProjection(controller: controller) { ctrl in
            TimedLyricLine.activeIndex(in: l, at: ctrl.currentTime) ?? 0
        })
    }

    private let fontSize: CGFloat = 22
    private var rowHeight: CGFloat { fontSize * 1.55 }
    private let rowSpacing: CGFloat = 6
    private var rowStride: CGFloat { rowHeight + rowSpacing }

    var body: some View {
        let active = min(max(activeLine.value, 0), max(0, lines.count - 1))
        GeometryReader { geo in
            // 真·滚动：用 ScrollViewReader + 动画版 scrollTo(anchor:.center) 让歌词内容真正向上滚动
            //（取代之前的整列 offset，避免看起来像淡入淡出）。上下留白让首/末行也能滚到正中。
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: rowSpacing) {
                        Color.clear.frame(height: geo.size.height * 0.5)
                        ForEach(lines.indices, id: \.self) { i in
                            row(i, active: active)
                                .frame(maxWidth: .infinity)
                                .frame(height: rowHeight)
                                .id(i)
                        }
                        Color.clear.frame(height: geo.size.height * 0.5)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(active, anchor: .center) }
                .onChange(of: active) { newActive in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
                        proxy.scrollTo(newActive, anchor: .center)
                    }
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.24),
                        .init(color: .white, location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    @ViewBuilder
    private func row(_ i: Int, active: Int) -> some View {
        if i == active {
            ShelfKaraokeActiveLine(
                controller: controller,
                line: lines[i],
                lineEnd: endTime(i),
                fontSize: fontSize,
                reduceMotion: reduceMotion
            )
        } else {
            let d = abs(i - active)
            // 已唱行偏白、未唱行偏白的银色；越远越淡。全部加粗。
            Text(lines[i].text.isEmpty ? " " : lines[i].text)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle((i < active ? Color(white: 0.93) : Color(white: 0.86))
                    .opacity(max(0.18, 0.56 - Double(d - 1) * 0.12)))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .multilineTextAlignment(.center)
        }
    }

    private func endTime(_ i: Int) -> Double {
        i + 1 < lines.count ? lines[i + 1].time : lines[i].time + 4.0
    }
}

/// 当前行的逐字卡拉OK：底层银灰（未唱），上层发光亮白（已唱）按进度从左到右揭示，边界柔化。
private struct ShelfKaraokeActiveLine: View {
    let controller: MpvPlayerController
    let line: TimedLyricLine
    let lineEnd: Double
    let fontSize: CGFloat
    let reduceMotion: Bool

    /// 只投影「量化后的逐字进度」：同一量化桶内的时钟更新不触发重绘。
    @StateObject private var fill: ShelfControllerProjection<Double>

    init(controller: MpvPlayerController, line: TimedLyricLine, lineEnd: Double, fontSize: CGFloat, reduceMotion: Bool) {
        self.controller = controller
        self.line = line
        self.lineEnd = lineEnd
        self.fontSize = fontSize
        self.reduceMotion = reduceMotion
        let l = line
        let end = lineEnd
        _fill = StateObject(wrappedValue: ShelfControllerProjection(controller: controller) { ctrl in
            ShelfKaraoke.fraction(of: l, end: end, at: ctrl.currentTime)
        })
    }

    @State private var contentWidth: CGFloat = 0

    private var chars: [Character] { Array(line.text.isEmpty ? " " : line.text) }

    var body: some View {
        let p = fill.value
        let n = max(chars.count, 1)
        let sung = Double(p) * Double(n)   // 已唱字数（小数，边界字部分点亮）
        GeometryReader { geo in
            // 过宽则整体缩放以贴合可用宽度（替代单 Text 的 minimumScaleFactor）。
            let fit = (contentWidth > geo.size.width && contentWidth > 0) ? geo.size.width / contentWidth : 1
            HStack(spacing: 0) {
                ForEach(chars.indices, id: \.self) { i in
                    charView(chars[i], cp: min(max(sung - Double(i), 0), 1))
                }
            }
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: ShelfKaraokeWidthKey.self, value: g.size.width)
            })
            .scaleEffect(fit, anchor: .center)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .onPreferenceChange(ShelfKaraokeWidthKey.self) { contentWidth = $0 }
        }
        // 时钟仅 ~5.5Hz 采样：用**匀速 linear**(时长略大于采样间隔)让渲染服务器在两次采样间以 60fps 插值，
        // 不再 easeOut「减速→停顿→再起步」的一卡一卡；且仅 5.5Hz 触发 body 重算，逐帧平滑由动画插值完成（零额外重绘）。
        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: p)
    }

    /// 单字：已唱(cp→1)则**由银转亮白 + 略增大一号**；未唱(cp=0)为原位银灰。
    /// 去掉了"上浮(offset)"与"逐字发光(shadow)"——前者按用户要求移除，后者每字一个离屏阴影层、是逐字歌词卡顿的主因；
    /// 现仅保留 color + scale（纯 transform，无离屏），配合匀速插值 → 顺滑且轻。
    private func charView(_ c: Character, cp: Double) -> some View {
        Text(String(c))
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(Color(white: 0.86 + 0.14 * cp))
            .scaleEffect(1.0 + 0.10 * CGFloat(cp), anchor: .bottom)   // 已唱字略增大一号
    }
}

/// 测量当前行逐字 HStack 的自然宽度，用于过宽时整体缩放贴合。
private struct ShelfKaraokeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 逐字进度与歌词文本清理工具。
enum ShelfKaraoke {
    /// 当前行已唱比例（0…1）。量化到 256 级（仍受 ~5.5Hz 时钟上限，不增重绘）：目标值更细，配合匀速插值更顺。
    static func fraction(of line: TimedLyricLine, end: Double, at t: Double) -> Double {
        (rawFraction(of: line, end: end, at: t) * 256).rounded() / 256
    }

    #if DEBUG
    /// 合成逐字歌词（仅截图核对用）：8 行、每行均分逐字 segments，时间锚定在 ~30s 附近一行进行到一半。
    static func debugSampleLines() -> [TimedLyricLine] {
        let texts = ["夜空をかけてゆく光", "湖の面に揺れるメロディ", "今この瞬間を抱きしめて", "やさしい彗星のように",
                     "遠く遠く流れてゆく", "光が水面で踊る夜", "静かに響くこの歌声", "ずっとここにいたいよ"]
        var out: [TimedLyricLine] = []
        var t = 9.5
        let stride = 3.5
        for s in texts {
            var line = TimedLyricLine(time: t, text: s)
            let chars = Array(s)
            let per = (stride * 0.8) / Double(max(1, chars.count))
            line.segments = chars.enumerated().map { TimedLyricSegment(time: t + Double($0.offset) * per, text: String($0.element)) }
            out.append(line)
            t += stride
        }
        return out
    }
    #endif

    private static func rawFraction(of line: TimedLyricLine, end: Double, at t: Double) -> Double {
        if t <= line.time { return 0 }
        if !line.segments.isEmpty {
            let total = line.segments.reduce(0.0) { $0 + Double(max(1, $1.text.count)) }
            guard total > 0 else { return 0 }
            var sung = 0.0
            for (i, seg) in line.segments.enumerated() {
                let s = seg.time
                let e = i + 1 < line.segments.count ? line.segments[i + 1].time : end
                let len = Double(max(1, seg.text.count))
                if t >= e {
                    sung += len
                } else if t >= s {
                    let frac = e > s ? (t - s) / (e - s) : 1
                    sung += len * min(max(frac, 0), 1)
                    break
                } else {
                    break
                }
            }
            return min(1, sung / total)
        } else {
            let dur = max(end - line.time, 0.01)
            return min(max((t - line.time) / dur, 0), 1)
        }
    }
}

enum ShelfLyrics {
    /// 清理纯文本歌词：去掉空行与 lrc 元信息/头部行（[ti:]、词：、作曲… 等），避免被当作歌词显示。
    static func cleanedLines(from raw: String) -> [String] {
        let metaPrefixes = ["词：", "曲：", "词:", "曲:", "作词", "作曲", "编曲", "制作", "by:", "ti:", "ar:", "al:", "offset:"]
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.range(of: #"^\[[a-zA-Z#]+:.*\]$"#, options: .regularExpression) != nil { return false }
                if metaPrefixes.contains(where: { line.hasPrefix($0) }) { return false }
                return true
            }
    }
}

// MARK: - 进度条

private struct ShelfProgressRail: View {
    let controller: MpvPlayerController
    let palette: AlbumColorPalette

    @StateObject private var timeline: ShelfControllerProjection<ShelfTimelineSnapshot>
    @State private var scrubFraction: Double?
    @State private var railHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 已播放段上缓慢流过的高光相位（液态流光）。
    @State private var sheenPhase: CGFloat = 0
    /// 小圆点脉冲光相位（播放前进时一圈光晕脉动扩散）。
    @State private var thumbPulse = false

    init(controller: MpvPlayerController, palette: AlbumColorPalette) {
        self.controller = controller
        self.palette = palette
        _timeline = StateObject(wrappedValue: ShelfControllerProjection(controller: controller) { ctrl in
            ShelfTimelineSnapshot(currentTime: ctrl.currentTime, duration: ctrl.duration, isPlaying: ctrl.isPlaying)
        })
    }

    var body: some View {
        let snapshot = timeline.value
        let duration = max(snapshot.duration, 0.01)
        let fraction = scrubFraction ?? min(max(snapshot.currentTime / duration, 0), 1)
        let displayTime = (scrubFraction.map { $0 * duration }) ?? snapshot.currentTime

        HStack(spacing: 14) {
            Text(shelfFormatTime(displayTime))
                .frame(width: 44, alignment: .leading)
            railTrack(fraction: fraction, duration: duration)
            Text(shelfFormatTime(duration))
                .frame(width: 44, alignment: .trailing)
        }
        // 时间数字：中等字重 + 提高不透明度 + 极淡暗影 → 在高亮专辑封面底板上也稳过 4.5:1 可读（skill §6 对比度）。
        .font(.system(size: ShelfDesignSystem.FontSize.time, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.78))
        .shadow(color: .black.opacity(0.28), radius: 2, y: 0.5)
        // 进度条 VoiceOver 语义：作为「可调」滑杆朗读当前/总时长，上下箭头 ±5s 快进/退（skill §1 无障碍）。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(shelfFormatTime(displayTime)) / \(shelfFormatTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.seek(to: min(duration, displayTime + 5))
            case .decrement: controller.seek(to: max(0, displayTime - 5))
            @unknown default: break
            }
        }
    }

    private func railTrack(fraction: Double, duration: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let active = scrubFraction != nil
            // 拖动/悬停时轨道与拖柄放大、变亮 → 操作即时反馈。
            let thumb: CGFloat = active ? 14 : (railHover ? 11 : 8)
            let trackH: CGFloat = active || railHover ? 5 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(active || railHover ? 0.20 : 0.14)).frame(height: trackH)
                // 已播放段使用专辑主色（取色加强）+ 顶部白色高光保留对比与玻璃光泽。
                Capsule()
                    .fill(LinearGradient(colors: [palette.primary.color, palette.glowPrimary.color],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(
                        Capsule().fill(LinearGradient(colors: [.white.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
                            .blendMode(.screen)
                    )
                    .frame(width: max(0, width * fraction), height: trackH)
                    .shadow(color: palette.glowPrimary.color.opacity(active ? 0.7 : 0.5), radius: active ? 10 : 8)
                // 液态流光：一道高光缓缓掠过已播放段（clip 在已播放胶囊内）。
                Capsule()
                    .fill(LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 52, height: trackH)
                    .offset(x: sheenPhase * (width + 104) - 52)
                    .frame(width: max(0, width * fraction), height: trackH, alignment: .leading)
                    .clipShape(Capsule())
                    .blendMode(.screen)
                    .allowsHitTesting(false)
                // 小圆点脉冲光：播放前进时一圈专辑色光晕自圆点向外脉动扩散（ping），强调「正在前进」；暂停时停在柔光静止态。
                Circle()
                    .fill(palette.glowPrimary.color)
                    .frame(width: thumb, height: thumb)
                    .scaleEffect(thumbPulse ? 1.95 : 1.1)
                    .opacity(thumbPulse ? 0.0 : 0.55)
                    .offset(x: max(0, width * fraction - thumb / 2))
                    .blur(radius: 2)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: palette.glowPrimary.color.opacity(0.85), radius: active ? 8 : 6)
                    .offset(x: max(0, width * fraction - thumb / 2))
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
            .animation(ShelfDesignSystem.Motion.controlHover, value: railHover)
            // 已播放段流光：仅播放中循环，暂停时停转（窗口可空闲）。
            .shelfAmbientLoop($sheenPhase, active: timeline.value.isPlaying && !reduceMotion, activeValue: 1, restValue: 0,
                              loop: .linear(duration: 3.8).repeatForever(autoreverses: false),
                              settle: .easeOut(duration: 0.4))
            // 小圆点脉冲光：仅播放中脉动扩散，暂停时停在柔光静止态。
            .shelfAmbientLoop($thumbPulse, active: timeline.value.isPlaying && !reduceMotion, activeValue: true, restValue: false,
                              loop: .easeOut(duration: 1.5).repeatForever(autoreverses: false),
                              settle: .easeOut(duration: 0.4))
            .onHover { railHover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubFraction = min(max(value.location.x / max(width, 1), 0), 1)
                    }
                    .onEnded { value in
                        let f = min(max(value.location.x / max(width, 1), 0), 1)
                        scrubFraction = nil
                        controller.seek(to: f * duration)
                    }
            )
        }
        .frame(height: 18)
    }
}

// MARK: - 歌曲标题

/// 唱片架下方的「正在播放」标题块：曲名 + 艺术家·专辑。切歌时文字内容交叉淡入。
private struct ShelfNowPlayingTitle: View {
    let title: String
    let subtitle: String?
    let reduceMotion: Bool
    var isPlaying: Bool = true
    var tint: Color = .white
    /// 流光相位（播放时一道柔光缓缓扫过标题）。
    @State private var sheenX: CGFloat = -0.4

    private var titleFont: Font { .system(size: ShelfDesignSystem.FontSize.title, weight: .heavy) }
    private var titleString: String { title.isEmpty ? " " : title }

    var body: some View {
        VStack(spacing: 3) {
            Text(titleString)
                .font(titleFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .shadow(color: .black.opacity(0.4), radius: 9, y: 2)
                // #5 打磨：标题一圈专辑色辉光，呼应取色、增强景深与"被光照亮"的空间感。
                .shadow(color: tint.opacity(0.30), radius: 13)
                // #4 活力：播放时一道柔光缓缓扫过标题字面（mask 到字形、screen 叠加；暂停停在屏外不耗）。
                .overlay {
                    if isPlaying && !reduceMotion {
                        GeometryReader { geo in
                            let w = max(geo.size.width, 1)
                            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: w * 0.34)
                                .offset(x: sheenX * (w + w * 0.34))
                                .blendMode(.screen)
                        }
                        .mask(
                            Text(titleString).font(titleFont).lineLimit(1)
                                .minimumScaleFactor(0.7).truncationMode(.tail)
                        )
                        .allowsHitTesting(false)
                    }
                }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: ShelfDesignSystem.FontSize.subtitle, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 24)
        .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.titleFade, value: title)
        .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.titleFade, value: subtitle)
        .shelfAmbientLoop($sheenX, active: isPlaying && !reduceMotion, activeValue: 1.0, restValue: -0.4,
                          loop: .easeInOut(duration: 4.6).repeatForever(autoreverses: false).delay(0.6),
                          settle: .linear(duration: 0.01))
    }
}

// MARK: - 底部 Dock（收藏 / 隔空播放 / 音量 / 收起播放界面）

/// 磨砂控制栏：上排图标（收藏/列表/隔空/音量/收起），底部内嵌一条**极窄三段横条**（上一首/暂停/下一首）。
private struct ShelfDock: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let currentItem: MediaItem
    let controller: MpvPlayerController
    let palette: AlbumColorPalette
    let isPlaying: Bool
    let reduceMotion: Bool
    let onMinimize: () -> Void

    /// 段间/两端统一间隙；段条粗细 ≈ 2× 进度条粗细；段宽固定使三段总宽≈上排图标宽（两端齐平）。
    private let segGap: CGFloat = 6
    private let segThickness: CGFloat = 6
    private let segWidth: CGFloat = 67

    /// 最新收藏态（toggleFavorite 改 appState 后本视图随 EnvironmentObject 刷新）。
    private var isFavorite: Bool {
        appState.musicQueue.first(where: { $0.id == currentItem.id })?.favorite ?? currentItem.favorite
    }

    var body: some View {
        VStack(spacing: 7) {
            // 上排：图标按钮
            HStack(spacing: 4) {
                ShelfDockButton(
                    systemImage: isFavorite ? "heart.fill" : "heart",
                    tint: isFavorite ? Color(red: 1.0, green: 0.34, blue: 0.40) : .white,
                    isActive: isFavorite,
                    reduceMotion: reduceMotion,
                    accessibility: isFavorite ? "取消喜欢" : "我喜欢",
                    action: { appState.toggleFavorite(currentItem) }
                )
                ShelfDockQueueButton(currentItem: currentItem, palette: palette, reduceMotion: reduceMotion)
                ShelfDockAirPlay(controller: controller, reduceMotion: reduceMotion)
                ShelfDockVolumeButton(controller: controller, reduceMotion: reduceMotion)
                Capsule().fill(.white.opacity(0.16)).frame(width: 1, height: 20).padding(.horizontal, 4)
                ShelfDockButton(
                    systemImage: "chevron.down",
                    tint: .white,
                    isActive: false,
                    reduceMotion: reduceMotion,
                    accessibility: "收起播放界面",
                    action: onMinimize
                )
            }

            // 底部内嵌的极窄三段横条：上一首 / 暂停 / 下一首；段间与两端等距。
            transportStrip
                .padding(.horizontal, segGap)
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, segGap)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(colorScheme == .dark ? 0.05 : 0.09))
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(
                    LinearGradient(
                        colors: [
                            palette.glowSecondary.color.opacity(colorScheme == .dark ? 0.075 : 0.055),
                            .clear,
                            palette.glowPrimary.color.opacity(colorScheme == .dark ? 0.045 : 0.032)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.38 : 0.50),
                            palette.glowPrimary.color.opacity(0.16),
                            .white.opacity(0.07)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .strokeBorder(.black.opacity(colorScheme == .dark ? 0.10 : 0.035), lineWidth: 0.7)
                    .padding(1)
            }
        )
        .shadow(color: ShelfDesignSystem.Elevation.surfaceColor,
                radius: ShelfDesignSystem.Elevation.surfaceRadius,
                y: ShelfDesignSystem.Elevation.surfaceY)
        // 湖光识别延展：Dock 下方一汪专辑色柔光，控制面读作"浮在被点亮的湖面上"，把全屏的湖光叙事收束到底部 chrome。
        // 纯叠加的彩色投影、静态无动画（零额外帧开销）；与上面的中性高程阴影叠合成"实托起 + 暖光晕"。
        .shadow(color: palette.glowPrimary.color.opacity(0.22), radius: 26, y: 9)
    }

    private var transportStrip: some View {
        let hasPrev = appState.hasAdjacentItem(to: currentItem, direction: -1)
        let hasNext = appState.hasAdjacentItem(to: currentItem, direction: 1)
        // 固定等宽三段（避免 GeometryReader 返回提案全宽导致段条溢出 Dock）。
        return HStack(spacing: segGap) {
            ShelfThinSegment(width: segWidth, thickness: segThickness, tint: .white, prominent: false, enabled: hasPrev, reduceMotion: reduceMotion, accessibilityLabel: "上一首") {
                appState.playAdjacent(to: currentItem, direction: -1)
            }
            ShelfThinSegment(width: segWidth, thickness: segThickness, tint: Color(nsColor: palette.primary.nsColor), prominent: true, enabled: true, reduceMotion: reduceMotion, accessibilityLabel: isPlaying ? "暂停" : "播放") {
                controller.togglePlay()
            }
            ShelfThinSegment(width: segWidth, thickness: segThickness, tint: .white, prominent: false, enabled: hasNext, reduceMotion: reduceMotion, accessibilityLabel: "下一首") {
                appState.playAdjacent(to: currentItem, direction: 1)
            }
        }
    }
}

/// 极窄段条按钮（无图标，靠位置区分）：固定等宽、圆角端、hover/press 反馈。中段(prominent)略亮+专辑色调。
private struct ShelfThinSegment: View {
    let width: CGFloat
    let thickness: CGFloat
    let tint: Color
    let prominent: Bool
    let enabled: Bool
    let reduceMotion: Bool
    var accessibilityLabel: String = ""
    let action: () -> Void

    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        let base = prominent ? 0.66 : 0.42
        let op = enabled ? (hover ? base + 0.28 : base) : 0.2
        Capsule()
            .fill(tint.opacity(op))
            .overlay(Capsule().fill(.white.opacity(prominent ? 0.3 : 0.2)).frame(height: 1).offset(y: -thickness * 0.28))
            .frame(width: width, height: thickness)
            // 主操作（中段播放/暂停）专辑色柔光：把"唯一主 CTA"从一排同形细条里轻轻托出（skill §4 primary-action）；
            // 上一/下一首不发光，层级清晰。纯叠加、暂停态仍在（不删任何效果）。
            .shadow(color: prominent && enabled ? tint.opacity(0.55) : .clear, radius: prominent ? 5 : 0)
            .scaleEffect(y: pressed ? 0.65 : 1.0, anchor: .center)
            .contentShape(Rectangle().inset(by: -9))   // 加大可点区（段条本身很细）
            .onHover { h in withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlHover) { hover = h } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if enabled, !pressed { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { pressed = true } } }
                    .onEnded { v in
                        withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlPress) { pressed = false }
                        if enabled, abs(v.translation.width) < 16, abs(v.translation.height) < 16 { action() }
                    }
            )
            // 无图标细条靠位置区分，对 VoiceOver/指针悬停不可读 → 补按钮语义 + 标签 + 激活动作 + tooltip
            // （skill §1 aria-labels / §9 nav-label-icon：上一首 / 播放·暂停 / 下一首）。
            .help(accessibilityLabel)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(enabled ? "" : "当前没有可切换的曲目")
            .accessibilityAction { if enabled { action() } }
    }
}

/// Dock 内的圆形玻璃图标按钮：hover 浮起底圈、按压回弹缩放；isActive 由 false→true 时图标弹一下（如收藏心跳）。
private struct ShelfDockButton: View {
    let systemImage: String
    var tint: Color = .white
    var isActive: Bool = false
    var reduceMotion: Bool = false
    var accessibility: String = ""
    let action: () -> Void

    @State private var hover = false
    @State private var activeBounce: CGFloat = 1.0

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint.opacity(isActive ? 1 : (hover ? 1 : 0.82)))
                .scaleEffect(activeBounce)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(ShelfDockPressStyle(reduceMotion: reduceMotion))
        .onHover { h in withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlHover) { hover = h } }
        .onChange(of: isActive) { active in
            guard active, !reduceMotion else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.42)) { activeBounce = 1.34 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { activeBounce = 1.0 }
            }
        }
        .help(accessibility)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(.isButton)
    }
}

/// 按压回弹：缩到 0.86 再弹回，让每次点击都有清晰反馈。
private struct ShelfDockPressStyle: ButtonStyle {
    var reduceMotion: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1.0)
            .animation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlPress, value: configuration.isPressed)
    }
}

/// Dock 内的隔空播放：复用系统 AVRoutePicker，去掉它自带的玻璃底，套到 Dock 统一的 hover 圆圈里。
private struct ShelfDockAirPlay: View {
    let controller: MpvPlayerController
    var reduceMotion: Bool = false
    @State private var hover = false

    var body: some View {
        AirPlayRoutePickerControl(
            session: controller.routePickerSession,
            player: controller.routePickerPlayer,
            tintColor: NSColor.white.withAlphaComponent(0.85),
            activeTintColor: NSColor.white,
            systemImage: "airplayaudio",
            size: 36,
            cornerRadius: 18,
            useGlassBackground: false,
            onRoutesWillBegin: { controller.prepareForMusicAirPlayRouteSelection() },
            onRoutesDidEnd: { controller.refreshMusicAirPlayRoute(afterRoutePicker: true) }
        )
        .frame(width: 40, height: 40)
        .background(Circle().fill(.white.opacity(hover ? 0.14 : 0)))
        .contentShape(Circle())
        .onHover { h in withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlHover) { hover = h } }
        .help("隔空播放")
        .accessibilityLabel("隔空播放")
    }
}

/// Dock 内的音量按钮：点击弹出感知线性的音量滑杆 popover。
private struct ShelfDockVolumeButton: View {
    let controller: MpvPlayerController
    var reduceMotion: Bool = false

    @StateObject private var volume: ShelfControllerProjection<Float>
    @State private var hover = false
    @State private var showPopover = false

    init(controller: MpvPlayerController, reduceMotion: Bool = false) {
        self.controller = controller
        self.reduceMotion = reduceMotion
        _volume = StateObject(wrappedValue: ShelfControllerProjection(controller: controller) { $0.volume })
    }

    private var value: Double { Double(volume.value) }
    private var icon: String {
        if value <= 0.001 { return "speaker.slash.fill" }
        if value < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.82))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(ShelfDockPressStyle(reduceMotion: reduceMotion))
        .onHover { h in withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlHover) { hover = h } }
        .help("音量")
        .accessibilityLabel("音量")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(.secondary)
                    Text("音量").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { PerceptualVolumeScale.sliderValue(fromLinear: value) },
                    set: { controller.setVolume(Float(PerceptualVolumeScale.linearVolume(fromSlider: $0))) }
                ), in: 0...1)
                .frame(width: 210)
            }
            .padding(16)
            .frame(width: 248)
        }
    }
}

/// Dock 内的列表按钮：点击弹出当前播放队列，点条目即播放（需求⑥）。
private struct ShelfDockQueueButton: View {
    let currentItem: MediaItem
    let palette: AlbumColorPalette
    var reduceMotion: Bool = false
    @State private var hover = false
    @State private var showQueue = false

    var body: some View {
        Button { showQueue.toggle() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.82))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(ShelfDockPressStyle(reduceMotion: reduceMotion))
        .onHover { h in withAnimation(reduceMotion ? nil : ShelfDesignSystem.Motion.controlHover) { hover = h } }
        .help("播放列表")
        .accessibilityLabel("播放列表")
        .popover(isPresented: $showQueue, arrowEdge: .top) {
            MusicQueuePopover(currentItem: currentItem, palette: palette)
        }
    }
}

/// 播放队列弹层：`List` + **原生 `.onMove` 拖动重排**（macOS 原生插入指示器，放置位置精确）+ 逐条移出 + 点按播放。
/// 之前用 onDrag/onDrop+dropEntered 实时重排「难精确定位/不跟手」→ 改 `.onMove`：拖动时显示落点间隙、松手才落定。
private struct ShelfQueuePopover: View {
    @EnvironmentObject private var appState: AppState
    let currentItem: MediaItem
    let palette: AlbumColorPalette

    private var queue: [MediaItem] {
        appState.musicQueue.isEmpty ? [currentItem] : appState.musicQueue
    }

    var body: some View {
        let queue = self.queue
        let rows = ShelfQueueRowModel.models(from: queue)
        VStack(spacing: 0) {
            HStack {
                Text("播放队列").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { appState.clearMusicQueue(keepingCurrent: true) } label: {
                    Label("清空", systemImage: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!queue.contains { $0.id != currentItem.id })
                .help("清空队列（保留当前曲）")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                List {
                    ForEach(rows) { row in
                        ShelfQueueRow(
                            row: row,
                            isCurrent: row.id == currentItem.id,
                            tint: Color(nsColor: palette.primary.nsColor),
                            onRemove: { appState.removeFromMusicQueue(row.track) }
                        )
                        .equatable()
                        .id(row.id)
                        .contentShape(Rectangle())
                        .onTapGesture { appState.play(row.track) }
                        .contextMenu {
                            Button { appState.play(row.track) } label: {
                                Label("播放", systemImage: "play.fill")
                            }
                            Button {
                                appState.playNextInMusicQueue(row.track)
                            } label: {
                                Label("下一曲播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .disabled(row.id == currentItem.id)
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
                    .onMove { indices, newOffset in
                        // 原生拖动重排：精确插入到目标位置。
                        appState.moveMusicQueueItems(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .environment(\.defaultMinListRowHeight, 0)
                .transaction { $0.animation = nil }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(currentItem.id, anchor: .center) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 360, height: 404)
    }
}

/// 队列行模型（Identifiable + Equatable）：预构以便拖动中 `.equatable()` 跳过重建。与琉璃 `MusicQueueRowModel` 同源。
private struct ShelfQueueRowModel: Identifiable, Equatable {
    let track: MediaItem
    let titleText: String
    let subtitleText: String
    let posterPath: String?

    var id: String { track.id }

    static func models(from queue: [MediaItem]) -> [ShelfQueueRowModel] {
        queue.map { item in
            ShelfQueueRowModel(track: item, titleText: item.title,
                               subtitleText: item.artistAlbumLine ?? "未知艺人", posterPath: item.posterPath)
        }
    }
}

/// 队列行视图（Equatable）：拖柄 + 封面 + 标题/副标 + 当前曲喇叭 + 移出钮。与琉璃 `MusicQueueRow` 同源。
private struct ShelfQueueRow: View, Equatable {
    let row: ShelfQueueRowModel
    let isCurrent: Bool
    let tint: Color
    let onRemove: () -> Void
    private static let artworkCacheSize = CGSize(width: 76, height: 76)

    static func == (lhs: ShelfQueueRow, rhs: ShelfQueueRow) -> Bool {
        lhs.row == rhs.row && lhs.isCurrent == rhs.isCurrent
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.55))
                .frame(width: 16)
            PosterImage(path: row.posterPath, title: row.titleText, mediaType: row.track.type, cacheTargetSize: Self.artworkCacheSize)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.titleText)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? tint : .primary)
                    .lineLimit(1)
                Text(row.subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary.opacity(isCurrent ? 0.28 : 0.62))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)
            .help(isCurrent ? "正在播放的歌曲不能移出" : "移出队列")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 48)
        .background(.white.opacity(isCurrent ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(isCurrent ? 0.26 : 0.12), lineWidth: 1)
        }
    }
}

// MARK: - 手势提示

private struct ShelfHintPill: View {
    let isPlaying: Bool
    let repeatOne: Bool
    let gathered: Bool
    let browsing: Bool
    let override: String?

    private var text: String {
        if let override { return override }
        if browsing { return "翻看唱片架 · 点选唱片播放，松手回到当前曲" }
        if gathered { return "已拾起唱片 · 拖动可排成一列，松手随机排序" }
        if !isPlaying { return "点击唱片继续播放" }
        if repeatOne { return "单曲循环中 · 向下拉唱片可关闭" }
        return "点击唱片暂停 · 长按并晃动可拾起拖动"
    }

    var body: some View {
        Text(text)
            .font(.system(size: ShelfDesignSystem.FontSize.hint))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            // 提示胶囊原本是一层扁平白纱、无景深 → 与 Dock 不同语言。统一到 Dock 的「磨砂玻璃 +
            // 顶亮渐变描边 + 悬浮高程」（skill §4 effects-match-style / elevation-consistent）：读作同一套浮于湖面的玻璃。
            .background(
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(.white.opacity(override != nil ? 0.16 : 0.08))
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
                .shadow(color: ShelfDesignSystem.Elevation.floatingColor,
                        radius: ShelfDesignSystem.Elevation.floatingRadius,
                        y: ShelfDesignSystem.Elevation.floatingY)
            )
            .id(text)
            .transition(.opacity)
    }
}

// MARK: - 工具

func shelfFormatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
