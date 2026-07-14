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
        let administrationLink = showAdministration ? "<a href=\"/admin\">服务管理</a>" : ""
        let canDirectPlay = detail.canDirectPlay ? "true" : "false"
        let canTranscode = detail.canTranscode ? "true" : "false"
        let directDisabled = detail.canDirectPlay ? "" : " disabled aria-disabled=\"true\""
        let transcodeDisabled = detail.canTranscode ? "" : " disabled aria-disabled=\"true\""
        let resumePosition = detail.userState?.positionSeconds ?? 0
        let userStateSummary: String = {
            guard let state = detail.userState else { return "尚未播放" }
            if state.isWatched { return "已看 · 播放 \(state.playCount) 次" }
            if state.progress > 0 { return "续播 \(formatDuration(state.positionSeconds)) · \(Int((state.progress * 100).rounded()))%" }
            return state.playCount > 0 ? "已开始 · 播放 \(state.playCount) 次" : "尚未播放"
        }()

        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>\(escape(detail.title)) · \(escape(serverName))</title>
          <style>
            :root { --primary:#1e67a8; --primary-strong:#174d82; --ink:#172033; --muted:#5f6e84; --line:#dfe7f1; --canvas:#f4f7fb; --surface:#fff; --stage:#081523; --stage-line:#20364b; --success:#087a55; --danger:#b42318; --focus:#1570ef; }
            * { box-sizing:border-box; } body { margin:0; color:var(--ink); background:var(--canvas); font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; } a { color:inherit; } button,a { touch-action:manipulation; } :focus-visible { outline:3px solid var(--focus); outline-offset:3px; }
            .skip { position:fixed; z-index:1000; top:8px; left:8px; padding:10px 14px; border-radius:9px; color:#fff; background:var(--primary-strong); transform:translateY(-160%); } .skip:focus { transform:none; }
            .shell { display:grid; grid-template-columns:232px minmax(0,1fr); min-height:100dvh; } aside { padding:28px 18px; color:#eef7ff; background:linear-gradient(165deg,#183b68,#1e79cf 58%,#36bffa); }
            .brand { display:flex; gap:10px; align-items:center; font-size:19px; font-weight:800; } .brand-mark { display:grid; place-items:center; width:36px; height:36px; border-radius:11px; color:#176cb5; background:#fff; box-shadow:0 8px 18px #123c6a55; }
            nav { display:grid; gap:8px; margin-top:38px; } nav a { display:flex; align-items:center; min-height:44px; padding:10px 12px; border-radius:10px; text-decoration:none; } nav a:hover { background:#ffffff1c; } nav a.active { background:#ffffff2e; font-weight:700; }
            .boundary { margin-top:28px; padding:14px; border:1px solid #ffffff38; border-radius:14px; background:#153e6d55; font-size:13px; }
            main { width:100%; max-width:1440px; padding:clamp(22px,4vw,48px); } .back { display:inline-flex; align-items:center; min-height:44px; margin-bottom:14px; color:var(--primary-strong); font-weight:700; text-decoration:none; }
            .hero { display:grid; grid-template-columns:minmax(180px,260px) minmax(0,1fr); gap:clamp(24px,4vw,52px); align-items:end; } .poster { display:grid; place-items:center; aspect-ratio:2/3; border:1px solid #bcd2e7; border-radius:20px; color:#fff; background:linear-gradient(145deg,#174d82,#2e90fa 58%,#91ddff); box-shadow:0 18px 44px #17385d24; font-size:72px; font-weight:850; text-transform:uppercase; }
            h1 { margin:0; font-size:clamp(34px,6vw,68px); line-height:1.05; letter-spacing:-.045em; overflow-wrap:anywhere; } .original-title { margin:10px 0 0; color:var(--muted); font-size:18px; overflow-wrap:anywhere; }
            .facts { display:flex; flex-wrap:wrap; gap:8px; margin:20px 0 0; padding:0; list-style:none; } .facts li { padding:6px 10px; border:1px solid #cad8e7; border-radius:999px; color:#42526a; background:#fff; font-size:13px; }
            .overview { max-width:75ch; margin:24px 0 0; color:#3d4b60; white-space:pre-wrap; overflow-wrap:anywhere; }
            .player-card { margin-top:36px; overflow:hidden; border:1px solid var(--stage-line); border-radius:18px; background:var(--stage); box-shadow:0 20px 50px #0b1d3040; } .player-stage { display:grid; place-items:center; min-height:260px; background:#030a12; } video { display:block; width:100%; max-height:min(72vh,820px); background:#000; }
            .player-controls { display:flex; flex-wrap:wrap; gap:10px; align-items:center; padding:16px; color:#dcecff; } button { min-height:44px; padding:10px 16px; border:1px solid #5c7894; border-radius:11px; color:#fff; background:#173b5d; font:inherit; font-weight:750; cursor:pointer; transition:background-color .18s ease,border-color .18s ease; } button.primary { border-color:#4ba4f4; background:#1469b4; } button:hover { border-color:#8bc8ff; background:#21527d; } button:disabled { cursor:not-allowed; opacity:.48; }
            .status { flex:1 1 280px; margin:0; color:#c7d9eb; } .status.error { color:#ffb4ae; } .support-note { margin:0; padding:0 16px 16px; color:#9fb6cc; font-size:13px; }
            .details { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:14px; margin-top:24px; } .detail-card { min-height:104px; padding:17px; border:1px solid var(--line); border-radius:15px; background:var(--surface); } .detail-card span { display:block; color:var(--muted); font-size:13px; } .detail-card strong { display:block; margin-top:8px; overflow-wrap:anywhere; }
            footer { margin:30px 0 8px; color:var(--muted); font-size:13px; }
            @media (max-width:780px) { .shell { display:block; } aside { padding:16px 18px; } nav { display:flex; overflow-x:auto; margin-top:14px; } nav a { flex:none; } .boundary { display:none; } main { padding:24px 18px 40px; } .hero { grid-template-columns:110px minmax(0,1fr); gap:20px; align-items:center; } .poster { border-radius:14px; font-size:40px; } h1 { font-size:clamp(30px,8vw,50px); } .overview { grid-column:1/-1; } .details { grid-template-columns:1fr; } }
            @media (max-width:480px) { .hero { grid-template-columns:82px minmax(0,1fr); gap:15px; } .facts { grid-column:1/-1; } .player-card { margin-inline:-18px; border-left:0; border-right:0; border-radius:0; } .player-controls button { flex:1 1 130px; } }
            @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
          </style>
        </head>
        <body data-item-id="\(escape(detail.id))" data-can-direct-play="\(canDirectPlay)" data-can-transcode="\(canTranscode)" data-resume-position="\(resumePosition)" data-is-watched="\(detail.userState?.isWatched == true ? "true" : "false")">
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">
            <aside>
              <div class="brand"><span class="brand-mark" aria-hidden="true">M</span><span>MediaLIB</span></div>
              <nav aria-label="主导航"><a href="/">资料库首页</a><a class="active" aria-current="page" href="#main">媒体详情</a>\(administrationLink)<a href="/health">服务健康</a></nav>
              <div class="boundary"><strong>播放边界</strong><br>视频只通过当前登录会话和资料库授权下的同源媒体 ID 播放，不向网页发送本地文件路径。</div>
            </aside>
            <main id="main" tabindex="-1">
              <a class="back" href="/">← 返回资料库</a>
              <section class="hero" aria-labelledby="item-title">
                <div class="poster" role="img" aria-label="\(escape(detail.title)) 的封面占位图"><span>\(escape(String(detail.type.prefix(1))))</span></div>
                <div><h1 id="item-title">\(escape(detail.title))</h1>\(originalTitle)<ul class="facts"><li>\(escape(detail.type))</li><li>\(escape(year))</li><li>\(escape(runtime))</li><li>\(escape(rating))</li><li>\(escape(genres))</li></ul><p class="overview">\(escape(overview))</p></div>
              </section>
              <section class="player-card" aria-labelledby="player-heading">
                <h2 id="player-heading" class="skip">Web 播放器</h2>
                <div class="player-stage"><video id="player" controls playsinline preload="metadata" aria-label="\(escape(detail.title)) 播放器"></video></div>
                <div class="player-controls"><button id="direct-play" class="primary" type="button"\(directDisabled)>直接播放</button><button id="hls-play" type="button"\(transcodeDisabled)>兼容转码</button><button id="stop-transcode" type="button" hidden>停止转码</button><p id="player-status" class="status" role="status" aria-live="polite">选择播放方式。浏览器支持时优先直接播放。</p></div>
                <p id="support-note" class="support-note">兼容转码使用当前会话独占的 HLS；离开页面时会自动取消并清理临时文件。</p>
              </section>
              <section class="details" aria-label="媒体与用户信息"><article class="detail-card"><span>当前用户</span><strong id="user-playback-state">\(escape(userStateSummary))</strong></article><article class="detail-card"><span>分辨率</span><strong>\(escape(detail.resolution ?? "未知"))</strong></article><article class="detail-card"><span>视频编码</span><strong>\(escape(detail.videoCodec ?? "未知"))</strong></article><article class="detail-card"><span>音频编码</span><strong>\(escape(detail.audioCodec ?? "未知"))</strong></article></section>
              <footer>播放信息与媒体字节继续受当前用户、设备、会话和资料库权限检查；未知或无权媒体统一返回 404。</footer>
            </main>
          </div>
          <script src="/assets/player.js" defer></script>
        </body>
        </html>
        """
    }

    static let script = #"""
    (() => {
      'use strict';
      const player = document.getElementById('player');
      const directButton = document.getElementById('direct-play');
      const hlsButton = document.getElementById('hls-play');
      const stopButton = document.getElementById('stop-transcode');
      const status = document.getElementById('player-status');
      const supportNote = document.getElementById('support-note');
      const userPlaybackState = document.getElementById('user-playback-state');
      const itemID = document.body.dataset.itemId || '';
      const canDirectPlay = document.body.dataset.canDirectPlay === 'true';
      const canTranscode = document.body.dataset.canTranscode === 'true';
      const resumePosition = Number(document.body.dataset.resumePosition || 0);
      const csrfToken = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
      const nativeHLS = Boolean(
        player.canPlayType('application/vnd.apple.mpegurl') ||
        player.canPlayType('application/x-mpegURL')
      );
      let activeHLSSessionID = null;
      let currentMode = null;
      let fallbackAttempted = false;
      let isStarting = false;
      let resumeApplied = false;
      let playbackStartedReported = false;
      let lastProgressBucket = -1;

      const setStatus = (message, isError = false) => {
        status.textContent = message;
        status.classList.toggle('error', isError);
      };
      const setBusy = (busy) => {
        isStarting = busy;
        directButton.disabled = busy || !canDirectPlay;
        hlsButton.disabled = busy || !canTranscode || !nativeHLS;
      };
      const mediaPath = (prefix) => `${prefix}${encodeURIComponent(itemID)}`;
      const finitePlaybackNumber = (value) => Number.isFinite(value) && value >= 0 ? value : 0;
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
      const prepareNewSource = () => {
        resumeApplied = false;
        playbackStartedReported = false;
        lastProgressBucket = -1;
      };
      const safeManifestPath = (value) => {
        if (typeof value !== 'string' || !value.startsWith('/api/v1/hls/') || value.includes('\\') || value.includes('..')) return null;
        try {
          const url = new URL(value, window.location.origin);
          return url.origin === window.location.origin ? `${url.pathname}${url.search}` : null;
        } catch (_) { return null; }
      };
      async function cancelHLS(keepalive = false) {
        const sessionID = activeHLSSessionID;
        activeHLSSessionID = null;
        stopButton.hidden = true;
        if (!sessionID) return;
        try {
          await fetch(`/api/v1/hls/${encodeURIComponent(sessionID)}`, {
            method: 'DELETE', credentials: 'same-origin', keepalive,
            headers: { 'X-MediaLIB-CSRF': csrfToken }
          });
        } catch (_) { /* 页面离开或服务停止时，由服务端会话生命周期继续清理。 */ }
      }
      async function waitForManifest(path) {
        for (let attempt = 0; attempt < 40; attempt += 1) {
          const response = await fetch(path, { method: 'HEAD', credentials: 'same-origin', cache: 'no-store' });
          if (response.ok) return;
          if (response.status !== 404) throw new Error(response.status === 429 ? '转码探测过于频繁，请稍后重试。' : '转码输出暂时不可用。');
          await new Promise((resolve) => window.setTimeout(resolve, 250));
        }
        throw new Error('转码启动超时，请检查媒体文件或稍后重试。');
      }
      async function startDirect() {
        if (!canDirectPlay || isStarting) return;
        setBusy(true);
        await cancelHLS();
        currentMode = 'direct';
        prepareNewSource();
        fallbackAttempted = false;
        player.src = mediaPath('/api/v1/stream/');
        player.load();
        setStatus('正在准备直接播放…');
        let shouldFallback = false;
        try {
          await player.play();
          setStatus('正在直接播放。');
        } catch (error) {
          if (error?.name !== 'NotAllowedError') shouldFallback = true;
          else setStatus('浏览器阻止了自动开始，请在播放器中再次按播放。');
        } finally { setBusy(false); }
        if (shouldFallback) await handleDirectFailure();
      }
      async function startHLS() {
        if (!canTranscode || !nativeHLS || isStarting) return;
        setBusy(true);
        await cancelHLS();
        currentMode = 'hls';
        setStatus('正在启动兼容转码…');
        try {
          const response = await fetch(mediaPath('/api/v1/playback/hls/'), {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Accept': 'application/json', 'X-MediaLIB-CSRF': csrfToken }
          });
          if (!response.ok) throw new Error(response.status === 429 ? '转码请求过于频繁，请稍后重试。' : '无法启动兼容转码。');
          const session = await response.json();
          if (typeof session.id !== 'string' || !/^[a-z0-9-]{1,128}$/.test(session.id)) {
            throw new Error('服务端返回了无效的转码会话。');
          }
          activeHLSSessionID = session.id;
          const manifestPath = safeManifestPath(session.manifestPath);
          if (!manifestPath) throw new Error('服务端返回了无效的转码地址。');
          stopButton.hidden = false;
          await waitForManifest(manifestPath);
          player.src = manifestPath;
          prepareNewSource();
          player.load();
          await player.play();
          setStatus('正在使用兼容转码播放。');
        } catch (error) {
          await cancelHLS();
          currentMode = null;
          setStatus(error?.message || '兼容转码失败，请稍后重试。', true);
        } finally { setBusy(false); }
      }
      async function handleDirectFailure() {
        if (currentMode !== 'direct' || fallbackAttempted) return;
        fallbackAttempted = true;
        if (canTranscode && nativeHLS) {
          setStatus('浏览器无法直接播放，正在切换到兼容转码…');
          await startHLS();
        } else {
          setStatus(canTranscode ? '此浏览器无法直接播放该格式，也不支持原生 HLS。请使用 Safari 或可直放格式。' : '浏览器无法直接播放，且当前账号没有兼容转码权限。', true);
        }
      }

      directButton.disabled = !canDirectPlay;
      hlsButton.disabled = !canTranscode || !nativeHLS;
      if (!nativeHLS && canTranscode) supportNote.textContent = '当前浏览器没有原生 HLS 支持；可先尝试直接播放。跨浏览器 MSE 播放器仍在后续实施范围。';
      if (!canDirectPlay && !canTranscode) setStatus('此条目没有当前账号可用的播放方式。', true);
      directButton.addEventListener('click', startDirect);
      hlsButton.addEventListener('click', startHLS);
      stopButton.addEventListener('click', async () => {
        player.pause();
        player.removeAttribute('src');
        player.load();
        await cancelHLS();
        currentMode = null;
        setStatus('兼容转码已停止并清理。');
      });
      player.addEventListener('error', handleDirectFailure);
      player.addEventListener('medialib-direct-failed', handleDirectFailure);
      player.addEventListener('playing', () => {
        if (currentMode === 'direct') setStatus('正在直接播放。');
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
        if (playbackStartedReported && !player.ended) void reportPlaybackState('stopped');
      });
      player.addEventListener('ended', () => {
        if (!playbackStartedReported) return;
        playbackStartedReported = false;
        void reportPlaybackState('completed');
      });
      window.addEventListener('pagehide', () => {
        if (playbackStartedReported) void reportPlaybackState('stopped', true);
        void cancelHLS(true);
      });
    })();
    """#

    private static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = max(Int(seconds.rounded() / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
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
}
