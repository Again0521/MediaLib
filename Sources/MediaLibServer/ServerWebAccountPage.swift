import Foundation
import MediaLibServerProtocol

/// 当前认证用户自己的账户页。个人资料由受权 API 读取，注销只撤销当前会话；网页从不
/// 读取 Cookie、令牌或其它用户资料。
enum ServerWebAccountPage {
    static func render(serverName: String, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .account, showAdministration: showAdministration, note: .none, categories: categories,
            extras: sidebarExtras
        )
        let content = """
        \(ServerWebPageHeader.render(
            icon: .account,
            eyebrow: "Account",
            title: "设置",
            subtitle: "你的账号，以及你能访问哪些内容。"
        ))
        <div class="account-stack">
          <section class="ui-card" aria-labelledby="profile-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="profile-title">登录身份</h2></div>
            <p id="profile-state" class="ui-state-line account-state t-footnote t-tertiary" role="status" aria-live="polite">正在加载账户资料…</p>
            <!-- 名字与用户名从两列定宽表格里搬出来，做成一张身份卡：这是这一页
                 唯一一处"这是谁"的信息，读者第一眼要看的就是它，不该和"已生效
                 权限"并列成 dl 里的第三行。首字母底板由脚本填，不占服务端渲染。 -->
            <div id="profile" class="account-identity" hidden>
              <span id="account-monogram" class="ui-icon-tile ui-icon-tile-lg ui-icon-tile-tint account-monogram" aria-hidden="true"></span>
              <div class="account-identity-copy">
                <strong id="display-name" class="t-title-3">—</strong>
                <span id="username" class="t-callout t-tertiary">—</span>
              </div>
              <dl class="account-meta">
                <dt>角色</dt><dd id="roles" class="account-pills">—</dd>
                <dt>已生效权限</dt><dd id="permissions" class="account-pills">—</dd>
              </dl>
            </div>
          </section>

          <section class="ui-card" aria-labelledby="personal-data-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="personal-data-title">我的数据</h2></div>
            <p class="t-footnote t-tertiary">这些记录只属于当前账号，其他用户看不到，也不会覆盖桌面端的全局状态。</p>
            <div class="account-personal-links">
              \(ServerWebUI.linkButton("我的评分", href: "/ratings", variant: .secondary, icon: .star))
              \(ServerWebUI.linkButton("播放历史", href: "/history", variant: .secondary, icon: .history))
              \(ServerWebUI.linkButton("播放队列", href: "/queue", variant: .secondary, icon: .queue))
            </div>
          </section>

          <section class="ui-card" aria-labelledby="appearance-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="appearance-title">外观</h2></div>
            <p class="t-footnote t-tertiary">选择只保存在本浏览器，不会同步到服务端，也不会写入任何账号数据。</p>
            \(ServerWebUI.appearanceSwitcher())
          </section>

          <section class="ui-card" aria-labelledby="password-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="password-title">修改密码</h2></div>
            <p class="t-footnote t-tertiary">验证当前密码后，所有已登录设备都会退出；请使用新密码重新登录。</p>
            <form id="change-password" class="account-form">
              <div class="ui-field">
                <label class="ui-label" for="current-password">当前密码</label>
                <input class="ui-input" id="current-password" type="password" autocomplete="current-password" maxlength="1024" required>
              </div>
              <div class="ui-field">
                <label class="ui-label ui-label-required" for="new-password">新密码</label>
                <input class="ui-input" id="new-password" type="password" autocomplete="new-password" minlength="12" maxlength="1024" required aria-describedby="new-password-help">
                <p class="ui-help" id="new-password-help">至少 12 个字符。</p>
              </div>
              <div class="ui-field">
                <label class="ui-label ui-label-required" for="confirm-password">确认新密码</label>
                <input class="ui-input" id="confirm-password" type="password" autocomplete="new-password" minlength="12" maxlength="1024" required>
              </div>
              \(ServerWebUI.button("修改密码并退出所有设备", variant: .primary, icon: .key, id: "change-password-submit", type: "submit"))
              <p id="password-state" class="ui-state-line account-state t-footnote t-tertiary" role="status" aria-live="polite"></p>
            </form>
          </section>

          <section class="ui-card" aria-labelledby="logout-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="logout-title">当前设备</h2></div>
            <p class="t-footnote t-tertiary">退出只会撤销当前浏览器会话；其它设备仍可在服务管理页按权限单独处理。</p>
            <div class="account-actions">\(ServerWebUI.button("退出当前账户", variant: .destructive, icon: .logout, id: "logout"))</div>
            <p id="logout-state" class="ui-state-line account-state t-footnote t-tertiary" role="status" aria-live="polite"></p>
          </section>
        </div>
        """
        return ServerWebDocument.render(
            title: "设置",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/account.css"],
            pageScripts: ["/assets/overlays.js", "/assets/account.js"],
            tint: .admin
        )
    }

    /// Cacheable account-page presentation. Identity and session data are fetched
    /// only through authenticated, non-cacheable endpoints.
    static let style = #"""
    /* Settings is a reading-and-editing page, so it keeps a narrow measure rather
       than stretching forms across the full content width. */
    .account-stack { display: grid; max-width: 760px; gap: var(--space-5); }

    .account-identity {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      align-items: center;
      gap: var(--space-3) var(--space-4);
    }
    .account-identity-copy { display: grid; min-width: 0; gap: 2px; }
    .account-monogram { font-size: var(--type-title2-size); font-weight: var(--weight-bold); }
    /* 角色与权限跨满整行落在名字下面：它们是这个人的属性，不是他的名字的一部分。 */
    .account-identity .account-meta { grid-column: 1 / -1; padding-top: var(--space-3); border-top: var(--hairline) solid var(--divider); }
    .account-meta {
      display: grid;
      grid-template-columns: 120px minmax(0, 1fr);
      gap: var(--space-3) var(--space-4);
      font-size: var(--type-callout-size);
    }
    .account-meta dt { color: var(--text-tertiary); font-size: var(--type-subhead-size); }
    .account-meta dd { margin: 0; overflow-wrap: anywhere; }
    .account-pills { display: flex; flex-wrap: wrap; gap: var(--space-2); }

    .account-form { display: grid; gap: var(--space-4); max-width: 460px; }
    .account-form .ui-btn { justify-self: start; }
    .account-actions { display: flex; }
    .account-personal-links { display: flex; flex-wrap: wrap; gap: var(--space-2); }

    @media (max-width: 719px) {
      .account-meta { grid-template-columns: minmax(0, 1fr); gap: var(--space-1); }
      .account-meta dt { margin-top: var(--space-2); }
      .account-form .ui-btn, .account-actions .ui-btn { width: 100%; }
    }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const profileState = byID('profile-state');
      const profile = byID('profile');
      const logoutButton = byID('logout');
      const logoutState = byID('logout-state');
      const passwordForm = byID('change-password');
      const passwordSubmit = byID('change-password-submit');
      const passwordState = byID('password-state');
      const appendPills = (id, values, empty) => {
        const target = byID(id);
        target.replaceChildren();
        const items = Array.isArray(values) ? values.filter((value) => typeof value === 'string' && value.length <= 128) : [];
        if (!items.length) { target.textContent = empty; return; }
        items.forEach((value) => {
          const pill = document.createElement('span');
          pill.className = 'ui-chip';
          pill.textContent = value;
          target.append(pill);
        });
      };
      async function loadProfile() {
        try {
          const controller = new AbortController();
          const timer = window.setTimeout(() => controller.abort(), 10000);
          let response;
          try {
            response = await fetch('/api/v1/auth/me', { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal: controller.signal });
          } finally { window.clearTimeout(timer); }
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('暂时读不到你的账号信息');
          const data = await response.json();
          if (typeof data.username !== 'string' || typeof data.displayName !== 'string') throw new Error('账号信息读取失败');
          byID('display-name').textContent = data.displayName;
          byID('username').textContent = `@${data.username}`;
          // 首字母而不是头像：产品里没有头像这回事，一个占位人形只是噪声。
          const initial = (data.displayName || data.username || '').trim().slice(0, 1).toUpperCase();
          byID('account-monogram').textContent = initial;
          appendPills('roles', data.roleIDs, '未分配角色');
          appendPills('permissions', data.permissionIDs, '没有额外权限');
          profile.hidden = false;
          profileState.textContent = '已更新。';
        } catch (error) {
          profileState.classList.add('error');
          profileState.textContent = error && error.message ? error.message : '暂时读不到你的账号信息。';
        }
      }
      logoutButton.addEventListener('click', async () => {
        if (!window.confirm('确定要退出登录吗？')) return;
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { logoutState.classList.add('error'); logoutState.textContent = '请刷新页面后再试。'; return; }
        logoutButton.disabled = true;
        logoutState.classList.remove('error');
        logoutState.textContent = '正在退出…';
        try {
          const response = await fetch('/api/v1/auth/logout', { method: 'POST', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token } });
          if (response.status === 401 || response.status === 204) { window.location.assign('/login'); return; }
          throw new Error(response.status === 429 ? '操作太频繁了，等一会儿再试。' : '暂时退不出去。');
        } catch (error) {
          logoutState.classList.add('error');
          logoutState.textContent = error && error.message ? error.message : '没能退出，请稍后再试。';
          logoutButton.disabled = false;
        }
      });
      passwordForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        const currentField = byID('current-password');
        const newField = byID('new-password');
        const confirmField = byID('confirm-password');
        const currentPassword = currentField.value;
        const newPassword = newField.value;
        if (newPassword.length < 12 || newPassword !== confirmField.value) {
          passwordState.classList.add('error');
          passwordState.textContent = newPassword.length < 12 ? '新密码至少要 12 个字符。' : '两次输入的新密码不一致。';
          return;
        }
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { passwordState.classList.add('error'); passwordState.textContent = '请刷新页面后再试。'; return; }
        passwordSubmit.disabled = true;
        passwordState.classList.remove('error');
        passwordState.textContent = '正在更新密码…';
        try {
          const response = await fetch('/api/v1/auth/password', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': token },
            body: JSON.stringify({ currentPassword, newPassword })
          });
          if (response.status === 401 || response.status === 204) { window.location.assign('/login'); return; }
          throw new Error(response.status === 429 ? '操作太频繁了，等一会儿再试。' : '没能改密码。确认一下当前密码是否输对了。');
        } catch (error) {
          passwordState.classList.add('error');
          passwordState.textContent = error && error.message ? error.message : '没能改密码，请稍后再试。';
          passwordSubmit.disabled = false;
        } finally {
          currentField.value = '';
          newField.value = '';
          confirmField.value = '';
        }
      });
      loadProfile();
    })();
    """#

}
