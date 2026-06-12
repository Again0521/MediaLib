# MediaLIB 市场功能差距与实施计划

更新时间：2026-06-08

## 产品定位结论

MediaLIB 不适合在近期变成一台完整的家庭媒体服务器。相比 Plex、Emby、Jellyfin 这类 server-client 体系，MediaLIB 当前更有价值的方向是：

- 面向 macOS 的原生本地/NAS/Emby/Jellyfin/Plex 媒体库与高完成度播放器。
- 不移动用户文件、隐私优先、安装后单机可用。
- 视频、音乐、缓存、任务中心和播放器体验都在一个干净的桌面应用里闭环。

因此竞品对比后的优先级不是“什么都做”，而是先补齐本机媒体中枢的高频闭环：集合、版本、离线策略、章节图/自动标记、同步冲突、资料修正与跨设备状态。Live TV/DVR、插件生态和完整多用户服务器体系暂时只做架构预留。

## 竞品能力对照

| 能力领域 | 市面成熟能力 | MediaLIB 当前状态 | 差距判断 |
|---|---|---|---|
| 想看与首页发现 | Plex Watchlist 可聚合多来源、推荐可用来源，首页有围绕用户意图的 hubs | 已有本机想看、首页推荐、继续观看、下一集、Emby 顶层视频纳入首页，以及手动/远端已看后的想看自动清理 | 还缺跨来源“可观看来源”解释和推荐理由 |
| 手动/智能集合 | Plex 支持手动集合、智能集合、自动集合、集合内联显示；Kodi Smart Playlist 规则成熟 | 已有手动视频集合、集合内排序、拼贴封面、视频智能集合复合规则、集合发布到首页和音乐智能歌单基础规则 | 缺来源集合导入 |
| 多版本/播放版本 | Infuse/Plex 可把同片不同版本聚合并在播放时选择版本 | 当前 `MediaItem` 仍混合媒体实体与播放资源 | 需要 `MediaEntity` / `MediaAsset` 拆分，支持本地/远程/缓存/转码版本 |
| 离线缓存 | Plex/Emby/Infuse 支持离线下载、质量选择、进度与离线入口 | 已有 Emby/Jellyfin/远程视频缓存、质量选择、暂停/继续/取消、字幕同步、删除缓存、缓存筛选、首页离线标签、系列自动缓存订阅、自定义未看集数窗口、整季订阅、暂停订阅、订阅到期计划、局域网策略、Wi-Fi 实时判断、缓存占用显示和全局容量上限 | 缺 Plex 转码下载/字幕策略与非媒体服务器网络源下载策略 |
| 后台任务与维护 | Jellyfin 定时任务覆盖扫描、字幕、章节图/keyframes、数据库优化、缓存清理 | 已有持久化任务中心、扫描、Emby/Jellyfin 同步、封面预热、元数据补充、视频缓存、章节图手动预生成、一键清理和容量超限回收 | 缺可配置计划任务、失败重试策略和字幕下载任务 |
| 片头/片尾/章节 | Plex Credits Detection 可生成 credits markers；Jellyfin 有章节图/keyframes 任务 | 已有内嵌章节、手动片头/片尾、跳过入口、章节图/keyframes 预生成并供播放器悬浮预览复用；自动片头/片尾可从内嵌章节关键词生成待审核标记，确认后才参与跳过 | 缺更深入的音频/画面自动检测、章节图自动计划和失败重试 |
| 服务端连接 | Infuse 原生连接 Plex/Emby/Jellyfin，支持 Direct Mode / Library Mode 与进度/评分同步 | Emby 已成型；Jellyfin 第一阶段已复用 MediaBrowser API 接入登录、库选择、索引同步、播放/痕迹同步入口和独立目录；Plex 第一阶段已支持服务器 URL + Token 直连、库选择、索引同步、播放 URL、播放进度和已观看写回 | 缺 Plex Discover/OAuth、Plex 转码质量/字幕边界；Emby/Jellyfin 仍缺更明确的 Direct Mode / Library Mode 口径和更细的失败恢复 |
| 跨设备同步 | Infuse iCloud Sync 同步列表、历史、进度、评分、手动匹配等；Trakt 常用于跨客户端痕迹 | 已有 Emby 痕迹同步、Trakt 本机已看/想看推送、Trakt watched/watchlist 导入生成冲突、采用远端写入本机索引（含用户评级）、保留本地写回 Trakt、统一同步冲突表、冲突队列 UI 和远程连接器账号表 | 缺 iCloud 实际同步、评分冲突来源接入、隐私开关、失败恢复和 Plex/Jellyfin/Emby 更完整远端写回 |
| 多用户/档案 | Plex/Emby 有用户与访问控制；Emby Premiere 矩阵包含用户管理 | 当前按单用户本机库设计，仅保留保险库 PIN/Touch ID 隐私隔离；本地多档案入口和状态接管已移除 | 不做本地多档案，后续只在真实远程连接器或 iCloud 需要时重新评估授权边界 |
| 元数据可靠性 | Plex/Infuse 支持手动修正、Edit Metadata、Artwork、Extras；Kodi 支持 NFO 导入导出 | 已有 TMDB、NFO、音乐标签工作台、详情分类标签、一键补充、元数据修正历史、详情页撤销入口和设置页历史批次撤销 | 缺批量字段差异确认、手动匹配复用策略、预告片/Extras、人物详情 |
| 音乐体验 | Plexamp/Apple Music 类产品强调智能电台、响度、无缝、歌词与队列上下文 | 已有队列持久化、ReplayGain/R128、防削波、歌词逐字、智能歌单基础 | 缺相似歌曲电台、按情绪/年代/风格的自动混合、远程/随机队列无缝策略 |
| 插件生态 | Kodi/Jellyfin 通过插件扩展 provider、Live TV、外部服务 | 当前是封闭内置能力 | 近期只做 provider adapter 架构预留，不直接开放插件 |
| Live TV/DVR | Emby/Jellyfin/Kodi/Plex 均有 Live TV/PVR 体系 | 无 | 暂缓，超过当前单机媒体库边界 |

## 业务逻辑优化重点

### 1. 分离媒体实体与播放资源

当前 `MediaItem` 同时承担电影/剧集/音乐实体、播放文件、远程流和缓存副本。多版本、离线缓存、服务端转码和播放源优先级继续增加后，这会越来越难维护。

计划拆分：

- `MediaEntity`：标题、简介、人物、合集、分类、用户意图、资料源评分。
- `MediaAsset`：本地路径、远程 URL、缓存路径、版本名、分辨率、码率、音轨/字幕、可用性。
- `PlaybackMarker`：章节、片头、片尾、书签、自动检测来源和审核状态。

### 2. 建立集合模型

手动视频集合已有基础表、UI、集合内排序、由前几项自动生成的拼贴封面和首页发布；视频智能集合已支持媒体类型、状态、最近加入时间、年份、资料评分、用户评级、题材、来源、AND/OR 复合规则和首页发布。下一步应向统一 `MediaCollection` 收敛：

- 手动集合：用户显式添加/移除条目，并可在集合页按内部顺序置顶、上移、下移或置底；封面从内部条目海报派生。
- 智能集合：保存复合规则，不复制媒体条目。
- 来源集合：从 TMDB/Emby/Plex/Jellyfin 导入的服务端集合。
- 首页发布：已完成，集合可选择作为首页横向看板，默认关闭。

### 3. 缓存策略从“单次下载”升级为“离线计划”

已有缓存任务能下载、暂停、继续、删除，并能显示占用、设置全局容量上限；一键清理会先整理失效记录和无引用文件，再按已看/最近播放/创建时间回收超限缓存。系列自动缓存订阅基础已完成，可维护下一集、未看 3/5/10 集、自定义未看集数或全系列，并复用现有视频缓存任务。下一步继续把它扩展成更完整、可解释的离线计划：

- 系列订阅：下一集、未看 3/5/10 集、自定义未看集数、整季、全系列、手动暂停、到期计划、局域网策略和 Wi-Fi 实时判断已完成；下一步补按季批量策略和更细的失败恢复。
- 容量配额：全局上限基础版已完成；下一步补按来源/系列的配额和到期策略。
- 网络策略：仅 Wi-Fi、仅本机局域网、允许远程。
- 离线入口：首页“离线”标签已展示可播放缓存，后续补断网时自动突出缓存来源和可观看解释。

### 4. 后台任务可计划、可重试、可审计

任务中心已经持久化，但仍偏“当前任务列表”。下一步要增加：

- 计划任务：扫描、封面预热、字幕下载、章节图/keyframes、数据库优化、缓存清理。章节图/keyframes 已有手动后台任务，下一步补自动计划与失败重试。
- 重试策略：网络失败、权限失败、资料源限流分别处理。
- 结果审计：完成后可看到新增、更新、失败、跳过原因。

### 5. 服务同步需要冲突模型

Emby/Jellyfin 痕迹同步已经支持双向、单向和不同步，但未来接入 Plex/Trakt/iCloud 以及更深的远程冲突恢复后，必须记录：

- 字段级更新时间。
- 本次修改来源。
- 同步状态与失败原因。
- 默认合并策略与用户可见冲突队列。基础队列 UI 已完成，后续连接器需要把真实远端写入和失败恢复接上。

### 6. 元数据修正需要可撤销

一键拉取与工作台已经能补数据，但发布版更需要“放心试错”：

- 每次元数据覆盖生成修正记录。
- 支持对单个条目回滚到上一次。
- 批量操作前展示字段差异。
- 手动匹配结果进入历史，未来扫描优先复用。

## 实施编排

### Batch A：低风险高收益，优先实现

1. **主窗口最小宽度继续收窄**：已在 2026-06-08 从 1120 调到 1088，高度保持 720。
2. **集合模型第一步**：手动视频集合表、基础 UI、集合内排序、拼贴封面和首页发布已完成，支持加入集合、从集合移除、集合页和右键调整顺序。
3. **智能集合规则扩展**：已完成多条件 AND/OR、评分/评级/类型/年份/标签/来源条件。
4. **缓存容量与清理策略**：已完成基础版，设置页显示占用与全局容量上限，一键清理会回收已看或较久未播放的超限缓存，播放缓存会刷新最近访问时间。
5. **集合发布到首页**：已完成，手动集合和智能集合可选择发布为首页横向看板，默认关闭，保持首页清爽。
6. **Emby 同步库选择**：已完成。编辑 Emby 来源时可选择要纳入 MediaLIB 的服务器库，保留当前“全同步”默认。

### Batch B：需要 schema 与任务中心扩展

7. **离线订阅计划**：基础版继续补齐。系列可自动维护下一集、未看 3/5/10 集、自定义未看集数、当前整季或全系列，并在任务中心复用现有缓存任务；订阅支持暂停 7 天、“允许远程/仅局域网/仅 Wi-Fi”策略和 7/30/90 天到期计划，过期规则会自动从 MediaLIB 内部索引清理；首页“离线”标签已展示可播放缓存，后续补非 Emby 网络源下载策略和失败恢复。
8. **章节图/keyframes 后台任务**：第一步已完成。视频/系列右键可“预生成章节图”，任务中心按有限 bucket 生成进度条悬浮预览图，写入 `Caches/MediaLib/PreviewFrames` 并被播放器优先复用；后续补自动计划、失败重试和更完整的 storyboard/trickplay 审计。
9. **自动片头/片尾检测审核流**：基础版已完成。右键“检测片头片尾”通过后台任务分析内嵌章节关键词，生成待审核自动标记；播放器章节弹层确认后进入跳过逻辑，拒绝后保留用于重复候选抑制。下一步补音频/画面检测和跨集聚合置信度。
10. **元数据修正历史与撤销**：基础版已完成。元数据覆盖按 batch 记录字段旧值/新值、来源和撤销状态，详情页可撤销最近一次覆盖，设置页可查看历史批次并按批次撤销；下一步补批量应用前字段差异确认和手动匹配复用。
11. **同步冲突表**：基础版已完成。`sync_conflicts` 为 Emby/Plex/Jellyfin/Trakt/iCloud 共用字段级冲突队列，支持 pending/resolved/ignored 与 resolution；设置页已有用户可见冲突列表，可记录保留本地、采用远端、合并、都保留或忽略，其中采用远端已能把已看/想看/喜欢和用户评级写入 MediaLIB 内部索引；Trakt watched/watchlist 冲突选择保留本地时会写回 Trakt。下一步补评分冲突来源接入、失败恢复和 Plex/Jellyfin/Emby 更完整远端写回。

### Batch C：连接器与跨设备

12. **Jellyfin 连接器**：第一阶段已完成。复用 MediaBrowser API 与既有 Emby service 结构，支持 Jellyfin 登录、受限凭据保存、`jellyfin://` 来源、库选择、索引同步、独立目录、播放入口和播放/收藏/已观看痕迹同步；连接器账号会写入 `remote_connector_accounts`。后续补 Jellyfin 专属发现、多用户授权、Direct/Library 口径、字幕/转码边界和失败恢复。
13. **Plex 连接器**：第一阶段已完成。媒体源页可通过 Plex 服务器地址 + Plex Token 直连，写入 `plex://` 来源与连接器账号，支持库选择、索引同步、独立 Plex 目录、播放源刷新、播放进度和已观看写回；喜欢状态先保存在 MediaLIB 本机。后续补 plex.tv OAuth/Discover、Plex 转码质量、字幕/sidecar、评分/收藏语义和失败恢复。
14. **Trakt 同步**：双向第一阶段已完成。已有设备码连接、本地已看/想看推送到 Trakt，以及“从 Trakt 导入”入口；导入会拉取 watched movies/shows 和 watchlist，对已匹配 TMDB 的公开视频生成 watched/watchlist 同步冲突，用户采用远端后会写入 MediaLIB 内部索引，选择保留本地会把本机 watched/watchlist 写回 Trakt。后续补评分同步冲突、隐私开关和失败恢复。
15. **iCloud 同步**：provider 与连接器账号模型已预留；后续同步本机设置、手动匹配、集合、播放历史、评分和任务策略；服务端来源凭据不直接同步。
16. **本地用户档案**：已按当前产品方向移除。MediaLIB 回到单一全局本机状态，播放记录、播放次数、已看、喜欢、想看和评分都写入全局内部索引；旧 `local_user_profiles` / `profile_media_state` 表仅作为历史兼容承载，不提供设置页管理、侧栏切换或儿童档案隔离。

### Batch D：边界扩展，暂缓

17. **Live TV/DVR**：仅在播放器、连接器、任务中心和同步模型稳定后评估。
18. **插件/Provider Adapter**：先开放资料源 adapter 配置，不开放任意代码插件。
19. **WebDAV/SFTP/云盘直连**：在缓存策略和凭据模型稳定后再做。

## 每项验收原则

- 不移动、删除或重命名用户媒体文件。
- 不牺牲现有 UI、动画、玻璃材质、图片质量和播放器能力。
- 新增远程同步必须可关闭，并清晰标注数据去向。
- 新增后台分析必须可取消、可恢复、可查看失败原因。
- 涉及数据库结构必须提升 schema version，迁移前使用 SQLite backup API。
- 每项功能都需包含检查、文档和 DMG 交付。

## 官方参考

- Plex Universal Watchlist: https://support.plex.tv/articles/universal-watchlist/
- Plex Collections: https://support.plex.tv/articles/201273953-collections/
- Plex Downloads: https://support.plex.tv/articles/downloads-overview/
- Plex Credits Detection: https://support.plex.tv/articles/credits-detection/
- Emby Offline Access: https://support.emby.media/support/articles/Offline-Access.html
- Emby Premiere Feature Matrix: https://emby.media/support/articles/Premiere-Feature-Matrix.html
- Jellyfin Tasks: https://jellyfin.org/docs/general/server/tasks/
- Jellyfin Live TV: https://jellyfin.org/docs/general/server/live-tv/setup-guide/
- Jellyfin Plugins: https://jellyfin.org/docs/general/server/plugins/
- Infuse Plex/Emby/Jellyfin: https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin
- Infuse iCloud Sync: https://support.firecore.com/hc/en-us/articles/115000070773-iCloud-Sync
- Infuse Downloading Files: https://support.firecore.com/hc/en-us/articles/215091037-Downloading-Files
- Kodi Smart Playlists: https://kodi.wiki/view/Smart_playlists
- Kodi PVR: https://kodi.wiki/view/PVR
- Kodi Add-ons: https://kodi.tv/addons/
