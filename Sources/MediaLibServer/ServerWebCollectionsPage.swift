import Foundation
import MediaLibServerProtocol

/// 经授权的手动合集网页。它不显示桌面端的编辑入口：服务器网页只读展示，
/// 所有卡片和分页都由同源 API 重新按当前账户授权过滤。
enum ServerWebCollectionsPage {
    static func directory(serverName: String, page: ServerCollectionsPage, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras) -> String {
        let cards = page.items.map(collectionCard).joined()
        let content = """
        \(ServerWebPageHeader.render(
            icon: .collections,
            eyebrow: "Collections",
            title: "合集",
            subtitle: "你在 Mac 上整理好的合集。",
            countID: "collection-status",
            countUnit: "个",
            initialCount: page.totalItemCount
        ))
        <section id="collection-grid" class="collection-grid" aria-live="polite">\(cards)</section>
        \(loadMore(id: "collections-load-more", label: "载入更多合集", hidden: !page.hasMore))
        \(ServerWebUI.emptyState(
            icon: .collections,
            title: "尚无可访问的合集",
            message: "在 Mac 上建一个合集，把喜欢的内容放进去，这里就能看到。",
            id: "collections-empty",
            hidden: !page.items.isEmpty
        ))
        """
        return document(
            title: "合集",
            serverName: serverName,
            csrfToken: csrfToken,
            bodyAttributes: "",
            sidebar: ServerWebNavigation.render(active: .collections, showAdministration: showAdministration, note: .library, categories: categories, extras: sidebarExtras),
            content: content
        )
    }

    static func detail(
        serverName: String, detail: ServerCollectionDetail, csrfToken: String,
        showAdministration: Bool, categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras,
        back: ServerWebBackNavigation.Target = Kind.manual.defaultBack
    ) -> String {
        page(
            id: detail.id, name: detail.name,
            cards: detail.items.items.map(mediaCard).joined(),
            totalItemCount: detail.items.totalItemCount, hasMore: detail.items.hasMore, kind: .manual,
            serverName: serverName, csrfToken: csrfToken,
            showAdministration: showAdministration, categories: categories,
            sidebarExtras: sidebarExtras, back: back
        )
    }

    /// 智能集合详情。与手动合集同一套版面——两者对读者是同一种东西（一个有名字的
    /// 容器，点进去是一批媒体），差别只在成员从哪来，那是服务端的事。
    static func smartDetail(
        serverName: String,
        detail: ServerSmartCollectionDetail,
        csrfToken: String,
        showAdministration: Bool,
        categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras,
        back: ServerWebBackNavigation.Target = Kind.smart.defaultBack
    ) -> String {
        page(
            id: detail.id, name: detail.name,
            cards: detail.items.items.map(libraryMediaCard).joined(),
            totalItemCount: detail.items.totalItemCount, hasMore: detail.items.hasMore, kind: .smart,
            serverName: serverName, csrfToken: csrfToken,
            showAdministration: showAdministration, categories: categories,
            sidebarExtras: sidebarExtras, back: back
        )
    }

    fileprivate enum Kind {
        case manual, smart

        var eyebrow: String { self == .smart ? "Smart Collection" : "Collection" }
        /// 只在读者的来处无从判断时才用得上——真正的返回目标由 `Referer` 决定。
        var defaultBack: ServerWebBackNavigation.Target {
            self == .smart
                ? .init(label: "返回首页", href: "/")
                : .init(label: "返回合集", href: "/collections")
        }
        var breadcrumbRoot: String { self == .smart ? "智能集合" : "合集" }
        /// 智能集合的成员是规则算出来的，没有"下一页"可以按 id 续取；一次给足。
        var supportsPaging: Bool { self == .manual }
    }

    private static func page(
        id: String,
        name: String,
        cards: String,
        totalItemCount: Int,
        hasMore: Bool,
        kind: Kind,
        serverName: String,
        csrfToken: String,
        showAdministration: Bool,
        categories: [ServerLibraryCategory],
        sidebarExtras: ServerWebSidebarExtras,
        back: ServerWebBackNavigation.Target
    ) -> String {
        let content = """
        \(ServerWebPageHeader.render(
            icon: .collections,
            eyebrow: kind.eyebrow,
            title: name,
            subtitle: "这个合集里的内容。",
            countID: "collection-count",
            countUnit: "部",
            initialCount: totalItemCount,
            breadcrumb: [(kind.breadcrumbRoot, kind == .manual ? "/collections" : nil), (name, nil)],
            back: (back.label, back.href)
        ))
        <section id="collection-media-grid" class="ui-media-grid" aria-live="polite">\(cards)</section>
        \(loadMore(id: "collection-items-load-more", label: "载入更多媒体", hidden: !(kind.supportsPaging && hasMore)))
        <p id="collection-items-status" class="ui-state-line collection-status t-footnote t-tertiary" role="status" aria-live="polite"></p>
        """
        return document(
            title: name,
            serverName: serverName,
            csrfToken: csrfToken,
            bodyAttributes: kind == .manual ? ServerWebHTML.attribute("data-collection-id", id) : "",
            sidebar: ServerWebNavigation.render(
                active: .collections, showAdministration: showAdministration, note: .playback,
                categories: categories, extras: sidebarExtras
            ),
            content: content
        )
    }

    private static func document(title: String, serverName: String, csrfToken: String, bodyAttributes: String, sidebar: String, content: String) -> String {
        ServerWebDocument.render(
            title: title,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/collections.css"],
            pageScripts: ["/assets/overlays.js", "/assets/collections.js"],
            bodyAttributes: bodyAttributes,
            tint: .editorial
        )
    }

    private static func loadMore(id: String, label: String, hidden: Bool) -> String {
        let hiddenAttribute = hidden ? " hidden" : ""
        return #"<div class="ui-load-more"\#(hiddenAttribute)>\#(ServerWebUI.button(label, variant: .secondary, icon: .chevronDown, id: id))</div>"#
    }

    private static func collectionCard(_ collection: ServerCollectionCard) -> String {
        guard let id = ServerWebURL.pathSegment(collection.id) else { return "" }
        return """
        <a class="collection-card" href="/collections/\(id)" aria-label="查看合集 \(ServerWebHTML.escape(collection.name))">
          <span class="collection-symbol" aria-hidden="true">\(ServerWebIcon.collections.html(size: .md))</span>
          <span class="collection-copy">
            <strong>\(ServerWebHTML.escape(collection.name))</strong>
            <small class="t-numeric">\(collection.mediaCount) 部可访问媒体</small>
          </span>
          \(ServerWebIcon.chevronRight.html(size: .sm, extraClass: "collection-arrow"))
        </a>
        """
    }

    private static func mediaCard(_ media: ServerCollectionMedia) -> String {
        guard let id = ServerWebURL.pathSegment(media.id) else { return "" }
        let path = media.isSeries ? "/series/\(id)/play" : "/item/\(id)#play"
        let sourceBadge = media.isRemoteSource ? #"<span class="ui-media-badge">Mlink</span>"# : ""
        let artwork = media.artworkAvailable
            ? #"<img src="/api/v1/images/\#(id)/poster?size=320" alt="" loading="lazy" decoding="async" data-ready="true">"#
            : #"<span class="ui-poster-fallback">\#(ServerWebHTML.escape(media.title))</span>"#
        return """
        <a class="ui-media-card" href="\(path)" aria-label="查看 \(ServerWebHTML.escape(media.title))" data-artwork-palette="\(ServerWebArtworkPalette.token(for: media.id))">
          <span class="ui-poster">\(artwork)<span class="ui-poster-corner">\(sourceBadge)</span></span>
          <span class="ui-media-title">\(ServerWebHTML.escape(media.title))</span>
        </a>
        """
    }

    /// 智能集合的成员是普通的资料库条目（`ServerLibraryItem`），手动合集用的是
    /// 它自己的 `ServerCollectionMedia`。两者字段一致，卡片长得一样，所以这里只
    /// 是把前者转成同一张卡，而不是让页面长出第二套卡片样式。
    private static func libraryMediaCard(_ item: ServerLibraryItem) -> String {
        mediaCard(ServerCollectionMedia(
            id: item.id,
            type: item.type,
            title: item.title,
            year: item.year,
            artworkAvailable: item.artworkAvailable,
            isSeries: item.isSeries,
            isRemoteSource: item.isRemoteSource
        ))
    }

    static let style = #"""
    .collection-status { margin-bottom: var(--space-4); }

    .collection-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(256px, 1fr));
      gap: var(--space-3);
    }
    .collection-card {
      display: grid;
      grid-template-columns: 44px minmax(0, 1fr) auto;
      align-items: center;
      gap: var(--space-3);
      padding: var(--space-4);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-md);
      color: inherit;
      background: var(--surface);
      transition:
        border-color var(--duration-base) var(--ease-out),
        box-shadow var(--duration-base) var(--ease-out),
        transform var(--duration-base) var(--ease-out);
    }
    .collection-card:hover { border-color: var(--border-strong); box-shadow: var(--shadow-2); transform: translateY(-2px); }
    .collection-symbol {
      display: grid;
      width: 44px;
      height: 44px;
      place-items: center;
      border-radius: var(--radius-sm);
      color: var(--accent-text);
      background: var(--accent-subtle);
    }
    .collection-copy { display: grid; min-width: 0; gap: 2px; }
    .collection-copy strong {
      overflow: hidden;
      font-size: var(--type-callout-size);
      font-weight: var(--weight-semibold);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .collection-copy small { color: var(--text-tertiary); font-size: var(--type-footnote-size); }
    /* The chevron leans toward the destination on hover — a small directional
       hint that the row goes somewhere. */
    .collection-arrow { color: var(--text-tertiary); transition: transform var(--duration-base) var(--ease-out); }
    .collection-card:hover .collection-arrow { color: var(--accent); transform: translateX(3px); }


    @media (max-width: 719px) {
      .collection-grid { grid-template-columns: minmax(0, 1fr); }
    }
    """#

    static let script = #"""
    (() => { 'use strict';
      const byID = id => document.getElementById(id);
      const create = (tag, className, value) => { const el = document.createElement(tag); if (className) el.className = className; if (value !== undefined) el.textContent = value; return el; };
      const safeText = value => String(value || '').slice(0, 512); const pageSize = 24;
      // 取色由 Swift 插值下来，桶数与哈希与服务端同源。
      \#(ServerWebArtworkPalette.scriptHelper)
      const artworkPaletteToken = (value, prefix) => medialibArtworkPalette(value, prefix);
      // 图标由 Swift 从 `ServerWebIcon` 插值下来。手写的 `COLLECTION_GLYPH` 是把
      // 圆角矩形改成了直角矩形的合集图标——同一页上服务端渲染的那批卡片带圆角，
      // 脚本补上来的这批不带。
      \#(ServerWebIcon.scriptHelper(for: [.collections, .chevronRight]))
      const glyph = (name, className) => medialibIcon(name, className);
      async function fetchJSON(url, signal) { const response = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal }); if (response.status === 401) { window.location.assign('/login'); return null; } if (!response.ok) throw new Error(`服务暂时不可用（${response.status}）。`); return response.json(); }
      const collectionCard = item => { const link = create('a', 'collection-card'); const id = String(item.id || ''); link.href = `/collections/${encodeURIComponent(id)}`; link.setAttribute('aria-label', `查看合集 ${safeText(item.name)}`); const symbol = create('span', 'collection-symbol'); symbol.append(glyph('collections', 'icon icon-md')); const copy = create('span', 'collection-copy'); copy.append(create('strong', '', safeText(item.name))); copy.append(create('small', 't-numeric', `${Math.max(0, Number(item.mediaCount) || 0)} 部可访问媒体`)); link.append(symbol, copy, glyph('chevronRight', 'icon icon-sm collection-arrow')); return link; };
      const mediaCard = item => { const link = create('a', 'ui-media-card'); const id = String(item.id || ''); link.href = item.isSeries === true ? `/series/${encodeURIComponent(id)}/play` : `/item/${encodeURIComponent(id)}#play`; link.dataset.artworkPalette = artworkPaletteToken(id, 'poster'); link.setAttribute('aria-label', `${item.isSeries === true ? '直接播放剧集' : '查看并播放'} ${safeText(item.title)}`); const poster = create('span', 'ui-poster'); if (item.artworkAvailable === true) { const image = document.createElement('img'); image.alt = ''; image.loading = 'lazy'; image.decoding = 'async'; image.dataset.ready = 'true'; image.src = `/api/v1/images/${encodeURIComponent(id)}/poster?size=320`; poster.append(image); } else { poster.append(create('span', 'ui-poster-fallback', safeText(item.title))); } const sourceLabel = ({emby:'Emby',jellyfin:'Jellyfin',plex:'Plex',mlink:'Mlink'})[item.remoteSourceKind]; if (sourceLabel) { const corner = create('span', 'ui-poster-corner'); corner.append(create('span', 'ui-media-badge', sourceLabel)); poster.append(corner); } link.append(poster); link.append(create('span', 'ui-media-title', safeText(item.title))); return link; };
      const collectionID = document.body.dataset.collectionId || '';
      const grid = byID(collectionID ? 'collection-media-grid' : 'collection-grid'); const more = byID(collectionID ? 'collection-items-load-more' : 'collections-load-more'); const moreWrap = more?.parentElement; const status = byID(collectionID ? 'collection-items-status' : 'collection-status'); const empty = byID('collections-empty'); let offset = grid?.children.length || 0; let loading = false;
      more?.addEventListener('click', async () => { if (loading) return; loading = true; more.disabled = true; more.dataset.busy = 'true'; const controller = new AbortController(); const timeout = window.setTimeout(() => controller.abort(), 10000); status.classList.remove('error'); status.textContent = collectionID ? '正在载入更多媒体…' : ' · 载入中…'; try { const url = collectionID ? `/api/v1/collections/${encodeURIComponent(collectionID)}/items?offset=${offset}&limit=${pageSize}` : `/api/v1/collections?offset=${offset}&limit=${pageSize}`; const data = await fetchJSON(url, controller.signal); if (!data) return; const items = Array.isArray(data.items) ? data.items : []; const fragment = document.createDocumentFragment(); for (const item of items) fragment.append(collectionID ? mediaCard(item) : collectionCard(item)); grid.append(fragment); offset += items.length; if (moreWrap) moreWrap.hidden = !data.hasMore; if (empty) empty.hidden = Number(data.totalItemCount) > 0; const total = Math.max(0, Number(data.totalItemCount) || 0); status.textContent = collectionID ? `共 ${total} 部可访问媒体` : ` · ${total} 个`; if (collectionID) { const headerCount = byID('collection-count'); if (headerCount) headerCount.textContent = ` · ${total} 部`; } } catch (error) { status.classList.add('error'); status.textContent = collectionID ? (error?.name === 'AbortError' ? '请求超时，请重试。' : '载入失败，请重试。') : ' · 载入失败'; if (window.medialibToast) window.medialibToast('载入失败，请重试。', { tone: 'error' }); } finally { window.clearTimeout(timeout); loading = false; more.disabled = false; delete more.dataset.busy; } });
    })();
    """#
}
