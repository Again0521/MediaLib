import Foundation
import MediaLibServerProtocol

/// 网页端的保险库锁屏。
///
/// 解锁**只**发生在 Mac 上的 App 里：口令与 Touch ID 由系统钥匙串保护，一个字节
/// 都不会过网。这一页因此从不接收口令，它只呈现两种"进不去"的原因：
///
/// * `.locked` —— 这台机器上的 App 现在锁着。去 App 里解锁，这一页就会有内容。
/// * `.notGranted` —— 账号没有被授权那个保险库资料库。这是管理员的一个明确动作，
///   不是解锁能解决的事，所以措辞必须分开——否则读者会一直去解锁一个已经解锁的
///   保险库，然后以为是坏了。
///
/// 解锁且已授权时读者根本不会走到这里：路由改用 `ServerWebLibraryPage` 的保险库
/// 作用域，内容与其它资料库页面同一套渲染与授权。
enum ServerWebVaultPage {
    enum Reason {
        case locked
        case notGranted
    }

    static func render(
        serverName: String,
        showAdministration: Bool,
        reason: Reason = .locked,
        categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras
    ) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .vault,
            showAdministration: showAdministration,
            note: .security,
            categories: categories,
            extras: sidebarExtras
        )
        let heading = reason == .locked ? "保险库已锁定" : "这个账号没有保险库权限"
        let explanation = reason == .locked
            ? "私密内容、路径与文件名均已隐藏。网页端不会请求或接收保险库口令；请在这台 Mac 的 App 里用 Touch ID 或密码解锁，解锁后刷新本页即可浏览。"
            : "保险库需要管理员在 App 的用户设置里单独授权。即使这台 Mac 上的保险库已解锁，未被授权的账号也看不到它的内容。"
        let content = """
        \(ServerWebPageHeader.render(
            icon: .vault,
            eyebrow: "Vault",
            title: "保险库",
            subtitle: reason == .locked ? "私密内容需要在 Mac 上的 App 里解锁。" : "私密内容需要单独授权。"
        ))
        <section class="vault-lock" aria-labelledby="vault-title">
          <span class="ui-icon-tile ui-icon-tile-lg ui-icon-tile-brand vault-lock-icon" aria-hidden="true">\(ServerWebIcon.render(.vault, size: .xl, variant: .duotone))</span>
          <h2 id="vault-title" class="t-title-1">\(ServerWebHTML.escape(heading))</h2>
          <p class="t-callout">\(ServerWebHTML.escape(explanation))</p>
          <!-- 这里从前画着六个"密码点"。它们是纯装饰——没有输入框、没有监听，网页
               端按设计根本不接收口令（口令过网就等于把保险库的钥匙交出去了）。可是
               它长得就像一个可以敲字的地方，于是读者会一直试着在这里输入密码，然后
               以为是坏了。看起来能用却不能用，比没有更糟，所以把它删掉。 -->
          \(ServerWebUI.linkButton("前往设置", href: "/account", variant: .primary, icon: .settings))
        </section>
        """
        return ServerWebDocument.render(
            title: "保险库",
            serverName: serverName,
            csrfToken: nil,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/vault.css"],
            bodyClass: "vault-system-page",
            tint: .vault
        )
    }

    /// The lock screen is one of the few places that keeps a fixed dark treatment
    /// in both appearances: it is a security surface, and a light rendition would
    /// read as an ordinary page rather than a boundary.
    static let style = #"""
    .vault-system-page .app-main {
      display: grid;
      align-content: start;
      justify-items: center;
    }
    .vault-lock {
      display: flex;
      max-width: 460px;
      flex-direction: column;
      align-items: center;
      gap: var(--space-4);
      margin-top: var(--space-9);
      padding: var(--space-10) var(--space-7);
      border: var(--hairline) solid var(--glass-thick-border);
      border-radius: var(--radius-xl);
      color: var(--text-primary);
      background: var(--glass-thick-bg);
      -webkit-backdrop-filter: var(--glass-thick-blur);
      backdrop-filter: var(--glass-thick-blur);
      box-shadow: var(--glass-thick-highlight), var(--shadow-4);
      text-align: center;
    }
    /* 保险库的锁标是全站最大的一枚底板，所以它只在 `.ui-icon-tile-brand` 之上
       加尺寸——材质、圆角、内高光仍然是同一套。 */
    .vault-lock-icon {
      width: 72px;
      height: 72px;
      border-radius: var(--radius-lg);
      box-shadow: var(--inner-highlight-strong), var(--shadow-3);
    }
    .vault-lock-icon > svg { width: var(--icon-xl); height: var(--icon-xl); }
    .vault-lock p { max-width: 42ch; color: var(--text-secondary); }
    """#
}
