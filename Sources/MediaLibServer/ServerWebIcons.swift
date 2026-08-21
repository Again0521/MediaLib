import Foundation

/// The product's single icon vocabulary.
///
/// It replaces two unrelated icon enums (a 24px stroked set in the navigation and
/// a 48px filled, multi-coloured set in the page header) plus the ~40 Unicode and
/// emoji glyphs that used to stand in for icons.  Those glyphs rendered at
/// whatever size and weight the visitor's platform font decided, could not take a
/// colour, and read as placeholder art.
///
/// Every glyph is drawn on the same grammar so they sit together as a family:
/// a 24×24 box, 1.8px strokes, round caps and joins, `currentColor`, optical
/// balance rather than geometric centring.  Sizing comes from the `.icon-*`
/// classes — the page CSP forbids inline `style` attributes.
enum ServerWebIcon: String {
    // Navigation & structure
    case home, search, library, grid, list, film, series, anime, documentary, show
    case music, album, artist, playlist, photos, people, collections, folder
    case queue, history, clock, source, dashboard, users, account, settings, vault

    // Actions
    case play, pause, skipBack, skipForward, seekBack, seekForward
    /// 常规的快退/快进：双三角。`seekBack`/`seekForward` 是"重播 N 秒"的环形箭头，
    /// 读者在播放键两侧期待的是这一对。
    case rewind, fastForward
    case add, plusCircle, close, check, checkCircle, refresh, download, upload
    case edit, trash, more, filter, sort, external, link, share, key, logout

    // State & meaning
    case heart, heartFilled, bookmark, bookmarkFilled, star, starFilled, circle
    case eye, eyeOff, info, warning, error, success, shield, activity, sparkles

    // Chrome
    case chevronLeft, chevronRight, chevronUp, chevronDown
    case arrowLeft, arrowRight, arrowUp, arrowDown
    case sun, moon, display, menu, sidebar
    case volumeOn, volumeOff, fullscreen, fullscreenExit, pictureInPicture, speed
    case image, video, subtitles, cast, server, database, wifiOff
    /// 传输模式键。此前只存在于 `app-shell.js` 里的三条手写实心路径，
    /// 和这里的线性族不是同一种画法——底栏上因此有两枚外来的图标。
    case shuffle, repeatAll, repeatOne

    /// Every glyph in the family, for the checks that must not miss one.
    ///
    /// 不是 `CaseIterable`：那会把五对别名各数一次，让"每枚字形都要能解析"这类
    /// 断言看起来覆盖了 95 个，实际只覆盖了 90 张画。这里给的就是全部的画。
    static let allGlyphs: [ServerWebIcon] = [
        .home, .search, .library, .grid, .list, .film, .series, .anime, .documentary, .show,
        .music, .album, .artist, .playlist, .photos, .people, .collections, .folder,
        .queue, .history, .clock, .source, .dashboard, .users, .account, .settings, .vault,
        .play, .pause, .skipBack, .skipForward, .seekBack, .seekForward, .rewind, .fastForward,
        .add, .plusCircle, .close, .check, .checkCircle, .refresh, .download, .upload,
        .edit, .trash, .more, .filter, .sort, .external, .link, .share, .key, .logout,
        .heart, .heartFilled, .bookmark, .bookmarkFilled, .star, .starFilled, .circle,
        .eye, .eyeOff, .info, .warning, .error, .shield, .activity, .sparkles,
        .chevronLeft, .chevronRight, .chevronUp, .chevronDown,
        .arrowLeft, .arrowRight, .arrowUp, .arrowDown,
        .sun, .moon, .display, .menu, .sidebar,
        .volumeOn, .volumeOff, .fullscreen, .fullscreenExit, .pictureInPicture, .speed,
        .image, .video, .subtitles, .cast, .server, .database, .wifiOff,
        .shuffle, .repeatAll, .repeatOne
    ]

    enum Size: String {
        case xs = "icon-xs"
        case sm = "icon-sm"
        case md = "icon-md"
        case lg = "icon-lg"
        case xl = "icon-xl"
    }

    /// 同一枚字形的两种画法。
    ///
    /// `.line` 是全族的默认语法：24 栅格、1.8 描边、`currentColor`。
    /// `.duotone` 在它底下多垫一层同色低透明度的**面**，只用在 ≥24px 的场景
    /// （页头标题图标、空态、统计格、品牌标）。小尺寸上那层面会和线条糊在一起，
    /// 反而比纯线条更脏，所以它不是一个全局开关。
    ///
    /// 关键是这一层**不改 svg 元素自己的属性**：`viewBox` 和 `stroke-width`
    /// 原样保留，面层作为一个自带 `fill`/`stroke` 的 `<g>` 写在内容里。图标族的
    /// 栅格与描边契约因此仍然只有一套。
    enum Variant {
        case line
        case duotone
    }

    /// Renders the glyph.
    ///
    /// Icons are hidden from assistive technology by default: an icon beside a
    /// visible label would otherwise be announced twice.  Pass `label` only when
    /// the icon is the *only* content of its control, in which case it becomes an
    /// `img` with an accessible name.
    static func render(
        _ icon: ServerWebIcon,
        size: Size = .md,
        variant: Variant = .line,
        extraClass: String = "",
        label: String? = nil
    ) -> String {
        let variantClass = (variant == .duotone && icon.duotoneBody != nil) ? "icon-duotone" : ""
        let classes = (["icon", size.rawValue] + [variantClass, extraClass].filter { !$0.isEmpty })
            .joined(separator: " ")
        let accessibility: String
        if let label, !label.isEmpty {
            accessibility = #"role="img" aria-label="\#(ServerWebHTML.escape(label))""#
        } else {
            accessibility = #"aria-hidden="true" focusable="false""#
        }
        let fill = icon.isSolid ? "currentColor" : "none"
        let stroke = icon.isSolid ? "none" : "currentColor"
        var content = icon.body
        if variant == .duotone, let shade = icon.duotoneBody {
            content = #"<g fill="currentColor" stroke="none" class="icon-duotone-shade">\#(shade)</g>"# + content
        }
        return #"<svg class="\#(classes)" viewBox="0 0 24 24" fill="\#(fill)" stroke="\#(stroke)" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" \#(accessibility)>\#(content)</svg>"#
    }

    func html(size: Size = .md, variant: Variant = .line, extraClass: String = "", label: String? = nil) -> String {
        ServerWebIcon.render(self, size: size, variant: variant, extraClass: extraClass, label: label)
    }

    // MARK: - Icon tiles

    /// 图标底板的三档尺寸。见 tokens 的 `--icon-tile-size-*`。
    enum TileSize: String {
        case sm = "ui-icon-tile-sm"
        case md = "ui-icon-tile-md"
        case lg = "ui-icon-tile-lg"

        fileprivate var glyph: Size {
            switch self {
            case .sm: return .md
            case .md, .lg: return .lg
            }
        }
    }

    /// 底板的四种取向：强调色淡底（默认）、中性淡底、实心品牌渐变、识别色淡底。
    ///
    /// `.tint` 自己不带颜色——它读祖先上的 `data-tint="…"`。所以「这一栏是音乐」
    /// 只需要在区块上声明一次，里面的底板、胶囊、徽章一起跟着走；没有 `data-tint`
    /// 的落点则与 `.accent` 完全一致。
    enum TileTone: String {
        case accent = "ui-icon-tile-accent"
        case quiet = "ui-icon-tile-quiet"
        case brand = "ui-icon-tile-brand"
        case tint = "ui-icon-tile-tint"
    }

    /// 识别色的域。取值即 `data-tint` 的属性值，令牌层按同名 `[data-tint="…"]`
    /// 投出 `--tint-glyph` / `--tint-fill-a` / `--tint-fill-b` / `--tint-border`。
    ///
    /// 只上非交互面（图标底板、区块头、概览格、空态、分区胶囊）。按钮、链接、
    /// 焦点环、选中态仍然只有 `--accent`——「蓝＝可点」是全站唯一的可点性线索。
    enum Tint: String, CaseIterable {
        case video, music, photo, vault, admin, editorial, neutral

        /// 直接吐出属性片段，省得每个调用点自己拼 `data-tint="…"`。
        var attribute: String { #" data-tint="\#(rawValue)""# }
    }

    /// 带底板的图标。
    ///
    /// 此前产品里有六处"圆角方块 + 图标"的容器（页头 52×58、品牌标 34、空态 52、
    /// 首页统计 34、仪表盘 36、移动端页头 44×48），每一处的尺寸、圆角、内高光都
    /// 是各写各的硬编码。它们讲的是同一件事，所以现在只有这一个构建器。
    ///
    /// 底板永远是装饰：它对辅助技术不可见，可读的名字由它旁边的标题承担。
    static func tile(
        _ icon: ServerWebIcon,
        size: TileSize = .md,
        tone: TileTone = .accent,
        extraClass: String = ""
    ) -> String {
        let classes = (["ui-icon-tile", size.rawValue, tone.rawValue] + (extraClass.isEmpty ? [] : [extraClass]))
            .joined(separator: " ")
        let glyph = render(icon, size: size.glyph, variant: .duotone)
        return #"<span class="\#(classes)" aria-hidden="true">\#(glyph)</span>"#
    }

    // MARK: - Sharing the drawings with the page scripts

    /// The glyph's inner SVG markup, for the scripts that build icons in the DOM.
    ///
    /// 四个页面脚本此前各自抄了一份路径数据，其中两份还是**实心 Material 画法**
    /// ——底栏的播放键和这里的 `.play` 根本不是同一个形状。脚本改不了
    /// `ServerWebIcon`，所以只能反过来：由 Swift 把这里的字形插值进脚本常量，
    /// 路径数据全产品只存在这一份。
    ///
    /// 脚本侧仍必须用 `createElementNS` 组装元素——`innerHTML` 被两条测试禁掉了
    /// ——所以这里交出去的是内容，不是整个 `<svg>`。
    static func scriptGlyphBody(_ icon: ServerWebIcon) -> String {
        icon.body
    }

    /// Whether the glyph is drawn as a solid shape rather than a stroke.
    ///
    /// 脚本要靠它决定给元素设 `fill` 还是 `stroke`；判断逻辑同样只该有一份。
    static func scriptGlyphIsSolid(_ icon: ServerWebIcon) -> Bool {
        icon.isSolid
    }

    /// One element of a glyph, as structured data rather than markup.
    struct Element {
        let tag: String
        let attributes: [(name: String, value: String)]
    }

    /// Parses a glyph body back into elements.
    ///
    /// 这里能用一个二十行的扫描器而不是一个 SVG 解析器，是因为输入不是任意
    /// SVG：`body` 全部由本文件自己写，格式收得极紧——一律 `<tag a="1" b="2"/>`，
    /// 没有嵌套、没有文本节点、没有单引号、没有实体。任何一条不合这个格式的
    /// 字形都会解析成空，并被 `testEveryIconParsesIntoScriptElements` 抓住。
    static func elements(of icon: ServerWebIcon) -> [Element] {
        var result: [Element] = []
        var rest = Substring(icon.body)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let inner = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]

            // `<g …>` 分组只出现在双色面层里，而面层不参与脚本渲染。
            guard let tagEnd = inner.firstIndex(where: { $0 == " " || $0 == "/" }) else { continue }
            let tag = String(inner[inner.startIndex..<tagEnd])
            guard !tag.isEmpty, !tag.hasPrefix("/") else { continue }

            var attributes: [(name: String, value: String)] = []
            var scan = inner[tagEnd...]
            while let equals = scan.firstIndex(of: "=") {
                let name = scan[scan.startIndex..<equals]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let afterEquals = scan.index(after: equals)
                guard afterEquals < scan.endIndex, scan[afterEquals] == "\"",
                      let valueEnd = scan[scan.index(after: afterEquals)...].firstIndex(of: "\"")
                else { break }
                let value = String(scan[scan.index(after: afterEquals)..<valueEnd])
                if !name.isEmpty { attributes.append((name, value)) }
                scan = scan[scan.index(after: valueEnd)...]
            }
            result.append(Element(tag: tag, attributes: attributes))
        }
        return result
    }

    /// Emits a JavaScript helper that draws this icon family in the DOM.
    ///
    /// 四个页面脚本此前各自抄了一份路径数据，其中两份还是实心 Material 画法——
    /// 底栏的播放键和页面上的 `.play` 因此根本不是同一个形状。脚本没法 import
    /// Swift，所以反过来由 Swift 把字形插值进脚本：路径数据全产品只有这一份，
    /// 抄错和漏改都不再可能。
    ///
    /// 交出去的是**结构化数据加一个 createElementNS 组装器**，不是一段 HTML：
    /// 两条测试禁止脚本里出现 `innerHTML`，而那正好也是对的做法。
    ///
    /// 生成的作用域内可用：`medialibIcon(name, className)` → `<svg>`。
    static func scriptHelper(for icons: [ServerWebIcon]) -> String {
        let entries = icons.map { icon -> String in
            let parts = elements(of: icon).map { element -> String in
                let attributes = element.attributes
                    .map { #""\#($0.name)":"\#($0.value)""# }
                    .joined(separator: ",")
                return #"["\#(element.tag)",{\#(attributes)}]"#
            }.joined(separator: ",")
            return #""\#(icon.rawValue)":{"solid":\#(icon.isSolid),"parts":[\#(parts)]}"#
        }.joined(separator: ",")

        return """
        const MEDIALIB_ICON_NS = 'http://www.w3.org/2000/svg';
        const MEDIALIB_ICONS = {\(entries)};
        const medialibIcon = (name, className) => {
          const spec = MEDIALIB_ICONS[name];
          const svg = document.createElementNS(MEDIALIB_ICON_NS, 'svg');
          svg.setAttribute('class', className || 'icon icon-md');
          svg.setAttribute('viewBox', '0 0 24 24');
          svg.setAttribute('fill', spec && spec.solid ? 'currentColor' : 'none');
          svg.setAttribute('stroke', spec && spec.solid ? 'none' : 'currentColor');
          svg.setAttribute('stroke-width', '1.8');
          svg.setAttribute('stroke-linecap', 'round');
          svg.setAttribute('stroke-linejoin', 'round');
          svg.setAttribute('aria-hidden', 'true');
          svg.setAttribute('focusable', 'false');
          if (!spec) return svg;
          for (const [tag, attributes] of spec.parts) {
            const node = document.createElementNS(MEDIALIB_ICON_NS, tag);
            for (const key of Object.keys(attributes)) node.setAttribute(key, attributes[key]);
            svg.appendChild(node);
          }
          return svg;
        };
        """
    }

    /// A handful of glyphs read as "on" states (a filled heart, a filled star) and
    /// are drawn solid so the on/off pair is unmistakable at a glance.
    private var isSolid: Bool {
        switch self {
        case .heartFilled, .starFilled, .bookmarkFilled, .play, .pause, .rewind, .fastForward:
            return true
        default:
            return false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private var body: String {
        switch self {
        case .home:
            return #"<path d="M3 10.5 12 3l9 7.5"/><path d="M5.5 9.5V21h13V9.5"/><path d="M9.5 21v-6.5h5V21"/>"#
        case .search:
            return #"<circle cx="11" cy="11" r="7"/><path d="m16.5 16.5 4 4"/>"#
        case .library:
            return #"<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M7.5 8.5h9M7.5 12h9M7.5 15.5h5.5"/>"#
        case .grid:
            return #"<rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/>"#
        case .list:
            return #"<path d="M4 6.5h.01M4 12h.01M4 17.5h.01M8.5 6.5H20M8.5 12H20M8.5 17.5H20"/>"#
        case .film:
            return #"<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M8 4v16M16 4v16M3 9.5h5M16 9.5h5M3 14.5h5M16 14.5h5"/>"#
        case .series:
            return #"<rect x="2.5" y="7" width="19" height="13" rx="2.5"/><path d="m8 3.5 4 3.5 4-3.5"/>"#
        case .show:
            // 综艺此前和「剧集」共用同一台带天线的电视，于是侧栏里两条分类是同
            // 一枚图标。综艺的共同点是台上有人在讲——话筒比电视机更能指认它。
            return #"<rect x="9" y="2.5" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0"/><path d="M12 18v3.5M8.5 21.5h7"/>"#
        case .anime:
            return #"<path d="M12 3.5c4.7 0 8.5 3.2 8.5 7.2 0 4-3.8 7.2-8.5 7.2-.9 0-1.8-.1-2.6-.3L5 20l.9-3.3C4 15.4 3.5 13.4 3.5 10.7c0-4 3.8-7.2 8.5-7.2Z"/><path d="M9 10.5h.01M15 10.5h.01"/>"#
        case .documentary:
            return #"<path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h6.9a1.5 1.5 0 0 1 1.5 1.5V20l-4.9-2.4L4 20Z"/><path d="M17 4h1.5A1.5 1.5 0 0 1 20 5.5V20"/>"#
        case .music:
            return #"<path d="M9 18V6l11-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>"#
        case .album:
            return #"<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2.5"/>"#
        case .artist:
            return #"<circle cx="12" cy="8" r="3.5"/><path d="M5 20.5a7 7 0 0 1 14 0"/>"#
        case .playlist:
            return #"<path d="M4 6.5h11M4 11h11M4 15.5h6"/><path d="M17 19V9.5l4-1V17"/><circle cx="15.6" cy="19" r="1.6"/>"#
        case .photos:
            return #"<rect x="3" y="4" width="18" height="16" rx="2.5"/><circle cx="8.5" cy="9" r="1.6"/><path d="m4 17.5 4.8-4.6 3 2.9 2.4-2.3 5.8 5"/>"#
        case .people, .users:
            return #"<circle cx="9" cy="8" r="3.2"/><path d="M3.5 20v-1.8a5.5 5.5 0 0 1 11 0V20"/><path d="M16.5 5.2a3.2 3.2 0 0 1 0 5.9M17.5 13.4a5 5 0 0 1 3 4.6V20"/>"#
        case .collections:
            return #"<rect x="3.5" y="6.5" width="17" height="13" rx="2.5"/><path d="M6.5 6.5V4.8M17.5 6.5V4.8M7 3.5h10"/>"#
        case .folder:
            return #"<path d="M3.5 6.5A1.5 1.5 0 0 1 5 5h4l2 2.5h8a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5Z"/>"#
        case .queue:
            return #"<path d="M4 6.5h12M4 11h12M4 15.5h7"/><path d="M17.5 14v7M14 17.5h7"/>"#
        case .history:
            return #"<path d="M3.5 12a8.5 8.5 0 1 0 2.8-6.3L3.5 8.2"/><path d="M3.5 3.6v4.6h4.6"/><path d="M12 7.5V12l3 1.8"/>"#
        case .clock:
            return #"<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5.2l3.2 1.9"/>"#
        case .server:
            return #"<rect x="3" y="4.5" width="18" height="6.5" rx="2"/><rect x="3" y="13" width="18" height="6.5" rx="2"/><path d="M6.8 7.8h.01M6.8 16.3h.01"/>"#
        case .source:
            // 媒体源不是机架，是"接进来的一块盘"。和 `.server` 共用机架图形时，
            // 设置页里的「媒体源」和状态页里的「服务器」看上去是同一个东西。
            return #"<rect x="2.5" y="6.5" width="12.5" height="11" rx="2.5"/><path d="M6 10.5h.01M6 14h.01"/><path d="M15 12h6.5"/><path d="m18.5 9 3 3-3 3"/>"#
        case .database:
            return #"<ellipse cx="12" cy="6" rx="7.5" ry="3"/><path d="M4.5 6v12c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3V6"/><path d="M4.5 12c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3"/>"#
        case .dashboard:
            return #"<path d="M4 13a8 8 0 0 1 16 0"/><path d="M12 13 15.5 9"/><circle cx="12" cy="13" r="1.4"/><path d="M4 13v3.5h16V13"/>"#
        case .account:
            return #"<circle cx="12" cy="8" r="3.8"/><path d="M4.5 20.5a7.5 7.5 0 0 1 15 0"/>"#
        case .settings:
            return #"<circle cx="12" cy="12" r="3"/><path d="M19.4 14.5a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5v.2a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1h.2a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1Z"/>"#
        case .vault:
            return #"<rect x="4.5" y="10" width="15" height="10.5" rx="2.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/><path d="M12 14v2.5"/>"#
        case .key:
            // 保险库是一把挂锁，钥匙是钥匙。两者共用挂锁图形时，"登出/凭据"这类
            // 用 `.key` 的地方会被读成"这里也有个保险库"。
            return #"<circle cx="8" cy="8" r="4.5"/><path d="m11.4 11.4 8.1 8.1"/><path d="m17 17 2-2M14.6 14.6l2-2"/>"#
        case .play:
            return #"<path d="M8 5.4a1 1 0 0 1 1.5-.87l9.1 5.3a1 1 0 0 1 0 1.73l-9.1 5.3A1 1 0 0 1 8 16z"/>"#
        case .pause:
            return #"<rect x="6.5" y="5" width="4" height="14" rx="1.3"/><rect x="13.5" y="5" width="4" height="14" rx="1.3"/>"#
        case .skipBack:
            return #"<path d="M18.5 5.5v13L9 12z"/><path d="M6 5.5v13"/>"#
        case .skipForward:
            return #"<path d="M5.5 5.5v13L15 12z"/><path d="M18 5.5v13"/>"#
        case .rewind:
            return #"<path d="M11.5 6.5v11L4 12z"/><path d="M20 6.5v11L12.5 12z"/>"#
        case .fastForward:
            return #"<path d="M12.5 6.5v11L20 12z"/><path d="M4 6.5v11L11.5 12z"/>"#
        case .seekBack:
            return #"<path d="M3.5 12a8.5 8.5 0 1 1 2.8 6.3"/><path d="M3.5 7.4V12h4.6"/>"#
        case .seekForward:
            return #"<path d="M20.5 12a8.5 8.5 0 1 0-2.8 6.3"/><path d="M20.5 7.4V12h-4.6"/>"#
        case .add:
            return #"<path d="M12 5v14M5 12h14"/>"#
        case .plusCircle:
            return #"<circle cx="12" cy="12" r="8.5"/><path d="M12 8.5v7M8.5 12h7"/>"#
        case .close:
            return #"<path d="m6.5 6.5 11 11M17.5 6.5l-11 11"/>"#
        case .check:
            return #"<path d="m5 12.5 4.8 4.8L19 7.5"/>"#
        case .checkCircle, .success:
            return #"<circle cx="12" cy="12" r="8.5"/><path d="m8.2 12.2 2.7 2.7 5-5.4"/>"#
        case .refresh:
            return #"<path d="M20.5 12a8.5 8.5 0 1 1-2.5-6"/><path d="M20.5 4v5h-5"/>"#
        case .download:
            return #"<path d="M12 3.5v11.5"/><path d="m7.5 10.5 4.5 4.5 4.5-4.5"/><path d="M4.5 19.5h15"/>"#
        case .upload:
            return #"<path d="M12 20.5V9"/><path d="m7.5 13.5 4.5-4.5 4.5 4.5"/><path d="M4.5 4.5h15"/>"#
        case .edit:
            return #"<path d="M4 20h4.2l10-10a2.4 2.4 0 0 0-3.4-3.4l-10 10Z"/><path d="m13.8 7.4 2.8 2.8"/>"#
        case .trash:
            return #"<path d="M4.5 6.5h15"/><path d="M9 6.5V4.8A1.3 1.3 0 0 1 10.3 3.5h3.4A1.3 1.3 0 0 1 15 4.8v1.7"/><path d="M6.5 6.5 7.4 19a1.5 1.5 0 0 0 1.5 1.4h6.2a1.5 1.5 0 0 0 1.5-1.4l.9-12.5"/>"#
        case .more:
            return #"<circle cx="5.5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="18.5" cy="12" r="1.3"/>"#
        case .filter:
            return #"<path d="M3.5 5.5h17l-6.6 7.6V19l-3.8 2v-7.9Z"/>"#
        case .sort:
            return #"<path d="M7 20V4M7 4 3.5 7.6M7 4l3.5 3.6"/><path d="M17 4v16M17 20l-3.5-3.6M17 20l3.5-3.6"/>"#
        case .external:
            return #"<path d="M14 4.5h5.5V10"/><path d="M19.5 4.5 11 13"/><path d="M18 14.5v4A1.5 1.5 0 0 1 16.5 20h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6h4"/>"#
        case .link:
            return #"<path d="M10 13.5a3.6 3.6 0 0 0 5.3.4l2.8-2.8a3.6 3.6 0 0 0-5.1-5.1l-1.6 1.6"/><path d="M14 10.5a3.6 3.6 0 0 0-5.3-.4l-2.8 2.8a3.6 3.6 0 0 0 5.1 5.1l1.6-1.6"/>"#
        case .share:
            return #"<circle cx="17.5" cy="6" r="2.6"/><circle cx="6.5" cy="12" r="2.6"/><circle cx="17.5" cy="18" r="2.6"/><path d="m8.8 10.8 6.4-3.5M8.8 13.2l6.4 3.5"/>"#
        case .logout:
            return #"<path d="M14.5 4.5h3A1.5 1.5 0 0 1 19 6v12a1.5 1.5 0 0 1-1.5 1.5h-3"/><path d="M11 16.5 15.5 12 11 7.5"/><path d="M15 12H4.5"/>"#
        case .heart:
            return #"<path d="M20.4 5.6a5.2 5.2 0 0 0-7.4 0L12 6.6l-1-1a5.2 5.2 0 1 0-7.4 7.4L12 20.5l8.4-7.5a5.2 5.2 0 0 0 0-7.4Z"/>"#
        case .heartFilled:
            return #"<path d="M20.4 5.6a5.2 5.2 0 0 0-7.4 0L12 6.6l-1-1a5.2 5.2 0 1 0-7.4 7.4L12 20.5l8.4-7.5a5.2 5.2 0 0 0 0-7.4Z"/>"#
        case .bookmark:
            return #"<path d="M6.5 3.5h11a1 1 0 0 1 1 1v16l-6.5-3.7L5.5 20.5v-16a1 1 0 0 1 1-1Z"/>"#
        case .bookmarkFilled:
            return #"<path d="M6.5 3.5h11a1 1 0 0 1 1 1v16l-6.5-3.7L5.5 20.5v-16a1 1 0 0 1 1-1Z"/>"#
        case .star:
            return #"<path d="m12 3.8 2.7 5.5 6 .9-4.3 4.2 1 6-5.4-2.8-5.4 2.8 1-6L3.3 10.2l6-.9Z"/>"#
        case .starFilled:
            return #"<path d="m12 3.8 2.7 5.5 6 .9-4.3 4.2 1 6-5.4-2.8-5.4 2.8 1-6L3.3 10.2l6-.9Z"/>"#
        case .circle:
            return #"<circle cx="12" cy="12" r="8.5"/>"#
        case .eye:
            return #"<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="3"/>"#
        case .eyeOff:
            return #"<path d="M9.6 5.9A8.9 8.9 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a17 17 0 0 1-3.2 4"/><path d="M6.3 7.9A17 17 0 0 0 2.5 12S6 18.5 12 18.5a8.7 8.7 0 0 0 3.6-.8"/><path d="m4 4 16 16"/>"#
        case .info:
            return #"<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.8h.01"/>"#
        case .warning:
            return #"<path d="M10.6 4.3 2.9 17.5a1.6 1.6 0 0 0 1.4 2.4h15.4a1.6 1.6 0 0 0 1.4-2.4L13.4 4.3a1.6 1.6 0 0 0-2.8 0Z"/><path d="M12 9.5v4M12 16.8h.01"/>"#
        case .error:
            return #"<circle cx="12" cy="12" r="8.5"/><path d="m9.2 9.2 5.6 5.6M14.8 9.2l-5.6 5.6"/>"#
        case .shield:
            return #"<path d="M12 3 5 5.8v5.4c0 4.3 2.9 8.1 7 9.3 4.1-1.2 7-5 7-9.3V5.8Z"/><path d="m9.2 12 2 2 3.6-3.8"/>"#
        case .activity:
            return #"<path d="M3.5 12h4l2.5-6.5 4 13 2.5-6.5h4"/>"#
        case .sparkles:
            return #"<path d="M12 3.5 13.6 8 18 9.6 13.6 11.2 12 15.6 10.4 11.2 6 9.6 10.4 8Z"/><path d="M18.5 15.5 19.3 17.7 21.5 18.5 19.3 19.3 18.5 21.5 17.7 19.3 15.5 18.5 17.7 17.7Z"/>"#
        case .chevronLeft:
            return #"<path d="m15 5.5-7 6.5 7 6.5"/>"#
        case .chevronRight:
            return #"<path d="m9 5.5 7 6.5-7 6.5"/>"#
        case .chevronUp:
            return #"<path d="m5.5 15 6.5-7 6.5 7"/>"#
        case .chevronDown:
            return #"<path d="m5.5 9 6.5 7 6.5-7"/>"#
        case .arrowLeft:
            return #"<path d="M20 12H4.5"/><path d="m10.5 5.5-6 6.5 6 6.5"/>"#
        case .arrowRight:
            return #"<path d="M4 12h15.5"/><path d="m13.5 5.5 6 6.5-6 6.5"/>"#
        case .arrowUp:
            return #"<path d="M12 20V4.5"/><path d="m5.5 10.5 6.5-6 6.5 6"/>"#
        case .arrowDown:
            return #"<path d="M12 4v15.5"/><path d="m5.5 13.5 6.5 6 6.5-6"/>"#
        case .sun:
            return #"<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2.2M12 19.3v2.2M4.2 4.2l1.6 1.6M18.2 18.2l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.2 19.8l1.6-1.6M18.2 5.8l1.6-1.6"/>"#
        case .moon:
            return #"<path d="M20 14.2A8.4 8.4 0 0 1 9.8 4 8.5 8.5 0 1 0 20 14.2Z"/>"#
        case .display:
            return #"<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7M12 17v3.5"/>"#
        case .menu:
            return #"<path d="M4 7h16M4 12h16M4 17h16"/>"#
        case .sidebar:
            return #"<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M9.5 4.5v15"/>"#
        case .volumeOn:
            return #"<path d="M4 9.5h3L11.5 5.5v13L7 14.5H4Z"/><path d="M15.5 9.2a4 4 0 0 1 0 5.6M18.2 6.5a7.8 7.8 0 0 1 0 11"/>"#
        case .volumeOff:
            return #"<path d="M4 9.5h3L11.5 5.5v13L7 14.5H4Z"/><path d="m15.5 10 5 4M20.5 10l-5 4"/>"#
        case .fullscreen:
            return #"<path d="M4 9V4.5h5M20 9V4.5h-5M4 15v4.5h5M20 15v4.5h-5"/>"#
        case .fullscreenExit:
            return #"<path d="M9.5 4v5.5H4M14.5 4v5.5H20M9.5 20v-5.5H4M14.5 20v-5.5H20"/>"#
        case .pictureInPicture:
            return #"<rect x="2.5" y="5" width="19" height="14" rx="2.5"/><rect x="12" y="11.5" width="7.5" height="5.5" rx="1.2"/>"#
        case .speed:
            return #"<path d="M4 17a8 8 0 1 1 16 0"/><path d="m15 9.5-3.6 4.6"/><circle cx="12" cy="17" r="1.3"/>"#
        case .image:
            return #"<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><circle cx="8.5" cy="9.5" r="1.5"/><path d="m4 16.5 4.5-4.2 3 2.8 2.5-2.3 6 5.2"/>"#
        case .video:
            return #"<rect x="2.5" y="6" width="13" height="12" rx="2.5"/><path d="m15.5 10.5 6-3v9l-6-3Z"/>"#
        case .subtitles:
            return #"<rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M6.5 14h4M13 14h4.5"/>"#
        case .cast:
            return #"<path d="M2.5 18.5h.01"/><path d="M2.5 14.5a4 4 0 0 1 4 4M2.5 10.5a8 8 0 0 1 8 8"/><path d="M6.5 6h13a1.5 1.5 0 0 1 1.5 1.5v10a1.5 1.5 0 0 1-1.5 1.5h-4.5"/>"#
        case .wifiOff:
            return #"<path d="M3 3l18 18"/><path d="M12 18.5h.01"/><path d="M8.5 15a5 5 0 0 1 6 0M5 11.5a10 10 0 0 1 4-2.4M19 11.5a10 10 0 0 0-3-2.2"/>"#
        case .shuffle:
            return #"<path d="M16.5 4.5 20.5 8l-4 3.5"/><path d="M16.5 12.5 20.5 16l-4 3.5"/><path d="M3.5 8h3.2c1.3 0 2.5.7 3.2 1.8l3.4 5.4c.7 1.1 1.9 1.8 3.2 1.8h4"/><path d="M3.5 16h3.2c1.3 0 2.5-.7 3.2-1.8l.7-1.1"/><path d="m13.2 9.6.7-1.1C14.6 7.4 15.8 6.7 17.1 6.7h3.4"/>"#
        case .repeatAll:
            return #"<path d="M6.5 3.5 3 7l3.5 3.5"/><path d="M3 7h13.5A4.5 4.5 0 0 1 21 11.5v.5"/><path d="M17.5 20.5 21 17l-3.5-3.5"/><path d="M21 17H7.5A4.5 4.5 0 0 1 3 12.5V12"/>"#
        case .repeatOne:
            return #"<path d="M6.5 3.5 3 7l3.5 3.5"/><path d="M3 7h13.5A4.5 4.5 0 0 1 21 11.5v.5"/><path d="M17.5 20.5 21 17l-3.5-3.5"/><path d="M21 17H7.5A4.5 4.5 0 0 1 3 12.5V12"/><path d="M11.4 9.6 13 8.5V15"/>"#
        }
    }

    /// The filled backing shape for `.duotone`, or `nil` when the glyph has no
    /// closed primary form to fill.
    ///
    /// 只有"有一个主体轮廓"的字形才配得上面层：一枚箭头、一条分隔线、一个加号
    /// 底下垫一块面，只会变成一团污渍。取不到面层的字形照常按纯线条画——`render`
    /// 会连 `icon-duotone` 类一起省掉，所以调用方不必逐个判断。
    ///
    /// 面层刻意比线条**略小一圈**（缩进约 0.6–1px）。和描边正好重合的面会从
    /// 1.8px 的线里透出来，把整枚图标的边缘染脏；退进去之后，线仍然是线，面只
    /// 负责给它一点体积。
    fileprivate var duotoneBody: String? {
        switch self {
        case .home:
            return #"<path d="M6.4 10.1 12 5.4l5.6 4.7V20H6.4Z"/>"#
        case .search:
            return #"<circle cx="11" cy="11" r="6.1"/>"#
        case .library, .film, .photos, .image, .subtitles:
            return #"<rect x="3.9" y="5.4" width="16.2" height="13.2" rx="1.8"/>"#
        case .grid:
            return #"<rect x="4.4" y="4.4" width="5.2" height="5.2" rx="1"/><rect x="14.4" y="4.4" width="5.2" height="5.2" rx="1"/><rect x="4.4" y="14.4" width="5.2" height="5.2" rx="1"/><rect x="14.4" y="14.4" width="5.2" height="5.2" rx="1"/>"#
        case .series:
            return #"<rect x="3.4" y="7.9" width="17.2" height="11.2" rx="1.8"/>"#
        case .show:
            return #"<rect x="9.9" y="3.4" width="4.2" height="9.2" rx="2.1"/>"#
        case .anime:
            return #"<path d="M12 4.4c4.2 0 7.6 2.9 7.6 6.3 0 3.5-3.4 6.3-7.6 6.3-.8 0-1.6-.1-2.3-.3l-3.5 2 .7-2.6c-1.6-1.2-2-2.9-2-5.4 0-3.4 3.4-6.3 7.1-6.3Z"/>"#
        case .documentary:
            return #"<path d="M4.9 5.7A.9.9 0 0 1 5.8 4.9h6.3a.9.9 0 0 1 .9.8v12.8l-4-2-4 2Z"/>"#
        case .music:
            return #"<circle cx="6.5" cy="18" r="1.7"/><circle cx="17.5" cy="16" r="1.7"/>"#
        case .album:
            return #"<circle cx="12" cy="12" r="8.1"/>"#
        case .artist, .account:
            return #"<circle cx="12" cy="8" r="2.9"/><path d="M5.9 20.5a6.1 6.1 0 0 1 12.2 0Z"/>"#
        case .playlist:
            return #"<circle cx="15.6" cy="19" r="1"/>"#
        case .people, .users:
            return #"<circle cx="9" cy="8" r="2.6"/><path d="M4.4 20v-1.8a4.6 4.6 0 0 1 9.2 0V20Z"/>"#
        case .collections:
            return #"<rect x="4.4" y="7.4" width="15.2" height="11.2" rx="1.8"/>"#
        case .folder:
            return #"<path d="M4.4 6.6a.7.7 0 0 1 .7-.7h3.5l2 2.5h8.3a.7.7 0 0 1 .7.7v8.4a.7.7 0 0 1-.7.6H5.1a.7.7 0 0 1-.7-.6Z"/>"#
        case .queue:
            return #"<path d="M4 6.5h12"/>"#
        case .history, .clock, .refresh:
            return #"<circle cx="12" cy="12" r="7.6"/>"#
        case .source:
            return #"<rect x="3.4" y="7.4" width="10.7" height="9.2" rx="1.8"/>"#
        case .server:
            return #"<rect x="3.9" y="5.4" width="16.2" height="4.7" rx="1.3"/><rect x="3.9" y="13.9" width="16.2" height="4.7" rx="1.3"/>"#
        case .database:
            return #"<ellipse cx="12" cy="6" rx="6.6" ry="2.3"/>"#
        case .dashboard, .activity:
            return #"<path d="M4.9 13a7.1 7.1 0 0 1 14.2 0Z"/>"#
        case .settings:
            return #"<circle cx="12" cy="12" r="2.2"/>"#
        case .vault:
            return #"<rect x="5.4" y="10.9" width="13.2" height="8.7" rx="1.8"/>"#
        case .key:
            return #"<circle cx="8" cy="8" r="3.6"/>"#
        case .heart, .heartFilled:
            return #"<path d="M19.5 6.4a4.3 4.3 0 0 0-6.1 0L12 7.8l-1.4-1.4a4.3 4.3 0 1 0-6.1 6.1L12 19.3l7.5-6.8a4.3 4.3 0 0 0 0-6.1Z"/>"#
        case .bookmark, .bookmarkFilled:
            return #"<path d="M6.9 4.4h10.2a.4.4 0 0 1 .4.4v14.6L12 16.2l-5.5 3.2V4.8a.4.4 0 0 1 .4-.4Z"/>"#
        case .star, .starFilled:
            return #"<path d="m12 5.3 2.2 4.5 4.9.7-3.5 3.4.8 4.9L12 16.5l-4.4 2.3.8-4.9-3.5-3.4 4.9-.7Z"/>"#
        case .circle, .info, .error, .plusCircle, .checkCircle, .success:
            return #"<circle cx="12" cy="12" r="7.6"/>"#
        case .eye:
            return #"<circle cx="12" cy="12" r="2.2"/>"#
        case .warning:
            return #"<path d="M11.4 5.6 4.4 17.6a.7.7 0 0 0 .6 1h14a.7.7 0 0 0 .6-1L12.6 5.6a.7.7 0 0 0-1.2 0Z"/>"#
        case .shield:
            return #"<path d="M12 4.1 5.9 6.5v4.7c0 3.7 2.5 7 6.1 8.1 3.6-1.1 6.1-4.4 6.1-8.1V6.5Z"/>"#
        case .sparkles:
            return #"<path d="M12 5.1 13.2 8.4 16.5 9.6 13.2 10.8 12 14.1 10.8 10.8 7.5 9.6 10.8 8.4Z"/>"#
        case .video:
            return #"<rect x="3.4" y="6.9" width="11.2" height="10.2" rx="1.8"/>"#
        case .play, .pause:
            return nil
        case .filter:
            return #"<path d="M5.1 6.4h13.8l-5.5 6.3v6.2l-2.8 1.5v-7.7Z"/>"#
        case .trash:
            return #"<path d="M7.5 7.6h9l-.8 11.3a.6.6 0 0 1-.6.6H8.9a.6.6 0 0 1-.6-.6Z"/>"#
        default:
            return nil
        }
    }
}
