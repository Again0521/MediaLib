import Foundation

/// Layer 3 of the Web design system: the reusable control vocabulary.
///
/// Every interactive surface in the product is expected to come from here, fully
/// specified across default / hover / active / focus-visible / disabled /
/// selected in both themes.  Page stylesheets supply layout only.
///
/// Two rules the whole sheet obeys:
///
/// * **State never changes layout.** Hover, press, selection and disabled alter
///   colour, shadow and paint-only transforms — never height, padding or border
///   width — so nothing around them shifts.
/// * **Glass is structural.** Only surfaces that genuinely float above scrolling
///   content take a `--glass-*` material.  Ordinary content sits directly on the
///   canvas.
enum ServerWebPrimitives {
    static let css: String = """
    @layer primitives {
    \(layout)
    \(surfaces)
    \(buttons)
    \(controlBar)
    \(fields)
    \(choiceControls)
    \(segmentedAndTabs)
    \(indicators)
    \(listsAndTables)
    \(overlays)
    \(feedback)
    \(media)
    \(stateLine)
    \(loadMore)
    \(trackRows)
    \(pointerAndTouch)
    }
    """

    // MARK: - Layout helpers

    private static let layout = #"""
      .ui-stack { display: flex; flex-direction: column; gap: var(--space-4); }
      .ui-stack-sm { gap: var(--space-2); }
      .ui-stack-lg { gap: var(--space-7); }

      /* Wraps instead of overflowing: toolbars and action rows must survive a
         narrow viewport without a horizontal scrollbar. */
      .ui-cluster {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--space-2);
      }
      .ui-cluster-between {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: var(--space-4);
      }
      .ui-spacer { flex: 1 1 auto; min-width: 0; }

      .ui-section { display: flex; flex-direction: column; gap: var(--space-4); }
      .ui-section + .ui-section { margin-top: var(--space-9); }
      .ui-section-head {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        justify-content: space-between;
        gap: var(--space-3);
      }
      /* 标题前的图标底板和标题本身是**一组**，不是区块头的第三个孩子。
         区块头靠 `justify-content: space-between` 把「更多」顶到行尾——多一个
         直接子元素，三样东西就会被均分开，标题飘到行中央。 */
      .ui-section-identity {
        display: flex;
        min-width: 0;
        align-items: center;
        gap: var(--space-3);
      }
      /* 区块标题走 title-1，不是 title-2。
         此前是 21/600，而卡片标题是 14/600——两级之间只差一档字号，滚过去像是
         同一栏重复了十遍。两个参考页（App Store「探索」、Apple Music「新发现」）
         的区块头都在 24–28/700 这一档，编辑感几乎全部来自这一个决定。 */
      .ui-section-head h2 {
        font-size: var(--type-title1-size);
        line-height: var(--type-title1-line);
        letter-spacing: var(--type-title1-track);
        font-weight: var(--weight-bold);
      }
      /* 标题即出口。`›` 只在悬停/聚焦时前移，标题本身不动——一行大字整体位移
         会把下面的整排卡片一起带得发抖。 */
      .ui-section-link {
        display: inline-flex;
        align-items: center;
        gap: 2px;
        color: inherit;
      }
      .ui-section-link:hover { color: var(--accent-text); }
      .ui-section-chevron {
        flex: none;
        color: var(--text-tertiary);
        transition: transform var(--duration-fast) var(--ease-out), color var(--duration-fast) var(--ease-out);
      }
      .ui-section-link:hover .ui-section-chevron,
      .ui-section-link:focus-visible .ui-section-chevron {
        color: var(--accent-text);
        transform: translateX(2px);
      }
      /* 文字按钮不换行。
         「进入音乐 ›」这种两三个字加一个箭头的控件，一旦被挤到断行，箭头会独自
         掉到第二行，看起来像渲染坏了。它本来就该在放不下时整体让位，而不是把
         自己拆开。`flex: none` 是为了在 flex 容器里不被压缩到收缩点。 */
      .ui-section-more {
        display: inline-flex;
        min-height: var(--control-height-lg);
        align-items: center;
        flex: none;
        gap: 2px;
        color: var(--accent-text);
        font-size: var(--type-callout-size);
        font-weight: var(--weight-semibold);
        white-space: nowrap;
      }
      .ui-section-more:hover { text-decoration: underline; }

      /* 横向列表的翻页键。
         客户端把它们放在列表**之外**、内容轨的留白里，做成一条细线箭头——压在
         内容上的圆形按钮会挡住卡片，而这一排卡片本身就是要看的东西。
         只在指针悬停在这条轨道上、且那个方向确实还有内容时出现；到头即隐藏，
         一个按下去没反应的箭头比没有更让人怀疑是不是坏了。 */
      /* `min-width: 0` 不是可选的。
         这个包裹层是脚本插进来的，它落在什么容器里由页面决定；一旦父级是 flex 或
         grid，它作为项目的 `min-width` 默认是 `auto`，于是会被里面 3000px 宽的轨
         道整个撑开——轨道自己再也不会溢出，横向滚动跑到了页面上。 */
      .ui-rail { position: relative; min-width: 0; max-width: 100%; }
      .ui-rail-step {
        position: absolute;
        top: 50%;
        z-index: 2;
        display: grid;
        width: 28px;
        /* 加高不加宽，和 banner 的翻页键同一个形状：跟随轨道高度，而不是一个固定
           的小方块——一条贯穿整排卡片的细长条更好瞄准，也更像"翻到下一页"。 */
        height: 100%;
        max-height: 384px;
        place-items: center;
        transform: translateY(-50%);
        border: 0;
        border-radius: var(--radius-sm);
        color: var(--text-tertiary);
        background: transparent;
        cursor: pointer;
        opacity: 0;
        transition: opacity var(--duration-fast) var(--ease-out), color var(--duration-fast) var(--ease-out);
      }
      .ui-rail-step:hover { color: var(--text-primary); }
      .ui-rail-glyph { width: 20px; height: 52px; }
      .ui-rail-previous { right: calc(100% + 2px); }
      .ui-rail-next { left: calc(100% + 2px); }
      .ui-rail:hover .ui-rail-step,
      .ui-rail:focus-within .ui-rail-step { opacity: 1; }
      .ui-rail-step[hidden] { display: none; }
      /* 拖动过程中不要让卡片继续响应 hover，否则整排卡片会跟着指针闪。 */
      .ui-rail.is-dragging { cursor: grabbing; }
      .ui-rail.is-dragging * { pointer-events: none; }
      /* 触摸设备用原生惯性滚动，不需要这两个键。窄视口也直接隐藏：浏览器设备
         模拟、外接鼠标平板和小窗桌面仍可能报告 fine pointer，若只看 pointer，
         放在轨道外侧的箭头会把整页撑宽。 */
      @media (hover: none), (pointer: coarse), (max-width: 719px) {
        .ui-rail-step { display: none; }
      }

      .ui-divider {
        height: var(--hairline);
        border: 0;
        background: var(--divider);
      }

      /* Wide content (tables, code, timelines) scrolls inside its own well so the
         page body never scrolls sideways. */
      .ui-scroll-x {
        overflow-x: auto;
        overscroll-behavior-x: contain;
        -webkit-overflow-scrolling: touch;
      }
    """#

    // MARK: - Surfaces

    private static let surfaces = #"""
      /* ---- 图标底板 --------------------------------------------------------
         产品里所有"圆角方块 + 一枚图标"的容器都是这一个组件：页头标题图标、
         侧栏品牌标、空态、首页统计格、区块头。此前它们是六份各自硬编码的
         尺寸与内高光，于是同一屏里能同时出现 34、36、44、52 四种底板。

         三档尺寸、三种取向。取向决定底与字形的颜色，尺寸只决定几何——这样
         "换个大小"和"换个语气"是两件互不干扰的事。 */
      .ui-icon-tile {
        display: grid;
        flex: none;
        place-items: center;
        border: var(--hairline) solid transparent;
        box-shadow: var(--inner-highlight), var(--shadow-1);
      }
      .ui-icon-tile-sm {
        width: var(--icon-tile-size-sm);
        height: var(--icon-tile-size-sm);
        border-radius: var(--icon-tile-radius-sm);
      }
      .ui-icon-tile-md {
        width: var(--icon-tile-size-md);
        height: var(--icon-tile-size-md);
        border-radius: var(--icon-tile-radius-md);
      }
      .ui-icon-tile-lg {
        width: var(--icon-tile-size-lg);
        height: var(--icon-tile-size-lg);
        border-radius: var(--icon-tile-radius-lg);
      }
      .ui-icon-tile-accent {
        color: var(--icon-tile-glyph);
        border-color: var(--icon-tile-border);
        background: var(--icon-tile-fill);
      }
      .ui-icon-tile-quiet {
        color: var(--icon-tile-glyph-quiet);
        border-color: var(--border);
        background: var(--icon-tile-fill-quiet);
      }
      /* 识别色底板。颜色由祖先上的 `data-tint="…"` 投过来，本身不认识任何
         具体色相——加一个域只需要在令牌层多一条 `[data-tint]`，这里一个字不改。
         没有 `data-tint` 的落点回退到强调色，与 `-accent` 完全一致。 */
      .ui-icon-tile-tint {
        color: var(--tint-glyph, var(--icon-tile-glyph));
        border-color: var(--tint-border, var(--icon-tile-border));
        background-image: linear-gradient(155deg,
          var(--tint-fill-a, var(--accent-subtle-hover)),
          var(--tint-fill-b, var(--accent-subtle)));
      }
      /* 实心品牌底：唯一一处让字形反白的底板，只给品牌标与锁标。 */
      .ui-icon-tile-brand {
        color: var(--brand-mark-glyph);
        background: var(--brand-mark-fill);
        box-shadow: var(--inner-highlight-strong), var(--shadow-2);
      }
      /* 实心底上的双色面层要反过来提亮，不然它是在往品牌色里掺黑。 */
      .ui-icon-tile-brand .icon-duotone-shade { opacity: 0.3; }

      .ui-surface {
        border: var(--hairline) solid var(--border);
        border-radius: var(--card-radius);
        background: var(--surface);
      }
      .ui-card {
        display: flex;
        flex-direction: column;
        gap: var(--space-3);
        padding: var(--card-pad);
        border: var(--hairline) solid var(--border);
        border-radius: var(--card-radius);
        background: var(--surface);
        box-shadow: var(--shadow-1);
      }
      .ui-card-quiet { box-shadow: none; background: transparent; }
      .ui-card-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--space-3);
      }
      .ui-card-title {
        font-size: var(--type-title3-size);
        line-height: var(--type-title3-line);
        letter-spacing: var(--type-title3-track);
        font-weight: var(--weight-semibold);
      }

      /* Interactive cards lift on hover only in the paint layer.  The translate
         is 2px: enough to read as "this responds", small enough that a grid of
         them does not shimmer as the pointer crosses it. */
      .ui-card-interactive {
        cursor: pointer;
        transition:
          box-shadow var(--duration-base) var(--ease-out),
          border-color var(--duration-base) var(--ease-out),
          transform var(--duration-base) var(--ease-out);
      }
      .ui-card-interactive:hover {
        border-color: var(--border-strong);
        box-shadow: var(--shadow-3);
        transform: translateY(-2px);
      }
      .ui-card-interactive:active { transform: translateY(0); box-shadow: var(--shadow-1); }

      /* The three materials.  A glass surface is never nested inside another —
         two translucent layers stacked lose all legibility. */
      .ui-glass-thin, .ui-glass, .ui-glass-thick {
        border: var(--hairline) solid var(--glass-regular-border);
        border-radius: var(--card-radius);
      }
      .ui-glass-thin {
        border-color: var(--glass-thin-border);
        background: var(--glass-thin-bg);
        -webkit-backdrop-filter: var(--glass-thin-blur);
        backdrop-filter: var(--glass-thin-blur);
        box-shadow: var(--glass-thin-highlight), var(--glass-thin-shadow);
      }
      .ui-glass {
        background: var(--glass-regular-bg);
        -webkit-backdrop-filter: var(--glass-regular-blur);
        backdrop-filter: var(--glass-regular-blur);
        box-shadow: var(--glass-regular-highlight), var(--glass-regular-shadow);
      }
      .ui-glass-thick {
        border-color: var(--glass-thick-border);
        background: var(--glass-thick-bg);
        -webkit-backdrop-filter: var(--glass-thick-blur);
        backdrop-filter: var(--glass-thick-blur);
        box-shadow: var(--glass-thick-highlight), var(--glass-thick-shadow);
      }

      /* Where floating chrome overlaps scrolling content, fade the meeting point
         instead of drawing a hard 1px rule under it. */
      .ui-scroll-edge {
        position: relative;
      }
      .ui-scroll-edge::after {
        content: "";
        position: absolute;
        z-index: 1;
        right: 0;
        bottom: -20px;
        left: 0;
        height: 20px;
        pointer-events: none;
        background: linear-gradient(to bottom, var(--bg-canvas), transparent);
      }
    """#

    // MARK: - Buttons

    private static let buttons = #"""
      .ui-btn {
        position: relative;
        display: inline-flex;
        min-width: 0;
        height: var(--btn-height-md);
        align-items: center;
        justify-content: center;
        gap: var(--btn-gap);
        padding: var(--btn-pad-md);
        border: var(--hairline) solid transparent;
        border-radius: var(--btn-radius);
        font-size: var(--btn-font);
        font-weight: var(--btn-weight);
        line-height: 1;
        white-space: nowrap;
        cursor: pointer;
        user-select: none;
        transition:
          background-color var(--duration-fast) var(--ease-out),
          border-color var(--duration-fast) var(--ease-out),
          color var(--duration-fast) var(--ease-out),
          box-shadow var(--duration-fast) var(--ease-out),
          transform var(--duration-instant) var(--ease-out);
      }
      .ui-btn > svg { width: var(--icon-sm); height: var(--icon-sm); flex: none; }
      /* 按钮里的文字同样不拆行——`.ui-btn` 已有 `white-space: nowrap`，这里保证
         内部的 <span> 不会自己再断一次。 */
      .ui-btn > span { white-space: nowrap; }
      /* Feedback lands on press, not on release. */
      .ui-btn:active { transform: scale(0.97); }

      /* 实心按钮不是"填了色的矩形"。

         填充分两层写：`background-color` 给实色，`background-image` 给那条
         `--fill-raise` 提亮渐变。分开的好处是 hover/active 只需要换颜色那一层，
         提亮层原地不动——写成一条 `background` 简写的话，每换一次状态都要把渐变
         整条重抄一遍，抄漏一次按钮就在 hover 时突然变平。

         阴影同样是两件事叠起来：顶部一道 `--inner-highlight` 内高光（光打在
         上沿），底下一层 `--shadow-accent-1` 彩色高程（自己颜色的落影）。一颗蓝
         按钮投中性灰影会像贴在纸上，投自己的颜色才像一块发着光的实体。 */
      .ui-btn-primary {
        color: var(--text-on-accent);
        background-color: var(--accent);
        background-image: var(--fill-raise);
        box-shadow: var(--inner-highlight), var(--shadow-accent-1);
      }
      .ui-btn-primary:hover {
        background-color: var(--accent-hover);
        box-shadow: var(--inner-highlight), var(--shadow-accent-2);
      }
      /* 按下时高程和内高光一起收掉：实体被按进纸面，光就不该还停在它上沿。 */
      .ui-btn-primary:active { background-color: var(--accent-active); box-shadow: none; }

      .ui-btn-secondary {
        color: var(--text-primary);
        border-color: var(--border);
        background-color: var(--surface);
        background-image: var(--fill-raise-soft);
        box-shadow: var(--shadow-1);
      }
      .ui-btn-secondary:hover {
        border-color: var(--border-strong);
        background-color: var(--surface-hover);
        box-shadow: var(--shadow-2);
      }
      .ui-btn-secondary:active { background-color: var(--surface-active); background-image: none; box-shadow: none; }

      /* 淡色按钮此前没有任何边——放在白卡上时它只是一小块浅蓝，读不出"这是个
         可按的东西"。一条同色发丝边足够立住轮廓，又不至于抢到实心按钮前面。 */
      .ui-btn-tinted {
        color: var(--accent-text);
        border-color: var(--icon-tile-border);
        background-color: var(--accent-subtle);
        background-image: var(--fill-raise-soft);
      }
      .ui-btn-tinted:hover { background-color: var(--accent-subtle-hover); }
      .ui-btn-tinted:active { background-image: none; }

      .ui-btn-ghost { color: var(--text-secondary); background: transparent; }
      .ui-btn-ghost:hover { color: var(--text-primary); background: var(--surface-hover); }
      .ui-btn-ghost:active { background: var(--surface-active); }

      /* Destructive actions read as destructive before they are pressed, and are
         visually separated from the confirming action beside them. */
      .ui-btn-destructive {
        color: var(--error);
        border-color: var(--border);
        background: var(--error-subtle);
      }
      .ui-btn-destructive:hover { color: var(--text-on-accent); background: var(--error); border-color: transparent; }

      /* Buttons that land on artwork rather than on a page surface.
         `--accent` cannot do this job: a solid accent fill competes with
         whatever colour the poster happens to be, and on a bright frame it
         loses its edge entirely.  A material fill borrows the image's own
         colour, so it stays separable on every frame.  `strong` is the one
         primary action on the surface; the plain variant is what sits beside
         it.  Both are foreground chrome, so the material is allowed here. */
      .ui-btn-on-media-strong {
        color: var(--btn-on-media-strong-label);
        border-color: transparent;
        background: var(--btn-on-media-strong-fill);
        box-shadow: var(--shadow-2);
      }
      .ui-btn-on-media-strong:hover { background: var(--btn-on-media-strong-hover); }
      .ui-btn-on-media-strong:active { box-shadow: none; }

      .ui-btn-on-media {
        color: var(--text-on-media);
        border-color: var(--btn-on-media-border);
        background: var(--btn-on-media-fill);
        -webkit-backdrop-filter: var(--btn-on-media-blur);
        backdrop-filter: var(--btn-on-media-blur);
        box-shadow: var(--shadow-2);
        text-shadow: var(--text-on-media-shadow);
      }
      .ui-btn-on-media:hover { background: var(--btn-on-media-fill-hover); }
      .ui-btn-on-media:active { background: var(--btn-on-media-fill-active); box-shadow: none; }

      .ui-btn-sm { height: var(--btn-height-sm); padding: var(--btn-pad-sm); font-size: var(--type-subhead-size); }
      .ui-btn-lg { height: var(--btn-height-lg); padding: var(--btn-pad-lg); font-size: var(--type-body-size); }

      .ui-btn-icon {
        width: var(--btn-height-md);
        padding: 0;
        border-radius: var(--btn-radius);
      }
      .ui-btn-icon.ui-btn-sm { width: var(--btn-height-sm); }
      .ui-btn-icon.ui-btn-lg { width: var(--btn-height-lg); }
      .ui-btn-icon > svg { width: var(--icon-md); height: var(--icon-md); }
      .ui-btn-round { border-radius: var(--radius-pill); }
      .ui-btn-block { display: flex; width: 100%; }

      .ui-btn:disabled, .ui-btn[aria-disabled="true"] {
        cursor: not-allowed;
        opacity: 0.45;
        box-shadow: none;
        transform: none;
      }
      .ui-btn:disabled:hover, .ui-btn[aria-disabled="true"]:hover {
        background: inherit;
        border-color: inherit;
      }

      /* Busy state keeps the label in place so the control does not resize
         mid-request; the spinner replaces the leading icon slot. */
      .ui-btn[data-busy="true"] { pointer-events: none; color: transparent; }
      .ui-btn[data-busy="true"]::after {
        content: "";
        position: absolute;
        width: var(--icon-sm);
        height: var(--icon-sm);
        border: 2px solid currentColor;
        border-radius: 50%;
        border-top-color: transparent;
        color: var(--text-on-accent);
        animation: ui-spin 0.7s linear infinite;
      }
      .ui-btn-secondary[data-busy="true"]::after,
      .ui-btn-ghost[data-busy="true"]::after { color: var(--text-secondary); }

      /* A toolbar is floating chrome, so it carries the regular material and its
         buttons drop their own backgrounds to avoid glass-on-glass. */
      .ui-toolbar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--space-2);
        padding: var(--space-2);
        border: var(--hairline) solid var(--glass-regular-border);
        border-radius: var(--radius-md);
        background: var(--glass-regular-bg);
        -webkit-backdrop-filter: var(--glass-regular-blur);
        backdrop-filter: var(--glass-regular-blur);
        box-shadow: var(--glass-regular-highlight), var(--shadow-2);
      }
      .ui-toolbar-sticky {
        position: sticky;
        z-index: var(--z-sticky);
        top: var(--space-3);
      }
      .ui-toolbar .ui-btn-secondary { background: transparent; box-shadow: none; border-color: transparent; }
      .ui-toolbar .ui-btn-secondary:hover { background: var(--surface-hover); }
    """#

    // MARK: - Filter / sort bar

    /// The one filter row, shared by every browsing surface.
    ///
    /// It reproduces the desktop client's `AppAdaptiveControlBar`: a card holding
    /// a sunken tray of state pills on the left and the dropdowns on the right.
    /// Pages used to grow one of these each — a bare form here, a glass toolbar
    /// there, two stacked toolbars on music — so the same three controls sat at
    /// three different heights on three different materials.
    ///
    /// It is deliberately **not** glass.  The bar scrolls with the content it
    /// filters, and a translucent surface that never floats over anything only
    /// costs a blur.
    private static let controlBar = #"""
      .ui-control-bar {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        padding: 11px 14px;
        border: var(--hairline) solid var(--control-bar-border);
        border-radius: var(--radius-md);
        background: var(--control-bar-bg);
        box-shadow: var(--shadow-1);
      }
      .ui-control-tray {
        display: flex;
        min-width: 0;
        align-items: center;
        gap: var(--space-2);
        min-height: 44px;
        padding: 5px;
        border: var(--hairline) solid var(--control-tray-border);
        border-radius: var(--radius-md);
        background: var(--control-tray-bg);
        overflow-x: auto;
        scrollbar-width: none;
      }
      .ui-control-tray::-webkit-scrollbar { display: none; }
      /* The tray already draws the recessed track, so the segmented control
         inside it drops its own — two nested sunken fills read as a seam. */
      .ui-control-tray > .ui-segmented {
        padding: 0;
        background: transparent;
        overflow: visible;
      }
      .ui-control-bar-trailing {
        display: flex;
        flex: 0 0 auto;
        align-items: center;
        gap: var(--space-2);
        margin-left: auto;
      }
      /* Optional narrow-layout actions (for example a progressive-disclosure
         trigger) stay out of the desktop row unless a page opts them in. */
      .ui-control-bar-mobile-trailing { display: none; }
      .ui-control-bar-trailing .ui-select { width: auto; min-width: 132px; }

      /* Sort is a key plus a direction.  A single `<select>` cannot express
         "choose the same key again to flip", which is how the client behaves, so
         the direction is its own toggle beside the key. */
      .ui-sort-control { display: flex; align-items: center; gap: 6px; }
      .ui-sort-order {
        display: inline-flex;
        width: var(--field-height);
        height: var(--field-height);
        flex: none;
        align-items: center;
        justify-content: center;
        border: var(--hairline) solid var(--field-border);
        border-radius: var(--field-radius);
        color: var(--text-secondary);
        background: var(--field-bg);
        cursor: pointer;
        transition:
          color var(--duration-fast) var(--ease-out),
          border-color var(--duration-fast) var(--ease-out),
          background-color var(--duration-fast) var(--ease-out),
          transform var(--duration-fast) var(--ease-out);
      }
      /* One arrow, two orientations — the direction is the whole meaning of the
         control, so it turns rather than being swapped for a second glyph. */
      .ui-sort-order > svg {
        width: var(--icon-sm);
        height: var(--icon-sm);
        transition: transform var(--duration-base) var(--ease-spring);
      }
      .ui-sort-order.is-reversed > svg { transform: rotate(180deg); }
      .ui-sort-order:hover { color: var(--text-primary); border-color: var(--field-border-hover); }
      .ui-sort-order:active { transform: scale(0.94); }
      .ui-sort-order:focus-visible { outline: none; border-color: var(--accent); box-shadow: var(--focus-ring); }
      .ui-sort-order[aria-pressed="true"] {
        color: var(--accent-text);
        border-color: transparent;
        background: var(--accent-subtle);
      }

      /* Narrow: the tray takes its own full-width row and scrolls, the trailing
         controls drop below it right-aligned.  Same two branches the client's
         `ViewThatFits` falls back through. */
      @media (max-width: 719px) {
        .ui-control-bar {
          flex-direction: column;
          align-items: stretch;
          gap: var(--space-2);
        }
        .ui-control-tray { width: 100%; }
        .ui-control-bar-trailing { margin-left: 0; justify-content: flex-end; flex-wrap: wrap; }
        /* Every browsing surface with secondary controls uses the same mobile
           progressive disclosure: state/category pills stay on the first row,
           the icon trigger remains independent at the right, and the expanded
           controls form one left-to-right rail instead of a right-aligned wrap. */
        .ui-control-bar.is-mobile-disclosable {
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto;
          align-items: center;
        }
        .ui-control-bar.is-mobile-disclosable > .ui-control-tray { width: 100%; min-width: 0; }
        .ui-control-bar.is-mobile-disclosable > .ui-control-bar-mobile-trailing {
          display: flex;
          grid-column: 2;
          justify-content: flex-end;
        }
        .ui-control-bar-disclosure { min-width: 44px; min-height: 44px; }
        .ui-control-bar.is-mobile-disclosable > .ui-control-bar-trailing {
          display: none;
          width: 100%;
          min-width: 0;
          grid-column: 1 / -1;
          margin-left: 0;
          justify-content: flex-start;
          flex-wrap: nowrap;
          overflow-x: auto;
          overflow-y: hidden;
          overscroll-behavior-inline: contain;
          scrollbar-width: none;
          -webkit-overflow-scrolling: touch;
        }
        .ui-control-bar.is-mobile-disclosable > .ui-control-bar-trailing::-webkit-scrollbar { display: none; }
        .ui-control-bar.is-mobile-disclosable.is-advanced-open > .ui-control-bar-trailing { display: flex; }
        .ui-control-bar.is-mobile-disclosable > .ui-control-bar-trailing > * { flex: 0 0 auto; }
      }
      @media (pointer: coarse) {
        .ui-sort-order { width: var(--field-height-lg); height: var(--field-height-lg); }
      }
    """#

    // MARK: - Text fields

    private static let fields = #"""
      .ui-field { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
      .ui-label {
        color: var(--text-secondary);
        font-size: var(--type-subhead-size);
        font-weight: var(--weight-medium);
      }
      .ui-label-required::after { content: "*"; margin-left: 2px; color: var(--error); }
      /* Helper text is persistent: a placeholder disappears exactly when the
         guidance is needed. */
      .ui-help { color: var(--text-tertiary); font-size: var(--type-footnote-size); }
      .ui-error-text {
        display: flex;
        align-items: center;
        gap: var(--space-1);
        color: var(--error);
        font-size: var(--type-footnote-size);
      }

      .ui-input, .ui-select, .ui-textarea {
        width: 100%;
        min-width: 0;
        height: var(--field-height);
        padding: 0 var(--space-3);
        border: var(--hairline) solid var(--field-border);
        border-radius: var(--field-radius);
        color: var(--text-primary);
        background: var(--field-bg);
        font-size: var(--type-callout-size);
        transition:
          border-color var(--duration-fast) var(--ease-out),
          box-shadow var(--duration-fast) var(--ease-out),
          background-color var(--duration-fast) var(--ease-out);
      }
      .ui-textarea { height: auto; min-height: 96px; padding: var(--space-3); line-height: var(--type-body-line); resize: vertical; }
      .ui-input::placeholder, .ui-textarea::placeholder { color: var(--field-placeholder); }
      .ui-input:hover, .ui-select:hover, .ui-textarea:hover { border-color: var(--field-border-hover); }
      .ui-input:focus-visible, .ui-select:focus-visible, .ui-textarea:focus-visible {
        outline: none;
        border-color: var(--accent);
        box-shadow: var(--focus-ring);
      }
      .ui-input[aria-invalid="true"], .ui-textarea[aria-invalid="true"] {
        border-color: var(--error);
        box-shadow: 0 0 0 3px var(--error-subtle);
      }
      .ui-input:disabled, .ui-select:disabled, .ui-textarea:disabled {
        cursor: not-allowed;
        color: var(--text-tertiary);
        background: var(--surface-sunken);
        opacity: 0.7;
      }
      /* Read-only is not disabled: the value still matters and stays legible. */
      .ui-input[readonly] { background: var(--surface-sunken); border-style: dashed; }

      /* 下拉箭头此前是两块 5px 的三角形色块拼出来的，拼缝在 1× 屏上看得见，而且
         它是全站唯一一处**不属于图标族**的箭头——旁边的 `.ui-sort-order` 用的是
         真正的 `chevronDown` 字形，两者并排时角度和粗细都对不上。

         改成用同一枚 chevron 做遮罩：形状来自字形，颜色来自 `currentColor`，于是
         它跟着文字色走，disabled 时自动一起变淡。data URI 里的 `#` 必须转义成
         `%23`，否则会被当成片段标识符——这条渐变因此写成 stroke 而不是 fill。 */
      .ui-select {
        padding-right: var(--space-8);
        cursor: pointer;
        appearance: none;
        -webkit-appearance: none;
        background-color: var(--field-bg);
        background-image: var(--select-caret), var(--fill-raise-soft);
        background-position: right var(--space-3) center, 0 0;
        background-size: var(--icon-sm) var(--icon-sm), auto;
        background-repeat: no-repeat, no-repeat;
      }

      .ui-search { position: relative; display: flex; align-items: center; min-width: 0; }
      .ui-search > svg {
        position: absolute;
        left: var(--space-3);
        width: var(--icon-sm);
        height: var(--icon-sm);
        pointer-events: none;
        color: var(--text-tertiary);
      }
      .ui-search .ui-input { padding-left: calc(var(--space-3) * 2 + var(--icon-sm)); }
      .ui-search .ui-input::-webkit-search-cancel-button { -webkit-appearance: none; }

      /* iOS zooms any focused control whose text is under 16px.  Touch layouts
         raise both the font size and the target height rather than disabling
         zoom, which would break pinch for everyone. */
      @media (pointer: coarse) {
        .ui-input, .ui-select, .ui-textarea {
          height: var(--field-height-lg);
          font-size: 16px;
        }
      }
    """#

    // MARK: - Checkbox / radio / switch / slider

    private static let choiceControls = #"""
      .ui-check-row {
        display: flex;
        min-height: var(--control-height-lg);
        align-items: center;
        gap: var(--space-3);
        padding: var(--space-1) 0;
        cursor: pointer;
      }
      .ui-check-row-disabled { cursor: not-allowed; opacity: 0.5; }

      .ui-check, .ui-radio {
        flex: none;
        width: 20px;
        height: 20px;
        margin: 0;
        border: var(--border-thick) solid var(--border-strong);
        background-color: var(--surface);
        box-shadow: var(--inner-shadow);
        cursor: pointer;
        appearance: none;
        -webkit-appearance: none;
        transition:
          background-color var(--duration-fast) var(--ease-out),
          border-color var(--duration-fast) var(--ease-out),
          box-shadow var(--duration-fast) var(--ease-out);
      }
      .ui-check { border-radius: var(--radius-xs); }
      .ui-radio { border-radius: 50%; }
      /* 未选中时是一个凹槽（内阴影），选中后翻成一块凸起的实心（提亮层 + 内高
         光 + 彩色高程）。这一对反向的材质本身就在讲"关"和"开"，不必只靠颜色。 */
      .ui-check:hover, .ui-radio:hover { border-color: var(--accent); }
      .ui-check:checked, .ui-radio:checked {
        border-color: var(--accent);
        background-color: var(--accent);
        background-image: var(--fill-raise);
        box-shadow: var(--inner-highlight), var(--shadow-accent-1);
      }
      /* 勾此前是两条 `linear-gradient` 拼出来的折线：两段的端点是方的，接缝处还
         会露出一个小台阶——而图标族里的每一笔都是圆头。改用真正的 `check` 字形
         做遮罩，勾就和产品里其它所有勾是同一支笔画的。 */
      .ui-check:checked {
        background-image: var(--check-mark), var(--fill-raise);
        background-position: center, 0 0;
        background-size: 13px 13px, auto;
        background-repeat: no-repeat, no-repeat;
      }
      .ui-radio:checked { box-shadow: inset 0 0 0 4px var(--surface), var(--shadow-accent-1); }
      .ui-check:disabled, .ui-radio:disabled { cursor: not-allowed; opacity: 0.5; }

      .ui-switch {
        position: relative;
        flex: none;
        width: 44px;
        height: 26px;
        margin: 0;
        border: 0;
        border-radius: var(--radius-pill);
        background-color: var(--border-strong);
        box-shadow: var(--inner-shadow);
        cursor: pointer;
        appearance: none;
        -webkit-appearance: none;
        transition: background-color var(--duration-base) var(--ease-out);
      }
      /* 旋钮是这条轨道里唯一"浮"起来的东西，所以它同时带内高光和接触阴影；
         轨道反过来是凹的。位移走 `--ease-spring`——这是弹性曲线在产品里的第一个
         真实消费者，之前它定义了却没有任何人用。 */
      .ui-switch::after {
        content: "";
        position: absolute;
        top: 3px;
        left: 3px;
        width: 20px;
        height: 20px;
        border-radius: 50%;
        background-color: #ffffff;
        background-image: var(--fill-raise-soft);
        box-shadow: var(--inner-highlight-strong), var(--shadow-2);
        transition: transform var(--duration-base) var(--ease-spring);
      }
      .ui-switch:checked { background-color: var(--success); background-image: var(--fill-raise); }
      .ui-switch:checked::after { transform: translateX(18px); }
      .ui-switch:disabled { cursor: not-allowed; opacity: 0.5; }

      .ui-slider {
        width: 100%;
        height: 20px;
        padding: 0;
        border: 0;
        background: transparent;
        cursor: pointer;
        appearance: none;
        -webkit-appearance: none;
      }
      .ui-slider::-webkit-slider-runnable-track {
        height: 4px;
        border-radius: var(--radius-pill);
        background:
          linear-gradient(var(--accent), var(--accent)) 0 / var(--ui-slider-progress, 0%) 100% no-repeat,
          var(--border-strong);
      }
      .ui-slider::-moz-range-track { height: 4px; border-radius: var(--radius-pill); background: var(--border-strong); }
      .ui-slider::-moz-range-progress { height: 4px; border-radius: var(--radius-pill); background: var(--accent); }
      .ui-slider::-webkit-slider-thumb {
        width: 16px;
        height: 16px;
        margin-top: -6px;
        border: 0;
        border-radius: 50%;
        background: #ffffff;
        box-shadow: var(--shadow-2), inset 0 0 0 1px var(--border);
        appearance: none;
        -webkit-appearance: none;
        transition: transform var(--duration-fast) var(--ease-out);
      }
      .ui-slider::-moz-range-thumb {
        width: 16px;
        height: 16px;
        border: 0;
        border-radius: 50%;
        background: #ffffff;
        box-shadow: var(--shadow-2), inset 0 0 0 1px var(--border);
      }
      .ui-slider:active::-webkit-slider-thumb { transform: scale(1.15); }
      .ui-slider:focus-visible::-webkit-slider-thumb { box-shadow: var(--focus-ring); }

      /* The compact scrubber/level family: transport progress and volume, in the
         audio dock and in the video player.
         `.ui-slider` above is the page-surface control — 20px tall, thumb always
         showing.  Transport controls want the opposite: a hairline track that
         stays out of the way and a thumb that only appears once you reach for
         it.  Rather than a second copy of the pseudo-element matrix, the three
         colours are indirected through component tokens, so the same geometry
         sits on a glass dock or on artwork by swapping a modifier.
         The fill reads `--progress`, which is the property the dock and player
         scripts already write — a range input cannot paint its own filled
         portion in WebKit, so the value has to arrive as a custom property. */
      .ui-range {
        --range-track: var(--divider);
        --range-fill: var(--accent);
        --range-buffered: var(--border-strong);
        --range-thumb: var(--text-primary);
        --range-thumb-shadow: var(--shadow-1);
        --range-thickness: 4px;
        --range-thumb-size: 12px;
        width: 100%;
        height: var(--range-hit, 16px);
        margin: 0;
        padding: 0;
        border: 0;
        background: transparent;
        cursor: pointer;
        appearance: none;
        -webkit-appearance: none;
      }
      /* On artwork the fill goes white rather than accent: a blue bar drawn over
         an unknowable frame is the same clash the on-media buttons avoid. */
      .ui-range-on-media {
        --range-track: var(--track-on-media);
        --range-buffered: var(--btn-on-media-fill-active);
        --range-fill: var(--text-on-media);
        --range-thumb: var(--thumb-on-media);
        --range-thumb-shadow: var(--thumb-on-media-shadow);
      }
      /* 三层：已播（`--progress`）、已缓冲（`--buffered`）、槽底。
         已缓冲那一段此前根本不存在——网慢的时候读者看不出"还要等多久才能拖到
         那儿"，只能反复去点。它压在已播段下面，颜色比已播弱一档。 */
      .ui-range::-webkit-slider-runnable-track {
        height: var(--range-thickness);
        border-radius: var(--radius-pill);
        background:
          linear-gradient(var(--range-fill), var(--range-fill)) 0 / var(--progress, 0%) 100% no-repeat,
          linear-gradient(var(--range-buffered), var(--range-buffered)) 0 / var(--buffered, 0%) 100% no-repeat,
          var(--range-track);
        transition: height var(--duration-fast) var(--ease-out);
      }
      .ui-range::-moz-range-track {
        height: var(--range-thickness);
        border-radius: var(--radius-pill);
        background: var(--range-track);
      }
      .ui-range::-moz-range-progress {
        height: var(--range-thickness);
        border-radius: var(--radius-pill);
        background: var(--range-fill);
      }
      .ui-range::-webkit-slider-thumb {
        width: var(--range-thumb-size);
        height: var(--range-thumb-size);
        margin-top: calc((var(--range-thickness) - var(--range-thumb-size)) / 2);
        border: 0;
        border-radius: 50%;
        background: var(--range-thumb);
        box-shadow: var(--range-thumb-shadow);
        appearance: none;
        -webkit-appearance: none;
        transition: transform var(--duration-fast) var(--ease-out);
      }
      .ui-range::-moz-range-thumb {
        width: var(--range-thumb-size);
        height: var(--range-thumb-size);
        border: 0;
        border-radius: 50%;
        background: var(--range-thumb);
        box-shadow: var(--range-thumb-shadow);
      }
      .ui-range:active::-webkit-slider-thumb { transform: scale(1.2); }
      .ui-range:focus-visible::-webkit-slider-thumb { box-shadow: var(--focus-ring); }
      .ui-range:disabled { cursor: not-allowed; opacity: 0.45; }
      /* A scrubber is a target you aim at, so it thickens under the pointer.
         Driving it from the thickness property rather than the track rule keeps
         the thumb centred as the track grows. */
      .ui-range-scrub:hover, .ui-range-scrub:focus-visible { --range-thickness: 6px; }
    """#

    // MARK: - Segmented control, tabs, breadcrumb

    private static let segmentedAndTabs = #"""
      /* Radio-backed so it works without JavaScript and announces as a group. */
      .ui-segmented {
        display: inline-flex;
        max-width: 100%;
        padding: 3px;
        border-radius: var(--radius-sm);
        background: var(--surface-sunken);
        /* 托盘是凹的，选中的那一格是凸的——两者反向，选中态因此不必只靠颜色。 */
        box-shadow: var(--inner-shadow);
        overflow-x: auto;
        scrollbar-width: none;
      }
      .ui-segmented::-webkit-scrollbar { display: none; }
      /* Two backings, one appearance.  A segment that filters in place is a
         radio; a segment that navigates to another URL has to be a real anchor
         so it deep-links and middle-clicks.  Both are styled here rather than
         letting the navigating variant grow a private copy in a page sheet. */
      .ui-segmented > label, .ui-segmented > a, .ui-segmented > button {
        position: relative;
        display: inline-flex;
        height: calc(var(--control-height-md) - 6px);
        flex: none;
        align-items: center;
        justify-content: center;
        gap: var(--space-2);
        padding: 0 var(--space-4);
        border-radius: calc(var(--radius-sm) - 3px);
        color: var(--text-secondary);
        font-size: var(--type-subhead-size);
        font-weight: var(--weight-medium);
        white-space: nowrap;
        text-decoration: none;
        cursor: pointer;
        transition:
          color var(--duration-fast) var(--ease-out),
          background-color var(--duration-fast) var(--ease-out),
          box-shadow var(--duration-fast) var(--ease-out);
      }
      .ui-segmented > label > svg,
      .ui-segmented > a > svg,
      .ui-segmented > button > svg { width: var(--icon-sm); height: var(--icon-sm); }
      /* 反馈落在按下那一刻，不是松手之后。
         等到 click 才给反馈，控件读起来是"死的"；这一下缩放只发生在绘制层，不改
         尺寸也不改内边距，所以旁边的东西不会跟着挪。
         `prefers-reduced-motion` 下 base 层会把所有 transform 关掉，这里不用再判。 */
      .ui-segmented > label:active,
      .ui-segmented > a:active,
      .ui-segmented > button:active { transform: scale(0.97); }
      .ui-segmented input { position: absolute; opacity: 0; pointer-events: none; }
      .ui-segmented > label:hover,
      .ui-segmented > a:hover,
      .ui-segmented > button:hover { color: var(--text-primary); }
      .ui-segmented input:checked + span,
      .ui-segmented > label:has(input:checked),
      .ui-segmented > a[aria-current="page"],
      .ui-segmented > button[aria-checked="true"] {
        color: var(--text-primary);
        background-color: var(--surface);
        background-image: var(--fill-raise-soft);
        box-shadow: var(--inner-highlight), var(--shadow-2);
        font-weight: var(--weight-semibold);
      }
      .ui-segmented > label:has(input:focus-visible),
      .ui-segmented > a:focus-visible,
      .ui-segmented > button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }

      /* 侧栏那一档：三格等分整条宽度，只有图标。可读的名字走 `aria-label` +
         `title`，由 `testIconOnlyControlsCarryAnAccessibleName` 钉住。 */
      .ui-segmented-compact { display: flex; width: 100%; }
      .ui-segmented-compact > button { flex: 1; padding: 0; }

      .ui-tabs {
        display: flex;
        gap: var(--space-5);
        border-bottom: var(--hairline) solid var(--divider);
        overflow-x: auto;
        scrollbar-width: none;
      }
      .ui-tabs::-webkit-scrollbar { display: none; }
      .ui-tab {
        position: relative;
        display: inline-flex;
        height: var(--control-height-lg);
        flex: none;
        align-items: center;
        gap: var(--space-2);
        color: var(--text-secondary);
        font-size: var(--type-callout-size);
        font-weight: var(--weight-medium);
        white-space: nowrap;
        cursor: pointer;
        transition: color var(--duration-fast) var(--ease-out);
      }
      .ui-tab:hover { color: var(--text-primary); }
      .ui-tab::after {
        content: "";
        position: absolute;
        right: 0;
        bottom: -1px;
        left: 0;
        height: 2px;
        border-radius: var(--radius-pill);
        background: var(--accent);
        opacity: 0;
        transform: scaleX(0.4);
        transition: opacity var(--duration-base) var(--ease-out), transform var(--duration-base) var(--ease-out);
      }
      .ui-tab[aria-selected="true"] { color: var(--text-primary); font-weight: var(--weight-semibold); }
      .ui-tab[aria-selected="true"]::after { opacity: 1; transform: none; }

      .ui-breadcrumb {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--space-2);
        color: var(--text-tertiary);
        font-size: var(--type-subhead-size);
      }
      .ui-breadcrumb a { color: var(--text-secondary); }
      .ui-breadcrumb a:hover { color: var(--text-primary); text-decoration: underline; }
      .ui-breadcrumb li { display: inline-flex; align-items: center; gap: var(--space-2); }
      .ui-breadcrumb li + li::before {
        content: "";
        width: 5px;
        height: 5px;
        border-top: 1.5px solid currentColor;
        border-right: 1.5px solid currentColor;
        opacity: 0.6;
        transform: rotate(45deg);
      }
      .ui-breadcrumb [aria-current="page"] { color: var(--text-primary); font-weight: var(--weight-medium); }
      @media (max-width: 719px) {
        .ui-breadcrumb a {
          display: inline-flex;
          min-height: var(--control-height-lg);
          align-items: center;
        }
      }
    """#

    // MARK: - Chips, badges, status

    private static let indicators = #"""
      .ui-chip {
        display: inline-flex;
        height: var(--control-height-sm);
        align-items: center;
        gap: var(--space-2);
        padding: 0 var(--space-3);
        border: var(--hairline) solid var(--border);
        border-radius: var(--radius-pill);
        color: var(--text-secondary);
        background-color: var(--surface);
        background-image: var(--fill-raise-soft);
        box-shadow: var(--shadow-1);
        font-size: var(--type-subhead-size);
        font-weight: var(--weight-medium);
        white-space: nowrap;
        transition:
          color var(--duration-fast) var(--ease-out),
          border-color var(--duration-fast) var(--ease-out),
          background-color var(--duration-fast) var(--ease-out);
      }
      .ui-chip > svg { width: var(--icon-xs); height: var(--icon-xs); }
      /* chip 此前没有任何 hover 态。可点的 chip（筛选、标签）和纯展示的 chip 长
         得一模一样，指针停上去也没有回应——读者只能靠试。 */
      a.ui-chip:hover, button.ui-chip:hover, .ui-chip[role="button"]:hover {
        color: var(--text-primary);
        border-color: var(--border-strong);
        background-color: var(--surface-hover);
      }
      a.ui-chip:active, button.ui-chip:active, .ui-chip[role="button"]:active { transform: scale(0.97); }
      .ui-chip-active {
        color: var(--accent-text);
        border-color: var(--icon-tile-border);
        background-color: var(--accent-subtle);
      }
      a.ui-chip-active:hover, button.ui-chip-active:hover { background-color: var(--accent-subtle-hover); }
      /* A removable filter chip carries its own dismiss target, sized for touch
         without inflating the chip. */
      .ui-chip-remove {
        display: inline-flex;
        width: 18px;
        height: 18px;
        margin-right: -4px;
        align-items: center;
        justify-content: center;
        border-radius: 50%;
        color: inherit;
        cursor: pointer;
      }
      .ui-chip-remove:hover { background: var(--surface-active); }

      .ui-tag {
        display: inline-flex;
        align-items: center;
        gap: var(--space-1);
        padding: 2px var(--space-2);
        border-radius: var(--radius-xs);
        color: var(--text-secondary);
        background: var(--surface-sunken);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-medium);
        letter-spacing: var(--type-caption-track);
      }

      .ui-badge {
        display: inline-flex;
        min-width: 20px;
        height: 20px;
        align-items: center;
        justify-content: center;
        padding: 0 6px;
        border-radius: var(--radius-pill);
        color: var(--text-on-accent);
        background: var(--accent);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        font-variant-numeric: tabular-nums;
      }
      .ui-badge-neutral { color: var(--text-secondary); background: var(--surface-sunken); }

      /* Status is never carried by colour alone: a dot plus a word. */
      .ui-status {
        display: inline-flex;
        align-items: center;
        gap: var(--space-2);
        font-size: var(--type-subhead-size);
        font-weight: var(--weight-medium);
      }
      .ui-status::before {
        content: "";
        width: 8px;
        height: 8px;
        flex: none;
        border-radius: 50%;
        background: currentColor;
      }
      .ui-status-ok { color: var(--success); }
      .ui-status-warn { color: var(--warning); }
      .ui-status-error { color: var(--error); }
      .ui-status-idle { color: var(--text-tertiary); }

      /* Rides directly on artwork, so it uses the always-dark media treatment
         rather than a theme surface. */
      .ui-media-badge {
        display: inline-flex;
        align-items: center;
        gap: var(--space-1);
        padding: 3px var(--space-2);
        border: var(--hairline) solid rgba(255, 255, 255, 0.18);
        border-radius: var(--radius-xs);
        color: var(--text-on-media);
        background: var(--overlay-on-media);
        -webkit-backdrop-filter: var(--glass-thin-blur);
        backdrop-filter: var(--glass-thin-blur);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        font-variant-numeric: tabular-nums;
      }
    """#

    // MARK: - Lists and tables

    private static let listsAndTables = #"""
      .ui-list { display: flex; flex-direction: column; }
      .ui-list > li + li, .ui-list > .ui-row + .ui-row { border-top: var(--hairline) solid var(--divider); }
      .ui-row {
        display: flex;
        min-height: var(--row-height);
        align-items: center;
        gap: var(--space-3);
        padding: var(--space-2) var(--space-3);
        border-radius: var(--row-radius);
        color: inherit;
        transition: background-color var(--duration-fast) var(--ease-out);
      }
      .ui-row-interactive { cursor: pointer; }
      .ui-row-interactive:hover { background: var(--surface-hover); }
      .ui-row-interactive:active { background: var(--surface-active); }
      .ui-row[aria-current="true"], .ui-row-selected {
        color: var(--text-primary);
        background: var(--surface-selected);
        font-weight: var(--weight-semibold);
      }
      .ui-row-lead { display: flex; flex: none; align-items: center; justify-content: center; }
      .ui-row-body { display: flex; flex: 1; min-width: 0; flex-direction: column; gap: 2px; }
      .ui-row-title { font-size: var(--type-callout-size); font-weight: var(--weight-medium); }
      .ui-row-sub { color: var(--text-tertiary); font-size: var(--type-footnote-size); }
      .ui-row-trail { display: flex; flex: none; align-items: center; gap: var(--space-2); }
      /* Row actions stay reachable without hover, which does not exist on touch;
         hover only raises their prominence. */
      .ui-row-trail .ui-btn-ghost { opacity: 0.6; transition: opacity var(--duration-fast) var(--ease-out); }
      .ui-row:hover .ui-row-trail .ui-btn-ghost,
      .ui-row:focus-within .ui-row-trail .ui-btn-ghost { opacity: 1; }

      .ui-table { width: 100%; font-size: var(--type-callout-size); }
      .ui-table th {
        position: sticky;
        top: 0;
        z-index: 1;
        padding: var(--space-2) var(--space-3);
        border-bottom: var(--hairline) solid var(--border);
        color: var(--text-tertiary);
        background: var(--bg-canvas);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        letter-spacing: var(--type-caption-track);
        text-align: left;
        text-transform: uppercase;
        white-space: nowrap;
      }
      .ui-table td {
        padding: var(--space-3);
        border-bottom: var(--hairline) solid var(--divider);
        vertical-align: middle;
      }
      .ui-table tbody tr { transition: background-color var(--duration-fast) var(--ease-out); }
      .ui-table tbody tr:hover { background: var(--surface-hover); }
      .ui-table-numeric { text-align: right; font-variant-numeric: tabular-nums; }

      /* Below the tablet breakpoint a table stops being a grid and becomes a
         stack of labelled records; each cell carries its header in `data-label`. */
      @media (max-width: 719px) {
        .ui-table-responsive thead { display: none; }
        .ui-table-responsive tr {
          display: grid;
          gap: var(--space-1);
          padding: var(--space-3);
          border: var(--hairline) solid var(--border);
          border-radius: var(--card-radius);
          background: var(--surface);
        }
        .ui-table-responsive tr + tr { margin-top: var(--space-2); }
        .ui-table-responsive td { display: flex; justify-content: space-between; gap: var(--space-4); padding: 0; border: 0; }
        .ui-table-responsive td::before {
          content: attr(data-label);
          color: var(--text-tertiary);
          font-size: var(--type-footnote-size);
          font-weight: var(--weight-medium);
        }
        .ui-table-responsive td:empty { display: none; }
      }

      .ui-pager {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: var(--space-3);
        padding-top: var(--space-6);
      }
      .ui-pager-label {
        color: var(--text-tertiary);
        font-size: var(--type-subhead-size);
        font-variant-numeric: tabular-nums;
      }
    """#

    // MARK: - Menus, popovers, tooltips, modals, sheets

    private static let overlays = #"""
      /* Every overlay materialises from its trigger: it scales up from the
         corner it belongs to while its blur resolves, so it reads as a surface
         arriving rather than a rectangle fading in. */
      .ui-menu, .ui-popover {
        position: absolute;
        z-index: var(--z-overlay);
        min-width: var(--menu-min-width);
        max-width: min(92vw, 380px);
        padding: var(--space-2);
        border: var(--hairline) solid var(--glass-regular-border);
        border-radius: var(--overlay-radius);
        background: var(--glass-regular-bg);
        -webkit-backdrop-filter: var(--glass-regular-blur);
        backdrop-filter: var(--glass-regular-blur);
        box-shadow: var(--glass-regular-highlight), var(--shadow-4);
        transform-origin: var(--ui-overlay-origin, top left);
        animation: ui-overlay-in var(--duration-base) var(--ease-out);
      }
      .ui-popover { padding: var(--space-4); }
      .ui-menu-item {
        display: flex;
        width: 100%;
        min-height: var(--control-height-md);
        align-items: center;
        gap: var(--space-3);
        padding: 0 var(--space-3);
        border-radius: var(--radius-xs);
        color: var(--text-primary);
        font-size: var(--type-callout-size);
        text-align: left;
        cursor: pointer;
      }
      .ui-menu-item > svg { width: var(--icon-sm); height: var(--icon-sm); color: var(--text-tertiary); }
      .ui-menu-item:hover { background: var(--surface-hover); }
      .ui-menu-item[aria-checked="true"] { color: var(--accent-text); font-weight: var(--weight-semibold); }
      .ui-menu-item-destructive { color: var(--error); }
      .ui-menu-separator { height: var(--hairline); margin: var(--space-2) var(--space-2); background: var(--divider); }

      .ui-tooltip {
        position: absolute;
        z-index: var(--z-overlay);
        max-width: 260px;
        padding: var(--space-2) var(--space-3);
        border-radius: var(--radius-xs);
        color: var(--text-inverse);
        background: var(--text-primary);
        box-shadow: var(--shadow-3);
        font-size: var(--type-footnote-size);
        pointer-events: none;
        animation: ui-overlay-in var(--duration-fast) var(--ease-out);
      }

      /* A modal is a blocking task: it dims and pushes the page back.  A drawer
         is a parallel panel: translucent and offset, no scrim, so the flow the
         user was in is not broken. */
      .ui-scrim {
        position: fixed;
        z-index: var(--z-modal);
        inset: 0;
        display: grid;
        place-items: center;
        padding: var(--space-4);
        background: var(--surface-scrim);
        -webkit-backdrop-filter: blur(3px);
        backdrop-filter: blur(3px);
        animation: ui-fade-in var(--duration-base) var(--ease-out);
      }
      .ui-modal {
        width: min(560px, 100%);
        max-height: min(86dvh, 760px);
        display: flex;
        flex-direction: column;
        overflow: hidden;
        border: var(--hairline) solid var(--glass-thick-border);
        border-radius: var(--radius-lg);
        background: var(--glass-thick-bg);
        -webkit-backdrop-filter: var(--glass-thick-blur);
        backdrop-filter: var(--glass-thick-blur);
        box-shadow: var(--glass-thick-highlight), var(--shadow-4);
        animation: ui-modal-in var(--duration-base) var(--ease-out);
      }
      .ui-modal-head {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: var(--space-4);
        padding: var(--space-5) var(--space-5) var(--space-3);
      }
      .ui-modal-body { padding: 0 var(--space-5); overflow-y: auto; }
      .ui-modal-foot {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: flex-end;
        gap: var(--space-2);
        padding: var(--space-5);
      }
      .ui-modal-foot .ui-spacer { flex: 1 1 auto; }

      .ui-drawer {
        position: fixed;
        z-index: var(--z-modal);
        top: 0;
        bottom: 0;
        left: 0;
        width: min(320px, 86vw);
        display: flex;
        flex-direction: column;
        overflow-y: auto;
        border-right: var(--hairline) solid var(--glass-thick-border);
        background: var(--glass-thick-bg);
        -webkit-backdrop-filter: var(--glass-thick-blur);
        backdrop-filter: var(--glass-thick-blur);
        box-shadow: var(--shadow-4);
        animation: ui-drawer-in var(--duration-base) var(--ease-out);
      }

      /* Enters from the bottom and dismisses to the bottom — an overlay must
         leave along the path it arrived on. */
      .ui-sheet {
        position: fixed;
        z-index: var(--z-modal);
        right: 0;
        bottom: 0;
        left: 0;
        max-height: 88dvh;
        display: flex;
        flex-direction: column;
        overflow-y: auto;
        padding-bottom: env(safe-area-inset-bottom);
        border-radius: var(--radius-xl) var(--radius-xl) 0 0;
        border-top: var(--hairline) solid var(--glass-thick-border);
        background: var(--glass-thick-bg);
        -webkit-backdrop-filter: var(--glass-thick-blur);
        backdrop-filter: var(--glass-thick-blur);
        box-shadow: var(--shadow-4);
        animation: ui-sheet-in var(--duration-base) var(--ease-out);
      }
      .ui-sheet-grabber {
        width: 36px;
        height: 5px;
        margin: var(--space-3) auto var(--space-1);
        border-radius: var(--radius-pill);
        background: var(--border-strong);
      }

      @keyframes ui-fade-in { from { opacity: 0; } to { opacity: 1; } }
      @keyframes ui-overlay-in {
        from { opacity: 0; transform: scale(0.94) translateY(-4px); filter: blur(3px); }
        to { opacity: 1; transform: none; filter: none; }
      }
      @keyframes ui-modal-in {
        from { opacity: 0; transform: scale(0.96) translateY(8px); }
        to { opacity: 1; transform: none; }
      }
      @keyframes ui-drawer-in {
        from { transform: translateX(-100%); }
        to { transform: none; }
      }
      @keyframes ui-sheet-in {
        from { transform: translateY(100%); }
        to { transform: none; }
      }
    """#

    // MARK: - Empty / loading / toast / alert

    private static let feedback = #"""
      /* An empty state explains the cause and offers the next move; it is never
         just a shrug. */
      .ui-empty {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: var(--space-3);
        padding: var(--space-10) var(--space-6);
        border: var(--hairline) dashed var(--border);
        border-radius: var(--card-radius);
        text-align: center;
      }
      /* 几何与材质全部来自 `.ui-icon-tile`；空态自己只保留"不要被 flex 压扁"。 */
      .ui-empty-icon { margin-bottom: var(--space-1); }
      .ui-empty-title { font-size: var(--type-title3-size); font-weight: var(--weight-semibold); }
      .ui-empty-body { max-width: 46ch; color: var(--text-secondary); font-size: var(--type-callout-size); }

      .ui-skeleton {
        position: relative;
        overflow: hidden;
        border-radius: var(--radius-sm);
        background: var(--skeleton-base);
      }
      .ui-skeleton::after {
        content: "";
        position: absolute;
        inset: 0;
        background: linear-gradient(90deg, transparent, var(--skeleton-sheen), transparent);
        transform: translateX(-100%);
        animation: ui-shimmer 1.4s var(--ease-in-out) infinite;
      }
      .ui-skeleton-line { height: 12px; }
      .ui-skeleton-line-sm { height: 9px; width: 60%; }
      .ui-skeleton-poster { aspect-ratio: var(--poster-ratio); border-radius: var(--poster-radius); }
      @keyframes ui-shimmer { to { transform: translateX(100%); } }

      .ui-spinner {
        display: inline-block;
        width: var(--icon-md);
        height: var(--icon-md);
        border: 2px solid var(--border-strong);
        border-top-color: var(--accent);
        border-radius: 50%;
        animation: ui-spin 0.7s linear infinite;
      }
      @keyframes ui-spin { to { transform: rotate(360deg); } }

      .ui-progress {
        overflow: hidden;
        width: 100%;
        height: 4px;
        border-radius: var(--radius-pill);
        background: var(--border-strong);
      }
      .ui-progress > span {
        display: block;
        height: 100%;
        border-radius: inherit;
        background: var(--accent);
        transition: width var(--duration-base) var(--ease-out);
      }
      .ui-progress-indeterminate { position: relative; }
      .ui-progress-indeterminate::after {
        content: "";
        position: absolute;
        inset: 0 auto 0 0;
        width: 40%;
        border-radius: inherit;
        background: var(--accent);
        animation: ui-indeterminate 1.2s var(--ease-in-out) infinite;
      }
      @keyframes ui-indeterminate {
        0% { transform: translateX(-100%); }
        100% { transform: translateX(250%); }
      }

      /* Toasts announce politely and never take focus. */
      .ui-toast-region {
        position: fixed;
        z-index: var(--z-toast);
        top: calc(var(--space-4) + env(safe-area-inset-top));
        left: 50%;
        display: flex;
        width: min(var(--toast-width), calc(100vw - var(--space-8)));
        flex-direction: column;
        gap: var(--space-2);
        pointer-events: none;
        transform: translateX(-50%);
      }
      .ui-toast {
        display: flex;
        align-items: flex-start;
        gap: var(--space-3);
        padding: var(--space-3) var(--space-4);
        border: var(--hairline) solid var(--glass-regular-border);
        border-radius: var(--radius-md);
        background: var(--glass-regular-bg);
        -webkit-backdrop-filter: var(--glass-regular-blur);
        backdrop-filter: var(--glass-regular-blur);
        box-shadow: var(--glass-regular-highlight), var(--shadow-4);
        pointer-events: auto;
        animation: ui-toast-in var(--duration-base) var(--ease-out);
      }
      .ui-toast[data-leaving="true"] { animation: ui-toast-out var(--duration-exit) var(--ease-in) forwards; }
      .ui-toast > svg { flex: none; width: var(--icon-md); height: var(--icon-md); }
      .ui-toast-body { flex: 1; min-width: 0; font-size: var(--type-callout-size); }
      .ui-toast-ok > svg { color: var(--success); }
      .ui-toast-error > svg { color: var(--error); }
      .ui-toast-info > svg { color: var(--info); }
      @keyframes ui-toast-in {
        from { opacity: 0; transform: translateY(-12px) scale(0.97); }
        to { opacity: 1; transform: none; }
      }
      @keyframes ui-toast-out {
        to { opacity: 0; transform: translateY(-8px); }
      }

      /* Inline, persistent counterpart to a toast: used where the message must
         stay on screen until the underlying problem is fixed. */
      .ui-alert {
        display: flex;
        align-items: flex-start;
        gap: var(--space-3);
        padding: var(--space-4);
        border: var(--hairline) solid var(--border);
        border-left: 3px solid var(--info);
        border-radius: var(--radius-sm);
        background: var(--info-subtle);
        font-size: var(--type-callout-size);
      }
      .ui-alert > svg { flex: none; width: var(--icon-md); height: var(--icon-md); color: var(--info); }
      .ui-alert-success { border-left-color: var(--success); background: var(--success-subtle); }
      .ui-alert-success > svg { color: var(--success); }
      .ui-alert-warning { border-left-color: var(--warning); background: var(--warning-subtle); }
      .ui-alert-warning > svg { color: var(--warning); }
      .ui-alert-error { border-left-color: var(--error); background: var(--error-subtle); }
      .ui-alert-error > svg { color: var(--error); }
      .ui-alert-title { font-weight: var(--weight-semibold); }
    """#

    // MARK: - Media

    private static let media = #"""
      .ui-media-grid {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(var(--grid-min), 1fr));
        gap: var(--grid-gap);
      }
      .ui-media-grid-wide { --grid-min: 260px; }
      .ui-media-grid-tight { --grid-min: 132px; --grid-gap: var(--space-4); }

      .ui-media-card {
        display: flex;
        min-width: 0;
        flex-direction: column;
        gap: var(--space-2);
        color: inherit;
      }
      /* 按下海报时整张封面轻微内收。幅度比卡片 hover 的 2px 位移更小：一整墙海报
         同时响应指针经过会闪，但被按下的那一张必须给出回应。 */
      .ui-media-card:active .ui-poster { transform: scale(0.985); }
      /* The artwork zooms *inside* its frame; neither the frame nor the label
         moves.  An earlier version lifted and scaled the whole tile, but shelves
         scroll horizontally (`overflow-x: auto` also clips vertically), so the
         lift was sliced off at the top of every rail.  Keeping the frame fixed
         also keeps the grid still: text that shifts under the pointer makes a
         library feel unstable. */
      .ui-poster {
        position: relative;
        display: block;
        overflow: hidden;
        aspect-ratio: var(--poster-ratio);
        border-radius: var(--poster-radius);
        background: var(--surface-sunken);
        box-shadow: var(--shadow-1);
        transition: box-shadow var(--duration-slow) var(--ease-out), transform var(--duration-fast) var(--ease-out);
      }
      .ui-poster-wide { aspect-ratio: 16 / 9; }
      .ui-poster-square { aspect-ratio: 1 / 1; }
      .ui-poster img {
        width: 100%;
        height: 100%;
        object-fit: cover;
        opacity: 0;
        transition:
          opacity var(--duration-slow) var(--ease-out),
          transform var(--duration-slow) var(--ease-out);
      }
      .ui-poster img[data-ready="true"] { opacity: 1; }
      .ui-poster-fallback {
        position: absolute;
        inset: 0;
        display: grid;
        place-items: center;
        padding: var(--space-3);
        color: var(--text-on-media);
        background: linear-gradient(145deg, var(--artwork-g1, var(--artwork-fallback-a)), var(--artwork-g2, var(--artwork-fallback-b)));
        text-shadow: var(--text-on-media-shadow);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        text-align: center;
      }
      /* 取不到图时的统一兜底。
         海报底下本来就压着一层写着标题的 `.ui-poster-fallback`，所以这里只服务
         那些没有兜底层的地方：音乐封面、详情页剧照、照片舞台。外壳在三次重试
         都失败之后才插入它——在那之前读者看到的应该是"正在加载"，不是"没有"。
         失败的 `<img>` 本身收起来：浏览器画的碎图标不是这个产品的一部分。 */
      .ui-artwork-fallback {
        position: absolute;
        inset: 0;
        display: grid;
        place-items: center;
        padding: var(--space-3);
        color: var(--text-on-media);
        background: linear-gradient(145deg, var(--artwork-g1, var(--artwork-fallback-a)), var(--artwork-g2, var(--artwork-fallback-b)));
        text-shadow: var(--text-on-media-shadow);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        text-align: center;
      }
      [data-artwork-failed] { position: relative; }
      img[data-artwork-state="failed"] { opacity: 0; }

      /* 落地光：悬停时封面在自身取色里投下一层极淡的彩色阴影。
         它是内容层的光，不是又一层玻璃——外壳保持安静，颜色由作品提供。
         用阴影而不是伪元素：`.ui-poster` 带 `overflow: hidden`，任何画在框外的
         伪元素都会被裁掉，而阴影本来就画在盒子之外。 */
      .ui-media-card:hover .ui-poster,
      .ui-media-card:focus-within .ui-poster {
        box-shadow: var(--shadow-3), 0 18px 38px -20px var(--artwork-accent, var(--accent));
      }
      /* 不挂就绪条件：还在 opacity 0 的图缩放本来就不花什么代价。
         （就绪标记现在全产品只有 `img[data-ready="true"]` 一个；此前是三个。） */
      .ui-media-card:hover .ui-poster img,
      .ui-media-card:focus-within .ui-poster img {
        transform: scale(1.05);
      }
      .ui-poster-corner {
        position: absolute;
        top: var(--space-2);
        right: var(--space-2);
        z-index: 2;
        display: flex;
        gap: var(--space-1);
      }
      .ui-poster-foot {
        position: absolute;
        right: 0;
        bottom: 0;
        left: 0;
        z-index: 2;
        padding: var(--space-8) var(--space-3) var(--space-3);
        background: var(--media-scrim);
        color: var(--text-on-media);
        text-shadow: var(--text-on-media-shadow);
        pointer-events: none;
      }
      .ui-poster-progress {
        position: absolute;
        right: 0;
        bottom: 0;
        left: 0;
        z-index: 3;
        height: 3px;
        background: rgba(255, 255, 255, 0.28);
      }
      .ui-poster-progress > span { display: block; height: 100%; background: var(--accent); }

      .ui-media-title {
        font-size: var(--type-callout-size);
        font-weight: var(--weight-medium);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      /* Secondary metadata is information, not clutter — it stays visible. */
      .ui-media-meta {
        display: flex;
        align-items: center;
        gap: var(--space-2);
        color: var(--text-tertiary);
        font-size: var(--type-footnote-size);
        font-variant-numeric: tabular-nums;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .ui-play-affordance {
        position: absolute;
        inset: 0;
        z-index: 2;
        display: grid;
        place-items: center;
        opacity: 0;
        transition: opacity var(--duration-base) var(--ease-out);
      }
      .ui-play-affordance > span {
        display: grid;
        width: 48px;
        height: 48px;
        place-items: center;
        border: var(--hairline) solid rgba(255, 255, 255, 0.24);
        border-radius: 50%;
        color: var(--text-on-media);
        background: var(--overlay-on-media-strong);
        -webkit-backdrop-filter: var(--glass-thin-blur);
        backdrop-filter: var(--glass-thin-blur);
      }
      .ui-media-card:hover .ui-play-affordance,
      .ui-media-card:focus-within .ui-play-affordance { opacity: 1; }

      /* Horizontal shelves get snap points and inertia, and hide their bar. */
      .ui-shelf {
        display: grid;
        grid-auto-flow: column;
        grid-auto-columns: minmax(var(--grid-min), var(--grid-min));
        gap: var(--grid-gap);
        padding-bottom: var(--space-2);
        overflow-x: auto;
        scroll-snap-type: x proximity;
        overscroll-behavior-x: contain;
        scrollbar-width: none;
      }
      .ui-shelf::-webkit-scrollbar { display: none; }
      .ui-shelf > * { scroll-snap-align: start; }
    """#

    /// Hover is an enhancement, never the only route to an action.
    ///
    /// On a touch screen `:hover` sticks after a tap, so the lift and the reveal
    /// are switched off entirely and anything hover-revealed becomes permanently
    /// visible instead.
    // MARK: - 「加载更多」

    /// 列表底下那颗居中的「加载更多」。合集、人物、相册各写过一份**逐字相同**的
    /// 三行规则，详情页的选集面板还手搓了第四份连按钮本体一起。
    private static let loadMore = #"""
      .ui-load-more { display: flex; justify-content: center; padding-top: var(--space-6); }
      .ui-load-more[hidden] { display: none; }
    """#

    // MARK: - 状态行

    /// 一行"正在加载…/加载失败/共 128 项"这样的活动区。
    ///
    /// 它此前有八份：`.library-status`、`.collection-status`、`.people-status`、
    /// `.admin-state`、`.login-status`、`.sources-state`、`.account-state`、
    /// `.episode-grid-status`。七份写 `min-height: 20px`、一份写 18px，另有七处
    /// 各自重复一遍 `.error { color: var(--error); }`。
    ///
    /// `min-height` 是这条规则真正的作用：文案从"正在加载…"变成结果时行高不变，
    /// 底下的内容不会跳一下。
    private static let stateLine = #"""
      .ui-state-line {
        min-height: 20px;
        color: var(--text-tertiary);
        font-size: var(--type-footnote-size);
      }
      .ui-state-line.error { color: var(--error); }
      .ui-state-line[hidden] { display: none; }
    """#

    // MARK: - 曲目行

    /// 一首歌在列表里的样子。产品里只有这一种。
    ///
    /// 它此前有三份实现：资料库页的 `.music-row`、音乐目录页的 `.song-row`、
    /// 首页的 `.track-row`。前两份的 `grid-template-columns` 是**逐字相同**的
    /// 六列声明，连 `min-height: 52px`、内边距、圆角和那条 `inset 0 1px 0` 的
    /// 分隔线都一样；差别只在音乐页多了 `content-visibility`，而资料库页多了
    /// 一条拼错的死规则（`.music-faverite`）。同一个东西写两遍，第二遍迟早会漏。
    private static let trackRows = #"""
      .ui-track-head,
      .ui-track-row {
        display: grid;
        grid-template-columns: minmax(0, 2.2fr) minmax(0, 1.2fr) minmax(0, 1.2fr) 56px 64px 40px;
        align-items: center;
        gap: var(--space-3);
      }
      .ui-track-head {
        padding: 0 var(--space-3) var(--space-2);
        border-bottom: var(--hairline) solid var(--border);
        color: var(--text-tertiary);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        letter-spacing: var(--type-caption-track);
        text-transform: uppercase;
      }
      .ui-track-row {
        min-height: 52px;
        padding: var(--space-1) var(--space-3);
        border-radius: var(--radius-sm);
        color: inherit;
        transition: background-color var(--duration-fast) var(--ease-out);
        /* 一个上千首的资料库会把上千行同时交给样式与布局；屏外的行跳过渲染后，
           滚动只为可见的那几十行付代价。这条只加在曲目行上，不加在海报卡上：
           paint containment 会裁掉盒外绘制，而海报卡的阴影正好落在盒外。曲目行
           只有 inset 分隔线和背景色，没有任何外扩绘制可被裁掉。`auto` 前缀让
           浏览器记住真实高度，避免滚过之后滚动条跳动。 */
        content-visibility: auto;
        contain-intrinsic-size: auto 52px;
      }
      .ui-track-row:hover { background: var(--surface-hover); }
      .ui-track-row:active { transform: scale(0.995); }
      .ui-track-row + .ui-track-row { box-shadow: inset 0 1px 0 var(--divider); }

      .ui-track-main { display: flex; min-width: 0; align-items: center; gap: var(--space-3); }
      .ui-track-copy { display: grid; min-width: 0; gap: 1px; }
      .ui-track-copy strong {
        overflow: hidden;
        font-size: var(--type-callout-size);
        font-weight: var(--weight-medium);
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .ui-track-copy small { color: var(--text-tertiary); font-size: var(--type-footnote-size); }
      .ui-track-meta {
        overflow: hidden;
        color: var(--text-tertiary);
        font-size: var(--type-footnote-size);
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .ui-track-duration {
        color: var(--text-tertiary);
        font-size: var(--type-footnote-size);
        font-variant-numeric: tabular-nums;
        text-align: right;
      }
      .ui-track-favorite { display: grid; place-items: center; color: var(--text-tertiary); }
      .ui-track-favorite svg { width: var(--icon-sm); height: var(--icon-sm); }

      /* 行内 38px 缩略图。占位是取色渐变加一枚字形，两者叠在**同一个网格单元**
         里——不显式共格的话网格会各给一行，于是字形把封面顶下去，两个都只剩一半高。 */
      .ui-track-art {
        display: grid;
        width: 38px;
        height: 38px;
        flex: none;
        overflow: hidden;
        place-items: center;
        border-radius: var(--radius-xs);
        color: var(--text-on-media);
        background: linear-gradient(145deg,
          var(--artwork-g1, var(--artwork-fallback-a)),
          var(--artwork-g2, var(--artwork-fallback-b)));
        font-size: var(--type-footnote-size);
        font-weight: var(--weight-bold);
      }
      .ui-track-art > * { grid-area: 1 / 1; }
      .ui-track-art img {
        width: 100%;
        height: 100%;
        object-fit: cover;
        opacity: 0;
        transition: opacity var(--duration-base) var(--ease-out);
      }
      .ui-track-art img[data-ready="true"] { opacity: 1; }

      /* 窄屏收列：先让专辑和歌词让位，再让艺术家和收藏让位。两页此前各写一套，
         而资料库页那套直接跳过了中间那一档。 */
      @media (max-width: 1023px) {
        .ui-track-head,
        .ui-track-row { grid-template-columns: minmax(0, 2fr) minmax(0, 1.2fr) 64px 40px; }
        .ui-track-head > span:nth-child(3),
        .ui-track-head > span:nth-child(4),
        .ui-track-album,
        .ui-track-lyrics { display: none; }
      }
      @media (max-width: 719px) {
        .ui-track-head,
        .ui-track-row { grid-template-columns: minmax(0, 1fr) 60px; }
        .ui-track-head > span:not(:first-child):not(:nth-child(5)),
        .ui-track-artist,
        .ui-track-favorite { display: none; }
      }
    """#

    private static let pointerAndTouch = #"""
      /* Two poster columns is the floor on a phone: one column per screen makes
         browsing a library a scrolling chore, and the artwork is already
         recognisable at half width. */
      @media (max-width: 719px) {
        .ui-media-grid { --grid-min: 132px; --grid-gap: var(--space-3); }
        .ui-media-grid-tight { --grid-min: 104px; }
        .ui-shelf { --grid-min: 136px; }
        .ui-segmented > label,
        .ui-segmented > a,
        .ui-segmented > button { height: var(--control-height-lg); }
      }
      @media (max-width: 419px) {
        .ui-media-grid { --grid-min: 118px; }
      }

      @media (hover: none), (pointer: coarse) {
        .ui-media-card:hover .ui-poster { box-shadow: var(--shadow-1); }
        .ui-media-card:hover .ui-poster img { transform: none; }
        .ui-card-interactive:hover { transform: none; box-shadow: var(--shadow-1); }
        .ui-play-affordance { opacity: 1; }
        .ui-row-trail .ui-btn-ghost { opacity: 1; }
        .ui-btn { min-height: var(--control-height-lg); }
        .ui-btn-icon { width: var(--control-height-lg); }
      }
    """#
}
