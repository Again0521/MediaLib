import Foundation

enum ServerWebLoginPage {
    static func render(serverName: String, csrfToken: String) -> String {
        """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>登录 · \(escape(serverName))</title>
          <link rel="stylesheet" href="/assets/login.css">
          <link rel="stylesheet" href="/assets/app-shell.css">
          <script src="/assets/login.js" defer></script>
        </head>
        <body>
          <main>
            <div class="brand"><span class="mark">M</span><span>MediaLIB</span></div>
            <h1>登录服务端</h1>
            <p class="server">\(escape(serverName))</p>
            <form id="login-form">
              <label for="username">用户名</label>
              <input id="username" name="username" autocomplete="username" maxlength="64" required>
              <label for="password">密码</label>
              <input id="password" name="password" type="password" autocomplete="current-password" maxlength="1024" required>
              <button id="submit" type="submit">安全登录</button>
              <p id="status" role="alert" aria-live="polite"></p>
            </form>
            <footer>会话使用 HttpOnly、Secure、SameSite=Strict Cookie；密码不会写入 URL、日志或浏览器存储。</footer>
          </main>
        </body>
        </html>
        """
    }

    /// Public but data-free login presentation. Credentials and CSRF remain in the
    /// non-cacheable page/form flow and are never serialized into this stylesheet.
    static let style = """
    :root { --blue:#2e90fa; --ink:#172033; --muted:#68758a; --line:#dbe4f0; --danger:#c4324b; }
    * { box-sizing:border-box; } body { min-height:100vh; margin:0; display:grid; place-items:center; padding:24px; color:var(--ink); background:radial-gradient(circle at 15% 5%,#dff4ff,transparent 38%),linear-gradient(145deg,#f8fbff,#edf4fb); font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    main { width:min(100%,420px); padding:30px; border:1px solid #ffffff; border-radius:24px; background:#ffffffed; box-shadow:0 24px 70px #22568a24; }
    .brand { display:flex; align-items:center; gap:11px; font-weight:800; } .mark { display:grid; place-items:center; width:38px; height:38px; border-radius:12px; color:white; background:linear-gradient(145deg,#176dcc,#36bffa); }
    h1 { margin:26px 0 6px; font-size:28px; letter-spacing:-.03em; } .server { margin:0 0 24px; color:var(--muted); }
    label { display:block; margin-top:15px; font-size:13px; font-weight:700; } input { width:100%; margin-top:7px; padding:12px 13px; border:1px solid var(--line); border-radius:11px; color:inherit; background:#fff; font:inherit; } input:focus { outline:3px solid #2e90fa25; border-color:var(--blue); }
    button { width:100%; margin-top:22px; padding:12px 16px; border:0; border-radius:12px; color:#fff; background:linear-gradient(135deg,#1d78d3,#36bffa); font:inherit; font-weight:800; cursor:pointer; } button:disabled { opacity:.6; cursor:wait; }
    #status { min-height:20px; margin:14px 0 0; color:var(--danger); font-size:13px; line-height:1.5; } footer { margin-top:20px; color:var(--muted); font-size:11px; line-height:1.5; }
    """

    static let script = """
    (() => {
      'use strict';
      const form = document.getElementById('login-form');
      const submit = document.getElementById('submit');
      const status = document.getElementById('status');
      const csrf = document.querySelector('meta[name="medialib-csrf-token"]').content;
      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        submit.disabled = true;
        status.textContent = '';
        try {
          const response = await fetch('/api/v1/auth/login', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrf },
            body: JSON.stringify({
              username: form.username.value,
              password: form.password.value,
              deviceName: navigator.userAgentData?.platform || navigator.platform || 'Web Browser',
              platform: 'Web',
              delivery: 'cookie'
            })
          });
          form.password.value = '';
          if (response.ok) { location.replace('/'); return; }
          if (response.status === 428) status.textContent = '管理员尚未完成首次密码设置，请先在 MediaLIB 桌面端完成初始化。';
          else if (response.status === 429) status.textContent = '登录尝试过多，请稍后再试。';
          else status.textContent = '用户名或密码不正确。';
        } catch (_) {
          status.textContent = '无法连接到 MediaLIB 服务端。';
        } finally {
          submit.disabled = false;
        }
      });
    })();
    """

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
