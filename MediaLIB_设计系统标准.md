# MediaLIB 设计系统标准

文档状态：2026-06-09 更新。

本标准覆盖除音乐展开页以外的普通页面、列表、设置页、弹出页、菜单、工具条和播放器外部的业务控件。音乐展开页保留专辑色沉浸式设计，不套用本标准的页面底色和普通弹窗标题。

## 设计原则

- 视觉零牺牲：不通过删除模糊、阴影、动画、圆角、渐变、图片质量或交互反馈换取性能。
- 系统一致：普通页面使用暖白珍珠玻璃、左上环境光、低饱和鼠标边缘光；同一层级的控件使用同一套圆角、描边、内边距和反馈方式。
- 反馈明确：每个可点击控件至少具备 hover 或点按反馈。普通按钮、页头按钮、重复列表按钮和音乐图标按钮不使用按压缩放或阴影位移。
- 布局稳定：hover、按下、选中和禁用状态不能改变外层布局尺寸；海报/封面 hover 只作用于绘制区域，不推动文字或命中区域。
- macOS 习惯：会打开后续窗口、选择器或弹窗的按钮文案使用省略号；立即执行动作不使用省略号。系统文件选择、保存和警告面板保持原生不透明外观。
- 性能分层：长列表、网格和设置项使用静态玻璃；页头、搜索框、少量主操作按钮允许使用更厚的玻璃层。底部音乐栏存在时下层页面进入 balanced 玻璃性能档。

## 音乐展开页专辑取色玻璃规范

音乐展开页是唯一允许脱离普通暖白页面底色的沉浸式界面。它使用“专辑颜料底板 + 局部液态玻璃”架构，而不是整窗桌面毛玻璃。

- 整窗底板必须由 `MetalAlbumBackdropView` 或等价的不透明渲染层承载，shader 最终输出 alpha=1；不得新增全屏 `.behindWindow`、`.underWindow`、`.ultraThinMaterial` 或能透出桌面的背景。
- 封面只作为低频颜料场参与底板：读取约 160px 封面后降采样到约 38px 网格，再用中等半径高斯柔化并做轻对比清洁；不得把高分辨率封面直接大半径实时 blur 后铺满窗口，也不得把黑场/近黑边缘当成发光色源。黑色只能参与深度、遮光和干净阴影，不得被抬成彩色光。
- 背景 shader 的白色 veil 只是极薄空气感总闸，不能承担主体亮度；主体色来自封面低频颜料场与经清洁化的小幅色相和声场，二者同源但方向不能完全照抄。出图彩度补偿保持克制，亮区进一步降彩，高光继续 clamp 到低于纯白，避免浅色封面变白板或彩色封面比原封面更艳。
- 歌词卡、控制栏和收起按钮使用同源局部中性玻璃：薄白 frost、`.hudWindow/.withinWindow` material、中性 tint、微纹理、`LyricsCardEffectLayerView`、顶部高光、底部暗线、中性发丝描边和中性阴影按同一顺序叠加；玻璃材质本身不改为专辑色实底，但静态边缘光、指针高光、`AlbumLightSpillOverlay` 和中心舞台光都应使用专辑 glow 的低饱和 tint。白色只保留很薄的 specular，高光主色应来自专辑光，避免不同封面下玻璃泛白。
- 歌词卡使用 `centerClarity`：卡片中心区域降低雾、暗 tint 和纹理，上下边缘保持厚度；当前行居中清晰，非当前行只通过透明度、距离 blur 和上下羽化拉开景深，不通过大幅字号跳变表达层级。
- 歌词卡中心舞台光必须是宽、软、低峰值的专辑色光池，位于文字层下方；白色只允许作为极低透明度镜面高光，不得冲淡当前歌词颜色。上下边缘可以略增加磨砂和景深，但中心播放行附近应更通透。
- 同时间戳歌词行不能一概合并：日文原文与中文翻译这类双语翻译对必须保留为相邻独立行并维持歌词文件显示顺序；播放和自动滚动锚点优先选择含假名的日文原文，翻译行作为伴随行低模糊显示；完全重复文本仍应去重，真正同一句分段才可合并。
- 歌词景深基础距离 blur 可保持 `[0, 0.9, 2.1, 3.4, 5.0]`，但额外边缘位置 blur 应保持克制，当前上限增量约 `1.35`；实际观感以“远行可感知但不糊成雾块”为准。
- 用户手动拖动或滚轮浏览歌词时，远离当前行的 blur 必须立即降到 0，只保留透明度层级；停止浏览后保持约 4 秒清晰阅读窗口，再按 `lyricBrowseBlurProgress` 渐进恢复自动居中和景深。
- 无歌词或纯音乐状态仍保留完整歌词卡，不隐藏面板；空态内容居中显示在同一舞台光和玻璃中心内，右上角可保留获取歌词入口。
- 封面光分两层：封面自身使用预烘焙 image-based glow，底层背景继续通过封面复制光和 Metal 色场表达专辑氛围；前景歌词卡、控制栏和收起按钮作为中性玻璃浮在其上，只接受方向化的外部受光，不把受光颜色烘进玻璃底材质。封面 glow 烘焙必须用亮度门控降低黑色权重，黑色只形成深度阴影，不向外发光。
- 切歌时保留旧 `albumPalette` 和旧纹理直到新取色/纹理就绪，避免整窗闪成 fallback 灰底。所有持续动态和 pointer 采样必须尊重 Reduce Motion，并在窗口不可见或应用后台时暂停。
- 底板饱和度可以小幅补偿玻璃层造成的视觉降彩，但只能沿 `paintPalette` 的轻饱和/vibrance、角色色清洁上限和 shader `kChromaBoost` 微调；不得回到高饱和大面积色块，也不得让底板比封面更抢眼。

## 配色 Token 标准

设置页只提供 5 套精调配色与自定义入口：清蓝、珊瑚、青柠、暖杏、夜幕。旧版冰璃、石墨、紫、粉、靛蓝、高饱和绿等 raw value 保留用于历史设置解码，但不再作为可选入口展示；旧值会被解析到新的现代色板。默认主题为清蓝。

### 主题总览

| 主题 | 对应方向 | 适用场景 | 设计说明 |
| --- | --- | --- | --- |
| 清蓝 | Apple Clean Blue | 默认主题、首页、媒体库、设置页 | 以更克制的 macOS 蓝作为强调色，页面底保持低饱和浅灰蓝，最接近 Finder / TV / Music 的原生综合气质。 |
| 珊瑚 | Soft Coral | 音乐、歌单、轻快首页 | 珊瑚红偏年轻但不霓虹，适合更有活力的日常媒体库。 |
| 青柠 | Clean Lime | 歌单、音乐库、轻松浏览 | 低饱和青柠绿提供多巴胺感，避免荧光绿造成疲劳。 |
| 暖杏 | Fresh Apricot | 音乐、专辑、个人收藏 | 以浅杏和蜂蜜橙替代旧暖黄，干净温和但不老气。 |
| 夜幕 | OLED Night | 夜间播放、暗室观影、深色模式优先 | 深色外观使用 `#0B0D10` 蓝黑基底；浅色外观也保持更冷静的蓝黑调性，与清蓝拉开。 |

### 完整色值

| 主题 | Token | Light Mode | Dark Mode |
| --- | --- | --- | --- |
| 清蓝 | Primary | `#2F7DE1` | `#5AA2F4` |
| 清蓝 | Secondary | `#6FB8ED` | `#7AC4F4` |
| 清蓝 | Accent | `#3B83E6` | `#70B4FA` |
| 清蓝 | Background | `#F6F8FC` | `#121820` |
| 清蓝 | Surface | `#FFFFFF` | `#1A222C` |
| 清蓝 | Elevated Surface | `#FFFFFF` | `#232C36` |
| 清蓝 | Border | `#D8DEE8` | `#344150` |
| 清蓝 | Text Primary | `#1D1D1F` | `#F5F5F7` |
| 清蓝 | Text Secondary | `#6E6E73` | `#A1A1AA` |
| 清蓝 | Success / Warning / Error | `#34C759` / `#FF9F0A` / `#FF3B30` | `#30D158` / `#FFD60A` / `#FF453A` |
| 珊瑚 | Primary | `#E86152` | `#F07A68` |
| 珊瑚 | Secondary | `#E79A8C` | `#D89A8F` |
| 珊瑚 | Accent | `#D85548` | `#FF8A78` |
| 珊瑚 | Background | `#FAF4F1` | `#1A1112` |
| 珊瑚 | Surface | `#FFFDFC` | `#241819` |
| 珊瑚 | Elevated Surface | `#FFFFFF` | `#30201E` |
| 珊瑚 | Border | `#EBD8D2` | `#47302D` |
| 珊瑚 | Text Primary | `#1D1D1F` | `#F5F5F7` |
| 珊瑚 | Text Secondary | `#746B67` | `#B8A5A0` |
| 珊瑚 | Success / Warning / Error | `#2FA463` / `#D18A2C` / `#D94F45` | `#5AD184` / `#E8B45C` / `#FF6B62` |
| 青柠 | Primary | `#739E45` | `#9CCB62` |
| 青柠 | Secondary | `#95B568` | `#ABC67B` |
| 青柠 | Accent | `#668F3C` | `#AAD970` |
| 青柠 | Background | `#F6F8F2` | `#10170F` |
| 青柠 | Surface | `#FEFFFB` | `#182116` |
| 青柠 | Elevated Surface | `#FFFFFF` | `#22301B` |
| 青柠 | Border | `#DDE8D0` | `#354627` |
| 青柠 | Text Primary | `#1D1D1F` | `#F5F7F1` |
| 青柠 | Text Secondary | `#67705F` | `#AAB89A` |
| 青柠 | Success / Warning / Error | `#2FA463` / `#C98732` / `#D74E45` | `#5AD184` / `#E6B866` / `#FF6B62` |
| 暖杏 | Primary | `#D88442` | `#EAA15A` |
| 暖杏 | Secondary | `#C79B68` | `#D8B286` |
| 暖杏 | Accent | `#C97535` | `#F1AD66` |
| 暖杏 | Background | `#FAF4EB` | `#19130E` |
| 暖杏 | Surface | `#FFFDF9` | `#231910` |
| 暖杏 | Elevated Surface | `#FFFFFF` | `#302214` |
| 暖杏 | Border | `#EADCC8` | `#493421` |
| 暖杏 | Text Primary | `#1D1D1F` | `#F7F1EA` |
| 暖杏 | Text Secondary | `#74685A` | `#BDAA94` |
| 暖杏 | Success / Warning / Error | `#2FA463` / `#D97928` / `#D74E45` | `#5AD184` / `#F0B468` / `#FF6B62` |
| 夜幕 | Primary | `#516FD8` | `#7893F2` |
| 夜幕 | Secondary | `#59677F` | `#8EA0C2` |
| 夜幕 | Accent | `#5B78E5` | `#86A3FF` |
| 夜幕 | Background | `#F2F4F8` | `#0C0E12` |
| 夜幕 | Surface | `#FFFFFF` | `#101216` |
| 夜幕 | Elevated Surface | `#FFFFFF` | `#171B21` |
| 夜幕 | Border | `#D5DAE6` | `#2B313A` |
| 夜幕 | Text Primary | `#1D1D1F` | `#F5F5F7` |
| 夜幕 | Text Secondary | `#636C7A` | `#9AA3AE` |
| 夜幕 | Success / Warning / Error | `#34C759` / `#FF9F0A` / `#FF3B30` | `#30D158` / `#FFD60A` / `#FF453A` |

### 层级规则

- App 主背景：优先 `AppColors.pageBackground` / `AppColors.background`，叠加一层静态左上环境光，不使用纯白或纯黑铺底。
- Sidebar 背景：使用系统 sidebar/list 背景语义和极低透明度主题 wash；选中态跟随 `AppColors.selectedGlassTint`，图标与文字必须有非颜色反馈。
- 内容区域背景：使用主题 Background 派生的暖白/石墨底；不要让页面背景比卡片更亮、更饱和。
- 顶部工具栏：使用 `PageHeader` 与 `HeaderControlGlassBackground`，控件下边界与标题对齐；搜索框不使用系统默认白底。
- 底部播放栏：保持一块厚白/深灰玻璃底，专辑色只裁剪在栏内做静态边缘氛围，进度和主播放按钮使用 Accent。
- 音乐展开页背景：由专辑色驱动，但必须先清洁化、降饱和、限制亮度，并与主题深浅外观融合；不要套普通页面 Background。
- 专辑/影片卡片背景：使用 `staticSurfaceBackground` 或 repeated surface；hover 只增强封面绘制层、描边或边缘光，不改变外层 frame。
- Hover：提高局部高光与描边透明度，`AppColors.pointerLightTint` 必须由当前主题左上光线与高亮色共同派生，默认图标、默认音乐封面和播放器外部氛围色也应优先使用主题派生色；禁止固定系统蓝、大面积实时 blur、scale 外层卡片或让文字位移。
- Selected：使用主题 Accent 或系统 accent 的低透明度底 + 明确图标/字重/描边；颜色不是唯一状态表达。
- Pressed：降低亮度或叠加短暂内阴影，不做按钮位移。
- Disabled：主文字降到 Text Secondary 的 45%-55% 透明度，图标同步降饱和，禁止只改颜色但仍像可点击。
- Now Playing：使用 Accent + 小型动效或频谱图标，背景保持克制；不要用整行高饱和发光。
- 播放进度条：轨道用 Border/Separator 派生，已播放段用 Accent；缓冲段使用 Secondary 低透明度。
- 音量条：视频、音乐和键盘音量调整统一使用感知曲线映射，低音量段变化更细，高音量段平滑推进；控件可以显示感知进度，但播放器和设置仍保存兼容的线性 0...1 音量。
- 浮窗通知：应用内轻量通知统一为顶部中央胶囊玻璃，由 `FloatingNoticeStack` / `FloatingNoticeCapsule` 承载；进入时从顶部向下滑入并轻微淡入，消失时向上收回。通知最多显示三条，支持手动关闭和自动消失。胶囊宽度必须由标题与说明文字的真实宽度决定，短文案明显收窄，长片名/路径/任务详情只在最大宽度内居中换行；左右图标与关闭按钮使用等宽槽位，保证文字视觉中心落在胶囊中心。任务类通知标题保持短句，具体对象放在说明行，禁止把完整任务名塞进标题撑宽浮窗。信息、成功、警告、错误和页面提示只改变图标与低透明度 tint，不改变胶囊形态；页面提示只写用户能直接理解的使用建议，并且同一页面提示只在首次进入时显示。需要确认或危险操作仍使用标准弹窗。
- 歌词高亮色：从专辑色清洁化后派生，亮度和饱和度夹在主题可读范围内；无可靠专辑色时回退 Accent。
- 海报/封面渐变背景：只能作为卡片内部或详情页局部氛围，先降饱和、降亮度、限制对比度，不把封面色大面积污染工具栏和列表。

### 媒体内容适配

- 海报和封面颜色不可控，普通 UI 色彩必须低饱和，避免与内容争抢视觉焦点。
- 动态封面色只允许用于背景氛围光、轻微渐变、歌词高亮、now playing 和播放器局部边缘光。
- 封面主色过亮、过暗、过饱和、偏脏灰棕或灰绿时，回退到当前主题 Accent 或经 HSB 清洁后的相邻安全色。
- 动态颜色按歌曲/专辑/海报 ID 缓存，切换内容时取消旧取色任务并校验当前 ID。
- 无封面音乐的默认图形应使用当前主题派生的玻璃渐变、唱片/音符和波形元素；不要复用视频默认封面，也不要写死蓝青渐变。

### 性能约束

- 长列表、网格、设置分组不使用 `.regularMaterial`、多层阴影、blendMode 或连续鼠标采样。
- 主题 token 在 `AppColors.activeTheme.didSet` 中一次性解析缓存；页面读取 `AppColors.primary`、`surface`、`textSecondary` 等只应是廉价读取。
- 背景氛围优先用静态渐变、预烤低分辨率图或 CoreAnimation/Metal 层按需绘制，不在 SwiftUI `body` 每帧重算颜色。
- 列表 cell 使用简单背景色 + hover/selected 状态；少量页头和播放器控件可以使用更厚的玻璃。
- 加载骨架和占位动效必须尊重 Reduce Motion；开启后保持静态高光，不启动无限 shimmer。

### SwiftUI Token 入口

当前代码入口为 `Sources/MediaLib/Views/AppTheme.swift` 与 `Sources/MediaLib/Views/AppColors.swift`。`AppTheme` 名称已被外观浅深设置占用，因此主题 token 命名为 `AppThemeTokens`：

```swift
struct AppThemeTokens: Equatable {
    var name: String
    var usage: String
    var primary: AppThemeColorToken
    var secondary: AppThemeColorToken
    var accent: AppThemeColorToken
    var background: AppThemeColorToken
    var surface: AppThemeColorToken
    var elevatedSurface: AppThemeColorToken
    var border: AppThemeColorToken
    var textPrimary: AppThemeColorToken
    var textSecondary: AppThemeColorToken
    var success: AppThemeColorToken
    var warning: AppThemeColorToken
    var error: AppThemeColorToken
}
```

页面迁移顺序：

1. 新代码禁止新增裸 `.blue`、`.purple`、`.pink`、`.orange`、`.white` 大面积填充或硬编码灰阶背景。
2. 普通页面背景改读 `AppColors.pageBackground` / `AppPageBackground`。
3. 卡片、设置分组、列表行统一读 `AppColors.surface`、`secondarySurface`、`border` 或既有 `staticSurfaceBackground`。
4. 文字优先用系统 `Color.primary` / `Color.secondary`；必须跨层级固定时才读 `AppColors.textPrimary` / `textSecondary`。
5. 主操作、播放进度、选中态、now playing 改读 `AppColors.accent` / `selectedGlassTint`，不要回退固定系统蓝。
6. 状态色统一读 `AppColors.success`、`warning`、`error`，同时配合图标、文案或形态。

### 模块建议

- 播放器底栏：背景保持单块 Surface/Elevated Surface 玻璃，Accent 只用于播放按钮、进度条和 now playing；专辑柔光必须裁剪在底栏内。
- 歌词页：背景继续由专辑色驱动，歌词已播放色从专辑色清洁化派生；无安全专辑色时回退当前主题 Accent。
- 视频详情页：大图、海报、剧照优先，信息面板使用 Surface，按钮使用 Accent；不要用高饱和渐变压过海报。
- 设置页：清蓝、夜幕或用户自定义效果最佳，分组卡片用 Surface，说明文字用 Text Secondary，危险操作用 Error + 图标/确认。
- 列表页：夜幕更适合深色浏览；行 hover 使用主题派生的低透明度 pointer light / Accent wash，不新增复杂材质。

### 不建议使用

- 紫色作为主色：会偏 Web3、游戏启动器或安卓播放器气质，且与当前 MediaLIB 蓝青品牌符号冲突。
- 高饱和荧光绿、荧光粉、霓虹青：长时间使用疲劳，和 Apple HIG 的系统色克制原则不一致。
- 纯黑 `#000000` 和纯白大面积铺底：深色下失去层级，浅色下刺眼；优先使用系统背景或近似 `#0B0D10` / `#F5F7FB`。
- 大面积多色渐变和赛博朋克蓝紫：会和海报/封面抢焦点，并增加廉价网页感。
- Material You 式整页取封面色污染：动态色只能作氛围，不可主导普通页面结构。

## 页面标准

- 页面背景统一使用 `AppPageBackground()`，保留暖白珍珠底和左上大范围环境光。
- 普通页面标题统一使用 `PageHeader`：左侧标题与图标，右侧操作区固定在同一行并与标题底部对齐。
- 页面外边距使用 `pageContainer()`，默认横向 32pt、纵向 28pt。
- 页面内工具条使用 `AppSurfaceToolbar`，内部按钮使用 `LiquidGlassButtonStyle`；打开后续流程的按钮使用省略号，例如“添加…”、“Emby 登录…”。
- 列表、网格、设置分组和重复卡片使用 `staticSurfaceBackground` 或 `GlassSurfaceRole.repeated`，不新增实时 material 或连续鼠标采样。

## 弹出页标准

- 普通编辑、确认、添加、重命名类弹窗使用 `AppSheetHeader`、`AppInfoNote`、`AppSheetActionFooter` 和 `appSheetChrome`。
- 弹窗宽度优先使用 `AppSheetMetrics.compactWidth`、`standardWidth`、`wideWidth`，不要随意手写新宽度；确实需要时只在当前弹窗局部声明。
- 弹窗标题使用 `title3.semibold`，不使用页面级 32pt 大标题。工作台类大弹窗可以保留 `PageHeader`。
- 底部操作区右对齐，取消在左、主操作在右；危险操作使用 destructive 语义并保持明确文案。
- 信息说明使用 `AppInfoNote`，语气简洁、平静、直接，不写内部实现术语或教程式长句。
- 设置页“关于软件”这类信息弹窗继续使用标准 `appSheetChrome`。页首图标和介绍文字放在同一横向信息组内，图标盒自身居中，右侧标题、简介和后续信息行保持左对齐；不要把软件名做成大字海报，也不要把图标和文字拆成两个不对齐的卡片。

## 控件标准

- 普通按钮：`LiquidGlassButtonStyle`；主操作使用 `prominent: true`。
- 页头按钮：通过 `PageHeader` 的操作区自动使用 `HeaderActionGlassButtonStyle`。
- 重复列表/行内小按钮：`RepeatedGlassButtonStyle`。
- 下拉菜单：`GlassMenuButton` 或 `.adaptiveMenuControl(selectedTitle:)`，宽度按当前选项文字自适应并预留箭头空间。
- 页头搜索框：`GlassSearchField` 宽度按占位或输入文字在最小/最大宽度间弹性计算；页面应设置克制的最大宽度，避免标题、操作按钮或窗口窄宽状态被挤压。
- 筛选胶囊：`GlassCapsuleControl`。大量胶囊可关闭连续 pointer edge，但必须保留轻量 hover/选中反馈。
- 输入框：`glassFormField` 或 `GlassSearchField`，避免系统默认白底和焦点环破坏玻璃层级。
- 关闭按钮：弹窗内使用带反馈的小型 `RepeatedGlassButtonStyle`，不要回到无反馈 `.plain` 图标。
- 低调图标/文字按钮：评分星星、展开全文、行内轻量文字链接等不适合加玻璃底的控件使用 `SubtleIconButtonStyle`，只通过透明度、亮度和饱和度反馈，不改变尺寸。
- 整行/整卡点击：搜索结果、健康提示、设置选项格等使用静态玻璃底并叠加 `repeatedSurfaceHover`，不要用外层 scale 或大阴影表达可点击。
- 详情返回：会从列表、海报、横向看板、搜索结果或健康中心进入详情的入口，应在打开前记录来源条目 ID，并给来源行或卡片稳定 `.id(item.id)`；返回时滚回原位置，不让用户丢失浏览上下文。
- 视频控制层：播放器按钮、文字和进度颜色应按内容亮度自适应黑/白高对比；可在打开时使用海报轻量取样，不做播放中逐帧采样。
- 音乐展开页不套普通页面背景，但歌词卡片、控制栏、弹层和收起按钮的玻璃质感必须集中复用 `FloatingLyricsGlass` / `LyricsCardEffectLayerView`。歌词卡片、控制栏和收起按钮要保持无色彩倾向的中性浮层；想提高通透感时优先微调 material opacity、低白度 frost、纹理、专辑色受光 tint 和 `centerClarity`，不要为某个组件单独新增第二套 blur、material、固定径向光、把专辑色做成玻璃底色实染，或连续全屏 pointer 采样。

## 文案标准

- 直接说用户会得到什么，少用“请先”“需要注意”等命令式口吻。
- 后台动作说明应明确“不修改用户媒体文件”“只更新 MediaLIB 索引”等安全边界。
- 打开流程的按钮加省略号：添加…、选择…、打开控制台…、从备份恢复…。
- 立即动作不加省略号：扫描全部、保存、创建、清除记录、立即备份。

## 验证清单

- 布局：标题、操作区、工具条、弹窗底部按钮未跳位。
- 视觉：玻璃层级、圆角、描边、左上高光和主按钮蓝色质感一致。
- 交互：每个按钮 hover 或点按有反馈；禁用状态不误导。
- 菜单：当前选项文字不截断；弹出菜单能容纳最长选项。右键菜单中可操作项应统一使用左侧图标，避免同一菜单内文字起点不齐。
- 文案：打开型动作使用省略号；立即动作不使用省略号。
- 系统面板：`NSOpenPanel`、`NSSavePanel`、`NSAlert` 保持原生不透明外观。
- 性能：长列表和网格没有新增大面积 material、shadow、blendMode 或连续 pointer 采样。
