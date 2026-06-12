# MusicPlayerView Metal 背景与歌词卡效果重构专项规划

创建日期：2026-06-05

本专项目标是在不削减音乐展开页任何光效、玻璃层次和歌词表现的前提下，把 WindowServer 压力从 SwiftUI/全屏 CA 合成热路径迁移到可暂停、可按需绘制的 Metal/局部图层架构，并为后续动态背景与歌词卡动态效果留下统一扩展入口。

## 当前代码现状

主入口在 `Sources/MediaLib/Views/MusicPlayerView.swift`：

- `MusicPlayerView.expandedPlayer` 的整窗背景已由 `MetalAlbumBackdropView` 接管；旧 `AlbumGlassBackdrop`、`MusicFullScreenGlassLayer`、`AlbumBackdropStaticLayer`、`AlbumBackdropLightLayer`、`AlbumNearFieldIlluminationLayer`、`AlbumBlurredArtworkBackdrop`、`LowResolutionArtworkBackdropLayer` 已在 2026-06-05 第二轮清理。
- `MusicPlayerMetalBackdropView.swift` 当前负责不透明 `backdropBaseColor`、低分辨率封面颜料场、纵向/斜向线性渐变、固定径向渐变、多枚 mesh 多色光斑、受控 `plusLighter` / `screen` 合成、斜向高光、`staticBackdrop`、`ambient`、整窗 glass、`nearField` 和 1px screen 边线；2026-06-09 第二轮把低频封面颜料场收为约 38px 网格和 15px softening，第三轮把 shader 彩度补偿微调到 1.10、白色 veil 保持 0.065、专辑光强保持 0.60，并通过 `glassifyAlbumColor` 的 clean shadow / mud guard 与 `harmonicShift` 生成小幅色相和声场，让底板和封面同源但不照抄。
- L0 静态模式仍保持 `MTKView.isPaused = true`、`enableSetNeedsDisplay = true`、`preferredFramesPerSecond = 30`；第二轮已设置 `CAMetalLayer.maximumDrawableCount = 2`，并移除 `draw(in:)` 中非主线程 `DispatchQueue.main.sync` 回主线程的兜底。
- `AppKitVisualEffectBackground` 默认 `blendingMode` 已在 2026-06-05 L2 轮次改为 `.withinWindow`；播放器页面不得再新增 `.behindWindow` 调用。
- `FloatingLyricsGlass` 内部的 `MusicInheritedGlassPointerWash` 已在 2026-06-05 L2 轮次移除，pointer wash 和边缘提亮改由局部 `LyricsCardEffectLayerView` 承载。后续边缘流光、扫光、节奏辉光继续进入 L2，不再由 SwiftUI body 和 modifier 响应鼠标移动。
- `MusicExpandedLyricsPanel` 的文字层仍是 SwiftUI；`LyricStageLight` 已局部 CA 化，`LyricCenterSpotlight`、`LyricEdgeTintOverlay`、`LyricCardEdgeDepthOverlay` 仍有 SwiftUI 渐变。静态卡片底和真实玻璃保留在 L1，卡片动态效果移入 L2，歌词文本与可访问性保留在 L3。
- `MusicExpandedLyricsPanel` 在无歌词 / 获取失败 / 纯音乐状态下保留完整玻璃歌词卡，并显示居中舞台空态；右上角获取歌词入口继续作为同一卡片上的轻量操作，不再把占位文案当作普通滚动歌词行显示。
- `MusicTimedLyricsScrollView` 已在 2026-06-05 L3 首轮改用 `MusicLyricRenderState` / `MusicLyricRenderObserver` 订阅去重后的 active 行与 seek 目标行。父 `ScrollView` 不再直接订阅每 tick 的 `clockState.lyricTime`；逐字进度进入 `MusicActiveKaraokeLyricLine` 的 `MusicLyricActiveLineProgressObserver`，按 `wordProgressBucket` 只更新 active line。
- 封面 glow 主路径已在 2026-06-06 改为 `AlbumBlurredCoverGlowLayer` + `AlbumCoverGlowBakeCache` 的 image-based 三层透明贴图：后台先按真实可见封面裁切、校正 Core Image Y 轴、用邻近边缘像素向外延展，再对 near/mid/far 分别混入不同强度的大尺度低频色场，最后叠加柔化圆角封面 alpha mask 与径向尾部衰减。2026-06-09 起，glow bake 叠加亮度门控 `lightEmitterMask`，近黑区域只形成深度阴影，不再被当作发光色源；`AlbumColorPalette.lightEmitterWeight` 也降低近黑采样权重。第二轮把 near/mid/far 改成更大 blur/reach、更低 alpha 和更低饱和，范围略扩但观感更软。运行时只合成缓存贴图并调 opacity / blend / scale，不再执行三层 SwiftUI 大半径 blur/mask，也不要恢复整图全局 blur 后外扩的 glow。当前 `AlbumGlowBakeKey.bakeVersion` 为 16。
- 旧封面发光分叉已删除：`AlbumSoftBloomGlow`、`AlbumPhysicalEdgeGlow`、`AlbumDirectionalGlowBake`、`AlbumArtworkGlowLayer` / `LowResolutionArtworkGlowLayer` 不再存在。后续不要恢复这些历史路径。
- `MusicExpandedArtwork` 已在 2026-06-05 阴影迁移轮次移除三层 SwiftUI `.shadow`，改由 `MusicExpandedArtworkShadowLayer` 的 3 个 `CALayer` 承载。2026-06-06 image-based glow 重构后，彩色 shadow 已降为轻量贴地色影，主发光只来自 artwork 复制图；黑色深度阴影继续设置 `shadowPath`、`shouldRasterize`、`rasterizationScale`。
- `MusicMiniSpectrumLayerView` 已在 2026-06-05 局部优化轮次改为固定最大高度的 `CAGradientLayer`，当前实现使用底边锚点和 `transform.scaleY` 自底向上缩放；颜色只在 accent/isPlaying 变化时刷新，bands 已做 bucket 去重。

## 2026-06-10：底板/发光/玻璃/舞台光整体重构

状态：已完成代码、6 变体双模式窗口截图验收、`MediaLibChecks` 与 DMG 打包。

本轮是对过去 20+ 轮参数微调路线的整体替换，核心判断：旧渲染链路（30+ 层渐变/光斑互相叠加 + 满窗模糊封面图盖住 Metal 底板）已无法靠调参收敛，需要换数学模型：

- L0 shader 重写：底板唯一色源 = 封面低频高斯颜料场纹理；两个固定旋转/镜像采样按大尺度噪声做【区域选择】（绝不 RGB 平均，互补色平均=灰泥），方向解耦但色系严格同源；近黑 HSV value 门控溶进中性底；HSV 舒适带（浅 V 0.70–0.895 / S≤0.42）取代层层叠加的 veil/tonemap/chroma 博弈；切歌双纹理 0.8s 交叉淡入（30fps 限时重绘后回到按需绘制暂停）。
- 删除 `AlbumFullCoverBackdrop`（满窗模糊封面图，违背"底板不像放大封面"）与旧三层 glow 死代码（约 820 行）。
- 封面发光 = `AlbumGlowBlurCoverBaker` 重写：边界色外延（clampedToExtent）→ 高斯扩散 → SDF 圆角方形羽化（22% 贴边平台 + power 1.05 长尾）×亮度门控（CIMaximumComponent，黑不发光）；画布边长 = coverSide × 几何 reach（触达歌词卡左缘/控制栏 + overshoot）。⚠ 灰度遮罩必须用 `CIBlendWithMask`；`CIBlendWithAlphaMask` 读 alpha 通道、灰度图 alpha 恒 1 会令羽化失效（本轮踩坑）。
- 玻璃受光彩色化：`FloatingLyricsGlass` 顶高光/发丝描边与 `LyricsCardEffectLayer` 的 tinted 比例整体向专辑色偏移，白只剩薄镜面；浅色 materialOpacity ↑ 到 0.42–0.46 让真实模糊可读。
- 舞台光（`LyricCenterSpotlight`/`LyricStageLightLayer`）峰值 ↓1/3、白核减半再减、blur 18→26。

后续调参入口：shader 顶部 `kLight*/kDark*/kInkGate*/kPool*/kBlob*` 常量；glow 烘焙的 plateau/power/saturation；`MusicGlassSurfaceRole.materialOpacity`。

## 2026-06-09：歌词与玻璃第三轮微调

状态：已完成代码与文档更新；需要后续在真实前台窗口用双语歌词、浅蓝低彩封面、黑底少量亮部封面继续截图复核。

本轮已修复 / 实现：

- `LyricSourceParser.coalescedTimestampLines` 增加脚本特征判断：同时间戳组里若出现含假名日文原文与纯汉字中文翻译，保留为相邻独立行，不再合并成一行；完全重复文本仍去重。
- `TimedLyricLine.playbackPosition` 对同时间戳组保留文件显示顺序，但在含假名日文原文 + 中文翻译的组里优先选择日文原文作为播放/滚动锚点；`MusicTimedLyricsScrollView` 把同时间戳翻译行作为低模糊伴随行显示，避免翻译行抢当前行高亮。
- 歌词卡 `centerClarity` 进一步降低 material 灰雾和中心白色 fill，上下静态雾面、纹理和发丝高光略增强；内部黑色 shade 下调以减少灰板感。
- `LyricCenterSpotlight` 增加宽椭圆专辑色舞台光，降低白色 specular 占比；`LyricStageLight` 轻提专辑色径向光但继续禁用中部横向硬亮带。
- `MusicPlayerMetalBackdropView` 小幅提高 `paintPalette` saturation/vibrance、role color 饱和上限和 shader `kChromaBoost = 1.10`，保持黑色不发光与亮区高光压缩。

本轮变更点：

- 修改 `Sources/MediaLib/Views/LyricAlignmentService.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerLyricsCardEffectLayer.swift`。
- 更新 `CHANGELOG.md`、`MediaLIB_设计系统标准.md`、`开发说明.md`、`用户使用说明.md`、`MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`handoff.md`。

## 2026-06-09：底板取色与玻璃受光第二轮

状态：已完成第二轮代码收束；真实窗口截图因 Codex 前台/窗口置前限制未完成，以构建和代码路径复核为准。

本轮已修复 / 实现：

- 新增 `--music-player-visual-debug-black` 夹具，用黑底、少量青金紫亮部回归“黑色不能发光”的视觉边界。
- `AlbumCoverGlowBakeCache.lightEmitterMask` 提高近黑亮度门槛，`AlbumColorPalette.lightEmitterWeight` 的最低发光权重下调；`AlbumGlowBakeKey.bakeVersion` 升为 16，避免复用旧 glow bake。
- 封面 glow near/mid/far 和 projected 三层的 blur/reach 略扩，alpha、saturation、contrast 下调，让封面发光范围稍大但更软、更不刺眼。
- `paintPalette` 改为约 38px 低频网格与 15px 柔化，取消 vibrance 回补；`glassifyAlbumColor` 对黑场进入 clean shadow，对灰棕/灰绿风险做 pearl/semantic 回拉。
- Metal shader 的 album field 增加亮度门控的和声偏移：暗部不偏移、不发光，彩色亮部才向语义色场轻微转向，让底板与封面有关但不直接照抄。
- `LyricStageLight`、`LyricCenterSpotlight`、`AlbumLightSpillOverlay` 和 `LyricsCardEffectLayerView` 的前景受光改为专辑色低饱和 tint 主导，白色只保留极薄 specular。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerLyricsCardEffectLayer.swift`。
- 更新 `CHANGELOG.md`、`MediaLIB_设计系统标准.md`、`开发说明.md`、`用户使用说明.md`、`MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`handoff.md`。

## 2026-06-05：回归排查第一轮

状态：已完成第一轮确定性修复；视觉 diff 与长时间采样仍待真实运行验收。

本轮已排查并确认仍存在的问题：

- B-1：`MusicPlayerMetalBackdropView` shader 里 near-field 光组之后才合成整窗 glass，与旧结构 `MusicFullScreenGlassLayer.zIndex(0.4) < AlbumNearFieldIlluminationLayer.zIndex(1.1)` 不一致，近场光会被玻璃层压暗。
- B-2：Metal uniform 仍通过 `metalAlbumGlassBaseNSColor` 并行重算玻璃底色，和 `AlbumColorPalette.albumGlassBaseColor(for:)` 存在维护分叉风险。
- C-1：`MTLCreateSystemDefaultDevice()` 或 renderer/pipeline 初始化失败时没有明确兜底，可能出现背景黑屏。

本轮已修复：

- 将 shader 中整窗 glass 合成块整体移到 near-field 光组之前，保持 staticBackdrop/ambient 在 glass 下、nearField 在 glass 上。
- 删除 `metalAlbumGlassBaseNSColor` 并改为 `NSColor(palette.albumGlassBaseColor(for: colorScheme)).usingColorSpace(.deviceRGB)` 路径生成 RGBA，避免玻璃底色权重分叉。
- 为 `MTKView` 设置 palette `backdropBaseColor` 的 clearColor/layer background；renderer 不可用时使用轻量 fallback command queue 清屏，至少保证不透明专辑底色，不退回旧全屏 SwiftUI 光效。

本轮暂不盲改、仍需实测的项目：

- A-1：`.bgra8Unorm` + 纹理 `.SRGB:false` 与旧 SwiftUI 色彩空间是否逐像素等价，需要旧/新整窗截图 diff 后决定是否切 `_srgb` 与 shader 线性混合。
- A-2：near-field / ambient 的 center 与 reach 需要继续逐项对照旧 `AlbumBackdropLightLayer.configuration(...)`，并 diff 封面四周光晕区。
- A-3 / B-3：`gradient3` / `gradient4` stop 是否肉眼可见，需要 diff 后再决定是否参数化为 `[0, 0.42, 1]` 与 `[0, 0.333, 0.667, 1]`。
- A-4：封面模糊 112px / radius 22 与旧背景模糊半径和采样尺寸是否一致，需要截图局部 diff。
- A-5 / B-5：`LyricsCardEffectLayerView.EffectView.isFlipped == true` 但 `effectLayer.geometryFlipped` 未设，代码上存在 y 镜像风险，需鼠标上半部实测光晕位置后决定。
- A-6 / B-6：`MusicExpandedArtworkShadowLayer` 仍使用 0.22s easeInEaseOut，而封面父层为 `AppMotion.musicPlayer` spring；需播放/暂停实测阴影是否滞后，再决定是否禁用隐式动画改为逐帧跟随。
- A-7：5 分钟 WindowServer RSS 增量、Energy Impact、MTKView 静态暂停/GPU 空闲仍未采样。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift`。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

## 2026-06-05：回归排查第二轮

状态：已完成第二轮确定性优化与死代码清理；仍未做真实窗口截图 diff / 5 分钟采样。

本轮已修复 / 实现：

- D-1：`MTKView` 的底层 `CAMetalLayer.maximumDrawableCount` 设置为 2，减少静态背景常驻 drawable。
- D-2：`draw(in:)` 非主线程回调不再 `DispatchQueue.main.sync`，改为丢弃当前帧并在 MainActor 请求下一帧，避免理论死锁风险。
- B-4：shader 末尾补回旧 `MusicFullScreenGlassLayer` 的 1px 白色 screen 边线，透明度沿用深色 0.08 / 浅色 0.22 并受 `glassIntensity` 控制。
- C-2：因 C-1 已采用纯色 fallback，删除旧 L0 SwiftUI/CA 背景死代码：`AlbumGlassBackdrop`、`MusicFullScreenGlassLayer`、`AlbumBackdropStaticLayer`、`AlbumBackdropLightLayer`、`AlbumNearFieldIlluminationLayer`、`AlbumBlurredArtworkBackdrop`、`LowResolutionArtworkBackdropLayer`。后续 2026-06-06 image-based glow 重构已删除旧 `MusicBackdropBlur` / `AlbumBloomImageBake` 预烤路径。

本轮未处理 / 仍需实测：

- A-1 / A-2 / A-3 / A-4：颜色空间、光晕中心/reach、渐变 stop、封面模糊尺寸与半径仍需新旧截图 diff 后决定。
- A-5 / B-5：歌词卡 pointer wash y 镜像尚未通过真实鼠标位置验证。
- A-6 / B-6：封面阴影 0.22s easeInEaseOut 是否滞后于父 spring 仍需播放/暂停实测。
- A-7：WindowServer、GPU 空闲和 Energy 采样仍未完成。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift`。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

## 2026-06-05：回归排查第三轮

状态：已完成运行探针与可重复 RSS 采样脚本；仍未完成同曲播放 5 分钟展开页验收。

本轮运行观察：

- 启动 debug 版 `MediaLib` 后，进程保持运行；初始采样约为 WindowServer 79MB、MediaLib 350MB。
- 空载 60 秒采样中，WindowServer 从约 78.6MB 到 78.7MB，MediaLib 保持约 350.6MB；未观察到空载持续增长。
- `System Events` 对 debug 进程窗口查询返回 `-10827` 或空窗口信息，当前会话无法自动进入音乐展开页、同曲播放或鼠标移动场景，因此不能把本轮空载结果视为 A-7 验收结论。

本轮新增工具：

- 新增 `scripts/probe_music_player_rss.sh [duration_seconds] [interval_seconds]`。
- 脚本输出 CSV：`timestamp,windowserver_pid,windowserver_rss_kb,windowserver_delta_mb,medialib_pid,medialib_rss_kb,medialib_delta_mb`。
- 在 Codex 沙盒内脚本子进程调用 `ps` 会被拦截；已用沙盒外批准运行验证脚本可读到 WindowServer/MediaLib RSS。

本轮仍需人工或可交互环境继续：

- 展开音乐播放器并播放同一首歌后，运行 `scripts/probe_music_player_rss.sh 300 30` 完成 A-7 的 5 分钟 RSS 曲线。
- 进入展开页后再做 A-5 pointer wash 上/下半部实测、A-6 播放/暂停封面阴影同步观察。
- 截图 diff 仍需旧版/新版成对截图或可控回退分支，当前未建立逐像素 diff 输入。

本轮变更点：

- 新增 `scripts/probe_music_player_rss.sh`。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

## 2026-06-06：目标视觉重构轮次

状态：已完成代码重构、构建和 `MediaLibChecks`；仍需要真实窗口截图对照图 3/4 做肉眼验收。

本轮实现：

- 取色：`AlbumColorPalette` 提高多色封面的主/辅/强调三色参与度，降低中性白雾注入；低彩/白灰封面改用 `neutralAverage` 保留真实中性主调，只有彩色面积占比足够明确时才允许极弱色相提示，避免少量暖色噪声把底板推成粉/肉色。
- L0：`MusicPlayerMetalBackdropView` 降低 white veil / glass white，增强专辑三色 mesh、ambient 与 near-field 光，保持 `softTonemap`、受控 `controlledPlus` / `controlledScreen` 和防纯白 clamp，目标是绚丽但不过曝。
- 封面：`MusicExpandedArtwork` 的播放态封面视觉尺寸略收，暂停态仍后退缩小；image-based glow 画布和 far 层继续扩大，彩色封面能染到歌词卡左边缘，白/灰封面保持扩散范围但通过低 alpha 与压暗避免过曝。
- glow：`AlbumBlurredCoverGlowLayer` 改为通过 `AlbumCoverGlowBakeCache` 后台预烘焙 artwork 原图的三层 image-based glow；烘焙时先校正 Core Image Y 轴，并从真实可见封面的邻近边缘像素向外扩散，避免顶/底颜色颠倒或封面另一侧颜色污染局部边缘。near / mid / far 分别使用 plusLighter / overlay / screen，并用 `vibrancy`、亮度压暗和 `maxAlpha` clamp 控制白色封面过曝。运行时只做透明贴图合成，避免恢复三层 SwiftUI 大 blur。旧 `AlbumBloomImageBake` 预烤单图路径已删除。
- L1/L2：`FloatingLyricsGlass` 降低灰膜和白雾，歌词卡/控制栏/收起按钮继续使用同一 `.withinWindow` 局部玻璃；歌词卡左缘 `AlbumLightSpillOverlay` 改为主/辅/强调色多段衰减，边缘浸染更接近封面发光照亮空间。
- 歌词：未改逐字播放算法，只保留现有 L3 降订阅结构和浏览时解除远离行模糊；歌词卡上下边缘加厚雾化，中间保持清晰。
- 清理：删除旧 glow 分叉，避免后续误回退到单色 halo、方向光试验层或低分辨率调色板 glow host。

本轮仍需真实环境验收：

- 用图 3/4 同类封面截图确认底板是否足够绚丽且不脏、白封面是否不过曝、封面光是否刚好染到歌词卡左缘。
- 播放/暂停时观察封面缩放与光晕熄灭是否连续，不应出现远端光残留或硬切。
- 如需量化性能，继续在展开播放同曲后运行 `scripts/probe_music_player_rss.sh 300 30`，而不是用 build 通过替代性能结论。

## 2026-06-08：附件方案收敛与浅色截图验收

状态：已完成浅色 debug 窗口截图、30 秒 RSS 快采、代码/文档收敛；暗色截图仍受当前 Codex 前台窗口控制限制。

本轮实现：

- `MetalAlbumBackdropView` 的低频封面颜料场改为约 48px 网格并做轻饱和 / vibrance 回补，让底板更像“专辑颜料场”而不是可辨识封面大 blur。
- shader 出图端将 `kChromaBoost` 收到 1.28，白色 veil 只作为空气感闸控，仍保持最终 clamp 低于纯白。
- `MusicExpandedLyricsPanel` 在无歌词、纯音乐或获取失败时显示居中舞台空态，右上角保留获取歌词入口；获取中图标呼吸动画尊重 Reduce Motion。
- 浅色四象限 debug 截图确认：标题栏区域连续无白条，背景来自上红/右绿/下蓝/左黄方向色，右侧歌词卡中心聚焦成立；截图中远行模糊偏重，故仅把额外边缘位置 blur 从 2.0 收到 1.35，保留基础距离 blur 分段。
- 30 秒快速 RSS 采样：WindowServer 约 +0.1MB，MediaLIB 约 +1.0MB。该样本只说明短时展开页无明显持续增长，不能替代后续 5 分钟播放采样。

仍需下一轮：

- 让暗色 debug 窗口稳定置前或通过 CGWindowID 截图，补齐深色截图验收。
- 用真实冷色、暖黄、奶油/低彩三类封面做截图，而不是只用四象限测试图。
- 如需性能结论，运行 `scripts/probe_music_player_rss.sh 300 30` 做 5 分钟同曲播放曲线。

## 2026-06-09：底板取色、黑色发光与玻璃受光重构

状态：已完成第一轮代码和文档收束；构建、检查和 DMG 打包在本轮交付前重新执行。真实音乐库截图仍应作为下一轮微调依据。

本轮目标来自用户反馈：黑色不应发光、底板仍偶发不像来自封面、玻璃受光偏白、底板与封面方向太一致、封面 glow 范围略小、底板过艳刺眼且偶发脏灰。

本轮实现：

- 取色权重：`AlbumColorPalette` 的采样增加 `lightEmitterWeight`，近黑/低亮色降低发光参与度；封面 glow 烘焙增加 `lightEmitterMask`，黑色区域只保留遮蔽和深度，不再作为向外扩散的 emission。
- 封面 glow：略微扩大封面发光覆盖和 feather，但同步降低 saturation、brightness、opacity 与 `maxAlpha`，让范围变宽但边缘更柔，避免白/浅封面过曝和深色封面发灰光。
- L0 Metal 底板：`paintPalette` 保持低频高斯色场，shader 通过 `harmonicShift` 对 primary/secondary/accent 做小幅色相和声变换，再与 album field 计算混合；底板颜色与封面同源但方向不同，切歌后靠统一 shader 数学自然过渡，而不是另起随机渐变。
- 观感收敛：`kGlowStrength`、`kWhiteVeilStrength`、`kChromaBoost` 和最终 clamp 全部降低；`glassifyAlbumColor` 不再把暗区抬成亮光，亮区进一步减彩，避免底板比封面更艳、信息量过大或显脏。
- 前景玻璃：`LyricCenterSpotlight`、`FloatingLyricsGlass` 上沿和 `AlbumLightSpillOverlay` 改为以专辑色光为主、白色只作为极薄 specular；玻璃底材质继续保持中性，不把专辑色烘成实底。

后续观察点：

- 用真实黑底、深蓝/深红、奶油低彩、强多色四类封面截图，观察黑区是否还在外发光、底板是否仍有“不像封面”的错觉。
- 若底板仍偏艳，优先继续降 `kChromaBoost`、`kGlowStrength` 和亮区 saturation ramp；若显脏，优先调整 `glassifyAlbumColor` 的暗部清洁与 `paintPalette` softening，不要新增全屏 SwiftUI blur/material。
- 若玻璃仍显白，优先继续降低白色 specular alpha，提高专辑色受光占比；不要把前景玻璃底材质改成专辑色实底。

## 目标四层架构

### L0：MetalAlbumBackdropView

新增 `MetalAlbumBackdropView`，优先使用 `MTKView`；如需要更细粒度 layer 管理，可用 `CAMetalLayer` 包装，但渲染策略保持一致。

迁移范围：

- 替换顶层 `AlbumGlassBackdrop`、`MusicFullScreenGlassLayer`、`AlbumNearFieldIlluminationLayer`。
- shader 内完整迁移当前背景视觉数学：`backdropBaseColor`、模糊封面纹理、全部 `LinearGradient`、全部 `RadialGradient`、mesh 多色光斑、`plusLighter`、`screen`、ambient light、staticBackdrop light、nearField light。
- 不减少光斑数量，不降低透明度层次，不改变颜色位置。当前固定 anchor 与 center offset 要作为统一参数表进入 renderer，例如 mesh 三点 `(0.86, 0.16)`、`(0.92, 0.88)`、`(0.10, 0.92)`，静态光层相对 `albumLightCenter` 的 5 radial + 1 beam，ambient 的 3 radial，nearField 的 3 radial + 1 beam。

实现安排：

- 新增 renderer 文件建议：
  - `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift`
  - `Sources/MediaLib/Views/MusicAlbumBackdropRenderer.swift`
  - `Sources/MediaLib/Views/MusicAlbumBackdropShaders.metal`
- 建立 `MusicAlbumBackdropUniforms`，包含 view size、backing scale、colorScheme、palette RGBA、albumLightCenter、artwork opacity、glass intensity、static/ambient/nearField 开关、animation phase、reduceMotion。
- 建立 `MusicAlbumBackdropLightSpec` 参数表，把现有 SwiftUI/CA 的 radial、linear、beam 数学转成 shader 函数。blend 函数固定为 `plusLighter = min(dst + src, 1)`、`screen = 1 - (1 - dst) * (1 - src)`，以截图一致性优先。
- 低分辨率模糊封面继续复用 `ArtworkImageCache` 和 `MusicAlbumBackdropImageBlur` 的思路，但输出为 `MTLTexture`；切歌时保留上一张纹理直到新纹理就绪，避免颜色断层。
- 静止模式：`MTKView.isPaused = true`，`enableSetNeedsDisplay = true`。palette、纹理、布局、colorScheme、reduceMotion、窗口可见性等参数变化时只 `setNeedsDisplay` 画一帧，然后重新暂停。
- 动态模式：后续扩展时只通过 uniforms 和 shader 函数增加动态，不再回到 SwiftUI 顶层堆全屏 `RadialGradient` / `LinearGradient` / `.blendMode` 动画。默认 `preferredFramesPerSecond = 30`。
- 生命周期暂停：监听窗口遮挡 `NSWindow.didChangeOcclusionStateNotification`、应用后台 `NSApplication.willResignActiveNotification`、重新激活、窗口移出屏幕、`reduceMotion`。不可见、后台、reduceMotion 或静态模式下停止连续 draw。

### L1：真实玻璃层

保留 `NSVisualEffectView` 作为歌词卡、控制栏、按钮、弹层的真实玻璃来源。

执行原则：

- `AppKitVisualEffectBackground` 默认 `blendingMode` 改为 `.withinWindow`。
- 播放器页面禁止 `.behindWindow`，避免 WindowServer 为整窗或大面板持有桌面模糊副本。
- 不用静态半透明白板替代真实玻璃。
- 不尝试用 Metal 复刻 `NSVisualEffectView`。Metal 只负责背景和独立动态效果层，不负责系统玻璃采样。
- `FloatingLyricsGlass` 保留真实 material、专辑 tint、静态描边和阴影；移除内部动态 pointer wash。

### L2：LyricsCardEffectLayer

新增独立 `LyricsCardEffectLayer`，用于歌词卡、控制栏、收起按钮等局部 rounded rect 动态效果。

迁移范围：

- 移除 `FloatingLyricsGlass` 内部 `MusicInheritedGlassPointerWash` overlay。
- pointer wash、边缘流光、扫光、节奏辉光等动态效果进入 L2。
- `LyricCenterSpotlight`、`LyricEdgeTintOverlay`、`LyricCardEdgeDepthOverlay` 可先按“静态效果是否造成 SwiftUI 全卡重绘”分批迁移；动态优先迁移，静态可保留到 L2 第二阶段统一。

实现安排：

- 新增 `LyricsCardEffectLayerView: NSViewRepresentable`，初版可用 `CALayer/CAGradientLayer/CAShapeLayer`，接口按 Metal uniform 设计，后续可替换为 `CAMetalLayer` 而不改 SwiftUI 调用点。
- 鼠标移动由 AppKit tracking area 直接写入 layer/coordinator 的 pointer uniform，只调用局部 layer `setNeedsDisplay` 或更新局部 shader buffer，不写 SwiftUI `@State`，不触发歌词卡 body 重建。
- 所有效果必须被 card/control 的 rounded rect mask 裁剪，合成范围只在局部 bounds 内，不允许全屏 blend。
- L2 需要统一 `cornerRadius`、palette、colorScheme、intensity、reduceMotion、isActive/visible。动态开关默认静止，后续节奏辉光可在 `preferredFramesPerSecond = 30` 下局部启停。

### L3：SwiftUI 歌词文本层

歌词文本、排版、逐字高亮、点击 seek、可访问性继续保留 SwiftUI，但高频状态要拆小。

实现安排：

- 新增 `MusicLyricRenderState`，至少包含：
  - `activeLineIndex`
  - `wordProgressBucket`
  - `seekPhase/revision`
  - `isBrowsing`
  - `timingSource` 或必要的展示元数据
- `activeLineIndex` 变化才触发 `ScrollViewReader.scrollTo`。
- `wordProgressBucket` 变化只更新 active line，不让整个 `ScrollView` 每 0.18s 重算。
- 普通播放中 `clockState.lyricTime` 不直接作为 `MusicTimedLyricsScrollView.body` 的全局输入；由 observer 将时间映射为去重后的 render state。
- 对普通 LRC 的 bucket 要按可见精度节流，例如逐字进度 60 或 80 桶；增强 LRC 片段时间戳可按片段 index + 局部进度 bucket 去重，确保视觉连续但不把每 tick 传播给所有行。
- 非 active 行保持静态 `Equatable` 输入；active 行可拆为独立 `MusicActiveLyricLineView` 或行级 observer，让进度变化只命中该行。

## 局部性能优化计划

### 1. AlbumSoftBloomGlow 预烤

- 在 `loadBloom()` 的后台任务中把 `saturation(1.35)` 和 `bloomMask` 的径向 alpha 蒙版烤进 `NSImage`。
- 保留当前 glow 范围、强度、颜色：低分辨率模糊半径、`frame(width: posterSize * 3.3)`、`glowScale`、`glowOpacity`、`.blendMode(.plusLighter)` 不改变。
- fallback 无封面路径也要预渲染同等范围的多色 glow，不能退回运行时 `.blur` 或削弱光斑。

### 2. MusicExpandedArtwork 阴影迁移

- 新增 `MusicExpandedArtworkLayerHost` 或局部 shadow wrapper，把三层 SwiftUI `.shadow` 改成 3 个 CALayer shadow。
- 每个 shadow layer 设置稳定 `shadowPath`，路径匹配封面 rounded rect。
- 设置 `shouldRasterize = true`，`rasterizationScale = window backingScaleFactor`。
- 保留当前动画参数：
  - primary glow：`opacity 0.0 -> 0.34`、`radius 4 -> 22`、`offsetY 2 -> 12`
  - accent glow：`opacity 0.0 -> 0.18`、`radius 3 -> 14`、`offsetY 1 -> 7`
  - depth shadow：`black opacity 0.18 -> 0.24`、`radius 18 -> 22`、`offsetY 16 -> 12`
- 播放/暂停仍由 `coverVisualProgress` 与 `glowVisualProgress` 驱动，但只更新 layer 属性，不触发封面大块 SwiftUI shadow 重新合成。

### 3. MusicMiniSpectrumLayerView 优化

- bar 初始化为最大高度，frame 高度不随音量变化。
- `anchorPoint = CGPoint(x: 0.5, y: 1.0)`，position 固定在底部。
- 播放时只改 `layer.transform = CATransform3DMakeScale(1, scaleY, 1)`。
- `bar.colors` 只在 `accentColor` 或 `isPlaying` 变化时更新。
- 对 `audioSpectrumBands` 做 bucket 去重，相同 bucket 不提交 CA 更新。建议把每个 band 映射为 0...24 或 0...32 的整数桶，并缓存上一帧桶数组。

## 分阶段执行

### Phase 0：基线与截图

- 记录当前音乐展开页静态模式 WindowServer RSS、Energy Impact、MTKView/CA 刷新情况。
- 固定一首有封面的本地音乐，截图桌面/窗口尺寸、浅色/深色、播放/暂停、reduceMotion 四组状态。
- 建立截图 diff 方法；无专用工具时至少保留同尺寸 PNG 并用脚本计算平均差、最大差和关键区域差。

### Phase 1：L0 Metal 背景落地

- 新增 `MetalAlbumBackdropView` 和 shader，不接入动态，先完全复刻静态视觉。
- 用单个 Metal draw 替换 `AlbumGlassBackdrop`、`MusicFullScreenGlassLayer`、`AlbumNearFieldIlluminationLayer`。
- 接入按需绘制：静止暂停、参数变化打一帧、窗口遮挡/后台/reduceMotion 暂停。
- 完成与 Phase 0 截图对比，修正色彩、位置、混合和透明度。

### Phase 2：L1/L2 拆分歌词卡与控制栏效果

- 修改 `AppKitVisualEffectBackground` 默认 `.withinWindow`，播放器调用点审计禁止 `.behindWindow`。
- 从 `FloatingLyricsGlass` 移除 `MusicInheritedGlassPointerWash`。
- 新增 `LyricsCardEffectLayerView`，先迁移 pointer wash 和边缘提亮；再迁移扫光/节奏辉光扩展点。
- 验证鼠标移动只更新 L2 layer/coordinator，不触发 `MusicExpandedLyricsPanel` 或 `MusicTimedLyricsScrollView` body 高频重建。

### Phase 3：L3 歌词 render state 下沉

- 新增 `MusicLyricRenderState` 与 observer。
- 将 active line 选择、seek 展示、逐字进度 bucket 去重后发布。
- `activeLineIndex` 变化触发滚动；`wordProgressBucket` 只影响 active line。
- 保留 seek 行定位、用户浏览暂停、点击歌词 seek、普通 LRC/增强 LRC 高亮行为。

### Phase 4：局部性能收口

- 预烤 `AlbumSoftBloomGlow` saturation 与 mask。
- 迁移 `MusicExpandedArtwork` 三层 shadow 到 CALayer。
- 优化 `MusicMiniSpectrumLayerView` transform 更新和 bucket 去重。

### Phase 5：验收与打包

- 运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`。
- 运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`。
- 重新生成 `dist/MediaLib.dmg`。
- 记录 WindowServer RSS 目标：默认静态背景模式从约 500M 降到 80M 到 150M；MTKView 静止时不持续刷新；Energy Impact 不持续升高。
- 记录视觉验收：背景颜色、光斑位置、plusLighter/screen 观感、玻璃质感、封面 bloom、歌词卡高光与改造前一致。

## 禁止回退项

- 禁止使用整页 `drawingGroup` 作为替代。
- 禁止删除光效、减少光斑、降低透明度层次或改变颜色位置。
- 禁止关闭真实玻璃。
- 禁止用静态白板替代 `NSVisualEffectView`。
- 禁止让鼠标移动、歌词时间、频谱刷新驱动整个播放器 body 重建。
- 禁止重新在 SwiftUI 顶层堆叠全屏 `RadialGradient`、`LinearGradient`、`blendMode` 动画。

## 每轮进度记录

### 2026-06-05：封面物理边缘发光与侧栏瞬时反馈

状态：已完成本轮代码修改；本轮针对用户反馈“发光只有一圈、不像封面真的发光”、侧栏图标慢慢变白/恢复、选中效果未跟随系统配色。

本轮判断：

- 前一轮虽然提高了发光可见性，但仍依赖调色板色和描边 halo，视觉上容易成为“套一圈光”，不是封面本身的边缘在向外发光。
- 真正接近物理发光的局部方案应把封面边缘像素当作 emission source：上边缘向上扩散、下边缘向下扩散、左/右边缘向对应方向扩散，并保留四角混合。
- 侧栏图标选中态不应使用过渡动画；选中底色也不应该被应用自定义主题 tint 强行覆盖系统强调色。

本轮变更点：

- 新增 `AlbumGlowRGB`、`AlbumEdgeGlowSample`、`AlbumEdgeGlowSampler`，用 Core Image `CIAreaAverage` 从封面上/下/左/右和四角采样方向色，并只做饱和度/亮度清洁，不旋转 hue。
- 新增 `AlbumDirectionalGlowBake`，把封面四边像素向外复制衰减并高斯扩散为局部 `NSImage` glow 贴图，保留边缘颜色变化；`AlbumPhysicalEdgeGlow` 同时叠加该贴图和四边/四角方向光场。
- `MusicExpandedArtwork` 移除上一轮的两层描边 halo，改挂 `AlbumPhysicalEdgeGlow`，继续局部裁在封面背景层，不回到全屏 SwiftUI blend。
- `PlayfulSymbolIcon` 对 selected 禁用隐式动画；`ContentView.sidebarRow` 禁用选中事务动画；侧栏 `List.tint` 改为 `NSColor.controlAccentColor`，让选中高亮跟随 macOS 系统强调色。

验证：

- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` 通过。
- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks` 通过。
- 尚未重新进入展开页截图复核实际 glow 强度；这轮代码结构已改成边缘像素发光，下一轮应以真实窗口截图为准微调 reach/opacity/blur。

### 2026-06-05：封面 glow 可见性与侧栏响应修正

状态：已完成本轮代码修改；本轮针对用户截图反馈的“发光效果没做出来”、专辑边缘缺少鼠标响应，以及左侧栏换色/图标选中还原过慢。

本轮判断：

- 上一轮已经把 bloom 从拉伸模糊图改为透明画布内的真实封面扩散，解决了白化和方向不对应的根因，但在偏亮/偏蓝封面下预烤 glow 被 L0 背景和封面阴影吞掉，肉眼会像“没有做出来”。
- 继续单纯提高预烤图 opacity 容易回到过曝；因此改成三段结构：预烤方向色负责颜色对应，贴边 halo 负责显性边缘发光，外扩 halo 负责柔和距离衰减。
- 左侧栏慢主要来自主题切换后部分 `List`/图标继续复用旧渲染与图标自身缺少快速 selected 动画；本轮让侧栏跟随 `themeRevision` 重建关键视图，并把 selected 动画统一压短。

本轮变更点：

- `MusicExpandedArtwork` 的封面背景从单层 `AlbumSoftBloomGlow` 改为 `AlbumSoftBloomGlow + 近边 plusLighter 描边 halo + 外扩 screen 描边 halo`；近边层更贴封面，外扩层更宽更柔，均按 `glowStrength` 和封面 palette 控制。
- `AlbumSoftBloomGlow` 的预烤图运行时补一层同色柔影，并提高 light/dark 播放态 opacity，让方向性色不再被背景完全吃掉，但不恢复大面积白色叠加。
- 专辑封面 `PosterImage` 接入 `pointerLiquidEdge(cornerRadius:tint:intensity:)`，让封面边缘响应鼠标局部光效。
- `AppMotion.sidebarSelection` 调整为 0.055s；`PlayfulSymbolIcon` 显式绑定该动画，侧栏 `List` 和图标跟随 `appState.themeRevision` 刷新。

验证：

- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` 通过。
- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks` 通过。
- 尚未在真实展开页重新截图确认 glow 强度；下一轮需要进入音乐展开界面点击播放，观察贴边 halo 是否足够明显、外扩 halo 是否柔和且不过曝。

### 2026-06-05：封面 glow 重做与展开面板精调

状态：已完成本轮代码修改；本轮针对用户截图反馈的封面发光白化/方向不对应、底色脏、按钮渐变、配色名称、换色滞后和展开面板观感。

本轮工作：

- `AlbumBloomImageBake` 重做：在 720px 透明画布中心按真实封面比例放置 artwork，再做色彩控制、54px 高斯扩散和圆角外距 alpha 蒙版；运行时不再把小封面拉伸成整块 glow，四周颜色应对应封面边缘方向。
- `AlbumSoftBloomGlow` 主路径改用 `.screen` 叠加并降低 light/dark opacity，减少 `.plusLighter` 导致的白化。
- `AlbumColorPalette.backdropBaseColor` / `albumGlassBaseColor` 改用 HSB 清洁约束，只限制亮度和饱和度，不旋转 hue，避免底色取到脏灰/脏棕。
- `LiquidGlassButtonStyle(prominent:)` 去掉强调按钮渐变填充和渐变描边，改为纯主题色实底。
- `AppThemePreset.displayName` 改为统一两字名称：晴蓝、云青、靛蓝、藤紫、桃粉、暖橙、湖青、新绿、石墨、自定。
- 配色切换统一走 `publishThemePaletteChange()`，自定义 ColorPicker 也递增 `themeRevision` 并刷新窗口；`ContentView` 的换色遮罩缩短。
- `FloatingLyricsGlass` 轻微降低灰膜/专辑染色，提高上沿高光和发丝描边，改善展开面板玻璃观感。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift`。
- 修改 `Sources/MediaLib/Views/AppColors.swift`。
- 修改 `Sources/MediaLib/Views/ContentView.swift`。
- 修改 `Sources/MediaLib/App/AppState.swift`。
- 修改 `Sources/MediaLibCore/Models/AppSettings.swift`。
- 更新 `CHANGELOG.md`、`handoff.md` 和本专项文档。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未做真实窗口截图 diff；下一轮应在音乐展开页播放态肉眼确认 glow 方向和底色清洁度。

### 2026-06-05：系统配色拆分与精调

状态：已完成全局配色预设第二轮精调；本轮不改音乐 L0/L2/L3 架构，仅延续用户反馈中的 Apple 审美配色专项。

本轮工作：

- `AppThemePreset` 新增系统靛蓝、系统紫、系统橙、系统绿；旧 `ocean/rose/mint/graphite` raw value 保留并重新定位为系统青、系统粉、系统湖水、系统石墨，避免历史设置解码失败。
- 精调所有预设 seed：底色统一为低饱和系统浅灰或轻微色温底，强调色采用 Apple 常用 system blue / cyan / indigo / purple / pink / orange / teal / green / gray 方向，左上光线改为柔和浅色 wash。
- 更新 `ResolvedAppTheme.classic` 与自定义配色 ColorPicker fallback，使默认自定义入口与新的系统蓝默认一致。
- 调整 `AppColors.ResolvedColorSet` 派生数学：大面积背景/卡片/输入框更中性，sidebar/card wash、glass tint、solar edge 更轻；图标/强调渐变减少过大的 hue shift；强调按钮底部压暗保证白字对比。

本轮变更点：

- 修改 `Sources/MediaLibCore/Models/AppSettings.swift`。
- 修改 `Sources/MediaLib/Views/AppTheme.swift`。
- 修改 `Sources/MediaLib/Views/AppColors.swift`。
- 修改 `Sources/MediaLib/Views/SettingsView.swift`。
- 更新 `CHANGELOG.md`、`handoff.md` 和本专项文档。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。

### 2026-06-05：音乐展开页过曝与通用 UI 第一轮修正

状态：已完成第一轮代码修正；主要针对用户截图中的封面/背景过曝、配色预设审美、侧栏点击反馈和获取类按钮。

本轮工作：

- 下调 L0 Metal shader 中 staticBackdrop、ambient light、nearField light 的 alpha 参数，保持光斑数量、中心和 reach 不变，仅把 screen 叠加强度从过曝区间收回到柔和专辑色区间。
- 下调 `MusicExpandedArtwork` 的封面 bloom opacity、边缘彩色描边 opacity，以及 `LowResolutionArtworkGlowLayer` 的多色径向光和 ring stroke 强度，避免 `.plusLighter` 与背景叠加后 clip 成白光。
- `LiquidGlassButtonStyle(prominent:)` 改为主题蓝色玻璃填充 + 白色文字 + 轻高光/轻投影，替换旧白底蓝字获取类按钮。
- `AppThemePreset` 保留 raw value 兼容旧设置，但展示名和 seedHex 改为系统蓝、Aqua、Apple 粉、湖水绿、石墨等 Apple 常用色方向。
- 新增 `AppMotion.sidebarSelection`，左侧栏目录行选中态使用 0.10s ease-out 事务反馈。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift`。
- 修改 `Sources/MediaLib/Views/AppColors.swift`。
- 修改 `Sources/MediaLib/Views/ContentView.swift`。
- 修改 `Sources/MediaLibCore/Models/AppSettings.swift`。
- 更新 `CHANGELOG.md`、`handoff.md` 和本专项文档。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未在真实音乐展开页截图复核新光强；下一轮应进入音乐展开界面点击播放后确认封面 glow 是否仍偏曝。

### 2026-06-05：封面阴影方向修复（评审修正轮）

状态：评审「MusicExpandedArtwork 阴影迁移」「L3 render state 首轮拆分」「L3 滚动稳定校准」「Album bloom 预烤」四个已完成轮次的代码，发现并修复一处方向错误；其余判定正确。

问题（封面阴影方向）：`MusicExpandedArtworkShadowLayer.ShadowView` 是**非翻转** NSView（y 向上）。macOS 上 CALayer 的 `shadowOffset` 正 y 会把阴影投向【上】，而被替换的原 SwiftUI `.shadow(y: 正值)` 是投向【下】。迁移时三层阴影都用了正 `shadowOffset.height`（primary 2→12、accent 1→7、depth 16→12），导致阴影方向整体翻转——尤其黑色深度/落地阴影本应在封面下方，却投到了上方。

依据：同文件 `MusicMiniSpectrumLayerView.SpectrumBarsView`（同为非翻转 NSViewRepresentable）以 y-up、y=0 对应屏幕底边工作（频谱条自底向上），证实非翻转表示层无 SwiftUI 垂直翻转，正 `shadowOffset.height` 即向上。

修复：三层阴影的 `shadowOffset.height` 取负，恢复向下投影（保留原插值数值与 radius/opacity）。

复审判定正确（未改）：

- L3 `MusicLyricRenderObserver` / `MusicLyricActiveLineProgressObserver`：render state 与逐字 progress 均 `Equatable` 去重，只在 active/target 行或 `wordProgressBucket` 变化时发布；仅 active 行订阅逐字进度，非 active 行静态——拆分正确，无每 tick 全列表重建。
- L3 `scheduleLyricViewportStabilityCheck`：事件后单个延迟无动画复核任务、有取消与 browsing/index 守卫，不订阅 tick——正确。
- Album bloom 预烤（历史复审）：该轮次的 `AlbumSoftBloomGlow` 方案已在 2026-06-06 被 `AlbumBlurredCoverGlowLayer` 的三层 image-based glow 替代；旧 `AlbumBloomImageBake` / `MusicBackdropBlur` 路径也已删除，保留本段仅作历史背景。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 的 `MusicExpandedArtworkShadowLayer.ShadowView.apply`（三处 `shadowOffset.height` 取负 + 注释说明坐标系）。

本轮验证：

- 已运行 `swift build`，通过。
- 阴影方向仍需真实窗口确认（应在封面下方而非上方）。

### 2026-06-05：L3 歌词滚动稳定校准修正

状态：已完成第六轮代码接入；复核 L3 首轮后，清理了已经不再被触发的旧 tick catch-up 残留，并补上非 tick 的事件后稳定校准。

本轮工作：

- 删除 `MusicTimedLyricsScrollView` 中已无调用的 `synchronizeAutoScrollIfNeeded`、`pendingSeekResync`、`LyricSeekResync` 和旧 catch-up 状态/函数。
- 新增 `lyricViewportStabilityTask` 与 `scheduleLyricViewportStabilityCheck`。
- active line 变化、seek 对齐、歌词内容变化、用户结束浏览后，只执行有限次延迟无动画居中复核，避免 `ScrollViewReader` / `LazyVStack` 同帧未完成时视口偶发没跟上。
- 稳定校准不订阅 `lyricTime` tick，不恢复父 `ScrollView` 每 0.18s 重建；仍以 active line / seek phase / seek target 事件为触发源。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 中 `MusicTimedLyricsScrollView` 的滚动稳定校准路径。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

本轮修改的代码范围：

- 仅 L3 歌词滚动事件后校准。
- 未修改 L0 Metal shader，未修改 L1/L2，未修改 active 行逐字 progress observer，未修改封面与频谱优化。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未做播放器真实窗口歌词 seek、拖动浏览、逐字高亮截图 diff 或 Instruments 重建频率采样。

下一轮建议：

- 进入真实运行验证：启动 MediaLIB，打开音乐展开页，采样 WindowServer RSS、MTKView 静止刷新、歌词 seek/拖动浏览/逐字高亮。

### 2026-06-05：L3 歌词 render state 首轮拆分

状态：已完成第五轮代码接入；L3 首轮把歌词滚动父层和 active 行逐字进度拆开。后续仍需真实窗口确认 seek、拖动浏览、自动居中和逐字高亮观感。

本轮工作：

- 新增 `MusicLyricRenderState` 与 `MusicLyricRenderObserver`，由 observer 内部接收 `controller.$lyricTime` / `controller.$seekState`，但只在 active 行、seek phase/revision 或 seek 目标行变化时发布给父 `MusicTimedLyricsScrollView`。
- `MusicTimedLyricsScrollView` 不再直接持有 `MusicLyricClockObserver`，父层 body 不再每 0.18s 因 `clockState.lyricTime` 重算整个 `ScrollView` / `ForEach`。
- 新增 `MusicActiveKaraokeLyricLine` 与 `MusicLyricActiveLineProgressObserver`，只有 active line 子视图订阅逐字进度。
- active line progress 使用 `wordProgressBucket` 去重；bucket 变化才发布 active 行高亮状态，非 active 行保持静态 `KaraokeLyricLine`。
- seek 预览仍保留 `.fullLineDuringSeek`，父层继续响应 seek phase/revision/目标行变化完成无动画对齐。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 中 `MusicTimedLyricsScrollView`。
- 新增同文件内局部类型 `MusicLyricRenderState`、`MusicLyricSeekRenderState`、`MusicLyricRenderObserver`、`MusicActiveKaraokeLyricLine`、`MusicLyricActiveLineProgressState`、`MusicLyricActiveLineProgressObserver`。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

本轮修改的代码范围：

- 仅 L3 歌词 render state / active 行 progress 订阅路径。
- 未修改 L0 Metal shader，未修改 L1 真实玻璃，未修改 L2 歌词卡 effect layer，未修改封面 bloom / 阴影 / 频谱。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未做播放器真实窗口歌词 seek、拖动浏览、逐字高亮截图 diff 或 Instruments 重建频率采样。

下一轮建议：

- 打开音乐展开页做 L0/L2/L3 综合视觉与性能确认：截图 diff、WindowServer RSS、MTKView 静止刷新、歌词 seek/逐字进度。
- 若实测仍有歌词 tick 造成父层重建，再继续把 active 行高亮下沉到 CALayer / Text renderer。

### 2026-06-05：MusicExpandedArtwork 阴影迁移

状态：已完成第四轮代码接入；局部性能优化中的 `MusicExpandedArtwork` 三层 SwiftUI shadow 已迁移到 CALayer。至此三项局部性能优化已完成首轮代码接入，L3 `MusicLyricRenderState` 仍待后续轮次。

本轮工作：

- 新增 `MusicExpandedArtworkShadowLayer`，使用 `NSViewRepresentable` + 3 个 `CALayer` 承载封面彩色主阴影、彩色强调阴影和黑色深度阴影。
- 三层阴影继续使用 `glowStrength` / `coverProgress` 插值；彩色阴影仅作为轻量贴地色影，主发光不得再依赖 `shadowColor`、`shadowOpacity`、`shadowRadius`、`shadowOffset` 参数。
- 每个 shadow layer 设置 `shadowPath` 为封面圆角矩形，设置 `shouldRasterize = true`，并按窗口 backing scale 更新 `rasterizationScale`。
- 阴影层放在 `MusicExpandedArtwork` 的封面 ZStack 底部，外层现有 `scaleEffect` 与 `offset` 继续统一驱动封面和阴影的播放/暂停空间动画。
- 删除 `MusicExpandedArtwork` 外层三次 SwiftUI `.shadow`，避免封面区域继续走 SwiftUI 大阴影合成。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 中 `MusicExpandedArtwork`。
- 新增同文件内局部组件 `MusicExpandedArtworkShadowLayer`。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

本轮修改的代码范围：

- 仅封面阴影迁移。
- 未修改 L0 Metal shader，未修改 L1 真实玻璃，未修改 L2 歌词卡 effect layer，未修改 L3 歌词时钟与文本层。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未做播放器实际截图 diff、WindowServer RSS 采样或 Energy Impact 采样；CALayer 阴影视觉仍需在真实窗口中确认。

下一轮建议：

- 进入 L3：新增 `MusicLyricRenderState`，降低 `clockState.lyricTime` 每 tick 对整个 `ScrollView` 的驱动范围。
- 之后统一做真实播放器截图 diff 与 WindowServer / Energy 采样。

### 2026-06-05：收起态迷你频谱溢出修复（评审修正轮）

状态：评审上一轮「Album bloom 预烤与迷你频谱优化」落地的频谱代码，发现并修复收起态频谱溢出缺陷。未改动 bloom 预烤、L0/L1/L2/L3 其它部分。

问题：收起态迷你播放器的频谱条从卡片底部溢出（条异常拉长、穿出圆角卡片）。

根因：`MusicMiniSpectrumLayerView.SpectrumBarsView.layoutBarsIfNeeded` 在条图层仍带非单位 `transform` 时调用 `bar.frame = ...`。上一轮 `rebuildLayers` 给条预设了 `CATransform3DMakeScale(1, 0.12, 1)`，且每帧都会写新的 scale；在非单位 transform 下设置 `frame`/`bounds`，CoreAnimation 会反算 `bounds` 以满足请求矩形——请求高度 16 在 0.12 缩放下会解出 `bounds.height ≈ 133`。随后再写 scale，就把条按被放大的 bounds 渲染成异常高度；叠加宿主层 `masksToBounds = false` 不裁剪，于是溢出卡片。

修复：

- 几何更新前先 `bar.transform = CATransform3DIdentity` 复位，再用 `bounds` + `position`（不再用 `frame`）设置几何，彻底避免 frame/transform 互相污染。
- 锚点改为底部 `(0.5, 0.0)`（非翻转 NSView 为 y-up，y=0 即底边），`position.y = 0`，高度仅由末尾的 `CATransform3DMakeScale(1, scaleY, 1)` 自底向上缩放生长。
- `rebuildLayers` 不再预设非单位 transform。
- `SpectrumBarsView` 宿主层 `masksToBounds = true` 作为兜底裁剪，确保任何异常下频谱都不溢出 25×16 小框。

附带修复（L0 评审发现）：`MusicAlbumBackdropRenderer.init` 原本每次 `attach`（每次展开播放器都会重建 MTKView）都 `device.makeLibrary(source:)` + `makeRenderPipelineState`，主线程重复编译 MSL 造成展开卡顿。改为按 `(device, pixelFormat)` 静态缓存编译好的 `MTLRenderPipelineState`（`NSLock` 保护），仅首次编译。

本轮变更点：

- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 的 `SpectrumBarsView`（两个 init 的 `masksToBounds`、`rebuildLayers` 锚点与初始 transform、`layoutBarsIfNeeded` 几何设置）。
- 修改 `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift` 的 `MusicAlbumBackdropRenderer`（新增 pipeline 静态缓存）。

本轮验证：

- 已运行 `swift build`，通过。
- 频谱与 pipeline 缓存均需在真实窗口确认：频谱条自底向上、收起卡内不溢出；展开时不再因 shader 重编译卡顿。

评审遗留待办（未改，供后续轮处理）：

- L2 `PointerWashLayer` 在 `isFlipped` NSView + 手动 sublayer 下的坐标系仍需真实窗口确认；`compositingFilter = "screenBlendMode"` 提亮是否生效需确认。
- 旧 `AlbumGlassBackdrop` / `MusicFullScreenGlassLayer` / `AlbumNearFieldIlluminationLayer` 及依赖的 `AlbumBackdropStaticLayer` / `AlbumBackdropLightLayer` 已无实例化、仅剩定义；`MusicExpandedView.body` 第 53–57 行注释仍引用 `AlbumBackdropStaticLayer/behindWindow`，与现状不符，建议清理。
- `MetalAlbumBackdropView.updateNSView` 每次都无条件请求重绘（`MusicAlbumBackdropState` 非 `Equatable`），可加去重。

### 2026-06-05：Album bloom 预烤与迷你频谱优化（历史轮次）

状态：已完成第三轮代码接入；其中 `AlbumSoftBloomGlow` 预烤路径已在 2026-06-06 删除并替换为 `AlbumBlurredCoverGlowLayer` 的三层 image-based glow。`AlbumBloomImageBake` / `MusicBackdropBlur` 后续也已删除；`MusicMiniSpectrumLayerView` transform 更新仍是当前实现的一部分。

本轮工作：

- 历史：`AlbumSoftBloomGlow` 的封面主路径移除运行时 `.saturation(1.35)` 与 `bloomMask`。
- 历史：新增旧版 `AlbumBloomImageBake`，在异步生成低分辨率柔光纹理时用 CoreImage 提升饱和度，并用 CoreGraphics 生成与原 SwiftUI `bloomMask` 同 stop / 半径的径向 alpha mask，最终烤成带透明度的 `NSImage`。
- 当前：2026-06-06 后 glow 不再保留旧范围/opacity 方案，改为用 `AlbumCoverGlowBakeCache` 从 artwork 原图预烘焙 near/mid/far 三层 image-based blur；烘焙源图先做 Y 轴校正与邻近边缘像素延展，再用柔化圆角封面 alpha mask 和径向尾部衰减控制范围，并用 alpha clamp 控制过曝；运行时只合成缓存透明贴图，不再做 SwiftUI 三层大半径 blur/mask。
- `MusicMiniSpectrumLayerView` 的 bar 初始化为固定最大高度，设置底部锚点 `anchorPoint = CGPoint(x: 0.5, y: 1.0)`。
- 播放时用 `CATransform3DMakeScale(1, scaleY, 1)` 改变频谱高度，不再持续改 layer frame 高度。
- `bar.colors` 只在 accentColor 或 isPlaying 变化时更新。
- audio bands 做 bucket 去重；相同 bucket、相同播放状态和相同颜色时不提交新的 CA 更新。

本轮变更点：

- 历史修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 中 `AlbumSoftBloomGlow`、新增旧版 `AlbumBloomImageBake`、优化 `MusicMiniSpectrumLayerView.SpectrumBarsView`；当前 `AlbumSoftBloomGlow` 已删除。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

本轮修改的代码范围：

- 仅封面 bloom 预烤和底部迷你频谱更新路径。
- 未修改 L0 Metal shader，未修改 L1 真实玻璃，未修改 L2 歌词卡 effect layer，未修改 L3 歌词时钟与文本层。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未做播放器实际截图 diff、WindowServer RSS 采样或 Energy Impact 采样；封面 glow 预烤视觉仍需在真实窗口中确认。

下一轮建议：

- 继续做 `MusicExpandedArtwork` 三层 SwiftUI shadow 到 CALayer shadow 的迁移。
- 或进入 L3：新增 `MusicLyricRenderState`，把歌词 active 行滚动和逐字 progress bucket 从全 ScrollView tick 中拆开。

### 2026-06-05：L1/L2 玻璃与局部 pointer wash 接入

状态：已完成第二轮代码接入；L1 默认 `.withinWindow` 已落地，L2 初版局部 pointer wash 已替换旧 SwiftUI wash。L3 歌词 render state 与封面 bloom/阴影/频谱优化尚未开始。

本轮工作：

- 新增 `LyricsCardEffectLayerView`，使用 `NSViewRepresentable` + `CALayer` 在局部 rounded rect 内绘制 pointer wash 和边缘提亮。
- 鼠标移动由 `NSTrackingArea` 进入局部 AppKit view，只更新 `PointerWashLayer.pointer` 并触发局部 layer redraw；不写 SwiftUI `@State`，不再通过歌词卡/控制栏 body 更新实现 pointer wash。
- `FloatingLyricsGlass` 移除 `pointerLocation` / `globalFrame` 等 SwiftUI 状态，内部 overlay 从 `MusicInheritedGlassPointerWash` 改为 `LyricsCardEffectLayerView`。
- 删除旧 `MusicInheritedGlassPointerWash` SwiftUI 组件，避免后续误用。
- 音乐展开页前景层移除整窗 `MusicPlayerPointerLightScope`，避免鼠标移动通过环境值刷新展开页前景树。
- `MusicMiniPlayerGlassSurface` 中残留的旧 SwiftUI wash 也迁移到 `LyricsCardEffectLayerView`。
- `AppKitVisualEffectBackground` 默认 blendingMode 从 `.behindWindow` 改为 `.withinWindow`，真实玻璃仍保留 `NSVisualEffectView`。

本轮变更点：

- 新增 `Sources/MediaLib/Views/MusicPlayerLyricsCardEffectLayer.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 中 `FloatingLyricsGlass`、`MusicMiniPlayerGlassSurface`、`AppKitVisualEffectBackground` 和展开页前景 pointer scope。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

本轮修改的代码范围：

- 仅 L1 默认玻璃模式和 L2 pointer wash/边缘提亮局部图层。
- 未修改 L0 Metal 背景 shader，未修改 L3 歌词文本/时钟，未修改封面 bloom、封面阴影、迷你频谱。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未做播放器实际截图 diff、WindowServer RSS 采样或 Energy Impact 采样；局部 L2 pointer wash 视觉仍需在真实窗口中确认。

下一轮建议：

- 先打开音乐展开页做运行时 L0/L2 视觉确认和 WindowServer 采样。
- 视觉确认后进入 L3：新增 `MusicLyricRenderState`，让 `activeLineIndex` 变化触发滚动、`wordProgressBucket` 只更新 active line。

### 2026-06-05：L0 Metal 背景第一阶段接入

状态：已完成第一轮代码接入；L0 背景已由单个 `MTKView` 承载，L2/L3 与局部性能优化尚未开始。

本轮工作：

- 新增 `MetalAlbumBackdropView`，使用 `MTKView` 作为音乐展开页背景承载层。
- 新增 `MusicAlbumBackdropRenderer`，通过运行时 `device.makeLibrary(source:)` 编译 shader 字符串，避免本轮引入 SwiftPM `.metal` 资源配置风险。
- 将当前背景视觉参数迁入 shader：专辑底色、低分辨率模糊封面、纵向/斜向线性渐变、固定径向渐变、3 个 mesh 多色光斑、plusLighter/screen 合成、staticBackdrop 的 5 radial + 1 beam、ambient 的 3 radial + fill、nearField 的 3 radial + 1 beam。
- `MTKView` 静态默认 `isPaused = true`、`enableSetNeedsDisplay = true`，参数变化、纹理加载、窗口可见性/应用激活变化时请求单帧绘制；动态入口保留 `preferredFramesPerSecond = 30`，但本轮未开启连续动效。
- `MusicPlayerView.expandedPlayer` 顶层已用 `MetalAlbumBackdropView` 替换 `AlbumGlassBackdrop`、`MusicFullScreenGlassLayer`、`AlbumNearFieldIlluminationLayer`。
- `Package.swift` 为 `MediaLib` target 增加 `MetalKit` framework 链接。
- `handoff.md` 与 `CHANGELOG.md` 已同步记录本轮 L0 改造边界。

本轮变更点：

- 新增 `Sources/MediaLib/Views/MusicPlayerMetalBackdropView.swift`。
- 修改 `Sources/MediaLib/Views/MusicPlayerView.swift` 的展开页背景接入。
- 修改 `Package.swift`，增加 `MetalKit` 链接。
- 更新 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`、`CHANGELOG.md`、`handoff.md`。

本轮修改的代码范围：

- 仅音乐展开页 L0 背景承载与构建链接配置。
- 未修改歌词卡真实玻璃、控制栏、按钮、歌词文本、歌词时钟、封面 bloom、封面阴影、迷你频谱实现。

本轮验证：

- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，通过；仍有既有 OpenGL / UserNotifications 等非本轮警告。
- 已运行 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`，通过。
- 已运行 `scripts/package_dmg.sh`，完成 production build，并生成/校验 `dist/MediaLib.dmg`。
- 尚未做播放器实际截图 diff、WindowServer RSS 采样或 Energy Impact 采样；运行时 shader 视觉一致性需要下一轮通过打开播放器截图确认。

后续注意：

- L0 已接入但尚未做真实窗口截图 diff、WindowServer RSS 采样或 Energy Impact 采样。
- 后续背景动态只能继续通过 L0 shader uniform/function 扩展。

### 2026-06-05：专项规划创建

状态：已完成规划文档创建，未修改实现代码。

本轮工作：

- 阅读 `Sources/MediaLib/Views/MusicPlayerView.swift` 中音乐展开页顶层背景、歌词卡、真实玻璃、歌词时钟、封面 glow、封面阴影、迷你频谱相关实现。
- 阅读 `handoff.md` 中 2026-06-01 到 2026-06-04 的音乐展开页性能和视觉约束，确认已有 CA 化优化不是本次 L0 Metal 终态。
- 新增本专项文档，记录四层架构、分阶段计划、局部性能优化、验收标准和禁止回退项。

本轮变更点：

- 新增 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md`。
- 重新生成打包产物 `dist/MediaLib.dmg`；打包脚本同步刷新了 `dist/MediaLIB.app`。

本轮修改的代码范围：

- 无。按用户要求，本轮未修改 Swift/Metal/脚本实现代码。

本轮验证：

- 已运行 `scripts/package_dmg.sh`，脚本完成 production build 并生成/校验 `dist/MediaLib.dmg`。
- 未运行 `MediaLibChecks`，未做截图 diff；本轮是规划文档创建轮。
