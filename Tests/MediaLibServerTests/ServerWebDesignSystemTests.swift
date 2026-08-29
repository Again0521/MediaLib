import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

/// Invariants of the Web design system itself, as distinct from any one page.
///
/// These exist because the previous generation of this UI failed in ways no
/// page-level test could catch: an override stylesheet quietly negated the
/// tokens, dark mode was declared but unreachable, translucency had no fallback,
/// and emoji stood in for icons.
final class ServerWebDesignSystemTests: XCTestCase {
    private let router = LocalHTTPRouter(
        serverID: "server-001",
        serverName: "客厅服务器",
        authenticationProvider: { _ in .testAdministrator() }
    )

    private func asset(_ path: String) -> String {
        let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertEqual(response.statusCode, 200, path)
        return String(data: response.body, encoding: .utf8) ?? ""
    }

    // MARK: - Theming

    func testEverySemanticTokenIsDefinedInBothAppearances() {
        let tokens = asset("/assets/tokens.css")

        // A token defined only in light leaves dark rendering an unresolved
        // custom property — which paints as nothing at all, not as a fallback.
        let semanticTokens = [
            "--bg-canvas", "--surface", "--surface-raised", "--surface-sunken",
            "--surface-hover", "--surface-active", "--surface-selected", "--surface-scrim",
            "--text-primary", "--text-secondary", "--text-tertiary", "--text-inverse",
            "--text-on-accent", "--text-link",
            "--border", "--border-strong", "--divider",
            "--accent", "--accent-hover", "--accent-active", "--accent-text",
            "--accent-subtle", "--accent-subtle-hover",
            "--success", "--warning", "--error", "--info",
            "--focus-ring-color", "--focus-ring",
            "--shadow-1", "--shadow-2", "--shadow-3", "--shadow-4",
            "--glass-thin-bg", "--glass-regular-bg", "--glass-thick-bg",
            "--glass-thin-border", "--glass-regular-border", "--glass-thick-border",
            "--glass-thin-opaque", "--glass-regular-opaque", "--glass-thick-opaque",
            "--media-scrim", "--skeleton-base", "--skeleton-sheen",
            // 画面之上的那一族。它们在浅色和深色里是各自写的（而不是一套值两边
            // 共用），所以同样会因为漏掉一边而在某个外观下解析不出来。
            "--on-media-scrim-strong", "--on-media-scrim-mid", "--on-media-scrim-clear",
            "--btn-on-media-fill", "--btn-on-media-fill-hover", "--btn-on-media-fill-active",
            "--btn-on-media-border", "--btn-on-media-blur", "--btn-on-media-opaque",
            "--btn-on-media-strong-fill", "--btn-on-media-strong-hover", "--btn-on-media-strong-label",
            // 纵深族。浅色用白色提亮 + 彩色高程，深色必须各自收窄——同一组值两
            // 边共用会让深色控件顶上糊出一道灰雾。
            "--fill-raise", "--fill-raise-soft",
            "--inner-highlight", "--inner-highlight-strong", "--inner-shadow",
            "--shadow-accent-1", "--shadow-accent-2",
            // 图标底板与品牌标。这两族存在的意义就是消灭散落的硬编码，所以它们
            // 漏掉任何一个外观都会让某一处容器退回没有底的裸图标。
            "--icon-tile-fill", "--icon-tile-fill-quiet", "--icon-tile-border",
            "--icon-tile-glyph", "--icon-tile-glyph-quiet",
            "--brand-mark-fill", "--brand-mark-glyph"
        ] + ServerWebIcon.Tint.allCases.flatMap { tint in
            // 识别色族。每个域四个令牌，浅深各自编写（深色要提亮字形并抬高填充
            // 的 alpha——同一层 10% 的色在深表面上几乎读不出来）。
            ["glyph", "subtle", "subtle-hover", "border"].map { "--tint-\(tint.rawValue)-\($0)" }
        }

        guard let darkStart = tokens.range(of: "prefers-color-scheme: dark") else {
            return XCTFail("缺少深色外观")
        }
        let darkSection = String(tokens[darkStart.lowerBound...])

        for token in semanticTokens {
            XCTAssertTrue(tokens.contains("\(token):"), "浅色缺少语义 token \(token)")
            XCTAssertTrue(darkSection.contains("\(token):"), "深色缺少语义 token \(token)")
        }
    }

    func testDarkAppearanceIsReachableBothBySystemPreferenceAndExplicitChoice() {
        let tokens = asset("/assets/tokens.css")

        XCTAssertTrue(tokens.contains("@media (prefers-color-scheme: dark)"))
        // The system rule must not win over an explicit "light" choice, and the
        // explicit "dark" choice must win over a light system preference.
        XCTAssertTrue(tokens.contains(":root:not([data-theme=\"light\"])"))
        XCTAssertTrue(tokens.contains(":root[data-theme=\"dark\"]"))
        // Dark is authored, not inverted: it does not sit on pure black.
        XCTAssertFalse(tokens.contains("--bg-canvas: #000000;"))
    }

    func testAppearanceIsAppliedBeforeFirstPaintAndStoresExactlyOneKey() {
        let script = asset("/assets/appearance.js")

        XCTAssertTrue(script.contains("medialib-appearance"))
        XCTAssertTrue(script.contains("data-theme"))
        // Storage is guarded: private browsing and blocked storage must degrade
        // to the system preference rather than throwing on load.
        XCTAssertTrue(script.contains("try {"))
        XCTAssertTrue(script.contains("catch"))

        // The single stored key is a non-sensitive display preference.  Nothing
        // else in the browser bundle may touch storage at all.
        XCTAssertEqual(script.components(separatedBy: "STORAGE_KEY = ").count - 1, 1)
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("token"))
        XCTAssertFalse(script.contains("sessionStorage"))

        for other in ["/assets/app-shell.js", "/assets/overlays.js", "/assets/home.js", "/assets/library.js", "/assets/player.js", "/assets/account.js", "/assets/admin.js"] {
            let contents = asset(other)
            // `localStorage` 是永久的，浏览器端一份都不许有；cookie 与 innerHTML
            // 同样一份都不许有。
            XCTAssertFalse(contents.contains("localStorage"), other)
            XCTAssertFalse(contents.contains("document.cookie"), other)
            XCTAssertFalse(contents.contains("innerHTML"), other)
            // 会话级存储只有外壳用得上，而且只有一个键。
            //
            // 侧栏是常驻导航，可详情页和播放页走整页加载，文档被浏览器整个换掉：
            // 展开的分组收回去、滚动位置回到顶端。存下来的只有分组标题（页面上
            // 本来就写着）和一个滚动偏移量，随标签页关闭消失——没有地址、没有
            // 查询词、没有任何凭据。「返回」的来处则完全不落存储：整页加载靠
            // `Referer`，就地换页靠 history.state。
            guard other == "/assets/app-shell.js" else {
                XCTAssertFalse(contents.contains("sessionStorage"), other)
                continue
            }
            XCTAssertEqual(contents.components(separatedBy: "sessionStorage?.setItem").count - 1, 1)
            XCTAssertEqual(contents.components(separatedBy: "sessionStorage?.getItem").count - 1, 1)
            XCTAssertFalse(contents.contains("sessionStorage.setItem"), "存储访问必须是可选链，无痕模式下不能抛错")
            XCTAssertFalse(contents.contains("sessionStorage.getItem"), other)
            XCTAssertTrue(contents.contains("const sidebarStateKey = 'medialib:sidebar-state';"))
            XCTAssertEqual(contents.components(separatedBy: "'medialib:sidebar-state'").count - 1, 1)
        }
    }

    // MARK: - Materials

    func testTranslucencyDegradesOnEverySignalAtTheTokenLayer() {
        let tokens = asset("/assets/tokens.css")

        // Doing this on the tokens rather than per selector is what makes the
        // fallback complete: previously only three of ~88 blurred surfaces
        // degraded at all.
        for guardClause in [
            "@supports not ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px)))",
            "@media (prefers-reduced-transparency: reduce)",
            "@media (prefers-contrast: more)"
        ] {
            XCTAssertTrue(tokens.contains(guardClause), guardClause)
        }
        XCTAssertEqual(tokens.components(separatedBy: "--glass-thick-bg: var(--glass-thick-opaque)").count - 1, 3)
        // 画面上的按钮材质和三档玻璃属于同一件事，必须在同样三个信号下一起塌回
        // 不透明——否则关掉透明度的用户会看到别的都变实心、只剩它还在糊。
        XCTAssertEqual(tokens.components(separatedBy: "--btn-on-media-fill: var(--btn-on-media-opaque)").count - 1, 3)
    }

    func testReducedMotionSubstitutesFeedbackRatherThanRemovingIt() {
        let base = asset("/assets/base.css")

        XCTAssertTrue(base.contains("@media (prefers-reduced-motion: reduce)"))
        // Movement is dropped…
        XCTAssertTrue(base.contains("transform: none !important"))
        // …but indeterminate progress keeps a legible, non-vestibular signal.
        XCTAssertTrue(base.contains("ui-reduced-pulse"))
        XCTAssertTrue(base.contains(".ui-spinner"))
    }

    // MARK: - Cascade

    func testPageStylesheetsRefineThePrimitivesWithoutFightingThem() {
        XCTAssertTrue(asset("/assets/tokens.css").hasPrefix("@layer tokens, base, primitives, shell;"))

        // Layered foundations plus unlayered page rules means a page can refine a
        // component by writing an ordinary selector.  The previous architecture
        // needed 442 `!important` declarations to achieve the same thing.
        let pageSheets = [
            "/assets/home.css", "/assets/library.css", "/assets/music.css",
            "/assets/people.css", "/assets/collections.css",
            "/assets/photos.css", "/assets/queue.css", "/assets/status.css",
            "/assets/sources.css", "/assets/admin.css", "/assets/account.css",
            "/assets/vault.css", "/assets/login.css"
        ]
        for sheet in pageSheets {
            let css = asset(sheet)
            XCTAssertFalse(css.contains("!important"), "\(sheet) 不应再靠 !important 覆盖公共层")
            XCTAssertFalse(css.contains(":root{"), "\(sheet) 不应重新定义 token")
            XCTAssertFalse(css.contains(":root {"), "\(sheet) 不应重新定义 token")
        }
    }

    /// 原语只属于 tokens.css。
    ///
    /// 令牌文件开头写着"Nothing outside this file may reference them"，但实际上
    /// 九处样式抄了同两条渐变：品牌标的 `--c-blue-400/600` 出现在侧栏、登录页和
    /// 保险库，空封面占位的 `--c-gray-300/400` 出现在六个页面样式表里。
    /// 后者不是洁癖问题——那两级灰是照着浅色画布挑的，深色主题下的空封面因此
    /// 比任何一张真封面都亮。渐变收敛成语义令牌之后两套外观才各有各的值。
    func testNoStylesheetReachesPastTheSemanticLayerIntoPrimitives() {
        let sheets = [
            "/assets/base.css", "/assets/primitives.css", "/assets/app-shell.css",
            "/assets/home.css", "/assets/library.css", "/assets/music.css",
            "/assets/people.css", "/assets/collections.css",
            "/assets/photos.css", "/assets/queue.css", "/assets/status.css",
            "/assets/sources.css", "/assets/admin.css", "/assets/account.css",
            "/assets/vault.css", "/assets/login.css", "/assets/player.css"
        ]
        for sheet in sheets {
            let css = asset(sheet)
            XCTAssertFalse(
                css.contains("var(--c-blue-"),
                "\(sheet) 直接引用了强调色原语，应改用 --accent* / --brand-mark-fill"
            )
            XCTAssertFalse(
                css.contains("var(--c-gray-"),
                "\(sheet) 直接引用了灰阶原语，应改用语义表面色或 --artwork-fallback-fill"
            )
        }
    }

    // MARK: - 识别色

    /// 识别色只上非交互面。
    ///
    /// 「蓝＝可点」是这个界面唯一的可点性线索。多给几个色相看起来更热闹，代价是
    /// 把那条规律取消掉——于是这一族被限制在图标底板、区块头、概览格、空态、
    /// 分区胶囊这些**身份**表面上，按钮、链接、焦点环、选中态一个都不许碰。
    func testIdentityTintsStayOffInteractiveSurfaces() {
        let sheets = [
            "/assets/tokens.css", "/assets/base.css", "/assets/primitives.css",
            "/assets/app-shell.css", "/assets/home.css", "/assets/library.css",
            "/assets/music.css", "/assets/account.css", "/assets/admin.css"
        ]
        // 这些声明拿到识别色就等于让可点性跟着内容分区走。
        let forbidden = [
            ".ui-btn-primary", ".ui-btn-secondary", ".ui-btn-tinted",
            ":focus-visible", "--focus-ring", "--surface-selected", "--text-link"
        ]
        for sheet in sheets {
            let css = asset(sheet)
            for rule in css.components(separatedBy: "}") where rule.contains("var(--tint-") {
                for token in forbidden {
                    XCTAssertFalse(
                        rule.contains(token),
                        "\(sheet)：识别色落到了交互面 \(token) 上"
                    )
                }
            }
        }
    }

    /// 每个域的字形色在**它自己的**淡填充上过 4.5:1。
    ///
    /// 这条不能靠肉眼：淡填充是一层 alpha，实际读到的背景是它与表面色合成之后的
    /// 结果，而深浅两套的表面色不同。挑色时按这个算式逐档压深/提亮过——teal 的
    /// 浅色档因此从 `#0b7a75` 又降了一级（4.32 → 4.87）。
    func testIdentityTintGlyphsClearContrastOnTheirOwnFill() {
        let tokens = asset("/assets/tokens.css")
        let dark = String(tokens[tokens.range(of: "prefers-color-scheme: dark")!.lowerBound...])
        let light = String(tokens[..<tokens.range(of: "prefers-color-scheme: dark")!.lowerBound])

        for tint in ServerWebIcon.Tint.allCases where tint != .neutral {
            for (scope, section, surface) in [("浅色", light, "#ffffff"), ("深色", dark, "#1f242d")] {
                guard
                    let glyphRef = Self.declaration("--tint-\(tint.rawValue)-glyph", in: section),
                    let subtle = Self.declaration("--tint-\(tint.rawValue)-subtle", in: section),
                    let glyphHex = Self.resolve(glyphRef, in: tokens),
                    let fill = Self.rgba(subtle)
                else {
                    return XCTFail("\(scope) \(tint.rawValue)：令牌解析失败")
                }
                let background = Self.composite(fill, over: Self.rgb(surface)!)
                let contrast = Self.contrast(Self.rgb(glyphHex)!, background)
                XCTAssertGreaterThanOrEqual(
                    contrast, 4.5,
                    "\(scope) \(tint.rawValue) 字形在自己的填充上只有 \(String(format: "%.2f", contrast)):1"
                )
            }
        }
    }

    // MARK: - 颜色算术（只服务上面那条断言）

    private static func declaration(_ token: String, in css: String) -> String? {
        guard let range = css.range(of: "\(token):") else { return nil }
        let rest = css[range.upperBound...]
        guard let end = rest.firstIndex(of: ";") else { return nil }
        return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `var(--c-violet-600)` → `#6a3dc6`。原语只在 `:root` 里定义一次，两套外观共用。
    private static func resolve(_ value: String, in css: String) -> String? {
        guard value.hasPrefix("var(") else { return value }
        let name = value.dropFirst(4).prefix { $0 != ")" }
        return declaration(String(name), in: css)
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff), Double((value >> 8) & 0xff), Double(value & 0xff))
    }

    private static func rgba(_ value: String) -> (Double, Double, Double, Double)? {
        guard value.hasPrefix("rgba(") else { return nil }
        let parts = value.dropFirst(5).prefix { $0 != ")" }
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    private static func composite(
        _ fill: (Double, Double, Double, Double),
        over base: (Double, Double, Double)
    ) -> (Double, Double, Double) {
        (
            fill.0 * fill.3 + base.0 * (1 - fill.3),
            fill.1 * fill.3 + base.1 * (1 - fill.3),
            fill.2 * fill.3 + base.2 * (1 - fill.3)
        )
    }

    private static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        func luminance(_ colour: (Double, Double, Double)) -> Double {
            func channel(_ raw: Double) -> Double {
                let value = raw / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(colour.0) + 0.7152 * channel(colour.1) + 0.0722 * channel(colour.2)
        }
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    // MARK: - The one page header, the one filter bar

    private func page(_ path: String) -> String {
        let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertEqual(response.statusCode, 200, path)
        return String(data: response.body, encoding: .utf8) ?? ""
    }

    /// 页头契约的守卫。
    ///
    /// `ServerWebPageHeader` 的文档说"每个已认证页面都通过这里渲染"，但首页、
    /// 媒体详情、人物详情、照片详情四页各自写了标题块，剧集页还叠了两个页头——
    /// 于是同一个产品里出现了四种页面标题尺寸。这条断言让它不能再退回去。
    func testEveryAuthenticatedPageRendersExactlyOnePageHeaderAndOneH1() {
        // 这份名单是白名单，不是自动发现——新增路由如果不加进来，它就一直是没有
        // 覆盖的。`?size=1280` 能在详情页上活那么久，正是同一类盲区。
        let paths = [
            "/", "/category/video", "/search", "/watching", "/history", "/favorites",
            "/music/songs", "/music/playlists", "/photos", "/albums", "/queue", "/people", "/collections",
            "/admin", "/admin/libraries", "/admin/users", "/account", "/vault"
        ]
        for path in paths {
            let html = page(path)
            XCTAssertEqual(
                html.components(separatedBy: "class=\"app-page-head\"").count - 1, 1,
                "\(path) 应当恰好渲染一个共用页头"
            )
            XCTAssertEqual(html.components(separatedBy: "<h1").count - 1, 1, "\(path) 应当恰好有一个 <h1>")
        }
    }

    /// 筛选行从前有四种容器：资料库是一个不落在任何表面上的裸 `<form>`，音乐页是
    /// 两条堆叠的玻璃工具条，照片和队列各自第三、第四种。
    func testFilterRowsAllUseTheOneControlBarComponent() {
        for path in ["/category/video", "/music/songs", "/photos", "/queue"] {
            let html = page(path)
            XCTAssertTrue(html.contains("class=\"ui-control-bar"), "\(path) 未使用共用筛选条")
            XCTAssertFalse(html.contains("class=\"library-filters\""), path)
            XCTAssertFalse(html.contains("class=\"ui-toolbar music-toolbar\""), path)
        }
        // `.ui-control-bar` 只能定义在 primitives 里，页面样式只做间距细化。
        XCTAssertTrue(asset("/assets/primitives.css").contains(".ui-control-bar {"))
        for sheet in ["/assets/library.css", "/assets/music.css", "/assets/photos.css", "/assets/queue.css"] {
            XCTAssertFalse(asset(sheet).contains(".ui-control-bar {"), "\(sheet) 不应重新定义共用筛选条")
        }
    }

    func testEveryControlBarWithAdvancedControlsUsesTheSharedMobileDisclosure() {
        let pagesAndPanels = [
            ("/category/video", "advanced-filters"),
            ("/music/songs", "music-advanced-filters"),
            ("/music/albums", "music-advanced-filters"),
            ("/music/artists", "music-advanced-filters"),
            ("/music/recent", "music-advanced-filters"),
            ("/queue", "queue-advanced-filters")
        ]
        for (path, panelID) in pagesAndPanels {
            let html = page(path)
            XCTAssertTrue(html.contains("is-mobile-disclosable"), "\(path) 没有接入共用移动展开样式")
            XCTAssertTrue(html.contains("ui-control-bar-disclosure"), "\(path) 缺少高级筛选图标入口")
            XCTAssertTrue(html.contains("aria-label=\"高级筛选\""), path)
            XCTAssertTrue(html.contains("title=\"高级筛选\""), path)
            XCTAssertFalse(html.contains(">高级筛选</span>"), "\(path) 的移动端入口不应占用文字宽度")
            XCTAssertTrue(html.contains("aria-controls=\"\(panelID)\""), path)
            XCTAssertTrue(html.contains("aria-expanded=\"false\""), path)
            XCTAssertTrue(html.contains("id=\"\(panelID)\""), path)
        }
        // 相册只有内容分类，没有第二层筛选；保持同一 control bar 外观，但不能画一颗
        // 点击后什么都没有的空按钮。
        for path in ["/photos", "/albums", "/music/playlists"] {
            let simpleBar = page(path)
            XCTAssertTrue(simpleBar.contains("class=\"ui-control-bar"), path)
            XCTAssertFalse(simpleBar.contains("ui-control-bar-disclosure"), path)
        }

        let style = asset("/assets/primitives.css")
        XCTAssertTrue(style.contains(".ui-control-bar.is-mobile-disclosable"))
        XCTAssertTrue(style.contains("grid-template-columns: minmax(0, 1fr) auto"))
        XCTAssertTrue(style.contains(".ui-control-bar-disclosure { min-width: 44px; min-height: 44px"))
        XCTAssertTrue(style.contains("justify-content: flex-start"))
        XCTAssertTrue(style.contains("flex-wrap: nowrap"))
        XCTAssertTrue(style.contains("overflow-x: auto"))
        XCTAssertTrue(style.contains(".is-advanced-open > .ui-control-bar-trailing { display: flex; }"))
        XCTAssertTrue(style.contains(".ui-control-bar-trailing > * { flex: 0 0 auto; }"))

        let script = asset("/assets/app-shell.js")
        XCTAssertTrue(script.contains("const closeControlBarDisclosures"))
        XCTAssertTrue(script.contains("bar.classList.toggle('is-advanced-open')"))
        XCTAssertTrue(script.contains("setAttribute('aria-expanded', expanded ? 'true' : 'false')"))
        XCTAssertTrue(script.contains("(max-width: 719px)"))
    }

    func testHomeGreetingStaysOnOneLineAndShrinksOnPhones() {
        let html = page("/")
        XCTAssertTrue(html.contains("id=\"home-title\""))
        XCTAssertTrue(html.contains("为你精选了一份片单"))
        let style = asset("/assets/home.css")
        XCTAssertTrue(style.contains(".home-document .app-page-head h1"))
        XCTAssertTrue(style.contains("white-space: nowrap"))
        XCTAssertTrue(style.contains("font-size: clamp(15px, 4.5vw, var(--type-display-size))"))
    }

    /// 计数从前有六种呈现方式：筛选栏下的一个标题块、工具条里的一个 span、
    /// 一段游离的 `<p>`…… 现在它是副标题的一部分，与客户端的 "… · N 项" 同一句话。
    func testLiveCountsLiveInThePageSubtitle() {
        for path in ["/category/video", "/music/songs", "/photos", "/queue", "/people", "/collections"] {
            let html = page(path)
            XCTAssertTrue(html.contains("class=\"app-subtitle-count"), "\(path) 的计数不在页头副标题里")
            XCTAssertTrue(html.contains("aria-live=\"polite\""), path)
        }
        XCTAssertFalse(page("/category/video").contains("class=\"library-results-head\""))
        XCTAssertFalse(page("/queue").contains("class=\"queue-summary\""))
    }

    /// 一个永远匹配不到内容的控件比缺席更糟。
    func testNoControlOffersAFilterTheDataLayerCannotSatisfy() {
        // 「有歌词」曾经是缺席的：歌词存在性只活在客户端一个内存缓存里，服务端
        // 没有这个字段。schema 29 把 `has_lyrics` 落库之后它才被放出来——所以这
        // 里断言的不是"有这个胶囊"，而是"有胶囊就必须有对应的数据"：每一行都得
        // 带上判定结果，否则它又会退回成一个筛不出东西的控件。
        // 这个 router 挂的是空资料库，所以要在真的渲染出行的时候才谈得上"行上有
        // 没有判定"——空页面上两者都不存在，断言不了任何东西。
        let songs = page("/music/songs")
        if songs.contains("有歌词"), songs.contains("class=\"song-row\"") {
            XCTAssertTrue(
                songs.contains("data-filter-lyrics="),
                "音乐页提供了「有歌词」筛选，行上却没有歌词判定，这个控件筛不出任何东西"
            )
        }
        // 艺术家页在客户端只提供「全部」，网页从前每一页都给全套筛选。
        let artists = page("/music/artists")
        for absent in ["有歌词", "未匹配", "收藏"] {
            XCTAssertFalse(
                artists.contains(">\(absent)</span>"),
                "艺术家页只提供「全部」，与客户端 availableFilterModes 一致"
            )
        }
        // 托盘里也不该出现永久禁用的单选项（照片页的"录像"曾经就是这样，
        // 而且没有接任何监听）。
        for path in ["/category/video", "/music/songs", "/photos"] {
            let html = page(path)
            guard let trayStart = html.range(of: "class=\"ui-control-tray\"") else { continue }
            let tray = String(html[trayStart.lowerBound...].prefix(2_000))
            XCTAssertFalse(tray.contains("disabled"), "\(path) 的筛选托盘里有禁用控件")
        }
    }

    /// 「有歌词」筛选背后必须真的有逐条目的判定，而且分组卡片按"组内任意一首"算。
    ///
    /// 空资料库的页面证明不了这件事（没有行，也就没有属性），所以这里直接渲染带
    /// 曲目的页面。客户端的四项筛选里，这一项是唯一需要新数据才成立的。
    func testMusicLyricsFilterCarriesRealPerItemData() {
        func track(_ id: String, album: String, hasLyrics: Bool) -> ServerLibraryItem {
            ServerLibraryItem(
                id: id, type: "music", title: id, year: 2026,
                artist: "艺术家", album: album, durationSeconds: 200,
                hasLyrics: hasLyrics, artworkAvailable: false
            )
        }
        let tracks = [
            track("with-lyrics", album: "甲", hasLyrics: true),
            track("without-lyrics", album: "乙", hasLyrics: false),
            track("also-in-甲", album: "甲", hasLyrics: false)
        ]
        let songs = ServerWebMusicPage.render(
            page: .songs, serverName: "S", csrfToken: "c",
            showAdministration: false, categories: [], sidebarExtras: .empty, tracks: tracks
        )
        XCTAssertTrue(songs.contains("有歌词"))
        XCTAssertTrue(songs.contains("data-filter-lyrics=\"true\""), "带歌词的曲目必须标出来")
        XCTAssertTrue(songs.contains("data-filter-lyrics=\"false\""), "没有歌词的曲目也必须标出来")

        // 专辑「甲」里有一首带歌词，所以整张专辑要留在筛选里；「乙」不该留下。
        let albums = ServerWebMusicPage.render(
            page: .albums, serverName: "S", csrfToken: "c",
            showAdministration: false, categories: [], sidebarExtras: .empty, tracks: tracks
        )
        let albumCards = albums.components(separatedBy: "class=\"album-card\"").dropFirst()
        let flagged = albumCards.filter { $0.prefix(600).contains("data-filter-lyrics=\"true\"") }
        XCTAssertEqual(flagged.count, 1, "只有含带歌词曲目的那张专辑该被标记")
    }

    /// 每个音乐分区提供的排序键与中文文案，逐字对齐客户端 `availableSortModes(for:)`
    /// 与 `MusicSortMode.title(for:)`。
    ///
    /// 两端说的是同一件事时不该有两套说法。这里钉死的是"客户端有哪几项、叫什么"，
    /// 所以任何一端单方面改词或增删排序键都会在这里断掉。
    func testMusicSortOptionsMatchTheClientWordForWord() {
        // 排序键与方向合成了一个控件（客户端就是一颗「歌曲名 · 正序」的菜单），
        // 所以每个键都有正序/倒序两项，文案与客户端逐字一致。
        let keys: [(ServerWebMusicPage.Page, [String])] = [
            (.songs, ["歌曲名", "艺术家", "专辑", "最多播放", "最近更新", "时长"]),
            (.recent, ["歌曲名", "艺术家", "专辑", "最多播放", "最近更新", "时长"]),
            (.albums, ["专辑名", "艺术家", "最近更新", "最多播放"]),
            (.artists, ["按名称", "按作品数量", "按播放次数"])
        ]
        let expected: [(ServerWebMusicPage.Page, [String])] = keys.map { page, labels in
            (page, labels.flatMap { ["\($0) · 正序", "\($0) · 倒序"] })
        }
        for (page, labels) in expected {
            let html = ServerWebMusicPage.render(
                page: page, serverName: "S", csrfToken: "c",
                showAdministration: false, categories: [], sidebarExtras: .empty, tracks: []
            )
            guard let start = html.range(of: "id=\"music-sort\""),
                  let end = html.range(of: "</select>", range: start.upperBound..<html.endIndex)
            else { return XCTFail("\(page) 缺少排序下拉") }
            let select = String(html[start.upperBound..<end.lowerBound])
            let rendered = select.components(separatedBy: "<option")
                .dropFirst()
                .compactMap { chunk -> String? in
                    guard let open = chunk.range(of: ">"), let close = chunk.range(of: "</option>") else { return nil }
                    return String(chunk[open.upperBound..<close.lowerBound])
                }
            XCTAssertEqual(rendered, labels, "\(page) 的排序项与客户端不一致")
        }
        // 歌单页在客户端只有一个排序键，所以整条排序控件不出现。
        let playlists = ServerWebMusicPage.render(
            page: .playlists, serverName: "S", csrfToken: "c",
            showAdministration: false, categories: [], sidebarExtras: .empty, tracks: []
        )
        XCTAssertFalse(playlists.contains("id=\"music-sort\""), "只有一个排序键时不该画出排序控件")
    }

    // MARK: - Icons


    func testProductionIconsAreNotEmojiOrPunctuation() {
        let paths = ["/", "/category/video", "/search", "/music/songs", "/photos", "/people", "/collections", "/queue", "/admin", "/admin/libraries", "/admin/users", "/account", "/vault"]
        // Emoji and box-drawing characters used to stand in for icons; they
        // render at whatever size and weight the platform font chooses and
        // cannot take a colour.
        let forbidden: Set<Character> = ["📺", "🎬", "🎵", "🧸", "📁", "▦", "▣", "⚙", "⌑", "⋯", "☑", "⌕", "♪", "♫", "↻", "▾"]

        for path in paths {
            let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let html = String(data: response.body, encoding: .utf8) ?? ""
            for character in forbidden where html.contains(character) {
                XCTFail("\(path) 仍使用字符 \(character) 充当图标")
            }
            XCTAssertTrue(html.contains("class=\"icon icon-"), path)
        }
    }

    /// 脚本里的图标必须来自同一份字形，而不是又一套手抄的路径。
    ///
    /// 四个页面脚本此前各带一份重复路径，其中 `app-shell.js` 的传输键和
    /// `sources.js` 的齿轮还是**实心 Material 画法**——底栏的播放键与页面上的
    /// `.play` 因此不是同一个形状。现在脚本侧的字形由 Swift 插值下来，所以这条
    /// 断言守两件事：解析器认得每一枚字形，以及脚本里不再出现裸的路径常量。
    func testScriptIconsComeFromTheOneGlyphSourceRatherThanHandCopiedPaths() {
        // 解析器面对的是本文件自己写的格式，所以"解析不出元素"意味着某枚字形
        // 写法跑偏了，而不是解析器该更宽容。
        for icon in ServerWebIcon.allGlyphs {
            let elements = ServerWebIcon.elements(of: icon)
            XCTAssertFalse(elements.isEmpty, "\(icon.rawValue) 解析不出任何元素")
            for element in elements {
                XCTAssertFalse(element.tag.isEmpty, "\(icon.rawValue) 有一个空标签")
                XCTAssertFalse(element.attributes.isEmpty, "\(icon.rawValue) 的 \(element.tag) 没有属性")
            }
        }

        // 生成的辅助函数只用 createElementNS 组装，绝不碰 HTML 字符串接收器。
        let helper = ServerWebIcon.scriptHelper(for: [.play, .music])
        XCTAssertTrue(helper.contains("createElementNS"))
        XCTAssertFalse(helper.contains("innerHTML"))
        XCTAssertTrue(helper.contains("\"solid\":true"), "play 是实心字形")
        XCTAssertTrue(helper.contains(ServerWebIcon.scriptGlyphBody(.play).components(separatedBy: "\"")[1]))

        // 那批被换掉的手抄路径不得复活。取的是原来那几条的特征片段。
        let scripts = ["/assets/app-shell.js", "/assets/sources.js", "/assets/collections.js", "/assets/library.js"]
        for path in scripts {
            let script = asset(path)
            XCTAssertFalse(script.contains("M8 5v14l11-7z"), "\(path) 又出现了实心 Material 播放三角")
            XCTAssertFalse(script.contains("GLYPH_"), "\(path) 不该再自带一份路径常量表")
            XCTAssertTrue(script.contains("medialibIcon"), "\(path) 应该用共享字形构建器")
        }
    }

    func testIconsShareOneGridStrokeAndColourContract() {
        // One family means one bounding box and one stroke weight; mismatched
        // boxes are what made the previous two icon sets look assembled.
        let markup = ServerWebIcon.render(.play) + ServerWebIcon.render(.search, size: .sm) + ServerWebIcon.render(.settings, size: .lg)
        XCTAssertEqual(markup.components(separatedBy: "viewBox=\"0 0 24 24\"").count - 1, 3)
        XCTAssertEqual(markup.components(separatedBy: "stroke-width=\"1.8\"").count - 1, 3)
        XCTAssertTrue(markup.contains("class=\"icon icon-sm\""))
        XCTAssertTrue(markup.contains("class=\"icon icon-lg\""))

        // Decorative by default, named only when the icon is the whole control.
        XCTAssertTrue(ServerWebIcon.render(.play).contains("aria-hidden=\"true\""))
        let labelled = ServerWebIcon.render(.play, label: "播放")
        XCTAssertTrue(labelled.contains("role=\"img\""))
        XCTAssertTrue(labelled.contains("aria-label=\"播放\""))
        XCTAssertFalse(labelled.contains("aria-hidden"))
    }

    // MARK: - Assets

    func testOneVersionCounterInvalidatesEveryBrowserAsset() {
        // Nine assets previously shipped unversioned and served stale for the
        // full cache lifetime after any change.
        let paths = ["/", "/category/video", "/queue", "/people", "/collections", "/photos", "/admin", "/admin/libraries", "/admin/users", "/account", "/vault", "/login"]
        for path in paths {
            let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let html = String(data: response.body, encoding: .utf8) ?? ""
            guard !html.isEmpty else { continue }
            for marker in ["href=\"/assets/", "src=\"/assets/"] {
                var remainder = Substring(html)
                while let range = remainder.range(of: marker) {
                    let tail = remainder[range.upperBound...]
                    guard let quote = tail.firstIndex(of: "\"") else { break }
                    let url = String(tail[..<quote])
                    XCTAssertTrue(url.contains("?v=\(ServerWebAssets.version)"), "\(path) 的 \(url) 缺少统一版本号")
                    remainder = tail[quote...]
                }
            }
        }
    }

    func testEveryDeclaredCoreAssetIsActuallyServed() {
        for path in ServerWebAssets.coreStylesheets + ["/assets/appearance.js", "/assets/overlays.js"] {
            let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            XCTAssertEqual(response.statusCode, 200, path)
            XCTAssertFalse(response.body.isEmpty, path)
        }
        // The override sheet that flattened every page to white is gone; it is no
        // longer part of the public asset table at all.
        XCTAssertNotEqual(
            router.response(for: "GET /assets/reference-system.css HTTP/1.1\r\nHost: localhost\r\n\r\n").statusCode,
            200
        )
    }

    // MARK: - Accessibility

    func testIconOnlyControlsCarryAnAccessibleName() {
        let markup = ServerWebUI.iconButton(.refresh, label: "刷新")
        XCTAssertTrue(markup.contains("aria-label=\"刷新\""))
        XCTAssertTrue(markup.contains("title=\"刷新\""))
    }

    func testAuthenticatedPagesExposeSkipLinkMainLandmarkAndLiveRegion() {
        for path in ["/", "/category/video", "/queue", "/admin", "/account"] {
            let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let html = String(data: response.body, encoding: .utf8) ?? ""
            XCTAssertTrue(html.contains("class=\"skip\" href=\"#main\""), path)
            XCTAssertTrue(html.contains("<main id=\"main\" class=\"app-main\" tabindex=\"-1\">"), path)
            XCTAssertTrue(html.contains("id=\"ui-toast-region\""), path)
            XCTAssertTrue(html.contains("aria-live=\"polite\""), path)
            // Zoom must never be disabled, and the display cutout is respected.
            XCTAssertTrue(html.contains("viewport-fit=cover"), path)
            XCTAssertFalse(html.contains("user-scalable=no"), path)
            XCTAssertFalse(html.contains("maximum-scale"), path)
        }
    }

    /// Inside a raw string (`#"""…"""#`) the line-continuation escape is `\#`,
    /// not a bare `\`.  Every shared builder was written with a bare one, so each
    /// wrapped line shipped a literal backslash into the markup — visible as
    /// stray `\` glyphs beside the search field and above every empty state.
    /// These builders are the ones that wrap, so they are the ones pinned here.
    func testSharedMarkupBuildersEmitNoLiteralBackslashes() {
        let builders: [(String, String)] = [
            ("searchField", ServerWebUI.searchField(
                id: "q", label: "搜索资料库", placeholder: "搜索资料库", action: "/search"
            )),
            ("searchField+hidden", ServerWebUI.searchField(
                id: "q", label: "搜索音乐", placeholder: "搜索音乐", action: "/search",
                hiddenFields: [(name: "type", value: "music")]
            )),
            ("emptyState", ServerWebUI.emptyState(
                icon: .library, title: "没有内容", message: "先在桌面端添加媒体源。"
            )),
            ("emptyState+action", ServerWebUI.emptyState(
                icon: .library, title: "没有内容", message: "先添加媒体源。",
                action: "查看来源", actionHref: "/admin/libraries"
            )),
            ("posterSkeletons", ServerWebUI.posterSkeletons(3))
        ]
        for (name, markup) in builders {
            XCTAssertFalse(markup.contains("\\"), "\(name) 输出中不应出现字面反斜杠：\(markup)")
        }
    }

    /// Every artwork URL a page emits must ask for a size the thumbnailer
    /// actually supports.  An unsupported one is not a soft failure: the image
    /// endpoint rejects the whole request with 400 and the artwork silently never
    /// appears, which is exactly how the home banner shipped blank.
    func testEmittedArtworkSizesAreAllSupportedByTheThumbnailer() throws {
        let expression = try NSRegularExpression(pattern: "/api/v1/images/[^\"?]+\\?size=(\\d+)")
        for path in ["/", "/category/video", "/photos", "/music/songs", "/queue", "/collections", "/people"] {
            let html = String(
                data: router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n").body,
                encoding: .utf8
            ) ?? ""
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in expression.matches(in: html, range: range) {
                guard let digits = Range(match.range(at: 1), in: html), let size = Int(html[digits]) else { continue }
                XCTAssertTrue(
                    ServerArtworkThumbnailer.supportedMaximumPixels.contains(size),
                    "\(path) 请求了不受支持的封面尺寸 \(size)，图片端点会返回 400"
                )
            }
        }
    }

    /// "Back" returns the reader where they came from.
    ///
    /// Detail pages hardcoded 返回资料库, so arriving from the queue, a collection
    /// or a series and pressing back landed on a page the reader had never
    /// visited. The origin now comes from the referrer — but only when it names a
    /// route this product actually serves.
    func testBackControlFollowsTheReferrerAndRefusesForeignOnes() {
        let fallback = ServerWebBackNavigation.Target(label: "返回首页", href: "/")
        func target(referer: String?) -> ServerWebBackNavigation.Target {
            let head = referer.map { "GET /item/x HTTP/1.1\r\nHost: localhost\r\nReferer: \($0)\r\n\r\n" }
                ?? "GET /item/x HTTP/1.1\r\nHost: localhost\r\n\r\n"
            return ServerWebBackNavigation.target(requestHead: head, fallback: fallback)
        }

        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/queue").href, "/queue")
        // A scoped browse page returns with its view intact, not to a bare list.
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/category/anime?type=anime&sort=titleAscending").href, "/category/anime?type=anime&sort=titleAscending")
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/queue").label, "返回播放队列")
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/favorites").href, "/favorites")
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/music/songs").href, "/music/songs")
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/").href, "/")
        // Identifier routes are rebuilt from a re-encoded segment, never echoed.
        // `/series/{id}` 不再是一个页面，所以它也不再是一个可返回的目的地。
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/series/s3"), fallback)
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/collections/c1").label, "返回合集")

        // 侧栏能到达的每一个页面都是一个合法的来处。少一个，从那里点进详情页再
        // 返回就会被扔回首页——这正是「返回」一度对所有二级页面都只会回首页的原因。
        for (path, label) in [
            ("/albums", "返回相册"), ("/vault", "返回保险库"),
            ("/admin", "返回仪表盘"), ("/admin/libraries", "返回媒体库与来源"),
            ("/admin/users", "返回用户"), ("/account", "返回设置")
        ] {
            let resolved = target(referer: "http://127.0.0.1:8098\(path)")
            XCTAssertEqual(resolved.href, path)
            XCTAssertEqual(resolved.label, label)
        }
        // 智能集合、智能歌单、远程来源分组也是侧栏条目；详情页之间还会互相跳。
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/smart-collections/sc1").href, "/smart-collections/sc1")
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/music/playlists/p1").href, "/music/playlists/p1")
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/remote/abc123").href, "/remote/abc123")
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/item/m1").href, "/item/m1")
        // 临时页面同样是来处：搜索结果带着查询词一起回去，而不是一个空结果页。
        XCTAssertEqual(
            target(referer: "http://127.0.0.1:8098/search?q=%E6%98%9F%E9%99%85").href,
            "/search?q=%E6%98%9F%E9%99%85"
        )
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/search?q=x").label, "返回搜索")

        // Anything else falls back rather than steering navigation.
        XCTAssertEqual(target(referer: nil), fallback)
        XCTAssertEqual(target(referer: "https://evil.example/library"), fallback)
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098/not-a-route"), fallback)
        XCTAssertEqual(target(referer: "not a url at all"), fallback)
        XCTAssertEqual(target(referer: "http://127.0.0.1:8098//library"), fallback)
    }

    /// A referrer must never be able to smuggle markup or a foreign target into
    /// the control's `href`.
    func testBackControlNeverEmitsUnescapedReferrerBytes() {
        let hostile = [
            "http://127.0.0.1:8098/series/\"><script>bad()</script>",
            "http://127.0.0.1:8098/collections/../../etc/passwd",
            "http://127.0.0.1:8098/people/a/b"
        ]
        for referer in hostile {
            let head = "GET /item/x HTTP/1.1\r\nHost: localhost\r\nReferer: \(referer)\r\n\r\n"
            let resolved = ServerWebBackNavigation.target(
                requestHead: head,
                fallback: .init(label: "返回首页", href: "/")
            )
            XCTAssertFalse(resolved.href.contains("<"), referer)
            XCTAssertFalse(resolved.href.contains("\""), referer)
            // The target is escaped where it is emitted; pre-escaping it here
            // would ship `&amp;amp;` in the href.
            XCTAssertFalse(resolved.href.contains("&amp;"), referer)
            XCTAssertFalse(resolved.href.contains(".."), referer)
        }
    }

    /// Search has one home across the product: the page header's trailing slot.
    func testSearchLivesInThePageHeaderOnEveryPageThatOffersIt() {
        for path in ["/category/video", "/search", "/people", "/photos", "/music/songs"] {
            let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let html = String(data: response.body, encoding: .utf8) ?? ""
            guard let headerRange = html.range(of: "class=\"app-page-head\""),
                  let searchRange = html.range(of: "class=\"app-page-search")
            else { return XCTFail("\(path) 未在页头渲染搜索框") }
            XCTAssertTrue(searchRange.lowerBound > headerRange.lowerBound, path)
            // The no-op 扫描 control is gone: it never started a scan, it only
            // raised a toast saying one was running somewhere.
            XCTAssertFalse(html.contains("id=\"btn-scan\""), path)
        }
    }

    /// 「返回」在服务端能算出来，前提是浏览器肯把来处发过来。
    ///
    /// `Referrer-Policy: no-referrer` 曾经让上面那套推导变成死代码：一个字节都
    /// 收不到，于是每一个详情页的返回都落到兜底的「返回首页」，不管读者是从
    /// 搜索结果、合集还是人物页点进来的。
    func testAuthenticatedPagesSendTheirOwnPathAsReferrer() {
        let headers = String(
            data: router.response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n").serializedHeaders(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(headers.contains("Referrer-Policy: same-origin"))
        XCTAssertFalse(headers.contains("Referrer-Policy: no-referrer"))
    }

    /// 取不到的资源会自己再试，不会在页面上留下一个永久的空格子。
    func testShellRetriesFailedResourcesAndFallsBackOnceExhausted() {
        let script = asset("/assets/app-shell.js")

        // 三次重试是下限，不是上限。
        XCTAssertTrue(script.contains("const resourceRetryDelays = [600, 1_800, 4_000];"))
        XCTAssertTrue(script.contains("document.addEventListener('error', event => handleResourceFailure(event.target), true);"))
        // 重试必须换 URL：同一个地址浏览器压根不会再发请求。
        XCTAssertTrue(script.contains("url.searchParams.set('_retry', String(attempt));"))
        // 样式表与页面控制器同样要重试——少一个 `library.js`，那一页就不出内容。
        XCTAssertTrue(script.contains("if (tag === 'script')"))
        XCTAssertTrue(script.contains("stylesheet"))
        // 插入文档之前就失败的图（页面控制器建卡片时的常态）也要被认领。
        XCTAssertTrue(script.contains("new window.MutationObserver"))
        XCTAssertTrue(script.contains("markArtworkFailed"))
        // 读取请求同样有界重试，写入请求绝不重试。
        XCTAssertTrue(script.contains("const readRetryDelays = [400, 1_200, 2_600];"))
        XCTAssertTrue(script.contains("if (!['GET', 'HEAD'].includes(request.method)) return false;"))

        // 统一兜底有一个真正的落点，而不是每个页面各画一种空白。
        let primitives = asset("/assets/primitives.css")
        XCTAssertTrue(primitives.contains(".ui-artwork-fallback"))
        XCTAssertTrue(primitives.contains("img[data-artwork-state=\"failed\"]"))
    }

    /// 侧栏是常驻导航，不跟着内容刷新。
    ///
    /// 详情页和播放页走整页加载，文档被浏览器整个换掉：展开的分组收回去、滚动
    /// 位置回到顶端。状态因此要存下来，在新文档落地时放回去。
    func testSidebarStateSurvivesFullDocumentNavigation() {
        let script = asset("/assets/app-shell.js")
        XCTAssertTrue(script.contains("const sidebarStateKey = 'medialib:sidebar-state';"))
        XCTAssertTrue(script.contains("restoreSidebarState();"))
        XCTAssertTrue(script.contains("window.addEventListener('pagehide', persistSidebarState);"))
        // 就地换页与整页加载共用同一份状态描述，不再各写一套。
        XCTAssertTrue(script.contains("applySidebarState(incomingSidebar, sidebarState);"))
        // 服务端标成当前的那个分组永远展开：读者在别处收起过同名分组，不该撤销
        // 这次定位。
        XCTAssertTrue(script.contains("if (details.querySelector('[aria-current]')) { details.open = true; continue; }"))
    }

    /// 「返回」跟着这一条历史记录走，前进后退之后也对得上。
    func testBackControlFollowsThisHistoryEntryAcrossBothNavigationPaths() {
        let script = asset("/assets/app-shell.js")
        // 就地换页把来处钉在新的那条历史记录上。
        XCTAssertTrue(script.contains("window.history.pushState({ medialibFrom: origin }, '', url.href);"))
        // 整页加载拿不到 pushState，来处从 `Referer` 读——服务端画那条链接用的
        // 也是同一个来处，两边不会说两种话。
        XCTAssertTrue(script.contains("const sameOriginReferrer = () => {"))
        XCTAssertTrue(script.contains("adoptOriginState();"))
        // 认领条件写得紧：不能是自己，必须同源。
        XCTAssertTrue(script.contains("if (url.href === window.location.href) return null;"))
        XCTAssertTrue(script.contains("if (url.origin !== window.location.origin) return null;"))
        // 服务端不认识那条来处时，宁可说「上一页」，也不指着首页写别的名字。
        XCTAssertTrue(script.contains("text.textContent = '返回上一页';"))
        // 带查询词的搜索页在读者心里叫「搜索结果」。
        XCTAssertTrue(script.contains("return '搜索结果';"))
        // 后退回来时连滚动位置一起带回来。
        XCTAssertTrue(script.contains("medialibScroll"))
    }

    func testPhoneViewportUsesFortyFourPointSharedControlsWithoutDependingOnPointerEmulation() {
        let tokens = asset("/assets/tokens.css")
        XCTAssertTrue(tokens.contains("@media (max-width: 719px)"))
        XCTAssertTrue(tokens.contains("--control-height-xs: 44px"))
        XCTAssertTrue(tokens.contains("--control-height-sm: 44px"))
        XCTAssertTrue(tokens.contains("--control-height-md: 44px"))
        XCTAssertTrue(tokens.contains("--field-height: 44px"))
        XCTAssertTrue(tokens.contains("--nav-item-height: 44px"))

        let primitives = asset("/assets/primitives.css")
        XCTAssertTrue(primitives.contains(".ui-segmented > button { height: var(--control-height-lg); }"))
        XCTAssertTrue(primitives.contains(".ui-section-more {"))
        XCTAssertTrue(primitives.contains("min-height: var(--control-height-lg)"))
        let shell = asset("/assets/app-shell.css")
        XCTAssertTrue(shell.contains(".nav-subitem { min-height: var(--nav-item-height); }"))
        XCTAssertTrue(ServerWebMediaDetailPage.style.contains(
            ".rating-star { width: var(--control-height-lg); height: var(--control-height-lg); }"
        ))
        XCTAssertTrue(ServerWebAdministrationPage.script.contains(
            "ui-btn ui-btn-sm ui-btn-ghost revoke-session"
        ))
    }
}
