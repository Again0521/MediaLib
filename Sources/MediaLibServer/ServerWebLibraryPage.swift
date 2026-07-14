import Foundation

/// 认证资料库浏览页。页面只包含同源静态脚本，所有服务器返回文本均通过
/// `textContent` 写入 DOM，避免把媒体元数据变成 HTML 注入面。
enum ServerWebLibraryPage {
    static func render(serverName: String, csrfToken: String, showAdministration: Bool) -> String {
        let administrationLink = showAdministration ? "<a href=\"/admin\">服务管理</a>" : ""
        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="medialib-csrf-token" content="\(escape(csrfToken))">
          <title>资料库 · \(escape(serverName))</title>
          <style>
            :root { --primary:#236fb5; --primary-strong:#174d82; --accent:#087f5b; --ink:#172033; --muted:#64748b; --line:#dfe7f1; --canvas:#f4f8fc; --surface:#fff; --focus:#1570ef; --danger:#b42318; }
            * { box-sizing:border-box; } html { min-width:320px; } body { overflow-x:hidden; margin:0; color:var(--ink); background:var(--canvas); font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
            a,button,select,input { touch-action:manipulation; } :focus-visible { outline:3px solid var(--focus); outline-offset:3px; }
            .skip { position:fixed; z-index:1000; top:8px; left:8px; padding:10px 14px; border-radius:9px; color:#fff; background:var(--primary-strong); transform:translateY(-160%); } .skip:focus { transform:none; }
            .shell { display:grid; grid-template-columns:232px minmax(0,1fr); min-height:100dvh; }
            aside { padding:28px 18px; color:#eef7ff; background:linear-gradient(165deg,#183b68,#1e79cf 56%,#36bffa); }
            .brand { display:flex; gap:10px; align-items:center; font-size:19px; font-weight:800; letter-spacing:.3px; }
            .brand-mark { display:grid; place-items:center; width:34px; height:34px; border-radius:11px; color:#1774ce; background:#fff; box-shadow:0 8px 18px #123c6a55; }
            nav { display:grid; gap:6px; margin-top:42px; } nav a { display:flex; align-items:center; min-height:44px; padding:10px 12px; border-radius:10px; color:inherit; text-decoration:none; font-size:14px; } nav a:hover,nav a.active { background:#ffffff2c; } nav a.active { font-weight:700; }
            .privacy { margin-top:28px; padding:13px; border:1px solid #ffffff35; border-radius:14px; background:#173d6d45; font-size:12px; }
            main { min-width:0; padding:clamp(22px,4vw,48px); } .eyebrow { margin:0 0 6px; color:var(--primary); font-size:13px; font-weight:750; letter-spacing:.08em; text-transform:uppercase; }
            h1 { margin:0; font-size:clamp(30px,5vw,52px); line-height:1.08; letter-spacing:-.045em; } .subtitle { max-width:68ch; margin:12px 0 0; color:var(--muted); }
            .filters { display:grid; grid-template-columns:minmax(220px,2fr) repeat(2,minmax(150px,1fr)) auto; gap:12px; align-items:end; margin-top:28px; padding:16px; border:1px solid var(--line); border-radius:18px; background:var(--surface); box-shadow:0 10px 30px #20385b0c; }
            .field { display:grid; gap:6px; min-width:0; } label { font-size:13px; font-weight:700; } input,select,button { min-height:44px; border:1px solid #bdcadb; border-radius:10px; font:inherit; } input,select { width:100%; padding:9px 11px; color:var(--ink); background:#fff; } button { padding:9px 18px; border-color:var(--primary); color:#fff; background:var(--primary); cursor:pointer; font-weight:750; transition:background-color .18s ease,border-color .18s ease; } button:hover { background:var(--primary-strong); } button:disabled { cursor:not-allowed; opacity:.48; }
            .results-head { display:flex; gap:16px; align-items:center; justify-content:space-between; margin-top:30px; } h2 { margin:0; font-size:19px; } .count { color:var(--muted); font-variant-numeric:tabular-nums; }
            .status { min-height:48px; margin:12px 0; padding:12px 14px; border:1px solid var(--line); border-radius:12px; color:var(--muted); background:#ffffffb8; } .status[hidden] { display:none; } .status.error { color:var(--danger); border-color:#f2b8b5; background:#fff4f2; }
            .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(164px,1fr)); gap:16px; }
            .card { position:relative; overflow:hidden; min-width:0; border:1px solid var(--line); border-radius:16px; background:var(--surface); box-shadow:0 10px 28px #243a6210; }
            .card a { display:block; min-height:100%; color:inherit; text-decoration:none; transition:background-color .18s ease; } .card a:hover { background:#f4f9ff; }
            .poster { display:grid; overflow:hidden; aspect-ratio:2/3; place-items:center; color:#fff; background:linear-gradient(145deg,#236dbb,#36bffa 56%,#9ae2ff); font-size:48px; font-weight:800; } .poster img { width:100%; height:100%; object-fit:cover; }
            .mlink { position:absolute; z-index:10; top:9px; left:9px; padding:4px 7px; border-radius:7px; color:#fff; background:#123b68e8; box-shadow:0 3px 10px #0c274555; font-size:11px; font-weight:800; letter-spacing:.03em; }
            .copy { padding:12px; } .title { overflow:hidden; margin:0; font-size:14px; line-height:1.4; text-overflow:ellipsis; white-space:nowrap; } .meta { margin:6px 0 0; color:var(--muted); font-size:12px; }
            .progress-label { display:block; margin-top:9px; color:var(--primary-strong); font-size:12px; } progress { display:block; width:100%; height:7px; margin-top:4px; accent-color:var(--accent); }
            .pager { display:flex; gap:12px; align-items:center; justify-content:center; margin-top:28px; } .pager button { min-width:96px; } .page-label { min-width:120px; text-align:center; color:var(--muted); font-variant-numeric:tabular-nums; }
            footer { margin-top:42px; color:var(--muted); font-size:12px; }
            @media (max-width:900px) { .filters { grid-template-columns:1fr 1fr; } .search-field { grid-column:1/-1; } }
            @media (max-width:720px) { .shell { display:block; } aside { padding:16px 20px; } nav { display:flex; overflow:auto; gap:8px; margin-top:14px; } nav a { flex:none; } .privacy { display:none; } main { padding:24px 18px 36px; } .filters { grid-template-columns:1fr; } .search-field { grid-column:auto; } .filters button { width:100%; } .grid { grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px; } }
            @media (max-width:374px) { .grid { grid-template-columns:1fr; } }
            @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
          </style>
          <script src="/assets/library.js" defer></script>
        </head>
        <body>
          <a class="skip" href="#main">跳到主要内容</a>
          <div class="shell">
            <aside><div class="brand"><span class="brand-mark">M</span><span>MediaLIB</span></div><nav aria-label="主导航"><a href="/">资料库首页</a><a class="active" aria-current="page" href="/library">浏览全部</a>\(administrationLink)<a href="/.well-known/mlink">Mlink 描述</a><a href="/health">服务健康</a></nav><p class="privacy">分类、搜索结果和续播进度均由当前服务端授权后返回，不包含本地文件路径或其他用户记录。</p></aside>
            <main id="main" tabindex="-1">
              <p class="eyebrow">Mlink Library</p><h1>浏览资料库</h1><p class="subtitle">在 \(escape(serverName)) 中按服务端分类查找内容。结果每页最多 100 项，降低浏览器与服务端的瞬时占用。</p>
              <form class="filters" id="filters" role="search">
                <div class="field search-field"><label for="query">搜索标题、年份或类型</label><input id="query" name="q" type="search" maxlength="128" autocomplete="off" placeholder="输入关键词"></div>
                <div class="field"><label for="type">服务端分类</label><select id="type" name="type"><option value="">全部分类</option></select></div>
                <div class="field"><label for="sort">排序方式</label><select id="sort" name="sort"><option value="updatedDescending">最近更新</option><option value="titleAscending">标题 A–Z</option><option value="yearDescending">年份从新到旧</option></select></div>
                <button id="submit" type="submit">应用筛选</button>
              </form>
              <div class="results-head"><h2>媒体项目</h2><span class="count" id="count">等待加载</span></div>
              <div class="status" id="status" role="status" aria-live="polite">正在载入资料库…</div>
              <div class="grid" id="grid" aria-busy="true"></div>
              <nav class="pager" aria-label="资料库分页"><button id="previous" type="button" disabled>上一页</button><span class="page-label" id="page-label">第 1 页</span><button id="next" type="button" disabled>下一页</button></nav>
              <footer>认证资料库 · 同源 API · 每页 48 项</footer>
            </main>
          </div>
        </body></html>
        """
    }

    static let script = #"""
    (() => {
      'use strict';
      const pageSize = 48;
      const form = document.getElementById('filters');
      const query = document.getElementById('query');
      const type = document.getElementById('type');
      const sort = document.getElementById('sort');
      const submit = document.getElementById('submit');
      const grid = document.getElementById('grid');
      const status = document.getElementById('status');
      const count = document.getElementById('count');
      const previous = document.getElementById('previous');
      const next = document.getElementById('next');
      const pageLabel = document.getElementById('page-label');
      let offset = 0;
      let total = 0;
      let controller = null;

      const element = (name, className, text) => {
        const node = document.createElement(name);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
      };

      const safeInitialState = () => {
        const params = new URLSearchParams(window.location.search);
        const q = params.get('q') || '';
        query.value = q.slice(0, 128);
        const initialSort = params.get('sort');
        if (['updatedDescending', 'titleAscending', 'yearDescending'].includes(initialSort)) sort.value = initialSort;
        const parsedOffset = Number(params.get('offset') || '0');
        offset = Number.isSafeInteger(parsedOffset) && parsedOffset >= 0 && parsedOffset <= 1000000 ? parsedOffset : 0;
        return params.get('type') || '';
      };

      const requestedType = safeInitialState();

      async function fetchJSON(path, signal) {
        const response = await fetch(path, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal });
        if (!response.ok) throw new Error(response.status === 401 ? '登录已失效，请重新登录。' : `服务暂时不可用（${response.status}）。`);
        return response.json();
      }

      async function loadCategories() {
        try {
          const data = await fetchJSON('/api/v1/library/categories');
          const fragment = document.createDocumentFragment();
          for (const category of Array.isArray(data.categories) ? data.categories : []) {
            if (typeof category.id !== 'string' || typeof category.title !== 'string') continue;
            const option = document.createElement('option');
            option.value = category.id;
            option.textContent = `${category.title}（${Number(category.itemCount) || 0}）`;
            fragment.append(option);
          }
          type.append(fragment);
          if (Array.from(type.options).some(option => option.value === requestedType)) type.value = requestedType;
        } catch (_) {
          // 分类失败不阻塞“全部分类”浏览；主列表会显示自己的可恢复错误。
        }
      }

      function renderItem(item) {
        const article = element('article', 'card');
        const link = element('a');
        link.href = `/item/${encodeURIComponent(String(item.id || ''))}`;
        link.setAttribute('aria-label', `查看并播放 ${String(item.title || '未命名媒体')}`);
        const badge = element('span', 'mlink', 'Mlink');
        const poster = element('div', 'poster', String(item.type || 'M').slice(0, 1).toUpperCase());
        poster.setAttribute('role', 'img');
        poster.setAttribute('aria-label', `${String(item.type || '媒体')} 占位封面`);
        if (item.artworkAvailable === true) {
          const image = document.createElement('img');
          image.alt = '';
          image.loading = 'lazy';
          image.decoding = 'async';
          image.src = `/api/v1/images/${encodeURIComponent(String(item.id || ''))}/poster`;
          image.addEventListener('load', () => poster.replaceChildren(image), { once: true });
        }
        const copy = element('div', 'copy');
        const titleNode = element('h3', 'title', String(item.title || '未命名媒体'));
        titleNode.title = String(item.title || '未命名媒体');
        const meta = element('p', 'meta', `${String(item.type || 'other')} · ${item.year || '未标注年份'}`);
        copy.append(titleNode, meta);
        const state = item.userState;
        if (state && Number.isFinite(Number(state.progress))) {
          const percent = Math.max(0, Math.min(100, Math.round(Number(state.progress) * 100)));
          const label = element('span', 'progress-label', state.isWatched ? '已看完' : `已播放 ${percent}%`);
          const progress = document.createElement('progress');
          progress.max = 100;
          progress.value = percent;
          progress.setAttribute('aria-label', label.textContent);
          copy.append(label, progress);
        }
        link.append(poster, copy);
        article.append(badge, link);
        return article;
      }

      async function loadPage(updateHistory = true) {
        if (controller) controller.abort();
        controller = new AbortController();
        const timeout = window.setTimeout(() => controller.abort(), 10000);
        submit.disabled = true;
        previous.disabled = true;
        next.disabled = true;
        grid.setAttribute('aria-busy', 'true');
        status.hidden = false;
        status.classList.remove('error');
        status.textContent = '正在载入资料库…';
        const params = new URLSearchParams({ offset: String(offset), limit: String(pageSize), sort: sort.value });
        const normalizedQuery = query.value.trim();
        if (normalizedQuery) params.set('q', normalizedQuery);
        if (type.value) params.set('type', type.value);
        try {
          const data = await fetchJSON(`/api/v1/library/browse?${params.toString()}`, controller.signal);
          total = Math.max(0, Number(data.totalItemCount) || 0);
          const items = Array.isArray(data.items) ? data.items : [];
          const fragment = document.createDocumentFragment();
          for (const item of items) fragment.append(renderItem(item));
          grid.replaceChildren(fragment);
          count.textContent = `共 ${total.toLocaleString()} 项`;
          const currentPage = Math.floor(offset / pageSize) + 1;
          const pageCount = Math.max(1, Math.ceil(total / pageSize));
          pageLabel.textContent = `第 ${currentPage} / ${pageCount} 页`;
          previous.disabled = offset === 0;
          next.disabled = !Boolean(data.hasMore);
          if (items.length === 0) {
            status.textContent = '没有符合条件的媒体。请尝试清除关键词或切换分类。';
          } else {
            status.hidden = true;
          }
          if (updateHistory) history.replaceState(null, '', `/library?${params.toString()}`);
        } catch (error) {
          if (error && error.name === 'AbortError') status.textContent = '请求超时。请检查服务状态后重试。';
          else status.textContent = error instanceof Error ? error.message : '资料库载入失败，请重试。';
          status.classList.add('error');
          grid.replaceChildren();
          count.textContent = '载入失败';
        } finally {
          window.clearTimeout(timeout);
          submit.disabled = false;
          grid.setAttribute('aria-busy', 'false');
        }
      }

      form.addEventListener('submit', event => { event.preventDefault(); offset = 0; loadPage(); });
      previous.addEventListener('click', () => { offset = Math.max(0, offset - pageSize); loadPage(); document.getElementById('main').focus(); });
      next.addEventListener('click', () => { if (offset + pageSize < total) offset += pageSize; loadPage(); document.getElementById('main').focus(); });
      loadCategories().finally(() => loadPage());
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
