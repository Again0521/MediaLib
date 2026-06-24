import MediaLibCore
import SwiftUI

/// 业务 → 主题 的唯一接口（R1）。
///
/// 设计目标：把内置音乐播放器主题（琉璃 / 无界 / 湖光）需要的全部业务数据与动作，
/// 收敛到一个**与主题无关**的载体里。主题视图只读这个 context，永远不直接 import 业务文件
/// （MpvPlayerController / AppState 的加载与编排逻辑）。
///
/// 为什么是值类型而非 ObservableObject：
/// - 本结构只承载**低频**业务数据（曲目 / 取色 / 歌词 / 各 flag），由宿主 `MusicPlayerView`
///   在每次 body 重算时从其 `@State` 直接构造并传入；SwiftUI 的值比较即可驱动主题更新。
/// - **高频**播放量（`currentTime` / 频谱 / `seekState`）刻意不进入本结构：它们继续由叶子视图
///   通过 `controller` 直读或经 `ShelfControllerProjection` 局部订阅，避免把 0.18s 进度刷新
///   传染成整树重算（既有性能红线）。因此这里只持有 `controller` 引用，不转发其变化。
///
/// R1 范围：仅新增本类型 + 让宿主构造它 + 湖光改吃它（等价重构、零视觉变化）。
/// 琉璃 / 无界拆分独立文件并改吃 context 留待 R2；主题参数文件化留待 R3+。
struct MusicPlaybackContext {
    // MARK: 低频业务数据（主题只读）

    /// 当前曲目（已含“活动曲优先、否则回退入参曲”的逻辑，由宿主算好传入）。
    let item: MediaItem
    /// 专辑取色调色板。
    let palette: AlbumColorPalette
    /// 纯文本歌词（未匹配到逐句时间戳时的回退展示）。
    let lyrics: String
    /// 逐句（可含逐字）时间轴歌词。
    let timedLyrics: [TimedLyricLine]
    /// 歌词时间轴来源（原词逐字 / 音频对齐 / 估算同步）。
    let lyricTimingSource: LyricTimingSource
    /// 是否存在可展示歌词（宿主算好的派生布尔）。
    let hasDisplayLyrics: Bool
    /// 是否正在在线获取歌词。
    let isFetchingLyrics: Bool
    /// 设置项：是否开启封面发光。
    let coverGlowEnabled: Bool
    /// 重型封面纹理 / 玻璃底是否已就绪（= 宿主 glassLayerReady）。
    let artworkReady: Bool
    /// 入场动画是否已完成（= reduceMotion || entrancePhase>=1）。湖光只需这个布尔。
    let entranceReady: Bool
    /// 入场动画原始阶段（0/1/2）。琉璃 / 无界按 `>=1`（左栏）与 `>=2`（歌词）分级淡入，需原始值。
    let entrancePhase: Int
    /// 无障碍：是否降低动态效果。
    let reduceMotion: Bool
    /// 明 / 暗外观。
    let colorScheme: ColorScheme

    // MARK: 主题需读写、但归宿主所有的视图状态

    /// 用户是否正在手动浏览歌词（拖动/滚动）。宿主的 `pauseLyricAutoScroll` /
    /// `resetLyricPlaybackViewportState` 也读写它，故归宿主所有，主题经此 Binding 双向访问。
    let userIsBrowsingLyrics: Binding<Bool>

    // MARK: 高频播放（仅暴露引用，不在本结构层观察）

    /// 播放控制器。主题需要高频量时自行通过它直读或建立局部投影订阅。
    let controller: MpvPlayerController

    // MARK: 动作（宿主注入，主题只调用、不关心实现）

    /// 触发在线获取歌词。
    let fetchLyrics: () -> Void
    /// 收起播放界面（回到底部迷你播放器）。
    let requestMinimize: () -> Void
    /// 用户开始手动浏览歌词时，暂停自动滚动（宿主实现，主题在歌词面板回调里调用）。
    let pauseLyricAutoScroll: () -> Void
}
