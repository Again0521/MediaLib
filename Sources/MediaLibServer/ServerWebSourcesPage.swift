import Foundation

/// Web 媒体源只读清单。服务端配置本身仍由桌面端管理，避免把路径和凭据引入浏览器。
enum ServerWebSourcesPage {
    static func render(serverName: String, csrfToken: String) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .sources, showAdministration: true, note: .security
        )
        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>媒体源 · \(escape(serverName))</title>
          <link rel="stylesheet" href="/assets/sources.css">
          <link rel="stylesheet" href="/assets/app-shell.css">
        </head>
        <body>
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">\(sidebar)
          <main id="main" tabindex="-1"><div class="topline"><div><h1>媒体源</h1><p class="subtitle">\(escape(serverName)) 当前已配置的媒体来源。网页端现在仅提供受保护的可见性；添加、编辑、删除与扫描仍须在本机 App 中完成。</p></div><button id="refresh" type="button">刷新数据</button></div><div id="global-status" class="notice" role="status" aria-live="polite">正在加载媒体源…</div><section class="panel" aria-labelledby="sources-title"><div class="panel-head"><div><h2 id="sources-title">已配置来源</h2><p class="panel-copy">需要 server.manage 权限；最多显示 500 项</p></div><span id="sources-count" class="count" aria-label="媒体源数量">—</span></div><p id="sources-state" class="state">正在加载…</p><div id="sources-content" class="content" hidden></div></section><footer>此响应不包含路径、网络地址、账号、密码、令牌、Cookie 或来源连接配置。</footer></main></div>
          <script src="/assets/sources.js" defer></script>
        </body>
        </html>
        """
    }

    /// Fixed media-source management layout. Source metadata remains in the
    /// protected API response and deliberately excludes paths and credentials.
    static let style = """
    :root { --primary:#1e5f9e; --primary-strong:#174d82; --sky:#2e90fa; --ink:#172033; --muted:#5d6b82; --line:#dfe7f1; --canvas:#f4f7fb; --surface:#fff; --danger:#b42318; --focus:#1570ef; }
    * { box-sizing:border-box; } html { background:var(--canvas); } body { margin:0; color:var(--ink); background:var(--canvas); font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; } a { color:inherit; } button,a { touch-action:manipulation; } :focus-visible { outline:3px solid var(--focus); outline-offset:3px; }
    .skip { position:fixed; z-index:1000; top:8px; left:8px; padding:10px 14px; border-radius:9px; color:#fff; background:var(--primary-strong); transform:translateY(-160%); } .skip:focus { transform:none; }
    .shell { display:grid; grid-template-columns:232px minmax(0,1fr); min-height:100dvh; } aside { padding:28px 18px; color:#eef7ff; background:linear-gradient(165deg,#183b68,#1e79cf 58%,#36bffa); } .brand { display:flex; gap:10px; align-items:center; font-size:19px; font-weight:800; } .brand-mark { display:grid; place-items:center; width:36px; height:36px; border-radius:11px; color:#176cb5; background:#fff; box-shadow:0 8px 18px #123c6a55; }
    nav { display:grid; gap:8px; margin-top:38px; } nav a { display:flex; align-items:center; min-height:44px; padding:10px 12px; border-radius:10px; text-decoration:none; } nav a:hover { background:#ffffff1c; } nav a.active { background:#ffffff2e; font-weight:700; } .boundary { margin-top:28px; padding:14px; border:1px solid #ffffff38; border-radius:14px; background:#153e6d55; font-size:13px; }
    main { width:100%; max-width:1220px; padding:clamp(22px,4vw,48px); } .topline { display:flex; gap:20px; align-items:flex-start; justify-content:space-between; } h1 { margin:0; font-size:clamp(28px,4vw,42px); line-height:1.15; letter-spacing:-.035em; } .subtitle { max-width:72ch; margin:10px 0 0; color:var(--muted); } button { min-height:44px; padding:10px 16px; border:1px solid #b9c9dd; border-radius:11px; color:var(--primary-strong); background:var(--surface); font:inherit; font-weight:700; cursor:pointer; } button:hover { border-color:#7ca8d4; background:#f3f8fd; } button:disabled { cursor:not-allowed; opacity:.5; }
    .notice { margin-top:24px; padding:13px 15px; border:1px solid #b8d8f5; border-radius:12px; color:#164f7d; background:#eaf6ff; } .panel { overflow:hidden; margin-top:18px; border:1px solid var(--line); border-radius:16px; background:var(--surface); box-shadow:0 10px 28px #243a620d; } .panel-head { display:flex; gap:16px; align-items:flex-start; justify-content:space-between; padding:18px 20px; border-bottom:1px solid var(--line); } h2 { margin:0; font-size:18px; } .panel-copy { margin:4px 0 0; color:var(--muted); font-size:14px; } .count { flex:none; min-width:36px; padding:4px 9px; border-radius:999px; color:#185f9c; background:#e7f3ff; text-align:center; font-variant-numeric:tabular-nums; font-size:13px; font-weight:800; }
    .state { min-height:76px; padding:22px 20px; color:var(--muted); } .state.error { color:var(--danger); } .state[hidden],.content[hidden] { display:none; } .content { padding:4px 20px 20px; } .rows { display:grid; } .row { display:grid; grid-template-columns:minmax(180px,1.3fr) minmax(130px,.8fr) minmax(170px,1fr) minmax(170px,1fr); gap:16px; align-items:center; min-height:72px; border-bottom:1px solid #edf1f6; } .row:last-child { border-bottom:0; } .primary { min-width:0; font-weight:700; overflow-wrap:anywhere; } .secondary,.meta { color:var(--muted); font-size:14px; overflow-wrap:anywhere; } .pill { display:inline-flex; min-height:28px; align-items:center; padding:3px 9px; border:1px solid #b9d7ef; border-radius:999px; color:#155b92; background:#f0f8ff; font-size:12px; font-weight:700; } footer { margin:28px 0 8px; color:var(--muted); font-size:13px; }
    @media (max-width:880px) { .shell { display:block; } aside { padding:16px 18px; } nav { display:flex; overflow-x:auto; margin-top:14px; } nav a { flex:none; } .boundary { display:none; } main { padding:24px 18px 40px; } .row { grid-template-columns:1fr 1fr; gap:7px 14px; padding:13px 0; } } @media (max-width:560px) { .topline { display:block; } .topline button { width:100%; margin-top:18px; } .panel-head,.content { padding-left:16px; padding-right:16px; } .row { grid-template-columns:1fr; gap:4px; min-height:0; padding:14px 0; } } @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
    """

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const status = byID('global-status');
      const refresh = byID('refresh');
      const formatter = new Intl.DateTimeFormat('zh-CN', { dateStyle: 'medium', timeStyle: 'short' });
      const element = (tag, className, text) => { const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = String(text); return node; };
      const safeDate = (value) => { const date = new Date(value); return Number.isNaN(date.getTime()) ? '时间未知' : formatter.format(date); };
      const state = (message, error = false) => { const notice = byID('sources-state'); const content = byID('sources-content'); notice.textContent = message; notice.classList.toggle('error', error); notice.hidden = false; content.hidden = true; content.replaceChildren(); };
      async function fetchSources() {
        const controller = new AbortController(); const timer = window.setTimeout(() => controller.abort(), 10000);
        try { const response = await fetch('/api/v1/admin/sources', { credentials: 'same-origin', headers: { 'Accept': 'application/json' }, signal: controller.signal }); if (response.status === 401) { window.location.assign('/login'); throw new Error('登录已失效'); } if (response.status === 403) throw new Error('当前账号没有查看媒体源的权限'); if (!response.ok) throw new Error(response.status === 429 ? '请求过于频繁，请稍后刷新' : '服务暂时无法读取媒体源'); return await response.json(); } finally { window.clearTimeout(timer); }
      }
      function render(data) {
        const sources = Array.isArray(data.sources) ? data.sources : []; byID('sources-count').textContent = String(Number.isFinite(data.totalCount) ? data.totalCount : sources.length); if (!sources.length) { state('还没有可显示的媒体源。'); return; }
        const rows = element('div', 'rows'); sources.forEach((source) => { const identity = element('div'); identity.append(element('div', 'primary', source.name || '未命名媒体源')); identity.append(element('div', 'secondary', `${source.sourceKind || 'unknown'} · ${source.mediaType || 'auto'}`)); const automation = element('div', 'meta', source.autoScan ? '自动扫描已开启' : '自动扫描已关闭'); const processing = element('div'); processing.append(element('span', 'pill', source.includeInMetadataFetch ? '参与元数据补全' : '不参与元数据补全')); processing.append(element('div', 'secondary', source.includeInHealthCheck ? '纳入资料库健康检查' : '不纳入健康检查')); const sourceRow = element('div', 'row'); sourceRow.append(identity, automation, processing, element('div', 'meta', `更新于 ${safeDate(source.updatedAt)}`)); rows.append(sourceRow); });
        byID('sources-state').hidden = true; const content = byID('sources-content'); content.replaceChildren(rows); content.hidden = false;
      }
      async function load() { refresh.disabled = true; status.hidden = false; status.textContent = '正在加载媒体源…'; state('正在加载…'); try { render(await fetchSources()); status.textContent = '媒体源数据已更新。'; } catch (error) { state(error && error.message ? error.message : '无法读取媒体源。', true); status.textContent = '加载失败，请稍后重试。'; } finally { refresh.disabled = false; } }
      refresh.addEventListener('click', load); load();
    })();
    """#

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
