import Foundation

/// Escaping and URL helpers shared by every server-rendered page.
///
/// This used to be a private copy inside each of the eighteen page files.  One
/// implementation means one place to audit, and no risk of a page quietly
/// shipping a weaker version.
enum ServerWebHTML {
    /// Escapes a value for interpolation into element content or a quoted
    /// attribute.  Both quote forms are escaped so the same function is safe in
    /// either position.
    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Renders `name="value"` with the value escaped, or nothing when the value is
    /// absent — so call sites stop hand-assembling conditional attribute strings.
    static func attribute(_ name: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return " \(name)=\"\(escape(value))\""
    }

    /// Renders a boolean attribute only when it is on.
    static func flag(_ name: String, _ enabled: Bool) -> String {
        enabled ? " \(name)" : ""
    }
}

/// Central registry for the browser-facing static assets.
///
/// A single version number governs every stylesheet and script.  The previous
/// scheme kept a per-file counter that had to be bumped by hand, so nine assets
/// shipped with no version at all and stayed stale in the browser for five
/// minutes after every change, while others drifted out of step with the tests
/// that asserted on them.
enum ServerWebAssets {
    /// Bumped by `bump_versions.py` whenever any web asset changes. The query
    /// is a cache identity, so static CSS/JS may safely be immutable for a year.
    static let version = 231

    /// Loaded by every authenticated page, in this order.  Cascade layers make the
    /// order meaningful without a single `!important`: tokens define values, base
    /// dresses bare elements, primitives supply components, the shell positions
    /// them, and an unlayered page stylesheet refines the result.
    static let coreStylesheets = [
        "/assets/tokens.css",
        "/assets/base.css",
        "/assets/primitives.css",
        "/assets/app-shell.css"
    ]

    static func url(_ path: String) -> String {
        "\(path)?v=\(version)"
    }
}

/// The one page skeleton.
///
/// Seventeen page files each carried their own `<!doctype html>` block, which is
/// how the product ended up with inconsistent stylesheet ordering, seven pages
/// pinning `color-scheme: light`, and a viewport tag that ignored the display
/// cutout.  Everything structural now lives here; pages contribute only their
/// own assets and their main content.
enum ServerWebDocument {
    /// A full authenticated page: sidebar, content canvas, mobile navigation.
    static func render(
        title: String,
        serverName: String,
        csrfToken: String?,
        sidebar: String,
        content: String,
        pageStylesheets: [String] = [],
        pageScripts: [String] = [],
        preloadedImages: [String] = [],
        bodyClass: String? = nil,
        bodyAttributes: String = "",
        tint: ServerWebIcon.Tint? = nil
    ) -> String {
        let body = """
        <a class="skip" href="#main">跳到主要内容</a>\
        <div class="shell">\(sidebar)<main id="main" class="app-main" tabindex="-1">\(content)</main></div>\
        <div id="ui-toast-region" class="ui-toast-region" role="status" aria-live="polite" aria-atomic="false"></div>
        """
        return shell(
            title: title,
            serverName: serverName,
            csrfToken: csrfToken,
            stylesheets: ServerWebAssets.coreStylesheets + pageStylesheets,
            scripts: ["/assets/app-shell.js"] + pageScripts,
            preloadedImages: preloadedImages,
            bodyClass: bodyClass,
            bodyAttributes: bodyAttributes + (tint?.attribute ?? ""),
            body: body
        )
    }

    /// A page that owns the whole viewport and has no app chrome — sign-in and the
    /// immersive player.  It still gets the tokens, so it is themed identically.
    static func standalone(
        title: String,
        serverName: String,
        csrfToken: String?,
        content: String,
        pageStylesheets: [String] = [],
        pageScripts: [String] = [],
        includeShellScript: Bool = false,
        bodyClass: String? = nil,
        bodyAttributes: String = "",
        tint: ServerWebIcon.Tint? = nil
    ) -> String {
        shell(
            title: title,
            serverName: serverName,
            csrfToken: csrfToken,
            stylesheets: [
                "/assets/tokens.css",
                "/assets/base.css",
                "/assets/primitives.css"
            ] + pageStylesheets,
            scripts: (includeShellScript ? ["/assets/app-shell.js"] : []) + pageScripts,
            bodyClass: bodyClass,
            bodyAttributes: bodyAttributes + (tint?.attribute ?? ""),
            body: content
        )
    }

    private static func shell(
        title: String,
        serverName: String,
        csrfToken: String?,
        stylesheets: [String],
        scripts: [String],
        preloadedImages: [String] = [],
        bodyClass: String?,
        bodyAttributes: String,
        body: String
    ) -> String {
        let documentTitle = ServerWebHTML.escape("\(title) · \(serverName)")
        let csrfMeta = csrfToken.map {
            #"<meta name="medialib-csrf-token" content="\#(ServerWebHTML.escape($0))">"#
        } ?? ""
        let links = stylesheets
            .map { #"<link rel="stylesheet" href="\#(ServerWebAssets.url($0))">"# }
            .joined()
        let tags = scripts
            .map { #"<script src="\#(ServerWebAssets.url($0))" defer></script>"# }
            .joined()
        let classAttribute = ServerWebHTML.attribute("class", bodyClass)
        // 一张放在 <body> 里的封面要等 CSS 解析完、布局跑起来才开始下载。页面上
        // 最大的那张图不该排在这个队伍后面：它是读者第一眼要看的东西。preload
        // 让它和样式表并行开始。仅限同源路径——CSP 的 img-src 是 'self' data:。
        let preloads = preloadedImages
            .filter { $0.hasPrefix("/") }
            .map { #"<link rel="preload" as="image" href="\#(ServerWebHTML.escape($0))" fetchpriority="high">"# }
            .joined()

        // `appearance.js` is deliberately render-blocking and first: it stamps the
        // stored light/dark choice onto <html> before the first paint, so an
        // explicit dark preference never flashes a white page.  The CSP forbids
        // inline scripts, so this cannot collapse into the document itself.
        return """
        <!doctype html><html lang="zh-Hans"><head>\
        <meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\
        <meta name="color-scheme" content="light dark">\
        <meta name="theme-color" content="#f6f8fb" media="(prefers-color-scheme: light)">\
        <meta name="theme-color" content="#12161c" media="(prefers-color-scheme: dark)">\
        \(csrfMeta)\
        <title>\(documentTitle)</title>\
        <script src="\(ServerWebAssets.url("/assets/appearance.js"))"></script>\
        \(preloads)\(links)\(tags)\
        </head><body\(classAttribute)\(bodyAttributes)>\(body)</body></html>
        """
    }
}
