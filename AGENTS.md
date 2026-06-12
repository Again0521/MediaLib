# MediaLIB Agent Notes

本文档给后续 Codex / Agent 会话使用，目的是保持开发方式一致。

## 工作原则

- 不要推倒重写，优先基于现有代码小步迭代。
- 修改前先给计划，修改后说明改了哪些文件、为什么改、如何测试。
- 不要移动用户的媒体文件；重分类只修改 MediaLIB 内部索引。
- 不要在锁定状态展示保险库路径、文件名、扫描中文件名或改密入口。
- 每次功能或 UI 改动后，同步更新相关文档。
- 每次交付都重新生成 `dist/MediaLib.dmg`。
- 主窗口无缝透明标题栏只允许应用到真正的主 `NSWindow`；`NSOpenPanel`、`NSSavePanel`、`NSAlert` 等 `NSPanel` 必须保留系统不透明背景与原生布局，不能被全局窗口观察器改成透明或 full-size content。
- 软件面向用户的显示名统一为 `MediaLIB`；内部 bundle id、Swift target、数据库目录和 UserDefaults key 继续沿用 `MediaLib` 以兼容旧数据。
- 数据库结构变更必须提升 `DatabaseManager.currentSchemaVersion` 并按版本顺序迁移；迁移和恢复前使用 SQLite backup API 创建一致性快照，不能直接复制 WAL 模式下的数据库文件。恢复只替换 MediaLIB 内部索引，不触碰用户媒体文件。
- 播放章节、片头、片尾和书签统一使用 `PlaybackMarker` / `playback_markers` 内部索引；内嵌章节按媒体替换时必须保留手动标记，标记删除或修改不能写回、移动或改名用户视频文件。播放器只在完整片头/片尾范围内显示跳过入口；内嵌章节读取复用现有低频轨道刷新，不新增高频计时器。后续自动检测与章节图必须进入统一后台任务中心。
- 片库健康中心必须复用 `AppState` 派生缓存，文件存在性与来源可达性只能在后台检查，不能在 SwiftUI `body` 中调用 `FileManager`。健康结果只允许来自仍存在且 `includeInHealthCheck == true` 的来源；删除来源或关闭健康检查必须取消旧检查并立即使该来源缓存失效。失效索引清理必须显式确认且只删除 MediaLIB 内部索引；离线来源中的条目不能清理，锁定状态不能展示保险库路径或内容，疑似重复项不能自动合并。
- `AppState.rebuildDerivedItemCaches` 保持单次全库分桶；“正在观看”必须读取公共/保险库派生缓存，不能在页面打开时重新全库 filter/sort。喜欢和想看状态只更新目标所属父级的 children 缓存；单歌单读取必须直接查询目标 ID，外部播放器发现结果应复用缓存并在应用激活或安装状态变化后刷新。
- FSEvents 增量扫描只能用于开启自动扫描且可访问的本机 `sourceKind == .local` 来源；SMB/FTP/NAS 文件事件不可靠，不能据此删除索引，继续使用周期完整扫描。文件事件必须先防抖合并，普通变化只调用 `MediaScanner.scanChanges` 更新受影响路径；目录删除/重命名、root change 或 event dropped 必须降级为安全完整扫描。增量删除前必须确认来源可访问且路径位于来源内部。任务中心保持会话级、惰性静态玻璃和受控进度发布；保险库任务始终隐藏路径和文件名。

## 重要命令

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks
scripts/package_dmg.sh
```

如果 SwiftPM 因用户级缓存权限失败，需要在 Codex 中允许沙盒外运行对应命令。

## 播放器约束

- 当前视频内置播放器是 `PlayerView.swift` 的 SwiftUI 窗口，运行时通过 `LibMpvClient.swift` 动态加载随 App 分发的 `libmpv` 核心，并通过 libmpv render API 渲染到应用内 `NSOpenGLView`。
- `LibMpvClient.swift` 使用 `mpv_render_context_create` / `mpv_render_context_render`，不要改回 `wid`、`vo=gpu` 嵌入或完整 mpv 可执行文件窗口，否则在部分 macOS 环境会再次出现控制层和视频分成两个窗口、Dock 多出图标的问题。
- 当前 `NSOpenGLView` / `NSOpenGLContext` / OpenGL 调用会触发 Apple 的弃用警告，官方方向是 Metal/MetalKit；但这牵涉 libmpv render API 的新渲染桥，不是普通组件替换。除非明确设计并验证 Metal/libmpv 渲染路径，不要为消除警告直接替换播放器承载视图。
- http/https 远程资源需要跳过本地文件存在性检查，可直接交给 mpv；这用于 Emby API 同步出的流媒体地址。
- MKV 等 AVFoundation 无法截帧的格式通过 `ThumbnailGenerator` 的 ffmpeg 兜底路径生成封面；打包脚本可复制 Homebrew `ffmpeg` 及依赖，但不要恢复完整 mpv 可执行文件作为截帧或播放入口。
- Emby 媒体源应通过登录同步维护，token/网络凭据保存在 Application Support 的 MediaLib/Credentials 文件中，不再读写或删除系统钥匙串，避免 ad-hoc 更新后首次打开弹系统密码框。媒体源列表固定显示为 `EMBY`，不要给用户提供手动重分类入口。内部条目用 `sourcePath + externalID` 维持与 Emby ItemId 的映射，`sourcePath` 要保留服务端 `ViewId` / `CollectionType` / 名称以驱动 EMBY 目录自适应分类。Emby 条目必须只显示在独立 EMBY 目录下，不要混入本地视频/音乐分类；左侧 EMBY 目录按有条目的通用分类和服务端 Views 自适应显示，无条目的分类不显示。Episode 必须优先使用 Emby `SeriesId` 作为父级，避免 `ParentId` 指向 Season 导致剧集详情页无剧集；如果服务端只返回 Episode 而不返回 Series，应合成 Series 父项保障剧集列表可见。
- Emby 登录弹窗点击“登录并同步”后必须立即关闭，认证与同步通过后台任务中心运行，并用全局对话框反馈成功或失败；首次连接失败时必须清理未完成的来源与凭据，不能留下不可用来源。不要把网络等待重新塞回登录弹窗。
- SMB/FTP 网络源当前依赖 macOS 挂载后选择目录，再复用本地扫描器；不要在没有可靠协议库时手写目录解析器。
- 旧完整 mpv 原生窗口路径已移除，不要再把它恢复成普通视频默认播放入口。
- 用户希望字幕/音轨通过应用内图标弹出下拉框选择。当前播放器通过 mpv `track-list` 提供真实音轨/字幕轨道弹层和选择状态，同目录 `.srt/.ass/.ssa/.vtt` 字幕也会作为外挂字幕入口；外挂字幕必须按 `external == true` / `external-filename` 留在“同目录字幕”分组，点击已加载外挂字幕应选择轨道而不是重复 `sub-add`；不要退回只循环轨道的菜单。
- 视频和音乐独立播放器窗口关闭时必须通过 `windowShouldClose` 先清理 `activePlayerItem`，再由 presenter 程序化关闭；不要在 `windowWillClose` 中同步改 SwiftUI 状态。
- 视频播放器窗口是透明标题栏 `ImmersivePlayerWindow`，保留 macOS 原生红黄绿按钮和系统圆角；红黄绿按钮应随控制层自动淡入淡出，形成无边框观感。不要改回纯 `.borderless`，也不要把窗口设回 opaque 黑底，否则会丢失原生按钮或出现直角。
- 视频播放器窗口尺寸按设置宽度和视频比例计算，设置页以当前屏幕可用宽度百分比显示并限制在合理范围，超过屏幕可用区域时等比缩小；打开前优先用 `MediaItem.resolution` 预判比例，Emby 该字段来自服务端 `MediaStreams`，本地缺失时先轻量读取视频轨道尺寸和旋转矩阵再开窗。mpv 准备好后仍可使用 `dwidth/dheight` 或 `width/height` 回传的真实显示比例校正窗口，但与预判一致时不要二次缩放；`PlayerView` 根视图不要设置固定最小高度破坏超宽视频比例。
- 视频播放器打开后需要按发起播放的主窗口所在屏幕的可用区域居中并激活窗口，SwiftUI 内容挂载后还要校正一次；不要只依赖 `NSWindow.center()` 或 `NSApp.keyWindow`。
- 视频播放器的拖动由 `PlayerInteractionOverlay` 区分点击和拖动后调用 `NSWindow.performDrag(with:)` 完成；不要只依赖 `isMovableByWindowBackground`，否则透明交互层会吃掉鼠标事件。
- 视频控制层自动隐藏计时器不要放进会随鼠标移动更新的 SwiftUI `@State`；控制条应常驻并切换透明度，hover 时暂停自动隐藏，否则控制条会闪烁并影响点击。
- 视频控制层移动鼠标唤出需要使用可取消的 debounce；取消旧隐藏任务后必须直接返回，不要用 `try? await Task.sleep` 吞掉取消并继续隐藏控制条。右侧控制层锁定后，移动鼠标不能唤出控制条。
- 视频关闭、窗口按钮关闭和上一集/下一集切换必须先保存进度并 teardown 当前播放器；`LibMpvClient.stopPlayback()` 会先静音、暂停并 stop mpv，避免关闭窗口后声音残留。OpenGL 视图首帧前保持黑色清屏，避免切集蓝屏；打开视频时在首帧视频参数回传前应继续显示加载层，并短时强制视图重绘，不要让“有声音但黑屏”裸露给用户。
- 视频快捷键由 `KeyCaptureView` 捕获，常用操作包括 Space/K、方向键、Shift/Option 方向键、J/L、M、F/Return/Cmd-F、Esc、Cmd-W/Q、数字键、`[`/`]`/`\`、`,`/`.`、C/V/A；未处理的 Command 组合要交还系统。
- 音乐播放器在 `MusicPlayerView.swift`，由 `ContentView` 覆盖在主界面内：展开时必须保留 macOS 系统红黄绿按钮，但隐藏主窗口工具栏、导航标题和侧栏展开按钮；不要再用 SwiftUI `.toolbar(.hidden, for: .windowToolbar)`，否则会把系统红黄绿一起隐藏。展开过程必须拆帧执行：先让播放器 overlay 以整窗 opacity 覆盖挂载，下一帧再用 AppKit 层无动画切换透明 titlebar/隐藏标题的沉浸 chrome，收起时先让播放器回到底栏，再延后恢复 chrome；不要把窗口 chrome 切换、播放器 overlay 插入和侧栏重排塞在同一帧，也不要对整窗 overlay 做 scale，否则会露出顶部系统白底。点击主窗口系统关闭按钮应按最后窗口关闭规则退出 MediaLIB，软件内收起按钮只负责回到底部迷你播放器。展开态 `ContentView` 必须让下层 `navigationRoot` 停止命中测试并写入 hover 抑制环境，避免下层列表、海报和按钮继续响应鼠标动作。最小化时先缩到底部迷你播放器控制条，再用 `AppMotion.sidebar` 单独恢复左侧栏并为迷你播放器预留侧栏宽度，主窗口 chrome 恢复必须延后到侧栏动画稳定后，避免底栏最后几帧跳位。音乐播放状态必须由 `ContentView` 持有唯一 `MpvPlayerController` 和不可见 `MusicPlaybackHost` 管理；`ContentView` 只持有该控制器，不要用 `@StateObject` 订阅播放进度导致根视图跟着 0.18s 进度刷新重算。`MusicPlayerView` 只负责展开页，底部条必须是独立 `MusicMiniPlayerBar`。底部迷你播放器必须由 `ContentView` 的窗口级 `GeometryReader` 给出整窗尺寸并在父层贴底，不要在 `MusicPlayerView` 内部用 `GeometryReader` 自己贴底，否则作为 `NavigationSplitView` overlay 时会拿到错误高度并漂到列表中部。底部条宽度必须按窗口剩余空间弹性计算，侧边栏收起时拉伸、展开时缩回；不要恢复固定 980px 宽度。不要再给 `MusicPlayerView` 按歌曲 `.id` 强制重建，否则切歌会重建整棵播放器并卡顿。内置音乐播放走 AVFoundation 音频后端，同一个控制器必须在展开/最小化之间保持，不要再弹独立音乐 `NSWindow`。
- 视频和音乐分别使用 `AppSettings.lastVideoVolume` / `lastMusicVolume` 记住上次调节音量；旧 `defaultVolume` 只保留为迁移旧配置初值。音乐控制条音量必须是进度条右侧按钮触发弹出滑条，不要恢复常驻音量滑杆，也不要把默认音量放回设置页。
- 音乐歌词最大化时显示，存在歌词时不显示获取歌词按钮；LRC 第一行需要从歌词卡片中心出现，当前行随时间轴弹性滚动并保持在中心附近，柔和变色并轻微放大；远离当前行的歌词需要逐步变淡并被玻璃模糊遮挡。用户手动拖动歌词区浏览时，应临时取消远离歌词的 blur，只保留透明度层级；点击带时间戳的歌词行应跳转到对应播放位置。增强 LRC 的 `<mm:ss.xx>` 片段时间戳需要走逐字/分词真实高亮，并优先于任何估算。普通逐句 LRC 没有逐字时间戳时必须用当前行到下一行的持续时间估算行内字符进度，最后一句用前几句平均时长或保守文本时长兜底；估算时排除空格、换行、标点和符号，中文按字符、英文按单词分配，句尾略延长，并输出原文字符 index。当前行里的未播放文字应略微下沉，播放到对应字或片段时按 `AppMotion.lyric` 缓慢上升并稍微突出，参考 Apple Music 的当前字效果；拖动进度条或手动浏览歌词后，下一句应自动校正回当前播放行；已播放歌词颜色从专辑封面主色派生更深但不过暗的色值，不要改回固定蓝色、呼吸亮度、硬切逐字变色或生硬换行。
- 歌词来源 badge 只显示“原词逐字 / 音频对齐 / 估算同步”等文字，不显示“甲乙丙”或 `abc` 图标；`TimedLyricLine.activeIndex` 不能提前把普通播放当前行推进到下一句。歌词 seek 统一通过 `MpvPlayerController.seekState: PlaybackSeekState?` 发布拖动预览、等待落点和真实落点：进度条必须在拖动开始/变化/结束时分别调用 `beginScrubbing` / `updateScrubbing` / `finishScrubbing`，不能只在拖动结束时 `seek(to:)`。`PlaybackSeekState` 的 `scrubbing` 阶段按拖动目标实时定位歌词行，`seeking` 阶段继续按目标时间等待底层播放器落地，`settled` 阶段按 AVPlayer/mpv 真实回读时间覆盖到真实行；第一条大于目标时间的歌词时间戳只作为结束边界。`currentTime` 只服务进度条即时反馈，`lyricTime` 只来自播放器真实回读，不能在 `beginTimelineSeek` 中乐观写入目标。LRC 解析必须保留同时间戳行的文件顺序，并把 80ms 内的重复时间戳行合并为一个显示块，避免双语/翻译歌词被二分查找稳定选到同一时间戳组的最后一行。旧 `lyricSeekTargetTime` / `lyricSeekRevision`、`LyricSeekRecovery`、`LyricSeekBoundaryCorrection`、`lyricClockSerial`、`TimelineSeekSnapshot` 和多轮延迟校正 Task 已删除，不要恢复。LRC `[offset:+/-毫秒]` 必须参与普通行和增强片段时间计算，否则歌词会整首稳定快/慢。控制器 pending seek 期间必须屏蔽旧播放时间回写；普通轮询只有同时离开 seek 前旧位置且靠近目标时才可确认落点，AVPlayer seek completion 只有 `finished == true` 才能强制采纳真实落点，取消或打断的 completion 只能触发后续校验，必要时节流补发底层 seek。seek 触发的远距离对齐必须重置歌词滚动视口并无动画居中目标/真实行，普通播放推进才恢复 `AppMotion.lyric` 平滑滚动。歌词卡片中心舞台光必须裁剪在歌词卡片内、位于文字下方；提升中心玻璃透明度时不要让文字颜色被白光冲淡，上下边缘可用轻量 material 渐隐增加模糊深度。
- 音乐展开页必须铺满 MediaLIB 内容区，内容层左上角只显示软件内最小化按钮；该按钮必须作为 `MusicPlayerView` 最外层固定浮层，使用 macOS 感透明液态玻璃、向下返回/收起箭头，足够明显且可点击，不要放回内容布局流里。按钮左边距必须与左侧控制栏左边距一致。界面分为两层：底层是专辑封面取色的厚实不透视色板背景，先用专辑色混合实底色遮住下层页面，再从专辑封面中心扩散舒适范围的柔和多色径向光和斜向光束，播放时用基于播放时间拍点的低频平滑脉冲变化强度/位置，避免明显闪烁；取到低饱和灰脏色、灰棕或灰绿时必须做清洁化处理，不能让整页变脏；不要恢复能透视到下层列表/页面的透明背景、整页系统 material 或铺满整屏的过量专辑色光。第二层左侧放专辑封面和液态玻璃控制栏，右侧放悬浮圆角液态玻璃歌词卡片。歌词卡片必须是单层可见玻璃面板，非紧凑布局下必须由 `MusicExpandedLayout` 显式计算 `lyricsRect`，用明确的 `x/y/width/height` 约束在剩余区域内；布局优先保证左侧封面和控制栏宽度及左边距，再让歌词卡片从右边界向左弹性收窄，并让歌词卡片右边距与控制栏左边距一致。歌词卡片要保留合理最小宽度，但窗口较小时优先保证左侧控制栏宽度。不要再使用中心点加固定高度定位，也不要回到 `HStack` + padding + `.frame(maxHeight: .infinity)` 这种会在真实窗口里被撑穿的方案；圆角接近主窗口圆角，材质要透亮并有高光描边和玻璃边缘质感；不能遮挡或压缩播放控制区，不要改回静态 `AppPageBackground` 两列页，也不要再把歌词包进几乎不可见的内层透明卡片。切歌取色必须取消旧 `paletteLoadTask` 并校验当前歌曲 ID，避免上一首封面色晚到覆盖当前界面；音乐展开页玻璃光效应使用专辑色 tint。底部迷你播放器本体保持克制白色厚玻璃，专辑色柔光必须裁剪在底栏内部并主要用于静态边缘氛围和右侧按钮由近到远衰减的轮廓光；不要恢复整条底栏的实时鼠标径向光或播放时间驱动 blur，否则会重新增加长列表滚动和 WindowServer 合成压力。底部迷你播放器的纵向 padding 必须位于圆角玻璃裁剪层内部，使静态专辑柔光覆盖完整 72pt 底栏高度，不要把光效限制在内层内容区域。
- 音乐展开页左侧封面、标题和控制栏必须按窗口可用高度自适应，长标题限制在安全高度内并允许缩放；底部迷你播放器必须显式贴底，不要随音乐列表内容漂到中部。底栏和列表/设置页同时存在时，任意方向滚动开始即可把底栏平滑收起到右侧封面形态；完整底栏封面和收起态封面必须用同一 matched geometry 身份衔接，收起像封面向右移动，展开像封面向左回到完整底栏。收起态只显示变暗专辑封面和低开销真实频谱，频谱只在收起封面可见时开启后台音频小窗口采样，播放时更新、暂停时静止，点击封面展开完整底栏。该交互必须使用 `AppMotion.musicPlayer`，不要用全宽实时鼠标光或播放时间驱动 blur 来实现。
- 底栏收起态父层必须保持完整可用宽度，不能把外层 frame 缩成 72pt；封面移动要发生在同一上层坐标系里，避免被下层滚动页面影响方向。收起态进度环必须绘制在封面外侧，颜色使用专辑高斯取色邻近深浅色，浅色未播放、深色已播放。音乐展开页暂停/播放时封面大小、后退位移、阴影、光晕、背景节奏光和近场光必须用连续视觉进度同步插值，不要拆成先关光再缩放、先缩放再开光，或直接用 `controller.isPlaying` 硬切 Canvas 强度；暂停末端封面周边 glow 必须收敛到接近 0，避免缩小完成后残留光圈再硬切，环境光可略照到歌词卡片和控制栏但封面四周发光距离要均匀。
- 歌词解析结果应在歌词文本变化时缓存到状态，不要在播放进度刷新驱动的 SwiftUI `body` 中反复解析整段歌词。
- 音乐队列由 `AppState.musicQueue` 管理；歌曲右键必须提供加入队列、下一首播放和添加到歌单，添加到歌单菜单第一项为新建歌单，后续为已有用户歌单。队列弹层需要支持清空、移除、拖动排序、整队列存入歌单和单曲存入歌单，不再恢复独立“播放列表”侧边栏页面；底栏和展开页弹出的队列都必须保持静态玻璃性能档，不要恢复队列内鼠标驱动光效。用户手动歌单单独通过“音乐 > 歌单”入口持久保存，只记录 MediaLIB 内部索引，不移动或改名音乐文件。专辑卡片、艺术家行和歌单卡片必须支持查看歌曲列表，播放专辑/艺术家/歌单分组时应通过 `replaceMusicQueueAndPlay` 用该分组歌曲替换当前队列，而不是追加到旧队列后面。添加到歌单只更新 `musicPlaylists` 和 `music_playlists` / `music_playlist_items`，不要 bump `libraryRevision` 或触发全库刷新。切歌必须复用现有 `AVQueuePlayer`，不要 teardown 后重建音频后端；即时衔接仅允许为本地确定性下一首保留一个队列项，随机、远程资源和柔和淡入不预加载。切歌保存上一首进度应静默写库，不要触发 `AppState.reload()` 全库刷新；自动下一首由音频结束通知立即触发，不要只依赖低频进度轮询。
- 音乐响度均衡只读取扫描阶段保存的 ReplayGain/R128 曲目/专辑增益与峰值，通过 `MusicLoudnessGain` 计算不超过原始满幅且受峰值约束的播放增益；不能为了均衡重编码、写回或修改用户音乐文件。没有标签时必须保持原始音量。即时衔接和柔和淡入继续复用同一个音频控制器；本地顺序播放/队列循环的即时衔接使用同一个 `AVQueuePlayer` 单项预加载，预加载项限制前向缓冲并可取消，单曲循环与单项队列循环必须在队尾条目被移出后正确重建并重启。若后续实现远程预加载或双播放器重叠交叉淡化，必须先验证 AirPlay、歌词时钟、随机/循环队列、关闭路径和内存占用。
- 视频 `favorite` 表示“喜欢”，`watchlist` 表示本机“想看”计划，两者不能重新合并。Emby 收藏仍同步 `favorite`，但 Emby 想看只保存在 MediaLIB 本机；本地扫描/upsert 和 Emby `replaceRemoteItems` 必须保留已有 `watchlist`。视频智能集合只保存媒体类型、状态和最近加入时间规则，动态匹配本地与 Emby 顶层视频，不复制媒体条目、不移动文件、不显示保险库或 Episode 子项。新增规则必须通过后续 schema version 迁移并覆盖扫描、远程刷新与备份恢复测试。
- 队列拖拽排序期间必须暂停滚动锚点恢复和可见行锚点刷新，避免每次 `musicQueue` 变化都把列表滚回旧位置；跨行移动需要轻微节流并禁用移动动画，长队列排序以可控为先。
- 音乐随机播放和循环模式是两个独立状态：随机由 `musicShuffleEnabled` 控制，循环由 `musicRepeatMode` 控制顺序播放/队列循环/单曲循环；不要再把随机塞回循环模式。循环模式必须是单个按钮循环切换，图标分别为顺序箭头、repeat、repeat.1。展开页第一行顺序为喜欢、弹性进度、队列；第二行顺序为 AirPlay、音量、上一首、播放/暂停、下一首、随机、循环模式，且两行首尾按钮边界对齐；展开页不要显示快退/快进 15 秒按钮，也不要把顺序播放/队列循环/单曲循环拆成三个按钮。展开页播放/暂停按钮必须复用底栏蓝色胶囊主按钮样式。底部条循环模式放在随机播放左侧，队列按钮放在 AirPlay 左侧，空间不足时隐藏快退/快进 15 秒按钮避免越界。音乐 AirPlay 使用 `MpvPlayerController.routePickerSession` 持久绑定当前路由播放器，展开/收起时刷新路由，本机同播由 `AppSettings.keepLocalAudioWithAirPlay` 控制并默认开启；开启本机同播时主音乐 `AVPlayer` 保持本机输出，单独的音频路由代理 `AVPlayer` 允许外部播放并交给原生 `AVRoutePickerView` 选择 AirPlay 设备；AirPlay 按钮使用固定深蓝玻璃色，不跟随专辑封面取色；可见 SwiftUI 按钮负责点击并主动触发隐藏的原生 `AVRoutePickerView`，不能依赖透明原生控件覆盖命中，也不能复用同一个 NSView 导致展开页不可点击；路由选择结束后需要延长外部播放状态探测，确保本机同播代理有机会跟上系统回调。音乐条目双击播放应优先显示底部迷你播放器，用户点击底栏曲目信息后再展开整页播放器。
- 视频播放器关闭和切集时必须先 teardown/停止 libmpv，再保存播放进度；不要把 `saveProgress` 放在停止播放器之前，否则数据库刷新会让关闭窗口和声音停止显得卡顿。
- Emby 远程视频清晰度选择只在片源分辨率和码率足够时显示，最低档位为 1080P，1080P 最低视频码率按约 5.8 Mbps 处理；不要生成 720P/标清等低于 1080P 的档位。原画必须保持 Emby 静态直连 URL，其他档位通过 Emby 转码参数生成，并保留 token、MediaSourceId 和 DeviceId。挂载局域网/NAS 视频也属于非本机视频，但没有服务端转码能力，只能提供播放端降采样档位，不能声称降低网络读取码率；通过 mpv `vf` scale 滤镜切换，不要重载文件或改变窗口比例。新增播放器弹层必须固定自身尺寸，不能影响播放器窗口 `contentAspectRatio`。
- 视频进度条悬浮预览气泡必须作为固定高度 scrubber 的 overlay 绘制，不参与控制条主布局；帧预览本地文件可用 AVFoundation，远程 Emby 和挂载网络路径应使用 ffmpeg 后台抽帧兜底并缓存，悬停时优先读内存缓存并预热邻近 bucket。预览 bucket 必须按视频总时长分成有限段，同一段内复用同一张缩略图，不要恢复固定短秒数或每分钟一张的生成方式；黑帧要尝试邻近时间点，加载中显示同控制栏一致的暗色玻璃占位，不要恢复黑块或让预览撑动控制栏。若后续实现真正 trickplay/storyboard，应在扫描或同步阶段预生成，不要让主播放线程抽帧。
- 视频侧栏不再提供独立“最近播放”页，旧 `video-recent` 需要迁移到“正在观看”；所有有播放痕迹的视频统一进入“正在观看”，并在“正在观看”和“已观看”保留一键清除当前页面播放记录入口。保险库内容仅在已解锁时进入这两个页面并允许从页面或保险库右键清除播放记录；锁定时不得泄露。Emby 最近播放和音乐最近播放仍保留各自清除入口。
- 音乐扫描必须穿透嵌套文件夹；自动识别源也要识别音频文件，音频文件不能被视频默认 50MB 阈值跳过。扫描器必须显式排除歌词、字幕、本地图片、`.cue`、`.nfo` 等旁路元数据文件，并只导入规范化后的普通媒体文件；同一路径需要去重，音乐导入时应清理同一 `file_path` 的旧重复记录。
- 音乐封面优先级必须保持：音频内嵌封面最高，其次联网补全封面，再次默认图标；联网封面不能覆盖内嵌封面。音频标签读取必须覆盖 common metadata 以及 iTunes/ID3/QuickTime 等格式级 metadata，尽量读取标题、艺术家、专辑、曲目号、年份、内嵌封面和内嵌歌词；不要把同目录 `cover/folder/poster` 或其他歌曲封面套给整个文件夹内的歌曲。
- 音乐专辑只信任音频标签或联网补全结果，不要把同一个文件夹强行视为同一个专辑；音乐歌词只匹配单曲同名 `.lrc` / `.txt`，不要用目录级 `lyrics.lrc` / `lyrics.txt` 作为共享歌词，也不要让歌词文本文件进入媒体扫描结果。
- 音乐标签编辑功能在 `MusicTagEditingService.swift` 与 `MusicTagScraperSheet.swift`：不能直接 vendoring `music-tag-web` 这类 GPL/额外限制的 Web 项目；当前只参考 MIT `music-tag` 的统一标签抽象思路，使用原生 Swift UI 和 ffmpeg 写回。MusicTag 工作台默认只更新 MediaLIB 索引，只有用户显式打开“写入文件”才修改本地音频文件标签；写入必须先生成临时文件并成功校验后再替换原文件，远程资源/不可写/不支持格式要逐条失败，不要移动用户媒体文件或后台静默批量改原文件。

## UI 约束

- 除音乐展开页外，普通页面、弹窗、工具条、列表、设置和菜单必须遵守 `MediaLIB_设计系统标准.md`。普通页面使用 `PageHeader`；普通编辑/添加/重命名/确认类弹窗使用 `AppSheetHeader`、`AppInfoNote`、`AppSheetActionFooter` 和 `appSheetChrome`；页内工具条使用 `AppSurfaceToolbar`。工作台型大弹窗可保留页面级结构，但仍要遵守按钮反馈、文案和静态玻璃性能约束。
- 页面卡片、选项栏、设置分组使用偏白、干净、低噪声的液态玻璃风格；设置页卡片必须复用其他页面的通用卡片材质。
- 鼠标光效默认应低饱和、偏白、克制且发光范围小；不要重新加重蓝色泛光。光效只影响卡片背景，按钮需要分离到卡片上层并只显示边缘光，不能让发光层盖到按钮内容。视频封面检视倾斜只作用于封面区域，不要让标题/元信息一起倾斜，也不要对外层命中卡片做 scale/offset 导致 hover 状态抖动。
- 除音乐展开播放器外，所有页面统一复用 `SurfaceBackground` / `AppPageBackground` 的暖白珍珠玻璃材质语言；左上环境光应保持低饱和浅米白/香槟色、宽范围，模拟屏幕外左上方且靠近用户的位置斜向照入，受光面应在左上，右下只留轻暗边，不要改回局部深蓝、浅水色、反向染色或偏饱和米黄色光斑。动画统一使用 `AppMotion` 中的非线性曲线，新增动画不要回到短促线性节奏，也不要给长列表和页面切换套大面积隐式动画。
- 通用玻璃元素应保留鼠标光源响应，使用局部 hover 位置改变高光角度和明暗；不要引入全局高频鼠标监听导致整屏重绘。普通页面中位于玻璃卡片上的玻璃按钮、菜单、搜索框、输入框和筛选胶囊需要有明确但不过白的填充层，与下层玻璃材质拉开层级；普通重复控件默认使用暖白半透明静态玻璃、直接描边和轻接触阴影，不要重新挂 `.regularMaterial` 或大投影，也不要把背景、卡片、按钮都调成同一块正白或冷蓝。页头搜索框和扫描/清除记录按钮可通过 `HeaderControlGlassBackground` 使用更明确的暖白系统玻璃、边缘折射和轻暗边，让搜索/工具控件从背景中浮起；列表行、海报卡、设置分组仍保持 cheap 静态路径。`GlassSearchField` 使用透明 AppKit 文本输入底来避免聚焦白底，后续不要换回会露出系统白底的默认 `TextField`。`LiquidGlassButtonStyle` 的非突出按钮必须保持 cheap 路径并裁剪到圆角，避免底部露出直角色块；滚动行内小按钮优先用 `RepeatedGlassButtonStyle`。强调按钮、解锁按钮和获取类按钮必须保持足够深的蓝色玻璃层与白色文字对比，并避免过强渐变。音乐展开页优先保留专辑色光效；歌词卡片、控制栏、弹层和收起按钮允许使用卡片级 `.thinMaterial` 透亮玻璃、低白度填充和专辑色边缘光恢复真实模糊，但不要把该材质复制到长列表或海报卡；歌词面板不要再使用固定圆心径向高光，避免左上角出现固定圆斑。音乐底栏只允许单块受控厚白玻璃底、裁剪静态专辑柔光和克制轮廓染色，不要恢复鼠标驱动的全宽光效。
- 所有海报墙页顶部允许使用 `PosterGridTopFade` 这类轻量渐隐材质遮罩，让内容滑出顶部更自然；不要为了该效果把整页海报墙包进大面积 blur/material 容器。
- `PageHeader` 是普通页面标题、搜索框和右侧操作按钮的统一入口。带操作区的页面必须保持“标题左侧 + 右侧操作区”的固定结构，并让右侧搜索/扫描/清除记录控件下边界与标题栏下边界对齐；不要恢复根据按钮数量自动切换单行/双行的页头，也不要在单个视频/音乐子页面手写不同的标题或工具条位置。
- 视频海报卡、音乐专辑卡和歌单卡可以通过固定高光、封面描边和 `repeatedSurfaceHover` 增强 hover 质感，但必须接入滚动期 hover 抑制和 Reduce Motion；不要把卡片 hover 做成会改变布局尺寸、整卡 scale/offset 或持续采样鼠标位置的动画，避免按钮点击时卡片跟着移动。
- 视频海报墙 hover 轻微放大只能作用于封面绘制区域，外层卡片、文字、布局尺寸和命中区域保持不变；详情页内发起视频播放必须保留当前详情选择，使用 `preserveSelection: true`，不能播放后跳回海报墙或其他页面。
- 面向用户的说明文案保持简洁、平静、直接，避免内部实现术语、命令式教程口吻和过度官方表达；同类页面使用一致语气。
- 会打开后续流程、文件选择器、弹窗或控制台的按钮文案使用省略号，例如“添加…”“选择…”“打开控制台…”；立即执行动作不使用省略号，例如“扫描全部”“保存”“立即备份”。
- 普通按钮、页头按钮、重复列表按钮、菜单按钮、筛选胶囊和音乐图标按钮不要使用按压 scale 或阴影 y 偏移；每个可点击控件至少提供鼠标响应或点按反馈，页头扫描/清除记录等操作统一复用 `HeaderActionGlassButtonStyle`，重复行按钮优先复用 `RepeatedGlassButtonStyle`。点击反馈用透明度、描边、边缘光、亮度或色彩变化，避免按钮条和下层卡片看起来发生位移。评分星星、展开全文和轻量文字链接这类不适合加背景的控件使用 `SubtleIconButtonStyle`；整行/整卡点击使用 `repeatedSurfaceHover`。筛选胶囊即使关闭连续 pointer edge，也必须保留轻量 hover 高光；批量操作栏不能退回裸 `.plain` 文字按钮。页头标题、搜索框和右侧操作区应保持稳定，不要让按钮状态变化触发布局动画。
- 左侧栏使用低饱和冷蓝 `SidebarGlassBackground`，需要比正文卡片更透明、更像整块玻璃，优先使用 `ultraThinMaterial` 和很轻的蓝色洗色以保留桌面/后景透亮感，不能重新变成整块高饱和蓝板。
- 视频播放器控制条使用底部紧凑悬浮条，第一行为完整进度条，第二行居中放上一集、播放/暂停、下一集；控制条不要恢复底部标题行、关闭按钮、跳秒按钮、外部打开按钮或占据顶部空间的大控制栏。较少用的 AirPlay/音轨/清晰度放左侧，音量/字幕/倍速/全屏等常用入口放右侧，同时保持左右视觉重量平衡。音量、倍速、音轨、字幕和清晰度使用暗色播放器玻璃弹层；音量滑条拖动期间不要写设置文件，倍速弹层只保留自绘吸附滑条，不要恢复预设按钮或系统 Slider 刻度横线，滑块中心、吸附点和下方文字刻度必须使用同一有效轨道宽度。控制层锁定/解锁不要使用会抢视频帧的显隐动画。键盘调音量时只显示临时音量 HUD，不要唤出完整控制区。
- 筛选条不再显示“范围/筛选/排序”等前置标签。
- 筛选条左右内边距一致，内容不要贴边；首页标签、全部/正在观看/已观看/未观看/想看/喜欢和音乐筛选等同类胶囊必须复用 `GlassCapsuleControl`，不要改回系统 segmented picker 或各自手写不同按钮样式。
- 设置页右侧控件统一右对齐，设置页输入框输入后的文字必须居中显示，输入框宽度按当前文本长度在最小/最大宽度之间弹性变化。
- App 图标保持方案 1 的白色圆角底、彩色叠层卡片、蓝色播放卡、胶片孔和播放三角，但不要再绘制水波纹和音乐符号；导出时可裁掉源图外圈展示留白以去除可见白边，不要重画或替换图标主体。应用内图标必须保持统一蓝系无边框符号风格，不要加底板/边框，也不要所有图标套同一个模板。视频、音乐、保险库、媒体源、设置、元数据等要有明确辨识度。
- 媒体库和设置页右侧控件要保持统一右边界；选择菜单控制条应按当前选项文字在安全最小/最大宽度内自适应，弹出菜单应能容纳最长选项，避免恢复容易截字的固定窄宽度。精简选项文字时不能损失含义。
- “新建智能歌单”入口属于“音乐 > 歌单”页面，不要恢复到音乐侧栏；视频普通分类与智能集合之间不增加额外分隔线。智能集合和智能歌单的名称输入使用编辑语义图标，不要使用会显示为“格式”的 `textformat`。
- 侧栏内联新建入口必须与同层普通侧栏行复用相同的 `PlayfulSymbolIcon(size: 22)`、10pt 间距和文字起始线；不要给它单独增加会破坏对齐的圆角按钮内边距或背景。
- 媒体源页操作按钮应放在左对齐工具条玻璃卡片中，不要放回页头右侧。Emby 来源行的分类控件应保持和普通来源同款外观但不可操作，固定显示 `EMBY`，不要恢复普通手动重分类。
- 视频选择系统播放器时，设置页不要展示内置视频窗口宽度和内置视频说明；默认倍速/快进快退只有视频或音乐至少有一个仍使用内置播放器时才显示，默认音量不要再展示为设置项。

## 性能约束

- 首页、侧边栏和健康提示应复用 `AppState.reload()` 后生成的派生缓存，不要在 SwiftUI `body` 中对全量 `items` 反复 filter/sort/reduce，也不要在页面切换时同步调用 `FileManager` 做缺失文件或媒体源存在性检查。
- 普通媒体库列表使用 `LibrarySnapshotCache`，按目标页面、搜索、筛选、排序和 `libraryRevision` 缓存过滤排序结果；不要把全量 filter/sort 放回 `LibraryView.body`。
- 不需要鼠标光源响应的长列表卡片和设置分组优先使用 `staticSurfaceBackground`，不要在滚动热路径重新引入连续 hover 监听。重复出现的列表行、海报卡、专辑/艺术家/歌单卡片、设置项及其 hover/selected 状态必须留在 cheap 档：优先使用 `GlassSurfaceRole.repeated`、`repeatedSurfaceHover` 和 `RepeatedGlassButtonStyle`，不要因为 hover 又挂回 material、大阴影或实时 `pointerLiquidLight`。`glassFormField` 和 `GlassMenuButton` 也属于重复控件，必须保持静态暖白玻璃路径；`GlassSearchField` 只在页头少量出现时允许经 `HeaderControlGlassBackground` 使用单层 `.thinMaterial`，不要扩散到长列表行。ScrollView 长列表应接入 `suppressHoverEffectsDuringScroll()`，让鼠标滚轮和触控板滑动期间临时暂停行 hover 放大、pointer 光效和封面检视倾斜，停止滑动后再恢复效果。底部迷你播放器保留裁剪在底栏内部的静态专辑色柔光和按钮边缘响应，但不要恢复整条底栏鼠标液态光、播放时间驱动 blur 或任何会让音乐列表滚动时跟着重绘的全宽光效。
- 本地和远程 http/https 海报都必须通过 `ArtworkImageCache` 按目标显示尺寸下采样后缓存，缓存上限保持克制；不要恢复原图级 `NSImage(contentsOfFile:)` 缓存，也不要把 Emby 海报改回裸 `AsyncImage`，否则 hover、滚动或标签切换时会重新闪默认海报。打包脚本如果复制到 Homebrew 间接依赖的 `Python.framework`，只保留动态加载需要的框架二进制和骨架；不要把 stdlib、tests、docs、headers、bin/include/lib/share 等完整 Python 内容恢复进 App 包。
- 页面切换、播放器展开/收起、控制条显示/隐藏和歌词滚动动画统一使用 `AppMotion`；不要给整屏长列表套大面积隐式 scale 动画，也不要用 selection `.id` 强制重建详情区来制造切换动画。音乐展开/收起的性能瓶颈优先从根视图订阅、NSWindow chrome 写入频率、侧栏重排和 overlay 插入同帧竞争排查，不要误判为单纯 30fps 限帧或通过删视觉效果处理。普通页面切换优先直接替换内容，不要让大列表先清空再刷新。
- 视频库和音乐库搜索输入需要短去抖后刷新快照；筛选、排序和 `libraryRevision` 变化可以立即刷新。
- 音乐歌曲列表滚动路径应使用 `MusicTrackRowModel` 这类预计算行模型；不要在每个 row 的 `body` 中解析文件名、格式化时长或查找歌词文件。歌曲列表、歌单明细、专辑页和艺术家页必须走原生虚拟化 `List`，不能恢复会随滚动逐批增长并保留历史节点的超长 `LazyVStack`；专辑页视觉仍是网格卡片，但用 `List` 行承载网格列以便离屏回收。行 hover 反馈应保持固定高度，用绘制层高光、左侧光带和封面微缩放表达，视觉上参考媒体源列表 hover，不要对整行做 scale/offset，也不要恢复逐行实时径向 `pointerLiquidLight`。视频海报墙和设置页长内容继续保持惰性/分批或惰性堆叠路径，避免越滑越卡。
- 详情页和设置弹层中可能超过几十行的结果列表也必须走原生虚拟化 `List`，隐藏系统背景/分隔线并在行内保留玻璃卡片；当前元数据搜索结果、字幕搜索结果和音乐元数据候选列表都已迁移。不要把这些弹层结果列表退回 `ScrollView + LazyVStack`。
- 海报宽高比只能使用 `ArtworkImageCache` 已缓存比例、媒体分辨率兜底或默认比例；生成视频帧、默认封面和无正式海报路径的单视频应优先用 `MediaItem.resolution` 推导横版比例，避免先竖后横的布局跳变。不要在海报卡片 `body` 中同步调用 `NSImage(contentsOfFile:)` 或 `ArtworkImageCache.image(path:)`。
- 详情页、快速预览和播放器可以在用户明确打开某个条目时检查文件存在性；列表和页面切换路径不要同步访问文件系统。
- 需要响应媒体库变化的页面优先监听 `AppState.libraryRevision` 刷新本地快照，避免把大列表推导写成高频计算属性。
- 首页、视频分类页、音乐分类页和 EMBY 页的扫描按钮只扫描当前分类对应媒体源；全量扫描只保留在媒体源页“扫描全部”。音乐分类页切换必须显式按新 section 刷新快照并标记归属，避免标题和列表内容错位。
- 自动扫描只扫描已添加、启用 `autoScan` 且当前真实可访问的本地/挂载网络路径；网络设备重连后要清理海报缺失缓存，避免同一路径封面永久显示默认图。

## 推荐阅读顺序

1. `handoff.md`
2. `ROADMAP.md`
3. `README.md`
4. `CHANGELOG.md`
5. `Sources/MediaLib/App/AppState.swift`
6. `Sources/MediaLib/App/LibMpvClient.swift`
7. `Sources/MediaLib/Views/MusicPlayerView.swift`
8. `Sources/MediaLib/Views/LibraryView.swift`
9. `Sources/MediaLib/Views/MusicLibraryView.swift`
10. `Sources/MediaLib/Views/SettingsView.swift`
