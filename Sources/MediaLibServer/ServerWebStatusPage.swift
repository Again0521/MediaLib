import Foundation
import MediaLibServerProtocol

/// 面向已认证用户的服务状态页；保留 `/health` 作为机器可读探针，避免把运维探针混作网页。
enum ServerWebStatusPage {
    static func render(serverName: String, csrfToken: String, showAdministration: Bool = false, categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .status, showAdministration: showAdministration, note: .none, categories: categories,
            extras: sidebarExtras, context: .administration
        )
        let content = """
        \(ServerWebPageHeader.render(
            icon: .status,
            eyebrow: "Dashboard",
            title: "仪表盘",
            subtitle: "看看服务器现在运行得怎么样。",
            actions: ServerWebUI.button("刷新", variant: .secondary, icon: .refresh, id: "refresh")
        ))
        <div class="status-grid">
          <section class="ui-card status-runtime" aria-labelledby="runtime-heading">
            <div class="ui-card-head">
              <h2 class="ui-card-title" id="runtime-heading">服务运行监测</h2>
              <span class="ui-status ui-status-idle" id="state-title">正在检查…</span>
            </div>
            <p class="t-footnote t-tertiary">网页端通过同源的只读健康探针确认服务进程状态，不公开网络地址或内部路径。</p>
            <div class="status-probe" id="probe-visual" aria-hidden="true"><span></span><span></span><span></span><span></span><span></span></div>
          </section>

          <section class="ui-card" aria-labelledby="identity-heading">
            <div class="ui-card-head">
              <h2 class="ui-card-title" id="identity-heading">服务器信息</h2>
              <span class="ui-tag">已认证</span>
            </div>
            <dl class="status-meta">
              <dt>服务器名称</dt><dd id="server-name">—</dd>
              <dt>服务器 ID</dt><dd id="server-id">—</dd>
              <dt>协议版本</dt><dd id="protocol-version">—</dd>
            </dl>
          </section>

          <section class="ui-card" aria-labelledby="boundary-heading">
            <div class="ui-card-head">
              <h2 class="ui-card-title" id="boundary-heading">访问边界</h2>
              <span class="ui-tag">受保护</span>
            </div>
            <p class="t-footnote t-tertiary">所有网页请求均受认证、授权、CSRF、限速和同源安全策略保护。</p>
            <div class="ui-spacer"></div>
            <a class="ui-section-more" href="/admin/libraries" data-native-navigation="true">查看媒体库\(ServerWebIcon.chevronRight.html(size: .xs))</a>
          </section>
        </div>

        <section class="ui-section" aria-labelledby="policy-heading">
          \(ServerWebUI.sectionHeader("在网页上能做什么"))
          <div class="status-policy">
            \(policyItem(.library, "浏览和搜索", "你有权限看的内容，都能在这里找到"))
            \(policyItem(.play, "直接播放", "影片和音乐就在这个页面里播"))
            \(policyItem(.settings, "添加和整理", "添加媒体源、整理资料库，回到 Mac 上的 App"))
            \(policyItem(.shield, "隐私", "密码和连接信息不会出现在网页上"))
          </div>
        </section>
        """
        return ServerWebDocument.render(
            title: "仪表盘",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/status.css"],
            pageScripts: ["/assets/overlays.js", "/assets/status.js"],
            tint: .admin
        )
    }

    private static func policyItem(_ icon: ServerWebIcon, _ title: String, _ detail: String) -> String {
        """
        <div class="status-policy-item">
          <span class="status-policy-icon" aria-hidden="true">\(icon.html(size: .sm))</span>
          <div><strong>\(ServerWebHTML.escape(title))</strong><small>\(ServerWebHTML.escape(detail))</small></div>
        </div>
        """
    }

    /// Fixed status-page UI only; live probe results stay in the protected runtime response.
    static let style = #"""
    .status-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: var(--space-5);
    }
    .status-grid .ui-card { min-height: 190px; }
    .status-runtime { grid-column: span 1; }

    /* A quiet activity trace rather than a decorative chart: five bars that read
       as "the probe is running" without implying data the page does not have. */
    .status-probe {
      display: flex;
      align-items: flex-end;
      gap: 5px;
      height: 34px;
      margin-top: auto;
    }
    .status-probe span {
      flex: 1;
      border-radius: var(--radius-pill);
      background: var(--accent-subtle);
    }
    .status-probe span:nth-child(1) { height: 40%; }
    .status-probe span:nth-child(2) { height: 68%; }
    .status-probe span:nth-child(3) { height: 100%; background: var(--accent); }
    .status-probe span:nth-child(4) { height: 56%; }
    .status-probe span:nth-child(5) { height: 78%; }

    .status-meta {
      display: grid;
      grid-template-columns: 92px minmax(0, 1fr);
      gap: var(--space-2) var(--space-4);
      font-size: var(--type-subhead-size);
    }
    .status-meta dt { color: var(--text-tertiary); }
    .status-meta dd {
      margin: 0;
      overflow-wrap: anywhere;
      color: var(--text-primary);
      font-family: var(--font-mono);
      font-size: var(--type-footnote-size);
    }

    .status-policy {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: var(--space-3);
    }
    .status-policy-item {
      display: flex;
      align-items: flex-start;
      gap: var(--space-3);
      padding: var(--space-4);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
    }
    .status-policy-icon {
      display: grid;
      width: 30px;
      height: 30px;
      flex: none;
      place-items: center;
      border-radius: var(--radius-xs);
      color: var(--accent-text);
      background: var(--accent-subtle);
    }
    .status-policy-item strong { display: block; font-size: var(--type-callout-size); font-weight: var(--weight-semibold); }
    .status-policy-item small {
      display: block;
      margin-top: 2px;
      color: var(--text-tertiary);
      font-size: var(--type-footnote-size);
      line-height: 1.5;
    }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const refresh = byID('refresh');
      const state = byID('state-title');
      if (!refresh || !state) return;

      // Status is never carried by colour alone: the class swaps the dot colour,
      // the text says the same thing in words.
      function setState(tone, message) {
        state.className = 'ui-status ui-status-' + tone;
        state.textContent = message;
      }

      async function load() {
        refresh.disabled = true;
        refresh.dataset.busy = 'true';
        setState('idle', '正在检查服务…');
        try {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 10000);
          let response;
          try { response = await fetch('/health', { credentials:'same-origin', headers:{Accept:'application/json'}, signal:controller.signal }); }
          finally { clearTimeout(timer); }
          if (!response.ok) throw new Error('暂时读不到状态');
          const data = await response.json();
          byID('server-name').textContent = typeof data.serverName === 'string' ? data.serverName : '未知';
          byID('server-id').textContent = typeof data.serverID === 'string' ? data.serverID : '未知';
          byID('protocol-version').textContent = typeof data.apiVersion === 'string' ? data.apiVersion : '未知';
          setState('ok', '服务运行正常');
        } catch (_) {
          setState('error', '暂时无法读取服务状态');
          if (window.medialibToast) window.medialibToast('无法读取服务状态，请稍后重试。', { tone: 'error' });
        }
        finally { refresh.disabled = false; delete refresh.dataset.busy; }
      }
      refresh.addEventListener('click', load);
      load();
    })();
    """#
}
