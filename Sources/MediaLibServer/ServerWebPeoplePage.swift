import Foundation
import MediaLibServerProtocol

/// 人物目录与人物作品页。肖像不直接引用第三方 profile URL，而使用稳定的文字首字母
/// 占位，从而既保留可扫读的视觉节奏，也不把浏览者 IP 暴露给元数据提供方。
enum ServerWebPeoplePage {
    static func directory(
        serverName: String,
        page: ServerPeoplePage,
        csrfToken: String,
        showAdministration: Bool,
        query: String = "",
        categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras
    ) -> String {
        let cards = page.items.map(personCard).joined()
        let sidebar = ServerWebNavigation.render(active: .people, showAdministration: showAdministration, note: .library, categories: categories, extras: sidebarExtras)
        let content = """
        \(ServerWebPageHeader.render(
            icon: .people,
            eyebrow: "Cast & Crew",
            title: "人物",
            subtitle: "出现在你资料库里的演员和幕后主创。",
            countID: "people-status",
            countUnit: "位",
            initialCount: page.totalItemCount,
            // 这里从前是一份手写的表单，既没有 action 也没有 method：脚本一旦没到，
            // 按下回车只会重新加载当前 URL。现在它是共用的搜索框，无脚本时也能提交。
            search: ServerWebUI.searchField(
                id: "people-query",
                label: "搜索人物",
                placeholder: "姓名、演员、导演",
                action: "/people",
                value: query,
                formID: "people-search"
            )
        ))
        <section id="people-grid" class="people-grid" aria-live="polite">\(cards)</section>
        \(loadMore(id: "people-load-more", label: "载入更多", hidden: !page.hasMore))
        \(ServerWebUI.emptyState(
            icon: .people,
            title: "没有匹配的人物",
            message: "换个名字试试。",
            id: "people-empty",
            hidden: !page.items.isEmpty
        ))
        """
        return ServerWebDocument.render(
            title: "人物",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/people.css"],
            pageScripts: ["/assets/overlays.js", "/assets/people.js"],
            tint: .editorial
        )
    }

    static func detail(
        serverName: String,
        detail: ServerPersonDetail,
        csrfToken: String,
        showAdministration: Bool,
        categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras,
        back: ServerWebBackNavigation.Target = .init(label: "返回人物", href: "/people")
    ) -> String {
        let sidebar = ServerWebNavigation.render(active: .people, showAdministration: showAdministration, note: .playback, categories: categories, extras: sidebarExtras)
        let facts = [
            detail.department,
            detail.birthday.map { "出生 \($0)" },
            detail.deathday.map { "逝世 \($0)" },
            detail.placeOfBirth
        ].compactMap { $0 }.map { #"<li class="ui-chip">\#(ServerWebHTML.escape($0))</li>"# }.joined()
        let credits = detail.credits.items.map(creditCard).joined()
        let biography = detail.biography.flatMap { $0.isEmpty ? nil : $0 }

        // 人物页从前有自己的一套标题块（.person-hero + t-title-1），于是同一个产品里
        // 出现了第三种页面标题尺寸。这里改用共用页头，只把它唯一真正特殊的地方
        // ——没有图标、只有姓名首字母——通过 iconOverride 交进去。
        let content = """
        \(ServerWebPageHeader.render(
            icon: .people,
            eyebrow: "Person",
            title: detail.name,
            subtitle: "",
            countID: "credits-count",
            countUnit: "部作品",
            initialCount: detail.credits.totalItemCount,
            back: (label: back.label, href: back.href),
            titleID: "person-name",
            iconOverride: #"<span class="app-page-icon-monogram">\#(ServerWebHTML.escape(initials(detail.name)))</span>"#
        ))
        <section class="person-hero" aria-labelledby="person-name">
          <ul class="person-facts">\(facts.isEmpty ? #"<li class="ui-chip">资料库人物</li>"# : facts)</ul>
          \(biography.map { #"<p class="person-biography t-callout">\#(ServerWebHTML.escape($0))</p>"# } ?? #"<p class="person-biography t-callout t-tertiary">暂无人物简介。</p>"#)
        </section>
        <section class="ui-section" aria-labelledby="credits-title">
          <div class="ui-section-head">
            <div>
              <p class="app-eyebrow">Filmography</p>
              <h2 id="credits-title">作品</h2>
            </div>
          </div>
          <div id="credit-grid" class="ui-media-grid" aria-live="polite">\(credits)</div>
          \(loadMore(id: "credits-load-more", label: "载入更多作品", hidden: !detail.credits.hasMore))
          <p id="credits-status" class="t-footnote t-tertiary ui-state-line people-status" role="status" aria-live="polite"></p>
        </section>
        """
        return ServerWebDocument.render(
            title: detail.name,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/people.css"],
            pageScripts: ["/assets/overlays.js", "/assets/people.js"],
            bodyAttributes: ServerWebHTML.attribute("data-person-id", detail.id),
            tint: .editorial
        )
    }

    private static func loadMore(id: String, label: String, hidden: Bool) -> String {
        let hiddenAttribute = hidden ? " hidden" : ""
        return #"<div class="ui-load-more"\#(hiddenAttribute)>\#(ServerWebUI.button(label, variant: .secondary, icon: .chevronDown, id: id))</div>"#
    }

    private static func personCard(_ person: ServerPersonCard) -> String {
        guard let id = ServerWebURL.pathSegment(person.id) else { return "" }
        let department = ServerWebHTML.escape(person.department ?? "资料库人物")
        return """
        <a class="person-card" href="/people/\(id)" aria-label="查看 \(ServerWebHTML.escape(person.name)) 的作品">
          <span class="person-monogram person-monogram-sm" aria-hidden="true">\(ServerWebHTML.escape(initials(person.name)))</span>
          <span class="person-card-copy">
            <strong>\(ServerWebHTML.escape(person.name))</strong>
            <small>\(department)</small>
            <small class="t-numeric">\(person.mediaCount) 部可见作品</small>
          </span>
        </a>
        """
    }

    private static func creditCard(_ credit: ServerPersonCredit) -> String {
        guard let id = ServerWebURL.pathSegment(credit.id) else { return "" }
        let path = credit.isSeries ? "/series/\(id)/play" : "/item/\(id)#play"
        let role = credit.role ?? (credit.category == "cast" ? "演职人员" : credit.category)
        let sourceBadge = credit.remoteSourceKind.map { kind in
            #"<span class="ui-media-badge">\#(ServerWebHTML.escape(kind.displayName))</span>"#
        } ?? ""
        let art: String
        if credit.artworkAvailable {
            art = #"<img src="/api/v1/images/\#(id)/poster?size=320" alt="" loading="lazy" decoding="async" data-ready="true">"#
        } else {
            art = #"<span class="ui-poster-fallback">\#(ServerWebHTML.escape(credit.title))</span>"#
        }
        return """
        <a class="ui-media-card" href="\(path)" aria-label="查看 \(ServerWebHTML.escape(credit.title))" data-artwork-palette="\(ServerWebArtworkPalette.token(for: credit.id))">
          <span class="ui-poster">\(art)<span class="ui-poster-corner">\(sourceBadge)</span></span>
          <span class="ui-media-title">\(ServerWebHTML.escape(credit.title))</span>
          <span class="ui-media-meta">\(ServerWebHTML.escape(role))</span>
        </a>
        """
    }

    static let style = #"""
    .people-status { margin-bottom: var(--space-4); }
    .app-subtitle-count.error { color: var(--error); }

    .people-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(232px, 1fr));
      gap: var(--space-3);
    }
    .person-card {
      display: flex;
      align-items: center;
      gap: var(--space-3);
      padding: var(--space-3);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-md);
      color: inherit;
      background: var(--surface);
      transition:
        border-color var(--duration-base) var(--ease-out),
        box-shadow var(--duration-base) var(--ease-out),
        transform var(--duration-base) var(--ease-out);
    }
    .person-card:hover { border-color: var(--border-strong); box-shadow: var(--shadow-2); transform: translateY(-2px); }
    .person-card-copy { display: grid; min-width: 0; gap: 1px; }
    .person-card-copy strong {
      overflow: hidden;
      font-size: var(--type-callout-size);
      font-weight: var(--weight-semibold);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .person-card-copy small { color: var(--text-tertiary); font-size: var(--type-footnote-size); }

    /* Initials stand in for a portrait rather than fetching a third-party image,
       so they need to read as a deliberate avatar, not a missing one. */
    .person-monogram {
      display: grid;
      width: 46px;
      height: 46px;
      flex: none;
      place-items: center;
      border-radius: 50%;
      color: var(--accent-text);
      background: var(--accent-subtle);
      font-size: var(--type-headline-size);
      font-weight: var(--weight-bold);
      letter-spacing: -0.03em;
    }
    .person-monogram-sm { width: 46px; height: 46px; }

    /* The name, the eyebrow and the back link now live in the shared page
       header; what is left here is the facts row and the biography. */
    .person-hero { display: grid; gap: var(--space-3); padding-bottom: var(--space-8); }
    .person-facts { display: flex; flex-wrap: wrap; gap: var(--space-2); }
    .person-biography {
      max-width: var(--page-max-prose);
      color: var(--text-secondary);
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }

    @media (max-width: 719px) {
      .people-grid { grid-template-columns: minmax(0, 1fr); }
    }
    """#

    static let script = #"""
    (() => { 'use strict';
      const byID = id => document.getElementById(id);
      const create = (tag, className, value) => { const el = document.createElement(tag); if (className) el.className = className; if (value !== undefined) el.textContent = value; return el; };
      const initials = name => String(name || '?').trim().split(/\s+/).slice(0, 2).map(part => part[0] || '').join('').toUpperCase() || '?';
      const pageSize = 24;
      const safeText = value => String(value || '').slice(0, 512);
      const artworkPaletteToken = (value, prefix) => { let hash = 2166136261; const text = String(value || ''); for (let index = 0; index < text.length; index += 1) { hash ^= text.charCodeAt(index); hash = Math.imul(hash, 16777619) >>> 0; } return `${prefix}-${hash % 10}`; };
      const personCard = item => { const link = create('a', 'person-card'); link.href = `/people/${encodeURIComponent(String(item.id || ''))}`; link.setAttribute('aria-label', `查看 ${safeText(item.name)} 的作品`); link.append(create('span', 'person-monogram person-monogram-sm', initials(item.name))); const copy = create('span', 'person-card-copy'); copy.append(create('strong', '', safeText(item.name))); copy.append(create('small', '', safeText(item.department) || '资料库人物')); copy.append(create('small', 't-numeric', `${Math.max(0, Number(item.mediaCount) || 0)} 部可见作品`)); link.append(copy); return link; };
      const creditCard = item => { const link = create('a', 'ui-media-card'); const id = String(item.id || ''); link.href = item.isSeries === true ? `/series/${encodeURIComponent(id)}/play` : `/item/${encodeURIComponent(id)}#play`; link.dataset.artworkPalette = artworkPaletteToken(id, 'poster'); link.setAttribute('aria-label', `${item.isSeries === true ? '直接播放剧集' : '查看并播放'} ${safeText(item.title)}`); const poster = create('span', 'ui-poster'); if (item.artworkAvailable === true) { const image = document.createElement('img'); image.alt = ''; image.loading = 'lazy'; image.decoding = 'async'; image.dataset.ready = 'true'; image.src = `/api/v1/images/${encodeURIComponent(id)}/poster?size=320`; poster.append(image); } else { poster.append(create('span', 'ui-poster-fallback', safeText(item.title))); } const sourceLabel = ({emby:'Emby',jellyfin:'Jellyfin',plex:'Plex',mlink:'Mlink'})[item.remoteSourceKind]; if (sourceLabel) { const corner = create('span', 'ui-poster-corner'); corner.append(create('span', 'ui-media-badge', sourceLabel)); poster.append(corner); } link.append(poster); link.append(create('span', 'ui-media-title', safeText(item.title))); link.append(create('span', 'ui-media-meta', safeText(item.role) || (safeText(item.category) === 'cast' ? '演职人员' : safeText(item.category)))); return link; };
      async function fetchJSON(url, signal) { const response = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal }); if (response.status === 401) { window.location.assign('/login'); return null; } if (!response.ok) throw new Error(`服务暂时不可用（${response.status}）。`); return response.json(); }
      const personID = document.body.dataset.personId || '';
      if (personID) { let offset = document.querySelectorAll('#credit-grid .ui-media-card').length; let loading = false; const more = byID('credits-load-more'); const moreWrap = more?.parentElement; const grid = byID('credit-grid'); const status = byID('credits-status'); more?.addEventListener('click', async () => { if (loading) return; loading = true; more.disabled = true; more.dataset.busy = 'true'; status.classList.remove('error'); status.textContent = '正在载入更多作品…'; const controller = new AbortController(); const timeout = window.setTimeout(() => controller.abort(), 10000); try { const data = await fetchJSON(`/api/v1/people/${encodeURIComponent(personID)}/credits?offset=${offset}&limit=${pageSize}`, controller.signal); if (!data) return; const fragment = document.createDocumentFragment(); for (const item of (Array.isArray(data.items) ? data.items : [])) fragment.append(creditCard(item)); grid.append(fragment); offset += Array.isArray(data.items) ? data.items.length : 0; if (moreWrap) moreWrap.hidden = !data.hasMore; status.textContent = ''; } catch (error) { status.classList.add('error'); status.textContent = error?.name === 'AbortError' ? '请求超时，请重试。' : '作品载入失败，请重试。'; } finally { window.clearTimeout(timeout); loading = false; more.disabled = false; delete more.dataset.busy; } }); return; }
      const form = byID('people-search'); const query = byID('people-query'); const grid = byID('people-grid'); const more = byID('people-load-more'); const moreWrap = more?.parentElement; const status = byID('people-status'); const empty = byID('people-empty'); let offset = grid?.querySelectorAll('.person-card').length || 0; let currentQuery = ''; let loading = false;
      async function load(reset) { if (loading) return; loading = true; more.disabled = true; const controller = new AbortController(); const timeout = window.setTimeout(() => controller.abort(), 10000); status.classList.remove('error'); status.textContent = ' · 载入中…'; try { const params = new URLSearchParams({ offset: String(reset ? 0 : offset), limit: String(pageSize) }); if (currentQuery) params.set('q', currentQuery); const data = await fetchJSON(`/api/v1/people?${params.toString()}`, controller.signal); if (!data) return; const items = Array.isArray(data.items) ? data.items : []; const fragment = document.createDocumentFragment(); for (const item of items) fragment.append(personCard(item)); if (reset) { grid.replaceChildren(fragment); offset = items.length; } else { grid.append(fragment); offset += items.length; } if (moreWrap) moreWrap.hidden = !data.hasMore; empty.hidden = Number(data.totalItemCount) > 0; status.textContent = ` · ${Math.max(0, Number(data.totalItemCount) || 0)} 位`; } catch (error) { status.classList.add('error'); status.textContent = ' · 载入失败'; if (window.medialibToast) window.medialibToast(error?.name === 'AbortError' ? '请求超时，请重试。' : '人物载入失败，请重试。', { tone: 'error' }); } finally { window.clearTimeout(timeout); loading = false; more.disabled = false; } }
      function runSearch() { currentQuery = String(query.value || '').trim().slice(0, 128); void load(true); }
      form?.addEventListener('submit', event => { event.preventDefault(); runSearch(); });
      // The explicit 搜索 button is gone now that the field lives in the page
      // header, so typing has to be the search: debounced, and Enter still
      // submits the form for anyone who expects that.
      var searchTimer = 0;
      query?.addEventListener('input', () => { window.clearTimeout(searchTimer); searchTimer = window.setTimeout(runSearch, 260); });
      more?.addEventListener('click', () => void load(false));
    })();
    """#

    private static func initials(_ value: String) -> String {
        let parts = value.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let result = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return result.isEmpty ? "?" : String(result.prefix(2))
    }
}
