import Foundation

/// Layer 4 of the Web design system: the application frame.
///
/// This sheet is responsible for exactly one thing — where the persistent chrome
/// sits and how it adapts. It no longer restyles buttons, cards, inputs, grids or
/// posters; those belong to `ServerWebPrimitives`, and the previous version's
/// habit of reaching across into them is what produced 170 `!important`
/// declarations in a single file.
///
/// The sidebar is the product's one piece of *thick* material: it separates a
/// structural region, content scrolls underneath it, and it is the only surface
/// wide enough to justify a 40px blur.
enum ServerWebShellStyle {
    static let css: String = """
    @layer shell {
    \(frame)
    \(sidebar)
    \(navigation)
    \(appearanceControl)
    \(pageHeader)
    \(mobile)
    \(navigationProgress)
    \(audioDock)
    }
    """

    private static let frame = #"""
      .shell {
        display: grid;
        grid-template-columns: var(--sidebar-width) minmax(0, 1fr);
        min-height: 100dvh;
        width: 100%;
      }
      /* One content measure for the whole product, carried by the column itself
         rather than by every child.
         The measure used to be `.app-main > * { max-width; margin-inline: auto }`,
         which silently centred any child that constrained itself further — a
         460px search field landed in the middle of the page instead of on the
         left rail, and pages worked around it one by one with `margin-inline: 0`.
         Constraining the column instead means children simply fill it, and a
         narrower child stays on the rail with everything else. */
      .app-main {
        grid-column: 2;
        min-width: 0;
        /* `width` is required, not redundant: auto inline margins on a grid item
           make it shrink-wrap its content instead of filling the track. */
        width: 100%;
        max-width: calc(var(--page-max) + 2 * var(--page-gutter));
        margin-inline: auto;
        padding: var(--page-top) var(--page-gutter) var(--space-12);
      }
      /* Full-bleed sections opt out explicitly rather than every page inventing
         its own width. */
      .app-main > .app-bleed { margin-inline: calc(-1 * var(--page-gutter)); }
      body[data-dialog-open="true"] { overflow: hidden; }
    """#

    private static let sidebar = #"""
      .app-sidebar {
        position: sticky;
        z-index: var(--z-sidebar);
        top: 0;
        display: flex;
        height: 100dvh;
        flex-direction: column;
        gap: var(--space-2);
        padding: var(--space-5) var(--space-3) var(--space-4);
        overflow-y: auto;
        overscroll-behavior: contain;
        border-right: var(--hairline) solid var(--border);
        background: var(--glass-thick-bg);
        -webkit-backdrop-filter: var(--glass-thick-blur);
        backdrop-filter: var(--glass-thick-blur);
        box-shadow: var(--glass-thick-highlight);
        scrollbar-width: none;
      }
      .app-sidebar::-webkit-scrollbar { display: none; }

      .app-brand {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        padding: var(--space-1) var(--space-2) var(--space-4);
        color: var(--text-primary);
      }
      /* 几何与材质来自 `.ui-icon-tile-sm` + `.ui-icon-tile-brand`。品牌标此前
         自带一份 34px、一条硬编码的 40% 白内高光，以及**直接引用原语**的蓝色
         渐变——那条渐变同时被登录页和保险库抄走了两份。 */
      .app-brand-mark > svg { width: 18px; height: 18px; }
      .app-brand-copy { display: grid; min-width: 0; gap: 1px; }
      .app-brand-copy strong {
        font-size: var(--type-headline-size);
        font-weight: var(--weight-bold);
        letter-spacing: -0.01em;
      }
      .app-brand-copy span {
        color: var(--text-tertiary);
        font-size: var(--type-caption-size);
        letter-spacing: var(--type-caption-track);
      }

      .app-sidebar-foot {
        display: grid;
        gap: var(--space-2);
        margin-top: auto;
        padding-top: var(--space-4);
        border-top: var(--hairline) solid var(--divider);
      }
      .app-status-card {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        padding: var(--space-2) var(--space-3);
        border-radius: var(--radius-sm);
        color: var(--text-primary);
        transition: background-color var(--duration-fast) var(--ease-out);
      }
      .app-status-card:hover { background: var(--surface-hover); }
      /* 侧栏底部的状态卡比正文小一号，所以它是唯一一处把 sm 底板再收窄的地方。 */
      .app-status-icon { width: 30px; height: 30px; }
      .app-status-icon > svg { width: var(--icon-sm); height: var(--icon-sm); }
      .app-status-copy { display: grid; min-width: 0; gap: 1px; }
      .app-status-copy strong { font-size: var(--type-subhead-size); font-weight: var(--weight-semibold); }
      .app-status-copy span {
        overflow: hidden;
        color: var(--text-tertiary);
        font-size: var(--type-caption-size);
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .app-sidebar-note {
        padding: var(--space-3);
        border-radius: var(--radius-sm);
        color: var(--text-tertiary);
        background: var(--surface-sunken);
        font-size: var(--type-caption-size);
        line-height: 1.5;
      }
      .app-sidebar-note strong { display: block; color: var(--text-secondary); }
    """#

    private static let navigation = #"""
      .app-nav { display: grid; gap: var(--nav-gap); }
      .app-nav-group + .app-nav-group { margin-top: var(--space-4); }
      .app-nav-title {
        padding: 0 var(--space-3) var(--space-2);
        color: var(--text-tertiary);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        letter-spacing: 0.07em;
        text-transform: uppercase;
      }

      .nav-item {
        position: relative;
        display: flex;
        min-height: var(--nav-item-height);
        align-items: center;
        gap: var(--space-3);
        padding: 0 var(--space-3);
        border-radius: var(--nav-item-radius);
        color: var(--text-secondary);
        font-size: var(--type-callout-size);
        font-weight: var(--weight-medium);
        transition:
          color var(--duration-fast) var(--ease-out),
          background-color var(--duration-fast) var(--ease-out),
          transform var(--duration-instant) var(--ease-out);
      }
      .nav-item > svg { width: var(--nav-icon-size); height: var(--nav-icon-size); color: var(--text-tertiary); }
      .nav-item > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .nav-item:hover { color: var(--text-primary); background: var(--surface-hover); }
      .nav-item:active, .nav-subitem:active { transform: scale(0.985); }
      .nav-item:hover > svg { color: var(--text-secondary); }

      /* Current location is carried by three signals at once — a tinted plate, a
         colour shift and a weight change — so it survives both colour-blindness
         and a low-contrast display. */
      .nav-item[aria-current] {
        color: var(--accent-text);
        background: var(--accent-subtle);
        font-weight: var(--weight-semibold);
      }
      .nav-item[aria-current] > svg { color: var(--accent); }
      .nav-item[aria-current]::before {
        content: "";
        position: absolute;
        top: 50%;
        left: calc(var(--space-3) * -1);
        width: 3px;
        height: 18px;
        border-radius: var(--radius-pill);
        background: var(--accent);
        transform: translateY(-50%);
      }
      .nav-count {
        margin-left: auto;
        color: var(--text-tertiary);
        font-size: var(--type-caption-size);
        font-variant-numeric: tabular-nums;
      }

      /* Groups are native disclosures: they expand without JavaScript and the
         browser keeps their state through a back navigation. */
      .nav-disclosure > summary {
        display: flex;
        min-height: var(--nav-item-height);
        align-items: center;
        gap: var(--space-3);
        padding: 0 var(--space-3);
        border-radius: var(--nav-item-radius);
        color: var(--text-secondary);
        font-size: var(--type-callout-size);
        font-weight: var(--weight-medium);
      }
      .nav-disclosure > summary:hover { color: var(--text-primary); background: var(--surface-hover); }
      .nav-disclosure > summary > svg:first-child {
        width: var(--nav-icon-size);
        height: var(--nav-icon-size);
        color: var(--text-tertiary);
      }
      .nav-chevron {
        width: var(--icon-xs);
        height: var(--icon-xs);
        margin-left: auto;
        color: var(--text-tertiary);
        transition: transform var(--duration-base) var(--ease-out);
      }
      .nav-disclosure[open] > summary .nav-chevron { transform: rotate(90deg); }
      .nav-subitems {
        display: grid;
        gap: var(--nav-gap);
        margin: var(--space-1) 0 var(--space-2) calc(var(--space-3) + var(--nav-icon-size) / 2);
        padding-left: var(--space-3);
        border-left: var(--hairline) solid var(--divider);
      }
      .nav-subitem {
        display: flex;
        min-height: 30px;
        align-items: center;
        gap: var(--space-2);
        padding: 0 var(--space-2);
        border-radius: var(--radius-xs);
        color: var(--text-secondary);
        font-size: var(--type-subhead-size);
        transition: color var(--duration-fast) var(--ease-out), background-color var(--duration-fast) var(--ease-out);
      }
      .nav-subitem > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .nav-subitem:hover { color: var(--text-primary); background: var(--surface-hover); }
      .nav-subitem[aria-current] { color: var(--accent-text); font-weight: var(--weight-semibold); }
      .nav-dot {
        width: 5px;
        height: 5px;
        flex: none;
        border: 1.5px solid currentColor;
        border-radius: 50%;
        opacity: 0.5;
      }
      .nav-subitem[aria-current] .nav-dot { background: currentColor; opacity: 1; }
    """#

    /// 外观切换器的全部外观来自 `.ui-segmented`（见 `ServerWebUI.appearanceSwitcher`）。
    /// 这里只剩它在侧栏里的位置。
    private static let appearanceControl = #"""
      .app-appearance { margin-top: var(--space-2); }
    """#

    private static let pageHeader = #"""
      /* 16px to the filter bar below, matching the client's
         `AppSpacing.headerToControls`.  The 48px rhythm between page sections is
         the container's `gap`; the header owning a larger bottom margin as well
         put a second, different gap between a title and the controls that belong
         to it. */
      .app-page-head {
        display: flex;
        flex-direction: column;
        gap: var(--space-3);
        padding-bottom: var(--space-4);
      }
      .app-page-head-main {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-end;
        justify-content: space-between;
        gap: var(--space-4);
      }
      /* The copy takes the room that is left; the trailing slot keeps its own
         measure.  Without a basis the copy claims its full 72ch subtitle and
         squeezes the actions until search and the page's button stack into two
         rows with empty space beside them. */
      .app-page-head-copy { display: flex; min-width: 0; flex: 1 1 420px; flex-direction: column; gap: var(--space-2); }
      .app-page-identity { display: flex; align-items: center; gap: var(--space-3); }
      /* Taller than it is wide, like the client's 62×68 identity slot: the tile
         reads as the page's mark rather than as one more square button in a row
         of square buttons.

         材质、圆角、内高光都来自 `.ui-icon-tile-lg`（primitives 层）；这里只保
         留页头独有的那一件事——把方底板拉成竖长方形。之前整块规则连同一条硬编
         码的白色内高光都写在这里，于是它和空态、品牌标、统计格四处各调各的。 */
      .app-page-icon { height: 58px; }
      /* The one glyph-less identity: a person has a monogram, not an icon. */
      .app-page-icon-monogram {
        font-size: var(--type-title2-size);
        font-weight: var(--weight-bold);
        letter-spacing: 0.01em;
      }
      .app-eyebrow {
        color: var(--text-tertiary);
        font-size: var(--type-caption-size);
        font-weight: var(--weight-semibold);
        letter-spacing: 0.09em;
        text-transform: uppercase;
      }
      .app-page-head h1 {
        font-size: var(--type-display-size);
        line-height: var(--type-display-line);
        letter-spacing: var(--type-display-track);
        font-weight: var(--weight-black);
      }
      .app-subtitle {
        max-width: 72ch;
        color: var(--text-secondary);
        font-size: var(--type-callout-size);
        line-height: var(--type-body-line);
      }
      /* The live count rides the subtitle rather than sitting in its own block,
         so "what this page is" and "how much of it there is" are one sentence —
         and the number updates in place when a filter changes. */
      .app-subtitle-count { color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
      /* Primary action sits at the end of the header row, secondary actions to its
         left, so the emphasised control is always in the same place. */
      .app-page-actions { display: flex; flex: 0 0 auto; flex-wrap: nowrap; align-items: center; gap: var(--space-2); }
      /* Search leads the trailing slot at a fixed measure, so it reads as a
         control rather than a stray form, and the page's own actions keep their
         position to its right. */
      .app-page-search { flex: 0 1 320px; min-width: 200px; }
      .app-back { align-self: flex-start; margin-left: calc(var(--space-3) * -1); }
    """#

    /// Below the desktop breakpoint the sidebar is not shrunk — it is replaced.
    ///
    /// A translucent top bar carries the brand, a drawer holds the full
    /// navigation, and a bottom tab bar exposes the five destinations people
    /// actually move between. Scaling the desktop rail down would have produced a
    /// nav that is technically present and practically unusable.
    private static let mobile = #"""
      .app-mobile-bar, .app-tabbar, .app-drawer-toggle, .app-drawer-scrim { display: none; }
      /* The drawer runs on a checkbox rather than a script, so navigation still
         opens if the shell bundle fails to load. */
      .app-drawer-state { display: none; }

      @media (max-width: 1023px) {
        .shell { grid-template-columns: minmax(0, 1fr); }
        .app-main {
          grid-column: 1;
          padding-top: calc(var(--space-4) + 52px + env(safe-area-inset-top));
          padding-bottom: calc(var(--tabbar-height) + var(--space-9) + env(safe-area-inset-bottom));
        }

        .app-sidebar {
          position: fixed;
          z-index: var(--z-modal);
          top: 0;
          bottom: 0;
          left: 0;
          width: min(320px, 86vw);
          height: 100dvh;
          padding-top: calc(var(--space-5) + env(safe-area-inset-top));
          transform: translateX(-101%);
          transition: transform var(--duration-base) var(--ease-out);
          box-shadow: var(--shadow-4);
        }
        .app-drawer-state:checked ~ .app-sidebar { transform: none; }

        .app-drawer-scrim {
          position: fixed;
          z-index: var(--z-overlay);
          inset: 0;
          display: block;
          background: var(--surface-scrim);
          opacity: 0;
          pointer-events: none;
          transition: opacity var(--duration-base) var(--ease-out);
        }
        .app-drawer-state:checked ~ .app-drawer-scrim { opacity: 1; pointer-events: auto; }

        .app-mobile-bar {
          position: fixed;
          z-index: var(--z-sticky);
          top: 0;
          right: 0;
          left: 0;
          display: flex;
          height: calc(52px + env(safe-area-inset-top));
          align-items: center;
          gap: var(--space-2);
          padding: env(safe-area-inset-top) var(--space-4) 0;
          border-bottom: var(--hairline) solid var(--border);
          background: var(--glass-regular-bg);
          -webkit-backdrop-filter: var(--glass-regular-blur);
          backdrop-filter: var(--glass-regular-blur);
        }
        .app-mobile-title {
          flex: 1;
          min-width: 0;
          overflow: hidden;
          font-size: var(--type-headline-size);
          font-weight: var(--weight-semibold);
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .app-drawer-toggle { display: inline-flex; }

        .app-tabbar {
          position: fixed;
          z-index: var(--z-dock);
          right: 0;
          bottom: 0;
          left: 0;
          display: grid;
          grid-auto-flow: column;
          grid-auto-columns: 1fr;
          height: calc(var(--tabbar-height) + env(safe-area-inset-bottom));
          padding-bottom: env(safe-area-inset-bottom);
          border-top: var(--hairline) solid var(--border);
          background: var(--glass-regular-bg);
          -webkit-backdrop-filter: var(--glass-regular-blur);
          backdrop-filter: var(--glass-regular-blur);
        }
        .app-tab {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          gap: 2px;
          color: var(--text-tertiary);
          font-size: 10px;
          font-weight: var(--weight-medium);
          letter-spacing: 0.01em;
        }
        .app-tab > svg { width: var(--icon-md); height: var(--icon-md); }
        .app-tab[aria-current] { color: var(--accent-text); }
        .app-page-head { padding-bottom: var(--space-4); }
      }

      @media (max-width: 719px) {
        .app-page-head-main { align-items: flex-start; }
        .app-page-icon { width: 44px; height: 48px; }
        .app-page-actions { width: 100%; flex-wrap: wrap; }
        .app-page-actions .ui-btn { flex: 1 1 auto; }
        /* On a phone the field takes the full row: a 320px control beside a
           wrapped button row leaves an awkward gap and a small tap target. */
        .app-page-search { flex: 1 1 100%; }
      }

      /* Between the phone tab bar and the full rail, the rail stays but narrows;
         labels remain because an icon-only rail is a discoverability tax. */
      @media (min-width: 1024px) and (max-width: 1279px) {
        :root { --sidebar-width: 216px; }
      }
    """#

    private static let navigationProgress = #"""
      /* Progressive document swaps have no browser spinner, so the shell draws
         its own: a thin indeterminate bar pinned to the top of the content area. */
      html.app-shell-navigating .app-main { cursor: progress; }
      html.app-shell-navigating::before {
        content: "";
        position: fixed;
        z-index: var(--z-toast);
        top: 0;
        left: 0;
        width: 100%;
        height: 2px;
        background: linear-gradient(90deg, transparent, var(--accent), transparent);
        background-size: 40% 100%;
        background-repeat: no-repeat;
        animation: app-shell-progress 1s var(--ease-in-out) infinite;
      }
      @keyframes app-shell-progress {
        0% { background-position: -40% 0; }
        100% { background-position: 140% 0; }
      }
    """#

    /// The persistent audio dock.
    ///
    /// It floats above every page, so it is the second place in the product that
    /// earns a glass material.  Its DOM is built by `app-shell.js`; the class and
    /// id names here are that script's contract and must not be renamed on their
    /// own.
    private static let audioDock = #"""
      #medialib-audio-dock {
        position: fixed;
        z-index: var(--z-dock);
        right: var(--space-4);
        bottom: var(--space-4);
        left: calc(var(--sidebar-width) + var(--space-4));
        display: flex;
        flex-direction: column;
        overflow: hidden;
        border: var(--hairline) solid var(--glass-regular-border);
        border-radius: var(--radius-lg);
        background: var(--glass-regular-bg);
        -webkit-backdrop-filter: var(--glass-regular-blur);
        backdrop-filter: var(--glass-regular-blur);
        box-shadow: var(--glass-regular-highlight), var(--shadow-4);
        animation: app-dock-in var(--duration-slow) var(--ease-out);
      }
      /* 玻璃是"显形"进场：模糊半径与缩放一起动，底栏读作一层材质滑到位，
         而不是一张突然出现的图片。 */
      @keyframes app-dock-in {
        from { opacity: 0; transform: translateY(16px) scale(0.98); -webkit-backdrop-filter: blur(0); backdrop-filter: blur(0); }
        to { opacity: 1; transform: none; }
      }

      /* ---- Section entrance -------------------------------------------------
         Blocks arrive as they scroll into view: 12px of travel and a fade, once
         each, staggered by at most four steps.  `will-reveal` is added by the
         script rather than authored into the markup, so a reader without
         JavaScript never sees a page of permanently invisible sections. */
      .will-reveal {
        opacity: 0;
        transform: translateY(12px);
      }
      .will-reveal.is-revealed {
        opacity: 1;
        transform: none;
        transition:
          opacity var(--duration-slow) var(--ease-out) var(--reveal-delay, 0ms),
          transform var(--duration-slow) var(--ease-out) var(--reveal-delay, 0ms);
      }

      /* 底栏是固定定位的浮层，会盖住页面尾部。脚本一直在给 <body> 加这个类，
         但全仓没有任何一条规则命中它——于是播放音乐时每一页的最后一段内容都被
         76px 高的底栏压住，且没有任何办法滚出来。 */
      body.medialib-audio-dock-visible .app-main { padding-bottom: 112px; }
      @media (max-width: 1023px) {
        body.medialib-audio-dock-visible .app-main {
          padding-bottom: calc(112px + var(--tabbar-height) + env(safe-area-inset-bottom, 0px));
        }
      }

      /* Three columns, as on every music service: what is playing, the
         transport with its scrubber on the centre line, and output controls.
         The previous bar put the transport off to one side, hid the elapsed and
         total times behind a single label, and pinned the scrubber to the dock's
         bottom edge as a 3px hairline. */
      .ml-audio-content {
        position: relative;
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1.6fr) minmax(0, 1fr);
        align-items: center;
        gap: var(--space-4);
        min-height: 76px;
        padding: var(--space-2) var(--space-4);
      }
      .ml-audio-lead { display: flex; min-width: 0; align-items: center; gap: var(--space-3); }
      /* 底栏那层由当前封面取色染出来的环境光。
         底栏是浮在内容之上的前景外壳，材质在这里是允许的（设计文档 §2）；这一
         层压在玻璃**底下**，所以它不构成"玻璃叠玻璃"，只是给这块玻璃换了一张
         底片。透明度压得很低——它要读作"这块玻璃背后有这首歌的颜色"，而不是
         一块彩色面板。 */
      .ml-audio-ambient {
        position: absolute;
        z-index: -1;
        /* 往外扩一圈：下面那道模糊会把元素边缘糊成半透明，正好扩出去用玻璃的
           圆角裁掉，否则四条边会看得出一圈更淡的带子。 */
        inset: -14%;
        /* 底栏的主色是**白色**，这一层只是白底后面透出的一点点颜色。
           之前是 0.34——那个浓度下整条底栏被染成了封面的颜色，读起来像一块彩色
           面板而不是一层玻璃。 */
        opacity: 0.1;
        /* 再糊一道：取色只该剩下"大概是什么色"，不该看得出两团渐变的形状。 */
        filter: blur(30px);
        background:
          radial-gradient(120% 180% at 8% 50%, var(--artwork-g2, transparent) 0%, transparent 62%),
          radial-gradient(90% 160% at 92% 50%, var(--artwork-g1, transparent) 0%, transparent 66%);
        transition: opacity var(--duration-slow) var(--ease-out);
        pointer-events: none;
      }
      /* 深色下底没有白可言，同样的浓度会淡到看不见，稍微抬一点。 */
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme="light"]) .ml-audio-ambient { opacity: 0.18; }
      }
      :root[data-theme="dark"] .ml-audio-ambient { opacity: 0.18; }
      /* 高对比下这层光整个撤掉：它降低的正是底栏文字与底之间的对比。 */
      @media (prefers-contrast: more) {
        .ml-audio-ambient { opacity: 0; }
      }

      .ml-audio-cover {
        display: grid;
        width: 56px;
        height: 56px;
        flex: none;
        overflow: hidden;
        place-items: center;
        border-radius: var(--radius-sm);
        color: var(--text-tertiary);
        background: var(--surface-sunken);
        box-shadow: var(--inner-highlight), var(--shadow-2);
      }
      .ml-audio-cover img { width: 100%; height: 100%; object-fit: cover; transition: opacity var(--duration-base) var(--ease-out); }
      .ml-audio-copy { display: grid; min-width: 0; gap: 1px; }
      /* 跑马灯：只在标题真的放不下时、且只在指针停留或键盘聚焦时跑一趟，跑完
         停在末尾，指针离开再滑回来。常驻循环是注意力税（设计文档 §2 禁止常驻
         动画），但一个被截断到看不出是哪首歌的曲名，读者没有别的办法看全。

         位移量由脚本量出来写进 `--marquee-shift`：CSS 拿不到"溢出了多少"。 */
      .ml-audio-title-track { overflow: hidden; }
      .ml-audio-copy strong {
        display: block;
        overflow: hidden;
        font-size: var(--type-callout-size);
        font-weight: var(--weight-semibold);
        text-overflow: ellipsis;
        white-space: nowrap;
        transition: transform var(--duration-slow) var(--ease-out);
      }
      .ml-audio-title-track[data-overflowing="true"]:hover > strong,
      .ml-audio-title-track[data-overflowing="true"]:focus-within > strong {
        overflow: visible;
        text-overflow: clip;
        transform: translateX(var(--marquee-shift, 0));
        transition-duration: 2.4s;
        transition-timing-function: linear;
      }
      .ml-audio-copy span {
        overflow: hidden;
        color: var(--text-tertiary);
        font-size: var(--type-footnote-size);
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .ml-audio-centre { display: grid; min-width: 0; justify-items: center; gap: var(--space-1); }
      .ml-audio-controls { display: flex; align-items: center; gap: var(--space-2); }
      .ml-audio-controls button {
        display: grid;
        width: 34px;
        height: 34px;
        place-items: center;
        border-radius: 50%;
        color: var(--text-secondary);
        cursor: pointer;
        transition: background-color var(--duration-fast) var(--ease-out), color var(--duration-fast) var(--ease-out), transform var(--duration-instant) var(--ease-out);
      }
      .ml-audio-controls button > svg { width: var(--icon-md); height: var(--icon-md); }
      .ml-audio-controls button:hover { color: var(--text-primary); background: var(--surface-hover); }
      .ml-audio-controls button:active { transform: scale(0.94); }
      .ml-audio-controls button:disabled { opacity: 0.4; cursor: not-allowed; }
      .ml-audio-controls button:disabled:hover { color: var(--text-secondary); background: transparent; }
      /* Shuffle and repeat are modes, so they stay lit while they are on. */
      .ml-audio-controls .is-active { color: var(--accent-text); background: var(--accent-subtle); }
      /* 播放键是整条底栏最大的一个圆，从前还是唯一一块实心强调色——底栏本身是
         一层安静的玻璃，上面按一颗饱和的蓝色圆，读起来像贴上去的，而不是这条
         栏杆的一部分。客户端的 mini player 同样不给传输键上强调色。
         强调色在这条栏里只留一处：进度条已播过的那一段。那才是真正需要一眼看
         出"到哪儿了"的东西。播放键靠尺寸和实心底立层级，不靠颜色喊。 */
      /* 选择器必须带上父级：`.ml-audio-controls button` 是"一个类 + 一个元素"，
         比单独一个 `.ml-audio-play` 更具体，宽高和颜色都会被它压回去。之前那版
         正是这样——播放键写着 `color: var(--text-on-accent)`，实际渲染出来的却
         是 `--text-secondary`；蓝底上勉强还看得见，换成深色底就彻底糊了。 */
      .ml-audio-controls .ml-audio-play {
        width: 42px;
        height: 42px;
        color: var(--text-inverse);
        background: var(--text-primary);
        box-shadow: var(--shadow-1);
      }
      .ml-audio-controls .ml-audio-play:hover { color: var(--text-inverse); background: var(--text-primary); opacity: 0.86; }
      .ml-audio-controls .ml-audio-play > svg { width: var(--icon-lg); height: var(--icon-lg); }

      .ml-audio-scrubber { display: flex; width: 100%; align-items: center; gap: var(--space-2); }
      .ml-audio-time {
        flex: none;
        min-width: 40px;
        color: var(--text-tertiary);
        font-size: var(--type-caption-size);
        font-variant-numeric: tabular-nums;
      }
      .ml-audio-scrubber .ml-audio-time:last-child { text-align: right; }

      .ml-audio-trail { display: flex; align-items: center; gap: var(--space-2); justify-content: flex-end; }
      .ml-audio-trail button, .ml-audio-queue {
        display: grid;
        width: 32px;
        height: 32px;
        flex: none;
        place-items: center;
        border-radius: 50%;
        color: var(--text-tertiary);
        cursor: pointer;
        transition: background-color var(--duration-fast) var(--ease-out), color var(--duration-fast) var(--ease-out);
      }
      .ml-audio-trail button > svg, .ml-audio-queue > svg { width: var(--icon-sm); height: var(--icon-sm); }
      .ml-audio-trail button:hover, .ml-audio-queue:hover { color: var(--text-primary); background: var(--surface-hover); }
      .ml-audio-trail button.is-active { color: var(--accent-text); background: var(--accent-subtle); }

      /* 两条滑杆的槽、把手、填充都来自 primitives 层的 `.ui-range`（JS 给它们
         挂了 `ui-range` 类），这里只留下尺寸这类真正属于底栏的事。从前这一整
         块是自己写的一套伪元素规则，和播放器里的那一套各写各的——于是播放器
         的音量条干脆漏了，渲染成系统原生控件。 */
      .ml-audio-progress-bar { flex: 1; min-width: 0; }
      /* 音量条从 84px 加到 132px。84px 的行程里，5% 一档的步进只有 4px 宽，
         想调到某个具体音量基本靠碰运气；把手也不再等到 hover 才出现——它是
         这条控件唯一在说"这里可以拖"的东西。 */
      .ml-audio-volume {
        width: 132px;
        flex: none;
        --range-hit: 20px;
      }

      @media (max-width: 1023px) {
        #medialib-audio-dock {
          right: var(--space-2);
          bottom: calc(var(--tabbar-height) + var(--space-2) + env(safe-area-inset-bottom));
          left: var(--space-2);
        }
        /* On a phone the bar keeps what a phone player keeps: what is playing,
           play/next, and the scrubber. Shuffle, repeat and output move out of
           the way rather than shrinking into unhittable targets. */
        .ml-audio-content { grid-template-columns: minmax(0, 1fr) auto; gap: var(--space-3); min-height: 64px; padding: var(--space-2) var(--space-3); }
        .ml-audio-centre { justify-items: end; }
        .ml-audio-scrubber { position: absolute; right: var(--space-3); bottom: 4px; left: var(--space-3); width: auto; }
        .ml-audio-shuffle, .ml-audio-repeat, .ml-audio-prev, .ml-audio-trail { display: none; }
        .ml-audio-scrubber .ml-audio-time { display: none; }
      }

      /* 触摸下的 44px 下限。
         底栏的传输键不是 `.ui-btn`（它们是自己一套 34/42px 的圆键），所以
         primitives 里那条 `(pointer: coarse) { .ui-btn { min-height: 44px } }`
         对它们完全不生效——手机上留下的恰恰是 42px 的播放键和 34px 的下一首。
         窄屏已经把次要键整条藏掉了（上面那段），剩下的这几个就必须够大。
         只按指针粗细判，不按宽度：平板横屏在 1023px 以上，但手指没有变细。 */
      @media (pointer: coarse) {
        .ml-audio-controls button,
        .ml-audio-controls .ml-audio-play,
        .ml-audio-trail button,
        .ml-audio-queue { width: 44px; height: 44px; }
      }
    """#
}
