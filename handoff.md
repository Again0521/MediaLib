# MediaLIB 交接文档

更新时间：2026-06-10（音乐展开页底板/发光/玻璃/舞台光整体重构，详见 `MusicPlayerView_Metal_Backdrop_Refactor_Plan.md` 2026-06-10 节与 `CHANGELOG.md`）  
工作目录：`/Users/again/Documents/Codex/2026-05-19`

## 1. 项目目标

MediaLIB 是一个面向 macOS 的本地/NAS 家庭影音媒体库应用，目标不是 Demo，而是可安装、可维护、可扩展的软件。核心目标包括：

- 管理本地硬盘、移动硬盘、SMB/FTP 网络设备、已挂载到 `/Volumes` 的 NAS 媒体目录和 Emby/Jellyfin/Plex 服务器资源。
- 同时支持视频媒体库和音乐媒体库，两者在左侧栏中作为同级一级模块。
- 视频支持电影、电视剧、动漫、纪录片、综艺、其他、保险库等分类；分类只改变 MediaLIB 内部索引，不改变物理文件位置。
- 音乐支持歌曲、专辑、艺术家、歌单、最近播放等二级入口；收藏已作为“音乐 > 歌单”中的不可删除置顶歌单展示，可在歌单明细中移出歌曲来取消收藏，“未匹配歌曲”不再作为左侧栏入口。播放队列统一通过播放器内队列按钮弹层管理，手动歌单通过“音乐 > 歌单”持久保存，只记录内部媒体索引，不移动或改名音乐文件。
- 支持本地扫描、SQLite 持久化、海报/封面生成、详情页、随 App 分发的 libmpv 内置播放器、系统播放器、保险库上锁、元数据搜索。
- 支持 Emby/Jellyfin 登录同步和 Plex 服务器 URL + Token 直连同步，远程 token/网络凭据保存在 Application Support 的 `MediaLib/Credentials` 文件中，不再触碰系统钥匙串；资源与内部条目通过 `sourcePath + externalID` 映射。
- Emby 已成型，Jellyfin 第一阶段已复用 MediaBrowser API 接入；两者都支持播放进度、播放生命周期、收藏和已观看痕迹数据同步，并可在来源设置弹窗中选择双向同步、仅从服务器同步或数据不同步。设置弹窗也可选择要纳入 MediaLIB 的服务器媒体库，空选择保持全库同步，指定后只同步所选 ViewId；新连接会保存自动恢复登录所需凭据，API 或播放前校验遇到 401/403 时自动更新 token 与流地址。
- 数据库已使用 `PRAGMA user_version` 顺序迁移；升级前自动保留一致性快照，设置“高级”支持立即备份、打开备份位置和恢复。恢复前会校验完整性/版本并自动保存当前数据库，只替换内部索引，不触碰媒体文件。
- 视频“喜欢”与“想看”已分离；本地与 Emby 顶层视频可使用本机想看状态。视频智能集合按媒体类型、状态和最近加入时间保存规则并动态求值；手动视频集合通过右键菜单和批量选择显式加入/移除条目，并可在集合页右键调整置顶、上移、下移和置底；侧栏与集合页头从集合内前几项自动生成拼贴封面。两类集合都只保存 MediaLIB 内部规则或条目 ID，不复制媒体条目或文件。
- 首页健康提示与侧栏“片库健康”已接入可操作健康中心，覆盖离线来源、失效路径、疑似重复组和核心元数据缺口。文件系统检查在后台完成，页面只消费派生缓存；清理只调用 `MediaRepository.deleteItems(ids:)` 删除内部索引并显式确认，离线来源和锁定保险库内容受保护，重复项不会自动合并。
- 本机自动扫描已接入 FSEvents 增量更新：文件事件经 1.2 秒合并后进入 `MediaScanner.scanChanges`，只处理受影响路径；目录删除/重命名、root change 或 event dropped 降级为完整来源扫描。SMB/FTP/NAS 继续周期完整扫描，不能用网络文件事件删除索引。侧栏“任务中心”持久化展示完整扫描、增量扫描、Emby/Jellyfin 同步、封面预热、视频缓存、章节图、元数据补充和一键清理，扫描可取消；保险库任务、浮窗、系统通知和日志只使用通用说明，不展示条目名、路径、文件名或具体错误对象；重启后未完成任务标记为失败/中断。
- 数据库当前 schema v18，在既有播放标记、响度、智能歌单、健康/元数据参与开关、genre 字段、`prefer_metadata_write_to_source`、`remote_trace_sync_mode`、`user_rating`、手动集合表、`video_smart_collections.rules_json`、手动/智能视频集合 `show_on_home`、Emby/Jellyfin/Plex 来源 `selected_emby_library_ids` 和 `video_offline_subscriptions` 基础上，新增 `metadata_correction_history`、`sync_conflicts`、`remote_connector_accounts`、`local_user_profiles`、`profile_media_state`。库选择字段名沿用 Emby 以兼容旧库，空值表示兼容旧行为的全库同步，非空时只同步指定服务器库，并通过远程索引替换清理未选库的内部条目。`rating` 为 TMDB/Emby/Jellyfin/Plex 等资料源 0-10 评分，`user_rating` 为用户 1-5 星评级；手动集合只保存内部 `media_items.id` 顺序并通过外键级联清理；自动缓存订阅保存系列 ID、模式、集数窗口、目标季、清晰度、启用状态、暂停到期、计划到期和网络策略，未看窗口可设为快捷值或 1 到 99 的自定义值，后台只投递现有视频缓存任务；右键菜单可设置不自动到期或 7/30/90 天后到期，过期清理只删除内部订阅规则，不删除已缓存视频；元数据修正历史按 batch 记录字段旧值/新值，详情页可撤销最近一次覆盖，设置页也可按批次撤销；连接器账号和同步冲突只保存 MediaLIB 内部同步承载数据，Emby/Jellyfin 登录同步和 Plex Token 直连同步会写入本地连接器账号；本地多档案功能已移除，播放进度、播放次数、已看、喜欢、想看和评分统一使用全局内部索引；设置页冲突队列采用远端可把已看、想看、喜欢和用户评级写入 MediaLIB 内部索引，评级冲突只更新 `user_rating`，不覆盖资料源 `rating`；Trakt watched/watchlist 冲突选择保留本地会写回 Trakt，合并和都保留仍记录处理选择，Jellyfin 登录/库同步/播放入口与 Plex 服务器 URL + Token 直连已接第一阶段，iCloud 网络流程仍需后续协议实现；迁移、备份和恢复必须继续使用 SQLite backup API；响度、队列、歌单、视频集合、自动缓存订阅、健康检查、痕迹同步策略、Emby/Jellyfin/Plex 库选择、同步冲突和元数据写回偏好都只作用于 MediaLIB 内部索引、远端状态 API 或用户明确允许的本地标签/sidecar 写回，不移动、不改名用户媒体文件。
- UI 目标是 macOS 26 风格：暖白珍珠液态玻璃、少量蓝系强调、低视觉噪声、统一页头/卡片/列表/播放器控件。
- 最终产物是 DMG 包；当前 DMG 输出路径保持 `dist/MediaLib.dmg`，包内应用显示为 `MediaLIB.app`。

## 1.1 2026-05-25 最新补充

- 2026-06-09 最新补充：音乐展开页歌词与玻璃第三轮微调完成，并在随后补齐同时间戳锚点选择。`LyricSourceParser.coalescedTimestampLines` 不再无条件合并 80ms 内同时间戳歌词；检测到“含假名日文原文 + 纯汉字中文翻译”时保留为相邻独立行，完全重复文本仍去重，显示顺序仍沿用歌词文件。`TimedLyricLine.playbackPosition` 会在这类同时间戳组中优先选择含假名日文原文作为播放/滚动锚点，翻译行在 `MusicTimedLyricsScrollView` 中作为低模糊伴随行显示，不再抢当前高亮。歌词卡、控制栏和收起按钮降低 `.hudWindow` material 灰雾和内部黑色 shade，歌词卡中心 fill 更透明，上下雾面/纹理/发丝高光略增强；中心舞台光改为更宽的专辑色椭圆光池，白色 specular 继续很低。底板微提 `paintPalette` saturation/vibrance、role color 饱和上限与 `kChromaBoost = 1.10`，但 `kGlowStrength = 0.60`、`kWhiteVeilStrength = 0.065`、黑色不发光和亮区高光压缩规则不变。后续如继续调截图，优先沿 `LyricAlignmentService.swift`、`FloatingLyricsGlass`、`LyricsCardEffectLayerView` 和 `MusicPlayerMetalBackdropView` 小步调参，不要新增全屏 blur/material 或把玻璃底改成专辑色实底。
- 2026-06-09 最新补充：音乐展开页底板取色与玻璃受光第二轮重构完成。黑色/近黑不再作为发光色源：`AlbumColorPalette.lightEmitterWeight` 降低近黑采样发光权重，`AlbumCoverGlowBakeCache.lightEmitterMask` 让 glow 烘焙按更高亮度门控，黑区只保留深度阴影；`AlbumGlowBakeKey.bakeVersion` 当前为 16。`MusicPlayerMetalBackdropView.paintPalette` 当前为约 38 网格、15px softening，取消强鲜艳度回补，shader 常量当前为 `kGlowStrength = 0.60`、`kWhiteVeilStrength = 0.065`、`kChromaBoost = 1.10`；`glassifyAlbumColor` 会把近黑区域送入 clean shadow、对灰棕/灰绿风险做清洁，`harmonicShift` 只对亮度和色度足够的区域做连续和声偏移，让底板同源但不照抄封面。封面 glow 三层和 projected 三层范围略扩但 alpha/饱和度/对比更低；`--music-player-visual-debug-black` 可用于回归黑底少量亮部夹具。歌词中心舞台光、玻璃上沿、`AlbumLightSpillOverlay` 和 `LyricsCardEffectLayerView` 的静态/指针高光都改为专辑色低饱和 tint 为主，白色只保留薄 specular；前景玻璃底材质仍保持中性，不能改成专辑色实底。后续调底板仍优先改 `paintPalette`、shader 常量、`glassifyAlbumColor`、glow bake 的亮度门控和 alpha/clamp，不要恢复全屏 SwiftUI blur/material，也不要把近黑封面边缘重新当作 emission。
- 2026-06-09 最新补充：远程来源隔离与通知反馈收束完成，无 schema 变更。Emby/Jellyfin/Plex 继续复用远程媒体服务器路径，但扫描当前远程分区或服务器媒体库时只刷新所属来源；本地视频目录、视频智能集合和手动集合不再纳入远程条目，远程内容只显示在各自远程一级目录和首页聚合中。清除播放记录会级联清理系列子集，避免远程正在观看清空后首页“下一集”仍被旧子集痕迹推出。视频/音乐智能集合、手动集合、媒体源设置和详情页元数据搜索结果应用点击保存/应用后立即关闭弹窗；集合/歌单/媒体源保存、远程库刷新、Trakt 导入/写回、远程状态回写和元数据写入结果都通过任务通知反馈。任务完成时 App 不在前台会优先走系统通知，未授权或不可用时回到前台补发软件内通知，前台软件内通知仍排队逐条展示。分类选择统一为 3x3 弹性按钮网格，片库健康四张摘要卡使用四等分弹性宽度，设置/规则菜单按当前选项文字自适应宽度。
- 2026-06-08 最新补充：音乐展开页附件实现第一轮已恢复构建基线。`Sources/MediaLib/Views/MusicPlayerLyricsCardEffectLayer 2.swift` 是旧版效果层副本，会被 SwiftPM 当作普通源码编译并与新版 `LyricsCardEffectLayerView` 重复定义，已删除；当前唯一入口是 `MusicPlayerLyricsCardEffectLayer.swift`，继续承载 `MusicGlassSurfaceRole`、静态玻璃层、pointer 高光层、`centerClarity` 和专辑色染边。后续做临时备份请放到 `artifacts/` 或源码目录外，不要留在 `Sources`。
- 2026-06-08 最新补充：Batch B 离线订阅 Wi-Fi 实时判断已完成，无 schema 变更。`AppState` 启动 `NWPathMonitor`，通过 `videoOfflineSubscriptionWiFiAvailable` 记录当前系统网络路径是否使用 Wi-Fi；右键“自动缓存系列 > 网络策略”现在开放“仅 Wi-Fi”。维护候选过滤中 `.wifiOnly` 只在 Wi-Fi 可用时排入新的自动缓存任务，Wi-Fi 状态变化会触发一次低延迟维护；已经在任务中心运行的手动或自动缓存不会被网络变化强制停止，避免误伤用户主动任务。
- 2026-06-08 最新补充：Batch B 离线首页入口已完成，无 schema 变更。`HomeTab.offline` 加入默认首页标签，并会把旧版默认首页配置迁移为包含“离线”；`AppState.homeOfflineVideoItems` 从 `homeVideoItems` 的本地公开视频和远程服务器顶层视频中筛出已缓存条目或部分缓存系列，`availableHomeTabs` 会随 `videoCacheRevision` 动态显示/隐藏离线标签。`HomeView` 的快照 key 监听 `videoCacheRevision`，缓存完成、删除或清理后会刷新离线页；保险库缓存不进入该入口，锁定态仍不泄露。`MediaLibChecks` 已覆盖默认首页标签与旧默认标签迁移。
- 2026-06-08 最新补充：Batch B/C 基础闭环继续推进，schema 升至 v18。`metadata_correction_history` 按 batch 记录每次元数据覆盖的字段旧值/新值、来源和撤销时间；`MediaRepository.updateMetadata` 返回字段差异，`AppState.updateMetadata` 统一记录详情页 TMDB/音乐信息应用、音乐标签工作台、一键音乐补全和健康中心一键补充；详情页有历史时显示“撤销元数据”，设置页“连接器与同步”可打开元数据历史列表并按批次撤销，只回滚 MediaLIB 内部索引。`sync_conflicts` 和 `remote_connector_accounts` 为 Emby/Jellyfin/Plex/Trakt/iCloud 同步冲突与远程账号提供统一承载；设置页“连接器与同步”可打开同步冲突队列，记录保留本地、采用远端、合并、都保留或忽略；采用远端会把已看、想看、喜欢和用户评级写入 MediaLIB 内部索引，Trakt 保留本地会把 watched/watchlist 写回 Trakt；Jellyfin 第一阶段同步和 Plex 服务器 URL + Token 直连第一阶段已接入媒体源页统一添加向导，Trakt 已支持从远端导入 watched/watchlist 差异生成冲突，iCloud 仍不提供未接好的同步按钮。`MediaLibChecks` 覆盖 v18 表、元数据历史撤销、历史批次汇总、同步冲突 resolve/ignore、Jellyfin/Plex/Trakt 账号 round-trip、Trakt 稳定冲突 ID、Trakt sync payload 和同步冲突值解析。
- 2026-06-08 最新补充：媒体源添加入口已收敛为单一“添加媒体源…”按钮。`SourcesView` 使用 `AddMediaSourceWizardSheet` 三步向导选择本地目录、网络设备、Emby、Jellyfin 或 Plex；第二步完成目录选择/分类、SMB/FTP 挂载信息或远程服务器凭据，第三步确认元数据拉取、健康检查、本地/网络写入源目录偏好或远程痕迹同步策略。旧 `RemoteMediaServerLoginSheet`、`NetworkMediaSourceSheet`、`MediaSourceTypeSelectionSheet` 和工具条上的 Emby/Jellyfin/Plex/网络设备分散按钮已移除。后续不要恢复多个添加按钮；远程连接提交后仍立即关闭向导，认证与同步进入后台任务中心。
- 2026-06-08 最新补充：媒体源行内选项框已收纳到设置弹窗。`SourceRowView` 只保留设置、扫描、删除和必要的重新挂载等操作按钮；每行设置按钮打开 `SourceSettingsSheet`，本地/网络来源可改分类、元数据参与、健康检查和写入源目录偏好，Emby/Jellyfin/Plex 来源可改服务器库选择、元数据/健康参与和痕迹同步策略。后续不要把分类菜单、同步库菜单、参与检查菜单或痕迹同步菜单恢复到来源行内。
- 2026-06-08 最新补充：Batch C Jellyfin 连接器第一阶段已完成。`MediaSourceKind.jellyfin`、`jellyfin://` source path、统一添加向导里的 Jellyfin 来源、受限凭据 kind、`remote_connector_accounts` 写入与失败清理都已接入；同步复用 `EmbyService` 的 MediaBrowser API，稳定 ID 使用 provider 前缀避免和 Emby 冲突，库选择继续复用兼容字段 `selected_emby_library_ids` 但内部同时服务 Emby/Jellyfin。远程目录 summary ID 已改为 `sourceID::viewID`，避免多个服务器 ViewId 重名撞车；播放、远程流 URL 刷新、收藏/已观看痕迹同步和视频缓存沿用远程媒体服务器路径。该阶段只修改 MediaLIB 内部索引、凭据和账号表，不修改 Jellyfin 服务端媒体文件；后续继续补评分冲突来源接入、iCloud、更多连接器远端写回，以及 Jellyfin 专属发现、多用户授权、Direct/Library 口径和失败恢复。
- 2026-06-08 最新补充：Trakt 双向同步第一阶段已完成。`TraktService.fetchRemoteState` 拉取 `/sync/watched/movies`、`/sync/watched/shows` 和 `/sync/watchlist`，只使用 TMDB id 映射本地公开视频；`AppState.importTraktState()` 在设置页按钮触发后生成 watched/watchlist 的 `sync_conflicts`，冲突 ID 为 `StableID.make(prefix: "sync-conflict", value: "trakt-\(mediaID)-\(field)")`，重复导入更新同一条冲突而不追加。导入本身不覆盖 `media_items`，不处理保险库和未匹配 TMDB 条目；用户在冲突队列采用远端后会写入本机已看、想看或喜欢状态，采用远端已看会清理本机想看但不额外反推 Trakt watchlist，选择保留本地会调用 Trakt sync API 写回 watched/watchlist。用户手动/批量标记视频已看时，如果条目仍在想看中，会通过 `MediaRepository.markWatched(... clearWatchlistWhenWatched: true)` 清理本机想看，并在可表达为 Trakt watchlist 时同步 remove watchlist；播放进度自动达阈值的 `updatePlayback` 不触发该清理。Trakt syncOnly 账号会写入 `remote_connector_accounts` 并更新 `lastSyncedAt`。后续若做评分同步或多字段合并，必须显式修改对应远端状态或 MediaLIB 内部状态，不能只记录选择。
- 2026-06-08 最新补充：按用户要求，本地多档案功能已移除。`ContentView` 不再显示侧栏档案菜单，设置页不再提供本地档案管理，`AppState.reload()` 不再读取或套用 `profile_media_state`；播放进度、播放次数、已看、喜欢、想看和评分统一使用全局 `media_items` 内部索引。旧 `local_user_profiles` 和 `profile_media_state` 表暂留作历史库兼容，不作为当前功能入口或检查项。
- 2026-06-08 最新补充：Batch B 自动片头/片尾审核流已完成到基础闭环。v17 为 `playback_markers` 增加 `review_status`、`detector_identifier` 和 `confidence`；视频/系列右键“检测片头片尾”通过任务中心 `.markerAnalysis` 分析内嵌章节关键词，生成 `origin == automatic` 且 `reviewStatus == pending` 的片头/片尾候选。播放器章节弹层中待审核标记可确认或忽略，确认后才参与跳过入口与时间轴显示，拒绝后从普通 fetch 隐藏但仍可用于重复候选抑制。检测仅写内部索引，不写回视频文件。
- 2026-06-08 最新补充：Batch B 章节图/keyframes 第一阶段已完成。`VideoFramePreviewGenerator` 已从 `PlayerView.swift` 私有枚举抽到 `MediaLibCore/Services`，播放器 hover 预览、磁盘缓存和后台“预生成章节图”共用同一套有限 bucket 策略；`FileAccessService.AppDirectories` 新增 `previewFrames`，App 启动时配置到 `Caches/MediaLib/PreviewFrames`，本地 AVFoundation 抽帧和远程/挂载 ffmpeg 兜底都会写入该内部缓存。`BackgroundTaskKind.keyframeStoryboard` 接入任务中心，`AppState.generateVideoFrameStoryboard` 可从视频/系列右键启动，按剧集逐个预生成进度条预览帧，支持取消，保险库任务隐藏标题和明细。`VideoCacheMenuItems` 新增“预生成章节图”；`MediaLibChecks` 覆盖 storyboard bucket 数量、排序、去重和邻近时间复用。该功能不修改 `MediaItem.filePath`，不移动、不改名、不写回用户视频文件。
- 2026-06-08 最新补充：Batch B 离线订阅计划第一步已完成，schema 升至 v16。`VideoOfflineSubscription` 新增 `.season`、`seasonNumber`、`pausedUntil`、`expiresAt` 和 `networkPolicy`；`VideoOfflineSubscriptionRepository` 读写 `season_number`、`paused_until`、`expires_at`、`network_policy`，并支持 `fetchExpired` / `deleteExpired`。右键“自动缓存系列”新增“自动缓存整季”、暂停 7 天、继续自动缓存、“到期计划：不自动到期 / 7 天 / 30 天 / 90 天”，以及“网络策略：允许远程网络 / 仅本机局域网 / 仅 Wi-Fi”。`maintainVideoOfflineSubscriptions` 只处理 `isRunnable` 订阅，整季模式只排入目标季，`localNetworkOnly` 只接受 localhost、`.local`、10/8、172.16/12、192.168/16、127/8 和常见本地 IPv6 前缀；`wifiOnly` 只在 `NWPathMonitor` 显示当前使用 Wi-Fi 时排入新任务；`scheduleVideoOfflineSubscriptionExpirationCheck` 会在到期后关闭内部订阅规则，不删除已缓存视频。所有自动缓存仍共用现有 `startVideoCacheJob`、任务中心、字幕同步和容量维护，不修改 `MediaItem.filePath`，不移动或写回用户媒体文件。
- 2026-06-08 最新补充：系列自动缓存订阅已补齐自定义未看集数窗口。`VideoCacheMenuItems` 的“自动缓存系列”和“指定缓存清晰度”子菜单都提供下一集、未看 3/5/10 集、全系列和“自定义未看集数…”入口；自定义弹窗 `VideoOfflineSubscriptionLimitSheet` 通过 `AppState.videoOfflineSubscriptionLimitRequest` 承载，可设置 1 到 99 集。保存仍走 `saveVideoOfflineSubscription(... episodeLimit:)` 和 `VideoOfflineSubscriptionRepository`，维护任务继续按 `episodeLimit` 选择当前未看窗口内缺失缓存，不新增下载器，不修改 `MediaItem.filePath`，不写回或移动用户媒体文件。
- 2026-06-08 最新补充：第六轮低风险缺陷修复已完成。`AppState.addSource` / `addSources` 的重复来源提示统一走 `duplicateMediaSourceAlert`，保险库类型不再在“已存在”弹窗中显示目录名；`addNetworkMountedSource` 也会先按 `mountedDirectory.path` 检查已有来源，避免同一个 SMB/FTP/FTPS 挂载目录重复入库。后续新增来源入口必须复用同一重复检测和保险库安全文案。
- 2026-06-08 最新补充：第五轮低风险清理已完成。添加保险库媒体源后的遗留空弹窗已移除，本地、批量和网络来源添加后只保留正常扫描任务/浮窗反馈；不要恢复“注意身体”这类与媒体库流程无关的提示。代码注释中内部排期编号式 `P0/P1/任务N` 口吻已收敛为稳定工程说明，后续新增性能或虚拟化注释应说明原因和约束，不写临时编号。
- 2026-06-08 最新补充：第四轮低风险隐私收口已完成。媒体源行删除确认弹窗现在复用 `SourceRowView.sourceTitle(isLockedPrivateSource:)` 的安全显示名，保险库锁定时不会因为确认标题露出原始来源名；`LibraryHealthCenterView` 的失效路径详情与疑似重复项详情新增 `AppState.isPrivateItem` 兜底，锁定态显示“路径已隐藏”。后续新增确认弹窗、健康行、重复项行或来源操作时，要复用同一套安全标签，不要直接把 `source.name`、`source.displayPath` 或 `item.filePath` 放进用户可见文本。
- 2026-06-08 最新补充：第三轮低风险清理已完成。`MusicLyricsPresenceCache` 移除了旧的 `includeGenericNames` 参数，歌词存在性只按单曲同名 `.lrc/.txt` 判定，继续避免目录级 `lyrics.lrc/txt` 被误认为共享歌词。设置页性能日志入口已统一显示为“性能记录”，底层 `debugLoggingEnabled` key 保持不变以兼容旧配置；视频缓存和音乐标签写入失败提示也收掉了临时文件、底层写入组件等实现细节，继续面向普通用户表达。
- 2026-06-08 最新补充：第二轮发版前代码体检已清理模型层同步文件访问死代码。`MediaItem.isPlayable` 与 `MediaSource.exists` 已删除，检查程序只验证 `isRemoteResource` 等纯内存语义；后续不要在模型属性、SwiftUI `body`、列表行或卡片筛选里直接做文件存在性判断，本地可达性继续走后台健康缓存、`AppState.sourceIsReachable` 或明确的服务方法。本轮还把保险库锁定态的缓存失败、字幕同步、健康中心离线来源和网络重新挂载提示继续泛化，日志不得带出保险库来源名、路径、服务端地址或底层错误对象；视频播放核心缺失提示已改为正式用户文案。
- 2026-06-08 最新补充：系列自动缓存订阅基础已完成，schema 升至 v15。新增 `VideoOfflineSubscription`、`VideoOfflineSubscriptionRepository` 与 `video_offline_subscriptions`，支持 `.nextEpisode`、`.nextUnwatched`（UI 提供未看 3/5/10 集与自定义未看集数）和 `.fullSeries` 三种模式，可保存指定清晰度。`VideoCacheMenuItems` 在系列可用时显示“自动缓存系列 / 自动缓存：当前规则”，默认清晰度和“指定缓存清晰度”子菜单都覆盖这些模式，并提供“停止自动缓存”。`AppState.cacheVideo` 已抽出 `startVideoCacheJob`，手动缓存和自动缓存共用现有任务中心、`VideoCacheDownloadController`、字幕同步、容量维护、暂停/继续/取消与进度展示；自动维护由 `scheduleVideoOfflineSubscriptionMaintenance` / `maintainVideoOfflineSubscriptions` 低频触发，会排除已缓存和已排队条目，`.nextUnwatched` 只维护当前未看窗口内缺失缓存，不会跳过已缓存后无限向后扩张。`updatePlayback(... reloadLibrary: false)` 会更新内存播放状态并调度维护，播放结束或关闭视频后可以补下一集。
- 2026-06-08 最新补充：集合发布到首页和 Emby 同步库选择已完成。手动集合与智能集合都有 `showOnHome` / `show_on_home`，编辑弹窗、集合页页头和侧栏右键都能切换“发布到首页 / 从首页移除”；首页总览会复用 `HomeOverviewBoard` 展示有内容的已发布集合，保留自动慢滚、鼠标拖动和返回锚点。首页集合只使用本地公开视频与远程服务器顶层视频，默认关闭且空集合不展示。Emby/Jellyfin/Plex 来源复用 `MediaSource.selectedEmbyLibraryIDs` / `media_sources.selected_emby_library_ids`，当前通过媒体源设置弹窗实时读取服务器库；空选择保持全库同步，选择具体库后保存会刷新远程目录并只清理 MediaLIB 内部索引，不改动服务器。主窗口最小内容尺寸已从 1120x720 小幅收回到 1088x720，高度不变；`MainWindowToolbarVisibilityGuard.minimumContentSize`、README、用户说明、开发说明和本交接文档均已同步。竞品差距表 `MARKET_GAP_ANALYSIS.md` 已按 Plex/Emby/Jellyfin/Infuse/Kodi 重新整理：已完成项移出缺口；Batch A 的手动视频集合基础、智能集合复合规则、缓存容量基础策略、集合发布到首页和 Emby 同步库选择均已完成。Batch B 的离线订阅计划第一步、订阅到期计划、首页离线标签、Wi-Fi 实时判断、章节图/keyframes 手动预生成、自动片头/片尾审核、元数据撤销、元数据历史列表和同步冲突队列 UI 均已完成；后续继续补章节图自动计划和更深入的自动检测。Batch C 已有连接器/Trakt 的数据承载基础、Jellyfin 第一阶段登录同步、Plex 服务器 URL + Token 直连第一阶段、Trakt 双向导入生成冲突、采用远端写入本机索引和保留本地写回 Trakt；本地多档案功能已移除；iCloud 的真实协议流程仍待接入；Live TV/DVR、插件和云盘直连继续暂缓。
- 2026-06-07 最新补充：发版前代码体检收紧了来源路径与缓存副文件边界。`AppState.isSourcePath` 和 `MediaRepository.replaceRemoteItems/deleteItems(sourcePathPrefix:)` 现在都按精确来源或 `sourceRoot/` 子路径匹配，并归一化尾部 `/`，避免 `emby://host/source` 误伤 `emby://host/source2`；检查程序已覆盖相邻前缀和尾部斜杠两种情况。`VideoOfflineCacheStore` 删除缓存字幕时只匹配完整视频 base 或 `<video-base>.`，不能恢复裸 `hasPrefix`。本轮还清理了多处元数据/详情/音乐列表展示中的可选字符串强解包，后续新增网络元数据字段优先用安全 fallback。
- 2026-06-07 最新补充：详情返回位置已从海报墙扩展为通用来源锚点。`AppState.selectedItemReturnAnchorID` 现在服务视频/剧集海报墙、首页海报型标签、首页总览横向看板、全局搜索结果和片库健康中心行；进入详情前写入来源条目 ID，返回时由对应 `ScrollViewReader` 或 `PosterGridList` 用禁用动画事务静默定位到原位置并清空。后续新增会替换主 detail 区的入口时，应给来源行 `.id(item.id)` 并复用这条锚点，不要为单页另造状态。
- 2026-06-07 最新补充：首页横向看板已支持鼠标按住拖动滚动。`HomeOverviewBoard` 使用 `horizontalMouseDragScroll` 直接驱动底层 `NSScrollView` 的横向 bounds，真正拖动时暂停自动滚动并吞掉松手点击；后续首页横向内容不要退回只能依赖触控板双指滑动的方案。“最近添加”入口只作为浏览列表，不显示清除记录按钮。
- 2026-06-07 最新补充：Emby 分类推断顺序已改为服务端 View/上级目录名称关键词优先，再看 `Genres`，最后才用 `CollectionType` 兜底；例如 “动漫-华语” 这类 Emby 上级目录会先映射到动漫。Emby 同步新增 `RemoteTraceSyncMode` 三档：`.bidirectional` 写回本机播放痕迹到服务端，`.importOnly` 只从 Emby 拉取，`.disabled` 尽量保留本机播放进度、收藏、已观看、想看、最近播放和用户评级，避免多人共用 Emby 时互相干扰。
- 2026-06-07 最新补充：评分与评级已拆分。`MediaItem.rating` 是资料源评分，详情页评分数字始终读它；`MediaItem.userRating` 是用户五角星评级，海报、右键菜单和详情页星星只写它。`MediaRepository.upsert` / `updateMetadata` 只在 `user_rating` 为空时由资料评分折算初始星级，`updateRating` 只更新 `user_rating`；后续不要把 TMDB/Emby 评分再次写成用户评级。
- 2026-06-07 最新补充，2026-06-08 已扩展：设置页“数据与诊断”一键清理由 `AppState.runOneClickCleanup()` 创建 `.cleanup` 任务，清理范围只限 MediaLIB 内部缓存：失效 manifest、已不存在条目的视频缓存、未被 manifest 引用的孤儿缓存/字幕文件、超出 `AppSettings.videoCacheSizeLimitGB` 的离线视频、空 artwork 目录和过长任务历史。不要遍历、删除或移动用户媒体源。容量超限回收必须通过 `VideoOfflineCacheStore.runMaintenance(validItemIDs:byteLimit:cleanupHint:)`，只能删除 manifest 登记的视频及同名字幕旁路文件。
- 2026-06-07 最新补充：任务中心已持久化到 Application Support 的 `MediaLib/BackgroundTasks.json`。`BackgroundTaskSnapshot` / `BackgroundTaskKind` 均为 `Codable`，启动时 active 任务会标记 failed；封面预热和一键清理也进入任务中心。后续新增后台任务应考虑重启后的可解释状态，不要恢复“本次启动内临时列表”口径。
- 2026-06-07 最新补充：视频缓存续传进度改为累计口径。`VideoCacheDownloadController` 会保留 resume data 字节数、`lastProgress` 和预期总大小，继续时先发布旧进度，再兼容 URLSession 回调本轮字节或累计字节两种行为，暂停后续传不能再从 0% 显示。取消、完成、失败和数据库恢复仍必须 invalidate 下载 controller。
- 2026-06-07 最新补充：设置页滑动性能路径已改为原生 `List` 分组虚拟化，保留 860pt 居中宽度、设置分组静态玻璃、`.glassPerformanceMode(.balanced)` 与 `.preferStaticGlassSurfaces(true)`；不要退回 `ScrollView + LazyVStack` 或给设置分组恢复连续 pointer 光。页头搜索框、设置菜单、智能集合和智能歌单规则控件继续按当前文字自适应宽度，避免标题挤压或右侧大留白。
- 2026-06-07 最新补充：视频播放器控制层用 `VideoControlBrightnessSampler` 在打开时对海报做一次小尺寸亮度取样，`VideoControlPalette` 统一驱动控制条、时间、图标、锁定按钮、进度和玻璃底的黑/白高对比内容色；不要在播放中逐帧采样，也不要固定成某一种颜色。视频窗口宽度 100% 时 `VideoWindowSizing.usesFullScreenWidth` 允许使用当前屏幕 `visibleFrame.width`，不再乘额外缩放系数。视频/音乐音量滑条和快捷键统一走 `PerceptualVolumeScale` 感知曲线。
- 2026-06-07 最新补充：音乐展开/收起转场增加中断兜底。`ContentView.finishInterruptedMusicTransition(expanded:)` 会在展开或收起任务被取消、曲目状态变化或 guard 提前返回时清理 `musicTransitionShieldActive`、`musicTransitionSuppressesBackground` 和沉浸状态，降低收起卡住概率；展开稳定后更早卸载背后导航树，收起前先挂回下层界面预热。
- 2026-06-07 最新补充：设置页新增“关于软件”分组，入口打开标准 `AboutMediaLIBSheet`，展示 GitHub `https://github.com/Again0521/MediaLib`、作者 `ZonnL`、QQ群 `977808370` 和邮箱 `zonn.l@foxmail.com`。该弹窗左侧使用真实 App Logo，信息行固定为图标列、标题列和值列，保证图标重心和标题首字对齐；后续关于/帮助类设置入口应继续走这套普通 sheet，不要弹独立窗口或改系统面板样式。
- 2026-06-07 最新补充，2026-06-08 已扩展：首页、远程媒体服务器、本地视频和保险库的条目口径已重新隔离。`AppState.homeVideoItems` 是首页专用缓存，允许汇总本地公开视频与远程服务器顶层视频；左侧本地“视频 > 想看/喜欢”只看 `cachedTopLevelItems` 本地公开内容；EMBY / Jellyfin 的本机想看显示在对应远程来源下；保险库喜欢/想看只在解锁后的保险库页面出现。`rebuildDerivedItemCaches()` 现在从所有 `.privateCollection` 根节点沿 `childrenByParentID` 向下传播 `cachedPrivateItemIDs`，覆盖“保险库 > 剧集 > 单集”等多层后代；后续不要退回只判断直接 parent，也不要把远程服务器或保险库条目混进本地视频侧栏。
- 2026-06-09 最新补充：音乐展开页封面光效新增并二次收紧 `AlbumProjectedCoverGlowLayer`。它位于 `MusicPlayerView.expandedPlayer` 的 Metal 背景之上、内容层之下，复用 `AlbumBlurredCoverGlowLayer` / `AlbumCoverGlowBakeCache` 的预烘焙封面复制图，profile 为 `.projected`；`MusicExpandedLayout.projectedGlowFrame` 现在是更宽的横向矩形并向封面下沿右侧偏移，`ProjectedCoverGlowFeatherMask` 用横向、纵向和径向叠加羽化，让封面底部光铺到控制栏和歌词卡左边缘；不要把它改成运行时 SwiftUI 大 blur 或第二套独立图片缓存。`AlbumGlowBakeKey.bakeVersion` 当前为 13，key 内包含 `profile`。控制栏高度由 `MusicPlayerVisualTokens.Controls.expandedHeight` 的外层固定 frame 约束，内部 `MusicControlGaussianColorWash` 只做局部裁剪高斯取色玻璃底，状态行也不能参与高度计算。`MusicPlayerMetalBackdropView.paintPalette` 当前为约 34 网格和 7px softening，保持整窗不透明 Metal 底板。
- 2026-06-07 最新补充：剧集 TMDB 宽松匹配已改为“清洗剧名优先”的多查询链路。`MetadataMatchScorer.videoSearchQueries` 会从标题、原名、目录名生成去季集号、发布组、分辨率和平台噪声后的剧名候选；`AppState.bestTMDBVideoMatch` 聚合多次 TMDB 搜索结果并记录候选由哪些查询词召回，评分时同时比较本地标题、TMDB 标题/原名和命中查询。宽松模式会增加查询数量并认可“清洗剧名命中”的证据，但年份明显冲突仍降分；`episode` 类型必须走 TMDB TV 搜索端点，不得落到 movie 搜索。
- 2026-06-07 最新补充：健康中心“一键补充”会把视频和音乐缺口加入任务中心，仅补充缺失字段、不覆盖已有数据；设置页已拆分“影视匹配宽容度”和“音乐匹配宽容度”。媒体源新增“元数据优先写入源目录”偏好，仅非 Emby 来源提供；开启后视频补充会保守尝试 `movie.nfo/tvshow.nfo`，音乐补充会保守尝试本地音频标签写回，失败时必须回落到 MediaLIB 索引。
- 2026-06-07 最新补充：普通页面配色继续收敛。清蓝、珊瑚、青柠、暖杏、夜幕的 `AppThemePreset.seedHex` 与 `AppThemeTokens` 已同步到更低霓虹、更干净的色值；`AppColors.pointerLightTint` / `solarLightTint` / `solarEdgeTint` 由当前主题左上光线与高亮色共同派生，hover 不再固定偏系统蓝。`PlayfulSymbolIcon`、默认音乐封面和视频播放器黑场氛围也应走主题派生色；无专辑色的音乐底栏进度、队列 now playing、模式按钮 fallback 已改用 `AppColors.selectedGlassTint` / `pointerLightTint`；AirPlay 深蓝仍是播放器约束中的明确例外，不跟随专辑或主题。
- 2026-06-07 最新补充：设置页“音乐播放”新增“封面发光”开关。开启时 `MusicExpandedArtwork` 继续使用 `AlbumBlurredCoverGlowLayer` 的 near/mid/far 三层 image-based glow；关闭时必须停用该三层 artwork glow，只保留 `AlbumPrimarySoftCoverShadow` 的浅单色主色柔影，并让播放/暂停状态下的阴影连续衰减，不要硬切残留光圈。
- 2026-06-08 最新补充：音乐展开页封面光效保留 `AlbumBlurredCoverGlowLayer` -> `AlbumCoverGlowBakeCache` 后台烘焙路径，near/mid/far 仍按 `bakeVersion` 11 的大范围 image-based glow 工作。底板取色已从上一轮“强推封面纹理和彩度”的方向回收：`MusicPlayerMetalBackdropView` 中 `paintPalette` 回到 40 格、轻量饱和回补和 8pt softening，`artworkOpacity`、`cleanMetalBaseColor`、`cleanMetalRoleColor`、`cleanMetalGlowColor`、`kGlowStrength`、`kWhiteVeilStrength`、`kChromaBoost` 与 `glassifyAlbumColor` 均恢复为克制基线；底板只负责不透明专辑色底和整窗玻璃厚度感，绚丽感交给受控 mesh blobs 与封面 glow。后续调“发灰”只能小幅改这些集中参数，不要提高整窗 artworkOpacity、不要强加 `paintPalette` saturation/contrast、不要新增全屏 SwiftUI 渐变/material。
- 2026-06-07 最新补充：右键菜单已统一用 `Label` 补齐左侧图标。侧栏智能集合/EMBY/智能歌单、视频海报、详情页剧集与封面、音乐歌曲/专辑/艺术家/歌单、播放队列和视频缓存清晰度菜单都应保持图标覆盖；后续新增右键项时，若同一菜单内已有图标，新增项也必须带图标，重分类图标统一走 `MediaType.systemImage`。
- 2026-06-07 最新补充：应用内浮窗通知已接入。`AppState.showFloatingNotice` / `showInterfaceTipOnce` 负责轻量通知和页面提示，`ContentView` 顶部中央 `FloatingNoticeStack` 以胶囊玻璃样式展示，最多三条、自动消失且可手动关闭；任务加入、任务完成/失败/取消和页面提示都应走这条路径。浮窗宽度按标题和说明文字真实测量，短提示必须收窄，长片名/路径/任务详情只在最大宽度内居中换行；任务通知保持短标题，具体对象放进说明行，不要再把完整任务名塞进标题导致胶囊固定撑宽。页面提示必须是用户能直接理解的使用建议，并通过 `UserDefaults` 保证同一提示首次进入后不再展示。危险操作、删除确认和需要用户选择的流程仍使用标准确认弹窗，不要用浮窗替代确认。
- 2026-06-07 最新补充：首页总览新增“继续观看 / 下一集 / 今日推荐”看板。继续观看与下一集复用 `AppState` 派生缓存；今日推荐优先从库内高评分剧集/动漫/纪录片/综艺中按当天稳定随机挑选，条目不足时回落到其它高分视频。后续不要在 `HomeView.body` 里做全库昂贵随机/排序，应继续使用派生缓存或后台快照。
- 2026-06-07 最新补充：`AppLoadingView` 已遵守 Reduce Motion，系统开启减少动态效果时不再启动无限 shimmer，只保留静态高光。后续加载骨架、占位或列表占位动画都应沿用这条降级规则。
- 2026-06-07 最新补充：音乐展开页继续只在现有集中路径里调色，不新增渲染层。`MusicPlayerMetalBackdropView.cleanMetalBaseColor` 提高主/辅/强调色参与并降低珍珠中和，shader 常量降 `kWhiteVeilStrength`、提 `kChromaBoost` / `kGlowStrength`，让底板更有被玻璃盖住的专辑高斯色深，同时继续 clamp 纯白；`FloatingLyricsGlass` 略降 material opacity 与灰膜，保留更清晰的上沿高光、专辑色描边和中心通透感。后续继续调底色优先改这些集中参数，不要恢复全屏 SwiftUI 渐变、material 或连续鼠标采样。
- 2026-06-07 最新补充，2026-06-08 已扩展：Emby/远程视频缓存基础闭环已落地。`VideoOfflineCacheStore` 管理 `Caches/MediaLib/VideoCache` 与 Application Support 下的 `VideoCacheManifest.json`；`AppState.cacheVideo` 使用任务中心执行下载，播放和外部打开优先走有效缓存副本，失效则回落远程路径。剧集/系列海报和剧集列表右键提供“缓存到本地”，有 Emby 清晰度规划时提供可选档位；单集/系列海报显示“已缓存 / 部分已缓存 / 已全部缓存”，二级目录仅在当前范围存在缓存时显示“已缓存”筛选按钮。缓存只写 MediaLIB 内部缓存，不修改 `MediaItem.filePath`，不移动、不改名、不写回服务端或用户媒体。缓存任务现在由 `VideoCacheDownloadController` 承载 `URLSessionDownloadTask`，任务中心可暂停、继续和取消并展示百分比/字节进度；暂停必须等待 resume data 进入 `.paused`，`.pausing` 时不能继续抢跑；完成、失败、取消或数据库恢复必须 invalidate session 并取消 worker，避免隐藏下载残留。`VideoCacheEntry.lastAccessedAt` 为兼容新增字段，旧 manifest 缺失时按 `createdAt` 兜底；播放缓存副本时通过 `markAccessed` 刷新。
- 2026-06-07 最新补充：视频缓存删除、路径设置和字幕同步已补齐。`AppSettings.videoCacheDirectoryPath` 记录用户选择的缓存根目录，实际文件仍写入其下的 `VideoCache` 子目录，manifest 保持在 Application Support，避免路径切换时丢失清单。系列/海报右键删除会收集该系列已缓存子集，单集右键只删除自身；删除只移除 manifest 登记的视频缓存文件和同名 `srt/ass/ssa/vtt` 旁路字幕，不触碰媒体源。重新缓存同一条目前会先清理旧副本，`VideoCacheJob.cleanedItemIDs` 防止暂停/继续后重复清理。Emby 原画直连缓存保留原容器音轨，文本字幕通过 `EmbyService.subtitleStreams` 与 `downloadSubtitle` 尽量同步为同名旁路字幕；非原画转码档位的音轨/字幕以服务端转码结果为准，字幕同步失败只写 warning。
- 2026-06-06 最新补充：音乐展开页四层视觉按用户新反馈重新接线。`MusicPlayerMetalBackdropView` 保持单 `MTKView`，shader 新增 `vibrancy` uniform、三色 album-color backdrop、整屏 Liquid Glass 折射/高光和轻 grain；`Coordinator` 切歌时始终预热下一张封面纹理，但由 `artworkOpacity` 控制使用，避免 `artworkReady` 阶段灰闪。`LyricsCardEffectLayerView` 现在常态也绘制玻璃底、上下雾区、内阴影和专辑染边，pointer 只叠加局部扫光；`FloatingLyricsGlass`、歌词卡、控制栏、收起按钮共用该材质，底栏调用保持低强度。2026-06-06 本轮已略微提高歌词卡、控制栏和收起按钮透明度，并继续为性能收口：降低 `Glass.frostWhite` / `frostTexture` / `topHighlight`、专辑 tint 和 material opacity；只有真正的歌词卡片传入 `centerClarity: true`，中心通透感由静态 fill 渐变与 `LyricsCardEffectLayerView` 承载，不再给 `.hudWindow` material 或磨砂纹理挂 SwiftUI 渐变 mask，控制栏与收起按钮不启用中心透明通道。`AlbumBlurredCoverGlowLayer` 明确为使用 `AlbumCoverGlowBakeCache` 后台烘焙 artwork 原图得到的 far ambient / mid spill / near bloom 三层 image-based glow，烘焙时必须校正 Core Image Y 轴并用邻近边缘像素外扩，运行时只贴透明图并调 opacity / blend / scale；`AlbumLightSpillOverlay` 只照亮歌词卡/控制栏/收起按钮朝向封面的左缘和少量内部。定时歌词浏览态 blur 必须为 0，停止浏览后再渐进恢复。
- 2026-06-06 最新补充，2026-06-08 已修正：音乐展开页封面 glow 主路径是 `MusicExpandedArtwork` -> `AlbumBlurredCoverGlowLayer` -> `AlbumCoverGlowBakeCache`。后台先按真实可见封面裁切、校正 Y 轴、用邻近边缘像素向外延展，再叠加柔化圆角封面 alpha mask 与径向尾部衰减；当前配方与 `bakeVersion` 以 2026-06-08 最新补充为准。运行时不再做三层 SwiftUI 大半径 blur/mask，也不要恢复整图全局 blur 后外扩的 glow。底板取色仍为“封面低频颜料色场 + tonal 语义 palette 调色”：`MusicPlayerMetalBackdropView` 预加载封面并生成颜料色场，shader 采样合成被玻璃遮住的封面高斯，再把 `primary/secondary/accent` 清洁化为受控明度/饱和度的角色色参与语义调色；低彩/白灰封面仍用真实中性平均保留白/灰/黑主调，只有彩色面积占比足够明确时才允许极弱色相提示。旧 `AlbumSoftBloomGlow`、`AlbumPhysicalEdgeGlow`、`AlbumDirectionalGlowBake`、`AlbumArtworkGlowLayer` / `LowResolutionArtworkGlowLayer`、`AlbumBloomImageBake` / `MusicBackdropBlur` 已删除，后续不要恢复这些历史路径，也不要恢复运行时三层 SwiftUI blur。
- 2026-06-06 最新补充：音乐展开页 L0 Metal 背景继续按单个 `MTKView` 绘制，但 shader 的白色 veil/玻璃白雾已进一步压低，专辑主/辅/强调三色 mesh、ambient 和 near-field 光增强，并保留高光压缩与防纯白 clamp。`AlbumColorPalette` 现在更积极保留多色封面的三色比例；低彩/白灰封面改用不降中性色权重的 `neutralAverage`，不再强制饱和度下限。后续调底板应优先改 `AlbumColorPalette` 与 `MusicPlayerMetalBackdropView.cleanMetalBaseColor` 的集中参数，不要在 SwiftUI 顶层叠全屏渐变或 material。
- 2026-06-06 最新补充：音乐展开页布局和玻璃层已按视觉重心微调。封面尺寸略缩小，播放态光程按彩色度能照到歌词卡左缘，暂停态仍保持封面后退缩小和近到远熄灭。歌词卡、控制栏、收起按钮继续共用 `FloatingLyricsGlass` / `.withinWindow` 局部玻璃，降低灰膜和白雾并增加专辑色边缘浸染；歌词卡上下边缘更厚、更雾，中间清晰，用户浏览歌词时仍临时解除远离行模糊。
- 2026-06-05 最新补充：配色二次收敛后，设置页只展示清蓝、珊瑚、青柠、暖杏、夜幕和自定义。冰璃与石墨已按反馈移除展示；旧 raw value 只为历史设置解码保留，不要再作为菜单入口恢复。侧栏 `List.tint` 已改回 `AppColors.selectedGlassTint` 跟随应用取色，`PlayfulSymbolIcon` 的视频水波也跟随主题色；不要改回固定 `NSColor.controlAccentColor` 或固定 cyan/blue。`LiquidGlassButtonStyle(prominent:)` 已收掉多层描边以修正暖色按钮边缘毛刺，后续不要再叠回顶部白描边 + 底部暗描边 + 外圈白描边的三层结构。
- 2026-06-05 最新补充：普通页面配色体系当前为清蓝、珊瑚、青柠、暖杏、夜幕 5 套主题 + 自定义。`AppThemePreset.allCases` 只展示这些入口，旧 `ocean/indigo/purple/rose/orange/mint/green/graphite/frosted/warm` raw value 保留兼容但会解析到新色板，不要再把紫色、粉色、高饱和绿、冰璃、石墨或霓虹方案放回设置菜单。`ResolvedAppTheme` 现在带完整 `AppThemeTokens`，`AppColors` 已缓存暴露 primary/secondary/accent/background/elevatedSurface/border/textPrimary/textSecondary/success/warning/error；后续替换硬编码色优先走这些 token 或现有语义表面。
- 2026-06-05 历史补充：音乐展开页曾试验物理边缘发光（`AlbumPhysicalEdgeGlow` / `AlbumDirectionalGlowBake` / `AlbumEdgeGlowSampler`）。该路径已在 2026-06-06 删除并替换为 `AlbumBlurredCoverGlowLayer` 的三层 image-based glow；后续不要恢复这些旧类型。
- 2026-06-05 最新补充：侧栏图标选中/还原已改为瞬时。`PlayfulSymbolIcon(selected:)` 禁用隐式动画，`ContentView.sidebarRow` 禁用选中事务动画；侧栏 `List` 使用 `AppColors.selectedGlassTint` tint，选中高亮跟随应用主题。后续不要再给侧栏图标 selected 状态加慢动画，也不要改回固定 `NSColor.controlAccentColor` 或系统蓝。
- 2026-06-05 最新补充：音乐展开页封面 glow 可见性继续修正。上一轮预烤 bloom 已解决白化和方向色根因，但在浅/蓝封面下会被背景吞掉；当前 `MusicExpandedArtwork` 使用“预烤方向色 + 贴边 plusLighter halo + 外扩 screen halo”三段结构，封面 `PosterImage` 也接入 `pointerLiquidEdge`，让专辑边缘响应鼠标局部光效。后续调 glow 时优先调贴边/外扩 halo 的半径和 opacity，不要回到全屏白光或简单提高预烤图 opacity。
- 2026-06-05 最新补充：左侧栏配色和图标反馈已加速。`ContentView` 侧栏 `List` 与侧栏图标跟随 `AppState.themeRevision` 刷新，`AppMotion.sidebarSelection` 当前为 0.055s，`PlayfulSymbolIcon` 显式绑定该动画；后续不要把侧栏选中/还原改回 0.1s 以上的慢反馈，也不要让换色依赖重启或其它页面状态刷新。
- 2026-06-05 最新补充：音乐展开页 L0 回归排查第三轮新增 `scripts/probe_music_player_rss.sh`。播放器已展开并播放同曲后，可运行 `scripts/probe_music_player_rss.sh 300 30` 采样 WindowServer / MediaLib RSS；脚本在 Codex 沙盒内会因子进程 `ps` 受限，需要沙盒外运行或在普通终端运行。本轮仅完成 debug app 空载 60 秒观察，WindowServer 约 78.6MB -> 78.7MB、MediaLib 约 350.6MB 持平；这不是同曲播放 A-7 验收。System Events 当前无法自动定位 debug 窗口，A-5 pointer wash y 镜像、A-6 封面阴影同步和截图 diff 仍需可交互环境。
- 2026-06-05 最新补充：音乐展开页 L0 Metal 背景第二轮收口已完成。`CAMetalLayer.maximumDrawableCount = 2`，`draw(in:)` 非主线程路径不再同步阻塞主线程，shader 已补回 1px white screen 边线；旧 L0 SwiftUI/CA 背景结构已删除，后续不要恢复 `AlbumGlassBackdrop`、`MusicFullScreenGlassLayer`、`AlbumBackdropStaticLayer`、`AlbumBackdropLightLayer`、`AlbumNearFieldIlluminationLayer`、`AlbumBlurredArtworkBackdrop` 或 `LowResolutionArtworkBackdropLayer`。旧 `MusicBackdropBlur` 已随封面 glow 主路径切换删除，不要恢复。
- 2026-06-05 最新补充：音乐展开页 L0 Metal 背景第一轮回归修复已完成。`MusicAlbumBackdropRenderer` shader 中整窗 glass 合成块已移到 near-field 光组之前，保持旧结构 `MusicFullScreenGlassLayer` 在 `AlbumNearFieldIlluminationLayer` 下方的 z 序；uniform 的玻璃底色改为直接使用 `AlbumColorPalette.albumGlassBaseColor(for:)` 再转 deviceRGB，不要恢复 `metalAlbumGlassBaseNSColor` 这种并行重算；renderer/pipeline 不可用时用 `backdropBaseColor` 清屏/铺底，避免 Metal 初始化失败黑屏。色彩空间 `_srgb` 与否、渐变 stop、模糊半径/尺寸、歌词卡 y 镜像、封面阴影是否滞后，以及 5 分钟 WindowServer/GPU 空闲采样仍未完成实测，后续不要把 build 通过当作视觉一致性结论。
- 2026-06-05 最新补充：L3 首拆后，歌词滚动追赶改成事件后有限稳定校准。`lyricViewportStabilityTask` 只在 active 行变化、seek 对齐、歌词内容变化或用户结束浏览后延迟复核居中；不要把旧 `synchronizeAutoScrollIfNeeded` / pending resync / 每 tick catch-up 链路恢复回来。
- 2026-06-05 最新补充：音乐展开页 L3 歌词状态已首轮拆分。`MusicTimedLyricsScrollView` 父层通过 `MusicLyricRenderObserver` 只订阅 active 行和 seek phase/revision/目标行变化；逐字进度由 active 行里的 `MusicLyricActiveLineProgressObserver` 按 `wordProgressBucket` 发布。后续不要恢复 `MusicLyricClockObserver` / `clockState.lyricTime` 每 tick 直接驱动整个歌词 `ScrollView` / `ForEach`。
- 2026-06-05 最新补充：`MusicExpandedArtwork` 的三层封面阴影已迁移到 `MusicExpandedArtworkShadowLayer` 的 3 个 `CALayer`。后续不要把彩色主阴影、彩色强调阴影和黑色深度阴影退回 SwiftUI `.shadow`；阴影参数仍按 `glowStrength` / `coverProgress` 插值，但必须保留 `shadowPath`、`shouldRasterize`、`rasterizationScale`。
- 2026-06-05 历史补充：`AlbumSoftBloomGlow` 预烤方案已在 2026-06-06 删除并替换；`MusicMiniSpectrumLayerView` 的频谱条固定最大高度并用底部锚点 `transform.scaleY` 更新仍是当前实现，高频 bands 做 bucket 去重，颜色只在 accent/isPlaying 改变时刷新。
- 2026-06-05 最新补充：音乐展开页 L1/L2 已开始落地。`AppKitVisualEffectBackground` 默认是 `.withinWindow`，播放器页面不要新增 `.behindWindow`；`FloatingLyricsGlass` 里的 SwiftUI `MusicInheritedGlassPointerWash` 已删除，pointer wash 与边缘提亮改由局部 `LyricsCardEffectLayerView` 的 AppKit tracking area + `CALayer` 绘制。展开页前景整窗 `MusicPlayerPointerLightScope` 已移除，鼠标移动不能再通过环境值刷新整棵播放器前景树。后续扫光、节奏辉光、边缘流光继续进入 L2 局部 rounded rect，不要回到 SwiftUI 全卡/全屏 overlay。
- 2026-06-05 最新补充：音乐展开页背景重构专项已完成 L0 第一阶段接入。`MusicPlayerView` 顶层不再挂 `AlbumGlassBackdrop`、`MusicFullScreenGlassLayer`、`AlbumNearFieldIlluminationLayer` 三组全屏 SwiftUI/CA 背景层，改由 `MetalAlbumBackdropView` 的单个 `MTKView` 绘制专辑底色、模糊封面、mesh 多色光斑、plusLighter/screen、ambient/static/nearField 光效。静态模式保持 `isPaused = true`、`enableSetNeedsDisplay = true`，参数变化请求单帧绘制；后续背景动态只能继续通过 L0 shader uniform/function 扩展，不要把全屏 RadialGradient/LinearGradient/blendMode 动画堆回 SwiftUI。
- 2026-06-05 最新补充：按钮反馈按 Apple HIG 方向统一收口。`LiquidGlassButtonStyle`、`RepeatedGlassButtonStyle`、`HeaderActionGlassButtonStyle` 和 `GlassMenuButton` 都在 hover/pressed 时提供更明显的静态边缘光、描边、亮度和透明度反馈；`GlassCapsuleControl` 即使关闭连续 pointer edge 也保留轻量 hover 高光。视频批量操作栏不能回到 `.plain` 文字按钮，音乐返回顶部按钮使用 `RepeatedGlassButtonStyle`，保持可点击性明确且不引发布局位移。
- 2026-06-04 最新补充：Emby 登录弹窗提交后立即关闭，`AppState.connectEmbyServer` 负责后台认证、任务中心状态、全局结果对话框和首次失败回滚。详情页所有主播放入口使用 `preserveSelection: true` 保留当前页面；视频海报墙只缩放封面绘制层，不缩放外层卡片或命中区域。用户可见说明文案统一为简洁、平静、直接的产品语气。
- 2026-06-04 最新补充：路线图技术债 Phase 2 已收口。`rebuildDerivedItemCaches` 保持单次全库分桶；“正在观看”使用公共/保险库派生缓存，不能退回页面打开时全库 filter/sort；喜欢/想看只更新目标所属父级的 children 缓存。`MusicPlaylistRepository.fetch(id:)` 必须保持目标歌单直查，`ExternalPlayerService` 普通读取使用缓存并在应用激活、播放器启动/退出或自定义路径变化时刷新。
- 2026-06-04 最新补充：`MediaLibAppDelegate.makeTitlebarSeamless` 必须排除所有 `NSPanel`，否则 `NSOpenPanel` / `NSSavePanel` 会被误改为透明并透出主页面。侧栏“新建智能集合”使用与普通行相同的 22pt 图标盒和 10pt 间距。菜单宽度测量已增加原生箭头/中文余量，设置与规则弹页放宽安全上限；`LiquidGlassButtonStyle(prominent: true)` 改为克制深蓝薄玻璃，不要恢复高饱和实心蓝。
- 2026-06-04 最新补充：健康中心只展示仍存在且开启 `includeInHealthCheck` 的来源；删除来源或关闭检查会取消旧文件健康任务并使来源缓存立即失效。保险库条目仅在解锁后进入“正在观看/已观看”，页面和保险库右键均可清除播放记录，锁定时继续隐藏。选择菜单按当前文字自适应，页头与重复按钮补齐边缘光/按压反馈；“新建智能歌单”已移动到歌单页面，设置页按视频、音乐、通用控制和元数据子类重新分组。
- 2026-06-04 最新补充：市场路线第八项基础闭环已落地。`AudioMetadataReader` 扫描 ReplayGain/R128 曲目/专辑增益与峰值，schema v4 持久化，`MusicLoudnessGain` 只计算受峰值约束且不超过原始满幅的播放增益。设置页可选择关闭/按歌曲/按专辑均衡，以及即时衔接/柔和淡入；即时衔接对本地顺序播放和队列循环仅预加载一个确定的下一首，并由同一个 `AVQueuePlayer` 自动前进，随机、远程和柔和淡入不预加载。队尾重启已覆盖单曲循环、单项队列循环和播放结束后再次播放；重叠交叉淡化留待覆盖 AirPlay、歌词时钟、队列和内存的专项验证。
- 2026-06-04 最新补充，2026-06-08 已更新：市场路线第七项基础闭环已落地。`PlaybackMarkerRepository` 使用 schema v17 `playback_markers` 持久化内嵌章节、手动片头/片尾范围和待审核自动标记；播放器章节读取复用现有轨道刷新节奏，控制条只绘制少量静态刻度与范围，完整且已确认的范围内提供跳过按钮。章节图/keyframes 已有右键手动后台预生成；自动片头片尾检测基础版已进入任务中心和审核流，章节图自动计划仍留待后续。
- 2026-06-04 最新补充，2026-06-07 已更新：市场路线第六项基础闭环已落地。`LocalFileEventMonitor` 仅监听可访问本机来源，`AppState` 防抖并按来源合并事件，`MediaScanner.scanChanges` 负责指定路径导入、删除和空系列清理；任何不可靠的目录结构事件都退回完整扫描。`BackgroundTaskSnapshot` / `BackgroundTaskCenterView` 统一展示完整扫描、增量扫描、Emby 同步、封面预热、视频缓存、元数据补充与一键清理状态，任务快照已持久化到 `BackgroundTasks.json`，进度按受控阈值更新，避免新增高频发布。
- 2026-06-04 最新补充：市场路线第五项已落地。`LibraryHealthCenterView` 从首页健康提示和管理侧栏进入，使用 `AppState` 的离线源、失效路径、重复标题与缺失元数据缓存；安全可清理条目在后台健康检查时预计算为 ID 集合，避免页面逐行 O(n²) 搜索。失效清理必须确认，只删内部索引，不得删除媒体文件、清理离线来源、泄露锁定保险库路径或自动合并重复项。
- 2026-06-04 / 2026-06-08 最新补充：市场路线第四项已落地并扩展。`media_items.watchlist` 是独立于 `favorite` 的本机视频计划，扫描/upsert 和 Emby/Jellyfin/Plex `replaceRemoteItems` 都必须保留；手动/批量标记已看和同步冲突采用远端已看会清理本机想看，播放进度自动达阈值不会隐式清理用户计划；`video_smart_collections` 持久化类型、状态、最近加入时间和 `rules_json` 复合规则，由 `VideoSmartCollection.matches` 对本地与远程服务器顶层视频动态求值。侧栏支持新建/编辑/删除，集合页面页头支持直接编辑规则。
- 2026-06-08 最新补充：`DatabaseManager` 当前 schema 为 v18，迁移、手动备份和恢复都使用 SQLite backup API，不能改回直接复制 WAL 文件。恢复前先验证 `user_version` 与 `integrity_check`，拒绝高于当前软件版本的备份，再创建 `auto-pre-restore` 安全快照；`AppState.restoreDatabase` 会取消扫描、待写队列、Emby 播放同步任务和视频缓存下载 controller，并在 reload 前关闭队列对账，避免旧运行态覆盖备份状态。自动检查覆盖备份恢复往返、高版本拒绝、迁移前快照、想看状态、智能集合复合规则、手动视频集合、播放标记、响度字段、媒体源元数据写回偏好、痕迹同步策略、Emby 库选择、用户评级、视频自动缓存订阅表、订阅 `season_number`、暂停/到期、网络策略和过期清理。
- 2026-06-04 最新补充：Emby 状态同步已从单向拉取升级为双向。`MpvPlayerController` 通过 `PlayerPlaybackReport` 在开始、暂停/恢复、每 15 秒节流进度和停止时写回，收藏/已观看/清除记录也写回服务端；`AppState.withValidEmbySession` 统一处理 401/403 自动重新认证。播放前会校验会话并刷新流 URL token。`MediaRepository.replaceRemoteItems` 在单事务中采用服务端播放位置、已观看和收藏状态并清理旧条目，不能退回先删后插。
- 2026-06-08 最新补充：Plex 连接器第一阶段已接入。`PlexService` 使用服务器地址 + Plex Token 直连 XML API，`AppState.connectPlexServer` 创建 `plex://` 来源、保存受限凭据和 `remote_connector_accounts`，并通过库选择同步 Movie/Show/Episode/Music 到独立 Plex 目录。播放前刷新 `X-Plex-Token`，播放进度写 `/:/progress`，已观看写 `/:/scrobble` / `/:/unscrobble`；Plex 喜欢状态只保存在 MediaLIB 本机，暂不做 plex.tv OAuth/Discover、Plex 转码质量、字幕 sidecar 或服务端收藏语义。
- 2026-06-04 最新补充：完成竞品与业务差距审计，路线见 `MARKET_GAP_ANALYSIS.md`。第一项已落地音乐队列持久化：`MusicQueueRepository` 通过 `music_queue_state` / `music_queue_items` 保存队列 ID 顺序、随机和循环状态；`AppState` 在启动加载曲库后恢复队列，但不设置 `activePlayerItem`，因此不会自动播放或主动出现底栏。队列变更使用 220ms 防抖并在后台写库，拖动排序时不要改回逐事件同步写库。
- 2026-06-04 历史补充：当时的 `AlbumSoftBloomGlow` 异步纹理方案已在 2026-06-06 删除。歌曲列表回顶锚点仍必须位于吸顶 `Section` 之前，确保返回真正第一行。剧集选中态通过不消费事件的 AppKit 左键按下监听即时更新，不能改回会等待双击判定的纯单击选中，也不能用会吞掉双击的零距离拖拽手势。
- 2026-06-02 最新补充：音乐展开页闪退已定位到展开时切换 `NSToolbar.isVisible` / `toolbarStyle` 触发 SwiftUI `NavigationSplitView` safe area 约束断言。`MainWindowToolbarVisibilityGuard` 现在保持主窗口 toolbar 结构稳定，只隐藏标题和侧栏切换按钮，切换前后仍快照并还原非全屏窗口 frame，红黄绿按钮必须继续保持可见；不要用 SwiftUI `.toolbar(.hidden, for: .windowToolbar)` 或直接隐藏整条 `NSToolbar` 回退。
- 2026-06-02 最新补充：顶部未沉浸白条不能用单独顶栏色块/材质层遮盖，否则展开动画会被分成两段。当前做法是在 `MainWindowToolbarVisibilityGuard` 中保持 toolbar 结构稳定，同时清空标题栏/toolbar 相关 AppKit 背景层、透明化 chrome，并只保留红黄绿按钮可见，让下方同一个整窗 `MusicPlayerView` 专辑色背景贯穿标题栏和内容区。
- 2026-06-02 最新补充：展开页全屏玻璃、低分辨率封面纹理和近场专辑光都应首帧挂载。不要再用 `glassLayerReady` / `backdropAnimationReady` 做 520ms/730ms 延迟插入图层，否则展开完成后会重新出现横向断层和稳定态合成峰值。
- 2026-06-02 最新补充：`AlbumBlurredArtworkBackdrop` 已从 SwiftUI 整屏 `PosterImage.blur(radius: 90)` 改为异步读取 `ArtworkImageCache` 低分辨率封面，并由 `LowResolutionArtworkBackdropLayer` 的 `CALayer` 拉伸柔化；歌词卡中心 `LyricStageLight` 也改为 `CAGradientLayer`，`FloatingLyricsGlass` 的悬浮阴影改为带 `shadowPath` 的 `GlassPanelShadowLayer`。视觉仍保留专辑封面氛围和玻璃悬浮感，但拖动窗口时不再让系统反复合成大面积实时高斯 blur / SwiftUI 大阴影。
- 2026-06-02 最新补充：歌词大卡片不再使用整块 `NSVisualEffectView` 或连续 pointer 采样；`LyricCardEdgeDepthOverlay` 的上下深度改为连续渐变，`FloatingLyricsGlass(isLyricsCard: true)` 走静态雾面、专辑色高光和描边。小控制栏、弹层和收起按钮仍可保留小面积 live glass，但不要把这条路径扩展回大歌词面板；展开页整体 hover 采样维持 balanced，不要回到 60Hz 全量采样。
- 2026-06-02 最新补充：歌词 seek 不再使用“下一句保险”作为二次落点。`PlaybackSeekState.scrubbing/seeking/settled` 均按拖动目标或 AVPlayer/mpv 真实回读时间定位当前行，第一条大于目标时间的歌词时间戳只作为当前句结束边界，不能再让 `LyricSeekResync` 等到下一句才把歌词滚回去。
- 2026-06-01 最新补充：`MusicTimedLyricsScrollView` 新增短窗口追赶重试。seek/边界保险后如果 `lastAutoScrolledIndex` 已经等于 active 行但实际视口没有跟上，当前行播放超过容忍时间后会按 `catchUpRetryInterval` 节流重发对齐，并在动画后做两次无动画稳定居中；普通播放不打开无限重试，避免日常歌词滚动抖动。
- 2026-06-01 最新补充：展开页和底栏进度条的高频刷新继续下沉。`MusicExpandedProgressRow` 只保留收藏、进度时间线和队列三段结构，`currentTime/duration` 订阅移动到 `MusicExpandedProgressTimeline`；底栏随机/循环按钮也不再随进度 tick 重建，时间文本和滑杆由 `MusicMiniProgressTimeline` 独立刷新。
- 2026-06-01 最新补充：歌词换行抛动继续收敛。active 行的逐字/分词字重保持稳定 semibold，只通过颜色和轻位移表现播放头；`LyricFlowLayout` 按当前字宽预留换行余量，降低高亮推进时因字重或测量宽度变化造成的重新折行。
- 2026-06-01 最新补充：音乐展开页封面光效改为事件驱动的双进度收束。`MusicExpandedArtwork` 现在把封面本体和光晕拆成 `coverVisualProgress` / `glowVisualProgress`，暂停时先把 glow 收到小于最终封面的范围，再延后收起封面；播放恢复时先亮光再推回封面。该层只订阅播放/暂停，不跟随 `currentTime` 或播放时间轴持续重绘。
- 2026-06-01 最新补充：歌词换行的“抛跳感”通过 `AppMotion.lyricFlow` 单独收敛。行切换去掉过强 scale transition，逐字/分词的字重和上下位移降低，`LyricFlowLayout` 的换行余量也缩小，避免同一句跨视觉行时因为宽度/字重变化重新断行。
- 2026-06-01 最新补充：歌词卡片、控制栏和收起按钮的 `FloatingLyricsGlass` 增加静态专辑色边缘浸染层，歌词卡片额外有 `LyricEdgeTintOverlay`。这些都是静态渐变/描边，不接入播放时间、鼠标全局采样或音频频谱；后续不要为了“光效活跃”重新把背景光接回 `TimelineView` / `currentTime`。
- 2026-06-01 最新补充：歌词 seek 二十多轮仍错行的核心原因之一已定位：`MusicTimedLyricsScrollView` 把 `PlaybackSeekState.settled` 长时间当成 seek 展示冻结态，下一句边界到来时高亮可能还固定在 `resolvedTime`。现在 `settled` 只在下一句边界前用于真实落点等待；边界保险触发或没有保险时，当前行、逐字进度和自动滚动回到真实 `lyricTime`。只有 `scrubbing` / `seeking` 允许整行 seek 高亮和目标时间预览。
- 2026-06-01 最新补充：歌词新增普通播放等待与追赶机制。`MusicTimedLyricsScrollView` 普通播放时会对行推进保留很短等待窗口，避免边界抖动时提前跳下一句；如果当前视口落后 active 行多行或超过追赶容忍窗口，会跳过慢动画快速对齐。歌词视图不再直接 `@ObservedObject` 整个播放器，而是通过 `MusicLyricClockObserver` 只订阅 `lyricTime` / `seekState`。
- 2026-06-01 最新补充：排查歌词同步算法后确认 `audioEnergy` / `precise` 的后台音频对齐当前只补充逐字/分词片段，不应移动行级 LRC 时间戳。后续优化算法时不能把音频能量对齐结果写回 `TimedLyricLine.time`，否则 seek 落点会和歌词文件原始标签脱节。
- 2026-06-01 最新补充：音乐展开页继续做无感性能优化。展开页进度行改用 `MusicExpandedProgressStateObserver`，音量按钮改用 `MusicExpandedVolumeStateObserver`，只在自身关心的字段变化时发布 SwiftUI 更新，避免播放器音量、状态、歌词时钟、进度 tick 互相触发整块控制栏重绘。
- 2026-06-01 最新补充：继续把 `MusicPlayerView` 的高频状态进一步拆散。根视图不再保留会误导未来使用的 `musicControls` 私有分支，歌词行只在 active 行计算逐字进度，非当前行保持静态；`MusicMiniSpectrum` 改为 `NSViewRepresentable` + `CAGradientLayer`，直接由 coordinator 订阅 `audioSpectrumBands/isPlaying` 并更新图层，不再通过 SwiftUI `Canvas` / HStack bar diff 驱动。背景光也从 SwiftUI `Canvas` 迁到 AppKit/CA 层组合，保留视觉但切掉每帧重绘热路径。
- 2026-06-01 最新补充：展开页视觉约束重新收紧到原需求。桌面壁纸采样已从歌词卡片/控制栏的主材质路径退场，统一改由专辑高斯底层取色或窗口内 material；`MusicExpandedArtwork` 的专辑 glow 距离和阴影半径略增，维持播放态的发光存在感但不扩大到桌面。歌词换行不再用更激进的 scale/transition，而是把 active / 邻近字改成更稳定的字重与位移，降低折行瞬间的跳变感。
- 2026-06-01 最新补充：音乐展开页在沉浸 chrome 稳定后会把背后的 `NavigationSplitView` 卸载成真正的空白承载层，释放列表、海报墙和筛选结果的资源；收起前会先无动画预热挂回下层，再让播放器退场，做到用户不易察觉的资源回收。歌词卡片、控制栏和收起按钮继续共用 `FloatingLyricsGlass`，并增加轻量静态雾面纹理与略厚的窗口内毛玻璃采样，统一“磨砂”质感但不把动态效果扩散到长列表。
- 2026-06-01 最新补充：结合外部链路分析后继续修复歌词 seek。`boundaryOverrideIndex` / `LyricBoundaryCorrection` 已删除，下一句保险改为不改 active index 的 `LyricSeekResync`：只记录 seek 目标后的第一条歌词时间戳，真实 `lyricTime` 到达后滚到真实当前行。seek 对齐不再通过 `.id(UUID())` 重建歌词 ScrollView，程序性 `proxy.scrollTo` 会短暂屏蔽滚轮监听，避免自动滚动把自己误判成用户浏览。`timedLyrics` 内容变化（例如后台音频对齐替换同数量行）也会触发重新对齐。
- 2026-06-01 最新补充：拖动进度条开始和提交新 seek 时会取消旧 `seekSyncCorrectionTask`，避免上一轮延迟校验在新一轮 scrubbing 期间把 `currentTime` / `lyricTime` 写回旧位置。后续不要让旧 seek 复核任务跨过新的用户拖动周期。
- 2026-06-01 最新补充：音乐展开页继续做无感懒加载优化。全屏高斯封面背景改到 `glassLayerReady` 后再挂载，歌词卡片等 `entrancePhase >= 1` 后再创建，`MusicExpandedArtwork` 暂停态不可见的模糊封面 glow 不再构建；这些都不缩减最终视觉，只降低展开首帧和暂停态负载。
- 2026-06-01 最新补充：音乐展开页光效已按用户要求取消随音乐/播放时间变化。`AlbumGlassBackdrop` 和 `AlbumNearFieldIlluminationLayer` 现在只绘制静态专辑色 Canvas，不再持有 `MpvPlayerController`、`TimelineView`、本地播放时钟或 `playbackLightProgress`；后续不要恢复播放进度、播放/暂停、节奏脉冲或音频能量驱动的背景/近场光。
- 2026-06-01 最新补充：音乐展开页性能优化方向改为“视觉静态、订阅下沉”。`MusicExpandedArtwork` 不再用 `@ObservedObject` 直接订阅播放器，只通过 `MusicMiniTransportStateObserver` 接收播放/暂停变化，避免 `currentTime` tick 重绘封面、光晕和阴影。下方 2026-05-31 / 2026-05-29 关于 `playbackLightProgress`、60Hz/30Hz `TimelineView`、动态 Canvas 的条目仅保留为历史背景，不能作为后续实现依据。
- 2026-06-01 最新补充：歌词 seek 链路已直接重写，旧 `LyricSeekRecovery` / `LyricSeekBoundaryCorrection` / `lyricClockSerial` / `TimelineSeekSnapshot` / 多轮延迟校正 Task 已移除。后续不要沿旧 recovery/boundary 思路补丁式修复；新的唯一入口是 `MpvPlayerController.seekState: PlaybackSeekState?`。
- 2026-06-01 最新补充：拖动进度条后 `currentTime` 只用于进度条即时反馈，`lyricTime` 不再在 `beginTimelineSeek` 中乐观写入目标，只能由 AVPlayer/mpv 真实回读经 `applyPlaybackClock` 更新。`MusicMiniSeekSlider` 在拖动开始/变化/结束时分别调用 `beginScrubbing` / `updateScrubbing` / `finishScrubbing`；`MusicTimedLyricsScrollView` 在 `scrubbing` 阶段按拖动目标显示目标行，`seeking` 阶段继续按目标行等待播放器落地，`settled` 阶段按真实 `resolvedTime` 或真实 `lyricTime` 居中真实行。
- 2026-06-01 最新补充：pending seek 的轮询确认必须同时满足“离开 seek 前旧位置”和“靠近目标”。近距离拖动时旧 timer 回读不能被当成 seek 成功；AVPlayer `finished == true` 的完成回调可以强制采纳真实落点，延迟复核仍会按节流补发底层 seek。
- 2026-06-01 最新补充：歌词视图收到 `PlaybackSeekState` 的 `scrubbing` / `seeking` / `settled` 时只对齐当前状态对应的真实 index，不再重置 `lyricViewportResetID` 或重建 ScrollView。普通播放推进监听真实 `lyricTime` 做平滑滚动；seek 后的下一时间戳保险只能触发一次 `LyricSeekResync` 滚到真实当前行，不能覆盖 active index，不能恢复 `.onChange`、循环 Task、旧 recovery 链路或 boundary override 互相抢状态的方案。
- 2026-06-01 最新补充：下面 2026-05-31 关于 `lyricSeekTargetTime` / `LyricSeekRecovery` / boundary correction 的条目仅保留为历史背景，已被 `PlaybackSeekState` 三阶段链路取代，不能按那些旧入口继续开发。
- 2026-06-01 最新补充，2026-06-09 修订：双语/翻译 LRC 常有同一时间戳的多行，旧二分查找会稳定选择同时间戳组的最后一行，表现为 seek 后必定差一行。`LyricSourceParser` 仍要保留同时间戳行的原始顺序并去重；完全重复文本或真正同一句分段可以合并为一个显示块，但含假名日文原文 + 纯汉字中文翻译必须保留为相邻独立 `TimedLyricLine`，播放/滚动锚点优先落在含假名日文原文，翻译行作为同时间戳伴随行显示。
- 2026-06-01 最新补充：`LyricSourceParser` 已支持 LRC `[offset:+/-毫秒]`，并把偏移同时应用到普通 LRC 行时间和增强 LRC 片段时间。忽略 offset 会导致整首歌词稳定快/慢数秒到十几秒，即使 seek 逻辑按真实播放时间找行也会稳定错行。
- 2026-05-31 最新补充：歌词 seek 的 pending 闸门必须覆盖所有播放器时间回写路径，不只是 seek 完成回调和延迟校验。`startTimer()` 中 AVPlayer/mpv 的轮询时间也必须统一走 `applyPlaybackClock`；不要再在 timer 里直接写 `currentTime` / `lyricTime`，否则拖动进度条后旧播放时间会在 0.18 秒轮询内把歌词时钟拉回旧行。
- 2026-05-31 最新补充：歌词 seek 现在有控制器级 pending 状态。`MpvPlayerController.seek(to:)` 会立即把 `currentTime` / `lyricTime` 钉到用户拖动的目标时间，并在 AVPlayer/mpv 真实落地前屏蔽旧播放时间轮询回写；pending 释放由 `applyPlaybackClock` 统一处理，完成回调和延迟校验都必须通过该入口。这样歌词卡片不会在 seek 后先跳到目标又被旧时钟拉回完全不相关的行。
- 2026-05-31 最新补充：歌词 seek recovery 的目标显示行按时间区间定位：用户拖动到目标时间 `T` 后，`MusicTimedLyricsScrollView` 通过 `TimedLyricLine.playbackPosition` 找到 `T` 落入的 `[本行时间, 下一行时间)` 区间，并把该区间对应行作为当前句；下一条歌词时间戳只作为结束边界，不作为当前句。recovery 期间用同一显示时间驱动高亮、逐字进度和滚动视口，避免滚动行与高亮行分裂。只有普通播放推进才回到 `TimedLyricLine.activeIndex` 的当前行判定。
- 2026-05-31 最新补充：歌词 seek 目标时间不能再从 `currentTime` 读取。`currentTime` 同时服务控制条即时反馈和播放器轮询回写，拖动进度后可能被旧 AVPlayer 时间覆盖，导致歌词按旧位置跳到完全无关行。现在 `MpvPlayerController` 单独发布 `lyricSeekTargetTime` / `lyricSeekRevision`，`MusicTimedLyricsScrollView` 只监听 `lyricSeekRevision` 建立 seek recovery；`seekSyncRevision` 只用于真实时间复核，不能重新发起目标行定位。
- 2026-05-31 最新补充：远距离 seek 未完成前，旧 `lyricTime` 的自然推进不能绕过控制器 pending 闸门写回。`reconcileSeekRecoveryWithActualTime` 现在以当前 `lyricTime` 所属歌词区间为准，只要真实行和 recovery 行不同就立即修正 recovery；不要再恢复“接近目标/朝目标移动”启发式。`LyricSeekBoundaryCorrection` 绑定 `lyricSeekRevision`，不要再绑 `seekSyncRevision`，否则 seek 完成/延迟校验自身递增会让下一句边界校正提前失效。
- 2026-05-31 最新补充：歌词来源 badge 只显示 `LyricTimingSource.displayTitle`，不要再通过 `textformat.abc` 或“甲乙丙”之类前缀暗示分档。`TimedLyricLine.activeIndex` 不再对行开始时间加 0.15s 提前量，而是按播放器真实歌词时钟定位当前行；`MpvPlayerController.lyricTime` 与控制条 `currentTime` 分离，seek 提交时 `currentTime` 可立即更新进度条，但歌词只在 AVPlayer/mpv 回读实际播放时间后更新。`MpvPlayerController.seekSyncRevision` 会在 seek 提交、AVPlayer/mpv 完成 seek 和短延迟真实时间校验后递增。`MusicTimedLyricsScrollView` 监听该修订，退出浏览态、清空 `lastAutoScrolledIndex` 并多次按 active line 居中滚动，用于进度条拖动后自动校正。
- 2026-05-31 历史背景：曾尝试通过重建歌词滚动视口和多轮 recovery 解决 seek 错位。该方向已在 2026-06-01 被废弃，因为它会让 `ScrollViewReader`、目标行和真实行互相抢状态；后续以 `PlaybackSeekState` + 真实 `lyricTime` + 被动 `LyricSeekResync` 为准。
- 2026-05-31 历史背景：曾让 seek 恢复态覆盖普通 active line，并给目标/校正行使用整行高亮。该方案已经删除；现在只有 `scrubbing` / `seeking` 可显示目标行整行高亮，`settled` 和普通播放必须回到真实 `lyricTime` 的当前行与逐字高亮。
- 2026-05-31 最新补充：`MusicExpandedLyricsPanel` 新增 `LyricStageLight` 和 `LyricCardEdgeDepthOverlay`。舞台光以卡片中心为圆心、限制在歌词卡片内并绘制在歌词文字下层；`FloatingLyricsGlass(isLyricsCard: true)` 会降低白色覆盖和专辑 tint，让中心附近玻璃更透，上下边缘再用轻量 material 渐隐增加模糊深度。注意后续不要把舞台光放到整屏背景或文字上层，否则会让歌词颜色发白。
- 2026-05-31 最新补充：音乐队列拖拽排序期间暂停 `restoreQueueScroll` 和可见行锚点更新，避免每次 `musicQueue` 移动都把列表滚回旧位置；`MusicQueueDragCoordinator` 对跨行移动做轻微节流，并用无动画 transaction 执行移动。队列行已 `.equatable()`，后续不要恢复拖动期间的滚动锚点自动恢复。
- 2026-05-31 最新补充：底部迷你播放器收起/展开的父层宽度保持完整可用宽度，内部封面在同一上层坐标系内向右贴边/向左展开，避免看起来跑到窗口下方再突然出现。收起态进度环绘制在封面外侧，使用 `AlbumColorPalette.progressLight/progressDark` 从专辑取色邻近色生成浅色未播放和深色已播放。
- 2026-05-31 最新补充：展开页封面抽为 `MusicExpandedArtwork`。暂停/播放只驱动单一 `playbackVisualProgress`，同步插值封面大小、位置、阴影、光晕透明度和扩散半径，形成连续“退后/推前”的空间感；背景和近场专辑光后续已改为静态 Canvas，不能再恢复 `playbackLightProgress`、播放时钟或节奏脉冲驱动。
- 2026-05-31 最新补充：`MusicExpandedArtwork` 的封面周边 glow、阴影、边缘高光和指针光源统一使用更陡的 `glowStrength` 插值，暂停末端接近 0，避免缩小完成后残留一圈光再硬切。`AlbumBackdropStaticGlowCanvas` 的环境光半径已略增，可自然照到歌词卡片和控制栏；封面四周发光距离仍应保持均匀，不要用单侧强光弥补环境照明。
- 2026-05-31 最新补充：歌词时间线新增 `LyricSourceParser` / `LyricAlignmentService`。TTML、YRC、QRC、KRC 和增强 LRC 的逐字/片段时间戳优先标记为 `exact`；普通 LRC 先走原有 `LyricHighlightEstimator` 的 `estimated` 路径，若本地音频可读则后台按行读取音频小片段，分析人声能量、静音区间和峰值变化生成 `aligned` 分段，并缓存到 `Caches/MediaLib/LyricAlignment`。`MusicExpandedLyricsPanel` 右下角有低存在感来源 badge，区分“原词逐字 / 音频对齐 / 估算同步”。对齐任务必须保持后台、可取消、按歌曲 ID 校验后再回写，避免影响播放进度刷新。
- 2026-05-31 最新补充：歌词同步设置新增 `LyricSyncAlgorithm`，设置页播放分组提供“快速估算 / 语速校准 / 音频校正 / 精确优先”。普通 LRC 现在由 `LyricEstimatedTimingBuilder` 在加载歌词时预计算 estimated 逐字时间段，播放 tick 不再按整行进度临时分配；音频校正和精确优先继续后台异步，缓存 key 带算法和版本。`TimedLyricSegment.durationHint` 用于 exact/estimated/aligned 的段长，长音字上升速度会随段长放慢。
- 2026-05-31 最新补充：音乐队列弹层继续降载。`MusicQueuePopover` 现在使用 `MusicQueueRowModel` 预计算标题/副标题/封面路径，行高固定并使用小尺寸封面缓存；移除了滑动时每行 `GeometryReader` 上报可见位置的 preference 热路径，拖拽排序也不再包额外 `withAnimation`。后续不要恢复逐行滚动几何采样，否则长队列滑动会再次掉帧。
- 2026-05-31 最新补充：收起态底部音乐封面新增 `MusicMiniCollapsedProgressRing`，只在收起封面形态用轻量 observer 订阅 `currentTime/duration`，沿封面外侧绘制专辑取色进度环：浅色为未播放，深色为已播放。完整底栏不要复用这个 observer，避免列表叠底栏时增加不必要刷新。
- 2026-05-31 最新补充：`PosterGridTopFade` 的 overlay 上移了 `AppSpacing.pageVertical + AppSpacing.headerToControls`，修正顶部渐隐遮罩错位压在海报首行中部的问题；继续保持轻量材质和浅 blur，不要把整个海报墙包进大面积 material。
- 2026-05-31 最新补充：底部迷你播放器收起/展开已改成封面横向移动衔接，`MusicMiniPlayerBar` 中完整底栏封面和收起态封面共享 `matchedGeometryEffect(id: "music-mini-cover")`；`MusicMiniPlayerCollapseScrollMonitor` 现在任意方向滚动开始即触发收起，不再只响应向下滚动。收起态频谱由 `MpvPlayerController.audioSpectrumBands` 驱动，只在 `MusicMiniPresetSpectrum` 出现时通过 `setAudioSpectrumVisualizationActive(true)` 开启；`AudioSpectrumAnalyzer` 在后台按当前播放时间读取本地音频 0.16 秒小窗口，计算 5 段真实能量条并约 0.34 秒节流发布，暂停时保持静态。海报墙 `PosterGridList` 顶部增加 `PosterGridTopFade` 的轻量材质渐隐遮罩；音乐歌曲列表补回右下返回顶部按钮并避让底栏。歌词换行的冲击感通过降低 `LyricFlowLayout` 行距和当前字上浮高度继续收敛。
- 2026-05-31 最新补充：普通逐句 LRC 已加入 `LyricHighlightEstimator` 估算逐字高亮路径。`TimedLyricLine.progress(in:index:currentTime:)` 用当前行开始时间和下一行开始时间计算行内进度，最后一句使用前几句平均时长和保守文本时长兜底；估算器清洗空格、换行、标点和符号，中文按字符、英文按单词分配时间，句尾权重略延长，输出原文字符索引用于当前字轻微放大/上浮。增强 LRC 的 `<mm:ss.xx>` 片段时间戳仍优先走真实 `SegmentedLyricFlowText`，只有缺失片段时才使用估算。手动拖拽歌词或进度条 seek 后，下一次 active line 变化会自动退出浏览态并滚回当前行，减少长期错位。底部迷你播放器在列表/设置页向下滚动时会收起到右侧封面，封面变暗并显示轻量预设频谱，暂停时频谱静止，点击封面展开；全局 pointer 光效半径、强度和倾斜幅度已继续收敛。
- 2026-05-31 最新补充：底部迷你播放器和音乐队列弹层进入静态玻璃性能档，队列弹层、底栏曲目信息、底栏按钮不再做鼠标驱动光源采样；底栏保留裁剪在 72pt 内部的静态专辑柔光，但专辑色染色已减弱，避免收起后控制栏取色残留继续污染底栏并降低滚动合成压力。展开页控制栏最大宽度压到 424pt，内边距、行距和 spacer 继续收窄但保留两行首尾按钮对齐。歌词当前行新增逐字/逐片段垂直动效：未播放文字略低，播放到时按 `AppMotion.lyric` 缓慢上升并轻微放大；普通 LRC 和增强 LRC 都走换行感知布局。设置页使用 balanced 静态玻璃性能模式，首页标签网格取消连续 pointer 边缘光；全局 balanced 模式降低指针采样频率、强度和倾斜幅度。页头搜索框/扫描按钮依据 Apple HIG Liquid Glass 控件层级增强边缘折射、暖白填充和轻暗边，强调按钮蓝色更深且渐变更克制。保险库解锁控件间距在锁定页和设置页都收窄。
- 2026-05-31 最新补充：剧集列表移除会吞掉双击的零距离拖拽手势，单击选中、双击播放恢复正常。视频 AirPlay 在路线选择开始时让代理 AVPlayer 以可听探测同步当前视频时间，外部路线生效后静音本地 mpv，减少选中设备后声音仍从本机输出的问题。音乐展开/收起的 `AppMotion.musicPlayer` 更紧凑，收起 chrome 恢复延迟缩短；展开控制栏最大宽度、内边距和按钮 spacer 继续收窄但保持两行首尾对齐。歌词当前行去掉呼吸柔光，普通 LRC 改为当前播放字符轻微放大并随换行平滑过渡；`FloatingLyricsGlass` 改用更透的 `ultraThinMaterial` 和更低白度填充，让歌词卡片、控制栏、收起按钮更明显透出底层专辑色。专辑页滚动时直接向卡片写入 hover 抑制环境，暂不响应 hover/检视效果。扫描器不再在扫描开始时删除整个源索引，改为全部文件成功导入后用临时 keep 表清理未再次出现的旧 ID；扫描取消或有错误时保留旧索引，避免中断后媒体库被清空。
- 2026-05-31 最新补充，2026-06-08 已更新：主窗口最小内容尺寸固定为 1088x720，依据侧栏 220pt、主内容最小约 848pt 和页头/底栏安全高度计算；当前同时写入 `contentMinSize` / `minSize`，并监听 `NSWindow.didResizeNotification` 兜底回弹，避免手动拖成只剩红绿灯。不要设置主窗口 `contentMaxSize`，以免影响 macOS 最大化/全屏。视频播放器最小内容尺寸由 `VideoWindowSizing.minimumControlSafeWidth` / `minimumControlSafeHeight` 与视频比例共同计算，除写入 `contentMinSize` / `minSize` 外，还在 `windowWillResize` 拦截过小拖拽，确保底部 596pt 控制条、左右 18pt 安全边、锁定按钮和加载层不会在缩小时错位。普通/页头按钮不再使用向下偏移外投影，强调播放按钮也只保留贴边光，继续避免按钮下方出现独立色块。
- 2026-05-31 最新补充：清晰度切换不再主动清空首帧状态或强制长时间加载层，尽量保留当前画面；进度条拖动改为拖动预览、松手提交 seek，减少切换清晰度后拖动时被 mpv 时间轴拉回。Emby 转码流仍通过 `StartTimeTicks` 快速续播，但当用户拖回当前转码分段之前时，会按目标时间重载当前清晰度 URL 并维护逻辑时间轴；切回原画时会用 `start=` 和短时多次校准确保继续从原时间播放。
- 2026-05-31 最新补充，2026-06-07 已更新：视频列表排序状态新增方向，重复点击同一排序项会在正序/倒序间切换；排序项已拆成“评分”和“评级”，“评分”读资料源 `rating`，“评级”读用户 `userRating`，缺失值按 0 参与排序。EMBY 服务端媒体库页面标题改为对应左侧栏名称，不再统一显示“EMBY 分类”。
- 2026-05-31 最新补充：音乐侧栏隐藏“未匹配歌曲”，旧 `music-unmatched` 选择会迁移到“歌曲”。音乐新增 `media_items.play_count`，每次发起音乐播放会递增；歌曲/专辑/艺术家页新增“最多播放”排序，专辑和艺术家按曲目播放次数汇总。最多播放排序下，歌曲行、专辑卡、艺术家行右键可重置播放次数，页头扫描按钮右侧提供一键重置所有歌曲播放次数。艺术家页筛选只保留“全部”，排序只保留按名称、按作品数量、按播放次数。
- 2026-05-31 最新补充：音乐播放次数递增不再修改 `updated_at` 或 bump `libraryRevision`，避免点击播放歌曲后 `MusicLibraryView` 误以为媒体库刷新并跳回首行。音乐队列弹层通过 `AppState.musicQueueScrollAnchorID` 在本次进程内记住上次停留附近的队列歌曲，不再写 `AppStorage` 跨启动恢复；队列变化后若记录的歌曲仍存在会恢复到该段，否则回到当前播放项。
- 2026-05-31 最新补充：视频播放器启用 mpv 内存缓存/预读参数以改善弱网播放；画质按钮固定显示“画质”，具体 1080P/2K/4K 只在弹层列表显示。控制条、弹层、滑条、预览气泡和播放/暂停按钮改成更轻的液态玻璃材质，播放/暂停按钮为胶囊形态，阴影更浅。
- 2026-05-31 最新补充：SMB/FTP 来源扫描前若本地挂载目录不可达，`AppState` 会读取 `RemoteCredentialStore` 中的网络 URL/账号，调用 macOS 打开对应网络 URL 触发重新挂载，并轮询原挂载目录；成功后继续扫描，失败才提示 NAS 不可访问。该方案依赖系统挂载能力，账号变化、服务器共享名变化或网络不可达仍需用户重新登录/挂载。
- 2026-05-31 最新补充：媒体源行对已保存凭据的 SMB/FTP 离线来源显示“重新挂载”按钮，手动触发同一套 macOS 系统挂载流程；成功后清理离线源缓存并刷新页面状态。扫描前自动重挂载仍保留。
- 2026-05-31 最新补充：音乐 AirPlay 已移除本机同播功能和设置项，主音乐 `AVPlayer` 始终允许系统外部播放；`AppSettings.keepLocalAudioWithAirPlay` 仅保留为旧配置解码兼容，不再驱动 UI 或播放器行为。视频 AirPlay 触发时不再用 `routePickerRevision` 重建隐藏 route picker，避免点击后系统路线选择器被刷新打断。
- 2026-05-31 最新补充：音乐展开覆盖层出现时立即隐藏工具栏侧栏切换按钮，标题栏透明/标题隐藏仍按 `musicImmersive` 延后切换，以免侧栏收起状态下全屏音乐页露出系统侧栏按钮。剧集选中态增加左侧选中条和更深描边；歌词当前行增加轻微呼吸/柔光动效，手动浏览时暂停。
- 2026-05-31 最新补充：音乐展开覆盖层隐藏侧栏按钮时会同时扫描 toolbar item 和标题栏视图层级里的系统侧栏 `NSButton`，并在展开后短延迟重试，处理侧栏收起状态下系统按钮晚创建的问题。剧集行按下鼠标即更新选中态，保留双击播放；当前歌词行呼吸亮度和柔光增强，歌词换行/切换加入淡入缩放过渡。
- 2026-05-30 最新补充：音乐展开/收起外层覆盖层只做 opacity，不再 scale，避免顶部标题栏和窗口边缘露出系统白底；展开时先挂载整窗播放器，再延后隐藏标题栏，收起时等播放器回到底栏后再恢复 chrome。`MainWindowToolbarVisibilityGuard` 保持主窗口标题栏透明，并将 `contentMinSize` 限制在不超过当前内容尺寸，降低反复展开后窗口被 AppKit 撑高的风险。`ContentView` 根层增加统一 `AppPageBackground` 兜底，启动或页面切换时顶端不应再出现纯白系统背景。
- 2026-05-30 最新补充：除音乐展开页外，普通页面视觉从上一轮冷白/冷灰蓝改为 Apple Music 式暖白珍珠玻璃。`pageBackground`、`cleanPanelFill`、`cleanFieldFill`、`LiquidGlassSurfaceLayer`、`LiquidGlassButtonStyle`、`HeaderControlGlassBackground`、`GlassMenuButton` 和筛选胶囊都使用浅米白/香槟左上高光，冷蓝只保留给图标、少量强调按钮和轻微折射；后续不要把普通页面搜索框、扫描按钮和选中态再调回大面积蓝色。
- 2026-05-30 最新补充：普通页面不应再直接使用 `Color.accentColor` / `.blue.opacity` 绘制状态胶囊或选中图标；媒体源图标底、详情页合集和字幕语言标签、设置勾选、剧集选中、首页空状态引导、音乐标签候选勾选已统一改用 `AppColors.selectedGlassTint` 与暖白玻璃底。应用内语义图标仍可保持蓝系无边框符号风格。
- 2026-05-31 最新补充：`HeaderControlGlassBackground` 现在用于页头搜索框/扫描/清除记录按钮的更厚实暖白系统玻璃采样，以获得更接近 Apple 自带软件的搜索/工具按钮质感；重复列表行、设置分组、海报卡仍走 cheap 静态表面。`LiquidGlassButtonStyle`、`RepeatedGlassButtonStyle`、`glassFormField` 和 `GlassMenuButton` 都要裁剪到自身圆角，避免按钮底部露出直角色块。
- 2026-05-30 最新补充：音乐歌曲行 hover/选中态左右内收，防止右侧圆角边缘被裁掉；选中高光用暖白玻璃、左上受光和轻微蓝色折射，不再整行冷蓝。`MusicPlayerView.FloatingLyricsGlass` 去掉固定左上径向光斑，歌词面板不应再出现与专辑无关的圆形印记。
- 2026-05-30 最新补充：`RemoteCredentialStore` 与 `PrivacyLockService` 已彻底停止读写和删除系统 Keychain；Emby/NAS 凭据与保险库 PIN 哈希只保存到 Application Support 的 `MediaLib/Credentials` 文件中。旧 Keychain 项不会迁移也不会清理，以避免 ad-hoc 签名更新后首次启动触发系统钥匙串密码框。
- 2026-05-30 最新补充：音乐展开页浮层玻璃统一为单层 `.thinMaterial` 透镜，歌词卡片、控制栏、弹层和收起按钮共用 `FloatingLyricsGlass`；专辑色只用于 tint、边缘折射和轻投影。控制栏现在先填满可用宽度再封顶，第一行收藏/队列与第二行 AirPlay/循环首尾边界对齐，进度条按剩余宽度自适应。
- 2026-05-31 最新补充：普通页头搜索框和扫描/清除记录按钮共用 `HeaderControlGlassBackground`，保持同一套暖白系统玻璃、左上浅米白/香槟高光、轻描边和接触阴影；后续不要在 `GlassSearchField` 或 `HeaderActionGlassButtonStyle` 中重新叠冷蓝填充或大投影。
- 2026-05-30 最新补充：`PageHeader` 现在固定为标题左侧、搜索框/扫描/清除记录等操作区右侧，操作区下边界与标题栏下边界对齐；视频海报页的页头和筛选条固定在列表外层，电视剧/动漫等页面在“全部/正在观看/已观看/想看/喜欢”等子页面之间切换时，不应再因为列表宽度、滚动条或按钮出现/消失导致页头元素左右位移。后续新增页面继续复用 `PageHeader`，不要重新手写标题栏。
- 2026-05-30 最新补充：`MarqueeText` 的文本测量层不再参与父布局，长标题会在卡片宽度内单行裁剪、尾部渐隐并在 hover 时首尾衔接循环滚动；不要恢复会用 `.fixedSize(horizontal: true)` 撑开父卡片的实现。
- 2026-05-30 最新补充：视频海报墙已改为 `PosterGridList` 的分块瀑布流：每个虚拟化列表块内用估算卡片高度分配到最短列，块内海报允许错落但保持固定竖向间距；标签使用 `PosterBadgeFlowLayout` 自适应排列，优先同排，换行时让底部行尽量排满。后续优化海报墙应继续保持虚拟化块、下采样缓存目标和滚动期 hover 抑制，不要回到一次性长 `LazyVGrid`。
- 2026-05-30 最新补充：音乐专辑卡片通过 `PosterImage(cacheTargetSize:)` 使用稳定缩略图缓存尺寸，减少专辑页虚拟化滚动时真实封面和默认图之间闪烁，也降低大封面解码/缓存驱逐压力。专辑页仍保持网格视觉与封面检视，滚动热路径不要恢复高分辨率封面目标。
- 2026-05-30 最新补充：音乐展开/收起会在 `ContentView` 层记录主窗口稳定 frame，并在展开、进入沉浸 chrome、收起和关闭阶段还原；`MainWindowToolbarVisibilityGuard` 负责保持 `fullSizeContentView`、透明 titlebar 和窗口尺寸稳定，只隐藏标题/侧栏展开按钮，不再隐藏或恢复整条 toolbar。展开态必须显式保持红黄绿按钮及其父视图可见。
- 2026-05-30 最新补充：音乐展开页四层视觉继续增强。底层加入低分辨率专辑图高斯模糊色板，并由 `AlbumPaletteCache` 从多个封面色相桶挑选主色、辅色和强调色；第二层 `MusicFullScreenGlassLayer` 保持整屏厚玻璃但降低白色覆盖，让底层色板透出；第三层歌词卡片/控制栏/收起按钮/弹层统一用更透亮的 `FloatingLyricsGlass`；第四层按钮保持在玻璃内容之上。控制栏略收窄，进度条更长且底色与面板拉开对比。后续不要把封面光扩大成整屏强染色。
- 2026-05-30 最新补充：`AppMotion` 的 hover/listHover 也改为短弹簧曲线，音乐背景动态层恢复 60Hz 平滑时钟。后续新增动画继续使用 `AppMotion`，不要直接写线性或短促 ease-out。
- 2026-05-29 最新补充：本轮按 Apple HIG 的材质层级、布局稳定性和图标留白原则继续纠偏。普通页面的 `pageBackground`、`cleanPanelFill`、`cleanFieldFill`、`LiquidGlassSurfaceLayer`、`LiquidGlassButtonStyle`、`GlassSearchField` 和 `GlassMenuButton` 降低正白覆盖，改为更冷的半透明玻璃、冷灰边缘和轻接触阴影；后续不要把普通页面卡片、按钮、搜索框再调成同一块纯白。
- 2026-05-29 最新补充：`PageHeader` 曾固定为标题行 + 操作行；2026-05-30 已调整为标题左侧、操作区右侧并下边界对齐。后续新增页面页头时继续复用 `PageHeader`，不要在单个页面手写不同的标题/搜索/按钮位置。
- 2026-05-29 最新补充：音乐展开页 `FloatingLyricsGlass` 已从偏白亚克力调整为更透亮的 `.thinMaterial` + 低白度 + 专辑色边缘光。歌词卡片、控制栏、收起按钮和弹层仍必须共用这套 modifier，避免材质再次分裂；不要恢复明显斜向假反光。
- 2026-05-29 最新补充：音乐收起路径改为播放器收到底栏后，用 `AppMotion.sidebar` 单独恢复侧栏，并延后 360ms 再恢复 chrome，减少底栏因侧栏预留宽度突变产生的最后几帧跳位。
- 2026-05-29 最新补充：`scripts/generate_icon.swift` 会裁掉源图约 7.6% 的展示留白，以移除导出图标外圈白边；这是导出裁切，不改变 `AppIconSource.png` 的主体设计。
- 2026-05-29 最新补充：第一阶段视觉回补已完成。`MusicPlayerView.FloatingLyricsGlass` 恢复为卡片级 `.regularMaterial` + 厚白填充 + 专辑色 tint 的受控玻璃，只用于歌词卡片、控制栏、弹层和收起按钮等少量大面板；不要把这一层复制到列表行、海报卡或普通按钮。`MusicMiniPlayerGlassSurface` 恢复单块 `.thinMaterial` 厚白底，内部按钮仍保持 cheap 路径，专辑柔光继续裁剪在 72pt 底栏内。
- 2026-05-29 最新补充：音乐展开/收起转场现在使用底部锚点缩放、位移和透明度组合，并把侧栏恢复、全屏柔光层和动态 Canvas 启动延后到主体动画之后。后续优化动画时优先继续分帧和缩小订阅范围，不要把窗口 chrome、侧栏、overlay 插入和动态 Canvas 重新塞回同一帧。
- 2026-05-29 最新补充：`MainWindowToolbarVisibilityGuard` 新增非全屏音乐转场 frame 守卫，会在沉浸 chrome 期间记录窗口 frame，并在 chrome/侧栏/overlay 恢复的延迟阶段持续校正；系统级全屏下仍不改 frame。若用户反馈展开态手动调整窗口后被恢复，需要把记录 frame 升级为监听用户 resize 后更新，而不是移除守卫。
- 2026-05-29 最新补充：`GlassSearchField` 改用透明 `NSTextField` 承载输入，避免 SwiftUI 原生 `TextField` 聚焦时出现白底；普通按钮和 `RepeatedGlassButtonStyle` 增强白色填充和描边对比。`PosterCardView` 不再显示视频封面底部播放进度条，音乐歌曲行 hover 使用更快的 `AppMotion.listHover`。
- 2026-05-29 最新补充：第二小轮把音乐展开页内部入场拆为封面/控制栏和歌词卡片两段；`cleanPanelFill` 与 `LiquidGlassSurfaceLayer.flat` 调整后，普通卡片和其上按钮的层级更清楚。视频海报卡、音乐专辑卡和歌单卡的 hover 只用固定高光、封面描边和小幅 scale，继续遵守滚动期 hover 抑制和 Reduce Motion。
- 2026-05-29 最新补充：视觉纠偏已完成。普通卡片不再使用纯白底，`LiquidGlassSurfaceLayer.flat` 恢复轻接触阴影和厚度；普通按钮降低正白填充并保留冷色边缘，避免和卡片融成一层。视频海报卡、音乐专辑卡和歌单卡取消 hover 整卡 scale，防止点击按钮时底层卡片产生位移观感。
- 2026-05-29 最新补充：音乐展开页移除了 `FloatingLyricsGlass` 中明显的斜向预渲染反光，改为径向专辑色透光；收起按钮改为复用同一套 `FloatingLyricsGlass`，材质与控制栏/歌词卡片一致。所有装饰 overlay 已加 `allowsHitTesting(false)`，后续新增玻璃装饰层也必须避免遮挡按钮命中。
- 2026-05-29 最新补充：`GlassSearchField` 的 AppKit 文本输入继续清理 `NSTextFieldCell` 和 field editor 背景，避免视频页搜索框聚焦白底。滚动期 hover 抑制缩短到约 90ms，鼠标移动会立即恢复 hover，避免滚轮停止后长时间没有悬停反馈。
- 2026-05-29 最新补充：按钮按压位移已收敛。`LiquidGlassButtonStyle`、`RepeatedGlassButtonStyle`、`HeaderActionGlassButtonStyle` 和 `MusicIconButtonStyle` 不再对按压态使用 scale 或阴影 y 偏移，只用透明度/边缘反馈，避免按钮下层卡片产生跳动观感。`PageHeader` 对自身布局禁用隐式动画，减少标题、搜索框和右侧操作区随状态切换抖动。
- 2026-05-29 最新补充：搜索框和普通按钮白度继续降低，`GlassSearchField` 改为更冷的透明玻璃层，普通/重复按钮降低正白覆盖并保留冷色边缘，以便在白色页面背景、卡片和按钮之间恢复层级。

## 1.1.1 2026-05-26 最新补充

- 2026-05-27 最新补充：本轮按用户反馈修复 Emby 命名空间和体验问题。`AppState.rebuildDerivedItemCaches()` 现在把 `emby://` 条目排除在本地 `cachedTopLevelItems` / `cachedMusicTracks` / 本地继续观看等派生缓存外，Emby 内容只显示在独立 EMBY 目录。`ContentView` 的 EMBY 侧栏只展示有条目的通用入口，并继续展示服务端 Views；无条目的分类不显示。后续不要把 Emby 条目放回普通视频/音乐侧栏。
- 2026-05-28 最新补充：视频播放器新增 Emby 远程清晰度选择。`EmbyService` 会写入 `MediaItem.videoBitrate`，数据库列为 `video_bitrate`；播放器中的 `RemoteVideoQualityPlanner` 只对 `metadataProvider == "Emby"` 且分辨率/码率足够的远程视频生成档位。原画使用原 URL 直连，非原画使用 Emby `Videos/{ItemId}/stream.mp4` 转码 URL，保留 `api_key`、`MediaSourceId`、`DeviceId`，并附加 `VideoBitrate`、`MaxStreamingBitrate`、`MaxWidth`、`MaxHeight`、`VideoCodec=h264`、`AudioCodec=aac`。档位最低为 1080P，1080P 最低视频码率约 5.8 Mbps；低于阈值的片源不显示清晰度按钮。
- 2026-05-28 最新补充：视频控制栏再次压缩。底部条不再显示标题行，默认最大宽度约 640pt，左右工具组和播放按钮尺寸都缩小。音量滑条拖动期间调用 `setVolume(..., remember: false)`，松手后才保存设置，避免拖动时反复写 UserDefaults；倍速弹层只保留滑条，按常见倍率吸附，拖动期间不反复同步外部路线和系统媒体信息。
- 2026-05-28 最新补充：挂载局域网/NAS 视频打开前会强制走比例探测，即使已有 `resolution` 也优先用 AVFoundation/ffmpeg 读取真实显示比例。`VideoAspectRatioResolver.probeLocalAspectRatio` 已加入 ffmpeg `-i` 输出解析，优先读 DAR，再读视频流宽高。`applyVideoAspectRatio` 对挂载网络文件使用更宽的比例容忍度，避免细小像素比例差异触发二次窗口 resize。
- 2026-05-28 最新补充：媒体源页操作按钮不再放在页头右侧，而是放到左对齐玻璃工具条卡片里。后续已把 Emby/Jellyfin/Plex 同步库、痕迹同步和本地/网络分类等行内选项收纳到每行设置弹窗；来源行只固定展示服务端类型或来源摘要，不再恢复旧的禁用分类菜单。
- 2026-05-28 最新补充：清晰度选择也覆盖已挂载的局域网/NAS 文件。`RemoteVideoQualityPlanner.isMountedNetworkFile` 通过 `volumeIsLocalKey == false` 和 `/Volumes/` 兜底识别非本机挂载路径；这类条目只在源分辨率高于 1080P 时生成“原画 + 播放端降采样”档位，并通过 `LibMpvClient.setString("vf", ...)` 对 mpv 设置 scale 滤镜，不重载文件、不改变窗口比例。注意挂载文件没有 Emby 这样的转码服务器，因此该路径不能降低网络读取码率，只能降低播放器端渲染分辨率。
- 2026-05-28 最新补充：视频控制栏进一步压缩和重排。底部控制条内不再提供外部打开按钮；左侧工具组为 AirPlay、音量、字幕、音轨，中心为上一集、播放/暂停、下一集，右侧为清晰度、倍速、全屏。控制条最大宽度和内边距收窄；弹层统一使用暗色播放器玻璃材质，避免白色弹层和暗色视频割裂。
- 2026-05-28 最新补充：进度条 hover 位移已修复。`VideoProgressScrubber` 的帧预览气泡现在挂在固定高度 scrubber 的 overlay 上，不参与主布局高度计算；后续不要把预览气泡放回进度条 `ZStack` 主布局，否则 hover 时控制栏会再次下跳。
- 2026-05-28 最新补充，2026-06-08 已更新：帧预览参考 Plex/Jellyfin trickplay 与 mpv/ffmpeg 缩略图思路，改为 `VideoFramePreviewGenerator` 的缓存 + AVFoundation + ffmpeg 兜底路径。本地文件优先 AVFoundation，远程 Emby 和挂载网络路径优先 ffmpeg 后台抽帧；当前缓存目录为 `Caches/MediaLib/PreviewFrames`，播放器 hover 和右键“预生成章节图”后台任务共用这些 jpg。抽到黑帧会尝试前后邻近时间点，未完成时显示暗色玻璃加载态而不是黑块。后续若做真正 sprite/VTT storyboard 或自动计划任务，不要阻塞当前播放线程。
- 2026-05-28 最新补充：视频缓冲提示由 `MpvPlayerController.updateBufferingState` 读取 mpv `paused-for-cache` 和 `cache-buffering-state`，UI 为 `PlayerBufferingOverlay` 半圆旋转图标和百分比。缓冲百分比有 1% 更新阈值，避免远程流加载时控制层高频刷新。
- 2026-05-28 最新补充：播放器窗口比例锁定增强。`VideoPlayerWindowPresenter` 创建 `NSHostingController` 后在 macOS 13+ 设置 `sizingOptions = []`，避免 SwiftUI 弹层把理想尺寸反馈给窗口；弹层内容统一 `.fixedSize`，窗口真实比例回传时更新 `contentAspectRatio`/`minSize`。后续新增播放器弹层也要固定尺寸，不要让它参与播放器根视图布局。
- 2026-05-28 最新补充：最新一轮继续压缩播放器控制条到约 596pt，并按使用频率重排：AirPlay/音轨/清晰度在左侧，音量/字幕/倍速/全屏在右侧，中心仍是上一集/播放/下一集。锁定/解锁小锁使用无动画事务切换，避免按钮点击触发控制条动画造成视频短暂卡顿。
- 2026-05-28 最新补充：Emby 清晰度切换会维护 `playbackTimelineOffset`。非原画转码 URL 带 `StartTimeTicks` 时，mpv 的 `time-pos` 会换算回原片时间轴，`duration` 优先使用原 `MediaItem.duration`，seek 时再映射为当前转码段时间；不要把转码段剩余时长直接写回 UI 总时长。
- 2026-05-28 最新补充：字幕弹层已区分内嵌字幕和 mpv `track-list` 中 `external == true` 的外挂字幕，外挂使用 `external-filename` 匹配同目录文件；点击同目录字幕会优先选择已加载轨道，否则再 `sub-add`，避免重复新增行。自动加载目录字幕点击后会设置 `subtitleAutoLoadEnabled` 并显示勾选。
- 2026-05-28 最新补充：帧预览悬停优先读内存缓存，未命中才后台抽帧，并预热前后邻近 bucket；远程/挂载路径 bucket 收紧到 3 秒，本地为 1.5 秒。预览气泡使用更薄的播放器玻璃边框。后续若做真正 storyboard/trickplay，可考虑扫描阶段预生成 sprite/VTT 或 Emby trickplay 接口，但不能让主播放线程参与抽帧。
- 2026-05-28 最新补充：倍速弹层改为自绘 `PlayerSnapSlider`，不再使用系统 `Slider`，避免下方刻度横线和文字标尺错位。媒体源工具条外层增加圆角裁剪和细描边，修复左侧 sharp corner。
- 2026-05-28 最新补充：视频播放器打开链路继续降压。`PlayerView` 现在先调用 `controller.configure` 启动 mpv，再用后台 utility 任务计算外挂字幕列表、挂载局域网/NAS 标记和清晰度档位；结果回来后再填充字幕/清晰度菜单。不要把 `SidecarSubtitleFile.find`、`RemoteVideoQualityPlanner.isMountedNetworkFile` 或清晰度规划放回 `.onAppear` 同步路径，否则 NAS 目录枚举和 volume resource 读取会重新拖慢首帧。
- 2026-05-28 最新补充：帧预览分段逻辑改为按总时长自适应。`VideoFramePreviewGenerator.segmentInterval` 目标为本地约 96 段、远程/挂载约 84 段，并用最小/最大段长收敛；同一段内复用同一张缩略图，预取邻近段。后续不要恢复按固定 1.5/3 秒或按分钟生成缩略图的策略。
- 2026-05-28 最新补充：`PlayerSnapSlider` 和 `PlayerSpeedTickLabels` 共用扣除 24pt 滑块后的有效轨道宽度，修复实际倍速与下方刻度错位；后续改倍速 UI 时要保持滑块中心、吸附点和文字刻度使用同一套坐标。
- 2026-05-28 最新补充：视频首帧等待保护已加入。`MpvPlayerController.hasVideoFrame` 在 `dwidth/dheight` 或 `width/height` 有效前保持 false，UI 会继续显示加载层；`scheduleInitialVideoRedraws` 会在启动后一小段时间强制 `MpvOpenGLView.needsDisplay`，降低有声音但黑屏的概率。
- 2026-05-28 最新补充：音乐专辑取色新增 `AlbumPaletteColor.cleanedHSB`，低饱和灰脏色会回退到蓝青 fallback，偏灰棕/灰绿会提饱和和亮度并转向更干净的琥珀/青绿色。展开页专辑光照半径已收窄，避免专辑色大面积污染整屏；后续增强光效时优先调局部强度，不要再把动态径向光铺满整页。
- 2026-05-28 最新补充：首页进入第 5 阶段大库/NAS 收口。`HomeView` 不再在 `body` 中直接调用 `appState.items(...)` 做分类和搜索；现在用 `visibleHomeItems` / `visibleHomeItemsKey` 保存当前 tab 快照，搜索 120ms 去抖，电影/剧集/收藏/未观看等过滤和搜索匹配在后台 `Task.detached` 中完成。后续不要把首页 tab 内容退回 body 过滤，否则大库搜索和切 tab 会重新占用主线程。
- 2026-05-28 最新补充：按用户四层模型重构音乐展开页视觉。`MusicPlayerView` 现在是专辑封面高斯取色底板、整屏厚液态玻璃、封面/控制栏/歌词卡片内容层、按钮顶层的结构；`AlbumCoverIlluminationLayer` 从封面中心发出柔和节奏光，只照亮靠近封面的控制栏和歌词卡片近侧。后续调整音乐展开页时不要删除整屏厚玻璃层，也不要把封面节奏光扩大成整屏染色。
- 2026-05-28 最新补充：视频播放器音量/倍速弹层改为更窄的横向玻璃控制。`PlayerVolumePopover` 使用左侧图标 + `PlayerLinearSlider`，去掉标题和百分比；`PlayerSpeedPopover` 使用左侧图标 + 加长 `PlayerSnapSlider`，下方刻度共用同宽轨道；字幕按钮已移动到左侧工具组并放在音轨按钮左边。后续新增播放器弹层继续使用 `playerPopoverGlass()`，保持和控制栏一致的暗色透视玻璃。
- 2026-05-28 最新补充：根据用户截图修复音乐展开页布局上漂。`MusicExpandedLayout` 现在区分顶部沉浸安全区和底部留白，非紧凑布局仍使用显式 `leftRect` / `lyricsRect`，但内容层不再贴到窗口 chrome；专辑封面尺寸增加高度比例和绝对上限。底层 `AlbumBackdropStaticLayer` 不再渲染可识别的大尺寸专辑图，只用清洁化专辑色生成抽象高斯色板，避免背景图看起来像组件飞出屏幕。
- 2026-05-28 最新补充：音乐展开页材质和光照再次收口。控制栏与歌词卡片都走同一套 `FloatingLyricsGlass` 强度，差异只来自圆角/尺寸；`AlbumCoverIlluminationLayer` 和 `AlbumBackdropLightCanvas` 的半径、漂移和不透明度已降低，封面节奏光只照亮近场，不再扩散成整屏绿/蓝染色。后续增强时优先调局部近场光，不要恢复大图背景或远距离强泛光。
- 2026-05-28 最新补充：音乐库筛选工具条使用 `ViewThatFits`，宽度不足时筛选胶囊和排序菜单上下排列，避免歌单/歌曲页的排序按钮与“有歌词/未匹配”等歌词筛选按钮重叠。视频播放器底部控制条左右工具区改为等宽 180pt，保持字幕在音轨左侧，同时让中间播放组按控制条真实中心对齐。
- 2026-05-28 最新补充：继续按用户最新截图修复音乐展开页。专辑取色算法不再人为偏移 hue，也不再把低饱和色清洁化到固定青绿 fallback；`AlbumPaletteCache` 现在从封面采样中找主色相，primary/secondary/accent 只使用该主色相邻近的采样色或同 hue 的白化/强调版本。`FloatingLyricsGlass` 面板 tint 也只使用 primary + 白色玻璃层，避免歌词卡片和控制栏出现封面里不存在的绿色/杂色。
- 2026-05-28 最新补充：音乐展开页边距规则改为显式对齐。`MusicExpandedLayout` 使用同一个 `panelInset` 约束歌词卡片上下边距，控制栏左边距和歌词卡片右边距继续共用 `contentLeadingInset`，收起按钮的 origin 也改为 `contentLeadingInset/panelInset`，与控制栏左边和歌词卡片顶边对齐。
- 2026-05-28 最新补充：系统级全屏下收起音乐面板的崩溃风险已处理。`MainWindowToolbarVisibilityGuard.Coordinator` 恢复窗口 styleMask 时会保留当前 `.fullScreen` 标记，避免在 macOS full screen space 内把窗口直接还原成非全屏 styleMask。后续改音乐 chrome 隐藏/恢复路径时必须继续保留这个保护。
- 2026-05-28 最新补充：下一轮优化继续针对音乐展开页播放态高频动态层。独立 45Hz `AlbumCoverIlluminationLayer` 已移除，封面近场节奏光合并到已有 60Hz `AlbumBackdropLightCanvas` 中绘制；展开页现在只保留一条 `TimelineView + Canvas` 动态刷新链路，仍保留封面附近脉冲/漂移光效，但减少一套 SwiftUI 时间线、Canvas 视图和 WindowServer 合成入口。后续若继续优化展开页，优先沿着“单一动态 Canvas + 静态玻璃层”的方向推进。
- 2026-05-29 最新补充：音乐展开页播放态订阅边界继续下沉。`MusicPlayerView` 根视图不再用 `@ObservedObject` 订阅 `MpvPlayerController`，播放进度只刷新 `MusicExpandedLyricsPanel`、`MusicExpandedControls` 和 `AlbumGlassBackdrop` 这几个局部组件；布局、专辑取色、静态玻璃层和最小化按钮不会再跟着进度 tick 重算。`AlbumGlassBackdrop` 的 `TimelineView + Canvas` 从 60Hz 改为 30Hz 平滑低频节奏，视觉仍保留专辑封面附近的柔和位移/变色光效，但稳定播放时的全屏动态层合成压力更低。
- 2026-05-29 最新补充：音乐展开页动态光效继续拆层。`AlbumBackdropStaticLayer` 现在通过 `AlbumBackdropStaticGlowCanvas` 持有远场专辑色径向光和斜向光束，这些只随专辑/布局变化重绘；`AlbumBackdropLightCanvas` 只保留封面附近三组低频节奏柔光和轻微明暗呼吸。后续如果继续优化，优先减少动态近场光数量或把部分面板边缘染色并入静态层，不要把远场光束重新放回播放中的 Timeline。
- 2026-05-29 最新补充：音乐展开页歌词卡片和控制栏继续拆订阅边界。`MusicExpandedLyricsPanel` 外层玻璃不再观察播放器，只有 `MusicTimedLyricsScrollView` 在有 LRC 时订阅播放进度；`MusicExpandedControls` 外层玻璃也不再观察播放器，进度行、运输按钮行、音量按钮和状态提示行各自局部刷新。后续不要把 `@ObservedObject var controller` 重新放回整块歌词卡片或整块控制栏，否则播放进度会再次触发 material/blur/shadow 外壳重绘。
- 2026-05-29 最新补充：视频播放器根视图订阅也已下沉。`PlayerView` 现在用 `@State` 持有 `MpvPlayerController`，状态面板、窗口 chrome 显隐、比例回传、音量 HUD 和控制条通过 `PlayerControllerProjection` 只发布各自关心的 Equatable 快照。控制条拆为时间轴状态和运输按钮状态，`currentTime` tick 主要刷新进度行，不再让音轨、字幕、清晰度、倍速、音量、AirPlay 等按钮区整块跟着重算。后续不要把播放器根视图或整块控制条改回 `@ObservedObject/@StateObject` 直接观察控制器。
- 2026-05-29 最新补充：视频海报墙曾使用热窗口降载；2026-05-30 已升级为 `PosterGridList` 分块瀑布流并由列表行虚拟化承载。后续如果继续调整海报墙，应沿当前分块/虚拟化方向推进，不要恢复旧 `LazyVGrid` 分批追加和占位壳路径。
- 2026-05-29 最新补充：Emby 同步进入大库分页路径。`EmbyService.fetchItems` 现在对每个服务端 View 的 `Users/{UserId}/Items` 请求使用 `StartIndex` / `Limit=300` 循环拉取，避免一次性返回巨大 JSON；Episode 缺少 Series 父项时的合成逻辑改为跨页收集候选并在全部页面映射后统一补父项。后续如果继续优化 Emby，同步写库可再做批量事务/差量更新，而不是拉完后全删全插。
- 2026-05-29 最新补充：远程海报失败缓存增加指数退避。`ArtworkImageCache` 的本地缺失路径仍短缓存约 8 秒；远程 http/https 海报下载失败或解码失败会从 30 秒开始退避，最长 10 分钟，减少弱网、失效 token 或 Emby 忙碌时滚动/切页反复打同一批 URL。成功加载或显式 `invalidateMissing` 会清掉对应失败记录。
- 2026-05-29 最新补充：重复表面规范已落成代码。`AppColors.swift` 新增 `GlassSurfaceRole`、`repeatedSurfaceHover` 和 `RepeatedGlassButtonStyle`，列表行、海报卡、音乐专辑/艺术家/歌单卡片、设置项及其 hover/selected 状态应留在 cheap 档，不要重新挂 material、大阴影或实时 `pointerLiquidLight`。`PosterCardView` 的 hover 已从连续 pointer 光改为固定绘制高光/左侧光带/描边；音乐集合卡片内“播放”按钮已改用无 material、无阴影的重复按钮样式。
- 2026-05-29 最新补充：普通页面重复控件继续去 material 化。`GlassSearchField`、`glassFormField` 和 `GlassMenuButton` 现在使用静态白玻璃填充、直接高光描边和轻接触阴影，不再为每个搜索框、表单输入和菜单按钮创建 `.regularMaterial` 实时模糊层；这些控件在首页、媒体库、音乐库、媒体源和设置页会大量复用，后续不要在它们内部重新挂 material 或 blendMode 高光。
- 2026-05-29 最新补充：普通页面按钮成本继续收敛。`LiquidGlassButtonStyle` 的非突出按钮已经分叉为 cheap 路径，去掉 blur/screen 高光和大投影，仅保留静态白玻璃、直接描边、轻接触阴影和较弱边缘光；`prominent=true` 的蓝色主按钮仍保留更厚高光。媒体源行扫描/删除、音乐元数据候选展开、字幕结果下载等可滚动行内按钮已改用 `RepeatedGlassButtonStyle`，后续新增行内小按钮优先使用该样式，不要默认套通用 rich 按钮。
- 2026-05-29 最新补充：弹层结果列表进入虚拟化路径。`MetadataSearchView` 的元数据搜索结果、`SubtitleSearchSheet` 的字幕结果和 `MusicTagScraperSheet` 的候选歌曲列表已从 `ScrollView + LazyVStack` 改为原生 `List`，并隐藏系统背景/分隔线保留玻璃行卡片。后续新增可能超过几十行的弹层结果列表时，应优先使用同样的 `List` 行承载方式，不要恢复会滚动累积行视图的惰性堆叠。
- 2026-05-28 最新补充：下一轮优化继续处理底部迷你播放器常驻时的合成成本。`MusicMiniAlbumGlowLayer` 原先用远大于底栏高度的 `Circle` 叠径向渐变再裁剪到 72pt 底栏；现在改成在底栏矩形内直接绘制同等径向渐变，视觉仍是静态专辑柔光，但宽窗口下减少不必要的大面积离屏图形。
- 2026-05-27 最新补充：视频播放器打开前比例预判已收紧。`VideoPlayerWindowPresenter` 先用条目的 `resolution` 计算窗口比例；Emby 条目该字段来自服务端 `MediaStreams` 宽高。本地条目缺少分辨率时会先通过 AVFoundation 读取视频轨道自然尺寸和 `preferredTransform`，再创建窗口；窗口宽度仍按设置页 `videoPlayerPreferredWidth` 和目标屏幕可用区域收敛。mpv 回传比例与预判一致时不再触发二次 resize。
- 2026-05-27 最新补充：视频控制区已改成第一行完整进度条、第二行居中“上一集 / 播放暂停 / 下一集”，控制条内不再放关闭和跳秒按钮。音量、倍速、字幕和音轨均为按钮弹层；音量快捷键只显示临时音量 HUD。`LibMpvClient` 只新增 mpv 属性读取能力，渲染仍走 libmpv render API + `NSOpenGLView`。
- 2026-05-27 最新补充：视频音轨/字幕弹层从 mpv `track-list` 读取内嵌轨道，字幕还会发现同目录 `.srt/.ass/.ssa/.vtt` 文件并可加载；进度条 hover 对本地文件使用 AVFoundation 抓取附近帧做预览，远程 Emby 流先只显示时间，避免额外拉远程视频流。
- 2026-05-27 最新补充：Emby Episode 同步时优先使用服务端 `SeriesId` 作为父级，解决 `ParentId` 指向 Season 时详情页无法拿到剧集的问题。`EmbyService` 同步字段包含 `MediaStreams`，会写入分辨率、音频/视频编码和文件大小，让远程流媒体详情更像本地条目。详情页远程文件区显示“Emby 流媒体”，外部打开走统一播放器入口，不直接展示带 token 的 URL。
- 2026-05-27 最新补充：按用户继续反馈修复 Emby 分类和播放路径回归。媒体源列表中的 Emby 源固定显示为 `EMBY`，不再提供手动重分类；Emby 条目 `sourcePath` 改为 `emby://.../library/<viewID>/type/<collectionType>/name/<encodedName>`，分类用 ViewId 稳定定位并保留服务端名称/类型供侧栏显示。如果同步结果只含 Episode 而没有 Series，`EmbyService` 会用 `SeriesId/SeriesName` 合成剧集父项。系统播放器打开远程 http/https 媒体时优先使用已安装的视频播放器应用，避免 URL 被浏览器当网页打开。
- 2026-05-27 最新补充：远程 http/https 海报现在通过 `ArtworkImageCache.remoteImage` 下载、下采样并缓存，`PosterImage` 使用 `RemotePosterImage`，不再使用裸 `AsyncImage`。这是为了避免 Emby 页面 hover、滚动或切换标签时远程海报视图重建并闪回默认封面；后续不要改回 `AsyncImage`。
- 2026-05-27 最新补充：音乐展开页进一步加强专辑中心光照和玻璃组件染色，底色减少白化断层，动态 Canvas 的径向柔光/斜向光束覆盖更远但仍只绘制动态层；`FloatingLyricsGlass` 增加左侧专辑色边缘高斯光，形成组件朝向封面的染色。新增 `性能卡顿分析报告.md` 汇总当前卡顿/掉帧界面、成因判断和后续突破口。
- 2026-05-27 最新补充：本轮复查用户反馈“内建屏动画仍低于 30 帧、外接 144Hz 观感尚可”，结论仍不是显式 30fps/DisplayLink 限制；新的主要峰值在音乐展开页稳定播放后的全屏 60Hz `Canvas`：旧实现每帧重画静态底色、多层大渐变、动态径向光和斜向光束，再叠加歌词/控制玻璃的 material、blur、shadow 与 hover 光源。内建 Retina 60Hz 高像素密度屏幕一旦合成超过 16.7ms 就会表现为 30fps 阶梯，外接高刷屏因刷新率/缩放/像素负载差异会掩盖。当前已拆成静态专辑色底层 + 仅动态柔光 Canvas，并在不降低视觉的情况下扩大专辑发光范围。
- 2026-05-27 历史补充：展开页播放按钮和展开页进度条当时已跟随专辑取色，底部迷你播放器进度条曾固定系统蓝/青以规避取色滞后；2026-06-07 后普通 fallback 已改为主题高亮派生色，后续不要把底栏进度或 now playing 状态退回固定蓝青。
- 2026-05-27 最新补充：Emby 同步现在先读 `Users/{userId}/Views`，再按每个 Emby 媒体库 ParentId 递归拉取 Movie/Series/Episode/Audio；条目 `sourcePath` 记录为 `emby://.../library/<viewID>/type/<collectionType>/name/<encodedName>`，左侧 EMBY 会显示服务端媒体库入口。刷新/删除 Emby 源时按 sourcePath 前缀清理旧条目，避免旧分类残留。
- 2026-05-27 最新补充：Emby 流媒体播放 URL 会优先使用服务端 `MediaSources` 中的 `Id` 和 `Container` 生成 `Videos|Audio/{ItemId}/stream.<container>?Static=true&MediaSourceId=...&DeviceId=...&api_key=...`。http/https 远程资源仍跳过本地文件存在性检查，直接交给 mpv 或外部播放器。
- 2026-05-27 最新补充：本轮继续处理内建屏音乐展开/收起卡顿和侧栏归位异常。收起路径不要在同一帧恢复 `NavigationSplitView` 侧栏和窗口 titlebar/toolbar；当前做法是播放器先回到底栏，沉浸 chrome 保持时无动画恢复侧栏，约一帧后再恢复主窗口 chrome，避免侧栏玻璃从 titlebar 下方重挂载时出现视觉下沉。
- 2026-05-27 最新补充：音乐队列弹层已改为虚拟化 `List`，保留行右键、拖拽排序、点击播放、移出和存入歌单。后续不要恢复 `ScrollView + LazyVStack`，否则长队列滚动后会重新累计历史行并拉高弹层内 hover/图片/按钮合成成本。
- 2026-05-27 最新补充：`FloatingLyricsGlass` 不再叠两套 hover 采样；同一次 pointer 位置驱动卡片柔光和内部按钮边缘光。音乐播放器内新增玻璃表面时优先复用这个单采样思路，避免在同一张卡片上同时挂 `onContinuousHover` 和 `pointerLiquidLight`。
- 2026-05-27 最新补充：通用 `LiquidGlassButtonStyle` 的 material/蓝色填充现在先裁进圆角形状，再绘制高光、描边和阴影，解决浅色页面上按钮底部出现方形色块的问题；强调按钮蓝色进一步加深，保证白字可读。媒体源页头紧凑布局下操作区右对齐，媒体源行右侧控件用固定宽度控制组贴右。
- 2026-05-27 最新补充：音乐展开页通过 AppKit 层隐藏导航标题和侧栏展开按钮，同时保留 macOS 红黄绿系统按钮；不要再使用 SwiftUI `.toolbar(.hidden, for: .windowToolbar)`，也不要直接切 `NSToolbar.isVisible`，前者会把系统按钮一起隐藏，后者会触发分栏 safe area 约束风险。
- 2026-05-27 最新补充：本轮确认内建屏音乐展开过程卡顿不是显式 30fps 限帧，而是根视图订阅播放进度、窗口 chrome 守卫反复写 `NSWindow`、侧栏重排和播放器 overlay 插入同帧叠加造成的合成峰值。当前 `ContentView` 只用 `@State` 持有 `MpvPlayerController`，由底栏/展开页/`MusicPlaybackHost` 自己观察；`MainWindowToolbarVisibilityGuard` 只在隐藏状态变化时写窗口属性，避免播放进度刷新期间反复触碰 toolbar/titlebar/styleMask。
- 2026-05-27 最新补充：音乐展开转场改为拆帧路径：先无动画切换 `fullSizeContentView`、透明 titlebar，并保持 toolbar safe area 稳定，约一帧后插入播放器 overlay，overlay 转场结束后再在遮罩下无动画收起侧栏；收起时先淡出播放器，再恢复侧栏和 chrome。这样保留可见展开动画，但不再让 `NavigationSplitView`、窗口 chrome 和全屏播放器创建同帧抢 WindowServer。
- 2026-05-27 最新补充：媒体源页头按钮靠右问题来自 `PageHeader` 标题区未给操作区让出稳定右对齐空间；现在标题区可压缩、操作区固定右侧，媒体源行补齐最大宽度。音乐展开顶部白色横条通过 AppKit 层透明 titlebar/full-size content 修复。
- 2026-05-27 最新补充：音乐专辑页和艺术家页已跟歌曲列表一样进入虚拟化路径。专辑页仍显示网格卡片，但由 `List` 行承载多个卡片列；艺术家页直接使用虚拟化 `List`。后续不要恢复逐批增长的 `LazyVStack`，那会在长滚动后累积历史视图。
- 2026-05-27 最新补充：底部迷你播放器的常驻进度条从原生 `Slider` 改为轻量 SwiftUI 绘制/拖动控件，减少设置页叠着底栏时的 AppKit slider 热更新和合成压力；视觉仍保留蓝色进度和圆形拖动点。视频窗口宽度设置上限调整为屏幕可用宽度 100%。

- 本轮继续处理用户反馈的内建屏动画掉帧、音乐展开顶栏残留、视频窗口开场跳动和长列表内存释放：复查后未发现全局 30fps 限帧或 DisplayLink 限帧；实际低频点主要是音乐展开背景曾固定 10fps、音乐播放进度 0.18s 发布一次，以及底部音乐栏 balanced pointer 采样 45Hz。当前 `GlassPerformanceMode.full/balanced` 都使用 60Hz pointer 时间阈值，balanced 仅降低强度、位移阈值和倾斜/阴影成本；音乐展开背景改用 60Hz 本地平滑播放时钟，避免专辑色律动被进度发布频率拖成阶梯。
- 音乐展开页现在只通过 `MainWindowToolbarVisibilityGuard` 的 AppKit 路径隐藏标题和侧边栏按钮，保留 macOS 红黄绿按钮，并保持主窗口 toolbar 结构稳定。不要再使用 SwiftUI `.toolbar(.hidden, for: .windowToolbar)`，它会把系统红黄绿一起隐藏；也不要直接切 `NSToolbar.isVisible`。
- 视频窗口创建时先用目标屏幕 `visibleFrame` 计算居中的 content rect，再显示窗口；真实视频比例首轮校正不使用 frame 动画，避免窗口看起来从其他位置打开后被拖到中心。视频控制条去掉显隐 scale，`PlayerWindowChromeVisibility` 只在可见性变化时动画，`PlayerControlsAutoHideCoordinator` 对鼠标移动重排隐藏任务做节流，减少控制层显示/隐藏瞬间卡视频帧。
- 音乐专辑和艺术家长列表继续使用虚拟化列表；视频海报墙已升级为分块瀑布流列表。`LocalPosterImage` 离屏 2.5 秒后释放视图持有的 `NSImage`，再次出现优先从 `ArtworkImageCache` 的下采样缓存取回，降低大库长时间浏览后的视图常驻内存。`PageHeader` 当前为标题左侧、操作区右侧并下边界对齐。
- 本轮按用户“视觉效果不降级”的性能要求继续收口：没有删除 blur、shadow、material、hover、transition 或玻璃动效，而是把 `LibraryView` / `MusicLibraryView` 的搜索、筛选、排序、分区切换快照构建从 MainActor 挪到后台 `Task.detached`，主线程只显示现有 `AppLoadingView` 骨架并在 key 校验通过后一次性写回。后续不要把全量 filter/sort/group/row model 生成放回 SwiftUI `body` 或 MainActor 热路径。
- 本轮把音乐歌曲列表和歌单歌曲明细提级为 P0 性能路径：`MusicSongListView` / `MusicPlaylistTrackListView` 改用原生虚拟化 `List`，避免 `LazyVStack` 分批增长后历史行长期留在 SwiftUI 树里；保留厚玻璃列表容器、行 hover 高光、左侧光带、封面微缩放和按钮质感。歌曲标题和文件名展示会去掉常见音频后缀，行内元数据按钮使用固定居中圆形图标，系统默认行分隔线已隐藏。右侧首字母/字符索引已按视觉反馈撤回。
- 收藏页迁移到歌单页：`ContentView.MusicLibrarySection.sidebarCases` 隐藏 `.favorites`，旧 `music-favorites` 存储选择会打开 `.playlists`；`MusicLibraryView` 生成虚拟收藏歌单 `MediaLIB.synthetic.favoriteMusicPlaylist` 并置顶显示，不允许重命名/删除/再次存入歌单，移出歌曲时走 `toggleFavorite`。
- 视频 AirPlay 的原生 route picker 触发链路已增强：`AirPlayRoutePickerSession.presentRoutesWhenReady` 会激活窗口、查找内部 `NSButton` 并短延迟重试，视频代理播放器外部播放观察改为 `.initial/.new`。macOS 仍不支持 `prioritizesVideoDevices`，后续调试 AirPlay 应继续围绕 AVPlayer 路由代理和系统 route picker 行为，不要恢复透明原生控件覆盖命中。
- `AppState` 新增 `ScanProgressThrottler`，扫描大目录时按时间和进度步进发布 UI 进度，保留首尾、错误和关键状态，但不再每个文件都创建 MainActor 任务。歌单总览改为一次性建立音乐 ID 查表，数据库新增常用索引并将批量清除播放记录合并为 chunked `IN` 更新，目标是降低启动、页面切换、扫描、歌单页和清记录路径的 CPU/主线程压力。
- 本轮按 `Codex_macOS26_华丽动效_UI重构指令.docx` 重新做 UI/UX 与性能分析：普通页面架构仍是 `ContentView` + `NavigationSplitView` + 页面级 `ScrollView`，共用组件集中在 `AppColors.swift`；重复点主要是页面滚动骨架、筛选条、返回顶部按钮和不同页面自己的 hover 状态；性能风险主要是底部音乐栏存在时下层页面仍可能持续响应 pointer 光效/封面倾斜，以及视频/音乐快照 miss 时切页直接空白或短暂复用上一页内容。
- 新增 `DesignSystemTokens.swift`，目前先承载 `AppSpacing`、`AppRadius`、`AppEffect` 和 `preferStaticGlassSurfaces` 环境开关，作为后续把超大 `AppColors.swift` 拆成真正 Design System 目录的第一步。不要把新 token 再散落回页面常量里。
- `ContentView` 在有音乐底部播放器时会给 `navigationRoot` 写入 `glassPerformanceMode(.balanced)`；下层普通页面继续显示白色厚玻璃、局部鼠标光和按钮边缘光，pointer 时间阈值仍对齐 60Hz，但会降低强度、增加位移阈值并减轻阴影和检视倾斜幅度。音乐展开覆盖时才切到 `.minimal` 并关闭下层命中测试。这样底部迷你播放器存在时不是直接禁用特效，而是减轻合成压力；底部迷你播放器自身不继承该降级。
- `LibraryView` / `MusicLibraryView` 新增轻量 `AppLoadingView` 骨架占位，并把切换分类、筛选、排序和 `libraryRevision` 的快照重算延后到下一轮主线程。目标快照未命中时不再显示上一分类内容，也不直接闪成“暂无”；异步任务写回前会校验当前 key，避免快速切页或搜索时旧结果晚到覆盖新页面。
- 视频海报墙已改为列表行承载的分块瀑布流，音乐歌曲、歌单歌曲明细、专辑页和艺术家页已改用原生虚拟化 `List`。专辑页仍保持网格卡片视觉，但由虚拟化列表按行承载卡片列，避免长滚动后累积历史视图。
- 首页统计、健康提示和扫描进度改为静态玻璃表面；它们仍保留统一白玻璃材质，但不再持续记录鼠标光源。首页标签栏、按钮和真实可交互控件仍走完整液态玻璃反馈。
- 设置页“元数据”区新增“音乐元数据获取”工作台，入口在 `SettingsView.metadataSettings`。它使用 `MusicTagScraperSheet.swift` 的白色厚玻璃弹层，支持按未匹配、全部音乐、缺少封面、收藏范围批量匹配 MusicBrainz / iTunes Search；结果先进入可编辑预览列表，可修改标题、艺术家、专辑、曲序、年份、歌词和封面路径，再选择性更新 MediaLIB 索引或写入音频文件。
- 本轮没有直接 vendoring `music-tag-web`：该 Web 项目存在 GPL/额外限制，不适合整包集成。当前实现只参考 MIT `music-tag` 的统一标签抽象思路，新增原生 `MusicTagDraft` / `MusicTagEditingService`，不引入 Python/Node 常驻运行时，避免包体和内存压力回升。
- `MusicTagEditingService.write` 只在用户显式打开“写入文件”后运行；默认只更新内部索引。写回通过 ffmpeg 复制音频流并写入文字标签，支持格式的封面会尝试作为 attached picture 嵌入；先生成同目录隐藏临时文件并校验大小后用 `FileManager.replaceItemAt` 替换原文件，失败保留原文件。远程 URL、不可写路径和不支持格式会逐条失败；封面嵌入失败时退回只写文字标签。
- `AppState.applyMetadata` 和 `applyMusicTagDraft` 改为调用 `updateMetadataInMemory` 增量刷新条目、当前队列、播放器条目、派生缓存和 `libraryRevision`，单首或批量标签应用不再每首触发整库 `reload()`。
- 本轮继续按 Apple 官方 SwiftUI/性能/弃用资料复核：`LazyVStack` 适合惰性创建滚动内容，Apple 对内存优化强调按需加载和降低图片内存；SwiftUI Material/HIG 的方向仍是用材质建立层级和可读性。OpenGL 相关构建警告来自 Apple 对 `NSOpenGLView`/`NSOpenGLContext` 的弃用和 Metal/MetalKit 推荐，但当前播放器依赖 libmpv render API + 应用内 OpenGL 视图，不应在未设计新渲染桥之前替换。
- `MusicSongListView` / `MusicPlaylistTrackListView` 当前使用 `List` 虚拟化，系统只保留可见行和缓冲行；不要恢复旧的初始挂载 260 / 追加 220 分批方案，那个方案虽降低首屏成本但滚到底仍会累计大量历史行。
- `MusicSongRow` 去掉行级实时 `pointerLiquidLight` 径向光源监听，改用固定高度绘制层、左侧光带、封面微缩放、描边和轻阴影，并新增 `AppMotion.listHover` 的更短非线性曲线。不要把逐行实时径向光源恢复到歌曲长列表热路径。
- `LibrarySnapshotCache` 和 `MusicLibrarySnapshotCache` 改为明确 LRU 淘汰，缓存命中会刷新访问顺序，满额时移除最久未使用项，避免用字典 `keys.first` 造成非预期快照淘汰。
- 最新收口继续降低内存：歌词存在性缓存、海报缺失缓存、海报宽高比缓存和专辑取色缓存都加入上限与访问顺序淘汰；视频/音乐快照缓存容量也更克制，目标是降低大库长时间浏览后的常驻内存。
- 最新视频 AirPlay 修复：macOS SDK 明确不支持 `AVRoutePickerView.prioritizesVideoDevices`，因此视频控制条改用视频 AirPlay 图标，继续绑定 AVPlayer 路由代理，并在路线选择结束后延长外部路线探测与同步窗口。
- 最新音乐展开光效调整：专辑色径向/斜向光源降低脉冲对比，增加渐变过渡点并扩大柔光范围，减少色彩断层和人眼干扰；仍保持低频拍点律动。
- 最新“音乐元数据获取”控制台调整：弹层最小尺寸降低，范围选择、搜索框和开关在窄窗口下会换行，避免弹窗宽度超过主窗口；设置页 TMDB API 输入框已按占位文案参与自适应宽度。
- `ArtworkImageCache.downsampledImage` 移除 ImageIO 失败后的 `NSImage(contentsOfFile:)` 原图兜底；`MetadataSearchService` 和 `ExternalPlayerService` 去掉 URL 强制解包，异常远程地址会走错误返回而不是崩溃。
- `TimedLyricLine.activeIndex` 改成二分查找，歌词行 `ForEach` 不再构造 `Array(timedLyrics.enumerated())`；默认音乐封面等高线改成静态常量，减少播放进度刷新和长列表大量默认封面时的微分配。
- 本轮针对用户反馈的海报 hover 漂移、音乐长列表 hover 慢半拍、歌词卡片浏览仍模糊、音乐分区切换加载感和音乐展开页缩放拉长继续收口。设计依据参考 Apple HIG 中“材质用于建立前景/背景层级、厚材质提供更好对比、颜色/材质需保证文字和控件可读、动效应表达状态并尊重 Reduce Motion”的原则。
- 普通页面光源从偏饱和米黄色调回低饱和象牙白/珍珠冷白，卡片白色填充和冷灰边缘更明确；`SidebarGlassBackground` 降低冷蓝和白色 wash 不透明度，更依赖 `ultraThinMaterial` 透出模糊桌面背景。不要把主界面光源改回高饱和黄/蓝/水色光斑。
- `PointerInspectTiltModifier` 不再对外层命中视图做 scale，只保留封面区域 3D 检视、方向高光和轻阴影；`PosterCardView` 也移除了整卡 scale，避免 hover 命中区域改变导致 enter/exit 抖动和海报“飞走”。
- `MusicSongRow` 固定 58pt 高度，移除整行 scale/offset，上浮感改为绘制层高光、左侧光带、封面微缩放和轻阴影；歌曲长列表通过 `List` 虚拟化可见行，不显示加载占位，滚动期间继续抑制 hover/光效。
- `MusicLibraryView` 分区切换时会优先读取目标 section 的快照缓存，避免 `visibleContentSectionID` 不一致时立即返回空数组导致“暂无/加载”闪烁；快照仍按 section、搜索、排序、筛选、libraryRevision 和歌词缓存版本归属。
- 本轮新增用户歌单闭环：数据库新增 `music_playlists` / `music_playlist_items`，`MusicPlaylistRepository` 按歌单更新时间读取和追加歌曲，`AppState.musicPlaylists` 负责内存同步；歌曲、专辑、艺术家、分组列表和播放器队列都可以存入新建或已有歌单，添加歌单不会 bump `libraryRevision`，避免音乐页面被整库刷新打断。
- 本轮继续处理长列表性能：音乐歌曲行 hover 改为接近媒体源行的固定高度选中层、左侧光带和封面微缩放；音乐歌曲、专辑、艺术家走虚拟化列表，视频海报墙走分块瀑布流列表，设置页主体改为惰性堆叠，滚动期间延长 hover 抑制窗口以覆盖触控板惯性。
- `MusicPlayerView` 歌词区域新增局部 scroll wheel 监视器，滚轮/触控板滚动和拖拽都会调用 `pauseLyricAutoScroll()`，浏览态临时取消远离歌词 blur；只有当前歌词行接收播放时间用于逐字/分词高亮，非当前行保持静态，降低歌词面板播放中重算。
- 音乐展开页堆叠布局歌词卡片改为 `MusicExpandedLayout.stackedLyricsHeight` 限制在窗口内，左右控制行移除 340pt 固定最小宽度，`availableHeight` 不再强制 420pt，降低缩放播放器时把主窗口错误拉长的概率。
- `ContentView` 的音乐展开/收起侧栏联动改为 `AppMotion.sidebar` 分阶段执行：展开时先收起侧栏，约 170ms 后铺开播放器；收起时播放器先回到底栏，约 300ms 后恢复侧栏，避免侧栏重排和播放器大层转场同帧抢主线程。

- 针对用户最新反馈的音乐展开掉帧、底部音乐栏导致列表滚动掉帧、单视频海报比例跳变和 WindowServer 合成压力，本轮做了可执行性能收口：音乐展开转场改为 `AppMotion.musicPlayerExpansion` 的透明度过渡，`ContentView` 在侧栏收起后延迟约 130ms 再铺开播放器；音乐展开背景移除全屏 blur/compositing group，改为厚实不透视的专辑色实底色板叠加更大范围柔和径向/斜向渐变；展开态 `navigationRoot` 会关闭命中测试并写入 hover 抑制环境，避免被遮住的下层列表、海报和按钮继续响应鼠标动作；底部迷你播放器保留白色厚玻璃、静态裁剪专辑柔光和按钮边缘光，但不再恢复整条底栏的实时鼠标径向光。
- 普通页面左上光源已改成更浅、更宽的浅米白/象牙白环境光，模拟屏幕外左上且靠近用户的位置斜向照入。后续不要把它改回局部深蓝、水色或高饱和光斑；卡片和按钮应被照亮得更偏白，只保留克制的暖白边缘轮廓。
- 通用强调按钮、保险库解锁按钮和获取类按钮的蓝色玻璃层已加深，解决浅色玻璃界面下文字发白不可读的问题；后续新增强调按钮不要使用过浅填充。
- `ArtworkMetrics.aspectRatio(for:)` 现在接受 `MediaItem`，会在生成视频帧、默认封面或无正式海报路径时使用 `MediaItem.resolution` 推导横版比例，避免单视频初始显示 2:3 后 hover/加载再切成 16:9。正式电影海报仍按 2:3，剧集兜底仍按 16:9。
- `MusicLibraryView` 新增 `MusicCollectionDrilldown` / `MusicCollectionTrackList`：点击专辑卡片、艺术家行或歌单卡片可查看分组歌曲；卡片/行右键有“查看歌曲”“播放”和“存入歌单”。`AppState.replaceMusicQueueAndPlay` 会用分组内可播放歌曲替换当前队列并从目标歌曲开始，避免把专辑/艺术家/歌单播放追加到旧队列后面。
- `PlayerView` 中音乐 UI 进度刷新间隔已降到约 0.18s，暂停态会抑制 0.25s 内的细小 currentTime 抖动，避免歌词/底栏在暂停或列表滚动时被无意义刷新牵动。
- 本轮继续按 `Codex_macOS26_华丽动效_UI重构指令.docx` 做 UI/UX 与性能巡检，结论是当前普通页面设计系统已经集中在 `AppColors.swift`，主要重复点集中在音乐歌曲列表自绘玻璃容器、设置页局部系统控件和打包依赖链；主要性能风险是本地海报原图级 `NSImage` 缓存、长列表多层 material/blur/shadow、滚动时 hover/tilt 高频状态更新，以及 Homebrew `Python.framework` 被完整复制进 App 包。
- 本轮没有重写音乐展开页布局；除音乐展开页外，继续保留左上柔和象牙白环境光、组件染色和边缘轮廓光。视频/剧集封面检视与 hover 放大继续保留；音乐歌曲行 hover 已加强为当前行轻微放大、上浮、封面缩放、象牙白高光和描边，但音乐列表容器仍走通用轻量 `LiquidGlassSurfaceLayer`，行级 hover 动画只作用当前行，滚动期间会被抑制以减少整列合成压力。
- `ArtworkImageCache` 已改为按显示尺寸通过 ImageIO 下采样后缓存，缓存上限从 160MB 收紧到 72MB；`LocalPosterImage` 会把目标显示尺寸传给缓存。后续不要恢复 `NSImage(contentsOfFile:)` 原图级缓存，也不要在海报卡片 `body` 中同步读取图片宽高。
- 设置页“缺失封面处理”已从系统 segmented picker 改为 `GlassCapsuleControl`，首页选项卡设置项也复用静态通用玻璃选中态；后续新增设置项选择控件时优先复用胶囊/菜单/静态玻璃，不要回到系统 segmented 外观。
- `scripts/package_dmg.sh` 新增 Homebrew 框架瘦身逻辑：如果间接依赖复制了 `Python.framework`，只保留动态加载需要的框架二进制和资源骨架，剔除 stdlib、tests、docs、headers、bin/include/lib/share 等目录，避免 VapourSynth/Python 链路把无用内容和潜在加载压力塞进 `MediaLIB.app`。元数据清理会同时处理符号链接自身的扩展属性；源 bundle `/private/tmp/MediaLib-package/MediaLIB.app` 是严格签名校验对象，`dist` 副本可能被 Documents/FileProvider 重新写入 `com.apple.provenance`。
- 本轮按 `Codex_macOS26_华丽动效_UI重构指令.docx` 做了第一阶段小步 UI 收口，没有重写页面结构，也没有改音乐展开页布局；普通页面继续复用 `AppColors.swift` 中已有 Design System。
- 本轮追加了性能向收口：普通页面太阳光已收敛为低饱和象牙白/珍珠冷白，`LiquidGlassSurfaceLayer` 增加轻量静态渲染模式，`staticSurfaceBackground` 用于长列表/海报/设置分组时不再叠系统 material、blur、多层重阴影或连续 hover 光源。
- 音乐歌曲行的 hover 反馈保留小幅放大、白色高光和描边，但移除了逐行动态液态光源、重阴影和行内按钮的常驻 material；视频/剧集封面检视仍保留，空闲状态不再给每张封面维持阴影。
- 底部音乐迷你播放器保留专用透明白色厚玻璃表面，内容增加内部左右安全边距，修复专辑封面左侧被底栏圆角裁掉的问题；底栏专辑色柔光改为静态裁剪层，避免跟随播放进度或鼠标位置重绘整条底栏。
- 最新修复：`MusicMiniPlayerBar` 的纵向 padding 已移入底栏圆角玻璃裁剪层，静态专辑色柔光和实际 72pt 底栏高度对齐；不要再把底栏内容 padding 放回裁剪层外，否则光效会再次小于底栏本体。
- 最新修复：`AppColors.swift` 新增 `PointerScrollActivityMonitor` 和 `suppressHoverEffectsDuringScroll()`，滚轮/触控板滑动期间会向环境写入 `suppressPointerHoverDuringScroll`，并让 `pointerLiquidLight`、`pointerLiquidEdge`、`pointerInspectTilt`、`PosterCardView`、`MusicSongRow` 等临时清空 hover 状态；停止滑动后自动恢复完整 hover 特效。
- 最新修复：音乐 AirPlay 已取消本机同播双播放器路径，主音乐 `AVPlayer` 始终允许系统外部播放，`audioRouteProxyPlayer` / 本机镜像路径不再由设置项创建；保留旧设置字段只用于解码兼容。
- `LocalPosterImage` 不再在每个加载任务中调用 `ArtworkImageCache.invalidateMissing(path:)`，避免滚动时把短时缺失缓存清空后反复同步检查文件系统；媒体库 reload 仍会统一清理缺失缓存。
- 除音乐展开页外，`AppPageBackground`、`LiquidGlassSurfaceLayer`、`LiquidGlassButtonStyle`、`GlassCapsuleControl`、`GlassSearchField` 和 `GlassMenuButton` 都加入更明确的左上柔和象牙白太阳光染色、高光和边缘轮廓光，让首页、媒体库、设置、来源、详情和弹层共享同一套白色厚玻璃语言。
- `staticSurfaceBackground` 现在会调用不响应 pointer 的 `LiquidGlassSurfaceLayer`，长列表、海报卡片、设置分组等静态表面保留象牙白染色和边缘光，但不再附带连续 hover 监听；需要卡片内鼠标光源的控件继续使用 `surfaceBackground`。当音乐展开页覆盖主界面时，`ContentView` 会向下层写入 hover 抑制环境并关闭命中测试。
- `pointerLiquidLight`、`pointerLiquidEdge`、`pointerInspectTilt`、按钮按压缩放、胶囊切换动画、视频/剧集海报卡片 hover 放大和音乐歌曲行 hover 放大接入 `accessibilityReduceMotion` 降级；普通状态下保留剧集/视频封面检视和音乐列表 hover 轻微放大。
- 新增 `glassFormField` 通用表单输入修饰器，保险库 PIN、设置输入框、Emby 登录、网络设备登录和元数据搜索弹窗都改用同一套暖白玻璃输入样式。
- 元数据搜索结果从默认 `List` 改成自绘 `MetadataResultCard`，网络设备分类从系统 segmented picker 改成 `GlassCapsuleControl` 网格；首页空库提示、快速预览底部条和媒体源分类选项也统一到静态厚玻璃表面。
- 底部音乐迷你播放器使用克制白色厚玻璃材质，专辑色发光层被裁剪在底栏圆角内部并保持静态；右侧队列、AirPlay、收藏、音量和关闭按钮会按距离获得由近到远递减的封面色轮廓光，AirPlay 保持固定深蓝色。
- 音乐扫描器现在显式排除歌词、字幕、本地图片、`.cue`、`.nfo` 等旁路元数据文件，只导入规范化后的普通媒体文件并按规范化路径去重；音乐导入前会删除同一 `file_path` 的旧重复行，解决同一个物理歌曲文件扫描出多条的问题。
- 歌词手动浏览时不再把远离当前行的歌词模糊掉，只保留透明度层级；点击带时间戳歌词行会直接 seek 到对应时间点。
- 音乐歌曲列表恢复更厚的液态玻璃容器、高光描边和柔和阴影，但仍通过预计算 `MusicTrackRowModel`、hover 节流和只点亮当前 hover 行来控制滚动成本。
- 视频播放器的 `MpvOpenGLView` 初始化增加像素格式失败兜底，避免极端 OpenGL 环境下因为 `pixelFormat` nil 直接崩溃；仍然保持 libmpv render API + 应用内 OpenGL 视图架构。
- 本轮新增 `MediaLIB_系统概要设计.docx`、`MediaLIB_详细设计.docx` 和 `scripts/generate_design_docs.py`；Documents 渲染器因沙盒外执行额度限制没有完成 PNG 视觉 QA，但已完成 DOCX 可读性和表格几何结构检查。

## 1.2 2026-05-24 补充

- 音乐展开页控制栏已按最新顺序拆成两行：第一行为喜欢、弹性进度、队列，第二行为隔空播放、音量、上一首、播放/暂停、下一首、随机播放、单个循环模式按钮；展开页不再显示快退/快进 15 秒按钮，两行首尾按钮通过等分 spacer 对齐。`MusicExpandedLayout` 现在用同一组左右边距约束收起按钮、左侧控制区和右侧歌词卡片；收起按钮顶部与歌词卡片顶部对齐，歌词卡片保留最小宽度，但窗口较小时会优先保证左侧控制栏宽度。AirPlay 按钮固定深蓝，不跟随专辑封面取色。
- 底部音乐迷你播放器增加防溢出布局：外层由 `ContentView` 保证左右 24pt 安全边距，内部已彻底移除快退/快进 15 秒按钮，循环模式位于随机左侧，队列按钮位于 AirPlay 左侧，曲目信息区域在窄宽度下只保留封面；底栏主体改为静态白色玻璃，专辑色只用于按钮和边缘光。
- 展开页播放/暂停按钮已复用底部迷你播放器的蓝色胶囊主按钮样式；底部迷你播放器内部新增裁剪在底栏内的专辑色柔光层，从封面侧向右衰减，不会溢出到底栏外。
- AirPlay 控件改为 SwiftUI 可见按钮触发隐藏的原生 `AVRoutePickerView`，不再依赖透明原生命中层；点击前会主动准备路线选择，底栏和展开页都使用这一触发模型。
- 收藏状态改为乐观更新，先同步当前播放条目、列表和队列内存状态，再后台写入数据库，失败时回滚；避免点击收藏时主线程等待数据库写入。
- 音乐歌曲列表恢复 hover 玻璃动效、描边、阴影和轻微缩放；光效仍通过 `PointerHoverThrottle` 节流。
- `PointerHoverThrottle` 当前为通用液态玻璃、按钮边缘光、检视倾斜和音乐歌词/控制玻璃提供 60Hz 时间阈值；历史版本曾为 30fps/3pt，内建 60Hz 屏幕上会显得明显卡顿，不要再恢复。设置分组、海报卡片、音乐专辑/艺术家卡片和底栏主体优先走轻量玻璃层，减少滑动和播放器动画时的高频重绘。
- AirPlay 路由入口现在由 `MpvPlayerController.routePickerSession` 持久持有最近绑定的 `AVPlayer`；每个可见控制都会保留隐藏的原生 `AVRoutePickerView`，但点击由 SwiftUI 按钮主动触发 activation，避免透明 NSView 覆盖命中失败。音乐播放遵循系统 AVPlayer 外部路线逻辑，不再创建本机同步镜像；路由面板关闭后仍会延长外部播放状态探测。视频播放器为当前视频准备 AVPlayer 路由代理，路线选择开始和结束时都会尝试同步外部播放。
- 音乐歌曲/专辑页顶部筛选条和首页横向标签栏改为与视频页一致的 `GlassCapsuleControl` 小胶囊玻璃按钮，专辑封面也接入 `pointerInspectTilt` 检视效果；设置页内 TextField/SecureField 输入文字统一居中，输入框会按文本长度弹性收窄/展开。
- 通用玻璃层已增加“卡片内鼠标光源上下文”：`SurfaceBackground` 会记录鼠标全局位置并传给内部按钮，`pointerLiquidEdge` 根据按钮与鼠标的距离和方向只点亮靠近鼠标的一侧边缘。默认卡片、按钮、搜索框、菜单和首页/设置/来源选择控件的厚度已上调，主界面叠加了从左上角射入的浅米白/象牙白环境光，侧栏冷蓝玻璃改为向下渐白。
- 音乐展开页和底部迷你播放器已接入专辑色光源：封面外扩柔光照亮周围控件，歌词卡片、控制栏、收起按钮、音量/队列弹层和底栏都会把专辑主色传给附近按钮边缘。展开页歌词卡片适度收窄，左侧控制区略向右移，收起按钮保持 18pt 等距悬浮。
- 音乐播放器保留“我喜欢”按钮：展开页第一行位于进度条左侧，底部条位于 AirPlay 与音量之间；`AppState.toggleFavorite` 现在先更新 `items`、`musicQueue`、`activePlayerItem`、`selectedItem`、`quickPreviewItem` 和派生缓存中的收藏位，再后台写数据库，避免点击收藏时等待整库 reload 或同步落库。`AirPlayRoutePickerSession` 会缓存最近的 `AVPlayer`，减少展开/收起时路由状态丢失。
- 视频封面检视效果已从海报墙扩展到详情页主封面和剧集行封面；`pointerInspectTilt` 仍只作用于封面区域，不会把标题/元信息一起倾斜。
- 视频侧栏已把独立“最近播放”迁移为“正在观看”：`SidebarDestination.init(storedID:)` 会把旧 `video-recent` 指到 `.video(.watching)`，该页从所有非音乐、非保险库条目中汇总 `hasPlaybackTrace` 并提供一键清除记录。海报右键新增手动标记已观看/未观看和收藏/取消收藏。
- 鼠标液态玻璃光效已拆成卡片背景光效和按钮边缘光：`SurfaceBackground` 只把 `LiquidGlassSurfaceLayer` 放在背景层，按钮统一走 `LiquidGlassButtonStyle` / `pointerLiquidEdge`，设置页分组复用通用卡片材质，视频库筛选改为小胶囊玻璃按钮。
- 视频宽度设置改为屏幕可用宽度百分比：`VideoWindowSizing` 提供 ratio/width 转换，设置页显示 45% 到 100% 的百分比，实际播放器仍保存目标点宽并按目标屏幕可用区域收敛。
- 歌词卡片在存在歌词时隐藏获取按钮；定时歌词用顶部/底部占位让第一行从中心出现，当前行滚动锚点保持 `.center`，远离当前行的歌词通过 opacity 和 blur 渐隐到玻璃里。
- 音乐展开页切歌取色已改为任务级校验：`MusicPlayerView` 会取消上一轮 `paletteLoadTask`，先清掉旧色，再只允许当前歌曲 ID 的取色结果写回，避免上一首封面色慢一拍覆盖当前界面。
- 音乐歌词卡片、控制栏、收起按钮、弹层和封面 hover 光效都复用专辑色液态玻璃；全局 `pointerLiquidLight` 默认光效已调低蓝色饱和度。音乐歌曲行使用轻量玻璃 hover、局部光源和小幅放大；视频/电视剧海报通过 `pointerInspectTilt` 做封面区域的检视倾斜。
- 音乐随机播放与循环模式已拆分：`AppState.musicShuffleEnabled` 控制随机，`AppState.musicRepeatMode` 控制顺序播放/队列循环/单曲循环；展开页第一行放喜欢、弹性进度和队列，第二行放 AirPlay、音量、上一首、播放/暂停、下一首、随机和单个循环模式按钮。AirPlay 按钮固定使用深蓝玻璃色，不随专辑封面取色。
- 新增 `AirPlayRoutePickerButton.swift` 封装 AVKit 隔空播放入口，音乐路由绑定当前 `AVPlayer`；视频控制栏也提供同一系统路由入口。新增 `SystemMediaIntegration.swift` 注册 macOS 系统媒体键/Now Playing 基础信息，App 菜单栏新增“播放”菜单。

## 2. 当前技术栈

- 语言：Swift 5.9
- UI：SwiftUI + 少量 AppKit bridge
- 播放：视频使用 SwiftUI 独立窗口 + 随 App 分发的 libmpv 核心，并通过 libmpv render API 渲染到应用内 OpenGL 视图；音乐使用 AVFoundation 音频后端；AVFoundation 仍用于音频标签读取和缩略图生成
- 数据库：SQLite3 C API，封装在 `DatabaseManager`
- 本地缓存/文件目录：Application Support、Caches
- 打包：SwiftPM release build + 手工生成 `.app` bundle + `hdiutil` 生成 DMG
- 图标：`scripts/generate_icon.swift` 使用用户提供的 `AppIconSource.jpg` 裁掉外侧拍摄边框后生成 `AppIcon.png`、`AppIconDark.png`、iconset 和 `.icns`
- 保险库密码：Application Support 凭据文件保存 PIN 哈希 + LocalAuthentication Touch ID / 设备认证
- 元数据：
  - 视频：TMDB 搜索入口，用户提供 API Key 或 Read Access Token
  - 音乐：MusicBrainz / iTunes Search 搜索入口
  - Emby：账号登录后通过 Emby API 同步 Movie/Series/Episode/Audio

## 3. 当前目录结构说明

```text
.
├── Package.swift
├── AGENTS.md
├── README.md
├── ROADMAP.md
├── CHANGELOG.md
├── 用户使用说明.md
├── 开发说明.md
├── handoff.md
├── scripts/
│   ├── generate_icon.swift       # 从用户源图生成 AppIcon PNG/Dark PNG/iconset/icns
│   └── package_dmg.sh            # 构建 app、签名、生成 dmg
├── Sources/
│   ├── MediaLib/                 # macOS App 层
│   │   ├── App/
│   │   │   ├── AppState.swift
│   │   │   ├── LibMpvClient.swift
│   │   │   ├── MediaLibApp.swift
│   │   │   ├── SystemMediaIntegration.swift
│   │   │   ├── MetadataSearchService.swift
│   │   │   ├── EmbyService.swift
│   │   │   ├── RemoteCredentialStore.swift
│   │   │   └── PrivacyLockService.swift
│   │   ├── Resources/
│   │   │   ├── AppIconSource.jpg
│   │   │   ├── AppIcon.png
│   │   │   ├── AppIconDark.png
│   │   │   └── AppIcon.icns
│   │   └── Views/
│   │       ├── ContentView.swift
│   │       ├── AirPlayRoutePickerButton.swift
│   │       ├── HomeView.swift
│   │       ├── LibraryView.swift
│   │       ├── MusicLibraryView.swift
│   │       ├── MusicPlayerView.swift
│   │       ├── PlayerView.swift
│   │       ├── PosterGridView.swift
│   │       ├── DetailView.swift
│   │       ├── SettingsView.swift
│   │       ├── SourcesView.swift
│   │       ├── PrivacyLockView.swift
│   │       ├── QuickPreviewView.swift
│   │       ├── EpisodeListView.swift
│   │       ├── EmptyStateView.swift
│   │       ├── KeyCaptureView.swift
│   │       └── AppColors.swift
│   ├── MediaLibCore/             # 可复用核心层
│   │   ├── Database/
│   │   │   ├── DatabaseManager.swift
│   │   │   ├── MediaRepository.swift
│   │   │   ├── SourceRepository.swift
│   │   │   ├── SQLiteValue.swift
│   │   │   └── DatabaseError.swift
│   │   ├── Models/
│   │   │   ├── AppSettings.swift
│   │   │   ├── MediaItem.swift
│   │   │   ├── MediaSource.swift
│   │   │   ├── MediaType.swift
│   │   │   └── ParsedMediaFile.swift
│   │   ├── Services/
│   │   │   ├── MediaScanner.swift
│   │   │   ├── AudioMetadataReader.swift
│   │   │   ├── FilenameParser.swift
│   │   │   ├── LocalMetadataService.swift
│   │   │   ├── ThumbnailGenerator.swift
│   │   │   ├── ExternalPlayerService.swift
│   │   │   ├── FileAccessService.swift
│   │   │   ├── AppSettingsStore.swift
│   │   │   └── LoggingService.swift
│   │   └── Utilities/
│   │       ├── DateCoding.swift
│   │       └── StableID.swift
│   └── MediaLibChecks/
│       └── main.swift            # 轻量项目健康检查
├── Tests/
└── dist/
    ├── MediaLIB.app              # 复制到 dist 的 app
    ├── MediaLib.dmg              # 最终 DMG
    └── icons/
```

## 4. 已实现功能

### 最新状态摘要

- 本轮将软件显示名更新为 `MediaLIB`，主界面标题、App Bundle 显示名、Emby 客户端名、联网 User-Agent 和用户可见提示同步改名；内部 bundle id、数据库目录和 UserDefaults key 保持兼容，不迁移用户数据目录。
- 本轮修复网络设备断开重连后封面长期停留默认图的问题：`ArtworkImageCache` 的缺失路径缓存会在媒体库刷新和本地海报重试时失效，扫描入口改用实时目录可达性判断，避免旧离线缓存阻止重连后的分类扫描。
- 本轮增加鼠标光源液态玻璃：`SurfaceBackground`、`SettingsGlassCard` 和 `GlassMenuButton` 接入局部 hover 光源，根据鼠标位置动态改变高光方向、描边和明暗。
- 本轮增加自动扫描设置：`AppSettings.automaticScanInterval` 支持关闭、15 分钟、每小时、每 6 小时、每天，`AppState` 定时扫描已添加且当前可访问的非 Emby 路径。
- 本轮把视频窗口宽度设置改为百分比：`VideoWindowSizing` 在设置页把保存的目标点宽转换为当前屏幕可用宽度比例，限制在 45% 到 100%，播放器打开时按目标屏幕可用区域和视频比例等比收敛。
- 本轮为 MKV 截帧封面增加 ffmpeg 兜底：AVFoundation 截帧失败后调用 App 包内或系统路径的 `ffmpeg` 输出 JPG；`scripts/package_dmg.sh` 会在本机存在 Homebrew `ffmpeg` 时把可执行文件和依赖复制进 App。
- 本轮重绘 App LOGO：保留白色圆角底、彩色叠层卡片、蓝色播放卡、胶片孔和播放三角，去掉水波纹和音乐符号；`scripts/generate_icon.swift` 现在直接绘制浅色/深色图标和 ICNS。
- 本轮统一全局动画和页面材质：`AppMotion` 改为更慢的非线性 timing curve，通用页面卡片/选项栏/设置分组/侧栏收敛到同一套白色玻璃材质；音乐展开播放器继续保留专辑色沉浸层。
- 本轮更新分类扫描：首页当前分类、视频分类页、音乐页和 EMBY 页的扫描按钮只扫描当前分类对应的媒体源，媒体源页“扫描全部”仍是全量入口；自动识别源仍建议从媒体源页全量扫描。
- 本轮修复音乐功能页面内容错位：`MusicLibraryView` 切换歌曲/专辑/艺术家/歌单/最近播放等分区时显式按新 section 刷新，并用 `visibleContentSectionID` 防止旧快照继续显示在新标题下。
- 本轮重点优化音乐播放器展开/关闭动画和音乐列表滚动掉帧：`ContentView` 不再让整屏播放器表面、封面和标题做 matched geometry，也不再把侧栏收起/恢复动画和播放器整屏转场叠在同一帧；展开/收起改为底部位移加透明度的短时动画。
- `AlbumGlassBackdrop` 和 `AlbumNearFieldIlluminationLayer` 始终保持静态专辑光，不再根据音乐播放、暂停、播放时间或音频能量启动背景律动，也不会创建周期性 `TimelineView` 刷新整页背景。
- 音乐底部迷你播放器外层不再观察播放器控制器，进度、播放控制和音量拆到小组件内；音乐 UI 进度刷新从 30fps 逐步降到约 8fps，并避免重复发布未变化的 `duration` / `isPlaying`。
- 音乐歌曲列表容器改为轻量静态填充和描边，去掉超长列表外层的大面积材质、裁剪和阴影；默认音乐封面在行内直接绘制小型蓝青图标，继续降低音乐列表上下滑动时的合成压力。
- 本轮继续做 UI/性能巡检：修复首页选项栏按数量强制双行的问题，`HomeTabBar` 现在先按实际可用宽度尝试单行，只有放不下时才进入可横向拖动的双行布局。
- 文件系统可访问性检查进一步移出主线程热路径：`AppState.reload()` 不再同步检查缺失文件和离线媒体源，而是启动后台 file health 任务，完成后回写缺失文件、离线源缓存并递增 `libraryRevision`；媒体源列表使用缓存可达性，不再每行渲染时同步 `source.exists`。
- 音乐列表歌词状态改为后台暖缓存：`MusicLyricsPresenceCache` 会异步检查同名 `.lrc` / `.txt` 并用缓存版本参与音乐快照 key，歌曲行和“有歌词”筛选不再在快照生成或滚动路径逐首访问文件系统。
- 音乐播放页打开时，同名歌词侧车文件读取改到 utility 后台任务；剧集列表也不再在 row `body` 中调用 `MediaItem.isPlayable` 做同步文件存在性检查。
- 媒体源行旧的右侧分类 `GlassMenuButton` 已被每行设置按钮取代；分类、服务器库、参与检查和痕迹同步都在设置弹窗里编辑，来源列表右侧只保留图标按钮，减少长来源名和多选项同时挤压。
- 本轮最新重点处理视频播放器彻底回到应用内 libmpv render API、液态玻璃播放界面、双窗口/Dock 额外图标、“视频窗口宽度”设置不生效，以及透明标题栏无边框观感、红黄绿按钮自动隐藏、真实视频比例和常用键盘快捷键。
- 视频普通播放入口已收口到 `PlayerView.swift` + `LibMpvClient.swift`：SwiftUI 独立窗口内使用 `MpvOpenGLView` 承载画面，运行时动态加载随 App 分发的 `libmpv`，不再启动完整 mpv 可执行文件窗口。
- 修复内置视频播放出现双窗口和 Dock 额外图标的问题：`LibMpvClient` 改用 `mpv_render_context_create` / `mpv_render_context_render` 官方 render API，不再依赖 `wid` 嵌入，避免 mpv 在 macOS 上自建 Cocoa 视频窗口；关闭播放器会释放 render context 和 mpv handle，避免关闭或强退外部窗口牵连主 App。
- `BundledMpvPlayerService.swift` 已删除，`scripts/package_dmg.sh` 只复制 `libmpv` 及其动态库依赖到 `Contents/Frameworks`。
- 视频播放器使用透明标题栏 `ImmersivePlayerWindow`，保留 macOS 原生红黄绿按钮和系统圆角；红黄绿按钮会随控制层自动淡入淡出，形成接近系统播放器的无边框观感。尺寸按设置中的视频窗口宽度和视频比例计算，mpv 准备后再用真实显示比例校正，超过屏幕可用区域时等比缩小；打开后按当前主窗口所在屏幕的可用区域居中并激活，背景可拖动，Esc 和控制条关闭按钮负责退出。
- 视频播放器窗口定位已改为基于发起播放的主窗口所在屏幕，而不是依赖可能已切换的 `NSApp.keyWindow`；SwiftUI 内容挂载后会再次居中校正，保证播放器整体出现在屏幕中心。
- 视频播放器拖动由 `PlayerInteractionOverlay` 处理：点击空白视频区域仍切换控制条，拖动空白视频区域会调用 `NSWindow.performDrag(with:)` 移动整个播放器窗口，避免透明覆盖层吞掉背景拖动事件。
- 视频播放器内部提供底部居中的紧凑液态玻璃悬浮控制条；鼠标移动唤出，播放数秒后自动收起，不再占用顶部空间。
- 视频控制层自动隐藏计时器已移到 `PlayerControlsAutoHideCoordinator`，控制条常驻视图层级并只切换透明度/命中测试，hover 时暂停自动隐藏，不再把每次移动产生的新 Task 写入 SwiftUI `@State`，避免控制层闪烁并影响按钮点击。
- 视频播放器常用快捷键已接入 `KeyCaptureView`：Space/K 播放暂停，方向键和组合方向键跳转/调音量，J/L、PageUp/PageDown、Home/End、数字键跳转，M 静音，F/Return/Cmd-F 全屏，Esc/Cmd-W/Q 退出，`[`/`]`/`\` 调倍速，`,`/`.` 逐帧，C/V/A 切换字幕、字幕显示和音轨。
- 设置里的“视频窗口宽度”由 `VideoPlayerWindowPresenter` 直接应用到播放器内容宽度；新开视频和复用当前窗口时都会重新计算并调整 frame。
- 字幕/音轨入口已保留为应用内图标菜单，当前可调用 libmpv 切换、关闭、添加同目录字幕；后续还需要补真实轨道列表和当前状态同步。
- 侧边栏小图标在 `PlayfulSymbolIcon` 中改为小尺寸严格居中模式，避免同级图标中心线不齐；页头大图标仍保留原来的蓝系语义图标风格。
- 关闭独立视频播放器窗口不会再退出主应用：`MediaLibAppDelegate` 禁止最后窗口关闭时终止 App，视频 presenter 通过 `windowShouldClose` 拦截系统关闭按钮，先清理 `activePlayerItem`，再程序化关闭窗口。
- 本轮此前还处理过音乐播放点击无效、剧集详情页双击播放返回海报页、媒体库筛选条冗余文字和 App 图标风格。
- 音乐播放器已移到主界面内：`ContentView` 根据音乐 `activePlayerItem` 覆盖播放器；播放状态由 `ContentView` 持有的唯一 `MpvPlayerController` 和不可见 `MusicPlaybackHost` 管理，展开态显示 `MusicPlayerView`，最小化时显示独立 `MusicMiniPlayerBar`；不再弹出独立音乐 `NSWindow`。底部迷你播放器由 `ContentView` 外层窗口级 `GeometryReader` 强制给出整窗尺寸并在父层贴底，避免 `MusicPlayerView` 内部 `GeometryReader` 在 `NavigationSplitView` overlay 下拿到错误高度后漂到列表中部。`MusicPlayerView` 不再按歌曲 `.id` 强制重建，切歌时先停旧音频并配置新曲，再写回旧曲播放进度。
- 音乐播放器已移除隐藏 AppKit/mpv 视图，避免后台视图拦截 SwiftUI 按钮点击。
- 内置音乐播放已切到原生 AVFoundation 音频后端，播放/暂停、进度、倍速和音量都直接控制同一个 `AVPlayer` 实例；不再依赖 mpv 子进程，避免点击播放时 Dock 抖动但没有声音。
- 视频播放器关闭和切换上下集已改为先保存进度并 teardown 当前播放器；`LibMpvClient.stopPlayback()` 会静音、暂停并 stop mpv，OpenGL 视图首帧前清黑，减少关闭后声音残留和切集蓝屏。
- 设置页已移除默认音量；`AppSettings` 改为分别保存 `lastVideoVolume` 和 `lastMusicVolume`，播放器每次用户调节音量时回写并在下次播放同类媒体时恢复。音乐展开控制栏和底部迷你播放器都使用进度条右侧音量按钮弹出滑条，不再常驻显示音量滑杆。
- 音乐扫描现在会穿透嵌套文件夹，自动识别媒体源也会识别音频；音频文件扫描使用低大小阈值，不会被视频默认 50MB 阈值跳过。音乐扫描会提取单曲内嵌 artwork 到缩略图目录，封面优先级为内嵌封面、联网补全封面、默认图标；不会再把同目录 `cover/folder/poster` 或其他歌曲封面套给整个文件夹内的歌曲，联网补全不会覆盖 `-embedded-artwork` 封面。音乐缺省封面使用当前主题派生的玻璃唱片/音符/波形图形，不再复用视频播放卡，也不要退回固定蓝青系。
- 音乐专辑只信任音频标签或联网补全结果，不再用文件夹名把同目录歌曲强行归为同一专辑；歌词只匹配单曲同名 `.lrc` / `.txt`，不再读取目录级 `lyrics.lrc` / `lyrics.txt` 作为共享歌词。
- 音乐播放器支持 LRC 同步歌词自动滚动，当前行会变色、加粗并轻微放大；增强 LRC 的 `<mm:ss.xx>` 片段时间戳会触发逐字/分词柔和高亮，已播放歌词颜色由专辑封面主色派生为更深但不过暗的颜色。没有片段时间戳的普通 LRC 当前行使用 `LyricProgressWrappingText` / `LyricFlowLayout` 按实际换行后的字符顺序推进高亮，避免多行同时横向渐变。用户拖拽歌词区会暂停自动跟随数秒，无时间戳歌词仍走普通文本滚动；歌词卡片内所有滚动视图都隐藏滚动条。
- 音乐展开页会从专辑封面提取主色，生成覆盖整页的厚实不透视色板背景；背景和近场专辑光始终是静态 Canvas，只随专辑取色、窗口布局和挂载状态变化，不随播放时间或音乐能量变化。第二层左侧放专辑封面和与右侧歌词卡片同源材质的液态玻璃控制栏，左列会按窗口可用高度给封面、长标题和控制栏留空间，避免封面被顶出窗口；右侧放独立圆角液态玻璃歌词卡片。右侧歌词卡片在非紧凑布局下由 `MusicExpandedLayout` 显式计算 `lyricsRect`，用明确的 `x/y/width/height` 约束在剩余区域内；布局先保证左侧封面/控制栏宽度和左边距，再让歌词卡片从右边界向左弹性收窄，并保持右边距与控制栏左边距一致。圆角为 36pt，并使用更透亮的 `ultraThinMaterial`、高光描边、玻璃边缘和柔光阴影，避免再次被拉成右侧整条竖向背景。专辑光效以封面中心为锚点扩散更大范围的多色径向柔光和斜向光束，并通过专辑色给歌词卡片、控制栏和按钮边缘提供更明显轮廓光。展开前 `ContentView` 会无动画把 `NavigationSplitView` 收到详情区，保留系统红黄绿按钮并保持主窗口 toolbar 结构稳定，只隐藏标题和侧栏展开按钮；展开期间下层 `navigationRoot` 会停止命中测试并抑制 hover 光效，避免左侧栏、列表和海报在遮罩下继续响应鼠标。最小化时先缩到底部迷你播放器，再无动画恢复侧边栏，并给迷你播放器预留侧栏宽度。展开/收起只走底部位移加透明度转场，避免重型变形动画造成音乐列表页掉帧。左上角展开态只保留软件内最小化按钮，按钮作为 `MusicPlayerView` 最外层窗口级固定浮层显示，使用圆形液态玻璃和向下返回/收起箭头，并以与左侧控制栏相同的左边距固定。
- 普通媒体库页面已增加 `LibrarySnapshotCache`，按页面、搜索、筛选、排序和 `libraryRevision` 缓存过滤排序结果；`LibraryView` 切换栏目时显式使用新的 `SidebarDestination` 刷新，并用 `visibleItemsDestinationID` 标记当前网格所属栏目，避免 SwiftUI 复用旧 view 时出现标题已变但列表落后一拍、动漫/电视剧内容互换。左侧栏接入 `SidebarGlassBackground`，当前蓝色洗色已降低以保持清透；通用 `SurfaceBackground` 卡片材质叠加更浅的象牙白高光和玻璃边缘。首页 `HomeTabBar` 在标签较多时会切成可横向拖动的双行布局，首页和首页设置只展示有内容的 tab，总览统计隐藏 0 项。
- 音乐歌词解析结果已改为 `MusicPlayerView` 状态缓存，只在歌词文本变化时解析，避免播放进度刷新时反复解析 LRC。
- 视频播放器控制层修复鼠标移动闪烁，自动隐藏任务取消后不会继续执行隐藏逻辑；支持左键播放/暂停、右键隐藏控制层、空格播放/暂停、左右方向键快退/快进、上下方向键调音量，并提供右侧中心控制层锁定按钮。
- 视频和音乐播放器已补上一集/上一曲、下一集/下一曲基础能力；音乐播放器新增内存级队列弹层，可查看后续歌曲、点击跳转或移除队列项。
- 视频“正在观看”、Emby 最近播放和音乐最近播放等留痕页面保留清除当前页面播放记录入口；清除时只重置播放位置、进度、已观看和最近播放时间，并在 `AppState` 内存、队列和快照版本中同步，不再整库 `reload()`，避免音乐列表被短暂清空。
- 媒体源页新增 Emby 登录同步入口：登录后获取 Emby 资源，token 存入 Application Support 的凭据文件，资源以 Emby ItemId 与内部条目保持映射。
- 左侧栏新增 EMBY 一级目录，有 Emby 媒体源或资源时显示，展开后按视频、音乐、最近播放、收藏分类。
- 媒体源页新增 SMB/FTP 网络设备入口，支持匿名或用户名密码登录；登录后选择系统挂载目录并选择分类扫描。
- 首页 tab、侧边栏目的上次位置、视频库和音乐库筛选/排序会保存到 UserDefaults。
- `AppState.reload()` 后会重建顶层媒体、保险库、音乐、Emby 和子级映射缓存，避免首页和标签页切换时反复做全量过滤/排序。
- 首页/侧边栏切换卡顿已做第一轮优化：`AppState.reload()` 现在还会缓存首页统计、继续观看、缺失文件、重复标题、可见视频分组和离线媒体源，首页健康提示不再在每次显示时同步访问文件系统。
- 页面切换和动画已收口到 `AppMotion`：主详情区不再按侧边栏 selection `.id` 强制重建页面，普通页面切换不再套整页 transition/animation，长列表更新时禁用隐式列表动画；音乐展开/收起使用 `AppMotion.musicPlayer` 的底部位移/透明度转场。
- 底部音乐迷你播放器已改为弹性控制条：侧边栏收起时按窗口剩余空间拉伸，侧边栏展开时缩回避让；常驻进度条使用轻量 SwiftUI 绘制/拖动控件，避免原生 slider 热更新和控件挤压。
- 音乐切歌已避免重建音频后端：`MpvPlayerController.configureMusic` 复用现有 `AVPlayer` 并 `replaceCurrentItem(with:)`，切歌保存上一首进度时静默写库，不触发全库 reload；音频结束通知会立即推进下一首。音乐进度刷新挂到 `.common` run loop，并以约 8fps 发布给 UI，避免进度刷新在音乐列表滚动和播放器转场时抢占过多主线程预算。
- 本轮修复音乐手动切歌一拍延迟：`MusicPlaybackHost` 的 `onChange(of: item.id)` 不再直接使用闭包捕获的 `item`，而是从 `AppState.activePlayerItem` 读取当前曲目后再调用 `MpvPlayerController.configureMusic`；同时 `MpvPlayerController` 为 AVFoundation 音乐切换增加播放代次校验，切换时先暂停旧 item，再确认新的 `AVPlayerItem` 才允许 seek 回调继续播放或播放结束通知推进队列，避免封面已经切到下一首但声音仍停在上一首。
- 本轮修复底部迷你播放器对系统侧栏按钮的响应：底栏是否预留侧栏宽度改为由 `NavigationSplitView` 列状态实时推导，用户主动收起左侧栏时底栏会拉伸，重新打开时会缩回。
- 本轮继续优化底部迷你播放器：曲目信息区域设置最大宽度，中间播放按钮保持紧凑，进度条常驻并使用剩余宽度，底栏向右填充更多可用空间；随机播放和循环模式已分离，循环模式按钮放在随机播放左侧，队列按钮放在 AirPlay 左侧，循环模式图标分别使用顺序箭头、repeat 和 repeat.1。音乐播放不再恢复历史进度，切歌和重新播放都从头开始；双击歌曲列表优先显示底部迷你播放器，用户点击底栏曲目信息后再展开。关闭音乐/视频播放器时保存播放痕迹不再触发全库 reload，音乐关闭路径也去掉了重复 teardown。队列弹层改为透明玻璃样式，支持清空、移出、点击播放、拖拽排序和存入歌单；播放队列本身不做独立侧边栏页面，历史选择会回落到“歌曲”，用户手动歌单则在“音乐 > 歌单”中显示。展开页歌词滚动条已隐藏，左上角收起按钮现在由 `MusicExpandedLayout` 定位为左上等距胶囊按钮，材质复用右侧歌词卡片；展开/收起动画改为从底栏来、回到底栏；音乐缺省封面和分类切换快照也在本轮修正。
- 音乐 AirPlay 现在由 `MpvPlayerController.routePickerSession` 持久绑定当前 `AVPlayer`；展开页、底部条和视频控制栏都通过显式 session 传入，由可见 SwiftUI 按钮触发隐藏原生 route picker，不再在 `MusicPlaybackHost` 中放隐藏 route keeper。音乐输出遵循系统外部路线逻辑，不再提供本机与外部设备同播开关。
- 音乐列表滚动掉帧已做多轮优化：`MusicLibraryView` 改为监听 `AppState.libraryRevision`，搜索输入短去抖后刷新快照；`MusicTrackRowModel` 会预计算文件名、歌词状态、时长、艺人和专辑文本，row 的 `body` 不再反复解析路径或查歌词文件。
- `ArtworkImageCache` 增加容量限制、cost、缺失路径缓存和宽高比缓存；海报卡片只读取已缓存比例，不再为了排版在 SwiftUI `body` 中同步加载本地图片。
- 详情页本地文件存在性改为后台任务写回状态，避免切换详情页时主线程同步访问 NAS/文件提供器路径。
- 通用卡片材质已叠加 `ultraThinMaterial`、白色高光描边和轻蓝阴影，整体观感更亮、更接近 macOS 26 风格。
- 剧集列表播放入口现在可保留详情页上下文，双击剧集播放不会清空当前选中海报。
- 媒体库视频/音乐筛选条已去掉“范围/筛选/排序”等标签，右侧排序控件改为自绘菜单按钮，左右内边距统一。
- App 图标已改为用户提供的方案 1 原图源；生成脚本会裁掉外侧拍摄边框/背景，只保留图标本体，并额外生成深色外观资源。应用内页头、侧边栏、设置分组、设置行和统计图标采用统一蓝系无边框符号风格，但按视频、音乐、媒体源、保险库、设置、状态、元数据等语义绘制不同图形，不能再套同一个胶片卡模板。

### 媒体源与扫描

- 媒体源添加、删除、保存、扫描。
- 支持多个文件夹一次添加并顺序扫描。
- 添加媒体源后会先弹出应用内分类面板，只展示真实媒体分类，避免系统确认按钮混入分类选择。
- Emby 源不进入本地 `MediaScanner`，通过 `EmbyService` 拉取远程资源并写入 `media_items`。
- SMB/FTP 源由 macOS 挂载后选择目录，最终仍按本地路径递归扫描。
- 支持自动分类源：电影、电视剧、动漫、纪录片、综艺、音乐、其他、保险库。
- 扫描中修改媒体源分类会撤销当前扫描状态并重新扫描对应媒体源。
- 保险库媒体源扫描时不在 UI 中显示当前路径和文件名。
- 支持视频扩展名：`mp4/mkv/mov/avi/m4v/wmv/flv/webm/ts/m2ts/mts/rmvb/rm/mpg/mpeg/3gp/3g2/vob/ogv/mxf/divx/f4v`。
- 支持音频扩展名：`mp3/m4a/aac/flac/wav/aiff/aif/alac/ogg/opus/ape/caf/mka`。

### 视频库

- 视频和音乐现在是左侧栏两个一级分组。
- 视频分组下的分类是动态显示：有内容后才显示电影/电视剧/动漫等分类。
- 电影、电视剧、动漫、纪录片、综艺、其他、保险库、正在观看、想看、喜欢、未观看、已观看，以及用户保存的智能集合。
- 剧集按系列聚合，支持常见 `S01E01`、中文“第 x 季 第 x 集”、`EP01` 等文件名模式。
- 对 Emby/Jellyfin 经典目录结构做了优先目录聚合，减少同剧集拆成多个系列的问题。
- 海报墙支持真实比例排版，竖版/横版封面自适应。
- 海报右键支持重分类、手动标记已观看/未观看、收藏/取消收藏，不移动物理文件。
- 海报、剧集行和音乐歌曲右键支持删除播放记录；视频侧播放痕迹统一汇总到“正在观看”，用于清除继续观看/已观看/最近播放痕迹。
- 海报悬停显示资料源评分；星级评级可直接点击调整，并写入独立的用户评级字段。

### 音乐库

- 音乐是独立一级模块，二级入口：
  - 歌曲
  - 专辑
  - 艺术家
  - 最近播放
  - 歌单
  - 收藏歌曲通过“歌单”页置顶虚拟歌单管理；未匹配歌曲不再放入左侧栏，只保留在元数据获取等需要的范围筛选中。
- 歌曲页使用列表而不是海报墙，显示封面、标题、文件名、艺术家、专辑、歌词状态、时长。
- 歌曲支持双击播放。
- 歌曲右键支持播放、收藏/取消收藏、重分类到视频/其他/保险库等类型。
- 专辑页按 `album + artist` 聚合，显示专辑封面、专辑名、艺术家、歌曲数、播放按钮。
- 艺术家页按 artist 聚合，显示歌曲数和专辑数。
- 音乐扫描新增 `AudioMetadataReader`，优先读取 common、iTunes、ID3、QuickTime 等音频标签中的标题、艺术家、专辑、曲目号、年份、时长、内嵌封面和内嵌歌词，再回退到文件名/目录推断。
- 音乐扫描同时读取 ReplayGain/R128 曲目/专辑增益与峰值；内置播放器可按设置使用防削波均衡，并在即时衔接和单播放器柔和淡入之间切换。本地确定性下一首的即时衔接使用单个 `AVQueuePlayer` 的有界单项预加载，随机、远程和柔和淡入保持非预加载路径。
- 本地同名 `.lrc` / `.txt` 歌词或音频内嵌歌词可在音乐播放器中显示。

### 播放器

- 视频内置播放使用 `PlayerView.swift` 的 SwiftUI 独立窗口，运行时通过 `LibMpvClient.swift` 动态加载随 App 分发的 `libmpv` 核心，并通过 libmpv render API 渲染到应用内 `MpvOpenGLView`。
- 音乐使用主界面内 `MusicPlayerView`，不再进入视频播放器，也不再弹独立音乐窗口。
- 视频播放器：
  - 优先加载 App 包内 `Contents/Frameworks/libmpv.2.dylib` / `libmpv.dylib`，开发环境下可回退到 Homebrew libmpv
  - 使用 SwiftUI 自绘自动隐藏液态玻璃控制栏，系统标题栏负责关闭、最小化和全屏
  - 自动尝试加载同目录字幕，字幕/音轨通过播放器内图标菜单调用 libmpv 控制
  - 关闭播放器会保存播放进度并销毁 libmpv handle，不影响主 App
  - 如果 libmpv 加载或启动失败，会在播放器内显示错误并提供系统播放器兜底
- 音乐播放器：
  - 播放/暂停
  - 进度条
  - 音量
  - 封面展示
  - 歌词区域
  - 同名歌词文件读取，并会主动尝试 LRCLIB 联网歌词

### 保险库

- 保险库分类上锁。
- 支持 Touch ID / 设备认证或 4 到 8 位数字密码解锁。
- 首次进入保险库会引导设置密码；当前版本不再读写或删除旧 Keychain 项，避免更新后首次启动弹系统密码框。
- 锁定状态隐藏保险库内容、媒体源路径、扫描路径/文件名和改密入口。
- 移除保险库密码前必须先解锁。
- 设置页可重命名保险库。
- 设置页可主动重新上锁。

### 元数据

- 设置页可填写 TMDB API Key 或 Read Access Token。
- 详情页可搜索 TMDB 信息并应用到电影/剧集。
- 音乐可选择 MusicBrainz / iTunes Search / 关闭。
- 详情页音乐搜索可应用曲名、艺人、专辑、年份、封面等信息。
- 远程封面会下载到缩略图缓存后写入本地路径。
- 设置页“音乐元数据获取”工作台可批量预览、编辑和应用音乐标签；默认只更新 MediaLIB 索引，用户显式打开“写入文件”才写回本地音频文件标签。

### UI / 设计

- 使用蓝/青蓝为主色，去掉大面积紫粉主色。
- App logo 保留方案 1 的白色圆角底、彩色叠层卡片、蓝色播放卡、胶片孔和播放三角，由 `scripts/generate_icon.swift` 生成浅色/深色资源；不要再加入水波纹和音乐符号。
- 统一页头、玻璃卡片、列表行、设置分组、海报卡片。
- 设置页分组标题与内容卡片形成层级，内容整体右移。
- 海报图片有简单内存缓存，减少页面切换时反复同步读盘。

### 构建与产物

- `swift build` 可通过。
- `.build/debug/MediaLibChecks` 可通过。
- `scripts/package_dmg.sh` 可生成：
  - `dist/MediaLIB.app`
  - `dist/MediaLib.dmg`
- `/private/tmp/MediaLib-package/MediaLIB.app` 通过严格签名校验。
- `dist/MediaLib.dmg` 通过 `hdiutil verify`。

## 5. 本轮会话修改过的文件

本轮迭代持续时间较长，几乎覆盖了 App 的核心路径。主要修改/新增文件如下：

### App 层

- `Sources/MediaLib/App/AppState.swift`
- `Sources/MediaLib/App/MediaLibApp.swift`
- `Sources/MediaLib/App/MetadataSearchService.swift`
- `Sources/MediaLib/App/PrivacyLockService.swift`

### UI 层

- `Sources/MediaLib/Views/ContentView.swift`
- `Sources/MediaLib/Views/HomeView.swift`
- `Sources/MediaLib/Views/LibraryView.swift`
- `Sources/MediaLib/Views/MusicLibraryView.swift` 新增
- `Sources/MediaLib/Views/MusicPlayerView.swift` 新增
- `Sources/MediaLib/Views/MusicPlaylistCreationSheet.swift` 新增
- `Sources/MediaLib/Views/MusicTagScraperSheet.swift` 新增
- `Sources/MediaLib/Views/PlayerView.swift`
- `Sources/MediaLib/Views/PosterGridView.swift`
- `Sources/MediaLib/Views/DetailView.swift`
- `Sources/MediaLib/Views/SettingsView.swift`
- `Sources/MediaLib/Views/SourcesView.swift`
- `Sources/MediaLib/Views/PrivacyLockView.swift`
- `Sources/MediaLib/Views/QuickPreviewView.swift`
- `Sources/MediaLib/Views/EpisodeListView.swift`
- `Sources/MediaLib/Views/EmptyStateView.swift`
- `Sources/MediaLib/Views/KeyCaptureView.swift`
- `Sources/MediaLib/Views/AppColors.swift`

### Core 层

- `Sources/MediaLibCore/Models/AppSettings.swift`
- `Sources/MediaLibCore/Models/MediaItem.swift`
- `Sources/MediaLibCore/Models/MediaType.swift`
- `Sources/MediaLibCore/Models/MediaSource.swift`
- `Sources/MediaLibCore/Models/MusicPlaylist.swift`
- `Sources/MediaLibCore/Database/DatabaseManager.swift`
- `Sources/MediaLibCore/Database/MediaRepository.swift`
- `Sources/MediaLibCore/Database/MusicPlaylistRepository.swift`
- `Sources/MediaLibCore/Services/MediaScanner.swift`
- `Sources/MediaLibCore/Services/AudioMetadataReader.swift` 新增
- `Sources/MediaLibCore/Services/MusicTagEditingService.swift` 新增
- `Sources/MediaLibCore/Services/FilenameParser.swift`
- `Sources/MediaLibCore/Services/ThumbnailGenerator.swift`
- `Sources/MediaLibCore/Services/LocalMetadataService.swift`
- `Sources/MediaLibCore/Services/ExternalPlayerService.swift`
- `Sources/MediaLibCore/Services/FileAccessService.swift`

### 资源、脚本、文档

- `Sources/MediaLib/Resources/AppIcon.png`
- `Sources/MediaLib/Resources/AppIconDark.png`
- `Sources/MediaLib/Resources/AppIconSource.jpg`
- `Sources/MediaLib/Resources/AppIcon.icns`
- `scripts/generate_icon.swift`
- `scripts/package_dmg.sh`
- `AGENTS.md` 新增
- `ROADMAP.md` 新增
- `README.md`
- `CHANGELOG.md`
- `开发说明.md`
- `用户使用说明.md`
- `handoff.md`

## 6. 每个修改文件的作用

- `AppState.swift`：全局状态、数据加载、扫描队列、播放入口、保险库锁状态、重分类、资料源评分/用户评级和元数据应用。当前侧边栏动态显示、音乐列表数据过滤和扫描重启逻辑都依赖它。
- `LibMpvClient.swift`：动态加载 `libmpv`，创建/destroy mpv handle 和 render context，将视频帧渲染到播放器 `MpvOpenGLView`，封装属性读取、属性设置和命令调用。
- `MediaLibApp.swift`：App 入口，注入 `AppState`，主题应用；App delegate 禁止最后窗口关闭时终止应用，避免关闭独立播放器窗口误退出主程序。
- `MetadataSearchService.swift`：TMDB、MusicBrainz、iTunes Search 搜索和远程封面落地缓存。
- `MusicTagScraperSheet.swift`：设置页“音乐元数据获取”工作台，自绘玻璃弹层、范围选择、批量匹配、展开式标签编辑、所选应用和显式写回文件入口。
- `PrivacyLockService.swift`：本机凭据文件保存 PIN 哈希、验证 PIN、Touch ID 解锁。
- `ContentView.swift`：左侧栏和主导航。现在定义 `VideoLibrarySection`、`MusicLibrarySection`、`SidebarDestination`，视频/音乐双一级结构在这里；通过 `VideoPlayerWindowPresenter` 打开独立视频窗口，并持有唯一音乐控制器、不可见 `MusicPlaybackHost`、展开页和独立底部迷你播放器。展开/收起音乐播放器时会刷新音乐 AirPlay 路由，并显式恢复主窗口红黄绿按钮和工具栏。
- `HomeView.swift`：首页、首页 tab、统计卡片、扫描进度。首页的音乐入口仍走 `HomeTab.music`，但实际调用 `.music(.songs)`；标签较多时 `HomeTabBar` 使用可拖动双行布局。
- `LibraryView.swift`：视频库列表/海报墙页面。只负责视频类 destination；筛选/排序栏已改为显式左对齐布局；栏目切换时用新 destination 刷新快照并用 `visibleItemsDestinationID` 防止旧列表显示在新标题下。
- `MusicLibraryView.swift`：音乐库专用 UI，包含歌曲列表、专辑聚合、艺术家聚合、歌单和最近播放；收藏通过“歌单”页置顶虚拟歌单展示，未匹配歌曲不再作为左侧栏栏目。歌词文件存在性使用内存缓存，减少滚动时同步读盘。歌曲右键支持加入队列、下一首播放和存入歌单；歌曲、专辑、艺术家和视频海报长列表都使用惰性/预取批次降低滚动压力。
- `MusicPlaylistCreationSheet.swift`：歌单创建弹层和通用 `MusicPlaylistActionsMenu`；菜单第一项为新建歌单，后续是已有歌单，供歌曲右键、分组列表、专辑/艺术家和队列复用。
- `MusicPlayerView.swift`：音乐专用展开页，封面、播放控制、歌词显示；`MusicPlaybackHost` 负责持续播放、切歌和进度回写，`MusicMiniPlayerBar` 负责独立底部控制条，`MusicQueuePopover` 负责透明队列弹层、清空、移出、拖拽排序和队列存入歌单；普通 LRC 当前行通过 `LyricProgressWrappingText` / `LyricFlowLayout` 做换行感知高亮。展开页取色以 `activePlayerItem` 为准，切歌会清掉旧色并校验当前歌曲 ID。
- `PlayerView.swift`：当前视频内置播放器窗口，负责 `ImmersivePlayerWindow`、`MpvOpenGLView`、液态玻璃底部控制栏、播放/暂停、seek、音量、倍速、全屏、字幕/音轨菜单和播放进度保存；`VideoPlayerWindowPresenter` 会按设置里的视频窗口宽度和视频比例创建或调整窗口，控制条自动隐藏状态由非发布协调对象管理。关闭和切集时先 teardown 停止 libmpv，再保存播放进度，降低关闭卡顿和残音。
- `PosterGridView.swift`：视频海报墙、海报卡片、资料源评分展示、用户评级入口、右键重分类、图片缓存使用；长海报列表使用分块瀑布流并由列表行虚拟化承载，避免一次实例化全部卡片。
- `DetailView.swift`：媒体详情页、播放/外部打开/收藏/已看/元数据搜索。
- `SettingsView.swift`：设置中心，播放、首页、扫描、元数据、封面、界面、保险库、高级设置；包含视频/音乐播放器分离设置、自动扫描间隔和音乐封面歌词一键获取。已移除播放器“快捷选择”和旧 AirPlay 同播冗余项，设置行右侧控件统一右对齐，输入框文本居中且按文本长度弹性收窄/展开，开关、下拉框和“选择”按钮右边界保持一致；视频为系统播放器时隐藏内置视频窗口宽度和内置视频说明。
- `SourcesView.swift`：媒体源管理；统一添加媒体源三步向导、每行来源设置弹窗、保险库源锁定时隐藏路径。
- `PrivacyLockView.swift`：保险库锁定/解锁页面。
- `QuickPreviewView.swift`：剧集快速预览，改为悬浮玻璃控制栏。
- `EpisodeListView.swift`：剧集列表，双击播放、空格预览、右键操作。
- `EmptyStateView.swift`：通用空状态。
- `KeyCaptureView.swift`：AppKit 键盘事件捕获，用于 Esc/Space 等快捷键。
- `AppColors.swift`：全局颜色、玻璃卡片、页头、搜索框、按语义重绘的蓝系玻璃应用内图标、右侧玻璃菜单按钮、图片缓存。当前侧栏使用更透明的 `ultraThinMaterial` 冷蓝玻璃，通用卡片底色偏白并注入浅米白/象牙白高光，降低材质灰雾感；`GlassCapsuleControl` 统一首页横条、视频筛选和音乐筛选按钮；音乐/status 等应用内图标调色板已移除紫/粉色。
- `AppSettings.swift`：用户设置模型。新增/维护视频/音乐播放器、首页 tab、自动扫描间隔、TMDB、音乐元数据源、封面策略、保险库相关设置；`keepLocalAudioWithAirPlay` 只作为旧配置解码兼容字段保留。
- `MediaItem.swift`：媒体条目模型。已扩展音乐字段：artist、album、trackNumber、externalID、metadataProvider 等。
- `MediaType.swift`：媒体分类枚举，包含 music、private 等。
- `MediaSource.swift`：媒体源模型。
- `MusicPlaylist.swift`：用户手动歌单模型，保存歌单名、媒体 ID 顺序和创建/更新时间。
- `DatabaseManager.swift`：SQLite 初始化和迁移。为媒体表增加音乐/元数据列，并创建 `music_playlists` / `music_playlist_items`。
- `MediaRepository.swift`：媒体增删改查、播放进度、播放记录清除、收藏、重分类、资料源评分、用户评级和元数据更新。播放记录清除会同时清除 `watched`，不要只清最近播放时间。
- `MusicPlaylistRepository.swift`：用户歌单持久化仓库，负责创建歌单、追加歌曲、读取歌单及其媒体 ID 顺序。
- `MediaScanner.swift`：扫描核心，区分音乐与视频；音乐路径会调用 `AudioMetadataReader`；保险库扫描隐藏路径。
- `AudioMetadataReader.swift`：读取音频标签、格式级 metadata、内嵌 artwork 和内嵌歌词，覆盖 common、iTunes、ID3、QuickTime 识别符并使用 AVFoundation async load API。
- `MusicTagEditingService.swift`：原生音乐标签写回核心，使用 `MusicTagDraft` 统一字段，通过 ffmpeg 复制音频流写入文字标签和可支持封面，临时文件校验通过后才替换原文件。
- `FilenameParser.swift`：文件类型识别与视频文件名解析。扩展了更多视频/音频后缀。
- `ThumbnailGenerator.swift`：视频帧截图、ffmpeg 兜底截图、默认封面生成；音乐缺省时生成专用音乐默认图，SwiftUI 默认封面展示需跟随当前主题派生色。
- `LocalMetadataService.swift`：本地 NFO、poster/cover/folder、fanart/backdrop 识别。
- `ExternalPlayerService.swift`：IINA/VLC/Movist/QuickTime、自定义 `.app` 外部播放器打开。
- `FileAccessService.swift`：Application Support、Caches、Thumbnails、Logs 路径。
- `generate_icon.swift`：使用用户提供的方案 1 原图源生成 App logo，裁掉外侧拍摄边框/背景，只保留图标本体；输出浅色 PNG、深色 PNG、iconset 和 `.icns`。
- `package_dmg.sh`：构建 release、生成 app bundle、签名、生成和校验 DMG。脚本直接使用 `generate_icon.swift` 生成的 `.icns`，并把 `AppIconDark.png` 放入 App 包；同时在本机存在 Homebrew `ffmpeg` 时复制 ffmpeg 和依赖，供 MKV 截帧封面兜底。注意 dist 下 app 可能被系统文件提供器加扩展属性，脚本对 dist app strict verify 只 warning，源 bundle `/private/tmp/MediaLib-package/MediaLIB.app` 是严格校验对象。
- `AGENTS.md`：后续开发约束，强调小步迭代、修改前先计划、修改后说明文件/原因/测试。
- `ROADMAP.md`：后续开发顺序，当前优先级是播放器稳定化、UI 对齐统一、音乐播放队列和元数据缓存。
- `README.md` / `CHANGELOG.md` / `开发说明.md` / `用户使用说明.md`：同步功能说明。

## 7. 当前未完成任务

以下是明确未完成或只做了 P0/雏形的任务：

- 音乐已有播放队列、当前曲库上一曲/下一曲、独立随机播放开关、顺序播放/队列循环/单曲循环模式，以及播放器队列弹层的清空、移出、拖拽排序和存入歌单；队列顺序、随机与循环状态已通过 `music_queue_state` / `music_queue_items` 跨启动持久化，启动恢复但不自动播放。用户手动歌单通过 `music_playlists` / `music_playlist_items` 持久保存，并已提供重命名、删除、移除单曲和手动排序 UI。
- 音乐歌词已能主动尝试 LRCLIB，LRC 时间戳歌词会自动滚动并高亮当前行，增强 LRC 片段时间戳已支持逐字/分词高亮，也支持点击带时间戳歌词跳转；还没有做歌词缓存表。
- MusicBrainz / iTunes 自动补全已有设置页一键入口和“音乐元数据获取”预览编辑工作台，但仍缺少更精细的候选评分、冲突对比、失败重试、撤销/备份保留策略和缓存表。
- 没有实现专门的 `music_tracks/music_albums/music_artists` 新表。当前音乐条目仍复用 `media_items`，但用户歌单已经使用 `music_playlists` / `music_playlist_items` 专用表。
- `AudioMetadataReader` 已改用 async `load(.stringValue)` / `load(.numberValue)` 等接口，并读取 common、iTunes、ID3、QuickTime 等格式级 metadata；后续仍可补更完整的非 AVFoundation 格式兜底。
- Emby/Jellyfin/Plex 已接入媒体源设置弹窗中的服务器库选择；更细的远端写回失败恢复、评分冲突、Plex OAuth/发现和更完整转码策略仍需后续补齐。
- libmpv 已随 App 打包并改写动态库路径，但这是基于本机 Homebrew libmpv 依赖复制；后续若换构建机，需要重新验证依赖完整性。
- 内置视频播放器已是 SwiftUI 独立窗口 + libmpv render API；后续重点不是恢复完整 mpv 窗口或 `wid` 嵌入，而是补轨道列表、状态同步和更多播放器设置。
- 字幕/音轨选择目前有应用内图标菜单，但还没有真实轨道列表和当前选择状态；这应作为播放器下一阶段重构重点。
- 本机来源已通过 FSEvents 自动监听新增、修改和删除变化，并在防抖合并后执行受影响路径的增量扫描；目录结构变化或事件丢失会安全降级为完整来源扫描。网络来源仍使用周期完整扫描兜底。
- 没有完整测试套件，只有 `MediaLibChecks` 轻量检查。

## 8. 已知 bug / 风险

- `dist/MediaLIB.app` 位于用户文档目录，可能被 macOS 文件提供器自动写入 `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` / `com.apple.provenance` 扩展属性，导致 strict `codesign --verify --deep --strict dist/MediaLIB.app` 报 “resource fork, Finder information, or similar detritus not allowed”。当前脚本以 `/private/tmp/MediaLib-package/MediaLIB.app` 为严格校验对象，DMG 也通过校验。
- mpv 对 MKV/AVI/RMVB/WebM 等格式支持明显好于 AVPlayer，但极少数编码、DRM、损坏文件仍可能失败，需要保留系统播放器兜底。
- Finder 和 Dock 图标统一使用 `AppIcon.icns`。不要再运行时直接设置 `NSApp.applicationIconImage` 为 PNG，否则 Dock 会绕过系统图标处理并显示成方形贴片；若未来需要系统级深色模式静态图标，需要研究 macOS 对多外观 AppIcon asset 的打包支持。
- 音乐标签读取依赖 AVFoundation，不同格式如 APE、部分 FLAC/Opus 的标签支持仍可能不稳定，需要保留联网补全和默认封面兜底。
- 部分音频格式的内嵌封面或歌词即使在格式级 metadata 中也不一定能读到，后续可评估 ffprobe/TagLib 兜底。
- “音乐元数据获取”写回依赖 ffmpeg 可执行文件，开发机和打包 App 通常由 `scripts/package_dmg.sh` 复制 Homebrew ffmpeg；未打包或用户机器没有 ffmpeg 时会提示不可写入文件标签。当前写回是“显式选择后修改原音频文件”，没有实现撤销 UI；后续可加保留备份或写入前二次确认策略。
- Emby 资源当前使用静态 stream URL 加 `api_key` 播放；播放前会校验会话并在 token 过期时自动重登、刷新本次播放 URL。服务器要求特殊转码或限制直连时仍需继续完善转码策略。
- 当前数据库使用 `PRAGMA user_version` 顺序迁移；未来若加音乐专用表，必须继续提升 schema version、创建迁移前一致性备份并覆盖恢复往返。
- 重分类只改当前条目 type，不会递归改子剧集/父系列的所有关联项。后续如果用户期望“整部剧集重分类”要补递归逻辑。
- 动态左侧栏“视频分类有内容才显示”可能导致新用户空库时只看到“暂无视频”和音乐所有子项；这是产品决策，但可能需要空状态引导。
- `HomeTab` 仍保留 music 作为首页 tab；左侧栏音乐已重构为专门分组，两者不要混淆。
- 保险库扫描隐藏 UI 路径，但日志里对保险库错误当前只写泛化信息；如果后续为了排查写入路径，要注意不要泄露保险库路径。
- `MediaScanner.scan` 开始前会 `deleteItems(sourcePath:)` 清理旧索引，取消扫描时可能导致该源暂时缺索引。分类变化重新扫描依赖重新跑完恢复。
- `MediaItem` 仍承担视频、剧集、音乐多种实体角色，后续功能继续膨胀会变重。

## 9. 下一步最推荐做什么

最推荐的下一步不是继续堆功能，而是按以下顺序收敛风险：

1. 做视频播放器 P0 稳定化：
   - 验证新机器上 `Contents/Frameworks/libmpv.2.dylib` 及依赖可动态加载
   - 如果 libmpv 启动失败，优先修正打包依赖、install name、rpath 和签名
   - 补真实字幕/音轨列表、当前选择状态、播放器设置面板和状态同步
2. 给音乐播放状态补更清晰的服务层边界：
   - `MusicPlaybackService` 或 `MusicPlayerViewModel`
   - 队列持久化和启动恢复
   - 歌单重命名、删除、移除单曲和手动排序
   - 保持现有随机、循环和 AVPlayer 复用路径
3. 给歌词补缓存表和失败记录：
   - `LyricsService`
   - 联网歌词缓存
   - 手动匹配/重新匹配入口
4. 给音乐库加最小测试：
   - 音频文件名/目录推断
   - album/artist 聚合
   - unmatched 逻辑
5. 评估是否继续引入音乐专用表：
   - 如果只是继续小步迭代，可继续复用 `media_items`
   - 用户歌单表已实现；如果要做歌词缓存、封面缓存、专辑/艺术家详情，建议继续评估 `music_tracks/music_albums/music_artists` 以及歌词/封面缓存表
6. 用真实 NAS 音乐目录和真实视频目录做 UI/性能验证。

## 10. 新会话继续开发时应该先读哪些文件

建议按这个顺序读：

1. `handoff.md`：先读本文件，理解当前状态和坑。
2. `AGENTS.md`、`ROADMAP.md`：了解开发约束和当前推荐顺序。
3. `README.md`、`CHANGELOG.md`、`用户使用说明.md`：了解对用户承诺的功能。
4. `Sources/MediaLib/Views/ContentView.swift`：理解左侧栏视频/音乐新结构。
5. `Sources/MediaLib/App/AppState.swift`：理解状态、过滤、扫描、播放、保险库、重分类。
6. `Sources/MediaLib/Views/MusicLibraryView.swift`：理解音乐库 UI 和聚合方式。
7. `Sources/MediaLib/Views/MusicPlayerView.swift`：理解当前音乐播放器。
8. `Sources/MediaLib/Views/PlayerView.swift`：理解当前视频内置播放器、OpenGL 承载视图、窗口尺寸应用和液态玻璃控制栏。
9. `Sources/MediaLib/App/LibMpvClient.swift`：理解 libmpv 动态加载、render context 和命令调用。
10. `Sources/MediaLibCore/Services/MediaScanner.swift`：理解扫描如何生成 `MediaItem`。
11. `Sources/MediaLibCore/Services/AudioMetadataReader.swift`：理解音频标签读取。
12. `Sources/MediaLibCore/Services/MusicTagEditingService.swift`、`Sources/MediaLib/Views/MusicTagScraperSheet.swift`：理解“音乐元数据获取”批量匹配、编辑和显式写回路径。
13. `Sources/MediaLibCore/Models/AppSettings.swift`、`MediaItem.swift`、`MediaType.swift`：理解模型和设置。
14. `Sources/MediaLibCore/Database/DatabaseManager.swift`、`MediaRepository.swift`：理解 SQLite 表结构和迁移。
15. `scripts/package_dmg.sh`：理解打包和签名验证流程。

## 11. 重要约束和不要踩的坑

- 不要把重分类实现成移动文件。用户明确要求只改分类，不改变物理存储位置。
- 不要把“音乐元数据获取”做成后台静默改原音乐文件；默认只能更新 MediaLIB 索引，只有用户在工作台显式打开“写入文件”并点击写入才可改本地音频标签。不要直接引入 `music-tag-web` 整包或其他许可证不兼容的 Web 工程。
- 不要承诺内置播放器可播放所有格式。mpv 覆盖面很广，但仍需保留系统播放器兜底和错误提示。
- 不要在锁定状态展示保险库路径、保险库文件名或扫描当前文件。
- 不要在设置未解锁时允许移除保险库密码。
- 不要把音乐继续塞进视频海报墙。音乐已经提级为独立左侧一级模块，歌曲应使用列表，专辑/艺术家用音乐专用视图。
- 不要让空的视频分类常驻左侧栏；当前产品决策是有内容才显示。
- 不要忘记 `HomeTab.music` 仍存在，它是首页 tab，不等同于左侧栏音乐分组。
- 不要再把 `scripts/package_dmg.sh` 改回依赖 `iconutil`；当前 Swift 脚本已直接写出 `.icns`，并保留 iconset 只用于检查导出尺寸。
- 不要在 `AppState.applyAppearance()` 里用 `NSApp.applicationIconImage` 设置 1024 PNG，Dock 会把它当普通方形图片显示。
- 不要用 `cat > file` 等 shell 写文件；继续使用 `apply_patch`。
- 媒体源添加和设置不要再用普通系统 alert/confirmationDialog，也不要恢复行内选项框。当前使用 `AddMediaSourceWizardSheet` 三步向导添加来源，保存后的分类、服务器库、健康/元数据参与和痕迹同步都通过 `SourceSettingsSheet` 设置弹窗处理。
- 不要随意删 `dist` 和 `.build`，除非明确需要。打包脚本会更新产物。
- 如果运行 `swift run` 因用户缓存权限失败，可直接运行 `.build/debug/MediaLibChecks`。之前沙盒下 `swift run MediaLibChecks` 可能会因 `/Users/again/.cache/clang/ModuleCache` 权限失败。
- `scripts/package_dmg.sh` 是已批准前缀，可运行。它会生成图标、release build、app、dmg。
- `swift build` 是已批准前缀，可运行。
- 代码里仍有 OpenGL 相关 deprecated warning，当前不阻塞构建；`AudioMetadataReader` 已改用 AVFoundation async load API。
- 当前不是 git 仓库，不能依赖 `git status` 查看改动。

## 最近一次验证结果

最近一次完成验证（2026-06-08）：

- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`：通过
- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks`：`MediaLibChecks passed`
- `scripts/package_dmg.sh`：通过，已刷新 `dist/MediaLib.dmg`
- `/private/tmp/MediaLib-package/MediaLIB.app`：strict codesign verify 通过
- `dist/MediaLib.dmg`：`hdiutil verify` 有效
- `dist/MediaLIB.app/Contents/MacOS/mpv`：不存在，确认已不再打包完整 mpv 可执行文件
- `dist/MediaLIB.app/Contents/Frameworks/libmpv.2.dylib`：存在，依赖会随 App 复制并改写为 `@loader_path/...`
- `/private/tmp/MediaLib-package/MediaLIB.app`：约 92M
- `dist/MediaLIB.app`：约 92M
- `dist/MediaLib.dmg`：约 38M

产物：

- `dist/MediaLIB.app`
- `dist/MediaLib.dmg`

## 12. 2026-06-05 UI 修正进度

最新补充 2（历史记录）：封面 glow 曾从“拉伸模糊封面”改为“大透明画布中心封面扩散”。该路径已在 2026-06-06 被当前 `AlbumBlurredCoverGlowLayer` 三层 image-based glow 主路径替代，旧 `AlbumSoftBloomGlow`、`AlbumBloomImageBake` 和 `MusicBackdropBlur` 已删除；后续不要按本段旧实现继续开发。

最新补充：系统配色已拆分为系统蓝、系统青、系统靛蓝、系统紫、系统粉、系统橙、系统湖水、系统绿、系统石墨和自定义。旧 `classic/ocean/rose/mint/graphite` raw value 保留以兼容历史设置，新增 `indigo/purple/orange/green`。底色 seed 统一收敛到低饱和系统浅灰，强调色使用 Apple 常用系统色方向；`AppColors.ResolvedColorSet` 的页面底、卡片底、输入框底、wash、glass tint、solar edge、图标/强调渐变和 prominent 按钮对比也已二次精调。后续如继续调色，优先改 `AppThemePreset.seedHex` 和 `AppColors.ResolvedColorSet`，不要在单个页面硬编码主题色。

本轮围绕用户截图中的音乐展开页过曝和通用 UI 观感做第一轮修正：

- `MusicPlayerMetalBackdropView.swift`：保留 L0 shader 光斑数量、位置和 reach，下调 static/ambient/nearField 的 screen 叠加强度。
- `MusicPlayerView.swift`：降低封面 plusLighter bloom、封面边缘彩色描边、低分辨率 CALayer glow 和 ring stroke，优先解决封面周边黄白过曝。
- `AppColors.swift`：`LiquidGlassButtonStyle(prominent:)` 改成主题蓝色玻璃实按钮、白字、轻高光；新增 `AppMotion.sidebarSelection`。
- `AppSettings.swift`：配色预设展示名/种子色调成系统蓝、Aqua 蓝、Apple 粉、湖水绿、石墨，保留 raw value 兼容旧设置。
- `ContentView.swift`：左侧栏行级选中反馈改为 0.10s ease-out。

已验证：

- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` 通过。
- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MediaLibChecks` 通过。

待复核：

- 进入音乐展开界面点击播放，肉眼确认封面发光是否还偏曝；如仍偏亮，优先继续微调 `MusicPlayerMetalBackdropView.swift` 的 nearField / ambient alpha，以及 `AlbumBlurredCoverGlowLayer` 的三层 opacity、maxAlpha、brightness 和 blur 参数。
