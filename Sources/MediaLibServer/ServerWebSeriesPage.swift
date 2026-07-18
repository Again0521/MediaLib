import Foundation
import MediaLibServerProtocol

/// 客户端式系列详情：首屏只渲染受权系列摘要，各季在用户展开时按页读取。
/// 所有动态剧集文本只经 textContent 进入 DOM；具体媒体仍跳转到网页播放器解码。
enum ServerWebSeriesPage {
    static func render(
        serverName: String,
        detail: ServerSeriesDetail,
        csrfToken: String,
        showAdministration: Bool
    ) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .library, showAdministration: showAdministration, note: .playback
        )
        let encodedID = ServerWebURL.pathSegment(detail.id)
        let poster: String
        if detail.artworkAvailable, let encodedID {
            poster = "<div class=\"series-poster\"><img src=\"/api/v1/images/\(encodedID)/poster\" alt=\"\" loading=\"eager\" decoding=\"async\"></div>"
        } else {
            poster = "<div class=\"series-poster placeholder\" role=\"img\" aria-label=\"\(escape(detail.title)) 的封面占位图\"><span>\(escape(String(detail.type.prefix(1)).uppercased()))</span></div>"
        }
        let originalTitle = detail.originalTitle.map { "<p class=\"original-title\">\(escape($0))</p>" } ?? ""
        let year = detail.year.map(String.init) ?? "年份未知"
        let rating = detail.communityRating.map { String(format: "%.1f / 10", $0) } ?? "暂无评分"
        let genres = detail.genres.isEmpty ? "未标注类型" : detail.genres.joined(separator: " · ")
        let preferenceRating = detail.userPreference.rating.map { String(format: "%.1f", $0) } ?? "0"
        let preferenceSummary = detail.userPreference.rating.map { String(format: "%.1f / 5", $0) } ?? "未评分"
        let seasons = detail.seasons.enumerated().map { index, season in
            let key = season.seasonNumber.map(String.init) ?? "unspecified"
            let watchedText = season.watchedCount == season.episodeCount && season.episodeCount > 0
                ? "已看完"
                : "已看 \(season.watchedCount) 集"
            let progressText = season.inProgressCount > 0 ? " · \(season.inProgressCount) 集观看中" : ""
            return """
            <details class="season" data-season-key="\(escape(key))"\(index == 0 ? " open" : "")>
              <summary><span><strong>\(escape(season.title))</strong><small>\(season.episodeCount) 集 · \(watchedText)\(progressText)</small></span><span class="season-chevron" aria-hidden="true"></span></summary>
              <div class="season-body"><p class="season-status" role="status" aria-live="polite">展开后载入剧集…</p><div class="episode-list" aria-busy="false"></div><button class="load-more" type="button" hidden>载入更多</button></div>
            </details>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>\(escape(detail.title)) · \(escape(serverName))</title>
          <link rel="stylesheet" href="/assets/series.css">
          <link rel="stylesheet" href="/assets/app-shell.css">
          <script src="/assets/series.js" defer></script>
        </head>
        <body data-series-id="\(escape(detail.id))" data-is-favorite="\(detail.userPreference.isFavorite ? "true" : "false")" data-is-watchlist="\(detail.userPreference.isWatchlist ? "true" : "false")" data-preference-rating="\(preferenceRating)">
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">
            \(sidebar)
            <main id="main" tabindex="-1">
              <a class="back" href="/library">← 返回资料库</a>
              <section class="series-hero" aria-labelledby="series-title">
                \(poster)
                <div class="series-copy"><p class="eyebrow">Mlink Series</p><h1 id="series-title">\(escape(detail.title))</h1>\(originalTitle)<ul class="facts"><li>\(escape(detail.type))</li><li>\(escape(year))</li><li>\(detail.seasons.count) 季</li><li>\(detail.totalEpisodeCount) 集</li><li>\(escape(rating))</li></ul><p class="overview">\(escape(detail.overview ?? "暂无简介。"))</p><p class="genres">\(escape(genres))</p></div>
              </section>
              <section class="preferences" aria-labelledby="preferences-title"><div><h2 id="preferences-title">我的清单</h2><p id="preference-status" role="status" aria-live="polite">这些标记只属于当前账号。</p></div><button id="toggle-favorite" type="button" aria-pressed="\(detail.userPreference.isFavorite ? "true" : "false")">\(detail.userPreference.isFavorite ? "已收藏" : "收藏")</button><button id="toggle-watchlist" type="button" aria-pressed="\(detail.userPreference.isWatchlist ? "true" : "false")">\(detail.userPreference.isWatchlist ? "已加入想看" : "加入想看")</button><label for="user-rating">我的评分<input id="user-rating" type="range" min="0" max="5" step="0.5" value="\(preferenceRating)"><output id="user-rating-value" for="user-rating">\(preferenceSummary)</output></label></section>
              <section class="episodes" aria-labelledby="episodes-title"><div class="section-heading"><div><p class="eyebrow">Episodes</p><h2 id="episodes-title">剧集</h2></div><span>共 \(detail.totalEpisodeCount) 集</span></div>\(seasons)</section>
              <footer>季与剧集只来自当前账号获授权的服务端资料库；播放由具体剧集的网页播放器和浏览器原生解码完成。</footer>
            </main>
          </div>
        </body></html>
        """
    }

    static let style = """
    :root { --primary:#236fb5; --primary-strong:#174d82; --ink:#172033; --muted:#5f6e84; --line:#dfe7f1; --canvas:#f4f8fc; --surface:#fff; --focus:#1570ef; --success:#087a55; --danger:#b42318; }
    * { box-sizing:border-box; } html { min-width:320px; } body { margin:0; overflow-x:hidden; color:var(--ink); background:var(--canvas); font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; } a,button,input,summary { touch-action:manipulation; } :focus-visible { outline:3px solid var(--focus); outline-offset:3px; }
    .skip { position:fixed; z-index:1000; top:8px; left:8px; padding:10px 14px; border-radius:9px; color:#fff; background:var(--primary-strong); transform:translateY(-160%); } .skip:focus { transform:none; }
    main { width:100%; max-width:1440px; min-width:0; padding:clamp(22px,4vw,48px); } .back { display:inline-flex; align-items:center; min-height:44px; margin-bottom:14px; color:var(--primary-strong); font-weight:700; text-decoration:none; }
    .series-hero { display:grid; grid-template-columns:minmax(180px,260px) minmax(0,1fr); gap:clamp(24px,4vw,52px); align-items:end; } .series-poster { display:grid; overflow:hidden; aspect-ratio:2/3; place-items:center; border:1px solid #bcd2e7; border-radius:20px; color:#fff; background:linear-gradient(145deg,#174d82,#2e90fa 58%,#91ddff); box-shadow:0 18px 44px #17385d24; font-size:72px; font-weight:850; } .series-poster img { width:100%; height:100%; object-fit:cover; }
    .eyebrow { margin:0 0 6px; color:var(--primary); font-size:13px; font-weight:800; letter-spacing:.08em; text-transform:uppercase; } h1 { margin:0; font-size:clamp(34px,6vw,68px); line-height:1.05; letter-spacing:-.045em; overflow-wrap:anywhere; } .original-title { margin:10px 0 0; color:var(--muted); font-size:18px; } .facts { display:flex; flex-wrap:wrap; gap:8px; margin:20px 0 0; padding:0; list-style:none; } .facts li { padding:6px 10px; border:1px solid #cad8e7; border-radius:999px; color:#42526a; background:#fff; font-size:13px; } .overview { max-width:75ch; margin:22px 0 0; color:#3d4b60; white-space:pre-wrap; overflow-wrap:anywhere; } .genres { margin:10px 0 0; color:var(--muted); }
    button { min-height:44px; padding:9px 16px; border:1px solid #b8cae0; border-radius:10px; color:var(--primary-strong); background:#f5f9fd; cursor:pointer; font:inherit; font-weight:750; transition:background-color .18s ease,border-color .18s ease; } button:hover { border-color:#7fb3e3; background:#eaf4ff; } button:disabled { cursor:not-allowed; opacity:.48; }
    .preferences { display:flex; flex-wrap:wrap; gap:12px; align-items:center; margin-top:28px; padding:18px; border:1px solid var(--line); border-radius:16px; background:var(--surface); } .preferences>div { flex:1 1 240px; } .preferences h2 { margin:0; font-size:18px; } .preferences p { margin:5px 0 0; color:var(--muted); font-size:13px; } .preferences p.error { color:var(--danger); } .preferences button[aria-pressed="true"] { border-color:var(--primary); color:#fff; background:var(--primary); } .preferences label { display:flex; align-items:center; gap:10px; min-height:44px; font-size:14px; font-weight:750; } .preferences input { width:min(170px,35vw); accent-color:var(--primary); } .preferences output { min-width:58px; color:var(--primary-strong); text-align:right; }
    .episodes { margin-top:34px; } .section-heading { display:flex; align-items:end; justify-content:space-between; gap:16px; margin-bottom:14px; } .section-heading h2 { margin:0; font-size:28px; } .section-heading>span { color:var(--muted); font-variant-numeric:tabular-nums; }
    .season { overflow:hidden; margin-top:10px; border:1px solid var(--line); border-radius:14px; background:var(--surface); } .season>summary { display:flex; min-height:56px; padding:8px 16px; align-items:center; justify-content:space-between; gap:14px; cursor:pointer; list-style:none; } .season>summary::-webkit-details-marker { display:none; } .season>summary:hover { background:#f6faff; } .season>summary span:first-child { display:grid; gap:2px; } .season>summary small { color:var(--muted); font-size:12px; font-weight:500; } .season-chevron { width:10px; height:10px; border-right:2px solid #60738a; border-bottom:2px solid #60738a; transform:rotate(45deg); transition:transform .18s ease; } .season[open] .season-chevron { transform:rotate(225deg); }
    .season-body { padding:0 14px 14px; border-top:1px solid #edf1f6; } .season-status { margin:12px 0; color:var(--muted); } .season-status.error { color:var(--danger); } .episode-list { display:grid; gap:8px; } .episode-row { display:grid; grid-template-columns:144px minmax(0,1fr) auto; gap:14px; align-items:center; min-width:0; padding:10px; border:1px solid #e4eaf2; border-radius:12px; background:#fbfdff; } .episode-art { position:relative; display:grid; overflow:hidden; aspect-ratio:16/9; place-items:center; border-radius:9px; color:#fff; background:linear-gradient(145deg,#174d82,#56b8ed); font-weight:800; text-decoration:none; } .episode-art img { width:100%; height:100%; object-fit:cover; } .mlink { position:absolute; top:6px; left:6px; padding:3px 6px; border-radius:6px; color:#fff; background:#123b68e8; font-size:10px; } .episode-copy { min-width:0; } .episode-copy h3 { margin:0; font-size:15px; overflow-wrap:anywhere; } .episode-copy p { margin:5px 0 0; color:var(--muted); font-size:13px; } .episode-state { color:var(--success)!important; font-weight:700; } .play-link { display:inline-flex; min-height:44px; padding:9px 15px; align-items:center; border-radius:10px; color:#fff; background:var(--primary); font-weight:750; text-decoration:none; } .play-link:hover { background:var(--primary-strong); } .load-more { display:block; min-width:132px; margin:14px auto 0; }
    footer { margin-top:34px; color:var(--muted); font-size:13px; }
    @media (max-width:780px) { main { padding:24px 18px 40px; } .series-hero { grid-template-columns:110px minmax(0,1fr); gap:20px; align-items:center; } .series-poster { border-radius:14px; font-size:40px; } h1 { font-size:clamp(30px,8vw,50px); } .overview,.genres { grid-column:1/-1; } .episode-row { grid-template-columns:112px minmax(0,1fr); } .play-link { grid-column:1/-1; justify-content:center; } }
    @media (max-width:480px) { .series-hero { grid-template-columns:82px minmax(0,1fr); gap:15px; } .facts { grid-column:1/-1; } .preferences button { flex:1 1 120px; } .preferences label { flex:1 0 100%; flex-wrap:wrap; } .episode-row { grid-template-columns:92px minmax(0,1fr); gap:10px; } }
    @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
    """

    static let script = #"""
    (() => {
      'use strict';
      const seriesID = document.body.dataset.seriesId || '';
      const csrfToken = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
      const favoriteButton = document.getElementById('toggle-favorite');
      const watchlistButton = document.getElementById('toggle-watchlist');
      const rating = document.getElementById('user-rating');
      const ratingValue = document.getElementById('user-rating-value');
      const preferenceStatus = document.getElementById('preference-status');
      let preference = {
        isFavorite: document.body.dataset.isFavorite === 'true',
        isWatchlist: document.body.dataset.isWatchlist === 'true',
        rating: Number(document.body.dataset.preferenceRating || 0) || null
      };
      const element = (name, className, text) => {
        const node = document.createElement(name);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
      };
      const duration = value => {
        const seconds = Number(value);
        if (!Number.isFinite(seconds) || seconds <= 0) return '时长未知';
        const minutes = Math.max(1, Math.round(seconds / 60));
        return `${minutes} 分钟`;
      };
      function renderEpisode(item) {
        const row = element('article', 'episode-row');
        const id = String(item.id || '');
        const mediaURL = `/item/${encodeURIComponent(id)}`;
        const art = element('a', 'episode-art', item.episodeNumber ? `第 ${item.episodeNumber} 集` : '剧集');
        art.href = mediaURL;
        art.setAttribute('aria-label', `查看并播放 ${String(item.title || '未命名剧集')}`);
        art.append(element('span', 'mlink', 'Mlink'));
        if (item.artworkAvailable === true) {
          const image = document.createElement('img');
          image.alt = '';
          image.loading = 'lazy';
          image.decoding = 'async';
          image.src = `/api/v1/images/${encodeURIComponent(id)}/poster`;
          image.addEventListener('load', () => art.replaceChildren(image, element('span', 'mlink', 'Mlink')), { once: true });
        }
        const copy = element('div', 'episode-copy');
        copy.append(element('h3', '', String(item.title || '未命名剧集')));
        const labels = [];
        if (Number.isInteger(item.seasonNumber)) labels.push(`S${String(item.seasonNumber).padStart(2, '0')}`);
        if (Number.isInteger(item.episodeNumber)) labels.push(`E${String(item.episodeNumber).padStart(2, '0')}`);
        labels.push(duration(item.runtimeSeconds));
        copy.append(element('p', '', labels.join(' · ')));
        const state = item.userState;
        if (state) {
          const percent = Math.max(0, Math.min(100, Math.round(Number(state.progress) * 100) || 0));
          copy.append(element('p', 'episode-state', state.isWatched ? '已看完' : (percent > 0 ? `看到 ${percent}%` : '未观看')));
        }
        const play = element('a', 'play-link', '播放');
        play.href = mediaURL;
        play.setAttribute('aria-label', `播放 ${String(item.title || '未命名剧集')}`);
        row.append(art, copy, play);
        return row;
      }
      const seasonState = new WeakMap();
      async function loadSeason(section) {
        const state = seasonState.get(section) || { offset: 0, loading: false, complete: false, controller: null };
        if (state.loading || state.complete || !seriesID) return;
        const key = section.dataset.seasonKey || '';
        if (!(key === 'unspecified' || /^\d{1,5}$/.test(key))) return;
        state.loading = true;
        state.controller = new AbortController();
        seasonState.set(section, state);
        const status = section.querySelector('.season-status');
        const list = section.querySelector('.episode-list');
        const more = section.querySelector('.load-more');
        more.disabled = true;
        list.setAttribute('aria-busy', 'true');
        status.hidden = false;
        status.classList.remove('error');
        status.textContent = state.offset === 0 ? '正在载入剧集…' : '正在载入更多剧集…';
        const timeout = window.setTimeout(() => state.controller.abort(), 10000);
        try {
          const params = new URLSearchParams({ season: key, offset: String(state.offset), limit: '50' });
          const response = await fetch(`/api/v1/series/${encodeURIComponent(seriesID)}/episodes?${params.toString()}`, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal: state.controller.signal });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error(`服务暂时不可用（${response.status}）。`);
          const data = await response.json();
          const items = Array.isArray(data.items) ? data.items : [];
          const fragment = document.createDocumentFragment();
          for (const item of items) fragment.append(renderEpisode(item));
          list.append(fragment);
          state.offset += items.length;
          state.complete = !Boolean(data.hasMore);
          more.hidden = state.complete;
          status.hidden = items.length > 0 || state.offset > 0;
          if (state.offset === 0) status.textContent = '这一季没有可见剧集。';
        } catch (error) {
          status.hidden = false;
          status.classList.add('error');
          status.textContent = error?.name === 'AbortError' ? '请求超时，请重新展开或载入。' : (error instanceof Error ? error.message : '剧集载入失败。');
        } finally {
          window.clearTimeout(timeout);
          state.loading = false;
          more.disabled = false;
          list.setAttribute('aria-busy', 'false');
        }
      }
      document.querySelectorAll('.season').forEach(section => {
        seasonState.set(section, { offset: 0, loading: false, complete: false, controller: null });
        section.addEventListener('toggle', () => { if (section.open) void loadSeason(section); });
        section.querySelector('.load-more')?.addEventListener('click', () => void loadSeason(section));
        if (section.open) void loadSeason(section);
      });
      const normalizePreference = value => ({
        isFavorite: value?.isFavorite === true,
        isWatchlist: value?.isWatchlist === true,
        rating: typeof value?.rating === 'number' && Number.isFinite(value.rating) && value.rating > 0 && value.rating <= 5 ? value.rating : null
      });
      function renderPreference() {
        favoriteButton.setAttribute('aria-pressed', String(preference.isFavorite));
        favoriteButton.textContent = preference.isFavorite ? '已收藏' : '收藏';
        watchlistButton.setAttribute('aria-pressed', String(preference.isWatchlist));
        watchlistButton.textContent = preference.isWatchlist ? '已加入想看' : '加入想看';
        rating.value = String(preference.rating || 0);
        ratingValue.textContent = preference.rating ? `${preference.rating.toFixed(1)} / 5` : '未评分';
      }
      async function updatePreference(field, value, control) {
        control.disabled = true;
        preferenceStatus.classList.remove('error');
        preferenceStatus.textContent = '正在更新我的清单…';
        try {
          const response = await fetch(`/api/v1/user-media/preferences/${encodeURIComponent(seriesID)}`, { method: 'POST', credentials: 'same-origin', headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken }, body: JSON.stringify({ [field]: value }) });
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('unavailable');
          preference = normalizePreference(await response.json());
          renderPreference();
          preferenceStatus.textContent = '我的清单已更新。';
        } catch (_) {
          renderPreference();
          preferenceStatus.classList.add('error');
          preferenceStatus.textContent = '无法更新我的清单，请稍后重试。';
        } finally { control.disabled = false; }
      }
      favoriteButton.addEventListener('click', () => void updatePreference('favorite', !preference.isFavorite, favoriteButton));
      watchlistButton.addEventListener('click', () => void updatePreference('watchlist', !preference.isWatchlist, watchlistButton));
      rating.addEventListener('change', () => void updatePreference('rating', Number(rating.value), rating));
      renderPreference();
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
