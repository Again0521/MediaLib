import Foundation

enum ServerWebLoginPage {
    static func render(serverName: String, csrfToken: String, returnState: String?) -> String {
        let action = returnState.map { "/login?next=\($0)" } ?? "/login"
        let content = """
        <main class="login-stage">
          <form class="login-card" id="login-form" action="\(action)" method="post">
            <div class="login-brand">
              <span class="ui-icon-tile ui-icon-tile-sm ui-icon-tile-brand login-mark" aria-hidden="true">\(ServerWebIcon.play.html(size: .sm))</span>
              <span>MediaLIB</span>
            </div>
            <h1 class="t-title-1">登录服务端</h1>
            <p class="login-server t-callout t-tertiary">\(ServerWebHTML.escape(serverName))</p>
            <input type="hidden" name="csrf" value="\(ServerWebHTML.escape(csrfToken))">
            <div class="ui-field">
              <label class="ui-label" for="username">用户名</label>
              <input class="ui-input" id="username" name="username" autocomplete="username" maxlength="64" required>
            </div>
            <div class="ui-field">
              <label class="ui-label" for="password">密码</label>
              <input class="ui-input" id="password" name="password" type="password" autocomplete="current-password" maxlength="1024" required>
            </div>
            \(ServerWebUI.button("登录", variant: .primary, size: .large, id: "submit", type: "submit", extraClass: "ui-btn-block"))
            <p id="status" class="ui-state-line login-status" role="alert" aria-live="polite"></p>
            <p class="login-footnote t-caption t-tertiary">会话使用 HttpOnly、Secure、SameSite=Strict Cookie；密码不会写入 URL、日志或浏览器存储。</p>
          </form>
        </main>
        """
        return ServerWebDocument.standalone(
            title: "登录",
            serverName: serverName,
            csrfToken: csrfToken,
            content: content,
            pageStylesheets: ["/assets/login.css"],
            pageScripts: ["/assets/login.js"],
            bodyClass: "login-document",
            tint: .neutral
        )
    }

    /// Public but data-free login presentation. Credentials and CSRF remain in the
    /// non-cacheable page/form flow and are never serialized into this stylesheet.
    static let style = #"""
    /* Sign-in owns the viewport, so the ambient field is centred behind a single
       floating card rather than sitting behind an app frame. */
    .login-document { display: grid; min-height: 100dvh; place-items: center; padding: var(--space-6); }

    /* 这一页的背景**就是**它的设计。
       全局那层环境光（base.css 的 `body::before`）是给内容页用的：那里有整墙封面
       在供色，纱一浓就打架，所以两朵光晕都压在 5%–11%。登录页什么都没有——一张
       420px 的卡片浮在一片空白上，那层纱在这里等于不存在。注释里写着"ambient
       field is centred behind a single floating card"，而读者看到的是一张灰卡。

       这一层用识别色的三个色相各铺一朵，浓度抬到能看见但仍然读作"光"而不是"图"。
       **静态**——设计文档 §2 把呼吸、漂浮、循环渐变列为注意力税，一页登录界面上
       更是如此。玻璃卡自己有 40px 模糊，字始终坐在它上面，对比度不受影响。 */
    .login-document::after {
      content: "";
      position: fixed;
      z-index: -1;
      inset: 0;
      pointer-events: none;
      background:
        radial-gradient(62vw 58vh at 12% 6%, var(--tint-video-subtle-hover), transparent 64%),
        radial-gradient(54vw 52vh at 88% 12%, var(--tint-music-subtle-hover), transparent 62%),
        radial-gradient(70vw 60vh at 62% 104%, var(--tint-photo-subtle), transparent 66%);
    }
    .login-stage { width: min(100%, 420px); }
    .login-card {
      display: grid;
      gap: var(--space-4);
      padding: var(--space-8) var(--space-7) var(--space-6);
      border: var(--hairline) solid var(--glass-thick-border);
      border-radius: var(--radius-xl);
      background: var(--glass-thick-bg);
      -webkit-backdrop-filter: var(--glass-thick-blur);
      backdrop-filter: var(--glass-thick-blur);
      box-shadow: var(--glass-thick-highlight), var(--shadow-4);
    }
    .login-brand {
      display: flex;
      align-items: center;
      gap: var(--space-3);
      font-size: var(--type-headline-size);
      font-weight: var(--weight-bold);
      letter-spacing: -0.01em;
    }
    /* 几何与材质来自 `.ui-icon-tile-sm` + `.ui-icon-tile-brand`：登录页和侧栏
       的品牌标此前是两份一模一样却各自维护的规则。 */
    .login-mark > svg { width: 18px; height: 18px; }
    .login-card h1 { margin-top: var(--space-2); }
    .login-server { margin-top: calc(var(--space-4) * -1); overflow-wrap: anywhere; }
    /* Reserved height so an error message does not shove the button downward as
       it appears. */
    /* 登录失败是这一页唯一的状态，所以它常驻红色；高度与其余七处一样来自 `.ui-state-line`。 */
    .login-status { color: var(--error); }
    .login-footnote { padding-top: var(--space-4); border-top: var(--hairline) solid var(--divider); line-height: 1.6; }
    """#

    static let script = """
    (() => {
      'use strict';
      const form = document.getElementById('login-form');
      const submit = document.getElementById('submit');
      const status = document.getElementById('status');
      const csrf = document.querySelector('meta[name="medialib-csrf-token"]').content;
      const safeReturnPath = (() => {
        const state = new URLSearchParams(window.location.search).get('next') || '';
        if (!/^[A-Za-z0-9_-]{1,2732}$/.test(state)) return '/';
        let value;
        try {
          const padded = state.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - state.length % 4) % 4);
          value = new TextDecoder().decode(Uint8Array.from(atob(padded), character => character.charCodeAt(0)));
        } catch (_) { return '/'; }
        // Never make the login page an open redirect, even if a bookmark or an
        // intermediary modifies the query. Backslashes are excluded because
        // browsers can normalize them into a protocol-relative URL.
        return value.startsWith('/') && !value.startsWith('//') && !value.includes('\\\\') ? value : '/';
      })();
      // 访问 Cookie 的生命周期有意保持较短。若用户因过期访问令牌、服务端
      // 重启或硬刷新落在此页，仍可利用仅发送给认证端点的 HttpOnly 刷新
      // Cookie 无感恢复；脚本永远不会读取或持久化任何 token。
      const restoreBrowserSession = async () => {
        try {
          const response = await fetch('/api/v1/auth/refresh', {
            method: 'POST',
            credentials: 'same-origin',
            cache: 'no-store',
            headers: { Accept: 'application/json', 'X-MediaLIB-CSRF': csrf }
          });
          if (response.ok) { location.replace(safeReturnPath); return; }
        } catch (_) {
          // Offline / expired sessions intentionally leave the normal form
          // available. Do not reveal which credential condition failed.
        }
        status.textContent = '';
      };
      // 首屏那一瞬间正在做的是"看看这台浏览器上还有没有有效会话"，不是登录。
      // 写「正在登录…」会让人以为自己已经在登录流程里——尤其是它随后又变回空白。
      // 这条状态区留给真正的失败信息（红色常驻），静默续期不占用它。
      void restoreBrowserSession();
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
          if (response.ok) { location.replace(safeReturnPath); return; }
          if (response.status === 428) status.textContent = '请先在 Mac 上的 MediaLIB 里设置好密码。';
          else if (response.status === 429) status.textContent = '试得太频繁了，等一会儿再试。';
          else status.textContent = '用户名或密码不正确。';
        } catch (_) {
          status.textContent = '连不上 MediaLIB。检查一下 Mac 是否开着。';
        } finally {
          submit.disabled = false;
        }
      });
    })();
    """

    /// Delegates to the shared implementation in `ServerWebHTML`.
    ///
    /// Every page used to carry a private copy of this function — eighteen of
    /// them — which meant eighteen places to audit and eighteen chances for one
    /// to drift.  The local name is kept so the hundreds of call sites in this
    /// file stay readable.
    private static func escape(_ value: String) -> String { ServerWebHTML.escape(value) }
}
