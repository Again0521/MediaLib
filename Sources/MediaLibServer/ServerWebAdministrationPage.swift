import Foundation
import MediaLibServerProtocol

/// 只读 Web 管理总览。动态数据全部由同源脚本通过受保护 API 获取，并使用
/// `textContent` 渲染；页面本身不内嵌用户数据、令牌或数据库实体。
enum ServerWebAdministrationPage {
    static func render(serverName: String, csrfToken: String, categories: [ServerLibraryCategory] = []) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .administration, showAdministration: true, note: .security, categories: categories
        )
        let pageHeader = ServerWebPageHeader.render(
            icon: .administration,
            eyebrow: "管理",
            title: "服务管理",
            subtitle: "\(serverName) 的用户、资料库授权、活动设备、会话与安全事件均经逐操作权限检查。"
        )
        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>服务管理 · \(escape(serverName))</title>
          <link rel="stylesheet" href="/assets/admin.css">
          <link rel="stylesheet" href="/assets/app-shell.css?v=68">
          <script src="/assets/app-shell.js?v=68" defer></script>
        </head>
        <body>
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">
            \(sidebar)
            <main id="main" tabindex="-1">
              <div class="topline">\(pageHeader)<button id="refresh" type="button">刷新数据</button></div>
              <div id="global-status" class="notice" role="status" aria-live="polite">正在加载管理数据…</div>
              <section class="panel" aria-labelledby="create-user-title"><div class="panel-head"><div><h2 id="create-user-title">创建成员</h2><p class="panel-copy">仅创建普通成员；资料库访问必须显式勾选，并要求 libraries.manage 权限。</p></div></div><form id="create-member" class="create-form"><div class="form-grid"><label>显示名称<input id="new-display-name" name="displayName" type="text" maxlength="256" autocomplete="name" required></label><label>用户名<input id="new-username" name="username" type="text" maxlength="128" autocomplete="username" required></label></div><label>初始密码<input id="new-password" name="password" type="password" minlength="12" maxlength="1024" autocomplete="new-password" required></label><fieldset><legend>允许播放的资料库</legend><p id="library-selection-state" class="form-note" role="status">正在加载可授权资料库…</p><div id="library-options" class="library-options" hidden></div></fieldset><p class="form-note">新成员默认不具备下载、编辑或管理员权限。密码只用于本次提交，不会显示、保存或写入审计。</p><button id="create-member-submit" type="submit">创建成员</button><p id="create-member-state" class="state" role="status" aria-live="polite"></p></form></section>
              <section id="member-edit-panel" class="panel" aria-labelledby="edit-user-title" hidden><div class="panel-head"><div><h2 id="edit-user-title">编辑成员访问</h2><p class="panel-copy">只可编辑普通成员显示名和资料库访问；保存后该成员的现有会话会失效。</p></div></div><form id="edit-member" class="create-form"><div class="form-grid"><label>显示名称<input id="edit-display-name" name="displayName" type="text" maxlength="256" autocomplete="name" required></label><label>用户名<input id="edit-username" type="text" readonly></label></div><fieldset><legend>允许播放的资料库</legend><p id="edit-library-selection-state" class="form-note">请选择资料库。</p><div id="edit-library-options" class="library-options" hidden></div></fieldset><label>重置密码（可选）<input id="edit-password" name="password" type="password" minlength="12" maxlength="1024" autocomplete="new-password" placeholder="留空则不修改"></label><div class="edit-actions"><button id="edit-member-submit" type="submit">保存访问</button><button id="edit-member-cancel" type="button">取消</button></div><p id="edit-member-state" class="state" role="status" aria-live="polite"></p></form></section>
              <div class="dashboard">
                <section class="panel" aria-labelledby="users-title"><div class="panel-head"><div><h2 id="users-title">用户</h2><p class="panel-copy">需要 users.manage 权限</p></div><span id="users-count" class="count" aria-label="用户数量">—</span></div><p id="users-state" class="state">正在加载…</p><div id="users-content" class="content" hidden></div></section>
                <section class="panel" aria-labelledby="sessions-title"><div class="panel-head"><div><h2 id="sessions-title">活动设备与会话</h2><p class="panel-copy">需要 sessions.manage 权限；不显示 IP、User-Agent 或令牌</p></div><span id="sessions-count" class="count" aria-label="会话数量">—</span></div><p id="sessions-state" class="state">正在加载…</p><div id="sessions-content" class="content" hidden></div></section>
                <section class="panel events" aria-labelledby="events-title"><div class="panel-head"><div><h2 id="events-title">安全事件</h2><p class="panel-copy">需要 server.manage 权限；最多显示最近 100 条</p></div><span id="events-count" class="count" aria-label="安全事件数量">—</span></div><p id="events-state" class="state">正在加载…</p><div id="events-content" class="content" hidden></div></section>
              </div>
              <footer>管理操作受角色、资料库授权、CSRF、限速和审计保护 · 响应不包含密码、Cookie、token、摘要、媒体路径、请求头或客户端地址。</footer>
            </main>
          </div>
          <script src="/assets/admin.js" defer></script>
        </body>
        </html>
        """
    }

    /// Fixed administration UI. User, library, session and audit information must
    /// only come from permission-gated APIs and never from this cacheable asset.
    static let style = """
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
    .state { min-height:76px; padding:22px 20px; color:var(--muted); } .state.error { color:var(--danger); } .state[hidden],.content[hidden],.panel[hidden] { display:none; }
    .content { padding:4px 20px 20px; } .rows { display:grid; } .row { display:grid; grid-template-columns:minmax(150px,1.2fr) minmax(130px,1fr) minmax(160px,1.2fr) minmax(120px,.8fr); gap:16px; align-items:center; min-height:66px; border-bottom:1px solid #edf1f6; } .row:last-child { border-bottom:0; }
    .primary { min-width:0; font-weight:700; overflow-wrap:anywhere; } .secondary,.meta { color:var(--muted); font-size:14px; overflow-wrap:anywhere; } .mono { font-variant-numeric:tabular-nums; font-feature-settings:"tnum"; }
    .pill { display:inline-flex; align-items:center; min-height:28px; padding:3px 9px; border:1px solid #b9d7ef; border-radius:999px; color:#155b92; background:#f0f8ff; font-size:12px; font-weight:700; } .pill.danger { border-color:#f2c0bc; color:var(--danger); background:#fff3f2; }
    .events .row { grid-template-columns:minmax(155px,.9fr) minmax(180px,1.2fr) minmax(100px,.6fr) minmax(190px,1.2fr); }
    .create-form { display:grid; gap:14px; padding:20px; } .form-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:14px; } label { display:grid; gap:6px; color:var(--muted); font-size:14px; font-weight:700; } input { min-height:44px; width:100%; padding:10px 11px; border:1px solid #b9c9dd; border-radius:10px; color:var(--ink); background:#fff; font:inherit; } input[readonly] { color:var(--muted); background:#f6f8fb; } input:focus { border-color:var(--focus); outline:0; box-shadow:0 0 0 3px #1570ef22; } fieldset { margin:0; padding:14px; border:1px solid var(--line); border-radius:12px; } legend { padding:0 5px; color:var(--muted); font-size:14px; font-weight:700; } .library-options { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:8px; } .library-option { display:flex; gap:9px; align-items:flex-start; min-height:44px; padding:8px; border-radius:9px; color:var(--ink); background:#f7faff; font-weight:600; } .library-option input { flex:none; width:18px; min-height:18px; margin:3px 0 0; accent-color:var(--primary); } .form-note { margin:0; color:var(--muted); font-size:13px; } .create-form button { justify-self:start; } .edit-actions { display:flex; flex-wrap:wrap; gap:10px; } .edit-actions button { min-width:120px; } .edit-actions button[type=button] { color:var(--muted); background:#f7f9fc; }
    footer { margin:28px 0 8px; color:var(--muted); font-size:13px; }
    @media (max-width:880px) { .shell { display:block; } aside { padding:16px 18px; } nav { display:flex; overflow-x:auto; margin-top:14px; } nav a { flex:none; } .boundary { display:none; } main { padding:24px 18px 40px; } .row,.events .row { grid-template-columns:1fr 1fr; gap:7px 14px; padding:13px 0; } }
    @media (max-width:560px) { .topline { display:block; } .topline button { width:100%; margin-top:18px; } .panel-head { padding:16px; } .content { padding:2px 16px 16px; } .row,.events .row,.form-grid { grid-template-columns:1fr; gap:4px; min-height:0; padding:14px 0; } .create-form button { width:100%; } }
    @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
    """

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const globalStatus = byID('global-status');
      const refreshButton = byID('refresh');
      const createForm = byID('create-member');
      const createSubmit = byID('create-member-submit');
      const createState = byID('create-member-state');
      const librarySelectionState = byID('library-selection-state');
      const libraryOptions = byID('library-options');
      const editPanel = byID('member-edit-panel');
      const editForm = byID('edit-member');
      const editSubmit = byID('edit-member-submit');
      const editCancel = byID('edit-member-cancel');
      const editState = byID('edit-member-state');
      const editDisplayName = byID('edit-display-name');
      const editUsername = byID('edit-username');
      const editPassword = byID('edit-password');
      const editLibrarySelectionState = byID('edit-library-selection-state');
      const editLibraryOptions = byID('edit-library-options');
      let availableLibraries = [];
      let editingUser = null;
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
      function renderEditLibraryOptions(selectedIDs) {
        const selected = new Set(Array.isArray(selectedIDs) ? selectedIDs : []);
        editLibraryOptions.replaceChildren();
        availableLibraries.forEach((library) => {
          const label = element('label', 'library-option');
          const checkbox = document.createElement('input');
          checkbox.type = 'checkbox';
          checkbox.name = 'editLibraryID';
          checkbox.value = library.id;
          checkbox.checked = selected.has(library.id);
          const text = element('span', '', `${library.name} · ${library.mediaType}`);
          label.append(checkbox, text);
          editLibraryOptions.append(label);
        });
        editLibraryOptions.hidden = !editLibraryOptions.childElementCount;
        editLibrarySelectionState.textContent = availableLibraries.length ? '仅勾选成员可浏览和播放的资料库。' : '当前没有可授权的非保险库资料库。';
      }
      function renderLibraries(data) {
        const libraries = Array.isArray(data.libraries) ? data.libraries.filter((library) =>
          library && typeof library.id === 'string' && library.id.length > 0 && library.id.length <= 512 &&
          typeof library.name === 'string' && typeof library.mediaType === 'string'
        ) : [];
        availableLibraries = libraries.slice(0, 500);
        libraryOptions.replaceChildren();
        if (!availableLibraries.length) {
          librarySelectionState.textContent = '当前没有可授权的非保险库资料库；可创建无资料库访问的成员。';
          libraryOptions.hidden = true;
          renderEditLibraryOptions([]);
          return;
        }
        availableLibraries.forEach((library) => {
          const label = element('label', 'library-option');
          const checkbox = document.createElement('input');
          checkbox.type = 'checkbox';
          checkbox.name = 'libraryID';
          checkbox.value = library.id;
          const text = element('span', '', `${library.name} · ${typeof library.mediaType === 'string' ? library.mediaType : '媒体库'}`);
          label.append(checkbox, text);
          libraryOptions.append(label);
        });
        libraryOptions.hidden = !libraryOptions.childElementCount;
        librarySelectionState.textContent = libraryOptions.childElementCount ? '仅勾选新成员可浏览和播放的资料库。' : '当前没有可授权的非保险库资料库。';
        renderEditLibraryOptions(editingUser ? editingUser.libraryIDs : []);
      }
      function setLibraryLoadFailure(message) {
        availableLibraries = [];
        libraryOptions.hidden = true;
        libraryOptions.replaceChildren();
        librarySelectionState.textContent = message;
        renderEditLibraryOptions([]);
      }
      async function createMember(event) {
        event.preventDefault();
        const username = byID('new-username').value.trim();
        const displayName = byID('new-display-name').value.trim();
        const passwordField = byID('new-password');
        const password = passwordField.value;
        const libraryIDs = Array.from(libraryOptions.querySelectorAll('input[name="libraryID"]:checked'))
          .map((input) => input.value)
          .filter((value) => typeof value === 'string' && value.length > 0 && value.length <= 512)
          .slice(0, 100);
        if (!username || !displayName || password.length < 12) {
          createState.classList.add('error');
          createState.textContent = '请填写显示名称、用户名和至少 12 个字符的初始密码。';
          return;
        }
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { createState.classList.add('error'); createState.textContent = '页面安全令牌不可用，请刷新后重试。'; return; }
        createSubmit.disabled = true;
        createState.classList.remove('error');
        createState.textContent = '正在创建成员…';
        try {
          const response = await fetch('/api/v1/admin/users', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': token },
            body: JSON.stringify({ username, displayName, password, libraryIDs })
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (response.status === 403) throw new Error('当前账号没有创建成员或授予所选资料库的权限。');
          if (!response.ok) throw new Error(response.status === 429 ? '操作过于频繁，请稍后重试。' : '无法创建成员，请检查输入或更换用户名后重试。');
          createForm.reset();
          createState.textContent = '成员已创建。';
          await load();
        } catch (error) {
          createState.classList.add('error');
          createState.textContent = error && error.message ? error.message : '无法创建成员，请稍后重试。';
        } finally {
          passwordField.value = '';
          createSubmit.disabled = false;
        }
      }
      function closeEditUser() {
        editingUser = null;
        editForm.reset();
        editForm.removeAttribute('data-user-id');
        editPanel.hidden = true;
        editState.textContent = '';
        editState.classList.remove('error');
      }
      function openEditUser(user, focusPassword = false) {
        if (!user || typeof user.id !== 'string' || !user.id || user.isBuiltInAdministrator) return;
        editingUser = user;
        editForm.dataset.userID = user.id;
        editDisplayName.value = typeof user.displayName === 'string' ? user.displayName : '';
        editUsername.value = typeof user.username === 'string' ? user.username : '';
        editPassword.value = '';
        renderEditLibraryOptions(user.libraryIDs);
        editState.classList.remove('error');
        editState.textContent = '编辑普通成员访问；保存后其现有会话会失效。';
        editPanel.hidden = false;
        editPanel.scrollIntoView({ behavior: 'smooth', block: 'start' });
        (focusPassword ? editPassword : editDisplayName).focus({ preventScroll: true });
      }
      async function saveMemberEdit(event) {
        event.preventDefault();
        if (!editingUser || typeof editingUser.id !== 'string' || !editingUser.id) return;
        const displayName = editDisplayName.value.trim();
        const password = editPassword.value;
        const libraryIDs = Array.from(editLibraryOptions.querySelectorAll('input[name="editLibraryID"]:checked'))
          .map((input) => input.value)
          .filter((value) => typeof value === 'string' && value.length > 0 && value.length <= 512)
          .slice(0, 100);
        if (!displayName || new TextEncoder().encode(displayName).length > 256) {
          editState.classList.add('error');
          editState.textContent = '显示名称不能为空且不能超过 256 字节。';
          editDisplayName.focus();
          return;
        }
        if (password && password.length < 12) {
          editState.classList.add('error');
          editState.textContent = '新密码至少需要 12 个字符。';
          editPassword.focus();
          return;
        }
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { editState.classList.add('error'); editState.textContent = '页面安全令牌不可用，请刷新后重试。'; return; }
        editSubmit.disabled = true;
        editState.classList.remove('error');
        editState.textContent = '正在保存成员访问…';
        try {
          const encodedID = encodeURIComponent(editingUser.id);
          const accessResponse = await fetch(`/api/v1/admin/users/${encodedID}/access`, {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': token },
            body: JSON.stringify({ displayName, libraryIDs })
          });
          if (accessResponse.status === 401) { window.location.assign('/login'); return; }
          if (accessResponse.status === 403) throw new Error('当前账号没有编辑成员资料库权限。');
          if (!accessResponse.ok) throw new Error(accessResponse.status === 429 ? '操作过于频繁，请稍后重试。' : '无法保存成员访问，请检查输入后重试。');
          if (password) {
            const passwordResponse = await fetch(`/api/v1/admin/users/${encodedID}/password`, {
              method: 'POST', credentials: 'same-origin',
              headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': token },
              body: JSON.stringify({ password })
            });
            if (passwordResponse.status === 401) { window.location.assign('/login'); return; }
            if (passwordResponse.status === 403) throw new Error('当前账号没有重置成员密码权限。');
            if (!passwordResponse.ok) throw new Error(passwordResponse.status === 429 ? '操作过于频繁，请稍后重试。' : '访问已保存，但密码未更新。');
          }
          editPassword.value = '';
          editState.textContent = password ? '成员访问和密码已更新；现有会话已撤销。' : '成员访问已更新；现有会话已撤销。';
          await load();
        } catch (error) {
          editState.classList.add('error');
          editState.textContent = error && error.message ? error.message : '无法保存成员访问，请稍后重试。';
        } finally {
          editPassword.value = '';
          editSubmit.disabled = false;
        }
      }
      function renderUsers(data) {
        const users = Array.isArray(data.users) ? data.users : [];
        byID('users-count').textContent = String(Number.isFinite(data.totalCount) ? data.totalCount : users.length);
        if (editingUser) {
          const refreshed = users.find((user) => user && user.id === editingUser.id);
          if (refreshed) {
            editingUser = refreshed;
            editDisplayName.value = typeof refreshed.displayName === 'string' ? refreshed.displayName : '';
            editUsername.value = typeof refreshed.username === 'string' ? refreshed.username : '';
          } else {
            closeEditUser();
          }
        }
        if (!users.length) { setState('users', '还没有可显示的用户。'); return; }
        const rows = element('div', 'rows');
        users.forEach((user) => {
          const identity = element('div');
          identity.append(element('div', 'primary', user.displayName || user.username || '未命名用户'));
          identity.append(element('div', 'secondary', `@${user.username || 'unknown'}`));
          const role = element('div', 'secondary', Array.isArray(user.roleIDs) ? user.roleIDs.join('、') : '未分配角色');
          const libraryCount = Array.isArray(user.libraryIDs) ? user.libraryIDs.length : (user.libraryGrantCount || 0);
          const access = element('div', 'meta mono', `${libraryCount} 个资料库 · ${user.activeDeviceCount || 0} 台设备`);
          const actions = element('div');
          actions.append(element('span', `pill${user.isDisabled ? ' danger' : ''}`, user.isBuiltInAdministrator ? '内置管理员' : (user.isDisabled ? '已停用' : (user.requiresInitialPassword ? '待设置密码' : '正常'))));
          if (!user.isBuiltInAdministrator) {
            const edit = element('button', 'user-toggle', '编辑访问');
            edit.type = 'button';
            edit.addEventListener('click', () => openEditUser(user));
            actions.append(edit);
            const resetPassword = element('button', 'user-toggle', '重置密码');
            resetPassword.type = 'button';
            resetPassword.addEventListener('click', () => openEditUser(user, true));
            actions.append(resetPassword);
            const toggle = element('button', 'user-toggle', user.isDisabled ? '启用' : '停用');
            toggle.type = 'button';
            toggle.addEventListener('click', () => setUserAvailability(user.id, !user.isDisabled, toggle));
            actions.append(toggle);
          }
          rows.append(row([identity, role, access, actions]));
        });
        showContent('users', rows);
      }
      async function setUserAvailability(id, disabled, button) {
        if (typeof id !== 'string' || !id) return;
        const action = disabled ? '停用' : '启用';
        if (!window.confirm(`${action}此用户${disabled ? '会撤销其所有已登录会话' : ''}。是否继续？`)) return;
        button.disabled = true;
        globalStatus.hidden = false;
        globalStatus.textContent = `正在${action}用户…`;
        try {
          const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
          if (!token) throw new Error('页面安全令牌不可用，请刷新后重试');
          const response = await fetch(`/api/v1/admin/users/${encodeURIComponent(id)}/${disabled ? 'disable' : 'enable'}`, {
            method: 'POST', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (response.status === 403) throw new Error('当前账号没有管理用户的权限');
          if (!response.ok) throw new Error(response.status === 429 ? '操作过于频繁，请稍后重试' : '无法更新用户状态');
          globalStatus.textContent = `用户已${action}。`;
          await load();
        } catch (error) {
          globalStatus.textContent = error && error.message ? error.message : '更新用户状态失败，请稍后重试。';
          button.disabled = false;
        }
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
          const revoke = element('button', 'revoke-session', '撤销');
          revoke.type = 'button';
          revoke.addEventListener('click', () => revokeSession(session.id, revoke));
          const actions = element('div');
          actions.append(element('span', 'pill', `至 ${safeDate(session.refreshExpiresAt)}`), revoke);
          rows.append(row([
            element('div', 'primary', user ? (user.displayName || user.username) : shortID(session.userID)),
            element('div', 'secondary', device ? `${device.name} · ${device.platform}` : shortID(session.deviceID)),
            element('div', 'meta mono', `最近使用 ${safeDate(session.lastUsedAt)}`),
            actions
          ]));
        });
        showContent('sessions', rows);
      }
      async function revokeSession(id, button) {
        if (typeof id !== 'string' || !id || !window.confirm('撤销此会话后，该设备需要重新登录。是否继续？')) return;
        button.disabled = true;
        globalStatus.hidden = false;
        globalStatus.textContent = '正在撤销会话…';
        try {
          const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
          if (!token) throw new Error('页面安全令牌不可用，请刷新后重试');
          const response = await fetch(`/api/v1/admin/sessions/${encodeURIComponent(id)}/revoke`, {
            method: 'POST', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (response.status === 403) throw new Error('当前账号没有撤销会话的权限');
          if (!response.ok) throw new Error(response.status === 429 ? '操作过于频繁，请稍后重试' : '无法撤销该会话');
          globalStatus.textContent = '会话已撤销。';
          await load();
        } catch (error) {
          globalStatus.textContent = error && error.message ? error.message : '撤销会话失败，请稍后重试。';
          button.disabled = false;
        }
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
          fetchJSON('/api/v1/admin/security-events'),
          fetchJSON('/api/v1/admin/libraries')
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
        if (results[3].status === 'fulfilled') renderLibraries(results[3].value);
        else setLibraryLoadFailure('没有读取可授权资料库的权限；仍可创建无资料库访问的成员。');
        globalStatus.textContent = failures ? `已加载，其中 ${failures} 个区域不可用。可检查账号权限后重试。` : '管理数据已更新。';
        refreshButton.disabled = false;
      }
      refreshButton.addEventListener('click', load);
      createForm.addEventListener('submit', createMember);
      editForm.addEventListener('submit', saveMemberEdit);
      editCancel.addEventListener('click', closeEditUser);
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
