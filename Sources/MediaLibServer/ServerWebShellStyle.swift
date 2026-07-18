import Foundation

/// Shared, cacheable visual shell for the authenticated Web application.
///
/// Feature-specific rules stay beside their markup. This last-loaded sheet owns the
/// desktop application chrome so every page keeps the same sidebar and canvas.
enum ServerWebShellStyle {
    static let css = """
    :root { --ml-primary:#2e90fa; --ml-sky:#36bffa; --ml-canvas:#f6f8fc; --ml-sidebar:#fbfcfe; --ml-sidebar-line:#e9edf4; --ml-sidebar-ink:#516174; --ml-sidebar-active:#0f3d71; }
    html { min-width:320px; background:var(--ml-canvas); }
    body { background:var(--ml-canvas); }
    .shell { grid-template-columns:258px minmax(0,1fr); }
    .shell > aside { padding:26px 16px; color:var(--ml-sidebar-ink); background:var(--ml-sidebar); border-right:1px solid var(--ml-sidebar-line); }
    .shell > .app-sidebar { position:sticky; top:0; align-self:start; width:258px; height:100dvh; overflow-y:auto; }
    .app-brand { display:flex; min-height:44px; gap:10px; align-items:center; color:#172033; font-size:19px; font-weight:850; letter-spacing:-.02em; text-decoration:none; }
    .shell > aside .brand { color:#172033; font-weight:850; letter-spacing:-.02em; }
    .shell > aside .brand-mark { color:#fff; background:linear-gradient(135deg,var(--ml-primary),var(--ml-sky)); box-shadow:0 7px 16px #2e90fa35; }
    .shell > aside nav { gap:5px; margin-top:34px; }
    .app-nav { display:grid; }
    .app-nav .nav-group-title { display:block; margin:0 10px 5px; color:#7b8799; font-size:11px; font-weight:800; letter-spacing:.1em; text-transform:uppercase; }
    .app-nav .nav-management-title { margin-top:24px; }
    .app-nav .nav-subgroup-title { display:block; margin:16px 10px 4px; color:#7b8799; font-size:11px; font-weight:750; }
    .app-nav .nav-item { gap:10px; min-width:0; }
    .app-nav .nav-item span { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .app-nav .nav-icon { flex:none; width:18px; height:18px; }
    .app-nav .nav-category { min-height:40px; padding-left:16px; }
    .app-nav .nav-category-dot { flex:none; width:7px; height:7px; border:2px solid #75aee3; border-radius:999px; }
    .app-nav .nav-category small { flex:none; margin-left:auto; color:#7b8799; font-size:11px; font-variant-numeric:tabular-nums; }
    .app-nav .nav-category.active .nav-category-dot { border-color:var(--ml-sidebar-active); background:var(--ml-sidebar-active); }
    .shell > aside nav a { border:1px solid transparent; color:var(--ml-sidebar-ink); font-size:14px; font-weight:650; }
    .shell > aside nav a:hover { color:#0f172a; background:#f1f5fa; }
    .shell > aside nav a.active { border-color:#dbeafe; color:var(--ml-sidebar-active); background:linear-gradient(110deg,#eaf4ff,#f8fbff); font-weight:800; }
    .shell > aside .phase,.shell > aside .privacy,.shell > aside .boundary,.shell > aside .sidebar-note { margin-top:28px; padding:13px; border:1px solid #e6ebf3; border-radius:14px; border-color:#e6ebf3; color:#68758a; background:#fff; box-shadow:0 8px 20px #243a6208; font-size:12px; line-height:1.55; }
    .app-mobile-nav { display:none; }
    .shell > main { min-width:0; background:radial-gradient(circle at 86% -15%,#dff3ff 0,transparent 31%),var(--ml-canvas); }
    @media (max-width:720px) { .shell { display:block; } .shell > aside { min-height:auto; padding:12px 18px; border-right:0; border-bottom:1px solid var(--ml-sidebar-line); } .shell > .app-sidebar { position:static; width:auto; height:auto; overflow:visible; } .app-brand { width:max-content; } .app-nav-desktop { display:none!important; } .app-mobile-nav { display:block; margin-top:8px; } .app-mobile-nav summary { display:flex; min-height:44px; align-items:center; padding:9px 12px; border:1px solid #dce5f0; border-radius:10px; color:var(--ml-sidebar-active); background:#fff; cursor:pointer; font-size:14px; font-weight:750; list-style:none; } .app-mobile-nav summary::-webkit-details-marker { display:none; } .app-mobile-nav summary::after { content:'⌄'; margin-left:auto; font-size:18px; transition:transform .18s ease; } .app-mobile-nav[open] summary::after { transform:rotate(180deg); } .shell > aside .app-nav-mobile-links { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:6px; margin-top:8px; padding:8px; border:1px solid #e4ebf4; border-radius:12px; background:#fff; } .app-nav-mobile-links .nav-group-title,.app-nav-mobile-links .nav-subgroup-title { grid-column:1/-1; margin-top:6px; } .app-nav-mobile-links .nav-item { min-width:0; min-height:44px; } .shell > aside .phase,.shell > aside .privacy,.shell > aside .boundary,.shell > aside .sidebar-note { display:none; } .shell > main { padding:24px 18px 36px; } }
    @media (prefers-reduced-motion:reduce) { .app-mobile-nav summary::after { transition:none; } }
    """
}
