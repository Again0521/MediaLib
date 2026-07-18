import Foundation

/// 面向已认证用户的服务状态页；保留 `/health` 作为机器可读探针，避免把运维探针混作网页。
enum ServerWebStatusPage {
    static func render(serverName: String, csrfToken: String, showAdministration: Bool = false) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .status, showAdministration: showAdministration, note: .none
        )
        return """
        <!doctype html>
        <html lang="zh-Hans"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><meta name="medialib-csrf-token" content="\(escape(csrfToken))"><title>服务状态 · \(escape(serverName))</title>
        <link rel="stylesheet" href="/assets/status.css"><link rel="stylesheet" href="/assets/app-shell.css"></head>
        <body><a class="skip" href="#main">跳到主要内容</a><div class="shell">\(sidebar)<main id="main" tabindex="-1"><h1>服务状态</h1><p class="subtitle">\(escape(serverName)) 的受认证状态视图。机器探针仍使用独立的 <code>/health</code>，本页不暴露路径、配置或凭据。</p><section class="card" aria-labelledby="state-title"><div class="state"><span class="dot" aria-hidden="true"></span><span id="state-title">正在检查服务…</span></div><dl class="meta"><dt>服务器名称</dt><dd id="server-name">—</dd><dt>服务器 ID</dt><dd id="server-id">—</dd><dt>协议版本</dt><dd id="protocol-version">—</dd></dl><button id="refresh" type="button">刷新状态</button></section></main></div><script src="/assets/status.js" defer></script></body></html>
        """
    }

    /// Fixed status-page UI only; live probe results stay in the protected runtime response.
    static let style = """
    :root{--ink:#172033;--muted:#5d6b82;--line:#dfe7f1;--canvas:#f4f7fb;--card:#fff;--focus:#1570ef}*{box-sizing:border-box}body{margin:0;color:var(--ink);background:var(--canvas);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:inherit}:focus-visible{outline:3px solid var(--focus);outline-offset:3px}.skip{position:fixed;top:8px;left:8px;padding:10px;color:#fff;background:#174d82;transform:translateY(-160%)}.skip:focus{transform:none}.shell{display:grid;grid-template-columns:232px minmax(0,1fr);min-height:100dvh}aside{padding:28px 18px;color:#eef7ff;background:linear-gradient(165deg,#183b68,#1e79cf 58%,#36bffa)}.brand{display:flex;gap:10px;align-items:center;font-size:19px;font-weight:800}.brand-mark{display:grid;place-items:center;width:34px;height:34px;border-radius:10px;color:#176cb5;background:#fff}nav{display:grid;gap:8px;margin-top:38px}nav a{display:flex;align-items:center;min-height:44px;padding:10px 12px;border-radius:10px;text-decoration:none}nav a:hover,nav a.active{background:#ffffff2c}main{max-width:920px;padding:clamp(22px,4vw,48px)}h1{margin:0;font-size:clamp(30px,5vw,48px);letter-spacing:-.04em}.subtitle{color:var(--muted)}.card{margin-top:26px;padding:22px;border:1px solid var(--line);border-radius:18px;background:var(--card);box-shadow:0 10px 28px #243a6210}.state{display:flex;gap:10px;align-items:center;font-weight:800}.dot{width:12px;height:12px;border-radius:50%;background:#087a55}.meta{display:grid;grid-template-columns:150px 1fr;gap:12px;margin-top:20px}.meta dt{color:var(--muted)}.meta dd{margin:0;overflow-wrap:anywhere}button{min-height:44px;margin-top:22px;padding:10px 16px;border:1px solid #b9c9dd;border-radius:11px;color:#174d82;background:#fff;font:inherit;font-weight:700;cursor:pointer}button:disabled{opacity:.5}@media(max-width:720px){.shell{display:block}aside{padding:16px 18px}nav{display:flex;overflow:auto;margin-top:14px}nav a{flex:none}main{padding:24px 18px}.meta{grid-template-columns:1fr;gap:3px}}@media(prefers-reduced-motion:reduce){*{transition-duration:.01ms!important}}
    """

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const refresh = byID('refresh');
      const state = byID('state-title');
      async function load() {
        refresh.disabled = true;
        state.textContent = '正在检查服务…';
        try {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 10000);
          let response;
          try { response = await fetch('/health', { credentials:'same-origin', headers:{Accept:'application/json'}, signal:controller.signal }); }
          finally { clearTimeout(timer); }
          if (!response.ok) throw new Error('服务探针不可用');
          const data = await response.json();
          byID('server-name').textContent = typeof data.serverName === 'string' ? data.serverName : '未知';
          byID('server-id').textContent = typeof data.serverID === 'string' ? data.serverID : '未知';
          byID('protocol-version').textContent = typeof data.apiVersion === 'string' ? data.apiVersion : '未知';
          state.textContent = '服务运行正常';
        } catch (_) { state.textContent = '暂时无法读取服务状态'; }
        finally { refresh.disabled = false; }
      }
      refresh.addEventListener('click', load);
      load();
    })();
    """#

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
