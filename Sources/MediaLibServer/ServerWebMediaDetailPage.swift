import Foundation
import MediaLibServerProtocol

/// 认证媒体详情与 Web 播放页。所有数据库文本先做长度收敛并在此处 HTML 转义；
/// 播放器只接收媒体 ID 对应的同源 API URL，不接触本地路径或原始令牌。
enum ServerWebMediaDetailPage {
    static func render(
        serverName: String,
        detail: ServerMediaItemDetail,
        csrfToken: String,
        showAdministration: Bool
    ) -> String {
        let year = detail.year.map(String.init) ?? "年份未知"
        let runtime = detail.runtimeSeconds.map(formatDuration) ?? "片长未知"
        let rating = detail.communityRating.map { String(format: "%.1f / 10", $0) } ?? "暂无评分"
        let genres = detail.genres.isEmpty ? "未标注类型" : detail.genres.joined(separator: " · ")
        let overview = detail.overview ?? "暂无简介。"
        let originalTitle = detail.originalTitle.map {
            "<p class=\"original-title\">\(escape($0))</p>"
        } ?? ""
        let sidebar = ServerWebNavigation.render(
            active: .library, showAdministration: showAdministration, note: .playback
        )
        let canDirectPlay = detail.canDirectPlay ? "true" : "false"
        let directDisabled = detail.canDirectPlay ? "" : " disabled aria-disabled=\"true\""
        let resumePosition = detail.userState?.positionSeconds ?? 0
        let preferenceRating = detail.userPreference.rating.map { String(format: "%.1f", $0) } ?? "0"
        let preferenceRatingSummary = detail.userPreference.rating.map { String(format: "%.1f / 5", $0) } ?? "未评分"
        let previousEpisodeControl = episodeNavigationControl(
            detail.previousEpisode, id: "previous-episode", action: "上一集"
        )
        let nextEpisodeControl = episodeNavigationControl(
            detail.nextEpisode, id: "next-episode", action: "下一集"
        )
        let automaticNextEpisodeControls = detail.nextEpisode == nil ? "" : """
        <div id="automatic-next-controls" class="automatic-next-controls"><label><input id="automatic-next" type="checkbox"> 自动播放下一集</label><button id="cancel-automatic-next" type="button" hidden>取消自动播放</button></div>
        """
        let userStateSummary: String = {
            guard let state = detail.userState else { return "尚未播放" }
            if state.isWatched { return "已看 · 播放 \(state.playCount) 次" }
            if state.progress > 0 { return "续播 \(formatDuration(state.positionSeconds)) · \(Int((state.progress * 100).rounded()))%" }
            return state.playCount > 0 ? "已开始 · 播放 \(state.playCount) 次" : "尚未播放"
        }()
        let posterContent: String
        if detail.artworkAvailable, let encodedID = ServerWebURL.pathSegment(detail.id) {
            posterContent = "<div class=\"poster\"><img src=\"/api/v1/images/\(encodedID)/poster\" alt=\"\" loading=\"eager\" decoding=\"async\"></div>"
        } else {
            posterContent = "<div class=\"poster\" role=\"img\" aria-label=\"\(escape(detail.title)) 的封面占位图\"><span>\(escape(String(detail.type.prefix(1))))</span></div>"
        }

        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>\(escape(detail.title)) · \(escape(serverName))</title>
          <link rel="stylesheet" href="/assets/player.css">
          <link rel="stylesheet" href="/assets/app-shell.css">
        </head>
        <body data-item-id="\(escape(detail.id))" data-can-direct-play="\(canDirectPlay)" data-resume-position="\(resumePosition)" data-is-watched="\(detail.userState?.isWatched == true ? "true" : "false")" data-is-favorite="\(detail.userPreference.isFavorite ? "true" : "false")" data-is-watchlist="\(detail.userPreference.isWatchlist ? "true" : "false")" data-preference-rating="\(preferenceRating)">
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">
            \(sidebar)
            <main id="main" tabindex="-1">
              <a class="back" href="/">← 返回资料库</a>
              <section class="hero" aria-labelledby="item-title">
                \(posterContent)
                <div><h1 id="item-title">\(escape(detail.title))</h1>\(originalTitle)<ul class="facts"><li>\(escape(detail.type))</li><li>\(escape(year))</li><li>\(escape(runtime))</li><li>\(escape(rating))</li><li>\(escape(genres))</li></ul><p class="overview">\(escape(overview))</p></div>
              </section>
              <section class="player-card" aria-labelledby="player-heading">
                <h2 id="player-heading" class="skip">Web 播放器</h2>
                <div id="player-stage" class="player-stage"><video id="player" controls playsinline preload="metadata" aria-label="\(escape(detail.title)) 播放器"></video></div>
                <div class="player-controls"><button id="direct-play" class="primary" type="button"\(directDisabled)>在浏览器中播放</button>\(previousEpisodeControl)\(nextEpisodeControl)\(automaticNextEpisodeControls)<button id="reset-playback" type="button">重置观看进度</button><label class="speed-control" for="playback-speed">速度<select id="playback-speed"><option value="0.5">0.5×</option><option value="0.75">0.75×</option><option value="1" selected>1×</option><option value="1.25">1.25×</option><option value="1.5">1.5×</option><option value="2">2×</option></select></label><button id="fullscreen" type="button" hidden>全屏</button><button id="picture-in-picture" type="button" hidden>画中画</button><p id="player-status" class="status" role="status" aria-live="polite">网页播放器会使用浏览器原生媒体解码能力。</p></div>
                <p id="support-note" class="support-note">MediaLIB 仅提供当前账号有权访问的同源媒体字节流、续播状态和元数据；编码格式是否可播放由当前浏览器决定。</p>
                <details id="technical-info" class="technical-info"><summary>播放信息与轨道</summary><p id="stream-info-status" role="status" aria-live="polite">展开后显示此媒体的容器、码率及浏览器原生控制栏可使用的音频/字幕轨道。</p><ul id="stream-list" class="stream-list" aria-label="媒体轨道"></ul></details>
              </section>
              <section class="preferences" aria-labelledby="preferences-heading"><h2 id="preferences-heading">我的清单</h2><button id="toggle-favorite" type="button" aria-pressed="\(detail.userPreference.isFavorite ? "true" : "false")">\(detail.userPreference.isFavorite ? "已收藏" : "收藏")</button><button id="toggle-watchlist" type="button" aria-pressed="\(detail.userPreference.isWatchlist ? "true" : "false")">\(detail.userPreference.isWatchlist ? "已加入想看" : "加入想看")</button><label class="rating-control" for="user-rating">我的评分<input id="user-rating" type="range" min="0" max="5" step="0.5" value="\(preferenceRating)"><output id="user-rating-value" for="user-rating">\(preferenceRatingSummary)</output></label><p>这些标记仅属于当前登录用户；不会修改媒体文件，也不会向其他用户公开。</p></section>
              <section class="details" aria-label="媒体与用户信息"><article class="detail-card"><span>当前用户</span><strong id="user-playback-state">\(escape(userStateSummary))</strong></article><article class="detail-card"><span>分辨率</span><strong>\(escape(detail.resolution ?? "未知"))</strong></article><article class="detail-card"><span>视频编码</span><strong>\(escape(detail.videoCodec ?? "未知"))</strong></article><article class="detail-card"><span>音频编码</span><strong>\(escape(detail.audioCodec ?? "未知"))</strong></article></section>
              <footer>播放信息与媒体字节继续受当前用户、设备、会话和资料库权限检查；未知或无权媒体统一返回 404。</footer>
            </main>
          </div>
          <script src="/assets/player.js" defer></script>
        </body>
        </html>
        """
    }

    /// 详情与浏览器原生播放器共用的固定样式。将其作为私有缓存的同源资源，
    /// 使连续打开媒体详情时无需重复解析播放器舞台和响应式布局规则。
    static let style = """
    :root { --primary:#1e67a8; --primary-strong:#174d82; --ink:#172033; --muted:#5f6e84; --line:#dfe7f1; --canvas:#f4f7fb; --surface:#fff; --stage:#081523; --stage-line:#20364b; --success:#087a55; --danger:#b42318; --focus:#1570ef; }
    * { box-sizing:border-box; } body { margin:0; color:var(--ink); background:var(--canvas); font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; } a { color:inherit; } button,a { touch-action:manipulation; } :focus-visible { outline:3px solid var(--focus); outline-offset:3px; }
    .skip { position:fixed; z-index:1000; top:8px; left:8px; padding:10px 14px; border-radius:9px; color:#fff; background:var(--primary-strong); transform:translateY(-160%); } .skip:focus { transform:none; }
    .shell { display:grid; grid-template-columns:258px minmax(0,1fr); min-height:100dvh; } aside { padding:26px 16px; color:var(--ink); background:#fbfcfe; border-right:1px solid #e9edf4; }
    .brand { display:flex; gap:10px; align-items:center; font-size:19px; font-weight:850; letter-spacing:-.02em; } .brand-mark { display:grid; place-items:center; width:34px; height:34px; border-radius:10px; color:#fff; background:linear-gradient(135deg,#2e90fa,#36bffa); box-shadow:0 7px 16px #2e90fa35; }
    nav { display:grid; gap:5px; margin-top:34px; } nav a { display:flex; align-items:center; min-height:44px; padding:10px 12px; border:1px solid transparent; border-radius:10px; color:#516174; text-decoration:none; font-size:14px; font-weight:650; } nav a:hover { color:#0f172a; background:#f1f5fa; } nav a.active { border-color:#dbeafe; color:#0f3d71; background:linear-gradient(110deg,#eaf4ff,#f8fbff); font-weight:800; }
    .boundary { margin-top:28px; padding:14px; border:1px solid var(--line); border-radius:14px; color:var(--muted); background:#fff; box-shadow:0 8px 20px #243a6208; font-size:13px; }
    main { width:100%; max-width:1440px; padding:clamp(22px,4vw,48px); background:radial-gradient(circle at 86% -15%,#dff3ff 0,transparent 31%),var(--canvas); } .back { display:inline-flex; align-items:center; min-height:44px; margin-bottom:14px; color:var(--primary-strong); font-weight:700; text-decoration:none; }
    .hero { display:grid; grid-template-columns:minmax(180px,260px) minmax(0,1fr); gap:clamp(24px,4vw,52px); align-items:end; } .poster { display:grid; overflow:hidden; place-items:center; aspect-ratio:2/3; border:1px solid #bcd2e7; border-radius:20px; color:#fff; background:linear-gradient(145deg,#174d82,#2e90fa 58%,#91ddff); box-shadow:0 18px 44px #17385d24; font-size:72px; font-weight:850; text-transform:uppercase; } .poster img { width:100%; height:100%; object-fit:cover; }
    h1 { margin:0; font-size:clamp(34px,6vw,68px); line-height:1.05; letter-spacing:-.045em; overflow-wrap:anywhere; } .original-title { margin:10px 0 0; color:var(--muted); font-size:18px; overflow-wrap:anywhere; }
    .facts { display:flex; flex-wrap:wrap; gap:8px; margin:20px 0 0; padding:0; list-style:none; } .facts li { padding:6px 10px; border:1px solid #cad8e7; border-radius:999px; color:#42526a; background:#fff; font-size:13px; }
    .overview { max-width:75ch; margin:24px 0 0; color:#3d4b60; white-space:pre-wrap; overflow-wrap:anywhere; }
    .player-card { margin-top:36px; overflow:hidden; border:1px solid var(--stage-line); border-radius:18px; background:var(--stage); box-shadow:0 20px 50px #0b1d3040; } .player-stage { display:grid; place-items:center; min-width:0; min-height:260px; background:#030a12; } video { display:block; inline-size:100%; max-inline-size:100%; min-inline-size:0; block-size:auto; max-height:min(72vh,820px); background:#000; }
    .player-controls { display:flex; flex-wrap:wrap; gap:10px; align-items:center; padding:16px; color:#dcecff; } button,.player-nav,.speed-control select { min-height:44px; padding:10px 16px; border:1px solid #5c7894; border-radius:11px; color:#fff; background:#173b5d; font:inherit; font-weight:750; cursor:pointer; transition:background-color .18s ease,border-color .18s ease; } .player-nav { display:inline-flex; align-items:center; text-decoration:none; } button.primary { border-color:#4ba4f4; background:#1469b4; } button:hover,.player-nav:hover,.speed-control select:hover { border-color:#8bc8ff; background:#21527d; } button:disabled { cursor:not-allowed; opacity:.48; } .speed-control { display:flex; align-items:center; gap:7px; min-height:44px; color:#dcecff; font-size:14px; font-weight:700; } .speed-control select { min-width:78px; padding-block:7px; }
    .status { flex:1 1 280px; margin:0; color:#c7d9eb; } .status.error { color:#ffb4ae; } .automatic-next-controls { display:flex; flex-wrap:wrap; gap:10px; align-items:center; color:#dcecff; font-size:14px; font-weight:700; } .automatic-next-controls label { display:flex; gap:8px; align-items:center; min-height:44px; padding:10px 12px; border:1px solid #5c7894; border-radius:11px; background:#102f4b; } .automatic-next-controls input { width:18px; height:18px; accent-color:#4ba4f4; } .support-note { margin:0; padding:0 16px 16px; color:#9fb6cc; font-size:13px; }
    .technical-info { margin:0 16px 16px; border-top:1px solid #29445d; color:#dcecff; } .technical-info summary { min-height:44px; padding:12px 0; font-weight:750; cursor:pointer; } .technical-info p { margin:0 0 12px; color:#c7d9eb; font-size:14px; } .stream-list { display:grid; gap:8px; margin:0; padding:0 0 2px; list-style:none; } .stream-list li { padding:9px 11px; border:1px solid #34536f; border-radius:9px; color:#dcecff; background:#0e2439; font-size:13px; overflow-wrap:anywhere; }
    .preferences { display:flex; flex-wrap:wrap; gap:12px; align-items:center; margin-top:24px; padding:18px; border:1px solid var(--line); border-radius:15px; background:var(--surface); } .preferences h2 { flex:1 0 100%; margin:0; font-size:18px; } .preferences p { flex:1 0 100%; margin:0; color:var(--muted); font-size:14px; } .preferences button { border-color:#b8cae0; color:var(--primary-strong); background:#f5f9fd; } .preferences button[aria-pressed=\"true\"] { border-color:#2e90fa; color:#fff; background:var(--primary); } .rating-control { display:flex; flex:1 1 220px; align-items:center; gap:10px; min-height:44px; color:#34435a; font-size:14px; font-weight:750; } .rating-control input { width:min(180px,45vw); accent-color:var(--primary); } .rating-control output { min-width:52px; color:var(--primary-strong); text-align:right; }
    .details { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:14px; margin-top:24px; } .detail-card { min-height:104px; padding:17px; border:1px solid var(--line); border-radius:15px; background:var(--surface); } .detail-card span { display:block; color:var(--muted); font-size:13px; } .detail-card strong { display:block; margin-top:8px; overflow-wrap:anywhere; }
    footer { margin:30px 0 8px; color:var(--muted); font-size:13px; }
    @media (max-width:780px) { .shell { display:block; } aside { padding:16px 18px; } nav { display:flex; overflow-x:auto; margin-top:14px; } nav a { flex:none; } .boundary { display:none; } main { padding:24px 18px 40px; } .hero { grid-template-columns:110px minmax(0,1fr); gap:20px; align-items:center; } .poster { border-radius:14px; font-size:40px; } h1 { font-size:clamp(30px,8vw,50px); } .overview { grid-column:1/-1; } .details { grid-template-columns:1fr; } }
    @media (max-width:480px) { .hero { grid-template-columns:82px minmax(0,1fr); gap:15px; } .facts { grid-column:1/-1; } .player-card { margin-inline:-18px; border-left:0; border-right:0; border-radius:0; } .player-controls button { flex:1 1 130px; } }
    @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
    """

    static let script = #"""
    (() => {
      'use strict';
      const player = document.getElementById('player');
      const playerStage = document.getElementById('player-stage');
      const directButton = document.getElementById('direct-play');
      const nextEpisodeLink = document.getElementById('next-episode');
      const automaticNextToggle = document.getElementById('automatic-next');
      const cancelAutomaticNextButton = document.getElementById('cancel-automatic-next');
      const resetPlaybackButton = document.getElementById('reset-playback');
      const speedControl = document.getElementById('playback-speed');
      const fullscreenButton = document.getElementById('fullscreen');
      const pictureInPictureButton = document.getElementById('picture-in-picture');
      const favoriteButton = document.getElementById('toggle-favorite');
      const watchlistButton = document.getElementById('toggle-watchlist');
      const ratingControl = document.getElementById('user-rating');
      const ratingValue = document.getElementById('user-rating-value');
      const status = document.getElementById('player-status');
      const userPlaybackState = document.getElementById('user-playback-state');
      const technicalInfo = document.getElementById('technical-info');
      const streamInfoStatus = document.getElementById('stream-info-status');
      const streamList = document.getElementById('stream-list');
      const itemID = document.body.dataset.itemId || '';
      const canDirectPlay = document.body.dataset.canDirectPlay === 'true';
      const resumePosition = Number(document.body.dataset.resumePosition || 0);
      const subtitlePath = (trackID) => `/api/v1/subtitles/${encodeURIComponent(itemID)}/${encodeURIComponent(String(trackID))}`;
      const csrfToken = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
      let isStarting = false;
      let resumeApplied = false;
      let playbackStartedReported = false;
      let lastProgressBucket = -1;
      let streamInfoLoaded = false;
      let sidecarSubtitlesLoaded = false;
      let automaticNextTimer = null;
      let preference = {
        isFavorite: document.body.dataset.isFavorite === 'true',
        isWatchlist: document.body.dataset.isWatchlist === 'true',
        rating: Number(document.body.dataset.preferenceRating || 0) || null
      };

      const setStatus = (message, isError = false) => {
        status.textContent = message;
        status.classList.toggle('error', isError);
      };
      const setBusy = (busy) => {
        isStarting = busy;
        directButton.disabled = busy || !canDirectPlay;
      };
      const nextEpisodeURL = () => {
        if (!(nextEpisodeLink instanceof HTMLAnchorElement)) return null;
        try {
          const value = new URL(nextEpisodeLink.href, window.location.origin);
          return value.origin === window.location.origin && value.pathname.startsWith('/item/') && !value.search ? value : null;
        } catch (_) { return null; }
      };
      const cancelAutomaticNext = (announce = false) => {
        if (automaticNextTimer !== null) window.clearInterval(automaticNextTimer);
        automaticNextTimer = null;
        if (cancelAutomaticNextButton) cancelAutomaticNextButton.hidden = true;
        if (announce) setStatus('已取消自动播放下一集。');
      };
      const scheduleAutomaticNext = () => {
        const target = nextEpisodeURL();
        if (!automaticNextToggle?.checked || !target) return;
        cancelAutomaticNext();
        let remaining = 7;
        if (cancelAutomaticNextButton) cancelAutomaticNextButton.hidden = false;
        setStatus(`本集已播放完成；下一集将在 ${remaining} 秒后播放。`);
        automaticNextTimer = window.setInterval(() => {
          remaining -= 1;
          if (remaining > 0) return;
          cancelAutomaticNext();
          window.location.assign(`${target.pathname}${target.search}#autoplay`);
        }, 1000);
      };
      const mediaPath = (prefix) => `${prefix}${encodeURIComponent(itemID)}`;
      const subtitleLabel = (value, fallback) => {
        if (typeof value !== 'string') return fallback;
        const normalized = value.trim().slice(0, 80);
        return normalized || fallback;
      };
      async function loadSidecarSubtitles() {
        if (sidecarSubtitlesLoaded || !itemID) return;
        sidecarSubtitlesLoaded = true;
        try {
          const response = await fetch(mediaPath('/api/v1/playback/subtitles/'), {
            credentials: 'same-origin', headers: { 'Accept': 'application/json' }
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('unavailable');
          const tracks = await response.json();
          if (!Array.isArray(tracks)) throw new Error('invalid');
          tracks.slice(0, 16).forEach((track, index) => {
            if (!Number.isInteger(track?.id) || track.id < 0 || track.id >= 16) return;
            const element = document.createElement('track');
            element.kind = 'subtitles';
            element.label = subtitleLabel(track.label, `字幕 ${index + 1}`);
            element.srclang = 'und';
            element.src = subtitlePath(track.id);
            player.append(element);
          });
          if (tracks.length) setStatus('正在直接播放；可在浏览器控制栏选择外挂字幕。');
        } catch (_) {
          // 字幕发现或读取失败不影响浏览器直放，也不回显服务器文件信息。
          sidecarSubtitlesLoaded = false;
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
        ratingControl.value = String(preference.rating || 0);
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
          setStatus('我的清单已更新。');
        } catch (_) {
          setStatus('无法更新我的清单，请稍后重试。', true);
          renderPreference();
        } finally {
          control.disabled = false;
        }
      }
      const finitePlaybackNumber = (value) => Number.isFinite(value) && value >= 0 ? value : 0;
      const hasPlayableSource = () => typeof player.currentSrc === 'string' && player.currentSrc.length > 0;
      const displayValue = (value, fallback = '未知') => {
        if (typeof value !== 'string') return fallback;
        const normalized = value.trim();
        return normalized ? normalized.slice(0, 120) : fallback;
      };
      const formatBitrate = (value) => Number.isInteger(value) && value > 0
        ? `${Math.round(value / 1000)} kbps` : '码率未知';
      const makeStreamLine = (stream) => {
        const type = displayValue(stream?.type, '未知轨道');
        const codec = displayValue(stream?.codec, '编码未知');
        const language = displayValue(stream?.language, '语言未知');
        const detail = type === 'video' && Number.isInteger(stream?.width) && Number.isInteger(stream?.height)
          ? ` · ${stream.width}×${stream.height}`
          : type === 'audio' && Number.isInteger(stream?.channels) ? ` · ${stream.channels} 声道` : '';
        return `${type} · ${codec} · ${language}${detail}`;
      };
      async function loadStreamInfo() {
        if (streamInfoLoaded || !itemID) return;
        streamInfoLoaded = true;
        streamInfoStatus.textContent = '正在读取播放信息…';
        try {
          const response = await fetch(mediaPath('/api/v1/playback/info/'), {
            credentials: 'same-origin', headers: { 'Accept': 'application/json' }
          });
          if (!response.ok) throw new Error('unavailable');
          const info = await response.json();
          if (!info || !Array.isArray(info.streams)) throw new Error('invalid');
          streamList.replaceChildren();
          const summary = document.createElement('li');
          summary.textContent = `容器：${displayValue(info.container)} · ${formatBitrate(info.bitrate)}`;
          streamList.append(summary);
          info.streams.slice(0, 20).forEach((stream) => {
            const row = document.createElement('li');
            row.textContent = makeStreamLine(stream);
            streamList.append(row);
          });
          streamInfoStatus.textContent = info.streams.length > 20
            ? '仅显示前 20 条轨道；实际切换由浏览器原生控制栏和媒体封装格式决定。'
            : '音频/字幕轨道的实际切换由浏览器原生控制栏和媒体封装格式决定。';
        } catch (_) {
          streamInfoLoaded = false;
          streamInfoStatus.textContent = '暂时无法读取播放信息；不影响直接播放。';
        }
      }
      async function reportPlaybackState(event, keepalive = false) {
        const positionSeconds = finitePlaybackNumber(player.currentTime);
        const durationSeconds = Number.isFinite(player.duration) && player.duration > 0 ? player.duration : null;
        try {
          const response = await fetch(mediaPath('/api/v1/playback/state/'), {
            method: 'POST', credentials: 'same-origin', keepalive,
            headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken },
            body: JSON.stringify({ event, positionSeconds, durationSeconds })
          });
          if (!response.ok || keepalive) return;
          const state = await response.json();
          if (!state || typeof state.progress !== 'number' || typeof state.playCount !== 'number') return;
          if (state.isWatched === true) userPlaybackState.textContent = `已看 · 播放 ${state.playCount} 次`;
          else if (state.progress > 0) userPlaybackState.textContent = `续播 ${Math.round(state.positionSeconds / 60)} 分钟 · ${Math.round(state.progress * 100)}%`;
          else userPlaybackState.textContent = state.playCount > 0 ? `已开始 · 播放 ${state.playCount} 次` : '尚未播放';
        } catch (_) { /* 状态同步失败不应中断本地播放。 */ }
      }
      async function resetPlaybackState() {
        if (!itemID || !window.confirm('重置后会清除你在此条目的续播位置、已看状态和播放次数。是否继续？')) return;
        resetPlaybackButton.disabled = true;
        setStatus('正在重置观看进度…');
        try {
          const response = await fetch(mediaPath('/api/v1/playback/state/'), {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken },
            body: JSON.stringify({ event: 'reset', positionSeconds: 0, durationSeconds: null })
          });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('unavailable');
          const state = await response.json();
          if (state && state.progress === 0 && state.playCount === 0) userPlaybackState.textContent = '尚未播放';
          if (Number.isFinite(player.currentTime)) player.currentTime = 0;
          playbackStartedReported = false;
          lastProgressBucket = -1;
          setStatus('观看进度已重置。');
        } catch (_) {
          setStatus('无法重置观看进度，请稍后重试。', true);
        } finally {
          resetPlaybackButton.disabled = false;
        }
      }
      function setPlaybackRate() {
        const rate = Number(speedControl.value);
        if (!Number.isFinite(rate) || rate < 0.5 || rate > 2) return;
        player.playbackRate = rate;
        setStatus(`播放速度已设为 ${rate}×。`);
      }
      async function toggleFullscreen() {
        try {
          if (document.fullscreenElement) await document.exitFullscreen();
          else if (typeof playerStage.requestFullscreen === 'function') await playerStage.requestFullscreen();
          else throw new Error('unsupported');
        } catch (_) { setStatus('当前浏览器无法进入全屏播放。', true); }
      }
      async function togglePictureInPicture() {
        try {
          if (document.pictureInPictureElement) await document.exitPictureInPicture();
          else if (typeof player.requestPictureInPicture === 'function') await player.requestPictureInPicture();
          else throw new Error('unsupported');
        } catch (_) { setStatus('当前浏览器无法使用画中画。', true); }
      }
      function updateFullscreenLabel() {
        fullscreenButton.textContent = document.fullscreenElement ? '退出全屏' : '全屏';
      }
      function isEditableTarget(target) {
        return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement || target?.isContentEditable === true;
      }
      async function togglePlayback() {
        if (!hasPlayableSource()) return startDirect();
        try {
          if (player.paused) await player.play(); else player.pause();
        } catch (_) { setStatus('浏览器阻止了播放，请使用播放器控制栏再次开始。', true); }
      }
      function seekBy(seconds) {
        if (!hasPlayableSource() || !Number.isFinite(player.currentTime)) return;
        const maximum = Number.isFinite(player.duration) ? player.duration : Number.MAX_SAFE_INTEGER;
        player.currentTime = Math.min(Math.max(player.currentTime + seconds, 0), maximum);
      }
      const prepareNewSource = () => {
        cancelAutomaticNext();
        resumeApplied = false;
        playbackStartedReported = false;
        lastProgressBucket = -1;
      };
      async function startDirect() {
        if (!canDirectPlay || isStarting) return;
        setBusy(true);
        prepareNewSource();
        player.src = mediaPath('/api/v1/stream/');
        player.load();
        void loadSidecarSubtitles();
        setStatus('正在准备直接播放…');
        try {
          await player.play();
          setStatus('正在直接播放。');
        } catch (error) {
          setStatus(error?.name === 'NotAllowedError' ? '浏览器阻止了自动开始，请在播放器中再次按播放。' : '当前浏览器无法解码此媒体格式。', true);
        } finally { setBusy(false); }
      }

      directButton.disabled = !canDirectPlay;
      if (!canDirectPlay) setStatus('此条目没有当前账号可用的浏览器播放权限。', true);
      renderPreference();
      directButton.addEventListener('click', startDirect);
      cancelAutomaticNextButton?.addEventListener('click', () => cancelAutomaticNext(true));
      resetPlaybackButton.addEventListener('click', resetPlaybackState);
      favoriteButton.addEventListener('click', () => {
        void updatePreference('favorite', !preference.isFavorite, favoriteButton);
      });
      watchlistButton.addEventListener('click', () => {
        void updatePreference('watchlist', !preference.isWatchlist, watchlistButton);
      });
      ratingControl.addEventListener('input', () => {
        const rating = Number(ratingControl.value);
        ratingValue.textContent = Number.isFinite(rating) && rating > 0 ? `${rating.toFixed(1)} / 5` : '未评分';
      });
      ratingControl.addEventListener('change', () => {
        const rating = Number(ratingControl.value);
        if (!Number.isFinite(rating) || rating < 0 || rating > 5) return;
        void updatePreference('rating', rating, ratingControl);
      });
      speedControl.addEventListener('change', setPlaybackRate);
      fullscreenButton.hidden = typeof playerStage.requestFullscreen !== 'function';
      fullscreenButton.addEventListener('click', toggleFullscreen);
      pictureInPictureButton.hidden = !document.pictureInPictureEnabled || typeof player.requestPictureInPicture !== 'function';
      pictureInPictureButton.addEventListener('click', togglePictureInPicture);
      document.addEventListener('fullscreenchange', updateFullscreenLabel);
      document.addEventListener('keydown', (event) => {
        if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey || isEditableTarget(event.target)) return;
        if (event.key === ' ' || event.key === 'Spacebar') { event.preventDefault(); void togglePlayback(); }
        else if (event.key === 'ArrowLeft') { event.preventDefault(); seekBy(-5); }
        else if (event.key === 'ArrowRight') { event.preventDefault(); seekBy(5); }
        else if (event.key.toLowerCase() === 'f' && !fullscreenButton.hidden) { event.preventDefault(); void toggleFullscreen(); }
        else if (event.key.toLowerCase() === 'm') { player.muted = !player.muted; setStatus(player.muted ? '已静音。' : '已取消静音。'); }
      });
      technicalInfo.addEventListener('toggle', () => {
        if (technicalInfo.open) void loadStreamInfo();
      });
      player.addEventListener('playing', () => {
        setStatus('正在直接播放。');
        if (!playbackStartedReported) {
          playbackStartedReported = true;
          void reportPlaybackState('started');
        }
      });
      player.addEventListener('loadedmetadata', () => {
        if (resumeApplied || !Number.isFinite(resumePosition) || resumePosition < 10) return;
        resumeApplied = true;
        if (Number.isFinite(player.duration) && resumePosition < player.duration - 30) player.currentTime = resumePosition;
      });
      player.addEventListener('timeupdate', () => {
        if (!playbackStartedReported || !Number.isFinite(player.currentTime)) return;
        const bucket = Math.floor(player.currentTime / 15);
        if (bucket <= lastProgressBucket) return;
        lastProgressBucket = bucket;
        void reportPlaybackState('progress');
      });
      player.addEventListener('pause', () => {
        if (playbackStartedReported && !player.ended) {
          cancelAutomaticNext();
          void reportPlaybackState('stopped');
        }
      });
      player.addEventListener('ended', () => {
        if (!playbackStartedReported) return;
        playbackStartedReported = false;
        void reportPlaybackState('completed');
        scheduleAutomaticNext();
      });
      player.addEventListener('error', () => {
        setStatus('浏览器无法读取此媒体；请检查当前浏览器的容器与编码支持。', true);
      });
      window.addEventListener('pagehide', () => {
        cancelAutomaticNext();
        if (playbackStartedReported) void reportPlaybackState('stopped', true);
      });
      if (window.location.hash === '#autoplay' && canDirectPlay) {
        history.replaceState(null, '', `${window.location.pathname}${window.location.search}`);
        window.setTimeout(() => { void startDirect(); }, 0);
      }
    })();
    """#

    private static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = max(Int(seconds.rounded() / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
    }

    private static func episodeNavigationControl(
        _ episode: ServerEpisodeNavigation?,
        id: String,
        action: String
    ) -> String {
        guard let episode, let encodedID = ServerWebURL.pathSegment(episode.id) else { return "" }
        let title = escape(episode.title)
        return "<a id=\"\(id)\" class=\"player-nav\" href=\"/item/\(encodedID)\" aria-label=\"\(escape(action))：\(title)\">\(escape(action))</a>"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
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
