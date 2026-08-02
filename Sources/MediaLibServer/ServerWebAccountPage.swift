import Foundation
import MediaLibServerProtocol

/// 当前认证用户自己的账户页。个人资料由受权 API 读取，注销只撤销当前会话；网页从不
/// 读取 Cookie、令牌或其它用户资料。
enum ServerWebAccountPage {
    static func render(serverName: String, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = []) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .account, showAdministration: showAdministration, note: .none, categories: categories
        )
        let pageHeader = ServerWebPageHeader.render(
            icon: .account,
            eyebrow: "我的媒体",
            title: "我的账户",
            subtitle: "查看当前登录身份和已生效权限；Cookie、令牌与会话标识不会显示。"
        )
        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>我的账户 · \(escape(serverName))</title>
          <link rel="stylesheet" href="/assets/account.css">
          <link rel="stylesheet" href="/assets/app-shell.css?v=68">
          <script src="/assets/app-shell.js?v=68" defer></script>
        </head>
        <body>
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">\(sidebar)<main id="main" tabindex="-1">\(pageHeader)<section class="card" aria-labelledby="profile-title"><h2 id="profile-title">登录身份</h2><p id="profile-state" class="state" role="status" aria-live="polite">正在加载账户资料…</p><dl id="profile" class="meta" hidden><dt>显示名称</dt><dd id="display-name">—</dd><dt>用户名</dt><dd id="username">—</dd><dt>角色</dt><dd id="roles" class="pills">—</dd><dt>已生效权限</dt><dd id="permissions" class="pills">—</dd></dl></section><section class="card" aria-labelledby="password-title"><h2 id="password-title">修改密码</h2><p class="subtitle">验证当前密码后，所有已登录设备都会退出；请使用新密码重新登录。</p><form id="change-password"><label>当前密码<input id="current-password" type="password" autocomplete="current-password" maxlength="1024" required></label><label>新密码<input id="new-password" type="password" autocomplete="new-password" minlength="12" maxlength="1024" required></label><label>确认新密码<input id="confirm-password" type="password" autocomplete="new-password" minlength="12" maxlength="1024" required></label><button id="change-password-submit" class="password-submit" type="submit">修改密码并退出所有设备</button><p id="password-state" class="state" role="status" aria-live="polite"></p></form></section><section class="card" aria-labelledby="logout-title"><h2 id="logout-title">当前设备</h2><p class="subtitle">退出只会撤销当前浏览器会话；其它设备仍可在服务管理页按权限单独处理。</p><button id="logout" type="button">退出当前账户</button><p id="logout-state" class="state" role="status" aria-live="polite"></p></section></main></div>
          <script src="/assets/account.js" defer></script>
        </body>
        </html>
        """
    }

    /// Cacheable account-page presentation. Identity and session data are fetched
    /// only through authenticated, non-cacheable endpoints.
    static let style = """
    :root{--ink:#172033;--muted:#5d6b82;--line:#dfe7f1;--canvas:#f4f7fb;--card:#fff;--blue:#174d82;--focus:#1570ef;--danger:#b42318}*{box-sizing:border-box}body{margin:0;color:var(--ink);background:var(--canvas);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:inherit}:focus-visible{outline:3px solid var(--focus);outline-offset:3px}.skip{position:fixed;z-index:2;top:8px;left:8px;padding:10px 14px;color:#fff;background:var(--blue);transform:translateY(-160%)}.skip:focus{transform:none}.shell{display:grid;grid-template-columns:232px minmax(0,1fr);min-height:100dvh}aside{padding:28px 18px;color:#eef7ff;background:linear-gradient(165deg,#183b68,#1e79cf 58%,#36bffa)}.brand{font-size:19px;font-weight:800}nav{display:grid;gap:8px;margin-top:38px}nav a{display:flex;align-items:center;min-height:44px;padding:10px 12px;border-radius:10px;text-decoration:none}nav a:hover,nav a.active{background:#ffffff2c}main{width:100%;max-width:960px;padding:clamp(22px,4vw,48px)}h1{margin:0;font-size:clamp(30px,5vw,48px);letter-spacing:-.04em}.subtitle{max-width:68ch;color:var(--muted)}.card{margin-top:26px;padding:22px;border:1px solid var(--line);border-radius:18px;background:var(--card);box-shadow:0 10px 28px #243a6210}.meta{display:grid;grid-template-columns:150px minmax(0,1fr);gap:12px;margin:18px 0 0}.meta dt{color:var(--muted)}.meta dd{margin:0;overflow-wrap:anywhere}.pills{display:flex;flex-wrap:wrap;gap:8px}.pill{display:inline-flex;min-height:28px;align-items:center;padding:3px 9px;border:1px solid #b9d7ef;border-radius:999px;color:#155b92;background:#f0f8ff;font-size:12px;font-weight:700}.state{min-height:24px;margin:16px 0 0;color:var(--muted)}.state.error{color:var(--danger)}form{display:grid;gap:13px;margin-top:18px;max-width:520px}label{display:grid;gap:6px;color:var(--muted);font-size:14px;font-weight:700}input{min-height:44px;padding:10px 11px;border:1px solid #b9c9dd;border-radius:10px;color:var(--ink);background:#fff;font:inherit}input:focus{border-color:var(--focus);outline:0;box-shadow:0 0 0 3px #1570ef22}button{min-height:44px;margin-top:22px;padding:10px 16px;border:1px solid #d49b96;border-radius:11px;color:#9d1b14;background:#fff;font:inherit;font-weight:700;cursor:pointer}button:hover{background:#fff4f2}button:disabled{opacity:.5;cursor:not-allowed}.password-submit{justify-self:start;margin-top:0;border-color:#b9c9dd;color:var(--blue)}.password-submit:hover{background:#f3f8fd}@media(max-width:720px){.shell{display:block}aside{padding:16px 18px}nav{display:flex;overflow:auto;margin-top:14px}nav a{flex:none}main{padding:24px 18px}.meta{grid-template-columns:1fr;gap:3px}.password-submit{width:100%}}@media(prefers-reduced-motion:reduce){*{transition-duration:.01ms!important}}
    """

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
          pill.className = 'pill';
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
          if (!response.ok) throw new Error('账户资料暂时不可用');
          const data = await response.json();
          if (typeof data.username !== 'string' || typeof data.displayName !== 'string') throw new Error('账户资料格式无效');
          byID('display-name').textContent = data.displayName;
          byID('username').textContent = `@${data.username}`;
          appendPills('roles', data.roleIDs, '未分配角色');
          appendPills('permissions', data.permissionIDs, '当前没有额外权限');
          profile.hidden = false;
          profileState.textContent = '账户资料已更新。';
        } catch (error) {
          profileState.classList.add('error');
          profileState.textContent = error && error.message ? error.message : '无法读取账户资料。';
        }
      }
      logoutButton.addEventListener('click', async () => {
        if (!window.confirm('确定要退出当前账户吗？')) return;
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { logoutState.classList.add('error'); logoutState.textContent = '页面安全令牌不可用，请刷新后重试。'; return; }
        logoutButton.disabled = true;
        logoutState.classList.remove('error');
        logoutState.textContent = '正在退出…';
        try {
          const response = await fetch('/api/v1/auth/logout', { method: 'POST', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token } });
          if (response.status === 401 || response.status === 204) { window.location.assign('/login'); return; }
          throw new Error(response.status === 429 ? '操作过于频繁，请稍后重试。' : '暂时无法退出当前账户。');
        } catch (error) {
          logoutState.classList.add('error');
          logoutState.textContent = error && error.message ? error.message : '退出失败，请稍后重试。';
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
          passwordState.textContent = newPassword.length < 12 ? '新密码至少需要 12 个字符。' : '两次输入的新密码不一致。';
          return;
        }
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { passwordState.classList.add('error'); passwordState.textContent = '页面安全令牌不可用，请刷新后重试。'; return; }
        passwordSubmit.disabled = true;
        passwordState.classList.remove('error');
        passwordState.textContent = '正在更新密码并撤销旧会话…';
        try {
          const response = await fetch('/api/v1/auth/password', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': token },
            body: JSON.stringify({ currentPassword, newPassword })
          });
          if (response.status === 401 || response.status === 204) { window.location.assign('/login'); return; }
          throw new Error(response.status === 429 ? '操作过于频繁，请稍后重试。' : '无法修改密码，请检查当前密码后重试。');
        } catch (error) {
          passwordState.classList.add('error');
          passwordState.textContent = error && error.message ? error.message : '无法修改密码，请稍后重试。';
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

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
