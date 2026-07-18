import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 认证 Web 首页：复用文档站的浅色蓝色视觉语言，但完全由当前服务端 DTO 驱动。
/// 不引用本地媒体路径、封面文件或外部 CDN，因此可安全随服务端二进制分发。
enum ServerWebHomePage {
    static func render(
        serverName: String,
        snapshot: ServerLibrarySnapshot,
        csrfToken: String,
        showAdministration: Bool = false
    ) -> String {
        let categories = MediaType.allCases.compactMap { type -> ServerLibraryCategory? in
            guard type != .privateCollection,
                  type != .auto,
                  let count = snapshot.summary.countsByType[type.rawValue],
                  count > 0
            else { return nil }
            return ServerLibraryCategory(id: type.rawValue, title: type.displayName, itemCount: count)
        }
        let summaryCards = categories.compactMap { category -> String? in
            guard let encodedID = ServerWebURL.queryValue(category.id) else { return nil }
            return """
                <a class="summary-card" href="/library?type=\(encodedID)" aria-label="浏览\(escape(category.title))分类，共 \(category.itemCount) 项">
                  <span>\(escape(category.title))</span>
                  <strong>\(category.itemCount)</strong>
                  <small>浏览分类</small>
                </a>
                """
            }
            .joined(separator: "\n")

        let mediaCards = snapshot.items.items.map { item in
            let year = item.year.map(String.init) ?? "未标注年份"
            let artworkState = item.artworkAvailable ? "已索引封面" : "无封面"
            let playbackState: String = {
                guard let state = item.userState else { return "" }
                if state.isWatched { return "<small class=\"playback-state\">已看完</small>" }
                guard state.progress > 0 else { return "" }
                let percent = Int((state.progress * 100).rounded())
                return "<small class=\"playback-state\">继续观看 · \(percent)%</small><progress max=\"100\" value=\"\(percent)\" aria-label=\"已播放 \(percent)%\"></progress>"
            }()
            let posterContent: String
            if item.artworkAvailable, let encodedID = ServerWebURL.pathSegment(item.id) {
                posterContent = "<div class=\"poster\"><img src=\"/api/v1/images/\(encodedID)/poster\" alt=\"\" loading=\"lazy\" decoding=\"async\"></div>"
            } else {
                posterContent = "<div class=\"poster\" role=\"img\" aria-label=\"\(escape(item.type)) 占位封面\"><span>\(escape(String(item.type.prefix(1)).uppercased()))</span></div>"
            }
            let content = """
              \(posterContent)
              <div class="card-copy">
                <h2 title="\(escape(item.title))">\(escape(item.title))</h2>
                <p>\(escape(item.type)) · \(escape(year))</p>
                <small>\(artworkState)</small>\(playbackState)
              </div>
            """
            let linkedContent = ServerWebURL.pathSegment(item.id).map {
                let destination = item.isSeries ? "/series/\($0)" : "/item/\($0)"
                let action = item.isSeries ? "查看系列" : "查看并播放"
                return "<a class=\"card-link\" href=\"\(destination)\" aria-label=\"\(action) \(escape(item.title))\">\(content)</a>"
            } ?? content
            return """
            <article class="media-card">
              <span class="mlink">Mlink</span>
              \(linkedContent)
            </article>
            """
        }.joined(separator: "\n")

        let cards = mediaCards.isEmpty
            ? "<p class=\"empty\">资料库还没有可公开预览的内容。请先在桌面端添加并扫描媒体源。</p>"
            : mediaCards
        let summary = summaryCards.isEmpty
            ? "<p class=\"empty\">暂无分类统计。</p>"
            : summaryCards
        let sidebar = ServerWebNavigation.render(
            active: .home,
            showAdministration: showAdministration,
            note: .library,
            categories: categories
        )

        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>\(escape(serverName)) · MediaLIB</title>
          <link rel="stylesheet" href="/assets/home.css">
          <link rel="stylesheet" href="/assets/app-shell.css">
        </head>
        <body>
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">
            \(sidebar)
            <main id="main" tabindex="-1">
              <div class="topline"><div><h1>\(escape(serverName))</h1><p class="subtitle">本机资料库预览 · \(snapshot.summary.totalItemCount) 项可见媒体</p></div><span class="badge">本机服务</span></div>
              <section><h2 class="section-title">资料库分类</h2><div class="summary-grid">\(summary)</div></section>
              <section><h2 class="section-title">最近索引的内容</h2><div class="media-grid">\(cards)</div></section>
              <footer>认证资料库 · API: <code>/api/v1/library/items</code></footer>
            </main>
          </div>
        </body>
        </html>
        """
    }

    /// Fixed homepage presentation only. Runtime media and account information must
    /// remain in the authenticated HTML/API response rather than this cacheable sheet.
    static let style = """
    :root { --blue:#2e90fa; --sky:#36bffa; --ink:#1b2230; --muted:#68758a; --line:#e6ebf3; --canvas:#f5f8fc; --card:#fff; }
    * { box-sizing:border-box; } body { margin:0; color:var(--ink); background:var(--canvas); font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; } :focus-visible { outline:3px solid #1570ef; outline-offset:3px; }
    .skip { position:fixed; z-index:1000; top:8px; left:8px; padding:10px 14px; border-radius:9px; color:#fff; background:#174d82; transform:translateY(-160%); } .skip:focus { transform:none; }
    .shell { display:grid; grid-template-columns:258px minmax(0,1fr); min-height:100dvh; }
    aside { padding:26px 16px; color:var(--ink); background:#fbfcfe; border-right:1px solid #e9edf4; }
    .brand { display:flex; gap:10px; align-items:center; font-weight:850; letter-spacing:-.02em; font-size:19px; }
    .brand-mark { display:grid; place-items:center; width:34px; height:34px; border-radius:10px; color:#fff; background:linear-gradient(135deg,#2e90fa,#36bffa); box-shadow:0 7px 16px #2e90fa35; }
    nav { display:grid; gap:5px; margin-top:34px; } nav a { display:flex; align-items:center; min-height:44px; padding:10px 12px; border:1px solid transparent; border-radius:10px; color:#516174; text-decoration:none; font-size:14px; font-weight:650; } nav a:hover { color:#0f172a; background:#f1f5fa; } nav a.active { border-color:#dbeafe; color:#0f3d71; background:linear-gradient(110deg,#eaf4ff,#f8fbff); font-weight:800; }
    .phase { margin-top:28px; padding:13px; border:1px solid var(--line); border-radius:14px; color:var(--muted); background:#fff; box-shadow:0 8px 20px #243a6208; font-size:12px; line-height:1.55; }
    main { padding:clamp(22px,4vw,48px); background:radial-gradient(circle at 86% -15%,#dff3ff 0,transparent 31%),var(--canvas); } .topline { display:flex; gap:16px; align-items:flex-start; justify-content:space-between; }
    h1 { margin:0; font-size:clamp(26px,4vw,40px); letter-spacing:-.04em; } .subtitle { margin:9px 0 0; color:var(--muted); }
    .badge { flex:none; padding:8px 11px; border-radius:999px; color:#1673c9; background:#e5f4ff; font-size:12px; font-weight:700; }
    section { margin-top:34px; } .section-title { margin:0 0 14px; font-size:17px; }
    .summary-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(132px,1fr)); gap:12px; }
    .summary-card,.media-card { border:1px solid var(--line); background:var(--card); box-shadow:0 10px 28px #243a6210; }
    .summary-card { display:block; min-height:112px; padding:16px; border-radius:15px; color:inherit; text-decoration:none; transition:border-color .18s ease,background-color .18s ease; } .summary-card:hover { border-color:#9bc7f1; background:#f7fbff; } .summary-card span { display:block; color:var(--muted); font-size:13px; } .summary-card strong { display:block; margin-top:8px; font-size:27px; } .summary-card small { display:block; margin-top:2px; color:#236fb5; font-size:12px; font-weight:700; }
    .media-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(164px,1fr)); gap:16px; } .media-card { position:relative; overflow:hidden; border-radius:16px; } .mlink { position:absolute; z-index:10; top:9px; left:9px; padding:4px 7px; border-radius:7px; color:#fff; background:#123b68e8; box-shadow:0 3px 10px #0c274555; font-size:11px; font-weight:800; letter-spacing:.03em; } .card-link { display:block; min-height:100%; color:inherit; text-decoration:none; transition:background-color .18s ease; } .card-link:hover { background:#f5faff; }
    .poster { display:grid; overflow:hidden; aspect-ratio:2/3; place-items:center; color:#fff; background:linear-gradient(145deg,#236dbb,#36bffa 56%,#9ae2ff); font-size:48px; font-weight:800; } .poster span { text-shadow:0 4px 12px #0c376755; } .poster img { width:100%; height:100%; object-fit:cover; }
    .card-copy { padding:12px; } .card-copy h2 { overflow:hidden; margin:0; font-size:14px; line-height:1.35; text-overflow:ellipsis; white-space:nowrap; } .card-copy p,.card-copy small { display:block; margin:6px 0 0; color:var(--muted); font-size:12px; } .card-copy small { color:#2180d5; } .card-copy .playback-state { color:#087a55; font-weight:700; } .card-copy progress { display:block; width:100%; height:6px; margin-top:5px; accent-color:#087f5b; }
    .empty { padding:20px; border:1px dashed #c7d4e5; border-radius:14px; color:var(--muted); background:#ffffffa8; }
    footer { margin-top:42px; color:var(--muted); font-size:12px; } code { padding:2px 5px; border-radius:5px; background:#eaf1f9; }
    @media (max-width:720px) { .shell { display:block; } aside { min-height:auto; padding:16px 20px; } nav { display:flex; overflow:auto; gap:8px; margin-top:14px; } nav a { flex:none; } .phase { display:none; } main { padding:24px 18px 36px; } .topline { display:block; } .badge { display:inline-block; margin-top:14px; } .media-grid { grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px; } .poster { min-height:164px; } }
    @media (prefers-reduced-motion:reduce) { *,*::before,*::after { transition-duration:.01ms!important; } }
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
