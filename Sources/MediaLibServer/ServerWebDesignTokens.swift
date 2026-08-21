import Foundation

/// Layer 1 of the Web design system: the single source of truth for every
/// colour, dimension, material and motion value the browser UI is allowed to
/// use.
///
/// Structure follows the primitive → semantic → component progression:
///
/// * **Primitive** tokens are raw values (`--c-gray-500`).  Nothing outside this
///   file may reference them.
/// * **Semantic** tokens name a purpose (`--text-secondary`, `--glass-regular-bg`).
///   Stylesheets and components read these.
/// * **Component** tokens specialise a semantic value for one control family
///   (`--btn-height-md`), so a control can be retuned without hunting selectors.
///
/// Light and dark are authored independently — dark is *not* an inversion.  The
/// dark ramp lifts surfaces by lightening them rather than by leaning on shadow,
/// which does not read on a dark canvas.
///
/// The stylesheet is fully static: it contains no server name, user, library or
/// path data, so it stays privately cacheable alongside the other assets.
enum ServerWebDesignTokens {
    static let css: String = """
    \(layerOrder)
    @layer tokens {
    \(primitives)
    \(lightSemantics)
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
    \(darkSemanticBody)
      }
    }
    :root[data-theme="dark"] {
    \(darkSemanticBody)
    }
    \(componentTokens)
    \(identityTintScopes)
    \(compatibilityAliases)
    \(materialFallbacks)
    }
    \(ServerWebArtworkPalette.css)
    """

    /// Declared once, in the first stylesheet every page loads.
    ///
    /// Later layers win over earlier ones regardless of selector specificity, and
    /// *unlayered* rules win over every layer.  Page stylesheets stay unlayered on
    /// purpose: a page can refine a primitive without `!important`, which is what
    /// the previous generation of this UI had to reach for 442 times.
    private static let layerOrder = "@layer tokens, base, primitives, shell;"

    private static let primitives = #"""
      :root {
        color-scheme: light dark;

        /* ---- Neutral ramp -------------------------------------------------
           A cool-cast gray.  Media artwork is loud and uncontrollable, so the
           chrome stays close to neutral and lets covers supply the colour. */
        --c-gray-0: #ffffff;
        --c-gray-25: #fbfcfe;
        --c-gray-50: #f6f8fb;
        --c-gray-100: #eff2f7;
        --c-gray-150: #e6eaf2;
        --c-gray-200: #d9dfe9;
        --c-gray-300: #c1c9d7;
        --c-gray-400: #9aa4b5;
        --c-gray-500: #66707f;
        --c-gray-600: #56606f;
        --c-gray-700: #3d4553;
        --c-gray-800: #2a303b;
        --c-gray-825: #232833;
        --c-gray-850: #1f242d;
        --c-gray-900: #171b22;
        --c-gray-950: #12161c;
        --c-gray-1000: #0a0d12;

        /* ---- Accent ------------------------------------------------------- */
        --c-blue-200: #b9d6fb;
        --c-blue-300: #8fc0ff;
        --c-blue-400: #5aa2f4;
        --c-blue-500: #2a72d4;
        --c-blue-600: #1f66c4;
        --c-blue-700: #17509b;

        /* ---- 识别色（identity hues）-----------------------------------------
           第二个色彩维度。产品此前只有一个强调蓝，于是拿不到封面颜色的地方
           （账户、管理、媒体源、状态，以及深色主题下的整片外壳）读作灰白一片。

           这一族**只上非交互面**：图标底板、区块头、概览格子、空态、分区胶囊。
           按钮、链接、焦点环、选中态仍然只有 `--accent` —— 「蓝＝可点」是全站
           唯一的可点性线索，多给几个颜色就等于把它取消掉。落点白名单由
           `testIdentityTintsStayOffInteractiveSurfaces` 钉住。

           每一档的挑法与上面的蓝一致：浅色档一路压深到字形在自己的 `-subtle`
           填充上过 4.5:1，深色档一路提亮到同样的下限。 */
        --c-violet-200: #ddd0fb;
        --c-violet-300: #c4aefa;
        --c-violet-400: #a884f5;
        --c-violet-500: #7b4fd8;
        --c-violet-600: #6a3dc6;
        --c-violet-700: #532f9c;

        --c-teal-200: #b6e7e2;
        --c-teal-300: #86d8d1;
        --c-teal-400: #45bdb4;
        --c-teal-500: #0f8d86;
        --c-teal-600: #0a716c;
        --c-teal-700: #075450;

        --c-rose-200: #fbcfd8;
        --c-rose-300: #f8aabb;
        --c-rose-400: #f27a97;
        --c-rose-500: #d63e64;
        --c-rose-600: #c22d55;
        --c-rose-700: #9a2343;

        --c-slate-200: #ccd4e6;
        --c-slate-300: #a8b4cf;
        --c-slate-400: #7d8cad;
        --c-slate-500: #55628a;
        --c-slate-600: #47537a;
        --c-slate-700: #364060;

        /* 琥珀已有 `-light` / `-dark` 两个状态色（警告），识别色要的是整条阶梯。
           两者共存：状态色不动，识别色另取。 */
        --c-amber-200: #fbe3ae;
        --c-amber-300: #f7cd6f;
        --c-amber-400: #eaa81f;
        --c-amber-500: #a86a00;
        --c-amber-600: #8a5a00;
        --c-amber-700: #6b4500;

        /* ---- Semantic hues ------------------------------------------------
           Light variants are darkened until body text clears 4.5:1 on the
           canvas; dark variants are lifted for the same reason. */
        --c-green-light: #157347;
        --c-green-dark: #34d17d;
        --c-amber-light: #8a5a00;
        --c-amber-dark: #ffd60a;
        --c-red-light: #c9252d;
        --c-red-dark: #ff6961;

        /* ---- Spacing ------------------------------------------------------
           4px base.  Every margin, padding and gap in the product comes from
           here; no page may invent an off-scale value. */
        --space-0: 0px;
        --space-1: 4px;
        --space-2: 8px;
        --space-3: 12px;
        --space-4: 16px;
        --space-5: 20px;
        --space-6: 24px;
        --space-7: 32px;
        --space-8: 40px;
        --space-9: 48px;
        --space-10: 64px;
        --space-11: 80px;
        --space-12: 96px;

        /* ---- Radii --------------------------------------------------------
           Nested corners must stay concentric: an inner radius is the outer
           radius minus the padding between them. */
        --radius-xs: 6px;
        --radius-sm: 10px;
        --radius-md: 14px;
        --radius-lg: 20px;
        --radius-xl: 28px;
        --radius-pill: 999px;

        /* ---- Border widths ------------------------------------------------ */
        --hairline: 1px;
        --border-thick: 2px;

        /* ---- Type ---------------------------------------------------------
           System stack only.  The page CSP forbids external fonts, and the
           platform face already ships optical sizing and tracking tables. */
        --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI",
                     "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", Roboto,
                     Helvetica, Arial, sans-serif;
        --font-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas,
                     "Liberation Mono", monospace;

        /* size / line-height / tracking are chosen as a set: tracking tightens
           as type grows, leading loosens as type shrinks. */
        --type-display-size: clamp(30px, 3.4vw, 42px);
        --type-display-line: 1.08;
        --type-display-track: -0.022em;
        --type-title1-size: clamp(24px, 2.4vw, 30px);
        --type-title1-line: 1.16;
        --type-title1-track: -0.018em;
        --type-title2-size: 21px;
        --type-title2-line: 1.24;
        --type-title2-track: -0.012em;
        --type-title3-size: 17px;
        --type-title3-line: 1.32;
        --type-title3-track: -0.006em;
        --type-headline-size: 15px;
        --type-headline-line: 1.4;
        --type-headline-track: -0.002em;
        --type-body-size: 15px;
        --type-body-line: 1.55;
        --type-body-track: 0em;
        --type-callout-size: 14px;
        --type-callout-line: 1.5;
        --type-callout-track: 0em;
        --type-subhead-size: 13px;
        --type-subhead-line: 1.46;
        --type-subhead-track: 0.004em;
        --type-footnote-size: 12px;
        --type-footnote-line: 1.42;
        --type-footnote-track: 0.008em;
        --type-caption-size: 11px;
        --type-caption-line: 1.36;
        --type-caption-track: 0.016em;

        --weight-regular: 400;
        --weight-medium: 500;
        --weight-semibold: 600;
        --weight-bold: 700;
        /* Page titles only.  The desktop client draws its `<h1>` equivalent at
           `.black`, and 700 beside a 30px display size reads a full step lighter
           than the same screen in the app. */
        --weight-black: 800;

        /* ---- Control geometry --------------------------------------------- */
        --control-height-xs: 26px;
        --control-height-sm: 32px;
        --control-height-md: 36px;
        --control-height-lg: 44px;
        --icon-xs: 14px;
        --icon-sm: 16px;
        --icon-md: 20px;
        --icon-lg: 24px;
        --icon-xl: 32px;

        /* ---- Layout -------------------------------------------------------- */
        --sidebar-width: 248px;
        --page-max: 1440px;
        --page-max-prose: 68ch;
        --page-gutter: clamp(20px, 3vw, 44px);
        --page-top: clamp(24px, 3vw, 40px);
        --tabbar-height: 56px;

        /* ---- Elevation ladder ---------------------------------------------- */
        --z-base: 0;
        --z-sticky: 100;
        --z-sidebar: 200;
        --z-dock: 300;
        --z-overlay: 400;
        --z-modal: 500;
        --z-toast: 600;
        --z-skip: 700;

        /* ---- Motion --------------------------------------------------------
           Exit runs at ~70% of enter so dismissal feels responsive. */
        --duration-instant: 80ms;
        --duration-fast: 120ms;
        --duration-base: 200ms;
        --duration-slow: 320ms;
        --duration-exit: 140ms;
        --ease-out: cubic-bezier(0.22, 0.82, 0.28, 1);
        --ease-in: cubic-bezier(0.55, 0.06, 0.68, 0.19);
        --ease-in-out: cubic-bezier(0.5, 0.05, 0.2, 1);
        --ease-spring: cubic-bezier(0.34, 1.32, 0.64, 1);
      }
    """#

    private static let lightSemantics = #"""
      :root {
        /* ---- Canvas & surfaces --------------------------------------------- */
        --bg-canvas: var(--c-gray-50);
        --bg-bloom-a: rgba(42, 114, 212, 0.07);
        --bg-bloom-b: rgba(120, 96, 200, 0.05);
        --surface: var(--c-gray-0);
        --surface-raised: var(--c-gray-0);
        --surface-sunken: var(--c-gray-100);
        --surface-hover: rgba(15, 22, 36, 0.045);
        --surface-active: rgba(15, 22, 36, 0.08);
        --surface-selected: rgba(42, 114, 212, 0.1);
        --surface-scrim: rgba(14, 18, 27, 0.36);

        /* ---- Filter bar ----------------------------------------------------
           The one filter/sort row, mirroring the client's `AppAdaptiveControlBar`:
           a plain card holding a sunken tray of pills.  It lives in the content
           plane, so it is a surface and not glass — glass is reserved for chrome
           that floats above content. */
        --control-bar-bg: var(--c-gray-0);
        --control-bar-border: #edf0f5;
        --control-tray-bg: #f1f5f9;
        --control-tray-border: #e2e8f0;

        /* ---- Text ---------------------------------------------------------- */
        --text-primary: #1c2026;
        --text-secondary: #56606f;
        /* 4.71:1 on the light canvas.  Tertiary text is still text: it has to
           clear AA, not merely look quiet. */
        --text-tertiary: #66707f;
        --text-inverse: var(--c-gray-0);
        --text-on-accent: var(--c-gray-0);
        --text-link: var(--c-blue-600);

        /* ---- Lines --------------------------------------------------------- */
        --border: rgba(20, 28, 44, 0.11);
        --border-strong: rgba(20, 28, 44, 0.2);
        --divider: rgba(20, 28, 44, 0.075);

        /* ---- Accent -------------------------------------------------------- */
        --accent: var(--c-blue-500);
        --accent-hover: var(--c-blue-600);
        --accent-active: var(--c-blue-700);
        --accent-text: var(--c-blue-600);
        --accent-subtle: rgba(42, 114, 212, 0.1);
        --accent-subtle-hover: rgba(42, 114, 212, 0.16);

        /* ---- Status -------------------------------------------------------- */
        --success: var(--c-green-light);
        --success-subtle: rgba(21, 115, 71, 0.11);
        --warning: var(--c-amber-light);
        --warning-subtle: rgba(138, 90, 0, 0.12);
        --error: var(--c-red-light);
        --error-subtle: rgba(201, 37, 45, 0.1);
        --info: var(--c-blue-600);
        --info-subtle: rgba(42, 114, 212, 0.1);

        /* ---- Focus --------------------------------------------------------- */
        --focus-ring-color: rgba(42, 114, 212, 0.5);
        --focus-ring: 0 0 0 3px var(--focus-ring-color);
        --focus-ring-inset: inset 0 0 0 2px var(--accent);

        /* ---- Shadows -------------------------------------------------------
           Two-part: a tight contact shadow plus a wide ambient one. */
        --shadow-1: 0 1px 2px rgba(16, 24, 40, 0.06);
        --shadow-2: 0 1px 2px rgba(16, 24, 40, 0.05), 0 4px 12px -4px rgba(16, 24, 40, 0.1);
        --shadow-3: 0 2px 4px rgba(16, 24, 40, 0.05), 0 12px 28px -10px rgba(16, 24, 40, 0.16);
        --shadow-4: 0 4px 8px rgba(16, 24, 40, 0.06), 0 28px 60px -20px rgba(16, 24, 40, 0.26);

        /* ---- 纵深 -----------------------------------------------------------
           一块实心填充不该读作"填了色的矩形"。系统控件顶上有一道极窄的提亮、
           底部略沉、边缘一条比填充本身深一档的线——三样合起来才有厚度。

           拆成三个令牌而不是一条写死的 box-shadow，是因为它们各自管一件事：
           `--fill-raise` 是叠在填充上的**背景层**（要走 background-image，能和
           实色 background-color 同时存在），`--inner-highlight` 是**阴影层**的
           顶部高光，`--inner-shadow` 给凹槽（轨道、托盘）用。按钮、分段控件选
           中态、开关旋钮、图标底板共用同一套，所以调一次全站一起动。

           `--shadow-accent-*` 是唯一被允许的彩色高程，只给强调色实心控件：
           一颗蓝按钮投出中性灰影会显得贴在纸上，投出自己颜色的影才像是发着
           光的实体。普通卡片仍然不得使用（见设计文档 §2 "光的去处"）。 */
        --fill-raise: linear-gradient(180deg, rgba(255, 255, 255, 0.17), rgba(255, 255, 255, 0));
        --fill-raise-soft: linear-gradient(180deg, rgba(255, 255, 255, 0.55), rgba(255, 255, 255, 0));
        --inner-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.35);
        --inner-highlight-strong: inset 0 1px 0 rgba(255, 255, 255, 0.6);
        --inner-shadow: inset 0 1px 2px rgba(16, 24, 40, 0.1);
        --shadow-accent-1: 0 1px 2px rgba(31, 102, 196, 0.26), 0 2px 6px -2px rgba(31, 102, 196, 0.24);
        --shadow-accent-2: 0 1px 2px rgba(31, 102, 196, 0.22), 0 8px 20px -6px rgba(31, 102, 196, 0.34);

        /* ---- 图标底板 --------------------------------------------------------
           页头标题图标、品牌标、空态图标、统计格的图标此前各写各的尺寸
           （52×58 / 34 / 52 / 34 / 36 / 44×48）和各自硬编码的白色内高光。
           统一到这一族之后，图标容器只剩"取哪一档尺寸"这一个决定。
           `-brand` 那档是实心品牌渐变配白字形，`-quiet` 是页面内的低调档。 */
        --icon-tile-fill: linear-gradient(155deg, var(--accent-subtle-hover), var(--accent-subtle));
        --icon-tile-fill-quiet: linear-gradient(155deg, var(--surface-sunken), var(--surface-hover));
        --icon-tile-border: rgba(31, 102, 196, 0.12);
        --icon-tile-glyph: var(--accent-text);
        --icon-tile-glyph-quiet: var(--text-tertiary);

        /* ---- 识别色语义层 ----------------------------------------------------
           每个域一组四个：字形色、淡填充、淡填充的另一端（渐变用）、发丝边。
           渐变**不在这里拼**——自定义属性的 `var()` 在声明它的元素上替换，把
           整条 `linear-gradient(...)` 收进令牌会让挂在元素上的那一半解析不到
           （取色机制曾整个失效在这条上，见设计文档 §7）。这里只发端点色，
           渐变留在用它的那条规则里。 */
        --tint-video-glyph: var(--c-blue-600);
        --tint-video-subtle: rgba(42, 114, 212, 0.1);
        --tint-video-subtle-hover: rgba(42, 114, 212, 0.16);
        --tint-video-border: rgba(31, 102, 196, 0.12);

        --tint-music-glyph: var(--c-violet-600);
        --tint-music-subtle: rgba(123, 79, 216, 0.1);
        --tint-music-subtle-hover: rgba(123, 79, 216, 0.17);
        --tint-music-border: rgba(106, 61, 198, 0.14);

        --tint-photo-glyph: var(--c-teal-600);
        --tint-photo-subtle: rgba(15, 141, 134, 0.1);
        --tint-photo-subtle-hover: rgba(15, 141, 134, 0.17);
        --tint-photo-border: rgba(10, 113, 108, 0.14);

        --tint-vault-glyph: var(--c-rose-600);
        --tint-vault-subtle: rgba(214, 62, 100, 0.1);
        --tint-vault-subtle-hover: rgba(214, 62, 100, 0.17);
        --tint-vault-border: rgba(194, 45, 85, 0.14);

        --tint-admin-glyph: var(--c-slate-600);
        --tint-admin-subtle: rgba(85, 98, 138, 0.11);
        --tint-admin-subtle-hover: rgba(85, 98, 138, 0.18);
        --tint-admin-border: rgba(71, 83, 122, 0.14);

        --tint-editorial-glyph: var(--c-amber-600);
        --tint-editorial-subtle: rgba(168, 106, 0, 0.11);
        --tint-editorial-subtle-hover: rgba(168, 106, 0, 0.18);
        --tint-editorial-border: rgba(138, 90, 0, 0.14);

        --tint-neutral-glyph: var(--text-tertiary);
        --tint-neutral-subtle: var(--surface-sunken);
        --tint-neutral-subtle-hover: var(--surface-hover);
        --tint-neutral-border: var(--border);

        /* ---- 品牌标 ----------------------------------------------------------
           侧栏品牌标、登录页与保险库的锁标此前都直接引用 `--c-blue-400/600`
           两个**原语**，绕过了整个语义层——本文件开头写明原语不得被外部引用。
           收敛到这里之后，换强调色只需要改一处。 */
        --brand-mark-fill: linear-gradient(145deg, var(--c-blue-400), var(--c-blue-600));
        --brand-mark-glyph: var(--c-gray-0);

        /* 没有封面时的占位色。`--c-gray-300/400` 此前被六个页面样式表各抄了一
           遍，而那两级灰是照着浅色画布挑的——深色主题下的空封面因此比任何一张真
           封面都亮。

           ⚠️ 这里只发**两个颜色**，不发整条渐变。自定义属性的 `var()` 在**声明它
           的那个元素上**替换，不是在使用处：把 `var(--artwork-g1, …)` 包进一条
           :root 上的令牌，`--artwork-g1` 就在 :root 上解析——那里它永远是未定义
           的，于是每张海报都拿到同一块灰，取色机制整个失效。渐变必须留在用它的
           那条规则里。 */
        --artwork-fallback-a: var(--c-gray-300);
        --artwork-fallback-b: var(--c-gray-400);

        /* 下拉箭头。此前是两块 5px 三角形色块拼出来的——拼缝在 1× 屏上看得见，
           而且它是全站唯一一处不属于图标族的箭头：旁边的排序方向键用的是真正的
           `chevronDown` 字形，两者并排时角度和粗细都对不上。

           背景图里没有 `currentColor`，所以描边色只能烘进 URI，也因此这条令牌
           必须浅深各写一份。data URI 内部用单引号，`#` 转义成 `%23`——不转义会
           被当成片段标识符，整张图静默不显示。 */
        --select-caret: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2366707f' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m5.5 9 6.5 7 6.5-7'/%3E%3C/svg%3E");
        /* 复选框的勾。同样烘进 URI，同样浅深各一份——描边色跟的是 `--text-on-accent`
           （浅色下白、深色下近黑），因为它画在强调色填充之上而不是画在画布上。 */
        --check-mark: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ffffff' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m5 12.5 4.8 4.8L19 7.5'/%3E%3C/svg%3E");

        /* ---- Glass ---------------------------------------------------------
           Three weights only.  Thin rides on artwork, regular carries floating
           chrome, thick separates a whole structural region.  Bigger surfaces
           read as thicker material: more blur, deeper shadow. */
        --glass-thin-bg: rgba(255, 255, 255, 0.6);
        --glass-thin-blur: blur(12px) saturate(150%);
        --glass-thin-border: rgba(255, 255, 255, 0.5);
        --glass-thin-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.6);
        --glass-thin-shadow: var(--shadow-1);
        --glass-thin-opaque: rgba(255, 255, 255, 0.96);

        --glass-regular-bg: rgba(252, 253, 255, 0.72);
        --glass-regular-blur: blur(24px) saturate(180%);
        --glass-regular-border: rgba(255, 255, 255, 0.6);
        --glass-regular-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.7);
        --glass-regular-shadow: var(--shadow-3);
        --glass-regular-opaque: var(--c-gray-0);

        --glass-thick-bg: rgba(250, 252, 255, 0.78);
        --glass-thick-blur: blur(40px) saturate(180%);
        --glass-thick-border: rgba(255, 255, 255, 0.66);
        --glass-thick-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.75);
        --glass-thick-shadow: var(--shadow-4);
        --glass-thick-opaque: var(--c-gray-25);

        /* Artwork overlays sit on unpredictable imagery, so they carry their
           own always-dark treatment in both themes. */
        --overlay-on-media: rgba(12, 16, 24, 0.52);
        --overlay-on-media-strong: rgba(12, 16, 24, 0.72);
        --text-on-media: #ffffff;
        --text-on-media-secondary: rgba(255, 255, 255, 0.78);
        /* The last-resort contrast floor. Where a scrim cannot cover the text —
           copy laid directly over artwork whose brightness is unknowable — this
           keeps the glyph edges separable from whatever is behind them. It is
           deliberately tight and dark rather than a glow. */
        --text-on-media-shadow: 0 1px 3px rgba(0, 0, 0, 0.55), 0 0 1px rgba(0, 0, 0, 0.4);
        --media-scrim: linear-gradient(to top, rgba(8, 11, 18, 0.86) 0%, rgba(8, 11, 18, 0.45) 38%, rgba(8, 11, 18, 0) 74%);
        /* 遮罩的三个停靠色，而不是又一条写死角度的渐变。
           `--media-scrim` 只解决"从下往上压暗"这一种情况；hero 需要的是同时
           从左压暗（让文案区可读）和从下压暗（让底部的点分页可读），播放器需
           要的又是另一个角度。把停靠色单独发出来，各处才能自己组合方向，而不
           是每多一个方向就再复制一条渐变。 */
        --on-media-scrim-strong: rgba(8, 11, 18, 0.86);
        --on-media-scrim-mid: rgba(8, 11, 18, 0.46);
        --on-media-scrim-clear: rgba(8, 11, 18, 0);
        /* 落在画面上的按钮。它不能用 --accent：实心强调色要和海报本身的颜色
           抢，碰上亮画面还会整颗糊掉。材质填充借的是画面自己的颜色，所以在任
           何一张图上都保持可读。strong 是一屏一个的主行动（照搬 Apple TV 的
           白色实心播放键），普通那档是它旁边的次要行动。 */
        --btn-on-media-fill: rgba(255, 255, 255, 0.18);
        --btn-on-media-fill-hover: rgba(255, 255, 255, 0.28);
        --btn-on-media-fill-active: rgba(255, 255, 255, 0.34);
        --btn-on-media-border: rgba(255, 255, 255, 0.24);
        --btn-on-media-blur: blur(20px) saturate(160%);
        --btn-on-media-opaque: rgba(28, 33, 42, 0.94);
        --btn-on-media-strong-fill: rgba(255, 255, 255, 0.96);
        --btn-on-media-strong-hover: #ffffff;
        --btn-on-media-strong-label: #0b1017;
        /* 播放器进度槽与把手。写在这里而不是播放器样式里，是因为它们和上面的
           on-media 前景色属于同一族：无论主题如何，它们永远画在画面之上。 */
        --track-on-media: rgba(255, 255, 255, 0.28);
        --thumb-on-media: #ffffff;
        --thumb-on-media-shadow: 0 1px 3px rgba(0, 0, 0, 0.5);

        --skeleton-base: rgba(20, 28, 44, 0.06);
        --skeleton-sheen: rgba(255, 255, 255, 0.55);

        /* Pulls the hero's ambient wash back toward the page so a saturated
           poster does not repaint the whole top of the front page. */
        --hero-ambient-veil: rgba(246, 248, 251, 0.74);
      }
    """#

    /// Emitted twice — once behind `prefers-color-scheme`, once behind an
    /// explicit `[data-theme="dark"]` — so the appearance control wins in both
    /// directions without a third state ever going undefined.
    private static let darkSemanticBody = #"""
        --bg-canvas: var(--c-gray-950);
        --bg-bloom-a: rgba(90, 162, 244, 0.11);
        --bg-bloom-b: rgba(140, 110, 235, 0.08);
        /* 表面比画布抬高一整档，不是半档。此前 surface 是 gray-900 而画布是
           gray-950，两者只差 5 个单位——深色主题下整页读作"黑上加黑"，卡片
           的边界全靠那条发丝边撑着。设计文档 §2 要求深色靠**提亮**抬升层级，
           这里就是那条规则的落点。
           两档都在 `--text-tertiary`（#8892a3）上重验过 ≥4.5:1：
           surface 4.96 / raised 4.70。再抬一档 raised 会掉到 4.22。
           凹槽仍留在画布**之下**（gray-1000），否则托盘会与画布同色而消失。 */
        --surface: var(--c-gray-850);
        --surface-raised: var(--c-gray-825);
        --surface-sunken: var(--c-gray-1000);
        --surface-hover: rgba(255, 255, 255, 0.06);
        --surface-active: rgba(255, 255, 255, 0.1);
        --surface-selected: rgba(90, 162, 244, 0.16);
        --surface-scrim: rgba(4, 6, 10, 0.6);

        /* Dark lifts the bar rather than dropping it: elevation reads as light
           here, so the card is raised and the tray recedes below the canvas. */
        --control-bar-bg: var(--c-gray-850);
        --control-bar-border: rgba(255, 255, 255, 0.08);
        --control-tray-bg: rgba(0, 0, 0, 0.28);
        --control-tray-border: rgba(255, 255, 255, 0.06);

        --text-primary: #f2f4f8;
        --text-secondary: #a8b2c1;
        --text-tertiary: #8892a3;
        --text-inverse: var(--c-gray-950);
        --text-on-accent: #08111d;
        --text-link: var(--c-blue-300);

        --border: rgba(255, 255, 255, 0.12);
        --border-strong: rgba(255, 255, 255, 0.22);
        --divider: rgba(255, 255, 255, 0.08);

        --accent: var(--c-blue-400);
        --accent-hover: #74b1f7;
        --accent-active: #8fc0ff;
        --accent-text: var(--c-blue-300);
        --accent-subtle: rgba(90, 162, 244, 0.16);
        --accent-subtle-hover: rgba(90, 162, 244, 0.24);

        --success: var(--c-green-dark);
        --success-subtle: rgba(52, 209, 125, 0.16);
        --warning: var(--c-amber-dark);
        --warning-subtle: rgba(255, 214, 10, 0.14);
        --error: var(--c-red-dark);
        --error-subtle: rgba(255, 105, 97, 0.16);
        --info: var(--c-blue-400);
        --info-subtle: rgba(90, 162, 244, 0.16);

        --focus-ring-color: rgba(120, 180, 250, 0.55);
        --focus-ring: 0 0 0 3px var(--focus-ring-color);
        --focus-ring-inset: inset 0 0 0 2px var(--accent);

        --shadow-1: 0 1px 2px rgba(0, 0, 0, 0.4);
        --shadow-2: 0 1px 2px rgba(0, 0, 0, 0.4), 0 4px 12px -4px rgba(0, 0, 0, 0.5);
        --shadow-3: 0 2px 4px rgba(0, 0, 0, 0.4), 0 12px 28px -10px rgba(0, 0, 0, 0.6);
        --shadow-4: 0 4px 8px rgba(0, 0, 0, 0.45), 0 28px 60px -20px rgba(0, 0, 0, 0.72);

        /* 深色下提亮层要收窄一大截：同样一条 17% 的白色渐变，在深表面上会直接
           读成一道灰雾而不是光。彩色高程同理——深底上大范围的蓝影会糊成一团，
           所以先用中性影立住接触感，再叠一层收得很紧的蓝色辉光。 */
        --fill-raise: linear-gradient(180deg, rgba(255, 255, 255, 0.1), rgba(255, 255, 255, 0));
        --fill-raise-soft: linear-gradient(180deg, rgba(255, 255, 255, 0.06), rgba(255, 255, 255, 0));
        --inner-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.14);
        --inner-highlight-strong: inset 0 1px 0 rgba(255, 255, 255, 0.22);
        --inner-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.5);
        --shadow-accent-1: 0 1px 2px rgba(0, 0, 0, 0.45), 0 2px 8px -3px rgba(90, 162, 244, 0.34);
        --shadow-accent-2: 0 2px 4px rgba(0, 0, 0, 0.45), 0 10px 24px -9px rgba(90, 162, 244, 0.44);

        --icon-tile-fill: linear-gradient(155deg, var(--accent-subtle-hover), var(--accent-subtle));
        --icon-tile-fill-quiet: linear-gradient(155deg, var(--surface-hover), var(--surface-sunken));
        --icon-tile-border: rgba(255, 255, 255, 0.1);
        --icon-tile-glyph: var(--accent-text);
        --icon-tile-glyph-quiet: var(--text-tertiary);

        /* 识别色的深色档：字形提亮两档，填充的 alpha 抬高——同样一层 10% 的色
           在深表面上几乎读不出来。边全部退回中性白 alpha，深色下有色边会在
           大面积铺开时糊成一圈脏边。 */
        --tint-video-glyph: var(--c-blue-300);
        --tint-video-subtle: rgba(90, 162, 244, 0.16);
        --tint-video-subtle-hover: rgba(90, 162, 244, 0.24);
        --tint-video-border: rgba(255, 255, 255, 0.1);

        --tint-music-glyph: var(--c-violet-300);
        --tint-music-subtle: rgba(168, 132, 245, 0.16);
        --tint-music-subtle-hover: rgba(168, 132, 245, 0.24);
        --tint-music-border: rgba(255, 255, 255, 0.1);

        --tint-photo-glyph: var(--c-teal-300);
        --tint-photo-subtle: rgba(69, 189, 180, 0.16);
        --tint-photo-subtle-hover: rgba(69, 189, 180, 0.24);
        --tint-photo-border: rgba(255, 255, 255, 0.1);

        --tint-vault-glyph: var(--c-rose-300);
        --tint-vault-subtle: rgba(242, 122, 151, 0.16);
        --tint-vault-subtle-hover: rgba(242, 122, 151, 0.24);
        --tint-vault-border: rgba(255, 255, 255, 0.1);

        --tint-admin-glyph: var(--c-slate-300);
        --tint-admin-subtle: rgba(125, 140, 173, 0.18);
        --tint-admin-subtle-hover: rgba(125, 140, 173, 0.26);
        --tint-admin-border: rgba(255, 255, 255, 0.1);

        --tint-editorial-glyph: var(--c-amber-300);
        --tint-editorial-subtle: rgba(234, 168, 31, 0.16);
        --tint-editorial-subtle-hover: rgba(234, 168, 31, 0.24);
        --tint-editorial-border: rgba(255, 255, 255, 0.1);

        --tint-neutral-glyph: var(--text-tertiary);
        --tint-neutral-subtle: var(--surface-hover);
        --tint-neutral-subtle-hover: var(--surface-sunken);
        --tint-neutral-border: rgba(255, 255, 255, 0.1);

        --brand-mark-fill: linear-gradient(145deg, var(--c-blue-400), var(--c-blue-600));
        --brand-mark-glyph: var(--c-gray-0);

        /* 深色下空封面必须压回画布一侧，否则它比任何一张真封面都亮。 */
        --artwork-fallback-a: var(--c-gray-700);
        --artwork-fallback-b: var(--c-gray-800);
        --select-caret: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%238892a3' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m5.5 9 6.5 7 6.5-7'/%3E%3C/svg%3E");
        --check-mark: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2308111d' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m5 12.5 4.8 4.8L19 7.5'/%3E%3C/svg%3E");

        /* Dark glass tints toward the canvas rather than toward white: a light
           translucent panel over a dark backdrop turns milky and loses its edge. */
        --glass-thin-bg: rgba(38, 44, 56, 0.6);
        --glass-thin-blur: blur(12px) saturate(150%);
        --glass-thin-border: rgba(255, 255, 255, 0.1);
        --glass-thin-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.08);
        --glass-thin-shadow: var(--shadow-1);
        --glass-thin-opaque: rgba(38, 44, 56, 0.98);

        --glass-regular-bg: rgba(30, 36, 46, 0.72);
        --glass-regular-blur: blur(24px) saturate(180%);
        --glass-regular-border: rgba(255, 255, 255, 0.11);
        --glass-regular-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.09);
        --glass-regular-shadow: var(--shadow-3);
        --glass-regular-opaque: var(--c-gray-850);

        --glass-thick-bg: rgba(24, 29, 38, 0.76);
        --glass-thick-blur: blur(40px) saturate(180%);
        --glass-thick-border: rgba(255, 255, 255, 0.1);
        --glass-thick-highlight: inset 0 1px 0 rgba(255, 255, 255, 0.08);
        --glass-thick-shadow: var(--shadow-4);
        --glass-thick-opaque: var(--c-gray-900);

        --overlay-on-media: rgba(8, 11, 18, 0.58);
        --overlay-on-media-strong: rgba(8, 11, 18, 0.78);
        --text-on-media: #ffffff;
        --text-on-media-secondary: rgba(255, 255, 255, 0.76);
        --text-on-media-shadow: 0 1px 3px rgba(0, 0, 0, 0.62), 0 0 1px rgba(0, 0, 0, 0.45);
        --media-scrim: linear-gradient(to top, rgba(4, 6, 11, 0.9) 0%, rgba(4, 6, 11, 0.5) 38%, rgba(4, 6, 11, 0) 74%);
        --on-media-scrim-strong: rgba(4, 6, 11, 0.9);
        --on-media-scrim-mid: rgba(4, 6, 11, 0.5);
        --on-media-scrim-clear: rgba(4, 6, 11, 0);
        --btn-on-media-fill: rgba(255, 255, 255, 0.16);
        --btn-on-media-fill-hover: rgba(255, 255, 255, 0.26);
        --btn-on-media-fill-active: rgba(255, 255, 255, 0.32);
        --btn-on-media-border: rgba(255, 255, 255, 0.2);
        --btn-on-media-blur: blur(20px) saturate(160%);
        --btn-on-media-opaque: rgba(20, 25, 33, 0.95);
        --btn-on-media-strong-fill: rgba(255, 255, 255, 0.94);
        --btn-on-media-strong-hover: #ffffff;
        --btn-on-media-strong-label: #0b1017;
        --track-on-media: rgba(255, 255, 255, 0.26);
        --thumb-on-media: #ffffff;
        --thumb-on-media-shadow: 0 1px 3px rgba(0, 0, 0, 0.62);

        --skeleton-base: rgba(255, 255, 255, 0.07);
        --skeleton-sheen: rgba(255, 255, 255, 0.12);

        /* Dark holds the wash down instead of washing it out. */
        --hero-ambient-veil: rgba(18, 22, 28, 0.68);
    """#

    private static let componentTokens = #"""
      :root {
        /* Buttons */
        --btn-height-sm: var(--control-height-sm);
        --btn-height-md: var(--control-height-md);
        --btn-height-lg: var(--control-height-lg);
        --btn-radius: var(--radius-sm);
        --btn-radius-lg: var(--radius-md);
        --btn-pad-sm: 0 var(--space-3);
        --btn-pad-md: 0 var(--space-4);
        --btn-pad-lg: 0 var(--space-5);
        --btn-gap: var(--space-2);
        --btn-font: var(--type-callout-size);
        --btn-weight: var(--weight-semibold);

        /* Fields */
        --field-height: var(--control-height-md);
        --field-height-lg: var(--control-height-lg);
        --field-radius: var(--radius-sm);
        --field-bg: var(--surface);
        --field-border: var(--border);
        --field-border-hover: var(--border-strong);
        --field-placeholder: var(--text-tertiary);

        /* Icon tiles — geometry only; the fills live in the semantic layer
           because they have to differ between appearances.  Three sizes cover
           every container in the product: sm sits inline beside a label, md is
           the brand mark and the section head, lg is the page-header tile. */
        --icon-tile-size-sm: 34px;
        --icon-tile-size-md: 44px;
        --icon-tile-size-lg: 52px;
        --icon-tile-radius-sm: var(--radius-xs);
        --icon-tile-radius-md: var(--radius-sm);
        --icon-tile-radius-lg: var(--radius-md);

        /* Navigation */
        --nav-item-height: 36px;
        --nav-item-radius: var(--radius-sm);
        --nav-icon-size: var(--icon-md);
        --nav-gap: 2px;

        /* Cards & media */
        --card-radius: var(--radius-md);
        --card-pad: var(--space-5);
        --poster-radius: var(--radius-md);
        --poster-ratio: 2 / 3;
        --grid-min: 168px;
        --grid-gap: var(--space-5);

        /* Overlays */
        --overlay-radius: var(--radius-md);
        --menu-min-width: 200px;
        --toast-width: 360px;

        /* Tables & lists */
        --row-height: 48px;
        --row-radius: var(--radius-sm);
      }
    """#

    /// Bridge for the previous token namespace.
    ///
    /// The home shelves and a handful of media surfaces carry curated layouts
    /// written against `--ml-*`.  Re-pointing those names at the new semantic
    /// tokens themes them correctly in both appearances immediately, without
    /// rewriting layout that is already good — and, unlike the old shim, the
    /// aliases now resolve to values that actually change with the theme.
    ///
    /// Deliberately alias-only: nothing new should be written against these.
    /// 把一个域的识别色投射到 `--tint-*` 四个通用名下。
    ///
    /// 属性写在**容器**上（区块、卡片、页头），底板、胶囊、徽章靠继承拿到它——
    /// 于是「这一栏是音乐」只需要声明一次，而不是给里面每个元素各挂一个类。
    ///
    /// 渐变故意不在这里拼：自定义属性的 `var()` 在声明它的那个元素上替换，
    /// 一条写死的 `linear-gradient(...)` 收进令牌之后，元素侧的端点色就再也
    /// 代不进去了（设计文档 §7 记着这条让全站取色失效过一次）。这里只投端点色。
    private static let identityTintScopes: String = {
        let domains = ["video", "music", "photo", "vault", "admin", "editorial", "neutral"]
        return domains.map { domain in
            """
            [data-tint="\(domain)"] {
              --tint-glyph: var(--tint-\(domain)-glyph);
              --tint-fill-a: var(--tint-\(domain)-subtle-hover);
              --tint-fill-b: var(--tint-\(domain)-subtle);
              --tint-border: var(--tint-\(domain)-border);
            }
            """
        }.joined(separator: "\n")
    }()

    private static let compatibilityAliases = #"""
      :root {
        --ml-bg: var(--bg-canvas);
        --ml-bg-raised: var(--surface);
        --ml-sidebar: var(--glass-thick-bg);
        --ml-surface: var(--surface);
        --ml-surface-2: var(--surface-raised);
        --ml-text: var(--text-primary);
        --ml-text-2: var(--text-secondary);
        --ml-text-3: var(--text-tertiary);
        --ml-line: var(--border);
        --ml-brand: var(--accent);
        --ml-brand-hover: var(--accent-hover);
        --ml-accent: var(--accent);
        --ml-success: var(--success);
        --ml-danger: var(--error);
        --ml-focus: var(--focus-ring);
        --ml-shadow: var(--shadow-2);
        --ml-shadow-hover: var(--shadow-3);
        --ml-radius-sm: var(--radius-xs);
        --ml-radius: var(--radius-sm);
        --ml-radius-lg: var(--radius-md);
        --ml-radius-xl: var(--radius-lg);
        --ml-ease: var(--ease-out);
        --ml-duration: var(--duration-base);
        --ml-sidebar-width: var(--sidebar-width);
        --ml-content: var(--page-max);
        --ml-gutter: var(--page-gutter);

        --ink: var(--text-primary);
        --muted: var(--text-secondary);
        --line: var(--border);
        --canvas: var(--bg-canvas);
        --card: var(--surface);
        --primary: var(--accent);
        --primary-strong: var(--accent-hover);
        --blue: var(--accent);
        --strong: var(--accent-hover);
        --danger: var(--error);
        --focus: var(--focus-ring-color);
        --ease: var(--ease-out);
      }
    """#

    /// Translucency is a progressive enhancement, never a load-bearing one.
    ///
    /// Three independent signals collapse the glass tokens to their opaque
    /// counterparts: no `backdrop-filter` support, the user asking for reduced
    /// transparency, and the user asking for more contrast.  Because the
    /// substitution happens on the tokens themselves, every glass surface in the
    /// product degrades at once instead of one selector at a time.
    private static let materialFallbacks = #"""
      @supports not ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px))) {
        :root {
          --glass-thin-bg: var(--glass-thin-opaque);
          --glass-regular-bg: var(--glass-regular-opaque);
          --glass-thick-bg: var(--glass-thick-opaque);
          --glass-thin-blur: none;
          --glass-regular-blur: none;
          --glass-thick-blur: none;
          --btn-on-media-fill: var(--btn-on-media-opaque);
          --btn-on-media-blur: none;
          /* 播放器控制条与浮层用的是这一档。模糊被撤掉之后，半透明的底就再也
             压不住画面细节了，所以它必须同时推到接近不透明。 */
          --overlay-on-media-strong: rgba(10, 13, 20, 0.96);
        }
      }
      @media (prefers-reduced-transparency: reduce) {
        :root {
          --glass-thin-bg: var(--glass-thin-opaque);
          --glass-regular-bg: var(--glass-regular-opaque);
          --glass-thick-bg: var(--glass-thick-opaque);
          --glass-thin-blur: none;
          --glass-regular-blur: none;
          --glass-thick-blur: none;
          --btn-on-media-fill: var(--btn-on-media-opaque);
          --btn-on-media-blur: none;
          /* 播放器控制条与浮层用的是这一档。模糊被撤掉之后，半透明的底就再也
             压不住画面细节了，所以它必须同时推到接近不透明。 */
          --overlay-on-media-strong: rgba(10, 13, 20, 0.96);
        }
      }
      @media (prefers-contrast: more) {
        :root {
          --glass-thin-bg: var(--glass-thin-opaque);
          --glass-regular-bg: var(--glass-regular-opaque);
          --glass-thick-bg: var(--glass-thick-opaque);
          --glass-thin-blur: none;
          --glass-regular-blur: none;
          --glass-thick-blur: none;
          --btn-on-media-fill: var(--btn-on-media-opaque);
          --btn-on-media-blur: none;
          /* 播放器控制条与浮层用的是这一档。模糊被撤掉之后，半透明的底就再也
             压不住画面细节了，所以它必须同时推到接近不透明。 */
          --overlay-on-media-strong: rgba(10, 13, 20, 0.96);
          /* 高对比下画面上的文字不再靠阴影和半透明遮罩救场：遮罩推到不透明，
             次级文字提到与主文字同色。 */
          --btn-on-media-border: rgba(255, 255, 255, 0.5);
          --on-media-scrim-mid: var(--on-media-scrim-strong);
          --text-on-media-secondary: var(--text-on-media);
          /* 高对比下纵深层要让路：提亮渐变会把实心填充的上沿冲淡，正好削掉
             用户要的那点对比。图标底板改用实边而不是渐变来立轮廓。 */
          --fill-raise: none;
          --fill-raise-soft: none;
          --inner-highlight: none;
          --inner-highlight-strong: none;
          --icon-tile-border: var(--border-strong);
          --border: var(--border-strong);
          --divider: var(--border-strong);
          --text-secondary: var(--text-primary);
          --text-tertiary: var(--text-secondary);
        }
      }
    """#
}
