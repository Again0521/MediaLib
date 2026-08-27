import Foundation
import MediaLibServerProtocol

/// 只读 Web 管理总览。动态数据全部由同源脚本通过受保护 API 获取，并使用
/// `textContent` 渲染；页面本身不内嵌用户数据、令牌或数据库实体。
enum ServerWebAdministrationPage {
    static func render(
        serverName: String,
        csrfToken: String,
        active: ServerWebNavigation.Active = .administration,
        categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras
    ) -> String {
        let sidebar = ServerWebNavigation.render(
            active: active, showAdministration: true, note: .security, categories: categories,
            extras: sidebarExtras, context: .administration
        )
        let content = """
        \(ServerWebPageHeader.render(
            icon: .administration,
            eyebrow: "Administration",
            title: "服务管理",
            subtitle: "管理谁能使用 \(serverName)，以及他们能看到什么。",
            actions: ServerWebUI.button("刷新数据", variant: .secondary, icon: .refresh, id: "refresh")
        ))
        \(ServerWebUI.alert(.info, message: "正在加载管理数据…", id: "global-status", messageID: "global-status-text", role: "status"))

        <section class="ui-card admin-panel" aria-labelledby="create-user-title">
          <div class="ui-card-head">
            <div>
              <h2 class="ui-card-title" id="create-user-title">创建成员</h2>
              <p class="t-footnote t-tertiary">仅创建普通成员；资料库访问必须显式勾选，并要求 libraries.manage 权限。</p>
            </div>
          </div>
          <form id="create-member" class="admin-form">
            <div class="admin-form-grid">
              <div class="ui-field">
                <label class="ui-label ui-label-required" for="new-display-name">显示名称</label>
                <input class="ui-input" id="new-display-name" name="displayName" type="text" maxlength="256" autocomplete="name" required>
              </div>
              <div class="ui-field">
                <label class="ui-label ui-label-required" for="new-username">用户名</label>
                <input class="ui-input" id="new-username" name="username" type="text" maxlength="128" autocomplete="username" required>
              </div>
            </div>
            <div class="ui-field">
              <label class="ui-label ui-label-required" for="new-password">初始密码</label>
              <input class="ui-input" id="new-password" name="password" type="password" minlength="12" maxlength="1024" autocomplete="new-password" required aria-describedby="new-password-note">
              <p class="ui-help" id="new-password-note">至少 12 个字符。密码只用于本次提交，不会显示、保存或写入审计。</p>
            </div>
            <fieldset class="admin-fieldset">
              <legend class="ui-label">允许播放的资料库</legend>
              <p id="library-selection-state" class="ui-help" role="status">正在加载可授权资料库…</p>
              <div id="library-options" class="library-options" hidden></div>
            </fieldset>
            <p class="ui-help">新成员默认不具备下载、编辑或管理员权限。</p>
            \(ServerWebUI.button("创建成员", variant: .primary, icon: .plusCircle, id: "create-member-submit", type: "submit"))
            <p id="create-member-state" class="ui-state-line admin-state t-footnote" role="status" aria-live="polite"></p>
          </form>
        </section>

        <section id="member-edit-panel" class="ui-card admin-panel" aria-labelledby="edit-user-title" hidden>
          <div class="ui-card-head">
            <div>
              <h2 class="ui-card-title" id="edit-user-title">编辑成员访问</h2>
              <p class="t-footnote t-tertiary">只可编辑普通成员显示名和资料库访问；保存后该成员的现有会话会失效。</p>
            </div>
          </div>
          <form id="edit-member" class="admin-form">
            <div class="admin-form-grid">
              <div class="ui-field">
                <label class="ui-label ui-label-required" for="edit-display-name">显示名称</label>
                <input class="ui-input" id="edit-display-name" name="displayName" type="text" maxlength="256" autocomplete="name" required>
              </div>
              <div class="ui-field">
                <label class="ui-label" for="edit-username">用户名</label>
                <input class="ui-input" id="edit-username" type="text" readonly>
              </div>
            </div>
            <fieldset class="admin-fieldset">
              <legend class="ui-label">允许播放的资料库</legend>
              <p id="edit-library-selection-state" class="ui-help">请选择资料库。</p>
              <div id="edit-library-options" class="library-options" hidden></div>
            </fieldset>
            <fieldset class="admin-fieldset">
              <legend class="ui-label">播放与远程策略</legend>
              <p id="edit-policy-state" class="ui-help" role="status">选择成员后加载策略。</p>
              <div class="admin-policy-grid">
                <label><input id="policy-playback" type="checkbox">允许播放</label>
                <label><input id="policy-remote" type="checkbox">允许远程访问</label>
                <label><input id="policy-direct" type="checkbox">允许 Direct Play</label>
                <label><input id="policy-remux" type="checkbox">允许 Remux</label>
                <label><input id="policy-transcode" type="checkbox">允许转码</label>
                <label><input id="policy-download" type="checkbox">允许下载</label>
              </div>
              <div class="admin-form-grid">
                <div class="ui-field">
                  <label class="ui-label" for="policy-streams">并发流上限</label>
                  <select class="ui-input" id="policy-streams">
                    <option value="1">1</option><option value="2">2</option><option value="3">3</option>
                    <option value="4">4</option><option value="5">5</option><option value="6">6</option>
                    <option value="7">7</option><option value="8">8</option>
                  </select>
                </div>
                <div class="ui-field">
                  <label class="ui-label" for="policy-bitrate">远程码率上限（Mbps）</label>
                  <input class="ui-input" id="policy-bitrate" type="number" min="1" max="200" inputmode="numeric" placeholder="继承服务器默认值">
                </div>
                <div class="ui-field">
                  <label class="ui-label" for="policy-start">允许访问开始时间</label>
                  <input class="ui-input" id="policy-start" type="time">
                </div>
                <div class="ui-field">
                  <label class="ui-label" for="policy-end">允许访问结束时间</label>
                  <input class="ui-input" id="policy-end" type="time">
                </div>
              </div>
              <div class="ui-field">
                <label class="ui-label" for="policy-rating">最高内容分级</label>
                <input class="ui-input" id="policy-rating" type="text" maxlength="32" placeholder="不限制">
              </div>
              <p class="ui-help">访问时间必须同时填写或同时留空。保存策略后该成员的现有会话会失效。</p>
            </fieldset>
            <div class="ui-field">
              <label class="ui-label" for="edit-password">重置密码（可选）</label>
              <input class="ui-input" id="edit-password" name="password" type="password" minlength="12" maxlength="1024" autocomplete="new-password" placeholder="留空则不修改">
            </div>
            <div class="edit-actions">
              \(ServerWebUI.button("保存访问", variant: .primary, icon: .check, id: "edit-member-submit", type: "submit"))
              \(ServerWebUI.button("取消", variant: .ghost, id: "edit-member-cancel"))
            </div>
            <p id="edit-member-state" class="ui-state-line admin-state t-footnote" role="status" aria-live="polite"></p>
          </form>
        </section>

        <div class="admin-dashboard">
          \(dataPanel(id: "users", title: "用户", note: "谁可以使用这台服务器"))
          \(dataPanel(id: "sessions", title: "已登录的设备", note: "最近登录过的设备"))
          \(dataPanel(id: "playback-sessions", title: "当前播放", note: "正在准备、排队或播放的 HLS 会话"))
          \(dataPanel(id: "events", title: "安全记录", note: "最近 100 条登录与权限变更", extraClass: "admin-panel-wide"))
        </div>
        <p class="t-footnote t-tertiary admin-footnote">管理操作受角色、资料库授权、CSRF、限速和审计保护 · 响应不包含密码、Cookie、token、摘要、媒体路径、请求头或客户端地址。</p>
        """
        return ServerWebDocument.render(
            title: "服务管理",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/admin.css"],
            pageScripts: ["/assets/overlays.js", "/assets/admin.js"],
            tint: .admin
        )
    }

    /// The three read-only panels share one shape, so they share one builder;
    /// their ids remain the contract `admin.js` fills in.
    private static func dataPanel(id: String, title: String, note: String, extraClass: String = "") -> String {
        """
        <section class="ui-card admin-panel \(extraClass)" aria-labelledby="\(id)-title">
          <div class="ui-card-head">
            <div>
              <h2 class="ui-card-title" id="\(id)-title">\(ServerWebHTML.escape(title))</h2>
              <p class="t-footnote t-tertiary">\(ServerWebHTML.escape(note))</p>
            </div>
            <span id="\(id)-count" class="ui-badge ui-badge-neutral">—</span>
          </div>
          <p id="\(id)-state" class="ui-state-line admin-state t-callout t-tertiary">正在加载…</p>
          <div id="\(id)-content" class="content" hidden></div>
        </section>
        """
    }

    /// Fixed administration UI. User, library, session and audit information must
    /// only come from permission-gated APIs and never from this cacheable asset.
    static let style = #"""
    /* 这条提示走公共的 `.ui-alert`。它与媒体源页的 `.sources-notice` 此前是两个
       名字、一份逐字相同的规则，而两者本来就是同一个组件。 */
    #global-status { margin-bottom: var(--space-5); }
    .admin-panel + .admin-panel, .admin-dashboard { margin-top: var(--space-5); }
    .admin-panel .ui-card-head { align-items: flex-start; }
    .content[hidden], .admin-state[hidden] { display: none; }

    .admin-form { display: grid; gap: var(--space-4); max-width: 620px; }
    .admin-form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--space-4); }
    .admin-form .ui-btn { justify-self: start; }
    .admin-fieldset {
      display: grid;
      gap: var(--space-2);
      padding: var(--space-4);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-sm);
      background: var(--surface-sunken);
    }
    .admin-fieldset legend { padding: 0 var(--space-2); }
    .library-options { display: grid; gap: var(--space-1); }
    .library-options label {
      display: flex;
      min-height: var(--control-height-lg);
      align-items: center;
      gap: var(--space-3);
      font-size: var(--type-callout-size);
      cursor: pointer;
    }
    .library-options input[type="checkbox"] {
      width: 20px;
      height: 20px;
      flex: none;
      margin: 0;
      accent-color: var(--accent);
    }
    .admin-policy-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: var(--space-1) var(--space-4);
    }
    .admin-policy-grid label {
      display: flex;
      min-height: var(--control-height-lg);
      align-items: center;
      gap: var(--space-3);
      font-size: var(--type-callout-size);
      cursor: pointer;
    }
    .admin-policy-grid input { width: 20px; height: 20px; margin: 0; accent-color: var(--accent); }
    .edit-actions { display: flex; flex-wrap: wrap; gap: var(--space-2); }

    /* Users and sessions sit side by side; the audit log takes the full width
       because its rows are long and wrapping them twice is worse than scrolling. */
    .admin-dashboard {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: var(--space-5);
    }
    .admin-panel-wide { grid-column: 1 / -1; }

    .rows { display: grid; }
    /* Rows adapt to the card they land in rather than assuming a wide one.
       These panels sit in a `minmax(320px, 1fr)` dashboard, so a fixed
       three-column row squeezed a device name and an expiry date into ~50px
       columns and wrapped both to four lines each.  Flex with a real basis lets
       the same row read as one line in a wide panel and as a stack in a narrow
       one. */
    .row {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: var(--space-1) var(--space-3);
      min-height: 56px;
      padding: var(--space-2) 0;
      border-bottom: var(--hairline) solid var(--divider);
    }
    .row > * { min-width: 0; }
    .row .primary { flex: 1 1 150px; }
    .row .secondary { flex: 1 1 150px; }
    .row .meta { flex: 1 1 190px; }
    .row-trail {
      display: flex;
      flex: 0 0 auto;
      align-items: center;
      margin-left: auto;
      gap: var(--space-2);
    }
    .row:last-child { border-bottom: 0; }
    .row .primary { font-size: var(--type-callout-size); font-weight: var(--weight-medium); overflow-wrap: anywhere; }
    .row .secondary, .row small, .row .meta {
      color: var(--text-tertiary);
      font-size: var(--type-footnote-size);
      overflow-wrap: anywhere;
    }
    .admin-footnote { padding-top: var(--space-6); }

    @media (max-width: 719px) {
      .admin-form-grid { grid-template-columns: minmax(0, 1fr); }
      .admin-policy-grid { grid-template-columns: minmax(0, 1fr); }
      .row > * { flex: 1 1 100%; }
      .row-trail { flex: 1 1 100%; margin-left: 0; }
      .admin-form .ui-btn, .edit-actions .ui-btn { width: 100%; }
    }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const globalStatus = byID('global-status');
      // 文案写进内层节点：往外层写会把提示图标一起抹掉。
      const globalStatusText = byID('global-status-text');
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
      const editPolicyState = byID('edit-policy-state');
      const policyPlayback = byID('policy-playback');
      const policyRemote = byID('policy-remote');
      const policyDirect = byID('policy-direct');
      const policyRemux = byID('policy-remux');
      const policyTranscode = byID('policy-transcode');
      const policyDownload = byID('policy-download');
      const policyStreams = byID('policy-streams');
      const policyBitrate = byID('policy-bitrate');
      const policyStart = byID('policy-start');
      const policyEnd = byID('policy-end');
      const policyRating = byID('policy-rating');
      var availableLibraries = [];
      var editingUser = null;
      var editingPolicy = null;
      var editingPolicyETag = null;
      var policyLoadRevision = 0;
      var loadedUsers = [];
      var loadedUserTotal = 0;
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
          if (response.status === 403) throw new Error('你没有查看这部分内容的权限。');
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
        editLibrarySelectionState.textContent = availableLibraries.length ? '仅勾选成员可浏览和播放的资料库。' : '目前没有可以分配的资料库。';
      }
      function renderLibraries(data) {
        const libraries = Array.isArray(data.libraries) ? data.libraries.filter((library) =>
          library && typeof library.id === 'string' && library.id.length > 0 && library.id.length <= 512 &&
          typeof library.name === 'string' && typeof library.mediaType === 'string'
        ) : [];
        availableLibraries = libraries.slice(0, 500);
        libraryOptions.replaceChildren();
        if (!availableLibraries.length) {
          librarySelectionState.textContent = '目前没有可以分配的资料库，不过仍然可以先把人加进来。';
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
        librarySelectionState.textContent = libraryOptions.childElementCount ? '仅勾选新成员可浏览和播放的资料库。' : '目前没有可以分配的资料库。';
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
          if (response.status === 403) throw new Error('你没有添加用户或分配资料库的权限。');
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
      const minutesToTime = (value) => {
        if (!Number.isInteger(value) || value < 0 || value >= 1440) return '';
        return `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`;
      };
      const timeToMinutes = (value) => {
        if (!value) return null;
        const match = /^(\d{2}):(\d{2})$/.exec(value);
        if (!match) return NaN;
        const hours = Number(match[1]);
        const minutes = Number(match[2]);
        return hours < 24 && minutes < 60 ? hours * 60 + minutes : NaN;
      };
      async function loadUserPolicy(userID) {
        const revision = ++policyLoadRevision;
        editingPolicy = null;
        editingPolicyETag = null;
        editPolicyState.textContent = '正在加载播放策略…';
        editPolicyState.classList.remove('error');
        editSubmit.disabled = true;
        try {
          const response = await fetch(`/api/v1/admin/users/${encodeURIComponent(userID)}/policy`, {
            credentials: 'same-origin', headers: { 'Accept': 'application/json' }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (response.status === 403) throw new Error('你没有查看用户播放策略的权限。');
          if (!response.ok) throw new Error('无法读取用户播放策略。');
          const documentValue = await response.json();
          if (revision !== policyLoadRevision || editingUser?.id !== userID) return;
          const policy = documentValue && documentValue.value;
          const etag = response.headers.get('ETag');
          if (!policy || !etag) throw new Error('播放策略响应不完整。');
          editingPolicy = policy;
          editingPolicyETag = etag;
          policyPlayback.checked = policy.playbackAllowed === true;
          policyRemote.checked = policy.remoteAccessAllowed === true;
          policyDirect.checked = policy.directPlayAllowed === true;
          policyRemux.checked = policy.remuxAllowed === true;
          policyTranscode.checked = policy.transcodeAllowed === true;
          policyDownload.checked = policy.downloadAllowed === true;
          policyStreams.value = String(Number.isInteger(policy.maximumConcurrentStreams) ? policy.maximumConcurrentStreams : 2);
          policyBitrate.value = Number.isInteger(policy.remoteBitrateLimitMbps) ? String(policy.remoteBitrateLimitMbps) : '';
          policyStart.value = minutesToTime(policy.accessStartMinute);
          policyEnd.value = minutesToTime(policy.accessEndMinute);
          policyRating.value = typeof policy.maximumContentRating === 'string' ? policy.maximumContentRating : '';
          editPolicyState.textContent = '策略已加载；保存后新限制立即生效。';
        } catch (error) {
          if (revision !== policyLoadRevision || editingUser?.id !== userID) return;
          editPolicyState.classList.add('error');
          editPolicyState.textContent = error && error.message ? error.message : '无法读取用户播放策略。';
        } finally {
          if (revision === policyLoadRevision && editingUser?.id === userID) editSubmit.disabled = false;
        }
      }
      function closeEditUser() {
        policyLoadRevision += 1;
        editingUser = null;
        editingPolicy = null;
        editingPolicyETag = null;
        editForm.reset();
        editForm.removeAttribute('data-user-id');
        editPanel.hidden = true;
        editState.textContent = '';
        editState.classList.remove('error');
        editPolicyState.textContent = '选择成员后加载策略。';
        editPolicyState.classList.remove('error');
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
        loadUserPolicy(user.id);
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
          editState.textContent = '名称不能为空，也不能太长。';
          editDisplayName.focus();
          return;
        }
        if (password && password.length < 12) {
          editState.classList.add('error');
          editState.textContent = '新密码至少需要 12 个字符。';
          editPassword.focus();
          return;
        }
        if (!editingPolicy || !editingPolicyETag) {
          editState.classList.add('error');
          editState.textContent = '播放策略尚未加载，请稍后再试。';
          return;
        }
        const accessStartMinute = timeToMinutes(policyStart.value);
        const accessEndMinute = timeToMinutes(policyEnd.value);
        if (Number.isNaN(accessStartMinute) || Number.isNaN(accessEndMinute) ||
            ((accessStartMinute === null) !== (accessEndMinute === null))) {
          editState.classList.add('error');
          editState.textContent = '访问开始和结束时间必须同时填写，且使用有效时间。';
          return;
        }
        const bitrateValue = policyBitrate.value.trim();
        const remoteBitrateLimitMbps = bitrateValue ? Number(bitrateValue) : null;
        const maximumConcurrentStreams = Number(policyStreams.value);
        const maximumContentRating = policyRating.value.trim() || null;
        if (!Number.isInteger(maximumConcurrentStreams) || maximumConcurrentStreams < 1 || maximumConcurrentStreams > 8 ||
            (remoteBitrateLimitMbps !== null && (!Number.isInteger(remoteBitrateLimitMbps) || remoteBitrateLimitMbps < 1 || remoteBitrateLimitMbps > 200)) ||
            (maximumContentRating && new TextEncoder().encode(maximumContentRating).length > 32)) {
          editState.classList.add('error');
          editState.textContent = '请检查并发流、远程码率和内容分级。';
          return;
        }
        const policy = {
          schemaVersion: 1,
          playbackAllowed: policyPlayback.checked,
          remoteAccessAllowed: policyRemote.checked,
          directPlayAllowed: policyDirect.checked,
          remuxAllowed: policyRemux.checked,
          transcodeAllowed: policyTranscode.checked,
          downloadAllowed: policyDownload.checked,
          maximumConcurrentStreams,
          remoteBitrateLimitMbps,
          accessStartMinute,
          accessEndMinute,
          maximumContentRating
        };
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
          if (accessResponse.status === 403) throw new Error('你没有修改用户可访问范围的权限。');
          if (!accessResponse.ok) throw new Error(accessResponse.status === 429 ? '操作过于频繁，请稍后重试。' : '无法保存成员访问，请检查输入后重试。');
          if (password) {
            const passwordResponse = await fetch(`/api/v1/admin/users/${encodedID}/password`, {
              method: 'POST', credentials: 'same-origin',
              headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': token },
              body: JSON.stringify({ password })
            });
            if (passwordResponse.status === 401) { window.location.assign('/login'); return; }
            if (passwordResponse.status === 403) throw new Error('你没有重置密码的权限。');
            if (!passwordResponse.ok) throw new Error(passwordResponse.status === 429 ? '操作过于频繁，请稍后重试。' : '访问已保存，但密码未更新。');
          }
          const policyResponse = await fetch(`/api/v1/admin/users/${encodedID}/policy`, {
            method: 'PATCH', credentials: 'same-origin',
            headers: {
              'Content-Type': 'application/json',
              'X-MediaLIB-CSRF': token,
              'If-Match': editingPolicyETag
            },
            body: JSON.stringify(policy)
          });
          if (policyResponse.status === 401) { window.location.assign('/login'); return; }
          if (policyResponse.status === 403) throw new Error('访问已保存，但你没有修改播放策略的权限。');
          if (policyResponse.status === 409) throw new Error('访问已保存，但播放策略已在另一个页面改变，请重新打开成员后再保存。');
          if (!policyResponse.ok) throw new Error(policyResponse.status === 429 ? '访问已保存，但操作过于频繁，请稍后重试策略。' : '访问已保存，但播放策略未更新。');
          const savedPolicy = await policyResponse.json();
          editingPolicy = savedPolicy.value;
          editingPolicyETag = policyResponse.headers.get('ETag');
          editPassword.value = '';
          editState.textContent = '已更新访问与播放策略。TA 的设备需要重新登录。';
          await load();
        } catch (error) {
          editState.classList.add('error');
          editState.textContent = error && error.message ? error.message : '无法保存成员访问，请稍后重试。';
        } finally {
          editPassword.value = '';
          editSubmit.disabled = false;
        }
      }
      function renderUsers(data, append = false) {
        const incoming = Array.isArray(data.users) ? data.users : [];
        if (append) {
          const known = new Set(loadedUsers.map((user) => user && user.id));
          incoming.forEach((user) => { if (user && !known.has(user.id)) loadedUsers.push(user); });
        } else {
          loadedUsers = incoming.slice(0, 200);
        }
        loadedUserTotal = Number.isFinite(data.totalCount) ? data.totalCount : loadedUsers.length;
        const users = loadedUsers;
        byID('users-count').textContent = String(loadedUserTotal);
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
          const actions = element('div', 'row-trail');
          actions.append(element('span', `pill${user.isDisabled ? ' danger' : ''}`, user.isBuiltInAdministrator ? '内置管理员' : (user.isDisabled ? '已停用' : (user.requiresInitialPassword ? '待设置密码' : '正常'))));
          if (!user.isBuiltInAdministrator) {
            const edit = element('button', 'ui-btn ui-btn-ghost user-toggle', '编辑访问');
            edit.type = 'button';
            edit.addEventListener('click', () => openEditUser(user));
            actions.append(edit);
            const resetPassword = element('button', 'ui-btn ui-btn-ghost user-toggle', '重置密码');
            resetPassword.type = 'button';
            resetPassword.addEventListener('click', () => openEditUser(user, true));
            actions.append(resetPassword);
            const toggle = element('button', 'ui-btn ui-btn-ghost user-toggle', user.isDisabled ? '启用' : '停用');
            toggle.type = 'button';
            toggle.addEventListener('click', () => setUserAvailability(user.id, !user.isDisabled, toggle));
            actions.append(toggle);
          }
          rows.append(row([identity, role, access, actions]));
        });
        if (loadedUsers.length < loadedUserTotal) {
          const moreRow = element('div', 'row');
          const more = element('button', 'ui-btn ui-btn-secondary', '加载更多用户');
          more.type = 'button';
          more.addEventListener('click', async () => {
            more.disabled = true;
            try {
              const next = await fetchJSON(`/api/v1/admin/users?offset=${loadedUsers.length}&limit=100`);
              renderUsers(next, true);
            } catch (error) {
              globalStatus.hidden = false;
              globalStatusText.textContent = error && error.message ? error.message : '无法加载更多用户。';
              more.disabled = false;
            }
          });
          moreRow.append(more);
          rows.append(moreRow);
        }
        showContent('users', rows);
      }
      async function setUserAvailability(id, disabled, button) {
        if (typeof id !== 'string' || !id) return;
        const action = disabled ? '停用' : '启用';
        if (!window.confirm(`${action}此用户${disabled ? '会让 TA 的所有设备退出登录' : ''}。是否继续？`)) return;
        button.disabled = true;
        globalStatus.hidden = false;
        globalStatusText.textContent = `正在${action}用户…`;
        try {
          const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
          if (!token) throw new Error('页面安全令牌不可用，请刷新后重试');
          const response = await fetch(`/api/v1/admin/users/${encodeURIComponent(id)}/${disabled ? 'disable' : 'enable'}`, {
            method: 'POST', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (response.status === 403) throw new Error('你没有管理用户的权限。');
          if (!response.ok) throw new Error(response.status === 429 ? '操作过于频繁，请稍后重试' : '无法更新用户状态');
          globalStatusText.textContent = `用户已${action}。`;
          await load();
        } catch (error) {
          globalStatusText.textContent = error && error.message ? error.message : '更新用户状态失败，请稍后重试。';
          button.disabled = false;
        }
      }
      function renderSessions(data, usersByID) {
        const devices = Array.isArray(data.devices) ? data.devices : [];
        const sessions = Array.isArray(data.sessions) ? data.sessions : [];
        byID('sessions-count').textContent = String(sessions.length);
        if (!devices.length && !sessions.length) { setState('sessions', '目前没有设备登录。'); return; }
        const deviceByID = new Map(devices.map((device) => [device.id, device]));
        const rows = element('div', 'rows');
        sessions.forEach((session) => {
          const user = usersByID.get(session.userID);
          const device = deviceByID.get(session.deviceID);
          const revoke = element('button', 'revoke-session', '撤销');
          revoke.type = 'button';
          revoke.addEventListener('click', () => revokeSession(session.id, revoke));
          const actions = element('div', 'row-trail');
          actions.append(element('span', 'ui-badge ui-badge-neutral', `至 ${safeDate(session.refreshExpiresAt)}`), revoke);
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
        if (typeof id !== 'string' || !id || !window.confirm('这台设备将需要重新登录。要继续吗？')) return;
        button.disabled = true;
        globalStatus.hidden = false;
        globalStatusText.textContent = '正在退出…';
        try {
          const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
          if (!token) throw new Error('页面安全令牌不可用，请刷新后重试');
          const response = await fetch(`/api/v1/admin/sessions/${encodeURIComponent(id)}/revoke`, {
            method: 'POST', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (response.status === 403) throw new Error('你没有让设备退出登录的权限。');
          if (!response.ok) throw new Error(response.status === 429 ? '操作过于频繁，请稍后重试' : '没能让这台设备退出');
          globalStatusText.textContent = '这台设备已退出登录。';
          await load();
        } catch (error) {
          globalStatusText.textContent = error && error.message ? error.message : '没能退出，请稍后再试。';
          button.disabled = false;
        }
      }
      function renderPlaybackSessions(data, usersByID) {
        const sessions = Array.isArray(data) ? data : [];
        byID('playback-sessions-count').textContent = String(sessions.length);
        if (!sessions.length) { setState('playback-sessions', '目前没有活动播放。'); return; }
        const stateLabel = { queued:'排队', preparing:'准备', ready:'就绪', playing:'播放', finished:'完成', failed:'失败', cancelled:'取消' };
        const rows = element('div', 'rows');
        sessions.forEach((session) => {
          const user = usersByID.get(session.userID);
          const terminate = element('button', 'ui-btn ui-btn-secondary', '终止');
          terminate.type = 'button';
          terminate.addEventListener('click', () => terminatePlaybackSession(session.sessionID, terminate));
          rows.append(row([
            element('div', 'primary', user ? (user.displayName || user.username) : shortID(session.userID)),
            element('div', 'secondary', `${session.mode || 'HLS'} · ${stateLabel[session.state] || session.state || '未知'}`),
            element('div', 'meta mono', `开始 ${safeDate(session.startedAt)}`),
            terminate
          ]));
        });
        showContent('playback-sessions', rows);
      }
      async function terminatePlaybackSession(id, button) {
        if (typeof id !== 'string' || !id || !window.confirm('此播放会立即停止。要继续吗？')) return;
        button.disabled = true;
        try {
          const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
          if (!token) throw new Error('页面安全令牌不可用，请刷新后重试');
          const response = await fetch(`/api/v1/admin/playback-sessions/${encodeURIComponent(id)}`, {
            method: 'DELETE', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (response.status === 403) throw new Error('你没有终止播放会话的权限。');
          if (!response.ok) throw new Error('播放会话已结束或暂时无法终止。');
          await load();
        } catch (error) {
          globalStatus.hidden = false;
          globalStatusText.textContent = error && error.message ? error.message : '无法终止播放会话。';
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
        globalStatusText.textContent = '正在加载管理数据…';
        ['users', 'sessions', 'playback-sessions', 'events'].forEach((name) => setState(name, '正在加载…'));
        const results = await Promise.allSettled([
          fetchJSON('/api/v1/admin/users?offset=0&limit=100'),
          fetchJSON('/api/v1/admin/sessions'),
          fetchJSON('/api/v1/admin/security-events'),
          fetchJSON('/api/v1/admin/libraries'),
          fetchJSON('/api/v1/admin/playback-sessions')
        ]);
        var failures = 0;
        var usersByID = new Map();
        if (results[0].status === 'fulfilled') {
          renderUsers(results[0].value);
          usersByID = new Map((results[0].value.users || []).map((user) => [user.id, user]));
        } else { failures += 1; setState('users', results[0].reason.message || '无法读取用户。', true); }
        if (results[1].status === 'fulfilled') renderSessions(results[1].value, usersByID);
        else { failures += 1; setState('sessions', results[1].reason.message || '读不到登录设备。', true); }
        if (results[2].status === 'fulfilled') renderEvents(results[2].value);
        else { failures += 1; setState('events', results[2].reason.message || '无法读取安全事件。', true); }
        if (results[3].status === 'fulfilled') renderLibraries(results[3].value);
        else setLibraryLoadFailure('看不到可分配的资料库，不过仍然可以先把人加进来。');
        if (results[4].status === 'fulfilled') renderPlaybackSessions(results[4].value, usersByID);
        else { failures += 1; setState('playback-sessions', results[4].reason.message || '无法读取当前播放。', true); }
        globalStatusText.textContent = failures ? `已加载，其中 ${failures} 个区域不可用。可检查账号权限后重试。` : '管理数据已更新。';
        refreshButton.disabled = false;
      }
      refreshButton.addEventListener('click', load);
      createForm.addEventListener('submit', createMember);
      editForm.addEventListener('submit', saveMemberEdit);
      editCancel.addEventListener('click', closeEditUser);
      load().catch(() => {
        globalStatusText.textContent = '加载失败，请稍后重试。';
        refreshButton.disabled = false;
      });
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
