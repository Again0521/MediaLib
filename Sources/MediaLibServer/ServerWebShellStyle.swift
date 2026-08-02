import Foundation

/// Shared, cacheable visual shell for the authenticated Web application.
///
/// Feature-specific rules stay beside their markup. This last-loaded sheet owns the
/// desktop application chrome so every page keeps the same sidebar and canvas.
enum ServerWebShellStyle {
    static let css = """
    :root { --ml-primary:#2e90fa; --ml-sky:#36bffa; --ml-pink:#ff5c8a; --ml-canvas:#f6f8fc; --ml-sidebar:#fbfcfe; --ml-sidebar-line:#e9edf4; --ml-sidebar-ink:#5a6478; --ml-sidebar-active:#173f70; --ml-sidebar-title:#1d1d1f; --ml-sidebar-muted:#8b96a8; --ml-sidebar-card:#ffffff; }
    html { min-width:320px; background:var(--ml-canvas); }
    body { background:var(--ml-canvas); }
    .shell { display:grid; grid-template-columns:258px minmax(0,1fr); min-height:100dvh; }
    .shell > aside { padding:18px 14px 14px; color:var(--ml-sidebar-ink); background:linear-gradient(180deg,#fbfcfe 0%,#f5f8fd 100%); border-right:1px solid var(--ml-sidebar-line); }
    .shell > .app-sidebar { position:sticky; top:0; align-self:start; width:252px; height:100dvh; overflow-y:auto; scrollbar-width:thin; scrollbar-color:#cbd5e1 transparent; }
    .app-brand { display:flex; min-height:44px; gap:11px; align-items:center; color:var(--ml-sidebar-title); text-decoration:none; padding:0 8px; border-radius:12px; }
    .app-brand:active { opacity:.82; }
    .brand-mark { position:relative; display:block; flex:none; width:38px; height:38px; border-radius:12px; background:linear-gradient(135deg,#f8fbff,#eaf4ff); box-shadow:0 7px 16px #2e90fa35; overflow:hidden; }
    .brand-mark-card { position:absolute; display:block; border-radius:5px; transform:rotate(-7deg); }
    .brand-mark-card-back { width:23px; height:17px; left:7px; top:8px; background:linear-gradient(135deg,#ff5c8a,#ff9f45); opacity:.9; }
    .brand-mark-card-front { width:22px; height:17px; left:10px; top:14px; background:linear-gradient(135deg,var(--ml-primary),var(--ml-sky)); box-shadow:0 3px 7px #2e90fa55; transform:rotate(6deg); }
    .brand-mark-play { position:absolute; left:9px; top:4px; width:0; height:0; border-top:4px solid transparent; border-bottom:4px solid transparent; border-left:6px solid #fff; }
    .brand-copy { display:grid; gap:2px; min-width:0; }
    .brand-copy strong { color:var(--ml-sidebar-title); font-size:16px; font-weight:850; letter-spacing:-.025em; line-height:1.1; }
    .brand-copy small { color:var(--ml-sidebar-muted); font-size:11px; font-weight:600; line-height:1.1; }
    .shell > aside nav { gap:4px; margin-top:18px; }
    .app-nav { display:grid; }
    .app-nav .nav-group-title { display:block; margin:0 10px 5px; color:var(--ml-sidebar-muted); font-size:10.5px; font-weight:800; letter-spacing:.14em; }
    .app-nav .nav-management-title { margin-top:20px; }
    .app-nav .nav-subgroup-title { display:block; margin:15px 10px 4px; color:var(--ml-sidebar-muted); font-size:10.5px; font-weight:750; letter-spacing:.05em; }
    .app-nav .nav-item, .app-nav .nav-group-row { gap:11px; min-width:0; min-height:44px; padding:8px 10px; border:1px solid transparent; border-radius:12px; }
    .app-nav .nav-item span { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .app-nav .nav-icon-tile { display:grid; place-items:center; flex:none; width:28px; height:28px; border-radius:9px; color:#3e8eda; background:#eaf4ff; }
    .app-nav .nav-icon { flex:none; width:16px; height:16px; }
    .app-nav .nav-item-primary .nav-icon-tile, .app-nav .nav-group-row.active .nav-icon-tile { color:#fff; background:linear-gradient(135deg,var(--ml-primary),var(--ml-sky)); box-shadow:0 5px 10px #2e90fa35; }
    .app-nav .nav-category { min-height:40px; padding-left:16px; }
    .app-nav .nav-category-dot { flex:none; width:7px; height:7px; border:2px solid #75aee3; border-radius:999px; }
    .app-nav .nav-category small { flex:none; margin-left:auto; color:#7b8799; font-size:11px; font-variant-numeric:tabular-nums; }
    .app-nav .nav-category.active .nav-category-dot { border-color:var(--ml-sidebar-active); background:var(--ml-sidebar-active); }
    .shell > aside nav a { display:flex; align-items:center; border:1px solid transparent; color:var(--ml-sidebar-ink); font-size:13.5px; font-weight:650; text-decoration:none; touch-action:manipulation; }
    .shell > aside nav a:hover, .shell > aside .nav-group-row:hover { color:#243b5a; background:#eef5fc; }
    .shell > aside nav a:active, .shell > aside .nav-group-row:active { color:var(--ml-sidebar-active); background:#e7f2ff; }
    .shell > aside nav a.active { border-color:#dbeafe; color:var(--ml-sidebar-active); background:linear-gradient(110deg,#eaf4ff,#fff4f8); font-weight:800; }
    .app-nav .nav-disclosure { display:grid; }
    .app-nav .nav-disclosure > summary { display:flex; list-style:none; cursor:pointer; }
    .app-nav .nav-disclosure > summary::-webkit-details-marker { display:none; }
    .app-nav .nav-disclosure > summary .nav-disclosure-count { flex:none; margin-left:auto; color:var(--ml-sidebar-muted); font-size:11px; font-variant-numeric:tabular-nums; }
    .app-nav .nav-chevron, .sidebar-status-chevron { flex:none; width:15px; height:15px; color:var(--ml-sidebar-muted); transition:transform .18s ease; }
    .app-nav .nav-disclosure[open] > summary .nav-chevron { transform:rotate(90deg); }
    .app-nav .nav-subitems { display:grid; gap:2px; margin-left:22px; padding-left:9px; border-left:1px solid #dce8f4; }
    .app-nav .nav-subitems .nav-item { min-height:40px; padding-top:6px; padding-bottom:6px; }
    .app-nav .nav-subitems .nav-icon-tile { width:18px; height:18px; background:transparent; color:#708198; }
    .app-nav .nav-subitems .nav-icon { width:16px; height:16px; }
    .app-nav .nav-item-disabled { color:#9aa6b6; cursor:not-allowed; }
    .app-nav .nav-item-disabled .nav-icon-tile { color:#a9b4c2; background:#f0f3f7; }
    .app-nav .nav-empty { display:block; padding:8px 12px; color:#9aa6b6; font-size:12px; }
    .app-nav .nav-empty-link { color:#6f8198; font-size:12.5px; }
    .sidebar-status-card { display:flex; align-items:center; gap:9px; min-height:58px; margin:12px 4px 0; padding:10px 11px; border:1px solid #e6ebf3; border-radius:14px; color:var(--ml-sidebar-ink); background:var(--ml-sidebar-card); box-shadow:0 8px 20px #243a6208; text-decoration:none; }
    .sidebar-status-card:hover { border-color:#cfe2f6; background:#fff; }
    .sidebar-status-card:active { opacity:.82; }
    .sidebar-status-icon { display:grid; place-items:center; flex:none; width:30px; height:30px; border-radius:9px; color:#fff; background:linear-gradient(135deg,var(--ml-primary),var(--ml-sky)); }
    .sidebar-status-icon svg { width:16px; height:16px; }
    .sidebar-status-copy { display:grid; gap:2px; min-width:0; flex:1; }
    .sidebar-status-copy strong { color:#334155; font-size:12px; font-weight:800; }
    .sidebar-status-copy small { color:#8b96a8; font-size:10.5px; font-weight:600; }
    .shell > aside .phase,.shell > aside .privacy,.shell > aside .boundary,.shell > aside .sidebar-note { margin-top:12px; padding:12px; border:1px solid #e6ebf3; border-radius:14px; color:#68758a; background:#fff; box-shadow:0 8px 20px #243a6208; font-size:12px; line-height:1.55; }
    .shell > main { padding:clamp(28px,4vw,52px); }
    .shell > main .page-heading { display:grid; grid-template-columns:56px minmax(0,1fr); gap:16px; align-items:start; max-width:78ch; margin:0 0 28px; }
    .page-title-icon { display:block; width:56px; height:56px; overflow:visible; }
    .page-title-icon svg { display:block; width:56px; height:56px; overflow:visible; }
    .page-title-copy { min-width:0; }
    .page-title-copy .eyebrow { margin:1px 0 5px; color:#2e78c2; font-size:11px; font-weight:800; letter-spacing:.12em; line-height:1.3; text-transform:uppercase; }
    .page-title-copy h1 { margin:0; color:#1d1d1f; font-size:clamp(30px,4vw,40px); font-weight:900; line-height:1.08; letter-spacing:-.04em; overflow-wrap:anywhere; }
    .page-title-copy .subtitle { max-width:68ch; margin:9px 0 0; color:#6e6e73; font-size:13.5px; font-weight:500; line-height:1.55; }
    .shell > main .filters,.shell > main .queue-toolbar,.shell > main .card,.shell > main .panel,.shell > main .preferences,.shell > main .detail-card { border-color:#edf0f5; background:#fff; box-shadow:0 10px 28px rgba(40,60,100,.08); }
    .shell > main .media-card,.shell > main .summary-card,.shell > main .person-card,.shell > main .credit-card,.shell > main .collection-card,.shell > main .photo-card,.shell > main .queue-item { background:#fff; border-color:#edf0f5; box-shadow:0 10px 28px rgba(40,60,100,.08); }
    .shell > main .filters { border-radius:16px; }
    .shell > main .filters input,.shell > main .filters select { border-color:#dde7f3; background:#eef1f6; }
    .shell > main .filters > button,.shell > main .load-more,.shell > main .create-form > button,.shell > main .toolbar-actions button:not(.secondary):not(.danger) { border-color:#2e90fa; color:#fff; background:linear-gradient(135deg,#2e90fa,#36bffa); }
    .shell > main .filters > button:hover,.shell > main .load-more:hover,.shell > main .create-form > button:hover,.shell > main .toolbar-actions button:not(.secondary):not(.danger):hover { border-color:#1878db; background:linear-gradient(135deg,#1878db,#2eaeeb); }
    .app-mobile-nav { display:none; }
    html.app-shell-navigating::before { content:""; position:fixed; z-index:2000; top:0; left:0; width:28%; height:2px; pointer-events:none; background:linear-gradient(90deg,var(--ml-primary),var(--ml-sky)); box-shadow:0 0 10px #2e90fa80; animation:ml-navigation-progress 1.15s ease-in-out infinite alternate; }
    @keyframes ml-navigation-progress { from { opacity:.45; transform:scaleX(.75); transform-origin:left; } to { opacity:1; transform:scaleX(1.8); transform-origin:left; } }
    .shell > main { min-width:0; background:radial-gradient(circle at 86% -15%,#dff3ff 0,transparent 31%),var(--ml-canvas); }
    @media (max-width:720px) { .shell { display:block; } .shell > aside { min-height:auto; padding:12px 18px; border-right:0; border-bottom:1px solid var(--ml-sidebar-line); } .shell > .app-sidebar { position:static; width:auto; height:auto; overflow:visible; } .app-brand { width:max-content; padding:0; } .app-nav-desktop { display:none!important; } .app-mobile-nav { display:block; margin-top:8px; } .app-mobile-nav summary { display:flex; min-height:44px; align-items:center; padding:9px 12px; border:1px solid #dce5f0; border-radius:12px; color:var(--ml-sidebar-active); background:#fff; cursor:pointer; font-size:14px; font-weight:750; list-style:none; } .app-mobile-nav summary::-webkit-details-marker { display:none; } .app-mobile-nav summary::after { content:'⌄'; margin-left:auto; font-size:18px; transition:transform .18s ease; } .app-mobile-nav[open] summary::after { transform:rotate(180deg); } .shell > aside .app-nav-mobile-links { display:grid; gap:4px; margin-top:8px; padding:8px; border:1px solid #e4ebf4; border-radius:14px; background:#fff; } .app-nav-mobile-links .nav-group-title,.app-nav-mobile-links .nav-subgroup-title { margin-top:6px; } .app-nav-mobile-links .nav-item { min-width:0; min-height:44px; } .app-nav-mobile-links .nav-subitems { margin-left:12px; } .sidebar-status-card { margin:10px 0 0; } .shell > aside .phase,.shell > aside .privacy,.shell > aside .boundary,.shell > aside .sidebar-note { display:none; } .shell > main { padding:24px 18px 36px; } .shell > main .page-heading { grid-template-columns:46px minmax(0,1fr); gap:12px; margin-bottom:22px; } .page-title-icon,.page-title-icon svg { width:46px; height:46px; } .page-title-copy h1 { font-size:30px; } }
    @media (prefers-reduced-motion:reduce) { .app-mobile-nav summary::after { transition:none; } html.app-shell-navigating::before { animation:none; opacity:.8; } }
    """
}
