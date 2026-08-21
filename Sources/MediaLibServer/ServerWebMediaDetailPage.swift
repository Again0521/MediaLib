import Foundation
import MediaLibServerProtocol

/// 认证媒体详情与 Web 播放页。所有数据库文本先做长度收敛并在此处 HTML 转义；
/// 播放器只接收媒体 ID 对应的同源 API URL，不接触本地路径或原始令牌。
enum ServerWebMediaDetailPage {
    /// - Parameter back: Where this page's back control points. The router
    ///   derives it from the request's referrer so the control returns the
    ///   reader to where they actually came from — the queue, a collection, a
    ///   person's credits, the series — rather than always to `/library`.
    static func render(
        serverName: String,
        detail: ServerMediaItemDetail,
        csrfToken: String,
        showAdministration: Bool,
        categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras,
        back: ServerWebBackNavigation.Target = .init(label: "返回首页", href: "/")
    ) -> String {
        let isMusic = detail.type.caseInsensitiveCompare("music") == .orderedSame
        let episodeContext = detail.episodeContext
        let isEpisode = episodeContext != nil
        let year = detail.year.map(String.init) ?? "年份未知"
        let runtime = detail.runtimeSeconds.map(formatDuration) ?? "片长未知"
        let rating = detail.communityRating.map { String(format: "%.1f / 10", $0) } ?? "暂无评分"
        let genres = detail.genres.isEmpty ? "未标注类型" : detail.genres.joined(separator: " · ")
        let overview = detail.overview ?? "暂无简介。"
        let sidebar = ServerWebNavigation.render(
            active: .library, showAdministration: showAdministration, note: .playback,
            categories: categories, extras: sidebarExtras
        )
        let canDirectPlay = detail.canDirectPlay ? "true" : "false"
        let directDisabled = detail.canDirectPlay ? "" : " disabled aria-disabled=\"true\""
        let sourceRecoveryControl = detail.canDirectPlay
            ? ""
            : ServerWebUI.button("重新检测媒体源", variant: .ghost, size: .small, icon: .refresh, id: "retry-source", extraClass: "ui-btn-on-media player-retry-source")
        let directPlayLabel: String
        if isMusic {
            directPlayLabel = detail.userState?.positionSeconds ?? 0 > 0 ? "继续播放音乐" : "播放音乐"
        } else {
            directPlayLabel = detail.userState?.positionSeconds ?? 0 > 0 ? "继续播放" : "播放"
        }
        let browserContentType = detail.browserContentType.map(escape) ?? ""
        let resumePosition = detail.userState?.positionSeconds ?? 0
        // 音乐由应用壳内固定底栏接管；视频在当前剧集详情页的嵌入式播放器中
        // 直接由浏览器解码。保留 /play 深链以兼容旧书签与网页全屏入口。
        let videoPlaybackURL: String = {
            guard let encodedID = ServerWebURL.pathSegment(detail.id) else { return "" }
            return "/play/\(encodedID)#play"
        }()
        let preferenceRating = detail.userPreference.rating.map { String(format: "%.1f", $0) } ?? "0"
        let preferenceRatingSummary = detail.userPreference.rating.map { String(format: "%.1f / 5", $0) } ?? "未评分"
        let selectedRating = detail.userPreference.rating ?? 0
        let ratingStars = (1...5).map { value in
            let isSelected = selectedRating >= Double(value) - 0.5
            return "<button class=\"rating-star\" type=\"button\" data-rating=\"\(value)\" aria-label=\"\(value) 星\" aria-pressed=\"\(isSelected)\">\(ServerWebIcon.starFilled.html(size: .md))</button>"
        }.joined()
        let technicalMetadata = [
            detail.resolution.map { ("分辨率", $0) },
            detail.videoCodec.map { ("视频", $0) },
            detail.audioCodec.map { ("音频", $0) }
        ].compactMap { $0 }.map { label, value in
            "<li><span>\(escape(label))</span><strong>\(escape(value))</strong></li>"
        }.joined()
        let clientDetailSections = clientDetailSections(for: detail)
        // 自动播放下一集需要一个同源目标；它作为文档属性传递，而不是画面上
        // 的一个按钮。
        let nextEpisodePathAttribute = detail.nextEpisode
            .flatMap { ServerWebURL.pathSegment($0.id) }
            .map { #" data-next-episode-path="/item/\#($0)""# } ?? ""
        let posterContent: String
        if detail.artworkAvailable, let encodedID = ServerWebURL.pathSegment(detail.id) {
            posterContent = "<div class=\"poster\"><img src=\"/api/v1/images/\(encodedID)/poster?size=640\" alt=\"\" loading=\"eager\" decoding=\"async\"></div>"
        } else {
            let palette = ServerWebArtworkPalette.token(for: detail.id, context: detail.type.lowercased() == "music" ? .music : .poster)
            posterContent = "<div class=\"poster\" data-artwork-palette=\"\(palette)\" role=\"img\" aria-label=\"\(escape(detail.title)) 的封面占位图\"><span class=\"poster-glyph\">\(escape(String(detail.type.prefix(1))))</span></div>"
        }
        // 这一栏说的是"这部作品是什么"，所以标题就该是作品名。从前这里硬写着
        // "简介"——一个每部片子都一样、什么也没告诉读者的词。看剧集时作品名是
        // 剧名（单集标题已经在页头和面包屑里了），其余情况就是条目自己的标题。
        let synopsisTitle = episodeContext?.seriesTitle ?? detail.title
        // 背景与画面前置图的公共来源。有剧照就用剧照，否则退回海报。
        let backdropKind = detail.backdropAvailable ? "backdrop" : "poster"
        let artworkBase = ServerWebURL.pathSegment(detail.id).flatMap { encodedID in
            (detail.backdropAvailable || detail.artworkAvailable) ? "/api/v1/images/\(encodedID)/\(backdropKind)" : nil
        }
        // 背景被 blur(56px) 糊过、再压到 0.28 不透明度，1024 和 320 在屏幕上根本
        // 分不出来——但前者要多下载十几倍的字节，而这正是首屏唯一挡在读者面前的
        // 东西。所以背景取最小的够用档，把带宽让给下面那张真正清晰显示的画面图。
        //
        // 这里从前写的是 size=1280。缩略图服务只认 160/320/640/1024
        //（ServerArtworkThumbnailer.supportedMaximumPixels），其余一律 400，
        // 于是"有剧照"的条目反而永远拿不到背景。
        let backdropURL = artworkBase.map { "\($0)?size=320" }
        // 画面前置图是清晰显示的，要另一档尺寸。
        let landingURL = artworkBase.map { "\($0)?size=1024" }
        let detailBackdrop = backdropURL.map {
            "<div class=\"detail-backdrop\" aria-hidden=\"true\"><img src=\"\($0)\" alt=\"\" decoding=\"async\" fetchpriority=\"high\"></div>"
        } ?? ""
        // 视频详情不再呈现一个尚未设置 source 的原生 <video controls>。
        // Chrome 会把这种预览误显示为灰色、不可播放的控制条，实际播放入口
        // 又是唯一的沉浸式网页播放器，极易让用户误判为播放失败。
        let videoLandingVisual = landingURL.map {
            "<img class=\"player-landing-art\" src=\"\($0)\" alt=\"\" loading=\"eager\" decoding=\"async\" fetchpriority=\"high\">"
        } ?? #"<span class="player-landing-placeholder" aria-hidden="true">\#(ServerWebIcon.play.html(size: .xl))</span>"#
        let adjacentEpisodeSelection = [
            detail.previousEpisode.map { episodeSelectionItem($0, position: "上一集") },
            "<div class=\"episode-choice current\" aria-current=\"page\"><span>正在观看</span><strong>\(escape(detail.title))</strong><small>\(escape(runtime))</small></div>",
            detail.nextEpisode.map { episodeSelectionItem($0, position: "下一集") }
        ].compactMap { $0 }.joined(separator: "")
        // 剧名 → 季集 → 本集，正是面包屑要表达的东西。从前它是一个塞满链接和
        // 分隔点的 `<h1>`：因为放在 `<h1>` 里，标题就无法交给会转义文本的共用页头，
        // 于是这一页只能自建标题块，而且它的 h1 比其它页面小一整档。
        let episodeBreadcrumb: [(label: String, href: String?)] = {
            guard let episodeContext else { return [] }
            let season = episodeContext.seasonNumber.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "未分季"
            let episode = episodeContext.episodeNumber.map { "第 \($0) 集" } ?? "剧集"
            // 剧集页已删除；剧名指向的是「继续看这部剧」，也就是播放解析路由。
            let seriesHref = ServerWebURL.pathSegment(episodeContext.seriesID).map { "/series/\($0)/play" }
            return [
                (label: episodeContext.seriesTitle, href: seriesHref),
                (label: "\(season) · \(episode)", href: nil),
                (label: detail.title, href: nil)
            ]
        }()
        let episodeDataAttributes: String = {
            guard let episodeContext else { return "" }
            let season = episodeContext.seasonNumber.map(String.init) ?? "unspecified"
            let episode = episodeContext.episodeNumber.map(String.init) ?? ""
            return " data-series-id=\"\(escape(episodeContext.seriesID))\" data-current-season=\"\(escape(season))\" data-current-episode=\"\(escape(episode))\""
        }()
        let seasonTabs: String = episodeContext?.seasons.map { season in
            let key = season.seasonNumber.map(String.init) ?? "unspecified"
            // 季标签后面不再缀集数。「第 1 季6」中间没有分隔，读起来像一个被截断
            // 的数字；集数在下面的剧集网格里本来就一目了然。
            return "<button class=\"episode-season-tab\" type=\"button\" data-season=\"\(escape(key))\" aria-pressed=\"false\">\(escape(season.title))</button>"
        }.joined() ?? ""
        // 播放器标记从前是一行三千多字符的字符串，末尾还挂着一整块「播放信息与
        // 轨道」面板——那块面板每次渲染又被下面的字符串手术切掉。既然它从来
        // 不会送到浏览器，就不该先生成再删除。
        let playerCardContent: String
        if isMusic, let encodedID = ServerWebURL.pathSegment(detail.id) {
            playerCardContent = """
            <section class="music-dock-prompt" aria-labelledby="player-heading">\(posterContent)<div><p>音乐播放</p><h2 id="player-heading">\(escape(detail.title))</h2><span>播放将在页面底栏持续进行，浏览资料库时不会中断。</span><button id="direct-play" class="primary start-play" type="button" data-music-play="\(encodedID)" data-music-title="\(escape(detail.title))" data-music-subtitle="\(escape(detail.originalTitle ?? genres))"\(directDisabled)>\(directPlayLabel)</button></div></section>
            """
        } else {
            playerCardContent = """
            <section class="player-card" aria-labelledby="player-heading">
              <h2 id="player-heading" class="visually-hidden">\(escape(detail.title)) 播放器</h2>
              <div id="player-stage" class="player-stage" tabindex="0" role="group" aria-label="\(escape(detail.title)) 播放器">
                <div id="player-landing" class="player-landing">\(videoLandingVisual)</div>
                <video id="player" hidden playsinline preload="metadata" aria-label="\(escape(detail.title)) 视频播放器"></video>
                <p id="player-status" class="visually-hidden" role="status" aria-live="polite"></p>
                <!-- 起播、缓冲、失败此前只有一条 sr-only 文本：画面上什么都不
                     显示，读者按下播放之后看到的是一个不动的黑框，分不清是在
                     缓冲还是已经坏了。这两块是同一条状态的可见形态。 -->
                <div id="player-busy" class="player-busy" aria-hidden="true" hidden><span class="ui-spinner"></span></div>
                <div id="player-error" class="player-error" role="alert" hidden>
                  <p id="player-error-message" class="player-error-message"></p>
                </div>
                <button id="direct-play" class="ui-btn ui-btn-on-media-strong start-play player-symbol-button" type="button" aria-label="\(escape(directPlayLabel))"\(directDisabled)>\(ServerWebIcon.play.html(size: .lg))<span class="visually-hidden">\(escape(directPlayLabel))</span></button>
                \(sourceRecoveryControl)
                <div id="shortcut-hint" class="player-shortcut-hint" aria-hidden="true" hidden><span>空格 播放/暂停</span><span>← → 快退/快进 5 秒</span><span>F 全屏</span><span>M 静音</span></div>
                <div id="transport-controls" class="transport-controls player-overlay-controls" aria-label="播放控制" hidden>
                  <input id="playback-seek" class="ui-range ui-range-on-media ui-range-scrub player-progress" type="range" min="0" max="0" value="0" step="0.1" aria-label="播放进度">
                  <div class="player-control-row">
                    <div class="player-control-group">
                      <button id="seek-backward" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="后退 10 秒" title="后退 10 秒">\(ServerWebIcon.rewind.html(size: .md))</button>
                      <button id="transport-play" class="ui-btn ui-btn-icon transport-primary player-btn" type="button" aria-label="播放"><span id="transport-play-icon">\(ServerWebIcon.play.html(size: .md))</span><span id="transport-pause-icon" hidden>\(ServerWebIcon.pause.html(size: .md))</span></button>
                      <button id="seek-forward" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="前进 10 秒" title="前进 10 秒">\(ServerWebIcon.fastForward.html(size: .md))</button>
                      <output id="playback-time" class="playback-time" aria-live="off">0:00 / --:--</output>
                    </div>
                    <div class="player-control-group player-control-group-end">
                      <div class="player-control-cluster player-volume-cluster player-hover-control" id="volume-cluster">
                        <button id="toggle-mute" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="静音" aria-pressed="false" title="静音"><span id="volume-on-icon">\(ServerWebIcon.volumeOn.html(size: .md))</span><span id="volume-off-icon" hidden>\(ServerWebIcon.volumeOff.html(size: .md))</span></button>
                        <div class="player-hover-popover volume-popover" id="volume-popover">
                          <output id="playback-volume-value" for="playback-volume">100%</output>
                          <label class="volume-control" for="playback-volume"><span class="visually-hidden">音量</span><input id="playback-volume" class="ui-range ui-range-on-media" type="range" min="0" max="1" step="0.05" value="1" orient="vertical"></label>
                        </div>
                      </div>
                      <div class="player-control-cluster">
                        <div class="player-hover-control speed-cluster" id="speed-cluster">
                          <button id="playback-speed-button" class="ui-btn ui-btn-icon player-btn speed-button" type="button" aria-label="播放速度" title="播放速度"><span id="playback-speed-value">1×</span></button>
                          <div class="player-hover-popover speed-popover" id="speed-popover">
                            <label class="speed-control" for="playback-speed"><span class="visually-hidden">播放速度</span><input id="playback-speed" class="ui-range ui-range-on-media speed-range" type="range" min="0" max="6" step="1" value="3" list="speed-ticks" aria-valuetext="1×"></label>
                            <datalist id="speed-ticks"><option value="0"></option><option value="1"></option><option value="2"></option><option value="3"></option><option value="4"></option><option value="5"></option><option value="6"></option></datalist>
                            <div class="speed-scale" aria-hidden="true"><span>0.5</span><span>1</span><span>1.5</span><span>2</span></div>
                          </div>
                        </div>
                        <details class="player-settings" id="subtitle-menu" hidden>
                          <summary class="ui-btn ui-btn-icon player-btn" aria-label="字幕" title="字幕">\(ServerWebIcon.subtitles.html(size: .md))</summary>
                          <div class="player-settings-panel player-track-panel" id="subtitle-panel" role="group" aria-label="字幕轨道"></div>
                        </details>
                        <details class="player-settings" id="audio-menu" hidden>
                          <summary class="ui-btn ui-btn-icon player-btn" aria-label="音轨" title="音轨">\(ServerWebIcon.volumeOn.html(size: .md))</summary>
                          <div class="player-settings-panel player-track-panel" id="audio-panel" role="group" aria-label="音频轨道"></div>
                        </details>
                      </div>
                      <div class="player-control-cluster">
                        <button id="picture-in-picture" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="画中画" title="画中画" hidden>\(ServerWebIcon.pictureInPicture.html(size: .md))</button>
                        <button id="default-size" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="默认尺寸" title="默认尺寸" aria-pressed="true" hidden>\(ServerWebIcon.display.html(size: .md))</button>
                        <button id="wide-size" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="宽屏模式" title="宽屏模式" aria-pressed="false">\(ServerWebIcon.sidebar.html(size: .md))</button>
                        <button id="web-fullscreen" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="网页全屏" title="网页全屏" aria-pressed="false">\(ServerWebIcon.fullscreen.html(size: .md))</button>
                        <button id="fullscreen" class="ui-btn ui-btn-icon player-btn" type="button" aria-label="全屏" title="全屏" hidden><span id="fullscreen-enter-icon">\(ServerWebIcon.fullscreen.html(size: .md))</span><span id="fullscreen-exit-icon" hidden>\(ServerWebIcon.fullscreenExit.html(size: .md))</span></button>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>
            """
        }
        let selectionPanel: String
        if isMusic {
            selectionPanel = ""
        } else if let episodeContext {
            selectionPanel = """
            <aside id="episode-panel" class="episode-panel episode-browser" aria-label="选集" data-series-id="\(escape(episodeContext.seriesID))"><div id="episode-season-tabs" class="episode-season-tabs" aria-label="季选择">\(seasonTabs)</div><p id="episode-grid-status" class="ui-state-line episode-grid-status" role="status" aria-live="polite">正在准备选集…</p><div id="episode-grid" class="episode-number-grid" aria-label="剧集列表"></div>\(ServerWebUI.button("加载更多剧集", variant: .secondary, size: .small, icon: .chevronDown, id: "episode-load-more", attributes: " hidden"))</aside>
            """
        } else {
            selectionPanel = """
            <aside class="episode-panel" aria-label="选集"><div class="episode-choices">\(adjacentEpisodeSelection)</div></aside>
            """
        }

        let content = """
          \(detailBackdrop)
          \(ServerWebPageHeader.render(
              icon: isMusic ? .music : .library,
              eyebrow: "\(detail.type) · \(year)",
              title: detail.title,
              subtitle: detail.originalTitle.flatMap { $0 == detail.title ? nil : $0 } ?? "",
              breadcrumb: episodeBreadcrumb,
              back: (label: back.label, href: back.href),
              actions: ServerWebUI.button("加入队列", variant: .secondary, icon: .queue, id: "add-to-queue")
                  + ServerWebUI.button(
                      detail.userPreference.isFavorite ? "已收藏" : "收藏",
                      variant: detail.userPreference.isFavorite ? .tinted : .secondary,
                      icon: detail.userPreference.isFavorite ? .heartFilled : .heart,
                      id: "toggle-favorite",
                      attributes: #" aria-pressed="\#(detail.userPreference.isFavorite ? "true" : "false")""#
                  )
                  + ServerWebUI.button(
                      detail.userPreference.isWatchlist ? "已加入想看" : "加入想看",
                      variant: detail.userPreference.isWatchlist ? .tinted : .secondary,
                      icon: detail.userPreference.isWatchlist ? .bookmarkFilled : .bookmark,
                      id: "toggle-watchlist",
                      attributes: #" aria-pressed="\#(detail.userPreference.isWatchlist ? "true" : "false")""#
                  ),
              titleID: "item-title"
          ))
          <div id="player-workspace" class="watch-layout\(isEpisode ? " is-episode-workspace" : "")"><div class="watch-main">\(playerCardContent)</div>\(selectionPanel)</div>
          <section class="detail-info">
            <div class="synopsis">\(posterContent)
              <div class="synopsis-copy">
                <p class="app-eyebrow">\(isEpisode ? "剧集详情" : "简介")</p>
                <h2 class="t-title-2 synopsis-title">\(escape(synopsisTitle))</h2>
                <ul class="facts">\(detailFacts(detail, runtime: runtime, rating: rating, genres: genres))</ul>
                <p class="overview t-body t-clamp">\(escape(overview))</p>
                <div class="detail-utility-inline">
                  <div class="detail-rating">
                    <span class="detail-utility-label">我的评分</span>
                    <div id="user-rating" class="rating-stars" role="group" aria-label="我的评分">\(ratingStars)</div>
                    <output id="user-rating-value" class="t-footnote t-tertiary" role="status">\(preferenceRatingSummary)</output>
                  </div>
                  \(technicalMetadata.isEmpty ? "" : "<ul class=\"technical-facts\" aria-label=\"媒体参数\">\(technicalMetadata)</ul>")
                </div>
              </div>
            </div>
          </section>\(clientDetailSections)
          <p class="t-footnote t-tertiary detail-footnote">播放信息与媒体字节继续受当前用户、设备、会话和资料库权限检查；未知或无权媒体统一返回 404。</p>
        """
        return ServerWebDocument.render(
            title: detail.title,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/player.css"],
            pageScripts: isMusic ? ["/assets/overlays.js"] : ["/assets/overlays.js", "/assets/player.js"],
            // 这两张就是整页最先被看见的像素。放在 <body> 里的 <img> 要排在样式表
            // 之后才开始下载；先声明出来，它们和样式表并行取。
            preloadedImages: [backdropURL, isMusic ? nil : landingURL].compactMap { $0 },
            bodyClass: "media-detail-page",
            bodyAttributes: #" data-media-kind="\#(isMusic ? "audio" : "video")" data-item-id="\#(escape(detail.id))" data-can-direct-play="\#(canDirectPlay)" data-browser-content-type="\#(browserContentType)" data-video-playback-url="\#(escape(videoPlaybackURL))" data-resume-position="\#(resumePosition)" data-duration-seconds="\#(detail.runtimeSeconds ?? 0)" data-is-watched="\#(detail.userState?.isWatched == true ? "true" : "false")" data-is-favorite="\#(detail.userPreference.isFavorite ? "true" : "false")" data-is-watchlist="\#(detail.userPreference.isWatchlist ? "true" : "false")" data-preference-rating="\#(preferenceRating)"\#(nextEpisodePathAttribute)\#(episodeDataAttributes)"#,
            tint: .video
        )
    }

    /// 详情与浏览器原生播放器共用的固定样式。将其作为私有缓存的同源资源，
    /// 使连续打开媒体详情时无需重复解析播放器舞台和响应式布局规则。
    /// 详情与浏览器原生播放器共用的固定样式。
    ///
    /// The player controls are the product's one true "chrome over content"
    /// surface: they float above moving video, so they take the thin glass
    /// material and an always-dark treatment in both appearances — a light
    /// control bar over arbitrary footage is unreadable.
    static let style = #"""
    /* ---- Backdrop --------------------------------------------------------- */
    /* 顶部锚定的环境铺色，不是铺满全页的一层灰纱。
       此前它 `position: fixed; inset: 0; opacity: .28`，整页均匀糊着同一张模糊
       图——那既拿不到"这部作品是什么颜色"，又把下半页的白底压脏。改成只占屏高
       的一段并向下淡出到画布，与首页 banner 的环境辉光是同一套做法（低清图 +
       模糊 + 压色纱 + 淡出到 `--bg-canvas`）。
       `mask-image` 的透明端必须落在元素**盒子内部**，否则元素自己的矩形边界会
       成为硬边（首页 banner 的磨砂层踩过这条）。 */
    /* 铺色层要相对**文档**定位，不是相对它在 DOM 里的父元素——`.app-main` 有
       最大宽度和居中外边距，铺色跟着收进那条测度里就成了一条居中的色带。
       给 body 一个定位上下文，让它明确地铺满整幅宽度。 */
    body.media-detail-page { position: relative; }
    .detail-backdrop {
      position: absolute;
      z-index: -1;
      top: 0;
      right: 0;
      left: 0;
      height: min(72vh, 720px);
      overflow: hidden;
      pointer-events: none;
      opacity: 0.55;
      filter: blur(48px) saturate(150%);
      -webkit-mask-image: linear-gradient(to bottom, rgba(0, 0, 0, 1) 0%, rgba(0, 0, 0, 0.55) 46%, rgba(0, 0, 0, 0) 96%);
      mask-image: linear-gradient(to bottom, rgba(0, 0, 0, 1) 0%, rgba(0, 0, 0, 0.55) 46%, rgba(0, 0, 0, 0) 96%);
    }
    .detail-backdrop img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      /* 竖版海报按 2:3 拍，居中裁进一条横带会正好切掉主体的头。 */
      object-position: center 28%;
      transform: scale(1.12);
    }
    .detail-footnote { padding-top: var(--space-9); }

    /* ---- Heading ----------------------------------------------------------
       The title, the eyebrow, the back link and the three preference buttons
       all come from the shared page header now.  This file used to draw its own
       heading at title-1, which is why a media page's title was visibly a step
       smaller than every other page in the product.  The original title is the
       header's subtitle, so `.original-title` went with it. */

    /* ---- Layout ----------------------------------------------------------- */
    .watch-layout { display: grid; grid-template-columns: minmax(0, 1fr); gap: var(--space-6); }
    .watch-layout.is-episode-workspace { grid-template-columns: minmax(0, 1fr) minmax(280px, 340px); }
    .watch-main { min-width: 0; }
    .watch-layout.is-wide { grid-template-columns: minmax(0, 1fr); }

    /* ---- Player ----------------------------------------------------------- */
    /* 黑底的那个盒子**必须**和画面一样大。
       高度预算从前只钳住舞台（`max-width` 加在 `.player-stage` 上），而卡片是
       网格列的整宽。默认布局里那一列本来就窄，看不出来；一进宽屏，列宽变成整页，
       卡片和舞台的差就全露出来了——1855×980 的窗口里实测每边 41px 纯黑，这正是
       "宽屏播放有黑边"。
       预算改挂在卡片上、舞台百分百填满卡片，于是任何档位下黑底盒子的尺寸都等于
       画面尺寸，四边不可能再有黑。让位出来的空间是页面底色，不是一条黑边。 */
    .player-card {
      width: 100%;
      max-width: calc(var(--player-height-budget, min(78dvh, 900px)) * (var(--player-aspect, 16 / 9)));
      margin-inline: auto;
      overflow: hidden;
      border-radius: var(--radius-lg);
      background: #05070b;
      box-shadow: var(--shadow-4);
    }
    /* 宽屏是读者明确要的"把画面放大"。默认档留着 78dvh 的预算，是为了让下面的
       简介、演员表还能露出一点；宽屏档没有这个义务，预算因此放宽到几乎整屏高。

       没有选集面板的页面（电影、音乐会录像、只有一集的剧集）本来就是单列——它
       们**就是**宽屏，只是没有那颗切换按钮，所以用同一份预算。留着默认档的话，
       画面会比它所在的那一列窄一圈，两边空出来的地方看着仍然像黑边。 */
    .watch-layout.is-wide .player-card,
    .watch-layout:not(.is-episode-workspace) .player-card { --player-height-budget: min(88dvh, 1200px); }
    /* 舞台与画面**只能有一个**在定尺寸。
       从前两边都在定：舞台按 `--player-aspect` 定比例，画面又自己带
       `block-size: auto` + `max-block-size: min(78dvh, 900px)`。高度预算一旦生效，
       画面就变成"100% 宽 × 被钳住的高"，而舞台还是按比例算出来的那个更高的盒子——
       于是上下是舞台露出来的底，左右是画面自己 `contain` 出来的边，四边全黑。
       切换尺寸档时这一点最明显，因为宽度一变，两套约束的差就跟着变。

       现在高度预算换算成**宽度上限**（`--player-aspect` 是 `1920 / 1080` 这样的
       形式，可以直接进 calc 做除法），舞台因此永远保持画面自己的比例，画面 100%
       填满舞台，任何档位下都不会有黑边。 */
    .player-stage {
      position: relative;
      display: grid;
      place-items: center;
      width: 100%;
      aspect-ratio: var(--player-aspect, 16 / 9);
      background: #05070b;
    }
    .player-stage video {
      inline-size: 100%;
      block-size: 100%;
      /* `contain` 只是最后一道保险：正常情况下舞台就是画面的比例，它无事可做。 */
      object-fit: contain;
      background: #05070b;
    }
    /* `.player-landing` 从前完全没有规则，而铺满的那条写的是
       `.player-landing-art img`——类名就在 <img> 自己身上，那个选择器匹配不到
       任何元素。结果画面前置图既没有铺满也没有压暗，按固有尺寸挤在舞台里。 */
    .player-landing { position: absolute; inset: 0; }
    .player-landing-art, .player-landing-placeholder {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
    }
    .player-landing-art { object-fit: cover; opacity: 0.55; }
    .player-landing-placeholder { display: grid; place-items: center; background: linear-gradient(145deg, #1b2330, #0b1018); }

    /* ---- 起播 / 缓冲 / 失败的可见形态 --------------------------------------
       这三种状态此前只有 `#player-status` 那条 sr-only 文本：能看见的读者按下
       播放之后，画面上什么都不发生，分不清是在缓冲还是已经坏了。 */
    .player-busy {
      position: absolute;
      z-index: 5;
      inset: 0;
      display: grid;
      place-items: center;
      color: var(--text-on-media);
      pointer-events: none;
    }
    .player-busy .ui-spinner { width: 34px; height: 34px; border-width: 3px; }
    .player-error {
      position: absolute;
      z-index: 6;
      right: var(--space-5);
      bottom: var(--space-9);
      left: var(--space-5);
      display: grid;
      justify-items: center;
      padding: var(--space-4) var(--space-5);
      border: var(--hairline) solid var(--btn-on-media-border);
      border-radius: var(--radius-md);
      color: var(--text-on-media);
      background: var(--overlay-on-media-strong);
      -webkit-backdrop-filter: var(--btn-on-media-blur);
      backdrop-filter: var(--btn-on-media-blur);
      box-shadow: var(--shadow-3);
      /* 玻璃是"显形"进场：模糊半径与缩放一起动，而不是一张突然出现的图片。 */
      animation: player-materialize var(--duration-base) var(--ease-out);
    }
    .player-error-message {
      max-width: 46ch;
      font-size: var(--type-callout-size);
      line-height: var(--type-callout-line);
      text-align: center;
    }
    @media (max-width: 719px) {
      .player-error { right: var(--space-3); left: var(--space-3); bottom: var(--space-8); }
    }
    .start-play {
      position: absolute;
      z-index: 3;
      display: inline-flex;
      align-items: center;
      gap: var(--space-2);
    }

    /* Controls fade with the pointer, but keyboard focus always brings them
       back — an overlay that can only be summoned by a mouse is not a control. */
    /* A scrim, not a panel.
       These controls used to be a floating rounded box inset 12px from the video
       on all sides, with its own border, blur and shadow — a widget sitting on
       top of the picture. Every player people actually use (YouTube, Netflix,
       Bilibili, Vimeo) instead darkens the foot of the frame and lays the
       scrubber edge to edge across it, so the controls read as part of the video
       surface and the artwork keeps its full width. */
    .player-overlay-controls {
      position: absolute;
      right: 0;
      bottom: 0;
      left: 0;
      z-index: 4;
      display: grid;
      gap: var(--space-1);
      padding: var(--space-8) var(--space-4) var(--space-3);
      /* 遮罩、控件配色与前景文字全部走 on-media 令牌，于是浅色/深色两套主题、
         以及 prefers-contrast: more 都自动成立；这里从前是一串写死的
         `#ffffff` 与 `rgba(0,0,0,…)`。 */
      background: var(--media-scrim);
      color: var(--text-on-media);
      opacity: 0;
      transition: opacity var(--duration-base) var(--ease-out);
      /* 控件条不再只是一层压暗：底部这条带子现在真的把画面糊掉。
         纯遮罩在高频画面上（雪花、字幕、密集树叶）挡不住细节，图标和时间码会
         和画面的纹理绞在一起；磨砂之后底下只剩色块，前景才真正浮起来。
         模糊挂在带蒙版的伪元素上而不是元素本身：`backdrop-filter` 会把整个盒子
         都糊掉，包括顶部本该透明的那一截，于是画面中间会出现一条硬边。蒙版让
         模糊和遮罩一起淡出。 */
    }
    .player-overlay-controls::before {
      content: "";
      position: absolute;
      z-index: -1;
      inset: 0;
      -webkit-backdrop-filter: var(--btn-on-media-blur);
      backdrop-filter: var(--btn-on-media-blur);
      -webkit-mask-image: linear-gradient(to top, #000 0%, #000 42%, transparent 84%);
      mask-image: linear-gradient(to top, #000 0%, #000 42%, transparent 84%);
      pointer-events: none;
    }
    .player-stage.controls-visible .player-overlay-controls,
    .player-overlay-controls:focus-within { opacity: 1; }
    .player-control-row { display: flex; align-items: center; gap: var(--space-3); }
    .player-control-group { display: flex; align-items: center; gap: var(--space-1); }
    .player-control-group-end { margin-left: auto; gap: var(--space-4); }
    /* 尾部从前是十个按钮排成一条平铺的队伍：音量、倍速、字幕、音轨、画中画、
       三个尺寸模式、全屏、更多——全都一样大、一样间距，要找哪个只能一个个认
       图标。现在按用途分成三簇（声音 / 内容设置 / 画面尺寸），簇内紧挨、簇间
       留一个更大的间距。分组本身就是一次说明，比再加一排标签便宜。 */
    .player-control-cluster { display: flex; align-items: center; gap: var(--space-1); }
    /* ⚠️ `.transport-controls` must never take `display: contents`.  It also
       carries `.player-overlay-controls`; a `display: contents` declared at equal
       specificity suppressed that element's box entirely, so the scrim, the
       padding and the positioning were never rendered and the controls floated
       loose over the picture.  The rule that did it belonged to a summary block
       below the video that no longer exists. */

    .player-overlay-controls button,
    .player-symbol-button {
      display: grid;
      width: 36px;
      height: 36px;
      place-items: center;
      border: 0;
      border-radius: var(--radius-xs);
      color: var(--text-on-media);
      background: transparent;
      cursor: pointer;
      transition: background-color var(--duration-fast) var(--ease-out), transform var(--duration-instant) var(--ease-out);
    }
    /* 画面正中那颗是"开始观看"，不是控制栏里的一个小图标——它和 36px 的静音、
       倍速按钮一样大，读起来像误放在中间的一个次要控件。放大到 88px 并给它自己
       的材质：它是这一页唯一的主行动。 */
    .player-symbol-button {
      width: 88px;
      height: 88px;
      border-radius: 50%;
      background: var(--overlay-on-media-strong);
      -webkit-backdrop-filter: var(--btn-on-media-blur);
      backdrop-filter: var(--btn-on-media-blur);
      box-shadow: var(--shadow-4);
      transition: background-color var(--duration-fast) var(--ease-out), transform var(--duration-fast) var(--ease-out);
    }
    .player-symbol-button:hover { background: var(--overlay-on-media-strong); transform: scale(1.04); }
    .player-symbol-button:active { transform: scale(0.97); }
    .player-symbol-button svg { width: 40px; height: 40px; }
    .player-overlay-controls button:hover { background: var(--overlay-on-media); }
    .player-overlay-controls button:active { transform: scale(0.94); }
    .player-overlay-controls button svg { width: var(--icon-md); height: var(--icon-md); }
    /* The primary control is bigger and circular; it does not need `!important`
       now that it is not fighting a generic button rule for the same properties. */
    .player-btn.transport-primary {
      width: 44px;
      height: 44px;
      border-radius: 50%;
      background: var(--overlay-on-media);
    }
    .player-btn.transport-primary:hover { background: var(--overlay-on-media-strong); }

    /* 进度条与音量条的槽/把手/填充都来自 primitives 层的 `.ui-range`，
       `.ui-range-on-media` 把三种颜色换成画面之上的那一族。这里只留下真正属于
       播放器的尺寸。
       从前这一整套伪元素规则在这个文件里又写了一遍，而音量条压根没写——于是它
       在画面上渲染成一个系统原生控件。同一套东西写两遍，第二遍迟早会漏。 */
    .player-progress { --range-hit: 16px; }
    .playback-time {
      margin-left: var(--space-2);
      color: var(--text-on-media-secondary);
      font-size: var(--type-footnote-size);
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    /* 音量与倍速都收进按钮上的悬浮层：控制栏本来就挤，一条常驻滑杆挤掉的是
       更常用的按钮。悬浮层用 `:hover`/`:focus-within` 双触发——只靠 hover 的话
       键盘用户永远打不开它。 */
    .player-hover-control { position: relative; display: flex; align-items: center; }
    .player-hover-popover {
      position: absolute;
      bottom: calc(100% + var(--space-2));
      left: 50%;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: var(--space-2);
      padding: var(--space-3) var(--space-2);
      border: var(--hairline) solid var(--glass-thin-border);
      border-radius: var(--radius-sm);
      background: var(--overlay-on-media-strong, rgba(20, 20, 24, 0.92));
      box-shadow: var(--shadow-2);
      opacity: 0;
      transform: translate(-50%, 4px);
      pointer-events: none;
      transition: opacity var(--duration-fast) var(--ease-out), transform var(--duration-fast) var(--ease-out);
    }
    .player-hover-control:hover .player-hover-popover,
    .player-hover-control:focus-within .player-hover-popover,
    .player-hover-control.is-open .player-hover-popover {
      opacity: 1;
      transform: translate(-50%, 0);
      pointer-events: auto;
    }
    /* 悬浮层与按钮之间那段空隙不能是"断开"的：鼠标从按钮移向滑杆的途中一旦
       离开命中区，层就收起来了，滑杆永远够不着。这条透明桥把空隙补上。 */
    .player-hover-popover::after {
      content: "";
      position: absolute;
      top: 100%;
      left: 0;
      width: 100%;
      height: var(--space-2);
    }
    @media (prefers-reduced-motion: reduce) {
      .player-hover-popover { transition: none; }
    }

    .volume-popover { width: 44px; }
    .volume-control { display: flex; align-items: center; justify-content: center; }
    /* 竖向滑杆：`writing-mode` 是现代写法，`appearance: slider-vertical` 是
       旧 WebKit 的回退，两者都写才能在 Safari 与 Chromium 上都竖起来。 */
    .volume-control input[type="range"] {
      writing-mode: vertical-lr;
      direction: rtl;
      -webkit-appearance: slider-vertical;
      width: 20px;
      height: 96px;
      --range-hit: 20px;
    }

    .speed-button { min-width: 44px; font-variant-numeric: tabular-nums; }
    #playback-speed-value { font-size: var(--type-footnote-size); font-weight: var(--weight-semibold); }
    .speed-popover { width: 168px; }
    .speed-control { display: block; width: 100%; }
    /* 分档而非无极：`step=1` 走的是 0–6 的档位下标，真实倍速由脚本查表得到。
       用下标做 range 的值，浏览器原生的键盘步进与吸附就直接是"一档一档"的。 */
    .speed-range { width: 100%; --range-hit: 20px; }
    .speed-scale {
      display: flex;
      justify-content: space-between;
      width: 100%;
      color: var(--text-on-media-secondary);
      font-size: var(--type-caption-size);
      font-variant-numeric: tabular-nums;
    }
    #playback-volume-value {
      min-width: 4ch;
      color: var(--text-on-media-secondary);
      font-size: var(--type-footnote-size);
      font-variant-numeric: tabular-nums;
    }
    .speed-control select, .player-settings select {
      height: var(--control-height-sm);
      padding: 0 var(--space-2);
      border: var(--hairline) solid var(--glass-thin-border);
      border-radius: var(--radius-xs);
      color: var(--text-on-media);
      background: var(--overlay-on-media);
      font-size: var(--type-footnote-size);
    }
    .speed-control select option, .player-settings select option { color: var(--text-primary); background: var(--surface); }

    .player-settings { position: relative; }
    .player-settings > summary { display: grid; width: 36px; height: 36px; place-items: center; border-radius: var(--radius-xs); }
    .player-settings > summary:hover { background: var(--overlay-on-media); }
    .player-settings-panel {
      position: absolute;
      right: 0;
      bottom: calc(100% + var(--space-2));
      z-index: 5;
      display: grid;
      min-width: 232px;
      gap: var(--space-3);
      padding: var(--space-4);
      border: var(--hairline) solid var(--glass-thick-border);
      border-radius: var(--radius-md);
      color: var(--text-on-media);
      background: var(--overlay-on-media-strong);
      -webkit-backdrop-filter: var(--glass-thick-blur);
      backdrop-filter: var(--glass-thick-blur);
      box-shadow: var(--shadow-4);
      transform-origin: bottom right;
      /* 玻璃要"显形"，不是淡入：模糊半径与缩放一起动，面板才读作一层真实的
         材质到位，而不是一张突然出现的图片。 */
      animation: player-materialize var(--duration-base) var(--ease-out);
      font-size: var(--type-footnote-size);
    }
    /* 轨道面板里的那些条目仍然是手搓的按钮；「重新检测媒体源」已经走
       `ServerWebUI.button` + `.ui-btn-on-media`。 */
    .player-settings-panel button {
      min-height: var(--control-height-sm);
      padding: 0 var(--space-3);
      border: var(--hairline) solid var(--glass-thin-border);
      border-radius: var(--radius-xs);
      color: var(--text-on-media);
      background: var(--overlay-on-media);
      cursor: pointer;
      font-size: var(--type-footnote-size);
    }
    .player-settings-panel button:hover { background: var(--overlay-on-media-strong); }

    @keyframes player-materialize {
      from { opacity: 0; transform: scale(0.94); -webkit-backdrop-filter: blur(0); backdrop-filter: blur(0); }
      to { opacity: 1; transform: scale(1); }
    }

    /* 字幕/音轨面板：一列可选轨道，选中态用 aria-checked 表达，与 `.ui-menu-item`
       同一语义。 */
    /* 轨道标签是"原声 · eng · AC3 · 1 声道（需转码）"这种长度，而末尾那几个字
       恰恰是最要紧的。面板按内容取宽、只封一个上限，而不是固定 208px 再把结论
       截掉。 */
    .player-track-panel {
      /* 轨道标签是"原声 · eng · AC3 · 1 声道（需转码）"这种长度，而末尾那几个字
         恰恰是最要紧的——它正是"这条轨为什么要转码"的答案。这里给的宽度按那条
         最长的真实标签定，超出的仍然省略号收尾。 */
      min-width: 260px;
      max-width: min(340px, 70vw);
      gap: 2px;
      padding: var(--space-2);
    }
    /* ⚠️ 选择器必须比 `.player-overlay-controls button` 更具体。
       那条规则把控制栏里的**每一个** button 都压成 36×36 的图标方块——传输栏上的
       按钮本该如此，但这两个面板也长在传输栏里，于是"关闭字幕"会被挤成一列
       竖排的单字。此前看不见，只是因为这两个菜单从来没有被填充过。 */
    .player-track-panel .player-track-item {
      display: flex;
      width: auto;
      height: auto;
      min-height: var(--control-height-sm);
      align-items: center;
      padding: 0 var(--space-3);
      border: 0;
      border-radius: var(--radius-xs);
      color: var(--text-on-media);
      background: transparent;
      cursor: pointer;
      font-size: var(--type-footnote-size);
      text-align: left;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .player-track-panel .player-track-item:hover { background: var(--overlay-on-media); }
    .player-track-panel .player-track-item[aria-checked="true"] { font-weight: var(--weight-semibold); background: var(--overlay-on-media); }
    /* 分组小标题：外挂 / 内封 / 来源服务器。同一部片子这三处经常都有一条
       「简体中文」，不分组的话菜单里是几条看起来一模一样的选项。 */
    .player-track-group {
      padding: var(--space-2) var(--space-3) var(--space-1);
      color: var(--text-on-media-secondary);
      font-size: var(--type-caption-size);
    }
    .player-track-group:first-child { padding-top: 0; }
    /* 「为什么不能换音轨」这句话就显示在菜单底部，而不是让那颗按钮静静地什么
       也不做。 */
    .player-track-note {
      max-width: 30ch;
      white-space: normal;
      padding: var(--space-2) var(--space-3) 0;
      color: var(--text-on-media-secondary);
      font-size: var(--type-caption-size);
      line-height: 1.4;
    }

    /* 快捷键提示：第一次真正开始播放时出现一次，然后自己退场。 */
    .player-shortcut-hint {
      position: absolute;
      top: var(--space-4);
      left: 50%;
      z-index: 5;
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-3);
      padding: var(--space-2) var(--space-4);
      border-radius: var(--radius-pill);
      color: var(--text-on-media-secondary);
      background: var(--overlay-on-media-strong);
      -webkit-backdrop-filter: var(--glass-regular-blur);
      backdrop-filter: var(--glass-regular-blur);
      font-size: var(--type-footnote-size);
      transform: translateX(-50%);
      animation: player-materialize var(--duration-base) var(--ease-out);
      pointer-events: none;
    }
    .player-shortcut-hint.is-leaving { opacity: 0; transition: opacity var(--duration-exit) var(--ease-in); }

    .status.error { color: var(--error); }
    /* 屏读专用文本走全局的 `.visually-hidden`（base.css）；这里此前是它的第二份拷贝。 */

    /* Web-fullscreen: the page frame steps out of the way entirely. */
    body.is-web-fullscreen .app-sidebar,
    body.is-web-fullscreen .app-mobile-bar,
    body.is-web-fullscreen .app-tabbar,
    body.is-web-fullscreen .app-page-head,
    body.is-web-fullscreen .detail-info,
    body.is-web-fullscreen .episode-panel,
    body.is-web-fullscreen .detail-footnote,
    body.is-web-fullscreen .client-detail-section { display: none; }
    body.is-web-fullscreen .shell { grid-template-columns: minmax(0, 1fr); }
    /* ★ 正文列必须跟着搬到第一列。
       外壳的 `.app-main` 写着 `grid-column: 2`（正常布局里第一列是侧栏）。网页
       全屏只把列数改成 1，却没有改这一句，于是正文被放进一条**隐式的第二列**
       ——宽度 0、起点在视口右边缘之外。实测 `main` 是 `{x: 1920, w: 0}`：整个
       页面看起来就是"点了网页全屏什么都没有"。
       同时要解除内容测度：`max-width` 与自动外边距是给正文排版用的，全屏下留着
       它们，画面会被钉在屏幕中间一小条。 */
    body.is-web-fullscreen .app-main {
      grid-column: 1;
      max-width: none;
      margin-inline: 0;
      padding: 0;
    }
    /* 选集面板在全屏下是 `display: none`，但那条 340px 的列还在——留着它，画面
       右边会白白让出一条选集面板宽的空白。列数也要跟着收成一列。 */
    body.is-web-fullscreen .watch-layout {
      grid-template-columns: minmax(0, 1fr);
      gap: 0;
    }
    body.is-web-fullscreen .player-card {
      max-width: none;
      border-radius: 0;
    }
    /* 全屏下高度不再是预算而是全部，所以那条宽度上限必须一并解除——留着它，
       画面会被按 78dvh 的预算钉在屏幕中间一小块。 */
    body.is-web-fullscreen .player-stage {
      aspect-ratio: auto;
      height: 100dvh;
      max-width: none;
    }

    /* ---- Episode browser -------------------------------------------------- */
    /* 选集面板。
       从前是一张硬描边的白卡：边框和内容抢注意力，而这一块的主角是那一格格的集
       号。改成用层次而不是线条来划分——去掉描边、给一层柔和投影，圆角与页面上
       其它卡片对齐。 */
    /* 面板的高度**永远等于左边的播放器**，多出来的集号靠滚动看，不靠把这一行
       撑高。此前它是 `align-content: start` 的自动高度网格，集数一多就把整行
       顶高，播放器旁边于是空出一大条。

       `--episode-panel-height` 由脚本量播放器卡片得到（CSS 没有办法拿到另一个
       网格项的高度）。拿不到时退回 `none`，也就是旧的自动高度——没有脚本的读者
       仍然能用，只是高度不再对齐。 */
    .episode-panel {
      display: grid;
      grid-template-rows: auto auto minmax(0, 1fr) auto;
      align-content: start;
      gap: var(--space-3);
      max-height: var(--episode-panel-height, none);
      min-height: 0;
      overflow: hidden;
      padding: var(--space-5);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-lg);
      background: var(--surface);
      box-shadow: var(--shadow-2);
    }
    /* 季标签铺满一行再换下一行。
       `flex-wrap` 那一版每颗按内容定宽，七季会排成 3/3/1 并在每行末尾留下一大条
       空白。`auto-fit` + `minmax(64px, 1fr)` 让它们均分整行宽度：列数随面板宽度
       自己算，64px 是不至于点不中的下限。 */
    /* 每颗季标签一样宽，最后一行不必填满。
       列宽由容器宽度除以 68px 下限算出，`1fr` 让这些列均分整行——**所有行共用
       同一套列**，所以第二行的按钮和第一行一模一样宽，装不满的地方就空着。

       ⚠️ 不要改回 `flex: 1 1 68px`。flex 是**按行**分配剩余宽度的：七季会排成
       第一行 4 颗各 69px、第二行 3 颗各 94px——同一排控件出现两种尺寸。
       `auto-fill` 而不是 `auto-fit`：后者会把空轨道折叠掉，季数少时按钮又会被
       拉宽。 */
    .episode-season-tabs {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(68px, 1fr));
      gap: var(--space-2);
    }
    .episode-season-tab {
      min-height: var(--control-height-sm);
      padding: 0 var(--space-2);
      white-space: nowrap;
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-pill);
      color: var(--text-secondary);
      background: var(--surface);
      cursor: pointer;
      font-size: var(--type-footnote-size);
      font-weight: var(--weight-medium);
      transition:
        background-color var(--duration-fast) var(--ease-out),
        border-color var(--duration-fast) var(--ease-out),
        color var(--duration-fast) var(--ease-out),
        transform var(--duration-instant) var(--ease-out);
    }
    .episode-season-tab:hover { border-color: var(--border-strong); background: var(--surface-hover); }
    /* 反馈落在按下那一刻，不是松手之后。 */
    .episode-season-tab:active { transform: scale(0.97); }
    .episode-season-tab[aria-selected="true"], .episode-season-tab.current {
      color: var(--text-on-accent);
      border-color: transparent;
      background: var(--accent);
      box-shadow: var(--shadow-1);
      font-weight: var(--weight-semibold);
    }
    /* Episode *numbers* are 44px tiles.  Episode *choices* are not: each one
       carries a position label, a full title and a caption, and they used to
       share this grid — which squeezed a whole episode title into a 44px column
       and wrapped it one character per line. */
    /* 集号格自己滚，不再用 `46dvh` 这个和播放器毫无关系的高度上限——那个值
       在矮窗口里比播放器还高，在高窗口里又白白浪费空间。 */
    .episode-number-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(var(--episode-cell), 1fr));
      /* 行按内容高度排，不铺满。
         这块网格占的是面板里那一条 `1fr` 的区域，而 `align-content` 默认是
         `stretch`——隐式行会把剩余高度平分掉，集数少的时候每个集号就被抻成一根
         两百多像素高的长条。 */
      align-content: start;
      gap: var(--space-2);
      min-height: 0;
      overflow-y: auto;
      overscroll-behavior: contain;
      scrollbar-width: thin;
    }
    /* 高度不够时先缩小格子，缩到安全下限为止，再往下才交给滚动。
       三档由脚本按量出来的可用高度切换。 */
    .episode-panel { --episode-cell: 44px; }
    .episode-panel[data-density="compact"] { --episode-cell: 38px; }
    .episode-panel[data-density="dense"] { --episode-cell: 32px; }
    /* 触摸下不缩：44px 是触摸目标下限，宁可滚动也不能把它按下去。 */
    @media (hover: none), (pointer: coarse) {
      .episode-panel[data-density] { --episode-cell: 44px; }
    }
    .episode-number {
      display: grid;
      /* 集号是方的。宽度由列自适应（`minmax(--episode-cell, 1fr)` 给了下限，
         所以再挤也不会小到点不中），高度跟着宽度走。 */
      aspect-ratio: 1;
      min-height: var(--episode-cell);
      place-items: center;
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-sm);
      color: var(--text-secondary);
      background: var(--surface);
      font-size: var(--type-callout-size);
      font-variant-numeric: tabular-nums;
      cursor: pointer;
      transition:
        background-color var(--duration-fast) var(--ease-out),
        border-color var(--duration-fast) var(--ease-out),
        color var(--duration-fast) var(--ease-out),
        box-shadow var(--duration-fast) var(--ease-out),
        transform var(--duration-instant) var(--ease-out);
    }
    .episode-number:active, .episode-choice:active { transform: scale(0.96); }
    .episode-choices {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
      gap: var(--space-2);
      max-height: 46dvh;
      overflow-y: auto;
    }
    .episode-choice {
      display: grid;
      min-width: 0;
      align-content: start;
      gap: 2px;
      padding: var(--space-3);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-sm);
      color: var(--text-secondary);
      background: var(--surface);
      font-size: var(--type-footnote-size);
      transition: background-color var(--duration-fast) var(--ease-out), border-color var(--duration-fast) var(--ease-out);
    }
    .episode-choice > span { color: var(--text-tertiary); font-size: var(--type-caption-size); }
    .episode-choice > strong {
      overflow: hidden;
      color: var(--text-primary);
      font-size: var(--type-callout-size);
      font-weight: var(--weight-medium);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .episode-choice > small { color: var(--text-tertiary); }
    .episode-number:hover, .episode-choice:hover {
      color: var(--text-primary);
      border-color: var(--border-strong);
      background: var(--surface-hover);
      box-shadow: var(--shadow-1);
    }
    /* 正在看的那一集：实心强调色，外加一圈同色的柔光。
       从前是一块饱和的蓝方块直接压在一排白格子里，重得像贴上去的；一圈扩散开的
       低透明度光晕会让它"亮起来"而不是"盖上去"。 */
    .episode-number.current, .episode-choice.current {
      color: var(--text-on-accent);
      border-color: transparent;
      background: var(--accent);
      box-shadow: var(--shadow-2), 0 0 0 4px var(--accent-subtle);
      font-weight: var(--weight-semibold);
    }
    .episode-choice.current > span,
    .episode-choice.current > strong,
    .episode-choice.current > small { color: var(--text-on-accent); }
    /* 只有一行字，不该占掉一整块。没有内容时连行高都不留。 */
    .episode-grid-status {
      margin: calc(var(--space-1) * -1) 0;
      color: var(--text-tertiary);
      font-size: var(--type-caption-size);
      line-height: 1.4;
    }
    .episode-grid-status:empty { display: none; }
    /* 「加载更多剧集」是 `.ui-btn-secondary`；这里此前连按钮本体都手搓了一份。 */
    /* Wide layout: each season is a full-width band whose episodes run across
       the page.
       The container element carries `.episode-number-grid` as well, and this
       rule used to override only `gap` and `max-height` — so the 44px auto-fill
       columns still applied and every season was squeezed into a single 44px
       track, stacking its episodes vertically down a sliver of an otherwise
       empty page. */
    .wide-season-rows {
      grid-template-columns: minmax(0, 1fr);
      gap: var(--space-6);
      max-height: none;
      overflow-y: visible;
    }
    .wide-season-row { display: grid; gap: var(--space-3); }
    .wide-season-row > h3 {
      color: var(--text-secondary);
      font-size: var(--type-subhead-size);
      font-weight: var(--weight-semibold);
    }
    /* The inner grid supplies the horizontal flow; it must not keep its own
       scroll well once the panel is the full width of the page. */
    .wide-season-row .episode-number-grid {
      grid-template-columns: repeat(auto-fill, minmax(52px, 1fr));
      max-height: none;
      overflow-y: visible;
    }

    /* ---- Synopsis --------------------------------------------------------- */
    .detail-info { padding-top: var(--space-9); }
    .synopsis { display: grid; grid-template-columns: 200px minmax(0, 1fr); align-items: start; gap: var(--space-7); }
    .synopsis .poster {
      overflow: hidden;
      aspect-ratio: var(--poster-ratio);
      border-radius: var(--radius-md);
      background: linear-gradient(145deg, var(--artwork-g1, var(--artwork-fallback-a)), var(--artwork-g2, var(--artwork-fallback-b)));
      box-shadow: var(--shadow-3);
    }
    .synopsis .poster img { width: 100%; height: 100%; object-fit: cover; }
    .synopsis-copy { display: grid; gap: var(--space-3); min-width: 0; }
    /* 作品名可以很长（尤其是日文全角标题），但它是一栏的标题不是正文，占到第三
       行就开始和下面的信息抢位置了。 */
    .synopsis-title { --clamp-lines: 2; overflow-wrap: anywhere; }
    /* 元信息分三级：徽章（评分/分级）→ 事实行（时长·状态·语言·地区）→ 题材胶囊。
       此前它们是同一颗灰框胶囊排成一行七个，谁也不比谁重要。 */
    .facts { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2); }
    .detail-badge {
      display: inline-flex;
      height: 22px;
      align-items: center;
      padding: 0 var(--space-2);
      border: var(--hairline) solid transparent;
      border-radius: var(--radius-xs);
      font-size: var(--type-footnote-size);
      font-weight: var(--weight-semibold);
    }
    /* 评分是这一排里唯一带数字的判定，给它识别色实底；其余保持描边。 */
    .detail-badge-score {
      color: var(--tint-glyph, var(--accent-text));
      border-color: var(--tint-border, var(--border));
      background-color: var(--tint-fill-b, var(--accent-subtle));
    }
    .detail-badge-outline { color: var(--text-secondary); border-color: var(--border-strong); }
    /* 事实行本身不装盒：它是背景信息，读者只在需要时才看它。 */
    .detail-fact-line {
      color: var(--text-tertiary);
      font-size: var(--type-footnote-size);
    }
    .detail-fact-line + .ui-chip { margin-left: var(--space-1); }
    /* 简介从前没有任何行数上限，而 TMDB 的分集简介经常是一段带硬换行的长文，
       于是这一栏能把整页撑到海报的好几倍高。
       `pre-wrap` 一并去掉：它会把源文本里的每个换行都保留下来，六行的额度会被
       几个空行吃光，读者反而看不到内容。简介是散文，按散文排。 */
    .overview {
      max-width: var(--page-max-prose);
      --clamp-lines: 6;
    }
    .detail-utility-inline { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-6); padding-top: var(--space-2); }
    .detail-rating { display: flex; align-items: center; gap: var(--space-3); }
    .detail-utility-label { color: var(--text-tertiary); font-size: var(--type-footnote-size); }
    .rating-stars { display: flex; gap: 2px; }
    /* Five discrete stars, not a slider: rating is a choice among five values. */
    .rating-star {
      display: grid;
      width: 28px;
      height: 28px;
      place-items: center;
      border: 0;
      border-radius: var(--radius-xs);
      color: var(--text-tertiary);
      background: transparent;
      cursor: pointer;
      transition: color var(--duration-fast) var(--ease-out), transform var(--duration-instant) var(--ease-out);
    }
    .rating-star svg { width: var(--icon-md); height: var(--icon-md); }
    .rating-star:hover { color: var(--warning); transform: scale(1.1); }
    /* The markup states selection with `aria-pressed` — these buttons are
       toggles, not radios.  The rule used to look for `aria-checked`, which the
       markup never sets, so a chosen rating never actually filled in. */
    .rating-star[aria-pressed="true"] { color: var(--warning); }
    .technical-facts { display: flex; flex-wrap: wrap; gap: var(--space-2); }
    .technical-facts li {
      padding: 2px var(--space-2);
      border-radius: var(--radius-xs);
      color: var(--text-secondary);
      background: var(--surface-sunken);
      font-size: var(--type-caption-size);
    }

    /* ---- Client detail sections ------------------------------------------- */
    .client-detail-section { padding-top: var(--space-9); }
    /* grid 项目的自动最小尺寸是 min-content，不写 `min-width: 0` 就压不下去：
       里面那条横向轨道一旦够长，整个区块会被撑到内容宽度，横向滚动跑到页面上，
       轨道自己反而永远不溢出、也就永远拖不动。 */
    .client-detail-section { min-width: 0; }
    .client-detail-section-head {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: var(--space-3);
    }
    .client-detail-section h2 {
      padding-bottom: var(--space-4);
      font-size: var(--type-title2-size);
      letter-spacing: var(--type-title2-track);
      font-weight: var(--weight-semibold);
    }
    .client-detail-production-list { display: flex; flex-wrap: wrap; gap: var(--space-2); }
    .client-detail-production-list span {
      display: inline-flex;
      height: var(--control-height-sm);
      align-items: center;
      padding: 0 var(--space-3);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-pill);
      color: var(--text-secondary);
      font-size: var(--type-footnote-size);
    }

    /* 人物是圆形头像 + 姓名 + 角色，与客户端的主创/演员行同一形状。 */
    .client-detail-people {
      display: grid;
      grid-auto-flow: column;
      grid-auto-columns: 104px;
      gap: var(--space-4);
      overflow-x: auto;
      padding-bottom: var(--space-2);
      scrollbar-width: thin;
      overscroll-behavior-x: contain;
    }
    .client-detail-person { display: grid; justify-items: center; gap: var(--space-1); color: inherit; text-align: center; }
    .client-detail-portrait {
      display: grid;
      width: 84px;
      height: 84px;
      overflow: hidden;
      place-items: center;
      border-radius: 50%;
      color: var(--accent-text);
      background: var(--accent-subtle);
      font-size: var(--type-title3-size);
      font-weight: var(--weight-bold);
      box-shadow: var(--shadow-1);
      transition: transform var(--duration-base) var(--ease-out), box-shadow var(--duration-base) var(--ease-out);
    }
    .client-detail-portrait img { width: 100%; height: 100%; object-fit: cover; }
    .client-detail-person:hover .client-detail-portrait { transform: scale(1.04); box-shadow: var(--shadow-3); }
    .client-detail-person strong {
      overflow: hidden;
      max-width: 100%;
      font-size: var(--type-footnote-size);
      font-weight: var(--weight-medium);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .client-detail-person small { color: var(--text-tertiary); font-size: var(--type-caption-size); }

    /* 艺术照横向排开，每张按自己的比例占位，于是解码完成时版面不会跳。
       行高从 148px 提到 200px：剧照上通常有人脸和字幕，148px 高的横版图只有
       83px 宽的有效画面，看不清是哪一场戏。 */
    .client-detail-stills {
      /* 一条等高的图带：高度由这里定一次，横版和竖版都只用它换算自己的宽度。
         从前这里是 `grid-auto-flow: column` + `grid-auto-rows`，看起来也该得到
         等高——但列宽是 auto，于是轨道按图片的固有宽度撑开，item 再被拉去填满
         轨道，`aspect-ratio` 根本轮不到生效：两种朝向最后是按各自原图的尺寸在
         排，横版看着就比竖版矮一截。改成 flex 行 + 定高，高度不再经过任何轨道
         协商。 */
      --still-height: clamp(150px, 15vw, 208px);
      display: flex;
      align-items: flex-start;
      gap: var(--space-3);
      overflow-x: auto;
      padding-bottom: var(--space-2);
      scrollbar-width: thin;
      overscroll-behavior-x: contain;
    }
    .client-detail-still {
      display: block;
      flex: none;
      overflow: hidden;
      block-size: var(--still-height);
      inline-size: auto;
      aspect-ratio: 16 / 9;
      border-radius: var(--radius-md);
      background: var(--surface-sunken);
      box-shadow: var(--shadow-1);
      transition: box-shadow var(--duration-base) var(--ease-out), transform var(--duration-base) var(--ease-out);
    }
    .client-detail-still[data-orientation="portrait"] { aspect-ratio: var(--poster-ratio); }
    .client-detail-still:hover { box-shadow: var(--shadow-3); transform: translateY(-2px); }
    .client-detail-still:focus-visible { outline: none; box-shadow: var(--focus-ring), var(--shadow-3); }
    .client-detail-still img { width: 100%; height: 100%; object-fit: cover; }

    .client-detail-related {
      display: grid;
      grid-auto-flow: column;
      grid-auto-columns: 148px;
      gap: var(--space-5);
      overflow-x: auto;
      padding-bottom: var(--space-2);
      scrollbar-width: thin;
      overscroll-behavior-x: contain;
    }
    .client-detail-related-card { display: grid; gap: var(--space-2); color: inherit; align-content: start; }
    .client-detail-related-card strong {
      overflow: hidden;
      font-size: var(--type-footnote-size);
      font-weight: var(--weight-medium);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .client-detail-related-card small { color: var(--text-tertiary); font-size: var(--type-caption-size); }
    /* 资料库里没有的推荐不是链接——点开会通向一个不存在的条目。 */
    .client-detail-related-card.is-discovery { cursor: default; }
    .client-detail-related-card.is-discovery .client-detail-related-art { opacity: 0.86; }
    .client-detail-related-art {
      display: grid;
      overflow: hidden;
      place-items: center;
      aspect-ratio: var(--poster-ratio);
      border-radius: var(--radius-md);
      color: var(--text-on-media);
      background: linear-gradient(145deg, var(--artwork-g1, var(--artwork-fallback-a)), var(--artwork-g2, var(--artwork-fallback-b)));
      box-shadow: var(--shadow-1);
      transition: box-shadow var(--duration-base) var(--ease-out);
    }
    a.client-detail-related-card:hover .client-detail-related-art { box-shadow: var(--shadow-3); }
    .client-detail-related-art img { width: 100%; height: 100%; object-fit: cover; }

    .client-detail-links { display: flex; flex-wrap: wrap; gap: var(--space-2); }
    .client-detail-extras { display: grid; gap: var(--space-2); }

    /* ---- Music ------------------------------------------------------------ */
    .music-dock-prompt {
      display: grid;
      gap: var(--space-3);
      padding: var(--space-7);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-lg);
      background: var(--surface);
      text-align: center;
    }

    /* 竖屏／窄屏：面板落到播放器下方，集号改成**横向**一条带子。
       纵向铺时几十集会把页面拉得很长，读者要滚很久才回到正文；横着一条则只占
       一行高度，左右滑动看完。 */
    @media (max-width: 1049px) {
      .watch-layout.is-episode-workspace { grid-template-columns: minmax(0, 1fr); }
      /* 高度对齐只在左右并排时才有意义；堆叠之后面板按内容高度走。 */
      .episode-panel { max-height: none; overflow: visible; }
      .episode-number-grid {
        /* 关键是这三条：`auto-flow: column` 让它横着排，`grid-auto-columns` 给
           每格一个固定宽度，`min-width: 0` 让轨道能被压缩——漏掉最后一条，
           轨道的固有宽度会把整块撑出屏幕，横向滚动会跑到页面上而不是留在这条
           带子里。 */
        grid-auto-flow: column;
        grid-auto-columns: var(--episode-cell);
        grid-template-columns: none;
        min-width: 0;
        max-width: 100%;
        overflow-x: auto;
        overflow-y: hidden;
        overscroll-behavior-x: contain;
        padding-bottom: var(--space-2);
      }
    }
    @media (max-width: 719px) {
      .synopsis { grid-template-columns: minmax(0, 1fr); }
      .synopsis .poster { max-width: 168px; }
      .player-overlay-controls { padding: var(--space-6) var(--space-2) var(--space-2); }
      .player-control-row { gap: var(--space-2); }
      .player-control-group-end { gap: var(--space-2); }
      /* 手机上收掉的是整簇音量，而不是音量和倍速一起。
         音量归系统音量键管，iOS Safari 的原生播放器同样不画这条滑杆；倍速没有
         任何系统入口，收掉就等于没有了，所以它留下——它本来就只是一个很窄的
         下拉。 */
      .player-volume-cluster { display: none; }
      .playback-time { margin-left: var(--space-1); }
    }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const player = document.getElementById('player');
      const playerStage = document.getElementById('player-stage');
      const playerLanding = document.getElementById('player-landing');
      const workspace = document.getElementById('player-workspace');
      const directButton = document.getElementById('direct-play');
      const defaultSizeButton = document.getElementById('default-size');
      const wideSizeButton = document.getElementById('wide-size');
      const webFullscreenButton = document.getElementById('web-fullscreen');
      const retrySourceButton = document.getElementById('retry-source');
      const transportControls = document.getElementById('transport-controls');
      const transportPlayButton = document.getElementById('transport-play');
      const seekBackwardButton = document.getElementById('seek-backward');
      const seekForwardButton = document.getElementById('seek-forward');
      const muteButton = document.getElementById('toggle-mute');
      const volumeControl = document.getElementById('playback-volume');
      const volumeValue = document.getElementById('playback-volume-value');
      const playbackSeek = document.getElementById('playback-seek');
      const playbackTime = document.getElementById('playback-time');
      const transportPlayIcon = document.getElementById('transport-play-icon');
      const transportPauseIcon = document.getElementById('transport-pause-icon');
      const volumeOnIcon = document.getElementById('volume-on-icon');
      const volumeOffIcon = document.getElementById('volume-off-icon');
      // 「下一集」不再是传输栏里的按钮——换集是导航，不是播放控制，它属于右侧
      // 选集面板。自动播放下一集仍然需要知道目标，所以目标随文档属性一起来。
      const nextEpisodePath = document.body.dataset.nextEpisodePath || '';
      const speedControl = document.getElementById('playback-speed');
      const fullscreenButton = document.getElementById('fullscreen');
      const fullscreenEnterIcon = document.getElementById('fullscreen-enter-icon');
      const fullscreenExitIcon = document.getElementById('fullscreen-exit-icon');
      const pictureInPictureButton = document.getElementById('picture-in-picture');
      const addToQueueButton = document.getElementById('add-to-queue');
      const favoriteButton = document.getElementById('toggle-favorite');
      const watchlistButton = document.getElementById('toggle-watchlist');
      const ratingStars = Array.from(document.querySelectorAll('.rating-star'));
      const ratingValue = document.getElementById('user-rating-value');
      const status = document.getElementById('player-status');
      const episodePanel = document.getElementById('episode-panel');
      const episodeGrid = document.getElementById('episode-grid');
      const episodeGridStatus = document.getElementById('episode-grid-status');
      const episodeLoadMoreButton = document.getElementById('episode-load-more');
      const episodeSeasonTabs = Array.from(document.querySelectorAll('.episode-season-tab'));
      const itemID = document.body.dataset.itemId || '';
      const mediaKind = document.body.dataset.mediaKind || 'video';
      const canDirectPlay = document.body.dataset.canDirectPlay === 'true';
      const browserContentType = document.body.dataset.browserContentType || '';
      const seriesID = document.body.dataset.seriesId || '';
      const currentSeason = document.body.dataset.currentSeason || 'unspecified';
      const currentEpisode = document.body.dataset.currentEpisode || '';
      const resumePosition = Number(document.body.dataset.resumePosition || 0);
      const lifecycle = new AbortController();
      const subtitlePath = (trackID) => `/api/v1/subtitles/${encodeURIComponent(itemID)}/${encodeURIComponent(String(trackID))}`;
      const csrfToken = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
      var isStarting = false;
      var resumeApplied = false;
      var playbackStartedReported = false;
      var lastProgressBucket = -1;
      var playbackTracksLoaded = false;
      var playbackCompleted = false;
      // ---- 播放通路 ---------------------------------------------------------
      // `direct` 是浏览器自己解容器的那条路；`remux` 是服务端只把音频转成 AAC、
      // 画面原样搬进分片 MP4 的那条路。后者存在的理由：MKV 里常见的 AC-3 / DTS
      // 没有任何浏览器能解码，直放得到的是**有画面没有声音**，而且不报错。
      //
      // 分片流是边转边发的，长度未知、不能 Range，所以跳转靠"改 start= 重开一条
      // 流"完成。`remuxOffset` 就是那条流的起点在整部片子里的秒数——画面上那条
      // 时间轴始终是整部片子的，不是这一条流的。
      var playbackMode = 'direct';
      var remuxOffset = 0;
      var remuxAudioTrack = 0;
      var playbackTracks = null;
      const knownDurationSeconds = Number(document.body.dataset.durationSeconds || 0) || 0;
      var playerLayout = 'default';
      var activeEpisodeSeason = currentSeason;
      var episodeOffset = 0;
      var episodeHasMore = false;
      var episodeLoading = false;
      var overlayHideTimer = null;
      var transportFrame = null;
      var preference = {
        isFavorite: document.body.dataset.isFavorite === 'true',
        isWatchlist: document.body.dataset.isWatchlist === 'true',
        rating: Number(document.body.dataset.preferenceRating || 0) || null
      };

      const playerBusy = document.getElementById('player-busy');
      const playerError = document.getElementById('player-error');
      const playerErrorMessage = document.getElementById('player-error-message');
      // 一条状态，两种形态：读屏走 `#player-status` 的 live region，眼睛走画面上
      // 的错误卡。此前只有前者，于是能看见的读者反而什么反馈都没有。
      const setStatus = (message, isError = false) => {
        if (status) {
          status.textContent = message;
          status.classList.toggle('error', isError);
        }
        if (!playerError || !playerErrorMessage) return;
        playerErrorMessage.textContent = isError ? message : '';
        playerError.hidden = !isError || !message;
        if (isError) setBufferingVisible(false);
      };
      // 缓冲指示要压一压再露头：起播顺利时它只会闪一下，那一下比不显示更吵。
      //
      // ⚠️ 名字不能叫 `setBusy`——这个作用域里已经有一个同名函数（它管的是播放
      // 按钮的忙碌态），两个 `const` 同名会让整个脚本直接抛 SyntaxError，播放器
      // 一个控件都不会响应。
      var bufferingTimer = null;
      const setBufferingVisible = active => {
        if (!playerBusy) return;
        if (bufferingTimer !== null) { window.clearTimeout(bufferingTimer); bufferingTimer = null; }
        if (!active) { playerBusy.hidden = true; return; }
        bufferingTimer = window.setTimeout(() => { bufferingTimer = null; playerBusy.hidden = false; }, 320);
      };
      const showOverlayControls = (keepVisible = false) => {
        if (!playerStage || transportControls.hidden) return;
        playerStage.classList.add('controls-visible');
        if (overlayHideTimer !== null) window.clearTimeout(overlayHideTimer);
        if (keepVisible || player.paused || document.fullscreenElement || document.body.classList.contains('is-web-fullscreen')) return;
        overlayHideTimer = window.setTimeout(() => {
          overlayHideTimer = null;
          if (!player.paused && !document.querySelector('.player-settings[open]')) playerStage.classList.remove('controls-visible');
        }, 2800);
      };
      const hideOverlayControls = () => {
        if (overlayHideTimer !== null) window.clearTimeout(overlayHideTimer);
        overlayHideTimer = null;
        if (!player.paused && !document.querySelector('.player-settings[open]')) playerStage?.classList.remove('controls-visible');
      };
      const setBusy = (busy) => {
        isStarting = busy;
        // 起播期间用同一个可见指示：从按下播放到第一帧解码出来这段时间，画面
        // 上原本什么都没有。
        setBufferingVisible(busy);
        directButton.disabled = busy || !canDirectPlay;
        directButton.setAttribute('aria-busy', String(busy));
        directButton.setAttribute('aria-label', busy ? '正在准备播放' : (hasPlayableSource() ? '重新播放' : '播放'));
      };
      // 选集面板的高度永远等于左边播放器卡片的高度。
      //
      // CSS 拿不到另一个网格项的高度，所以只能量。量到的值写进
      // `--episode-panel-height`，面板据此封顶、集号格自己滚——而不是把整行撑高，
      // 让播放器旁边空出一大条。
      //
      // 顺带按剩余高度切换集号格的密度：先缩小格子（缩到安全下限为止），实在不够
      // 再交给滚动。触摸下不缩，44px 是触摸目标下限。
      var episodePanelFrame = null;
      const syncEpisodePanelHeight = () => {
        episodePanelFrame = null;
        if (!workspace || !episodePanel) return;
        const playerCard = workspace.querySelector('.player-card');
        // 只有"面板在播放器**旁边**"时，对齐高度才有意义。
        //
        // 宽屏与窄屏堆叠下面板都在播放器下方，这时把它撑到播放器那么高，得到的
        // 是一张几百像素高、里面只有一行内容的空卡片——图里那一大片白正是这么
        // 来的。`is-wide` 从前不在判断里。
        const sideBySide = workspace.classList.contains('is-episode-workspace')
          && !workspace.classList.contains('is-wide')
          && !window.matchMedia('(max-width: 1049px)').matches;
        if (!playerCard || !sideBySide || document.body.classList.contains('is-web-fullscreen')) {
          workspace.style.removeProperty('--episode-panel-height');
          episodePanel.removeAttribute('data-density');
          return;
        }
        const available = Math.round(playerCard.getBoundingClientRect().height);
        if (available <= 0) return;
        workspace.style.setProperty('--episode-panel-height', `${available}px`);
        // 面板里除集号格之外的部分（标题、季标签、状态行、加载更多）先占掉一部分。
        const grid = document.getElementById('episode-grid');
        const chrome = Math.max(0, episodePanel.getBoundingClientRect().height - (grid ? grid.getBoundingClientRect().height : 0));
        const forGrid = available - chrome;
        if (forGrid >= 260) episodePanel.removeAttribute('data-density');
        else if (forGrid >= 180) episodePanel.dataset.density = 'compact';
        else episodePanel.dataset.density = 'dense';
      };
      const scheduleEpisodePanelHeight = () => {
        if (episodePanelFrame !== null) return;
        episodePanelFrame = window.requestAnimationFrame(syncEpisodePanelHeight);
      };
      if (episodePanel && workspace && typeof window.ResizeObserver === 'function') {
        const observer = new window.ResizeObserver(scheduleEpisodePanelHeight);
        const playerCard = workspace.querySelector('.player-card');
        if (playerCard) observer.observe(playerCard);
        lifecycle.signal.addEventListener('abort', () => { observer.disconnect(); }, { once: true });
      }
      window.addEventListener('resize', scheduleEpisodePanelHeight, { signal: lifecycle.signal });
      // 页面不可见时 `requestAnimationFrame` 根本不跑，所以隐藏期间量到的值会一直
      // 留着。回到前台补一次，否则读者切回来看到的是上一次的高度。
      document.addEventListener('visibilitychange', () => {
        if (!document.hidden) scheduleEpisodePanelHeight();
      }, { signal: lifecycle.signal });
      scheduleEpisodePanelHeight();

      // 尺寸切换只有在"播放器旁边真的坐着一块面板"时才有意义。
      //
      // 只有一集的剧集、电影、音乐会录像这些没有选集面板的页面，本来就是整幅
      // 单列——切到"宽屏"什么都不会变，再切回"默认尺寸"同样什么都不会变。那颗
      // 按钮点下去没有任何反应，它存在的唯一作用是让人怀疑是不是坏了。窄屏堆叠
      // 时同理。
      const layoutToggleIsMeaningful = () => Boolean(workspace)
        && workspace.classList.contains('is-episode-workspace')
        && !window.matchMedia('(max-width: 1049px)').matches;
      const syncLayoutButtons = () => {
        const meaningful = layoutToggleIsMeaningful();
        defaultSizeButton?.setAttribute('aria-pressed', String(playerLayout === 'default'));
        wideSizeButton?.setAttribute('aria-pressed', String(playerLayout === 'wide'));
        // 只留下"能切过去"的那一档。已经是当前尺寸的那颗按钮按下去什么都不会
        // 发生——摆在那里只是让人多认一个图标。
        if (defaultSizeButton) defaultSizeButton.hidden = !meaningful || playerLayout === 'default';
        if (wideSizeButton) wideSizeButton.hidden = !meaningful || playerLayout === 'wide';
      };
      const setPlayerLayout = (layout) => {
        if (!workspace || !playerStage) return;
        playerLayout = layout === 'wide' ? 'wide' : 'default';
        workspace.classList.toggle('is-wide', playerLayout === 'wide');
        document.body.classList.remove('is-web-fullscreen');
        // 直接量一次，不走 `requestAnimationFrame`。
        //
        // 切换尺寸是一次离散的动作，不是需要合帧的连续事件；而 rAF 在页面不可见
        // 时**根本不跑**。走排队的话，切到宽屏时那条"面板高度等于播放器"的旧上限
        // 会一直留在行内样式里——读者切回来看到的就是一张被撑高的空卡片。
        syncEpisodePanelHeight();
        syncLayoutButtons();
        webFullscreenButton?.setAttribute('aria-pressed', 'false');
        if (playerLayout === 'wide') void loadWideEpisodeRows();
        else if (seriesID) void loadEpisodeSeason(activeEpisodeSeason, true);
      };
      const toggleWebFullscreen = () => {
        if (!workspace) return;
        const active = !document.body.classList.contains('is-web-fullscreen');
        document.body.classList.toggle('is-web-fullscreen', active);
        webFullscreenButton?.setAttribute('aria-pressed', String(active));
        if (active) playerStage.focus({ preventScroll: true });
        // 进出网页全屏会整个换掉播放器的盒子，面板的高度预算必须跟着重算——
        // 同样直接量，理由与切换尺寸时一致。
        syncEpisodePanelHeight();
      };
      const nextEpisodeURL = () => {
        if (!nextEpisodePath) return null;
        try {
          const value = new URL(nextEpisodePath, window.location.origin);
          return value.origin === window.location.origin && value.pathname.startsWith('/item/') && !value.search ? value : null;
        } catch (_) { return null; }
      };
      const mediaPath = (prefix) => `${prefix}${encodeURIComponent(itemID)}`;
      // BCP-47 形状校验：只放行 `zh`、`zh-Hans`、`en-US` 这类标记。服务端解析
      // 不出语言时给 `und`，浏览器会把它当未知语言，正是我们要的语义。
      const subtitleLanguage = value => {
        if (typeof value !== 'string') return 'und';
        const normalized = value.trim().slice(0, 20);
        return /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/.test(normalized) ? normalized : 'und';
      };

      /// 按浏览器语言挑一条默认字幕。
      //
      // 匹配分三档，取分最高的一条：完整标记相同（`zh-Hans` = `zh-Hans`）、
      // 主语言加书写系统相同、仅主语言相同（`zh` 对 `zh-Hant`）。一条都匹配不上
      // 就保持关闭——硬塞一条读者看不懂的字幕比不开更糟。
      // 用户一旦自己选过字幕，自动归一就必须让位——否则某条轨道晚一步加载完成
      // 就会把读者刚选的那条顶掉。
      var subtitleChoiceLocked = false;
      function applyPreferredSubtitle() {
        if (subtitleChoiceLocked || !player.textTracks) return;
        const subtitles = Array.from(player.textTracks).filter(track => track.kind === 'subtitles');
        if (subtitles.length === 0) return;
        // 必须无条件归一，不能"已有 showing 就跳过"。浏览器会在插入 `<track>`
        // 时自作主张地开字幕——实测 Chrome 把**每一条**轨都置成 showing（addtrack
        // 事件里就已经是了），于是屏幕上同时叠着中英两份字幕。先全关，再至多开一条。
        subtitles.forEach(track => { track.mode = 'disabled'; });
        const preferred = (window.navigator?.languages && window.navigator.languages.length
          ? Array.from(window.navigator.languages)
          : [window.navigator?.language || '']).filter(Boolean).map(tag => tag.toLowerCase());
        if (preferred.length === 0) return;
        // 浏览器报的是地区（`zh-CN`），字幕轨带的是书写系统（`zh-Hans`），两者不能
        // 直接比对。四字母子标签是书写系统，两字母是地区；中文再按地区反推书写
        // 系统，否则同时存在简繁两轨时会各得同分，选中哪条只看遍历顺序。
        const regionScript = { cn: 'hans', sg: 'hans', my: 'hans', tw: 'hant', hk: 'hant', mo: 'hant' };
        const parse = tag => {
          const parts = String(tag || '').toLowerCase().split('-').filter(Boolean);
          const base = parts[0] || '';
          let script = '';
          let region = '';
          parts.slice(1).forEach(part => {
            if (part.length === 4 && !script) script = part;
            else if (part.length === 2 && !region) region = part;
          });
          if (!script && base === 'zh' && regionScript[region]) script = regionScript[region];
          return { full: parts.join('-'), base, script };
        };
        let best = null;
        subtitles.forEach(track => {
          const candidate = parse(track.language);
          if (!candidate.base || candidate.base === 'und') return;
          preferred.forEach((tag, order) => {
            const wanted = parse(tag);
            if (wanted.base !== candidate.base) return;
            let score = 1;
            if (candidate.script && wanted.script && candidate.script === wanted.script) score = 3;
            else if (candidate.full === wanted.full) score = 3;
            else if (!candidate.script || !wanted.script) score = 2;
            // 浏览器语言列表是有序偏好，越靠前越优先。
            const ranked = score * 100 - order;
            if (!best || ranked > best.ranked) best = { track, ranked };
          });
        });
        // 匹配不上就保持全关：硬塞一条读者看不懂的字幕比不开更糟。
        if (best) best.track.mode = 'showing';
        buildSubtitleMenu();
      }

      const subtitleLabel = (value, fallback) => {
        if (typeof value !== 'string') return fallback;
        const normalized = value.trim().slice(0, 80);
        return normalized || fallback;
      };
      /// 向服务端要这个条目的**全部**可选轨道。
      //
      // 从前网页只问外挂字幕（`/api/v1/playback/subtitles/`），音轨则完全交给
      // `HTMLMediaElement.audioTracks`。两件事都不成立：内封在 MKV 里的字幕浏览器
      // 看不见，而 `audioTracks` 只有 Safari 实现——Chrome 和 Firefox 里那个音轨
      // 菜单的 `hidden` 从来没被摘掉过。服务端有 ffprobe，它看得见容器里的每一条流。
      //
      // 这件事必须在**起播之前**做完：要不要走重封装，取决于默认音轨浏览器能不能
      // 解码，而那正是"部分格式没有声音"的判定点。
      async function loadPlaybackTracks() {
        if (mediaKind !== 'video' || playbackTracksLoaded || !itemID) return;
        playbackTracksLoaded = true;
        try {
          const response = await fetch(mediaPath('/api/v1/playback/tracks/'), {
            credentials: 'same-origin', headers: { 'Accept': 'application/json' }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('unavailable');
          const payload = await response.json();
          if (!payload || typeof payload !== 'object') throw new Error('invalid');
          playbackTracks = {
            audio: Array.isArray(payload.audio) ? payload.audio : [],
            subtitles: Array.isArray(payload.subtitles) ? payload.subtitles : [],
            remuxable: payload.remuxable === true,
            remuxUnavailableReason: typeof payload.remuxUnavailableReason === 'string'
              ? payload.remuxUnavailableReason : ''
          };
          attachSubtitleTracks(playbackTracks.subtitles);
          buildAudioMenu();
        } catch (_) {
          // 轨道发现失败不影响直放，也不回显服务器文件信息。下次进播放页再试。
          playbackTracksLoaded = false;
        }
      }
      function attachSubtitleTracks(tracks) {
        tracks.slice(0, 16).forEach((track, index) => {
          if (!Number.isInteger(track?.id) || track.id < 0 || track.id >= 16) return;
          const element = document.createElement('track');
          element.kind = 'subtitles';
          element.label = subtitleLabel(track.label, `字幕 ${index + 1}`);
          // 语言由服务端解析——外挂字幕从文件名，内封轨从容器标签，远程轨从来源
          // 服务器。`und` 是从前的硬编码值，它让"按浏览器语言选默认字幕"无从判断。
          element.srclang = subtitleLanguage(track.language);
          element.src = subtitlePath(track.id);
          // 轨道资源加载完成时浏览器会**重新**决定 mode，把我们刚归一好的结果
          // 覆盖掉（实测 Chrome 会把多条轨一起打开）。所以每条轨加载/失败后都
          // 再归一一次；这个函数是幂等的，重复执行没有副作用。
          element.addEventListener('load', applyPreferredSubtitle);
          element.addEventListener('error', applyPreferredSubtitle);
          player.append(element);
        });
        // 这一页自己拥有传输控件（原生控件被显式关掉），所以字幕必须有自己的
        // 选择入口——从前它们被挂上去了，却没有任何地方能选中它们。
        applyPreferredSubtitle();
        buildSubtitleMenu();
      }
      /// 默认应该走哪条通路。
      //
      // 只有一种情况必须换路：默认音轨的编码浏览器解不了。那时直放出来的是一段
      // 无声的视频，而且不会有任何错误事件——读者只能自己发现"这个格式没有声音"。
      const preferredAudioTrack = () => {
        const tracks = playbackTracks?.audio ?? [];
        if (tracks.length === 0) return null;
        return tracks.find(track => track.isDefault) ?? tracks[0];
      };
      const directPlayHasSound = () => {
        const tracks = playbackTracks?.audio ?? [];
        // 探不到轨道（没有 ffprobe、远程来源）时不做判断：直放照旧，这与从前
        // 的行为一致，只是不再对"确实解不了"的那些文件也一起沉默。
        if (tracks.length === 0) return true;
        return preferredAudioTrack()?.browserPlayable === true;
      };

      // ---- Track menus ------------------------------------------------------
      // Both menus are <details> inside the stage rather than document-level
      // popovers: a popover positioned in page coordinates disappears the moment
      // the player enters native fullscreen, which is exactly when a viewer
      // reaches for subtitles.
      function trackButton(label, active, onSelect) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'player-track-item';
        button.setAttribute('role', 'menuitemradio');
        button.setAttribute('aria-checked', active ? 'true' : 'false');
        button.textContent = label;
        button.addEventListener('click', () => {
          onSelect();
          button.closest('details')?.removeAttribute('open');
        });
        return button;
      }
      /// 面板里的分组小标题。三种来源的字幕经常同名（都叫"简体中文"），不分组的话
      /// 菜单里会出现两三条看起来一模一样的选项。
      function trackGroupHeading(text) {
        const heading = document.createElement('p');
        heading.className = 'player-track-group';
        heading.textContent = text;
        return heading;
      }
      const subtitleOriginNames = { sidecar: '外挂字幕', embedded: '内封字幕', remote: '来源服务器' };

      function buildSubtitleMenu() {
        const menu = document.getElementById('subtitle-menu');
        const panel = document.getElementById('subtitle-panel');
        if (!menu || !panel || !player.textTracks) return;
        const tracks = Array.from(player.textTracks).filter(track => track.kind === 'subtitles');
        if (tracks.length === 0) { menu.hidden = true; return; }
        const activeIndex = tracks.findIndex(track => track.mode === 'showing');
        const select = index => {
          subtitleChoiceLocked = true;
          tracks.forEach((track, position) => { track.mode = position === index ? 'showing' : 'disabled'; });
          buildSubtitleMenu();
        };
        const fragment = document.createDocumentFragment();
        fragment.append(trackButton('关闭字幕', activeIndex < 0, () => select(-1)));
        // `<track>` 是按服务端名单的顺序挂上去的，所以下标可以直接对回那份名单
        // 拿到来源。名单没到（异常回退）时不分组，仍然逐条列出。
        var lastOrigin = null;
        tracks.forEach((track, index) => {
          const origin = playbackTracks?.subtitles?.[index]?.origin;
          if (origin && origin !== lastOrigin && subtitleOriginNames[origin]) {
            fragment.append(trackGroupHeading(subtitleOriginNames[origin]));
            lastOrigin = origin;
          }
          fragment.append(trackButton(track.label || `字幕 ${index + 1}`, index === activeIndex, () => select(index)));
        });
        panel.replaceChildren(fragment);
        menu.hidden = false;
      }

      /// 音轨菜单由**服务端**的名单渲染。
      //
      // 从前它读 `HTMLMediaElement.audioTracks`：那个 API 只有 Safari 实现，于是
      // Chrome 和 Firefox 里这个菜单永远是 `hidden`。而且即便读得到，一条
      // `<video>` 也没有真正切换音轨的手段——换轨等于换一条只含目标音轨的流。
      function buildAudioMenu() {
        const menu = document.getElementById('audio-menu');
        const panel = document.getElementById('audio-panel');
        if (!menu || !panel) return;
        const tracks = playbackTracks?.audio ?? [];
        // 只有一条音轨、而且浏览器解得了它——没有任何可选的东西，不摆这个菜单。
        if (tracks.length < 2 && directPlayHasSound()) { menu.hidden = true; return; }
        const activeID = playbackMode === 'remux' ? remuxAudioTrack : (preferredAudioTrack()?.id ?? 0);
        const fragment = document.createDocumentFragment();
        tracks.forEach((track, index) => {
          const label = track.browserPlayable
            ? (track.label || `音轨 ${index + 1}`)
            : `${track.label || `音轨 ${index + 1}`}（需转码）`;
          fragment.append(trackButton(label, track.id === activeID, () => selectAudioTrack(track)));
        });
        if (!playbackTracks?.remuxable && playbackTracks?.remuxUnavailableReason) {
          const note = document.createElement('p');
          note.className = 'player-track-note';
          note.textContent = playbackTracks.remuxUnavailableReason;
          fragment.append(note);
        }
        panel.replaceChildren(fragment);
        menu.hidden = false;
      }

      /// 换音轨。
      //
      // 目标是第一条、而且浏览器自己解得了，就回到直放——那条路不占服务器 CPU，
      // 也支持真正的 Range 跳转。其余情况一律换一条重封装流，并把当前位置带过去。
      function selectAudioTrack(track) {
        if (!track || !playbackTracks) return;
        const position = timelinePosition();
        const isFirstBrowserPlayable = track.browserPlayable && track.id === (playbackTracks.audio[0]?.id ?? 0);
        if (isFirstBrowserPlayable) {
          if (playbackMode === 'direct') return;
          void startDirect({ resumeAt: position });
          return;
        }
        if (!playbackTracks.remuxable) {
          setStatus(playbackTracks.remuxUnavailableReason || '这台服务器现在没法切换音轨。', true);
          return;
        }
        void startRemux(track.id, position);
      }

      const seasonKeyIsSafe = value => value === 'unspecified' || /^\d{1,5}$/.test(value);
      const clearEpisodeSelection = () => {
        episodeGrid?.replaceChildren();
        episodeGrid?.classList.remove('wide-season-rows');
        episodeOffset = 0;
        episodeHasMore = false;
      };
      const renderEpisodeNumber = item => {
        const id = typeof item?.id === 'string' ? item.id : '';
        if (!id || !episodeGrid) return null;
        const link = document.createElement('a');
        link.className = 'episode-number';
        link.href = `/item/${encodeURIComponent(id)}#play`;
        const episodeNumber = Number.isInteger(item?.episodeNumber) ? item.episodeNumber : null;
        link.textContent = episodeNumber === null ? '—' : String(episodeNumber);
        link.setAttribute('aria-label', episodeNumber === null ? `播放 ${String(item?.title || '剧集')}` : `播放第 ${episodeNumber} 集：${String(item?.title || '未命名剧集')}`);
        link.title = String(item?.title || '未命名剧集').slice(0, 180);
        if (id === itemID || (currentEpisode && String(episodeNumber) === currentEpisode && activeEpisodeSeason === currentSeason)) {
          link.classList.add('current');
          link.setAttribute('aria-current', 'page');
        }
        return link;
      };
      const updateSeasonTabs = () => {
        episodeSeasonTabs.forEach(tab => {
          const selected = tab.dataset.season === activeEpisodeSeason;
          tab.setAttribute('aria-pressed', String(selected));
        });
      };
      async function requestEpisodePage(season, offset = 0) {
        if (!seriesID || !seasonKeyIsSafe(season)) return null;
        const controller = new AbortController();
        const timeout = window.setTimeout(() => controller.abort(), 10000);
        try {
          const query = new URLSearchParams({ season, offset: String(Math.max(offset, 0)), limit: '100' });
          const response = await fetch(`/api/v1/series/${encodeURIComponent(seriesID)}/episodes?${query.toString()}`, {
            credentials: 'same-origin', headers: { Accept: 'application/json' }, signal: controller.signal
          });
          if (response.status === 401) { window.location.assign('/login'); return null; }
          if (!response.ok) throw new Error('unavailable');
          const page = await response.json();
          return Array.isArray(page?.items) ? page : null;
        } catch (error) {
          if (episodeGridStatus) episodeGridStatus.textContent = error?.name === 'AbortError' ? '选集请求超时，请重试。' : '暂时无法读取选集。';
          return null;
        } finally { window.clearTimeout(timeout); }
      }
      async function loadEpisodeSeason(season, reset = false) {
        if (!episodeGrid || episodeLoading || !seasonKeyIsSafe(season)) return;
        if (reset) clearEpisodeSelection();
        if (!reset && !episodeHasMore) return;
        activeEpisodeSeason = season;
        updateSeasonTabs();
        episodeLoading = true;
        if (episodeGridStatus) episodeGridStatus.textContent = episodeOffset === 0 ? '正在载入剧集…' : '正在载入更多剧集…';
        if (episodeLoadMoreButton) episodeLoadMoreButton.disabled = true;
        const page = await requestEpisodePage(activeEpisodeSeason, episodeOffset);
        if (page && playerLayout === 'default') {
          const fragment = document.createDocumentFragment();
          page.items.forEach(item => { const node = renderEpisodeNumber(item); if (node) fragment.append(node); });
          episodeGrid.append(fragment);
          episodeOffset += page.items.length;
          episodeHasMore = page.hasMore === true;
          if (episodeGridStatus) episodeGridStatus.textContent = page.items.length || episodeOffset ? '' : '这一季没有可播放剧集。';
        }
        if (episodeLoadMoreButton) {
          episodeLoadMoreButton.hidden = !episodeHasMore;
          episodeLoadMoreButton.disabled = false;
        }
        episodeLoading = false;
      }
      async function loadWideEpisodeRows() {
        if (!episodeGrid || !seriesID || episodeLoading) return;
        episodeLoading = true;
        episodeGrid.replaceChildren();
        episodeGrid.classList.add('wide-season-rows');
        if (episodeGridStatus) episodeGridStatus.textContent = '正在载入各季剧集…';
        if (episodeLoadMoreButton) episodeLoadMoreButton.hidden = true;
        try {
          const seasons = Array.from(episodeSeasonTabs, tab => ({ tab, season: tab.dataset.season || '' }));
          const pages = new Array(seasons.length).fill(null);
          // Each season query is independent.  A bounded pool makes the wide
          // Bilibili-style selector feel immediate on multi-season shows while
          // keeping the local service and remote Mlink sources from receiving
          // an unbounded burst of requests.
          var nextSeasonIndex = 0;
          const workerCount = Math.min(4, seasons.length);
          await Promise.all(Array.from({ length: workerCount }, async () => {
            while (nextSeasonIndex < seasons.length) {
              const index = nextSeasonIndex++;
              pages[index] = await requestEpisodePage(seasons[index].season, 0);
            }
          }));
          if (playerLayout !== 'wide') return;
          const fragment = document.createDocumentFragment();
          seasons.forEach(({ tab }, index) => {
            const page = pages[index];
            if (!page) return;
            const row = document.createElement('section');
            row.className = 'wide-season-row';
            const title = document.createElement('h3');
            title.textContent = tab.childNodes[0]?.textContent?.trim() || '未分季';
            const numbers = document.createElement('div');
            numbers.className = 'episode-number-grid';
            page.items.forEach(item => {
              const id = typeof item?.id === 'string' ? item.id : '';
              if (!id) return;
              const link = document.createElement('a');
              link.className = 'episode-number';
              link.href = `/item/${encodeURIComponent(id)}#play`;
              const number = Number.isInteger(item?.episodeNumber) ? item.episodeNumber : '—';
              link.textContent = String(number);
              link.title = String(item?.title || '未命名剧集').slice(0, 180);
              link.setAttribute('aria-label', `播放第 ${number} 集：${String(item?.title || '未命名剧集')}`);
              if (id === itemID) { link.classList.add('current'); link.setAttribute('aria-current', 'page'); }
              numbers.append(link);
            });
            row.append(title, numbers);
            fragment.append(row);
          });
          episodeGrid.append(fragment);
          if (episodeGridStatus) episodeGridStatus.textContent = '';
        } finally {
          episodeLoading = false;
          // A quick wide → default switch previously left the default selector
          // empty until another click.  Restore its one-season request once
          // pending wide rows have settled, regardless of success or failure.
          if (playerLayout !== 'wide' && seriesID) void loadEpisodeSeason(activeEpisodeSeason, true);
        }
      }
      const normalizedPreference = (value) => {
        const rating = typeof value?.rating === 'number' && Number.isFinite(value.rating) && value.rating > 0 && value.rating <= 5
          ? value.rating : null;
        return { isFavorite: value?.isFavorite === true, isWatchlist: value?.isWatchlist === true, rating };
      };
      const renderPreference = () => {
        favoriteButton.setAttribute('aria-pressed', String(preference.isFavorite));
        favoriteButton.textContent = preference.isFavorite ? '已收藏' : '收藏';
        watchlistButton.setAttribute('aria-pressed', String(preference.isWatchlist));
        watchlistButton.textContent = preference.isWatchlist ? '已加入想看' : '加入想看';
        ratingStars.forEach((star) => {
          const rating = Number(star.dataset.rating);
          const selected = Number.isFinite(rating) && preference.rating !== null && preference.rating >= rating - 0.5;
          star.setAttribute('aria-pressed', String(selected));
        });
        ratingValue.textContent = preference.rating ? `${preference.rating.toFixed(1)} / 5` : '未评分';
      };
      async function updatePreference(field, value, control) {
        if (!itemID) return;
        control.disabled = true;
        try {
          const response = await fetch(mediaPath('/api/v1/user-media/preferences/'), {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken },
            body: JSON.stringify({ [field]: value })
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('unavailable');
          preference = normalizedPreference(await response.json());
          renderPreference();
          setStatus('清单已更新。');
        } catch (_) {
          setStatus('没能更新，请稍后再试。', true);
          renderPreference();
        } finally {
          control.disabled = false;
        }
      }
      async function addToQueue() {
        if (!itemID || !addToQueueButton) return;
        addToQueueButton.disabled = true;
        try {
          const response = await fetch('/api/v1/queue', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken },
            body: JSON.stringify({ action: 'add', mediaID: itemID })
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('unavailable');
          await response.json();
          addToQueueButton.textContent = '已加入播放队列';
          setStatus('已加入播放队列。');
        } catch (_) {
          addToQueueButton.disabled = false;
          setStatus('没能加入队列，请稍后再试。', true);
        }
      }
      const finitePlaybackNumber = (value) => Number.isFinite(value) && value >= 0 ? value : 0;
      const hasPlayableSource = () => [player.currentSrc, player.src].some((source) => typeof source === 'string' && source.length > 0);
      // ---- 虚拟时间轴 -------------------------------------------------------
      // 直放时它就是媒体元素自己的时间。重封装时元素只知道"从 remuxOffset 开始的
      // 这一段"，整部片子的位置要把偏移加回去；总长度则来自资料库里存的时长——
      // 分片流的 `duration` 是 Infinity，拿它当分母进度条会一直停在 0。
      const timelinePosition = () => finitePlaybackNumber(player.currentTime)
        + (playbackMode === 'remux' ? remuxOffset : 0);
      const timelineDuration = () => {
        if (playbackMode === 'remux') return knownDurationSeconds > 0 ? knownDurationSeconds : NaN;
        return player.duration;
      };
      // 这一条流已经缓冲到整部片子的第几秒。
      const timelineBufferedEnd = () => {
        if (!player.buffered || player.buffered.length === 0) return 0;
        const local = finitePlaybackNumber(player.currentTime);
        for (let index = 0; index < player.buffered.length; index += 1) {
          if (player.buffered.start(index) <= local && local <= player.buffered.end(index)) {
            return player.buffered.end(index) + (playbackMode === 'remux' ? remuxOffset : 0);
          }
        }
        return 0;
      };
      // 跳到整部片子的第 `target` 秒。
      //
      // 重封装时优先在**当前这条流内部**跳（目标已经缓冲过就不必重开），否则换一条
      // 从目标处开始的流。重开一条流要几百毫秒，不该为了向前三秒付这个代价。
      const seekTimeline = (target) => {
        const duration = timelineDuration();
        const upper = Number.isFinite(duration) && duration > 0 ? duration : Number.MAX_SAFE_INTEGER;
        const clamped = Math.min(Math.max(target, 0), upper);
        if (playbackMode !== 'remux') {
          if (Number.isFinite(player.currentTime)) player.currentTime = clamped;
          return;
        }
        const local = clamped - remuxOffset;
        if (local >= 0 && local <= timelineBufferedEnd() - remuxOffset) {
          player.currentTime = local;
          return;
        }
        void startRemux(remuxAudioTrack, clamped);
      };
      const browserCanPlay = () => !browserContentType || typeof player.canPlayType !== 'function' || player.canPlayType(browserContentType) !== '';
      const formatClock = (seconds) => {
        if (!Number.isFinite(seconds) || seconds < 0) return '--:--';
        const rounded = Math.floor(seconds);
        const hours = Math.floor(rounded / 3600);
        const minutes = Math.floor((rounded % 3600) / 60);
        const remainingSeconds = rounded % 60;
        return hours > 0
          ? `${hours}:${String(minutes).padStart(2, '0')}:${String(remainingSeconds).padStart(2, '0')}`
          : `${minutes}:${String(remainingSeconds).padStart(2, '0')}`;
      };
      // Keep the visible glyphs tied to the media element—not to the click
      // that happened to initiate a state change. This also covers keyboard,
      // Media Session and browser-native controls consistently.
      const setIconVisibility = (icon, visible) => {
        if (!icon) return;
        icon.hidden = !visible;
        if (visible) icon.removeAttribute('hidden'); else icon.setAttribute('hidden', '');
      };
      const syncTransportIcons = () => {
        const isPaused = player.paused || player.ended;
        const isMuted = player.muted || player.volume === 0;
        setIconVisibility(transportPlayIcon, isPaused);
        setIconVisibility(transportPauseIcon, !isPaused);
        setIconVisibility(volumeOnIcon, !isMuted);
        setIconVisibility(volumeOffIcon, isMuted);
      };
      const updateTransportUI = () => {
        const available = hasPlayableSource();
        transportControls.hidden = !available;
        // The big centre triangle is the "start watching" affordance. Once the
        // picture is running the transport bar owns play/pause, so it must get
        // out of the way — it used to stay parked over the middle of the video
        // for the whole episode. It returns on pause and at the end, which is
        // what every video player does.
        directButton.hidden = available && !player.paused && !player.ended;
        transportPlayButton.disabled = !available;
        seekBackwardButton.disabled = !available;
        seekForwardButton.disabled = !available;
        muteButton.disabled = !available;
        volumeControl.disabled = !available;
        const timelineTotal = timelineDuration();
        playbackSeek.disabled = !available || !Number.isFinite(timelineTotal) || timelineTotal <= 0;
        const isMuted = player.muted || player.volume === 0;
        syncTransportIcons();
        transportPlayButton.setAttribute('aria-label', player.paused || player.ended ? '播放' : '暂停');
        muteButton.setAttribute('aria-label', isMuted ? '取消静音' : '静音');
        muteButton.setAttribute('aria-pressed', String(isMuted));
        const volumePercent = Math.round((Number.isFinite(player.volume) ? player.volume : 1) * 100);
        volumeControl.value = String(volumePercent / 100);
        volumeValue.textContent = `${volumePercent}%`;
        playbackTime.textContent = `${formatClock(timelinePosition())} / ${formatClock(timelineTotal)}`;
        if (Number.isFinite(timelineTotal) && timelineTotal > 0) {
          playbackSeek.max = String(timelineTotal);
          playbackSeek.value = String(Math.min(Math.max(timelinePosition(), 0), timelineTotal));
        } else {
          playbackSeek.max = '0';
          playbackSeek.value = '0';
        }
        paintSeekProgress();
      };
      // Browsers can emit media events faster than the display refresh rate.
      // Coalescing only the steady-state paint keeps the controls just as
      // responsive while avoiding repeated text/range/style writes in one
      // compositor frame.
      const scheduleTransportUI = () => {
        if (transportFrame !== null) return;
        transportFrame = window.requestAnimationFrame(() => {
          transportFrame = null;
          updateTransportUI();
        });
      };
      // WebKit has no `::-moz-range-progress` equivalent, so the played portion
      // is painted as a gradient stop the track reads from.
      function paintSeekProgress() {
        const max = Number(playbackSeek.max);
        const percent = max > 0 ? (Number(playbackSeek.value) / max) * 100 : 0;
        playbackSeek.style.setProperty('--progress', `${Math.min(Math.max(percent, 0), 100)}%`);
        // 已缓冲到哪儿。取的是**当前播放头所在的那一段**的末端，而不是
        // `buffered.end(length - 1)`：拖动过之后缓冲区会碎成好几段，最后一段可
        // 能远在播放头之后，画出来就是一条骗人的长条。重封装时这个值同样要换算
        // 回整部片子的时间轴，否则第 100 分钟起播的那条流会把缓冲画在最左边。
        const bufferedEnd = timelineBufferedEnd();
        if (max > 0 && bufferedEnd > 0) {
          const buffered = Math.min(Math.max((bufferedEnd / max) * 100, 0), 100);
          playbackSeek.style.setProperty('--buffered', `${buffered}%`);
        } else {
          playbackSeek.style.setProperty('--buffered', '0%');
        }
      }
      async function reportPlaybackState(event, keepalive = false) {
        // 上报的是整部片子里的位置，不是当前这条流里的位置——否则从第 100 分钟
        // 重开一条重封装流之后，续播点会被写回第 0 分钟。
        const positionSeconds = finitePlaybackNumber(timelinePosition());
        const reportedDuration = timelineDuration();
        const durationSeconds = Number.isFinite(reportedDuration) && reportedDuration > 0 ? reportedDuration : null;
        try {
          const response = await fetch(mediaPath('/api/v1/playback/state/'), {
            method: 'POST', credentials: 'same-origin', keepalive,
            headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken },
            body: JSON.stringify({ event, positionSeconds, durationSeconds })
          });
          if (!response.ok || keepalive) return;
          const state = await response.json();
          if (!state || typeof state.progress !== 'number' || typeof state.playCount !== 'number') return;
        } catch (_) { /* 状态同步失败不应中断本地播放。 */ }
      }
      // 固定档位。滑杆的值是档位**下标**而不是倍速本身：这样浏览器原生的拖动
      // 吸附、方向键步进与 `step=1` 天然就是一档一档的，不需要脚本再去把连续值
      // 往最近的档位上凑（那种做法在拖动过程中会来回跳）。
      const speedSteps = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
      const speedValueLabel = document.getElementById('playback-speed-value');
      const formatSpeed = rate => `${Number.isInteger(rate) ? rate : rate}×`;
      function setPlaybackRate() {
        const index = Number(speedControl.value);
        if (!Number.isInteger(index) || index < 0 || index >= speedSteps.length) return;
        const rate = speedSteps[index];
        player.playbackRate = rate;
        const text = formatSpeed(rate);
        if (speedValueLabel) speedValueLabel.textContent = text;
        // range 的原生可访问值是下标，对读屏软件毫无意义；用 aria-valuetext
        // 把它换成真实倍速。
        speedControl.setAttribute('aria-valuetext', text);
        setStatus(`播放速度已设为 ${text}。`);
      }
      async function toggleFullscreen() {
        try {
          if (document.fullscreenElement) await document.exitFullscreen();
          else if (typeof playerStage.requestFullscreen === 'function') await playerStage.requestFullscreen();
          else throw new Error('unsupported');
        } catch (_) { setStatus('这个浏览器不支持全屏播放。', true); }
      }
      async function togglePictureInPicture() {
        try {
          if (document.pictureInPictureElement) await document.exitPictureInPicture();
          else if (typeof player.requestPictureInPicture === 'function') await player.requestPictureInPicture();
          else throw new Error('unsupported');
        } catch (_) { setStatus('这个浏览器不支持画中画。', true); }
      }
      function updateFullscreenLabel() {
        if (!fullscreenButton) return;
        const isFullscreen = Boolean(document.fullscreenElement);
        const label = isFullscreen ? '退出全屏' : '全屏';
        fullscreenButton.setAttribute('aria-label', label);
        fullscreenButton.title = label;
        // 图标也得跟着换。从前这里只改了 aria-label 和 title：全屏之后按钮的
        // 名字变成了"退出全屏"，画的却还是"进入全屏"那个向外的箭头，读图的人
        // 和读屏的人被告知了两件相反的事。
        if (fullscreenEnterIcon) fullscreenEnterIcon.hidden = isFullscreen;
        if (fullscreenExitIcon) fullscreenExitIcon.hidden = !isFullscreen;
      }
      function isEditableTarget(target) {
        return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement || target?.isContentEditable === true;
      }
      async function togglePlayback() {
        if (!hasPlayableSource()) return startPlayback();
        try {
          if (player.paused) await player.play(); else player.pause();
        } catch (_) { setStatus('浏览器拦下了自动播放，点一下播放键就好。', true); }
      }
      function toggleMute() {
        if (player.muted || player.volume === 0) {
          if (player.volume === 0) player.volume = 1;
          player.muted = false;
        } else player.muted = true;
        setStatus(player.muted ? '已静音。' : '已取消静音。');
        updateTransportUI();
      }
      function setVolume() {
        const volume = Number(volumeControl.value);
        if (!Number.isFinite(volume) || volume < 0 || volume > 1) return;
        player.volume = volume;
        player.muted = volume === 0;
        updateTransportUI();
      }
      function seekBy(seconds) {
        if (!hasPlayableSource() || !Number.isFinite(player.currentTime)) return;
        seekTimeline(timelinePosition() + seconds);
        showOverlayControls();
      }
      function seekToControlPosition() {
        const nextPosition = Number(playbackSeek.value);
        const total = timelineDuration();
        if (!Number.isFinite(nextPosition) || !Number.isFinite(total) || total <= 0) return;
        seekTimeline(nextPosition);
        showOverlayControls();
      }
      const prepareNewSource = () => {
        resumeApplied = false;
        playbackStartedReported = false;
        lastProgressBucket = -1;
        playbackCompleted = false;
      };
      /// 播放入口。
      //
      // 起播前先把轨道名单问回来：默认音轨浏览器解不了时要直接走重封装，否则
      // 读者看到的是一段无声视频，而且没有任何提示。这一步很轻（一次 JSON），
      // 而且只在整个页面生命周期里做一次。
      async function startPlayback() {
        if (!canDirectPlay || isStarting) return;
        await loadPlaybackTracks();
        if (!directPlayHasSound() && playbackTracks?.remuxable) {
          const track = preferredAudioTrack();
          setStatus('这段视频的音轨浏览器解不了，正在改用服务器转码的音频。');
          // 续播点在直放那条路上由 `loadedmetadata` 处理；重封装这条路没有那一步
          // （流本来就从 `start=` 开始），所以要在这里把它交出去。
          const resumeAt = resumeApplied
            ? timelinePosition()
            : (Number.isFinite(resumePosition) && resumePosition >= 10 ? resumePosition : 0);
          await startRemux(track?.id ?? 0, resumeAt);
          return;
        }
        if (!directPlayHasSound()) {
          // 转不了也要说清楚：从前这里什么都不说，画面照常播放，声音没有。
          setStatus(
            playbackTracks?.remuxUnavailableReason
              || '这段视频的音轨编码浏览器无法解码，播放时不会有声音。',
            true
          );
        }
        await startDirect();
      }

      /// 浏览器直放：字节原样来自 `/api/v1/stream/`，支持 Range 跳转。
      async function startDirect(options = {}) {
        if (!canDirectPlay || isStarting) return;
        if (!browserCanPlay()) {
          setStatus('这个浏览器不支持这种视频格式。换一个浏览器试试。', true);
          return;
        }
        setBusy(true);
        const resumeAt = Number.isFinite(options.resumeAt) ? options.resumeAt : null;
        playbackMode = 'direct';
        remuxOffset = 0;
        prepareNewSource();
        player.hidden = false;
        player.removeAttribute('aria-hidden');
        // The page owns transport controls so the browser never overlays its
        // stale no-source/error affordance while a same-origin stream is loading.
        player.controls = false;
        playerLanding?.setAttribute('hidden', '');
        player.src = mediaPath('/api/v1/stream/');
        player.load();
        if (resumeAt !== null) {
          // 换轨回直放要接着刚才的位置，不能从头开始。
          resumeApplied = true;
          player.addEventListener('loadedmetadata', () => {
            if (Number.isFinite(player.duration)) player.currentTime = Math.min(resumeAt, player.duration);
          }, { once: true });
        }
        updateTransportUI();
        buildAudioMenu();
        setStatus('正在准备…');
        try {
          await player.play();
          setStatus('正在播放。');
        } catch (error) {
          setStatus(error?.name === 'NotAllowedError' ? '浏览器阻止了自动开始，请在播放器中再次按播放。' : '这个浏览器打不开这段视频。', true);
        } finally { setBusy(false); }
      }

      /// 服务端重封装：画面原样搬运，音频转成 AAC，输出分片 MP4。
      //
      // 这条流没有长度也不接受 Range，所以"从第几秒开始"是 URL 的一部分。跳转就是
      // 换一条 URL；画面上那条时间轴由 `remuxOffset` 补回整部片子的位置。
      /// 把想去的秒数换成**关键帧对齐后**的秒数。
      //
      // 重封装原样搬运画面，因此只能从关键帧起流：要第 7 秒而最近的关键帧在第 6 秒，服务端交
      // 出来的就是从第 6 秒开始的那一段，页面却按第 7 秒记时间轴——差值最多一整个
      // GOP，而且会一直留在这条流上（时间显示偏，续播点也跟着偏）。先问清楚落点，
      // 再拿这个值去起流，ffmpeg 的吸附就成了空操作。
      //
      // 问不到就用原值：那时的表现和从前一样，而不是拒绝播放。
      async function resolveRemuxStart(seconds) {
        const target = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
        if (target <= 0) return 0;
        try {
          const query = new URLSearchParams({ at: target.toFixed(3) });
          const response = await fetch(`${mediaPath('/api/v1/playback/keyframe/')}?${query.toString()}`, {
            credentials: 'same-origin', headers: { 'Accept': 'application/json' }
          });
          if (!response.ok) return target;
          const payload = await response.json();
          const resolved = Number(payload?.startSeconds);
          return Number.isFinite(resolved) && resolved >= 0 && resolved <= target ? resolved : target;
        } catch (_) { return target; }
      }

      async function startRemux(audioTrackID, startSeconds) {
        if (!canDirectPlay || !playbackTracks?.remuxable) return;
        const wasReported = playbackStartedReported;
        setBusy(true);
        playbackMode = 'remux';
        remuxAudioTrack = Number.isInteger(audioTrackID) && audioTrackID >= 0 ? audioTrackID : 0;
        remuxOffset = await resolveRemuxStart(startSeconds);
        prepareNewSource();
        // 换一条流不是"重新开始看"：起播上报只该发一次，否则播放次数会随着每次
        // 拖动进度条一起涨。
        playbackStartedReported = wasReported;
        resumeApplied = true;
        player.hidden = false;
        player.removeAttribute('aria-hidden');
        player.controls = false;
        playerLanding?.setAttribute('hidden', '');
        const query = new URLSearchParams({
          audio: String(remuxAudioTrack), start: remuxOffset.toFixed(3)
        });
        player.src = `${mediaPath('/api/v1/transcode/')}?${query.toString()}`;
        player.load();
        updateTransportUI();
        buildAudioMenu();
        setStatus('正在准备…');
        try {
          await player.play();
          setStatus('正在播放。');
        } catch (error) {
          setStatus(
            error?.name === 'NotAllowedError'
              ? '浏览器阻止了自动开始，请在播放器中再次按播放。'
              : '服务器没能转出这段视频。',
            true
          );
        } finally { setBusy(false); }
      }

      directButton.disabled = !canDirectPlay;
      if (!canDirectPlay) setStatus('这段内容现在播不了。确认存放它的硬盘或服务器已连接，然后重试。', true);
      else if (!browserCanPlay()) {
        directButton.disabled = true;
        directButton.setAttribute('aria-disabled', 'true');
        setStatus('这个浏览器不支持这种视频格式。换一个浏览器试试。', true);
      }
      renderPreference();
      // 轨道名单在**进入页面时**就问，不等按下播放。
      //
      // 字幕与音轨的入口属于"我打开这一集，先看看有没有中文字幕"这件事；从前它们
      // 要等到第一帧解码出来才出现，而音轨那个入口根本不会出现。
      void loadPlaybackTracks();
      // 窄屏与宽屏之间来回拖窗口时，这两颗按钮的有效性也跟着变。
      syncLayoutButtons();
      window.addEventListener('resize', syncLayoutButtons, { signal: lifecycle.signal });
      directButton.addEventListener('click', () => { void startPlayback(); });
      defaultSizeButton?.addEventListener('click', () => setPlayerLayout('default'));
      wideSizeButton?.addEventListener('click', () => setPlayerLayout('wide'));
      webFullscreenButton?.addEventListener('click', () => { toggleWebFullscreen(); showOverlayControls(true); });
      episodeSeasonTabs.forEach(tab => tab.addEventListener('click', () => {
        const season = tab.dataset.season || '';
        if (!seasonKeyIsSafe(season)) return;
        if (playerLayout === 'wide') {
          activeEpisodeSeason = season;
          updateSeasonTabs();
          return;
        }
        void loadEpisodeSeason(season, true);
      }));
      episodeLoadMoreButton?.addEventListener('click', () => void loadEpisodeSeason(activeEpisodeSeason));
      retrySourceButton?.addEventListener('click', () => { window.location.reload(); });
      transportPlayButton.addEventListener('click', () => { void togglePlayback(); });
      seekBackwardButton.addEventListener('click', () => seekBy(-10));
      seekForwardButton.addEventListener('click', () => seekBy(10));
      muteButton.addEventListener('click', toggleMute);
      volumeControl.addEventListener('input', setVolume);
      playbackSeek.addEventListener('input', () => {
        paintSeekProgress();
        if (Number.isFinite(player.duration) && player.duration > 0) playbackTime.textContent = `${formatClock(Number(playbackSeek.value))} / ${formatClock(player.duration)}`;
      });
      playbackSeek.addEventListener('change', seekToControlPosition);
      addToQueueButton?.addEventListener('click', () => { void addToQueue(); });
      favoriteButton.addEventListener('click', () => {
        void updatePreference('favorite', !preference.isFavorite, favoriteButton);
      });
      watchlistButton.addEventListener('click', () => {
        void updatePreference('watchlist', !preference.isWatchlist, watchlistButton);
      });
      ratingStars.forEach((star) => star.addEventListener('click', () => {
        const rating = Number(star.dataset.rating);
        if (!Number.isFinite(rating) || rating < 1 || rating > 5) return;
        void updatePreference('rating', rating, star);
      }));
      // 悬浮层不能只靠 `:hover`：触摸屏没有 hover，键盘用户也够不到。按钮点击
      // 显式切换一个 `is-open` 类，与 CSS 的 hover/focus-within 并列生效；点到
      // 别处或按 Esc 收起。
      (() => {
        const clusters = [
          { root: document.getElementById('volume-cluster'), trigger: document.getElementById('toggle-mute') },
          { root: document.getElementById('speed-cluster'), trigger: document.getElementById('playback-speed-button') }
        ].filter(entry => entry.root && entry.trigger);
        if (clusters.length === 0) return;
        const closeAll = except => clusters.forEach(entry => {
          if (entry.root === except) return;
          entry.root.classList.remove('is-open');
          entry.trigger.setAttribute('aria-expanded', 'false');
        });
        clusters.forEach(entry => {
          entry.trigger.setAttribute('aria-expanded', 'false');
          entry.trigger.addEventListener('click', () => {
            // 静音按钮本来就有它自己的点击语义，这里只负责把面板一并打开，
            // 不拦截原有行为。
            const open = !entry.root.classList.contains('is-open');
            closeAll(entry.root);
            entry.root.classList.toggle('is-open', open);
            entry.trigger.setAttribute('aria-expanded', open ? 'true' : 'false');
          });
        });
        document.addEventListener('pointerdown', event => {
          if (clusters.some(entry => entry.root.contains(event.target))) return;
          closeAll(null);
        }, true);
        document.addEventListener('keydown', event => {
          if (event.key === 'Escape') closeAll(null);
        });
      })();
      speedControl.addEventListener('input', setPlaybackRate);
      speedControl.addEventListener('change', setPlaybackRate);
      if (fullscreenButton) {
        fullscreenButton.hidden = typeof playerStage.requestFullscreen !== 'function';
        fullscreenButton.addEventListener('click', () => { void toggleFullscreen(); showOverlayControls(true); });
      }
      if (pictureInPictureButton) {
        pictureInPictureButton.hidden = !document.pictureInPictureEnabled || typeof player.requestPictureInPicture !== 'function';
        pictureInPictureButton.addEventListener('click', togglePictureInPicture);
      }
      document.addEventListener('fullscreenchange', updateFullscreenLabel, { signal: lifecycle.signal });
      playerStage.addEventListener('pointermove', () => showOverlayControls());
      playerStage.addEventListener('pointerdown', () => showOverlayControls(true));
      playerStage.addEventListener('pointerleave', hideOverlayControls);
      transportControls.addEventListener('focusin', () => showOverlayControls(true));
      transportControls.addEventListener('focusout', () => { window.setTimeout(() => { if (!transportControls.contains(document.activeElement)) showOverlayControls(); }, 0); });
      player.addEventListener('click', () => { void togglePlayback(); });
      document.addEventListener('keydown', (event) => {
        if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey || isEditableTarget(event.target)) return;
        showOverlayControls();
        if (event.key === ' ' || event.key === 'Spacebar') { event.preventDefault(); void togglePlayback(); }
        else if (event.key === 'ArrowLeft') { event.preventDefault(); seekBy(-5); }
        else if (event.key === 'ArrowRight') { event.preventDefault(); seekBy(5); }
        else if (event.key.toLowerCase() === 'j') { event.preventDefault(); seekBy(-10); }
        else if (event.key.toLowerCase() === 'l') { event.preventDefault(); seekBy(10); }
        else if (event.key.toLowerCase() === 'f' && fullscreenButton && !fullscreenButton.hidden) { event.preventDefault(); void toggleFullscreen(); }
        else if (event.key.toLowerCase() === 'm') { toggleMute(); }
        else if (event.key === 'Escape' && document.body.classList.contains('is-web-fullscreen')) { event.preventDefault(); toggleWebFullscreen(); }
      }, { signal: lifecycle.signal });
      player.addEventListener('play', updateTransportUI);
      // 缓冲的可见形态。`waiting` 进、`playing`/`canplay` 出——起播顺利时那 320ms
      // 的延迟让它根本不出现。
      player.addEventListener('waiting', () => { setBufferingVisible(true); }, { signal: lifecycle.signal });
      player.addEventListener('stalled', () => { setBufferingVisible(true); }, { signal: lifecycle.signal });
      player.addEventListener('canplay', () => { setBufferingVisible(false); }, { signal: lifecycle.signal });
      player.addEventListener('progress', paintSeekProgress, { signal: lifecycle.signal });
      player.addEventListener('playing', () => {
        setBufferingVisible(false);
        updateTransportUI();
        showOverlayControls();
        // 轨道名单起播前就问过了；这里再调一次只是为了覆盖"页面加载时那次请求
        // 失败、但读者仍然按下了播放"的情况。函数自己带幂等闸。
        void loadPlaybackTracks();
        setStatus('正在播放。');
        directButton.setAttribute('aria-label', '重新播放');
        // 快捷键存在但从来没有被说出来过。第一次真正开始播放时短暂提示一次，
        // 之后不再打扰。
        const hint = document.getElementById('shortcut-hint');
        if (hint && !hint.dataset.shown) {
          hint.dataset.shown = 'true';
          hint.hidden = false;
          window.setTimeout(() => hint.classList.add('is-leaving'), 2600);
          window.setTimeout(() => { hint.hidden = true; hint.classList.remove('is-leaving'); }, 3200);
        }
        if (!playbackStartedReported) {
          playbackStartedReported = true;
          void reportPlaybackState('started');
        }
      });
      player.addEventListener('loadedmetadata', () => {
        updateTransportUI();
        buildAudioMenu();
        buildSubtitleMenu();
        if (player.videoWidth > 0 && player.videoHeight > 0) {
          // 挂在工作区上，不是舞台上：自定义属性只向下继承，而高度预算现在由
          // **卡片**换算成宽度上限，卡片是舞台的父级——写在舞台上它永远读不到。
          (workspace ?? playerStage).style.setProperty(
            '--player-aspect', `${player.videoWidth} / ${player.videoHeight}`
          );
          scheduleEpisodePanelHeight();
        }
        if (resumeApplied || !Number.isFinite(resumePosition) || resumePosition < 10) return;
        resumeApplied = true;
        if (Number.isFinite(player.duration) && resumePosition < player.duration - 30) player.currentTime = resumePosition;
      });
      player.addEventListener('timeupdate', () => {
        scheduleTransportUI();
        if (!playbackStartedReported || !Number.isFinite(player.currentTime)) return;
        const bucket = Math.floor(timelinePosition() / 15);
        if (bucket <= lastProgressBucket) return;
        lastProgressBucket = bucket;
        void reportPlaybackState('progress');
      });
      player.addEventListener('pause', () => {
        updateTransportUI();
        showOverlayControls(true);
        if (playbackStartedReported && !player.ended) {
          void reportPlaybackState('stopped');
        }
        if (!player.ended && !isStarting && hasPlayableSource()) setStatus('已暂停。');
      });
      player.addEventListener('ended', () => {
        updateTransportUI();
        showOverlayControls(true);
        playbackCompleted = true;
        directButton.disabled = !canDirectPlay;
        directButton.setAttribute('aria-label', '重新播放');
        if (!playbackStartedReported) {
          return;
        }
        playbackStartedReported = false;
        void reportPlaybackState('completed');
        setStatus('看完啦。');
      });
      player.addEventListener('error', () => {
        setBufferingVisible(false);
        updateTransportUI();
        setStatus('这个浏览器打不开这段视频。换一个浏览器试试。', true);
      });
      player.addEventListener('volumechange', scheduleTransportUI);
      window.addEventListener('pagehide', () => {
        if (playbackStartedReported) void reportPlaybackState('stopped', true);
      }, { signal: lifecycle.signal });
      document.addEventListener('medialib:pagewillunload', () => {
        if (transportFrame !== null) window.cancelAnimationFrame(transportFrame);
        if (playbackStartedReported) void reportPlaybackState('stopped', true);
        lifecycle.abort();
      }, { once: true });
      if (seriesID) void loadEpisodeSeason(activeEpisodeSeason, true);
      // 进入播放页不再自动开播。
      //
      // `#play` 挂在每一张海报卡片上（"海报即播放"），于是点开一个条目看看它是什么
      // 就会直接出声——在别人旁边、或者只是想确认一下选集的时候，这是个坏默认。
      // 现在它只负责把人带到播放页，开播交给中间那颗按钮。
      //
      // `#autoplay` 保留：那是"自动播放下一集"这个开关自己发起的续播，读者明确
      // 打开过它，把它一并关掉等于悄悄废掉一个功能。
      if (window.location.hash === '#play') {
        history.replaceState(null, '', `${window.location.pathname}${window.location.search}`);
      } else if (window.location.hash === '#autoplay' && canDirectPlay) {
        history.replaceState(null, '', `${window.location.pathname}${window.location.search}`);
        window.setTimeout(() => { void startPlayback(); }, 0);
      }
    })();
    """#

    private static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = max(Int(seconds.rounded() / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
    }

    /// 播放器下方的全部内容，顺序与客户端逐条对应：
    /// 制作信息 → 主创 → 演员 → 艺术照 → 库中相似作品 → 更多推荐 → 相关链接。
    ///
    /// 每一张外部图片都走同源代理端点，浏览器不会在加载这一页时向元数据提供方
    /// 发出任何请求。链接是唯一的例外，而它们只在读者主动点击时才生效。
    /// 顶部那一行标签，与客户端的胶囊行同序：年份/评分/状态/分级/时长/季集/类型。
    ///
    /// 状态、分级、语言和国家此前只出现在页面最下面一个独立的「详情」小节里，
    /// 离它们描述的作品有一屏远。
    private static func detailFacts(
        _ detail: ServerMediaItemDetail,
        runtime: String,
        rating: String,
        genres: String
    ) -> String {
        // 这一行此前是七颗一模一样的灰框胶囊：时长、评分、状态、分级、语言、地区、
        // 题材全部同一个形状。读者要在七个等重的方块里自己找出哪个是分级、哪个是
        // 题材。分三级，形状各不相同：
        //   事实（时长/状态/语言/地区）→ 一条以「·」分隔的等宽数字行，最轻
        //   判定（评分/分级）          → 徽章，最重
        //   题材                      → 可扫的识别色胶囊
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var badges: [String] = []
        if let rating = clean(rating) {
            badges.append(#"<li><span class="detail-badge detail-badge-score t-numeric">\#(escape(rating))</span></li>"#)
        }
        if let contentRating = clean(detail.detailExtras?.contentRating) {
            badges.append(#"<li><span class="detail-badge detail-badge-outline">\#(escape(contentRating))</span></li>"#)
        }

        var facts: [String] = [clean(runtime)].compactMap { $0 }
        if let extras = detail.detailExtras {
            facts.append(contentsOf: [extras.status, extras.originalLanguage].compactMap(clean))
            facts.append(contentsOf: extras.countries.prefix(3).compactMap(clean))
        }
        let factLine = facts.isEmpty
            ? ""
            : #"<li class="detail-fact-line t-numeric">\#(facts.map(escape).joined(separator: " · "))</li>"#

        // 题材是一串并列的值，不是一句话——一颗一颗地给，读者才扫得动。
        let genreChips = clean(genres).map { value in
            value.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "·" || $0 == " " })
                .map { #"<li class="ui-chip detail-genre">\#(escape($0.trimmingCharacters(in: .whitespaces)))</li>"# }
                .joined()
        } ?? ""

        return badges.joined() + factLine + genreChips
    }

    private static func clientDetailSections(for detail: ServerMediaItemDetail) -> String {
        guard let extras = detail.detailExtras else { return "" }
        guard let encodedItemID = ServerWebURL.pathSegment(detail.id) else { return "" }
        let production = Array((extras.networks + extras.productionCompanies).prefix(8))
        let productionMarkup = production.map { "<span>\(escape($0))</span>" }.joined()
        let crewMarkup = detailCredits(extras.crew, itemID: encodedItemID)
        let castMarkup = detailCredits(extras.cast, itemID: encodedItemID)
        let artworkMarkup = detailArtwork(extras.artwork, itemID: encodedItemID, title: detail.title)
        let relatedMarkup = detailRelated(extras.related)
        let discoveryMarkup = detailDiscovery(extras.discovery, itemID: encodedItemID)
        let linksMarkup = detailLinks(extras.links)

        func section(_ id: String, _ title: String, _ bodyClass: String, _ body: String, more: (label: String, href: String)? = nil) -> String {
            guard !body.isEmpty else { return "" }
            let moreLink = more.map {
                #"<a class="ui-section-more" href="\#($0.href)" data-native-navigation="true">\#(escape($0.label))\#(ServerWebIcon.chevronRight.html(size: .xs))</a>"#
            } ?? ""
            return """
            <section class="client-detail-section" aria-labelledby="\(id)-title">\
            <div class="client-detail-section-head"><h2 id="\(id)-title">\(escape(title))</h2>\(moreLink)</div>\
            <div class="\(bodyClass)">\(body)</div></section>
            """
        }
        let sections = [
            section("production", "制作信息", "client-detail-production-list", productionMarkup),
            section("crew", "主创", "client-detail-people", crewMarkup),
            // 人物目录不在侧栏里（客户端也没有），所以它的入口挂在这儿——演员卡本来
            // 就通向单个人物页，"查看全部"通向目录是同一条路的延长。
            section("cast", "演员", "client-detail-people", castMarkup, more: (label: "查看全部", href: "/people")),
            section("stills", "艺术照", "client-detail-stills", artworkMarkup),
            section("related", "库中相似作品", "client-detail-related", relatedMarkup),
            section("discovery", "更多推荐", "client-detail-related", discoveryMarkup),
            section("links", "相关链接", "client-detail-links", linksMarkup)
        ].joined()
        guard !sections.isEmpty else { return "" }
        return "<section class=\"client-detail-extras\" aria-label=\"详情\">\(sections)</section>"
    }

    private static func detailCredits(_ values: [ServerMediaDetailCredit], itemID: String) -> String {
        values.compactMap { value in
            guard let id = ServerWebURL.pathSegment(value.id) else { return nil }
            let role = value.role.isEmpty ? (value.category == "cast" ? "演员" : "主创") : value.role
            // 有缓存头像就用头像，没有就用姓名首字母——而不是去请求一张不存在的图
            // 然后留下一个碎图标。
            let portrait = value.portraitIndex.map { index in
                "<img src=\"/api/v1/images/\(itemID)/portrait/\(index)?size=160\" alt=\"\" loading=\"lazy\" decoding=\"async\">"
            } ?? "<span aria-hidden=\"true\">\(escape(String(value.name.prefix(1))))</span>"
            return """
            <a class="client-detail-person" href="/people/\(id)">\
            <span class="client-detail-portrait">\(portrait)</span>\
            <strong>\(escape(value.name))</strong><small>\(escape(role))</small></a>
            """
        }.joined()
    }

    private static func detailArtwork(_ values: [ServerMediaDetailArtwork], itemID: String, title: String) -> String {
        values.map { value in
            // 竖版海报和横版剧照混在一条里；让每张图按自己的比例占位，滚动条
            // 才不会在图片解码完成时跳一下。
            let orientation = value.aspectRatio >= 1.3 ? "landscape" : "portrait"
            // 缩略图是链接，指向同一张图的 1024 版本。浏览器自带的图片查看器
            // 就是最好的查看器：可缩放、可保存、可在新标签打开，而且不需要这一页
            // 再背一个灯箱脚本。CSP 下也没有别的选择——图片必须是真实的导航目标。
            return """
            <a class="client-detail-still" data-orientation="\(orientation)" \
            href="/api/v1/images/\(itemID)/still/\(value.index)?size=1024" \
            target="_blank" rel="noopener" aria-label="查看\(escape(title))艺术照">\
            <img src="/api/v1/images/\(itemID)/still/\(value.index)?size=320" \
            alt="\(escape(title)) 艺术照" loading="lazy" decoding="async"></a>
            """
        }.joined()
    }

    private static func detailRelated(_ values: [ServerMediaDetailRelated]) -> String {
        values.compactMap { value in
            guard let id = ServerWebURL.pathSegment(value.id) else { return nil }
            let destination = value.isSeries ? "/series/\(id)/play" : "/item/\(id)#play"
            let artwork = value.artworkAvailable
                ? "<img src=\"/api/v1/images/\(id)/poster?size=320\" alt=\"\" loading=\"lazy\" decoding=\"async\">"
                : "<span aria-hidden=\"true\">\(escape(String(value.type.prefix(1))))</span>"
            let year = value.year.map(String.init) ?? "资料库"
            return "<a class=\"client-detail-related-card\" href=\"\(destination)\"><span class=\"client-detail-related-art\">\(artwork)</span><strong>\(escape(value.title))</strong><small>\(escape(year))</small></a>"
        }.joined()
    }

    /// 资料库里还没有的推荐。它们不是链接——点开会通向一个不存在的条目——
    /// 所以渲染成静态卡片，并明说"资料库中没有"。
    private static func detailDiscovery(_ values: [ServerMediaDetailDiscovery], itemID: String) -> String {
        values.map { value in
            let artwork = value.artworkAvailable
                ? "<img src=\"/api/v1/images/\(itemID)/discovery/\(value.index)?size=320\" alt=\"\" loading=\"lazy\" decoding=\"async\">"
                : "<span aria-hidden=\"true\">?</span>"
            let year = value.year.map(String.init) ?? "未收录"
            return """
            <article class="client-detail-related-card is-discovery">\
            <span class="client-detail-related-art">\(artwork)</span>\
            <strong>\(escape(value.title))</strong><small>\(escape(year)) · 资料库中没有</small></article>
            """
        }.joined()
    }

    private static func detailLinks(_ values: [ServerMediaDetailLink]) -> String {
        values.map { value in
            // 外链一律 `noreferrer`：不要把当前页面的地址带给站外。
            """
            <a class="ui-btn ui-btn-secondary" href="\(escape(value.url))" target="_blank" rel="noopener noreferrer">\
            \(ServerWebIcon.external.html(size: .sm))<span>\(escape(value.title))</span></a>
            """
        }.joined()
    }

    private static func episodeSelectionItem(_ episode: ServerEpisodeNavigation, position: String) -> String {
        guard let encodedID = ServerWebURL.pathSegment(episode.id) else { return "" }
        let safeTitle = escape(episode.title)
        return "<a class=\"episode-choice\" href=\"/item/\(encodedID)\"><span>\(escape(position))</span><strong>\(safeTitle)</strong><small>切换并播放</small></a>"
    }

    /// Delegates to the shared implementation in `ServerWebHTML`.
    ///
    /// Every page used to carry a private copy of this function — eighteen of
    /// them — which meant eighteen places to audit and eighteen chances for one
    /// to drift.  The local name is kept so the hundreds of call sites in this
    /// file stay readable.
    private static func escape(_ value: String) -> String { ServerWebHTML.escape(value) }
}

enum ServerWebURL {
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func pathSegment(_ value: String) -> String? {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return value.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed)
    }

    /// Encodes a single bounded query value without permitting separators to
    /// become additional keys. Callers still choose the query key themselves.
    static func queryValue(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return value.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed)
    }
}
