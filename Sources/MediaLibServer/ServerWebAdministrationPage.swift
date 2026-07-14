import Foundation

/// 只读 Web 管理总览。动态数据全部由同源脚本通过受保护 API 获取，并使用
/// `textContent` 渲染；页面本身不内嵌用户数据、令牌或数据库实体。
enum ServerWebAdministrationPage {
    static func render(serverName: String, csrfToken: String) -> String {
        """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>服务管理 · \(escape(serverName))</title>
          <style>
            :root { --primary:#1e5f9e; --primary-strong:#174d82; --sky:#2e90fa; --ink:#172033; --muted:#5d6b82; --line:#dfe7f1; --canvas:#f4f7fb; --surface:#fff; --success:#087a55; --danger:#b42318; --focus:#1570ef; }
            * { box-sizing:border-box; } html { background:var(--canvas); } body { margin:0; color:var(--ink); background:var(--canvas); font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
            a { color:inherit; } button,a { touch-action:manipulation; } :focus-visible { outline:3px solid var(--focus); outline-offset:3px; }
            .skip { position:fixed; z-index:1000; top:8px; left:8px; padding:10px 14px; border-radius:9px; color:#fff; background:var(--primary-strong); transform:translateY(-160%); } .skip:focus { transform:none; }
            .shell { display:grid; grid-template-columns:232px minmax(0,1fr); min-height:100dvh; }
            aside { padding:28px 18px; color:#eef7ff; background:linear-gradient(165deg,#183b68,#1e79cf 58%,#36bffa); }
            .brand { display:flex; gap:10px; align-items:center; font-size:19px; font-weight:800; } .brand-mark { display:grid; place-items:center; width:36px; height:36px; border-radius:11px; color:#176cb5; background:#fff; box-shadow:0 8px 18px #123c6a55; }
            nav { display:grid; gap:8px; margin-top:38px; } nav a { display:flex; align-items:center; min-height:44px; padding:10px 12px; border-radius:10px; text-decoration:none; } nav a:hover { background:#ffffff1c; } nav a.active { background:#ffffff2e; font-weight:700; }
            .boundary { margin-top:28px; padding:14px; border:1px solid #ffffff38; border-radius:14px; background:#153e6d55; font-size:13px; }
            main { width:100%; max-width:1440px; padding:clamp(22px,4vw,48px); }
            .topline { display:flex; gap:20px; align-items:flex-start; justify-content:space-between; } h1 { margin:0; font-size:clamp(28px,4vw,42px); line-height:1.15; letter-spacing:-.035em; } .subtitle { max-width:70ch; margin:10px 0 0; color:var(--muted); }
            button { min-height:44px; padding:10px 16px; border:1px solid #b9c9dd; border-radius:11px; color:var(--primary-strong); background:var(--surface); font:inherit; font-weight:700; cursor:pointer; transition:background-color .18s ease,border-color .18s ease; } button:hover { border-color:#7ca8d4; background:#f3f8fd; } button:disabled { cursor:not-allowed; opacity:.5; }
            .notice { margin-top:24px; padding:13px 15px; border:1px solid #b8d8f5; border-radius:12px; color:#164f7d; background:#eaf6ff; }
            .dashboard { display:grid; gap:18px; margin-top:24px; } .panel { overflow:hidden; border:1px solid var(--line); border-radius:16px; background:var(--surface); box-shadow:0 10px 28px #243a620d; }
            .panel-head { display:flex; gap:16px; align-items:flex-start; justify-content:space-between; padding:18px 20px; border-bottom:1px solid var(--line); } .panel h2 { margin:0; font-size:18px; } .panel-copy { margin:4px 0 0; color:var(--muted); font-size:14px; }
            .count { flex:none; min-width:36px; padding:4px 9px; border-radius:999px; color:#185f9c; background:#e7f3ff; text-align:center; font-variant-numeric:tabular-nums; font-size:13px; font-weight:800; }
            .state { min-height:76px; padding:22px 20px; color:var(--muted); } .state.error { color:var(--danger); } .state[hidden],.content[hidden] { display:none; }
            .content { padding:4px 20px 20px; } .rows { display:grid; } .row { display:grid; grid-template-columns:minmax(150px,1.2fr) minmax(130px,1fr) minmax(160px,1.2fr) minmax(120px,.8fr); gap:16px; align-items:center; min-height:66px; border-bottom:1px solid #edf1f6; } .row:last-child { border-bottom:0; }
            .primary { min-width:0; font-weight:700; overflow-wrap:anywhere; } .secondary,.meta { color:var(--muted); font-size:14px; overflow-wrap:anywhere; } .mono { font-variant-numeric:tabular-nums; font-feature-settings:"tnum"; }
            .pill { display:inline-flex; align-items:center; min-height:28px; padding:3px 9px; border:1px solid #b9d7ef; border-radius:999px; color:#155b92; background:#f0f8ff; font-size:12px; font-weight:700; } .pill.danger { border-color:#f2c0bc; color:var(--danger); background:#fff3f2; }
            .events .row { grid-template-columns:minmax(155px,.9fr) minmax(180px,1.2fr) minmax(100px,.6fr) minmax(190px,1.2fr); }
            footer { margin:28px 0 8px; color:var(--muted); font-size:13px; }
            @media (max-width:880px) { .shell { display:block; } aside { padding:16px 18px; } nav { display:flex; overflow-x:auto; margin-top:14px; } nav a { flex:none; } .boundary { display:none; } main { padding:24px 18px 40px; } .row,.events .row { grid-template-columns:1fr 1fr; gap:7px 14px; padding:13px 0; } }
            @media (max-width:560px) { .topline { display:block; } .topline button { width:100%; margin-top:18px; } .panel-head { padding:16px; } .content { padding:2px 16px 16px; } .row,.events .row { grid-template-columns:1fr; gap:4px; min-height:0; padding:14px 0; } }
            @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
          </style>
        </head>
        <body>
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">
            <aside>
              <div class="brand"><span class="brand-mark" aria-hidden="true">M</span><span>MediaLIB</span></div>
              <nav aria-label="主导航"><a href="/">资料库首页</a><a class="active" aria-current="page" href="/admin">服务管理</a><a href="/health">服务健康</a></nav>
              <div class="boundary"><strong>安全边界</strong><br>此页只显示受权限保护的脱敏数据。管理员恢复仍仅能在本机 App 中完成。</div>
            </aside>
            <main id="main" tabindex="-1">
              <div class="topline"><div><h1>服务管理</h1><p class="subtitle">\(escape(serverName)) 的用户、活动设备、登录会话与安全事件。当前为只读总览，所有数据均经逐操作权限检查。</p></div><button id="refresh" type="button">刷新数据</button></div>
              <div id="global-status" class="notice" role="status" aria-live="polite">正在加载管理数据…</div>
              <div class="dashboard">
                <section class="panel" aria-labelledby="users-title"><div class="panel-head"><div><h2 id="users-title">用户</h2><p class="panel-copy">需要 users.manage 权限</p></div><span id="users-count" class="count" aria-label="用户数量">—</span></div><p id="users-state" class="state">正在加载…</p><div id="users-content" class="content" hidden></div></section>
                <section class="panel" aria-labelledby="sessions-title"><div class="panel-head"><div><h2 id="sessions-title">活动设备与会话</h2><p class="panel-copy">需要 sessions.manage 权限；不显示 IP、User-Agent 或令牌</p></div><span id="sessions-count" class="count" aria-label="会话数量">—</span></div><p id="sessions-state" class="state">正在加载…</p><div id="sessions-content" class="content" hidden></div></section>
                <section class="panel events" aria-labelledby="events-title"><div class="panel-head"><div><h2 id="events-title">安全事件</h2><p class="panel-copy">需要 server.manage 权限；最多显示最近 100 条</p></div><span id="events-count" class="count" aria-label="安全事件数量">—</span></div><p id="events-state" class="state">正在加载…</p><div id="events-content" class="content" hidden></div></section>
              </div>
              <footer>只读管理预览 · 响应不包含密码、Cookie、token、摘要、媒体路径、请求头或客户端地址。</footer>
            </main>
          </div>
          <script src="/assets/admin.js" defer></script>
        </body>
        </html>
        """
    }

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const globalStatus = byID('global-status');
      const refreshButton = byID('refresh');
      const dateFormatter = new Intl.DateTimeFormat('zh-CN', { dateStyle: 'medium', timeStyle: 'short' });
      const safeDate = (value) => {
        const date = new Date(value);
        return Number.isNaN(date.getTime()) ? '时间未知' : dateFormatter.format(date);
      };
      const shortID = (value) => typeof value === 'string' && value.length > 12 ? `${value.slice(0, 8)}…` : (value || '—');
      const element = (tag, className, text) => {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = String(text);
        return node;
      };
      const setState = (section, message, isError = false) => {
        const state = byID(`${section}-state`);
        const content = byID(`${section}-content`);
        state.textContent = message;
        state.classList.toggle('error', isError);
        state.hidden = false;
        content.hidden = true;
        content.replaceChildren();
      };
      const showContent = (section, node) => {
        const state = byID(`${section}-state`);
        const content = byID(`${section}-content`);
        state.hidden = true;
        content.replaceChildren(node);
        content.hidden = false;
      };
      const row = (values, className = '') => {
        const node = element('div', `row ${className}`.trim());
        values.forEach((value) => node.append(value));
        return node;
      };
      async function fetchJSON(path) {
        const controller = new AbortController();
        const timer = window.setTimeout(() => controller.abort(), 10000);
        try {
          const response = await fetch(path, {
            credentials: 'same-origin',
            headers: { 'Accept': 'application/json' },
            signal: controller.signal
          });
          if (response.status === 401) {
            window.location.assign('/login');
            throw new Error('登录已失效');
          }
          if (response.status === 403) throw new Error('当前账号没有查看此区域的权限');
          if (!response.ok) throw new Error(response.status === 429 ? '请求过于频繁，请稍后刷新' : '服务暂时无法读取此区域');
          return await response.json();
        } finally {
          window.clearTimeout(timer);
        }
      }
      function renderUsers(data) {
        const users = Array.isArray(data.users) ? data.users : [];
        byID('users-count').textContent = String(Number.isFinite(data.totalCount) ? data.totalCount : users.length);
        if (!users.length) { setState('users', '还没有可显示的用户。'); return; }
        const rows = element('div', 'rows');
        users.forEach((user) => {
          const identity = element('div');
          identity.append(element('div', 'primary', user.displayName || user.username || '未命名用户'));
          identity.append(element('div', 'secondary', `@${user.username || 'unknown'}`));
          const role = element('div', 'secondary', Array.isArray(user.roleIDs) ? user.roleIDs.join('、') : '未分配角色');
          const access = element('div', 'meta mono', `${user.libraryGrantCount || 0} 个资料库 · ${user.activeDeviceCount || 0} 台设备`);
          const state = element('span', `pill${user.isDisabled ? ' danger' : ''}`, user.isDisabled ? '已停用' : (user.requiresInitialPassword ? '待设置密码' : '正常'));
          rows.append(row([identity, role, access, state]));
        });
        showContent('users', rows);
      }
      function renderSessions(data, usersByID) {
        const devices = Array.isArray(data.devices) ? data.devices : [];
        const sessions = Array.isArray(data.sessions) ? data.sessions : [];
        byID('sessions-count').textContent = String(sessions.length);
        if (!devices.length && !sessions.length) { setState('sessions', '当前没有活动设备或登录会话。'); return; }
        const deviceByID = new Map(devices.map((device) => [device.id, device]));
        const rows = element('div', 'rows');
        sessions.forEach((session) => {
          const user = usersByID.get(session.userID);
          const device = deviceByID.get(session.deviceID);
          rows.append(row([
            element('div', 'primary', user ? (user.displayName || user.username) : shortID(session.userID)),
            element('div', 'secondary', device ? `${device.name} · ${device.platform}` : shortID(session.deviceID)),
            element('div', 'meta mono', `最近使用 ${safeDate(session.lastUsedAt)}`),
            element('span', 'pill', `至 ${safeDate(session.refreshExpiresAt)}`)
          ]));
        });
        showContent('sessions', rows);
      }
      function renderEvents(data) {
        const events = Array.isArray(data.events) ? data.events : [];
        byID('events-count').textContent = String(events.length);
        if (!events.length) { setState('events', '当前没有安全事件。'); return; }
        const rows = element('div', 'rows');
        events.forEach((event) => {
          const outcome = event.outcome === 'success' ? '成功' : (event.outcome === 'denied' ? '已拒绝' : '失败');
          rows.append(row([
            element('div', 'meta mono', safeDate(event.occurredAt)),
            element('div', 'primary', event.action || 'unknown'),
            element('span', `pill${event.outcome === 'success' ? '' : ' danger'}`, outcome),
            element('div', 'secondary', `${event.category || 'unknown'} · ${event.detailCode || '无详情代码'}`)
          ]));
        });
        showContent('events', rows);
      }
      async function load() {
        refreshButton.disabled = true;
        globalStatus.hidden = false;
        globalStatus.textContent = '正在加载管理数据…';
        ['users', 'sessions', 'events'].forEach((name) => setState(name, '正在加载…'));
        const results = await Promise.allSettled([
          fetchJSON('/api/v1/admin/users'),
          fetchJSON('/api/v1/admin/sessions'),
          fetchJSON('/api/v1/admin/security-events')
        ]);
        let failures = 0;
        let usersByID = new Map();
        if (results[0].status === 'fulfilled') {
          renderUsers(results[0].value);
          usersByID = new Map((results[0].value.users || []).map((user) => [user.id, user]));
        } else { failures += 1; setState('users', results[0].reason.message || '无法读取用户。', true); }
        if (results[1].status === 'fulfilled') renderSessions(results[1].value, usersByID);
        else { failures += 1; setState('sessions', results[1].reason.message || '无法读取会话。', true); }
        if (results[2].status === 'fulfilled') renderEvents(results[2].value);
        else { failures += 1; setState('events', results[2].reason.message || '无法读取安全事件。', true); }
        globalStatus.textContent = failures ? `已加载，其中 ${failures} 个区域不可用。可检查账号权限后重试。` : '管理数据已更新。';
        refreshButton.disabled = false;
      }
      refreshButton.addEventListener('click', load);
      load().catch(() => {
        globalStatus.textContent = '加载失败，请稍后重试。';
        refreshButton.disabled = false;
      });
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
