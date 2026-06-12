# MediaLIB Roadmap

更新时间：2026-06-08

## 市场差距驱动路线

完整竞品能力矩阵、业务逻辑问题与阶段验收原则见 `MARKET_GAP_ANALYSIS.md`。截至 2026-06-08，已完成项与下一步队列如下：

1. ✅ 音乐播放队列、随机与循环状态跨启动持久化。
2. ✅ Emby 双向播放进度、已观看与收藏同步，并补 token 失效恢复。
3. ✅ 数据库 schema version、备份与恢复。
4. ✅ 分离“喜欢”与“想看”，新增视频想看列表、已看后自动移出想看和智能集合。
5. ✅ 将首页健康提示升级为可操作的片库健康中心。
6. ✅ FSEvents 增量扫描与统一后台任务中心基础闭环。
7. ✅ 内嵌章节、手动片头/片尾标记与跳过能力基础闭环。
8. 🟨 音乐响度均衡、无缝播放与可配置跨曲过渡：ReplayGain/R128、防削波均衡、单播放器柔和淡入，以及本地确定性下一首单项预加载/同播放器自动前进已完成；远程与随机队列的无缝策略、重叠交叉淡化和智能续播待专项验证。
9. ✅ Emby/远程视频本地缓存、质量选择、暂停/继续/取消、字幕同步、缓存删除、缓存筛选、系列自动缓存订阅、自定义未看集数窗口、整季规则、订阅暂停和局域网策略。
10. ✅ 任务中心持久化、远程封面预热、元数据补充和一键清理接入。
11. ✅ 评分/评级拆分、Emby 痕迹同步三档策略、首页纳入 Emby 顶层视频。
12. ✅ Batch A：手动视频集合基础、集合内排序、拼贴封面、首页发布、智能集合复合规则、缓存容量基础策略和 Emby 同步库选择已完成。
13. 🟨 Batch B：离线订阅计划、订阅到期、Wi-Fi 实时判断、离线首页、章节图/keyframes 手动预生成、自动片头/片尾审核、元数据修正历史与撤销、同步冲突表和冲突队列 UI 已完成；继续补章节图自动计划、失败重试、非媒体服务器下载策略和更深入的片头/片尾自动检测。
14. 🟨 Batch C：Jellyfin 连接器第一阶段、Plex 服务器 URL + Token 直连第一阶段、Trakt watched/watchlist 导入生成冲突、采用远端写入本机索引（含用户评级）和保留本地写回 Trakt 已完成；本地多档案功能已移除，继续推进 iCloud 同步、评分冲突来源接入、Plex/Jellyfin/Emby 更完整远端写回、Plex Discover/OAuth 与转码/字幕边界、Jellyfin 深层 Direct/Library 口径。
15. Batch D：Live TV/DVR、Provider Adapter、WebDAV/SFTP/云盘直连，暂缓到核心闭环稳定后。

## 当前优先级

### P0 播放器稳定化

- 验证 `dist/MediaLIB.app/Contents/Frameworks/libmpv.2.dylib` 及其依赖在新机器上无需 Homebrew 也能被动态加载。
- 如果 libmpv 启动失败，优先修正依赖复制、install name、rpath 和签名流程。
- 保留系统播放器兜底，避免单个视频导致主 App 崩溃。
- 继续完善当前 `PlayerView.swift` + `LibMpvClient.swift` 播放器，目标是支持：
  - 真实字幕轨道列表和当前选择状态
  - 真实音轨列表和当前选择状态
  - 播放器设置面板
  - 播放状态同步
  - 更接近 macOS 原生播放器的自定义液态玻璃浮动工具栏
- 当前 `NSOpenGLView` / `NSOpenGLContext` 构建警告属于 Apple 已弃用 OpenGL、推荐 Metal/MetalKit 的范围；因为 MediaLIB 依赖 libmpv render API 的应用内 OpenGL 承载视图，迁移需要单独设计 Metal/libmpv 渲染桥并做窗口、控制层、字幕和 AirPlay 回归验证，不作为普通小版本的直接替换项。
- Emby 已支持账号登录、受限凭据文件、token 失效自动重登、播放前会话校验、服务器媒体库选择、Movie/Series/Episode/Audio 分页同步、事务式远程索引替换、播放生命周期/收藏/已观看双向同步、独立 EMBY 目录、按有内容的服务端 Views 自适应显示、Episode 通过 SeriesId 挂到剧集详情页、远程海报缓存、内置/系统播放器播放远程流，以及系列自动缓存订阅和自定义未看集数窗口；Jellyfin 第一阶段已复用 MediaBrowser API 接入登录、受限凭据、`jellyfin://` 来源、库选择、索引同步、独立目录和播放/痕迹同步入口；Plex 第一阶段已支持服务器地址 + Token 直连、`plex://` 来源、库选择、索引同步、独立目录、播放源刷新、播放进度和已观看写回。下一步应补更细的 direct/library 口径、Plex Discover/OAuth、Plex 转码/字幕边界和跨服务失败恢复。
- SMB/FTP 已支持通过 macOS 挂载后选择目录扫描，并可在扫描前或离线来源行触发系统重新挂载；下一步可补 Bonjour/局域网发现和更细的挂载状态诊断。

### P0 音乐播放闭环

- 当前已有内存级音乐队列、上一曲/下一曲、独立随机播放开关、顺序播放/队列循环/单曲循环模式；播放器队列弹层支持清空、移出、点击播放、拖拽排序和存入歌单。用户手动歌单已通过 `music_playlists` / `music_playlist_items` 持久保存，只记录内部媒体索引，不移动用户音乐文件。音乐与视频控制栏已接入 AVKit 隔空播放入口，音乐 route picker 由控制器持久绑定最近的 `AVPlayer`，可见按钮主动触发隐藏的原生路线选择器；音乐输出遵循系统 AVPlayer 外部路线逻辑，不再提供本机同播开关；macOS 菜单栏和系统媒体键会通过统一 `PlaybackCommand` 触发基础控制。
- 音乐队列拖拽排序已暂停拖动期间的滚动锚点恢复，并对跨行移动节流；后续若继续优化队列，重点观察超长队列在系统自动滚动边缘的排序可控性，不要恢复拖动中 `restoreQueueScroll`。
- 后续需要用真实 AirPlay 设备验证路线选择后的暂停、seek、音量、倍速、切歌和关闭路径，尤其关注系统 route 状态回调滞后时 UI 状态是否能及时同步。
- 播放队列、随机与循环状态已经通过 `MusicQueueRepository` 跨启动持久化；启动只恢复队列状态，不自动播放或主动显示底栏。后续继续补更清晰的队列上下文、智能续播；不要把当前队列重新做成侧边栏里的独立页面。
- 继续让歌曲列表、专辑、艺术家和歌单入口都能向同一个播放器队列投递播放上下文。
- 内置音乐播放已切到原生 AVFoundation 后端；继续验证播放按钮、进度条、音量弹出滑条在真实曲库和不同音频格式下的表现。
- 音乐扫描已持久化 ReplayGain/R128 曲目/专辑增益和峰值，播放器按设置应用防削波音量系数；即时衔接使用单个 `AVQueuePlayer`，仅为本地顺序播放/队列循环保留一个确定的下一首，限制预读并在同一播放器中自动前进。随机、远程资源和柔和淡入不预加载；下一阶段若引入远程预加载或双播放器重叠交叉淡化，必须先验证 AirPlay、歌词真实时钟、队列状态和内存占用。

### P1 UI 统一和性能

- 持续检查所有页面卡片、选项栏、设置行右侧控件对齐；设置输入框文本应居中显示，并按文本长度在最小/最大宽度之间弹性收窄或展开。
- 保持卡片底色偏白、低噪声、液态玻璃感；除音乐展开播放器外，各页面统一使用同一套白玻璃材质、从左上角射入的低饱和象牙白/珍珠冷白环境光、冷灰细描边和边缘轮廓光，侧栏使用更透明的 `ultraThinMaterial` 冷蓝玻璃，低洗色以保留模糊桌面背景。
- 鼠标光源液态玻璃效果已经接入通用卡片、玻璃菜单、音乐展开页和歌曲行；后续如新增自绘控件，应优先复用低饱和的 `pointerLiquidLight`、`pointerLiquidEdge` 和 `GlassCapsuleControl`，并避免全局鼠标驱动整页刷新。普通页面玻璃按钮需要通过白色填充与下层玻璃拉开层级；音乐播放器相关按钮则保留专辑色轮廓光。视频海报检视倾斜通过 `pointerInspectTilt` 限定在封面区域。静态长列表表面优先用 `staticSurfaceBackground` 的轻量渲染路径，避免在滚动热路径恢复系统 material、blur、多层阴影或逐行连续 hover 光源；同时确保 hover 放大、检视倾斜和连续光效支持 Reduce Motion 降级。
- 歌词卡片的舞台光只应作用在卡片内部、文字下层；歌词当前行和逐字高亮应使用播放器回读的 `lyricTime`，不要直接用进度条 seek 立刻写入的 `currentTime` 判定普通播放当前行。seek 目标和真实落点必须来自 `MpvPlayerController.seekState`：`scrubbing` 阶段按拖动目标实时定位歌词句，`seeking` 阶段按目标时间区间 `[本行时间, 下一行时间)` 等待播放器落地，`settled` 阶段按播放器真实落点覆盖到真实句；第一条大于目标时间的歌词时间戳只作为结束边界。进度条组件必须在拖动开始、变化和结束分别调用 `beginScrubbing`、`updateScrubbing`、`finishScrubbing`。LRC `[offset:+/-毫秒]` 必须作用到普通行和增强片段时间，同时间戳/近同时间戳的双语歌词行必须合并为一个显示块，避免固定一行错位。控制器 pending seek 期间必须屏蔽旧播放时间回写，普通轮询只有同时离开 seek 前旧位置且靠近目标时才可确认落点，AVPlayer seek completion 只有 `finished == true` 才能强制采纳真实落点，必要时节流补发底层 seek。远距离 seek 对齐必须重置歌词滚动视口并无动画居中目标/真实行，普通播放推进才使用平滑滚动。旧 recovery/boundary/serial/`TimelineSeekSnapshot` 多补丁链路已删除，不要恢复。底栏收起/展开动画应保持完整父层宽度，让封面在同一上层坐标系里横向滑动。收起态进度环应在封面外侧，深色代表已播放、浅色代表未播放。展开页暂停封面后退动效已局限在封面层，并通过单一连续视觉进度同步封面缩放、位移、阴影、光晕、背景节奏光和近场光，后续不要为了暂停态重建整页背景或恢复分段关光；暂停末端 glow 应收敛到接近 0，环境光可轻触歌词卡片和控制栏但不要破坏封面周边均匀光距。
- 普通页面表单输入、弹窗结果和选择项应继续向 `glassFormField`、`GlassCapsuleControl` 和静态 `LiquidGlassSurfaceLayer` 收敛；不要让新弹窗回到默认 rounded border 文本框、白色 `List` 或系统 segmented 外观。
- 全局动画继续使用更慢的非线性 `AppMotion` 曲线；新增页面转场、悬浮控件和列表反馈不要回到短促线性/ease-out 节奏。
- 首页标签栏应先按实际宽度保持单行，放不下时再切到可拖动双行展示，不能用固定数量阈值强制双行，也不能让右侧标签被窗口边缘遮住。
- 首页和首页设置只显示有内容的 tab；媒体库分类切换必须显式刷新到新 destination，不能出现标题与网格内容落后一拍。
- 音乐展开页收起按钮保持 `MusicExpandedLayout` 内左上等距胶囊定位，并复用歌词卡片材质；音乐默认封面和音乐图标保持蓝青主题。
- 音乐展开页封面 glow 继续只走 `MusicExpandedArtwork` -> `AlbumBlurredCoverGlowLayer` -> `AlbumCoverGlowBakeCache` 后台烘焙路径。near/mid/far 应作为大范围 image-based glow 使用，允许保色相的轻量饱和/对比回补抵消大半径模糊发灰，但不能混入 palette 主色、恢复旧物理边缘发光或运行时 SwiftUI 大模糊。底板继续由单个 `MusicPlayerMetalBackdropView` 绘制，只负责不透明专辑色底和整窗玻璃厚度感；发灰问题只能小幅检查 `paintPalette`、`cleanMetalBaseColor`、`glassifyAlbumColor` 和 shader 常量，不要提高整窗 artworkOpacity、不要叠全屏渐变或 material。
- 音乐展开页视觉链路修订为四层：L0 Metal 直接采样 `paintPalette` 的封面高斯色场，L1 shader 内整窗厚玻璃盖板，L2 歌词卡/控制栏/封面/收起按钮，L3 按钮和文字。封面外光必须保持 Metal 底板 + 预烘焙 image-based glow，不迁回全屏 SwiftUI blur；投射光按封面中心圆形等距扩散，受光组件通过方向化 `AlbumLightSpillOverlay` 染色，组件自身不再带彩色底。
- 音乐展开/关闭动画应继续保持轻量：整屏播放器表面不要恢复 matched geometry，窗口 chrome 切换、播放器 overlay 插入和侧栏收起/恢复不要同帧执行；当前通过先准备沉浸 chrome、再插入播放器、最后后台收起侧栏来削峰。根视图不要订阅音乐播放进度，窗口 chrome 守卫只在状态变化时写 `NSWindow`。背景律动只在展开稳定且播放中运行。专辑光效可以覆盖更大区域，但必须使用低频柔和位移和少量合成层；底部迷你播放器的专辑色光效必须裁剪在底栏内部。
- 音乐播放器最小化后侧栏恢复应在播放器缩到底栏后再执行，使用统一侧栏曲线但避免和播放器大层转场同帧抢主线程。
- 避免筛选条出现“范围/筛选/排序”等前置说明。
- App 图标继续以用户提供的方案 1 原图源生成，新增或重生成时不要把外侧拍摄边框/背景带入图标；应用内图标继续使用统一蓝系无边框符号风格，但新增图标必须按功能重绘，不能回到“一套模板套所有页面”。
- 设置页继续保持“选择系统播放器时隐藏内置播放器专属项”的规则，避免视频/音乐播放器设置互相污染。
- 优化音乐长列表滚动，减少同步文件读写、主线程图片解码和大面积离屏合成；歌词存在性、缺失文件和离线源这类文件系统检查应保持后台缓存，不要回到 SwiftUI 热路径。
- 超长音乐歌曲、歌单、专辑和艺术家页面继续使用预计算行模型和原生虚拟化 `List`；专辑页保持网格视觉但由 `List` 行承载多列卡片。hover 只保留接近媒体源行的固定高度绘制层、左侧光带、封面微缩放和轻阴影，不要恢复逐行实时径向光源。
- 音乐专辑网格、艺术家列表、视频海报墙和设置页长内容都应保持惰性/分批路径，避免用户越滑越卡，同时不显示“正在加载下一批”的占位。海报墙页顶部可以使用轻量材质渐隐遮罩柔化滑出边缘，但不要把整页 ScrollView 放进大 blur 或 material 容器。
- 底部迷你播放器保持透明液态玻璃和完整封面显示；其专辑色柔光应为裁剪在底栏内的低成本静态层，不要再用播放时间驱动的大面积 blur 重绘整条底栏。列表/设置等页面开始滚动时允许底栏收起到右侧封面形态，完整底栏封面和收起态封面要用同一几何身份平滑横向移动，封面变暗并显示低开销真实音频频谱，暂停时频谱静止，点击封面再展开完整底栏。
- 底部迷你播放器不再启用鼠标驱动的整条光效或按钮指针采样；保留完整 72pt 圆角裁剪内的静态专辑柔光和克制轮廓染色即可，不要把纵向 padding 放回圆角玻璃裁剪层外。
- 滚轮/触控板滑动路径已通过 `suppressHoverEffectsDuringScroll()` 临时抑制 hover 光效，后续新增 ScrollView 或长列表时应接入同一修饰器，停止滑动后再恢复放大、检视倾斜和鼠标光源。
- 音乐歌曲、专辑、艺术家、歌单、最近播放等页面切换必须保持快照归属标记，避免标题变了但内容仍显示上一分区。
- 音乐分区切换应优先复用目标 section 的快照缓存；如果新快照尚未生成，不要先清空列表显示“暂无/加载”，避免用户察觉页面正在重算。
- 分类页扫描保持按当前分类扫描对应媒体源；全量扫描只从媒体源页入口触发。
- 自动扫描已接入本机 FSEvents 增量更新、任务中心和单源 `autoScan` 开关；后续重点是任务持久化、失败重试与更细的事件诊断。
- 检查左侧栏切换：首页、视频分类、音乐分类、设置页之间不应出现明显卡顿；分类页复用 SwiftUI view 时必须监听目标 destination 变化刷新本地快照，避免标题变化但内容停留在上一分类。
- 清除播放记录只能重置痕迹字段并同步内存快照，不能触发整库 reload 或让音乐列表短暂空白。

### P1 音乐元数据

- MusicTag 精简工作台已接入设置页，支持批量预览、编辑、更新索引和显式写回音频文件标签；后续可补更精细的候选评分、冲突对比、失败重试、撤销/备份保留策略和更完整的封面嵌入格式验证。
- 为歌词和封面增加缓存表，避免重复联网和重复读盘。
- LRC 已解析为带时间戳模型并支持自动滚动；增强 LRC 的 `<mm:ss.xx>` 片段时间戳优先使用真实逐字/分词高亮，普通逐句 LRC 缺失逐字时间戳时会在加载歌词时预计算 estimated 逐字时间轴，按快速估算、语速校准、音频校正或精确优先四种设置选择不同策略。估算会结合字符/单词权重、标点停顿、句尾留白和全曲语速校准，音频校正与精确优先会后台分析本地音频并缓存 aligned 结果，播放时先用备用估算再无缝切换。点击歌词行可跳转到对应播放位置，手动浏览或 seek 后会在下一句自动校正到当前播放行。后续可评估接入真正 CTC/强制对齐模型或服务端对齐。
- 当前歌词行已采用 Apple Music 式逐字/逐片段垂直位移，未播放文字略低、播放到时缓慢上升并轻微放大；上浮高度差已收敛，后续歌词优化应沿该方向微调，不要恢复呼吸亮度或整行硬切渐变。
- 对 MusicBrainz / iTunes Search 自动匹配增加冲突处理、重试和失败记录。
- 评估新增 `music_tracks`、`music_albums`、`music_artists` 以及歌词/封面缓存表；`music_playlists` / `music_playlist_items` 已用于手动歌单。

### P2 扫描和元数据扩展

- 本机 FSEvents 增量扫描、取消扫描和会话级任务中心已完成基础闭环；后续补任务持久化、失败重试和历史诊断。
- 更完整的 ffmpeg/VideoToolbox 截帧策略和失败原因展示，继续改善 MKV、WebM 等 AVFoundation 不支持格式的封面生成。
- 文件夹结构变更已监听并安全降级为完整来源扫描；后续评估更细粒度的目录移动配对与诊断信息。
- TVDB、Douban 或其他刮削源。
- 字幕自动下载。
- 更完整的 NFO 和本地图片规则。

## 技术债修复计划

> 更新时间：2026-05-29。以下问题由代码审阅发现，Codex 历次迭代未覆盖。按三阶段推进，不降低任何视觉效果。

### Phase 1 ✅ 安全与正确性（已完成）

| # | 问题 | 文件 | 修复方案 |
|---|------|------|----------|
| P1-1 | `MusicPlaylistRepository.replaceItems` 事务跨多次 `queue.sync`，后台扫描操作可插队导致数据交织或意外回滚 | `DatabaseManager` / `MusicPlaylistRepository` | 新增 `transaction<T> {}` 方法，内部用单次 `queue.sync` 包裹 BEGIN/block/COMMIT；`execute`/`query` 检测当前线程是否已在队列上，实现可重入 |
| P1-2 | `addSource`/`addSources` 不检查重复路径，触发 SQLite UNIQUE 约束异常 | `AppState` | 添加前检查 `sources` 是否已含同路径 |
| P1-3 | `lockPrivacy()` / `removePrivacyPIN()` 不停止正在播放的私密内容 | `AppState` | 清理 `activePlayerItem` / `quickPreviewItem` 若属于私密条目 |
| P1-4 | `runAutomaticScanIfNeeded` 遇到不可达源时对用户弹窗，自动扫描应静默跳过 | `AppState` | `startScanQueue` 增加 `silent: Bool` 参数，自动扫描路径传 `true` |
| P1-5 | `EmbyService.validate` 将服务端原始响应体暴露在错误弹窗中，可能含 token/内部路径 | `EmbyService` | 仅记录 HTTP 状态码，原始 body 写日志不上报 UI |
| P1-6 | `FilenameParser.firstMatch` 每次调用重新编译 `NSRegularExpression`，扫描大库时 O(N×模式数) 编译开销 | `FilenameParser` | 将全部固定模式预编译为 `static let` 字典，`firstMatch` 查缓存复用 |
| P1-7 | `LocalMetadataService.tag()` 同样每次调用重新编译正则 | `LocalMetadataService` | 预编译 4 个固定 tag 名称的正则为 `static let` |
| P1-8 | `AudioMetadataReader.embeddedArtworkPath` 每次重扫无条件覆盖写入封面文件，大音乐库重扫 I/O 高 | `AudioMetadataReader` | 写入前检查三种扩展名是否已存在，命中则直接返回现有路径 |

### Phase 2 ✅ 性能优化

| # | 问题 | 修复方向 |
|---|------|----------|
| P2-1 | `MediaScanner.scan` 先删后扫，任务取消即丢失该源全部数据 | ✅ 已改为成功扫完整源后用 keep 表清理未再次出现的旧 ID；扫描取消或有错误时保留旧索引 |
| P2-2 | `rebuildDerivedItemCaches` 对 `items` 做 8–10 次独立线性扫描 | ✅ 已合并为单次 `for item in items` 分类分桶 |
| P2-3 | `updateFavoriteInMemory` 遍历 `cachedChildrenByParentID` 全部子条目 | ✅ 喜欢与想看仅更新目标所属父级的子条目缓存 |
| P2-4 | `MusicPlaylistRepository.fetch(id:)` 调用 `fetchAll()` 加载全量歌单 | ✅ 直接查询目标歌单与其有序歌曲 |
| P2-5 | `ExternalPlayerService.availablePlayers` 每次同步访问文件系统（4 次 `fileExists`） | ✅ 结果缓存，并在 App 激活、外部播放器启动/退出或自定义路径变化后刷新 |
| P2-6 | `AppState.items(for: .video(.watching))` 无专属缓存，每次重算 | ✅ 公共与保险库正在观看条目均在派生缓存重建时预计算 |

### Phase 3 🔲 功能完善

| # | 问题 | 修复方向 |
|---|------|----------|
| P3-1 | Emby `fetchItems` 无分页，大媒体库数据被服务端默认限制静默截断 | ✅ 已循环读取 `StartIndex` 直到拿到全部条目 |
| P3-2 | `fetchLyricsIfPossible` 无条件覆盖用户手动制作的 LRC 文件 | 仅在同名 `.lrc` 不存在时才写入 |
| P3-3 | `MediaItem.isPlayable` 含同步文件 I/O，不应在列表热路径调用 | 改为仅在详情页/播放前显式调用；列表路径依赖 `cachedMissingFileItems` |
| P3-4 | Emby `BoxSet`/`Season`/`MusicAlbum` 等类型被 `compactMap` 静默丢弃 | 按需映射更多 Emby 类型 |
| P3-5 | `MediaItem.hasEmbeddedArtwork` 依赖路径字符串模式，隐式约定易失效 | 数据库增加 `has_embedded_artwork` 布尔列或显式字段 |
| P3-6 | `queueItems(after:)` 含隐性副作用（修改 `musicQueue`） | 重命名并与 `prepareMusicQueue` 职责分离 |

---

## 交付要求

- 每次修改后运行：

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks
scripts/package_dmg.sh
```

- 每次交付都更新：
  - `CHANGELOG.md`
  - `handoff.md`
  - 涉及用户行为时更新 `README.md` 和 `用户使用说明.md`
  - 涉及开发规则时更新 `AGENTS.md` 和 `开发说明.md`
