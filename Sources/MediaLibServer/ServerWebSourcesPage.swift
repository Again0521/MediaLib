import Foundation
import MediaLibServerProtocol

/// Web 媒体源只读清单。服务端配置本身仍由桌面端管理，避免把路径和凭据引入浏览器。
enum ServerWebSourcesPage {
    static func render(serverName: String, csrfToken: String, categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .sources, showAdministration: true, note: .security, categories: categories,
            extras: sidebarExtras, context: .administration
        )
        let content = """
        \(ServerWebPageHeader.render(
            icon: .sources,
            eyebrow: "Sources",
            title: "媒体库与来源",
            subtitle: "看看每个来源的情况，随时重新扫描。",
            actions: ServerWebUI.button("添加媒体源…", variant: .secondary, icon: .add, disabled: true, attributes: #" title="媒体源由本机 App 管理""#)
                + ServerWebUI.button("刷新来源", variant: .primary, icon: .refresh, id: "refresh")
        ))
        \(ServerWebUI.alert(.info, message: "正在加载媒体源…", id: "global-status", messageID: "global-status-text", role: "status"))
        <section class="ui-card sources-panel" aria-labelledby="sources-title">
          <div class="ui-card-head">
            <h2 class="ui-card-title" id="sources-title">已连接媒体源</h2>
            <span id="sources-count" class="ui-badge ui-badge-neutral" aria-label="媒体源数量">—</span>
          </div>
          <div class="sources-list-tools">
            \(ServerWebUI.searchField(
                id: "sources-search",
                label: "筛选媒体源",
                placeholder: "搜索名称、类型或稳定标识",
                action: "/admin/libraries",
                formID: "sources-search-form"
            ))
          </div>
          <p id="sources-state" class="ui-state-line sources-state t-callout t-tertiary">正在加载…</p>
          <div id="sources-content" class="sources-content" hidden></div>
          <div class="sources-list-footer">
            \(ServerWebUI.button(
                "载入更多媒体源",
                variant: .ghost,
                size: .small,
                icon: .chevronDown,
                id: "sources-load-more",
                attributes: " hidden"
            ))
          </div>
        </section>
        <p class="t-footnote t-tertiary sources-footnote">媒体源的路径、网络地址、账号、密码、令牌、Cookie 与连接配置不会发送到网页。</p>
        """
        return ServerWebDocument.render(
            title: "媒体库与来源",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/sources.css"],
            pageScripts: ["/assets/overlays.js", "/assets/sources.js"],
            tint: .admin
        )
    }

    /// Fixed media-source management layout. Source metadata remains in the
    /// protected API response and deliberately excludes paths and credentials.
    static let style = #"""
    /* 提示条走公共的 `.ui-alert`（见管理页同一条注释）。 */
    #global-status { margin-bottom: var(--space-5); }
    .sources-panel { padding: 0; }
    .sources-panel .ui-card-head { padding: var(--space-4) var(--space-5); border-bottom: var(--hairline) solid var(--divider); }
    .sources-list-tools { padding: var(--space-4) var(--space-5) 0; }
    .sources-list-tools .app-page-search { width: min(100%, 420px); }
    .sources-list-footer { display: flex; justify-content: center; padding: var(--space-3) var(--space-5) var(--space-4); }
    .sources-state { padding: var(--space-6) var(--space-5); }
    .sources-state[hidden], .sources-content[hidden] { display: none; }
    .sources-content { padding: 0 var(--space-5) var(--space-2); }

    .rows { display: grid; }
    /* Icon, identity, trailing actions — the three things a row actually
       renders.  The grid used to declare four fractional columns for those
       three children, so the 34px icon sat alone in a ~320px track, the name and
       policy were squeezed into 198px and wrapped mid-phrase, and the actions
       landed in the middle of the row with a third of the width dead beside
       them. */
    .row {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr) auto;
      align-items: center;
      gap: var(--space-4);
      min-height: 68px;
      padding: var(--space-3) 0;
      border-bottom: var(--hairline) solid var(--divider);
      transition: background-color var(--duration-fast) var(--ease-out);
    }
    .row:last-child { border-bottom: 0; }
    .row:hover { background: var(--surface-hover); }
    .source-main { min-width: 0; }
    .source-title { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2); }
    .source-title .primary {
      font-size: var(--type-callout-size);
      font-weight: var(--weight-semibold);
      overflow-wrap: anywhere;
    }
    .source-kind { color: var(--tint-glyph, var(--accent-text)); background: var(--tint-fill-b, var(--accent-subtle)); }
    .row .secondary, .row .meta, .row small {
      color: var(--text-tertiary);
      font-size: var(--type-footnote-size);
      overflow-wrap: anywhere;
    }
    .source-icon {
      display: grid;
      width: 34px;
      height: 34px;
      flex: none;
      place-items: center;
      border-radius: var(--radius-xs);
      color: var(--accent-text);
      background: var(--accent-subtle);
    }
    .source-actions-row { display: flex; align-items: center; gap: var(--space-3); color: var(--text-tertiary); }
    .sources-footnote { padding-top: var(--space-5); }

    /* Narrow: the actions drop below the identity rather than competing with it
       for the same line. */
    @media (max-width: 559px) {
      .row { grid-template-columns: auto minmax(0, 1fr); gap: var(--space-2) var(--space-3); }
      .source-actions-row { grid-column: 1 / -1; justify-content: flex-end; }
    }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const status = byID('global-status');
      // 文案写进内层节点：往外层写会把提示图标一起抹掉。
      const statusText = byID('global-status-text');
      const refresh = byID('refresh');
      const searchForm = byID('sources-search-form');
      const search = byID('sources-search');
      const loadMore = byID('sources-load-more');
      let loadedSources = [];
      let loadedTotal = 0;
      let loading = false;
      let revision = 0;
      const formatter = new Intl.DateTimeFormat('zh-CN', { dateStyle: 'medium', timeStyle: 'short' });
      // 图标由 Swift 从 `ServerWebIcon` 插值下来。此前这里的四条路径是手写的
      // 第二套：`settings` 画的是一枚八芒星式的简化齿轮，和页面上那枚十二瓣的
      // `ServerWebIcon.settings` 并排出现在同一屏里。
      \#(ServerWebIcon.scriptHelper(for: [.source]))
      const glyph = (name, className) => medialibIcon(name, className || 'icon icon-sm');
      const element = (tag, className, text) => { const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = String(text); return node; };
      const safeDate = (value) => { const date = new Date(value); return Number.isNaN(date.getTime()) ? '时间未知' : formatter.format(date); };
      const state = (message, error = false) => { const notice = byID('sources-state'); const content = byID('sources-content'); notice.textContent = message; notice.classList.toggle('error', error); notice.hidden = false; content.hidden = true; content.replaceChildren(); };
      async function fetchSources(offset) {
        const controller = new AbortController(); const timer = window.setTimeout(() => controller.abort(), 10000);
        const parameters = new URLSearchParams({offset:String(offset),limit:'50'});
        const query = search?.value.trim().slice(0, 128) || '';
        if (query) parameters.set('q', query);
        try { const response = await fetch(`/api/v1/admin/sources?${parameters}`, { credentials: 'same-origin', headers: { 'Accept': 'application/json' }, signal: controller.signal }); if (response.status === 401) { window.location.assign('/login'); throw new Error('登录已失效'); } if (response.status === 403) throw new Error('你没有查看媒体源的权限。'); if (!response.ok) throw new Error(response.status === 429 ? '请求过于频繁，请稍后刷新' : '服务暂时无法读取媒体源'); return await response.json(); } finally { window.clearTimeout(timer); }
      }
      function render(data, append) {
        const sources = Array.isArray(data.sources) ? data.sources : [];
        if (!append) loadedSources = [];
        const knownIDs = new Set(loadedSources.map(source => source.id));
        sources.forEach(source => { if (source && typeof source.id === 'string' && !knownIDs.has(source.id)) loadedSources.push(source); });
        loadedTotal = Math.max(loadedSources.length, Number(data.totalCount) || 0);
        byID('sources-count').textContent = String(loadedTotal);
        loadMore.hidden = !data.isTruncated || loadedSources.length >= loadedTotal;
        loadMore.disabled = false;
        if (!loadedSources.length) { state(search?.value.trim() ? '没有匹配的媒体源。' : '还没有可显示的媒体源。'); return; }
        const rows = element('div', 'rows'); loadedSources.forEach((source) => { const title = element('div', 'source-title'); title.append(element('span', 'primary', source.name || '未命名媒体源')); title.append(element('span', 'ui-badge ui-badge-neutral', '可访问')); title.append(element('span', 'ui-badge ui-badge-neutral source-kind', source.sourceKind || 'unknown')); const identity = element('div', 'source-main'); identity.append(title); const policy = [source.autoScan ? '自动扫描' : '手动扫描', source.includeInMetadataFetch ? '自动补充信息' : '不自动补充信息', source.includeInHealthCheck ? '纳入健康检查' : '不纳入健康检查'].join(' · '); identity.append(element('div', 'secondary', policy)); const actions = element('div', 'source-actions-row', `更新于 ${safeDate(source.updatedAt)}`); const sourceRow = element('div', 'row'); const sourceIcon = element('span', 'source-icon'); sourceIcon.append(glyph('source', 'icon icon-md')); sourceRow.append(sourceIcon, identity, actions); rows.append(sourceRow); });
        byID('sources-state').hidden = true; const content = byID('sources-content'); content.replaceChildren(rows); content.hidden = false;
      }
      async function load(reset = true) {
        if (loading) return;
        loading = true;
        const currentRevision = reset ? ++revision : revision;
        refresh.disabled = true;
        if (reset) { status.hidden = false; statusText.textContent = '正在加载媒体源…'; state(search?.value.trim() ? '正在筛选媒体源…' : '正在加载…'); loadMore.hidden = true; }
        else { loadMore.disabled = true; loadMore.dataset.busy = 'true'; }
        try { const data = await fetchSources(reset ? 0 : loadedSources.length); if (currentRevision !== revision) return; render(data, !reset); statusText.textContent = '媒体源数据已更新。'; }
        catch (error) { if (currentRevision !== revision) return; if (reset) state(error && error.message ? error.message : '无法读取媒体源。', true); else loadMore.hidden = false; statusText.textContent = '加载失败，请稍后重试。'; }
        finally { loading = false; refresh.disabled = false; loadMore.disabled = false; delete loadMore.dataset.busy; }
      }
      refresh.addEventListener('click', () => load(true));
      loadMore.addEventListener('click', () => load(false));
      searchForm.addEventListener('submit', event => { event.preventDefault(); load(true); });
      load(true);
    })();
    """#

    /// Delegates to the shared implementation in `ServerWebHTML`.
    ///
    /// Every page used to carry a private copy of this function — eighteen of
    /// them — which meant eighteen places to audit and eighteen chances for one
    /// to drift.  The local name is kept so the hundreds of call sites in this
    /// file stay readable.
    private static func escape(_ value: String) -> String { ServerWebHTML.escape(value) }
}
