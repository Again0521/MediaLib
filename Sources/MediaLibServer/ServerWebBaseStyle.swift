import Foundation

/// Layer 2 of the Web design system: document-level defaults.
///
/// Everything here is the *ground* the interface stands on — the canvas, the
/// type scale, focus behaviour and the motion policy.  It deliberately styles
/// bare elements only; anything that needs a variant belongs in
/// `ServerWebPrimitives`.
enum ServerWebBaseStyle {
    static let css: String = """
    @layer base {
    \(reset)
    \(canvas)
    \(typography)
    \(icons)
    \(focusAndSelection)
    \(motionPolicy)
    }
    """

    private static let reset = #"""
      *, *::before, *::after { box-sizing: border-box; }
      html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
      body, h1, h2, h3, h4, h5, h6, p, figure, blockquote, dl, dd, ol, ul {
        margin: 0;
        padding: 0;
      }
      ol[class], ul[class] { list-style: none; }
      img, picture, svg, video, canvas { display: block; max-width: 100%; }
      img, video { height: auto; }
      svg { flex: none; }
      input, button, textarea, select { font: inherit; color: inherit; }
      button { background: none; border: 0; }
      table { border-collapse: collapse; border-spacing: 0; }
      [hidden] { display: none !important; }
      a { color: inherit; text-decoration: none; }
      a, button, input, label[for], select, summary, [role="button"] {
        touch-action: manipulation;
      }
      summary { cursor: pointer; }
      summary::-webkit-details-marker { display: none; }
    """#

    private static let canvas = #"""
      html, body { min-height: 100%; }
      body {
        min-height: 100dvh;
        overflow-x: hidden;
        color: var(--text-primary);
        background-color: var(--bg-canvas);
        font-family: var(--font-sans);
        font-size: var(--type-body-size);
        line-height: var(--type-body-line);
        font-weight: var(--weight-regular);
        -webkit-font-smoothing: antialiased;
        -moz-osx-font-smoothing: grayscale;
        text-rendering: optimizeLegibility;
        font-synthesis-weight: none;
      }

      /* The ambient field.  Two very low-chroma blooms, painted once and never
         animated, give the canvas depth without becoming a moving background. */
      body::before {
        content: "";
        position: fixed;
        z-index: -1;
        inset: 0;
        pointer-events: none;
        background:
          radial-gradient(72vw 52vh at 8% -8%, var(--bg-bloom-a), transparent 62%),
          radial-gradient(58vw 46vh at 96% 8%, var(--bg-bloom-b), transparent 60%);
      }

      /* 换页的交叉淡入。只有支持 View Transitions 的浏览器会走到这里；
         `prefers-reduced-motion` 由脚本判掉，不在这里再判一次（那样会留下一个
         时长为 0 的动画，Safari 上仍然会闪一下）。
         退出比进入短，与 `--duration-exit` 的取向一致。 */
      ::view-transition-old(root) {
        animation-duration: var(--duration-exit);
        animation-timing-function: var(--ease-in);
      }
      ::view-transition-new(root) {
        animation-duration: var(--duration-base);
        animation-timing-function: var(--ease-out);
      }

      ::-webkit-scrollbar { width: 12px; height: 12px; }
      ::-webkit-scrollbar-track { background: transparent; }
      ::-webkit-scrollbar-thumb {
        border: 3px solid transparent;
        border-radius: var(--radius-pill);
        background-clip: content-box;
        background-color: var(--border-strong);
      }
      ::-webkit-scrollbar-thumb:hover { background-color: var(--text-tertiary); }
      * { scrollbar-color: var(--border-strong) transparent; scrollbar-width: thin; }
    """#

    private static let typography = #"""
      .t-display, .t-title-1, .t-title-2, .t-title-3, .t-headline {
        color: var(--text-primary);
        text-wrap: balance;
      }
      .t-display {
        font-size: var(--type-display-size);
        line-height: var(--type-display-line);
        letter-spacing: var(--type-display-track);
        font-weight: var(--weight-bold);
      }
      .t-title-1 {
        font-size: var(--type-title1-size);
        line-height: var(--type-title1-line);
        letter-spacing: var(--type-title1-track);
        font-weight: var(--weight-bold);
      }
      .t-title-2 {
        font-size: var(--type-title2-size);
        line-height: var(--type-title2-line);
        letter-spacing: var(--type-title2-track);
        font-weight: var(--weight-semibold);
      }
      .t-title-3 {
        font-size: var(--type-title3-size);
        line-height: var(--type-title3-line);
        letter-spacing: var(--type-title3-track);
        font-weight: var(--weight-semibold);
      }
      .t-headline {
        font-size: var(--type-headline-size);
        line-height: var(--type-headline-line);
        letter-spacing: var(--type-headline-track);
        font-weight: var(--weight-semibold);
      }
      .t-body {
        font-size: var(--type-body-size);
        line-height: var(--type-body-line);
        letter-spacing: var(--type-body-track);
      }
      .t-callout {
        font-size: var(--type-callout-size);
        line-height: var(--type-callout-line);
        letter-spacing: var(--type-callout-track);
      }
      .t-subhead {
        font-size: var(--type-subhead-size);
        line-height: var(--type-subhead-line);
        letter-spacing: var(--type-subhead-track);
      }
      .t-footnote {
        font-size: var(--type-footnote-size);
        line-height: var(--type-footnote-line);
        letter-spacing: var(--type-footnote-track);
      }
      .t-caption {
        font-size: var(--type-caption-size);
        line-height: var(--type-caption-line);
        letter-spacing: var(--type-caption-track);
      }
      .t-secondary { color: var(--text-secondary); }
      .t-tertiary { color: var(--text-tertiary); }
      .t-mono, code, kbd, samp, pre { font-family: var(--font-mono); font-size: 0.92em; }

      /* Counts, durations, timecodes and table figures must not reflow as they
         tick, so numerals are tabular wherever they are compared or animated. */
      .t-numeric, time, .ui-table td, .ui-table th { font-variant-numeric: tabular-nums; }

      .t-prose { max-width: var(--page-max-prose); }
      .t-truncate {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      /* One clamp, parameterised by `--clamp-lines`.  The two fixed classes are
         kept because most callers want exactly two or three lines and should not
         have to name a number; anything else (a synopsis, a rule summary) sets
         the property.  `overflow-wrap: anywhere` is what stops one unbroken run
         — a URL, a long CJK sentence with no spaces — from widening the column
         instead of wrapping into the line budget. */
      .t-clamp, .t-clamp-2, .t-clamp-3 {
        display: -webkit-box;
        overflow: hidden;
        -webkit-box-orient: vertical;
        -webkit-line-clamp: var(--clamp-lines, 3);
        line-clamp: var(--clamp-lines, 3);
        overflow-wrap: anywhere;
      }
      .t-clamp-2 { --clamp-lines: 2; }
      .t-clamp-3 { --clamp-lines: 3; }

      .visually-hidden {
        position: absolute;
        width: 1px;
        height: 1px;
        margin: -1px;
        padding: 0;
        overflow: hidden;
        border: 0;
        clip-path: inset(50%);
        white-space: nowrap;
      }
    """#

    /// Icons take their size from a class rather than a `width` attribute so the
    /// bounding box stays identical across the whole family — mismatched boxes are
    /// what make an icon set look assembled rather than designed.
    private static let icons = #"""
      .icon { flex: none; color: currentColor; }
      .icon-xs { width: var(--icon-xs); height: var(--icon-xs); }
      .icon-sm { width: var(--icon-sm); height: var(--icon-sm); }
      .icon-md { width: var(--icon-md); height: var(--icon-md); }
      .icon-lg { width: var(--icon-lg); height: var(--icon-lg); }
      .icon-xl { width: var(--icon-xl); height: var(--icon-xl); }
      .icon-accent { color: var(--accent); }
      .icon-muted { color: var(--text-tertiary); }

      /* 双色字形的面层。透明度写在这里而不是 SVG 的 `fill-opacity` 属性上，
         因为它是**外观相关**的：浅色底上 0.16 刚好读作"有点体积"，同样的值放
         在深色底上会几乎看不见。属性写死就没有第二套值可言。 */
      .icon-duotone .icon-duotone-shade { opacity: 0.17; }
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme="light"]) .icon-duotone .icon-duotone-shade { opacity: 0.26; }
      }
      :root[data-theme="dark"] .icon-duotone .icon-duotone-shade { opacity: 0.26; }
      /* 高对比下面层整个撤掉：它压低的正是线条与底之间那点对比。 */
      @media (prefers-contrast: more) {
        .icon-duotone .icon-duotone-shade { opacity: 0; }
      }
    """#

    private static let focusAndSelection = #"""
      ::selection { color: var(--text-on-accent); background: var(--accent); }

      /* One focus treatment for the whole product.  It is never removed — only
         restricted to keyboard traversal, where it is the sole way to tell where
         you are. */
      :focus { outline: none; }
      :focus-visible {
        outline: 2px solid var(--accent);
        outline-offset: 2px;
        border-radius: var(--radius-xs);
      }

      .skip {
        position: fixed;
        z-index: var(--z-skip);
        top: var(--space-3);
        left: var(--space-3);
        display: inline-flex;
        min-height: var(--control-height-lg);
        align-items: center;
        padding: 0 var(--space-4);
        border-radius: var(--radius-sm);
        color: var(--text-on-accent);
        background: var(--accent);
        box-shadow: var(--shadow-3);
        font-size: var(--type-callout-size);
        font-weight: var(--weight-semibold);
        transform: translateY(calc(-100% - var(--space-4)));
        transition: transform var(--duration-fast) var(--ease-out);
      }
      .skip:focus-visible { transform: none; }
    """#

    /// Reduced motion is a substitution, not a switch.
    ///
    /// Blanket `animation: none` also silences spinners, progress and skeletons —
    /// the very feedback that tells someone the product is still working.  Instead
    /// movement collapses to a short cross-fade, and indeterminate indicators keep
    /// a slow, non-vestibular pulse.
    private static let motionPolicy = #"""
      @media (prefers-reduced-motion: reduce) {
        *, *::before, *::after {
          animation-duration: var(--duration-base) !important;
          animation-iteration-count: 1 !important;
          transition-duration: var(--duration-fast) !important;
          scroll-behavior: auto !important;
        }
        /* Movement, scale and blur are replaced by opacity; colour and opacity
           feedback survive untouched. */
        *, *::before, *::after {
          transition-property: opacity, background-color, border-color, color, box-shadow !important;
          transform: none !important;
        }
        .ui-spinner, .ui-progress-indeterminate::after {
          animation: ui-reduced-pulse 1.6s var(--ease-in-out) infinite alternate !important;
        }
        .ui-skeleton { animation: none !important; }
        /* One exemption, and it is not motion: the hero carousel *positions* its
           slides with a transform.  Blanketing `transform: none` there would not
           calm anything down — it would stack every slide at zero and leave the
           dots and arrows inert.  The travel itself is disabled in the script,
           which reads the same media query. */
        .hero-track { transform: translate3d(calc(var(--hero-offset, 0px) * -1), 0, 0) !important; }
      }
      @keyframes ui-reduced-pulse {
        from { opacity: 0.35; }
        to { opacity: 1; }
      }
    """#
}
