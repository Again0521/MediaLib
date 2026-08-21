import Foundation
import MediaLibServerProtocol

/// 本地相册源的网页查看器。系统 PhotoKit 相册不会被服务端伪造为文件媒体；这里只
/// 输出已经由媒体扫描器索引、并再次通过当前 principal 授权的 `.photo` 条目。
enum ServerWebPhotosPage {
    /// 相册的三个分区，与客户端「相册」分组一致。
    enum Scope {
        case album, photos

        var title: String { self == .album ? "全部" : "照片" }
        var active: ServerWebNavigation.Active { self == .album ? .albums : .photos }
        var subtitle: String {
            self == .album
                ? "你的照片和录像。"
                : "你的照片。"
        }
    }

    static func gallery(serverName: String, page: ServerLibraryItemsPage, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras, scope: Scope = .photos) -> String {
        let cards = page.items.map(photoCard).joined()
        // 「录像」从前是一个永久禁用、且没有接任何监听的单选项——一个永远不会
        // 发生任何事的控件比缺席更糟。它现在是一条通往「其他视频」分类的真链接，
        // 且只在那个分类确实有内容时出现。
        let homeVideoCount = categories.first { $0.id == "homeVideo" }?.itemCount ?? 0
        // 三个胶囊与侧栏「相册」分组逐项对应：全部 / 照片 / 录像。
        let kindChips: [ServerWebUI.ControlChip] = [
            .init(label: "全部", href: "/albums", selected: scope == .album),
            .init(label: "照片", href: "/photos", selected: scope == .photos)
        ] + (homeVideoCount > 0 ? [ServerWebUI.ControlChip(label: "录像", href: "/category/homeVideo")] : [])
        let content = """
        \(ServerWebPageHeader.render(
            icon: .photos,
            eyebrow: "Gallery",
            title: scope.title,
            subtitle: scope.subtitle,
            countID: "photo-status",
            countUnit: "张",
            initialCount: page.totalItemCount,
            search: ServerWebUI.searchField(
                id: "photo-query",
                label: "搜索照片",
                placeholder: "搜索照片",
                action: "/search",
                hiddenFields: [(name: "type", value: "photo")]
            ),
            actions: ServerWebUI.button("刷新", variant: .secondary, icon: .refresh, id: "photo-refresh")
        ))
        \(ServerWebUI.controlBar(
            label: "相册内容类型",
            chipsLabel: "内容类型",
            chips: kindChips,
            extraClass: "gallery-toolbar"
        ))
        <div id="photo-grid" class="gallery-grid" aria-live="polite">\(cards)</div>
        <div class="ui-load-more"\(page.hasMore ? "" : " hidden")>\(ServerWebUI.button("载入更多照片", variant: .secondary, icon: .chevronDown, id: "photo-load-more"))</div>
        \(ServerWebUI.emptyState(
            icon: .image,
            title: "没有可访问的照片",
            message: "在 Mac 上添加照片，扫描完就会出现在这里。",
            id: "photo-empty",
            hidden: !page.items.isEmpty
        ))
        """
        return document(
            title: scope.title,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: ServerWebNavigation.render(active: scope.active, showAdministration: showAdministration, note: .library, categories: categories, extras: sidebarExtras),
            content: content
        )
    }

    /// 照片右侧那一栏。
    ///
    /// 它此前渲染成一个**内容完全为空**的 `<div class="photo-meta">`，而版面仍然
    /// 给它留着一条 ≥260px 的列——照片详情页的右边永远是一块白。要么有东西可说，
    /// 要么把这条列收掉；两者之间没有第三种选择。
    ///
    /// 这一页手上真正有的只有分辨率、年份、题材和简介，所以有几条给几条，一条
    /// 都没有时整栏不渲染（`.photo-detail` 随之退回单列）。
    private static func photoMeta(_ item: ServerMediaItemDetail) -> String {
        var rows: [(String, String)] = []
        if let resolution = item.resolution, !resolution.isEmpty { rows.append(("尺寸", resolution)) }
        if let year = item.year { rows.append(("年份", String(year))) }
        if !item.genres.isEmpty { rows.append(("标签", item.genres.prefix(4).joined(separator: " · "))) }
        let overview = (item.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rows.isEmpty || !overview.isEmpty else { return "" }

        let list = rows.map { label, value in
            #"<div class="photo-meta-row"><dt>\#(ServerWebHTML.escape(label))</dt><dd>\#(ServerWebHTML.escape(value))</dd></div>"#
        }.joined()
        let note = overview.isEmpty ? "" : #"<p class="t-body t-tertiary photo-meta-note">\#(ServerWebHTML.escape(overview))</p>"#
        return #"<aside class="photo-meta"><dl class="photo-meta-list">\#(list)</dl>\#(note)</aside>"#
    }

    static func detail(
        serverName: String, item: ServerMediaItemDetail, csrfToken: String,
        showAdministration: Bool, categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras,
        back: ServerWebBackNavigation.Target = .init(label: "返回照片", href: "/photos")
    ) -> String {
        let encodedID = ServerWebURL.pathSegment(item.id)
        let image: String
        if item.artworkAvailable, let encodedID {
            image = #"<img src="/api/v1/images/\#(encodedID)/poster" alt="\#(ServerWebHTML.escape(item.title))" loading="eager" decoding="async">"#
        } else {
            image = #"<div class="photo-placeholder" role="img" aria-label="暂无照片预览">\#(ServerWebIcon.image.html(size: .xl))</div>"#
        }
        // 照片详情从前用 .photo-detail + t-title-2 自建标题，于是同一个产品出现了
        // 第四种页面标题尺寸。标题、eyebrow 和返回链接都交回共用页头。
        let content = """
        \(ServerWebPageHeader.render(
            icon: .photos,
            eyebrow: "Photo",
            title: item.title,
            subtitle: item.year.map(String.init) ?? "",
            back: (label: back.label, href: back.href),
            titleID: "photo-title"
        ))
        <section class="photo-detail" aria-labelledby="photo-title">
          <div class="photo-stage">\(image)</div>
          \(photoMeta(item))
        </section>
        """
        return document(
            title: item.title,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: ServerWebNavigation.render(active: .photos, showAdministration: showAdministration, note: .library, categories: categories, extras: sidebarExtras),
            content: content
        )
    }

    private static func document(title: String, serverName: String, csrfToken: String, sidebar: String, content: String) -> String {
        ServerWebDocument.render(
            title: title,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/photos.css"],
            pageScripts: ["/assets/overlays.js", "/assets/photos.js"],
            bodyClass: "gallery-web-document",
            tint: .photo
        )
    }

    private static func photoCard(_ item: ServerLibraryItem) -> String {
        guard let id = ServerWebURL.pathSegment(item.id) else { return "" }
        let palette = ServerWebArtworkPalette.token(for: item.id)
        let art = item.artworkAvailable
            ? #"<img src="/api/v1/images/\#(id)/poster?size=320" alt="" loading="lazy" decoding="async" data-ready="true">"#
            : #"<span class="ui-poster-fallback">\#(ServerWebHTML.escape(item.title))</span>"#
        let sourceBadge = item.isRemoteSource ? #"<span class="ui-media-badge">Mlink</span>"# : ""
        return """
        <a class="photo-card" href="/photo/\(id)" aria-label="查看照片 \(ServerWebHTML.escape(item.title))" data-artwork-palette="\(palette)">
          <span class="ui-poster ui-poster-wide photo-art">\(art)<span class="ui-poster-corner">\(sourceBadge)</span></span>
          <span class="photo-caption"><strong>\(ServerWebHTML.escape(item.title))</strong></span>
        </a>
        """
    }

    static let style = #"""
    .gallery-toolbar { margin-bottom: var(--space-6); }

    /* A photo wall is not a poster grid: tiles vary in width so the eye reads a
       composition rather than a spreadsheet, while every tile keeps one aspect
       ratio so nothing reflows as images decode. */
    .gallery-grid {
      display: grid;
      grid-template-columns: repeat(12, minmax(0, 1fr));
      gap: var(--space-3);
    }
    .photo-card { position: relative; grid-column: span 3; display: block; min-width: 0; color: inherit; }
    .photo-card:nth-child(5n + 2) { grid-column: span 4; }
    .photo-card:nth-child(7n + 4) { grid-column: span 2; }
    .photo-art { transition: transform var(--duration-slow) var(--ease-out), box-shadow var(--duration-slow) var(--ease-out); }
    .photo-card:hover .photo-art { transform: translateY(-3px); box-shadow: var(--shadow-3); }
    .photo-caption {
      position: absolute;
      right: 0;
      bottom: 0;
      left: 0;
      padding: var(--space-7) var(--space-3) var(--space-2);
      background: var(--media-scrim);
      pointer-events: none;
    }
    .photo-caption strong {
      display: block;
      overflow: hidden;
      color: var(--text-on-media);
      font-size: var(--type-footnote-size);
      font-weight: var(--weight-semibold);
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    /* 只有真的有第二栏内容时才排两列。`auto-fit` 在这里不行——它按可用宽度决定
       列数，而这里的条件是"有没有东西可放"。没有 `.photo-meta` 时舞台独占整行。 */
    .photo-detail {
      display: grid;
      grid-template-columns: minmax(0, 1fr);
      align-items: start;
      gap: var(--space-8);
    }
    .photo-detail:has(.photo-meta) { grid-template-columns: minmax(0, 1.9fr) minmax(260px, 0.8fr); }
    @media (max-width: 899px) {
      .photo-detail:has(.photo-meta) { grid-template-columns: minmax(0, 1fr); }
    }
    .photo-meta-list { display: grid; gap: var(--space-3); }
    .photo-meta-row {
      display: grid;
      grid-template-columns: 64px minmax(0, 1fr);
      gap: var(--space-3);
      font-size: var(--type-callout-size);
    }
    .photo-meta-row dt { color: var(--text-tertiary); font-size: var(--type-subhead-size); }
    .photo-meta-row dd { margin: 0; overflow-wrap: anywhere; }
    .photo-meta-note { padding-top: var(--space-4); border-top: var(--hairline) solid var(--divider); margin-top: var(--space-4); }
    /* The stage stays dark in both themes: a photograph reads truest against a
       neutral dark ground, and a light frame tints the perceived image. */
    .photo-stage {
      display: grid;
      min-height: min(60vw, 600px);
      place-items: center;
      overflow: hidden;
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-lg);
      background: linear-gradient(150deg, #1b2330, #0b1018);
    }
    .photo-stage img { width: 100%; height: auto; max-height: min(76vh, 820px); object-fit: contain; }
    .photo-placeholder { display: grid; padding: var(--space-12); place-items: center; color: rgba(255, 255, 255, 0.5); }
    .photo-meta { display: grid; gap: var(--space-3); }

    @media (max-width: 1023px) {
      .photo-card,
      .photo-card:nth-child(5n + 2),
      .photo-card:nth-child(7n + 4) { grid-column: span 4; }
      .photo-detail { grid-template-columns: minmax(0, 1fr); }
    }
    @media (max-width: 719px) {
      .photo-card,
      .photo-card:nth-child(n) { grid-column: span 6; }
      .gallery-grid { gap: var(--space-2); }
      .photo-stage { min-height: 240px; }
    }
    """#

    static let script = #"""
    (() => { 'use strict';
      const grid = document.getElementById('photo-grid');
      const more = document.getElementById('photo-load-more');
      const moreWrap = more?.parentElement;
      const status = document.getElementById('photo-status');
      const empty = document.getElementById('photo-empty');
      const refresh = document.getElementById('photo-refresh');
      var offset = grid?.children.length || 0; var loading = false;
      const esc = value => String(value || '').slice(0, 512);
      const artworkPaletteToken = value => { let hash = 2166136261; const text = String(value || ''); for (let index = 0; index < text.length; index += 1) { hash ^= text.charCodeAt(index); hash = Math.imul(hash, 16777619) >>> 0; } return `poster-${hash % 10}`; };
      const card = item => {
        const id = String(item.id || '');
        const link = document.createElement('a');
        link.className = 'photo-card'; link.href = `/photo/${encodeURIComponent(id)}`;
        link.dataset.artworkPalette = artworkPaletteToken(id);
        link.setAttribute('aria-label', `查看照片 ${esc(item.title)}`);
        const art = document.createElement('span'); art.className = 'ui-poster ui-poster-wide photo-art';
        if (item.artworkAvailable === true) { const image = document.createElement('img'); image.alt = ''; image.loading = 'lazy'; image.decoding = 'async'; image.dataset.ready = 'true'; art.append(image); image.src = `/api/v1/images/${encodeURIComponent(id)}/poster?size=320`; }
        else { const fallback = document.createElement('span'); fallback.className = 'ui-poster-fallback'; fallback.textContent = esc(item.title); art.append(fallback); }
        const sourceLabel = ({emby:'Emby',jellyfin:'Jellyfin',plex:'Plex',mlink:'Mlink'})[item.remoteSourceKind]; if (sourceLabel) { const corner = document.createElement('span'); corner.className = 'ui-poster-corner'; const mark = document.createElement('span'); mark.className = 'ui-media-badge'; mark.textContent = sourceLabel; corner.append(mark); art.append(corner); }
        const caption = document.createElement('span'); caption.className = 'photo-caption';
        const title = document.createElement('strong'); title.textContent = esc(item.title); caption.append(title);
        link.append(art, caption); return link;
      };
      refresh?.addEventListener('click', () => location.reload());
      more?.addEventListener('click', async () => {
        if (loading) return; loading = true; more.disabled = true; more.dataset.busy = 'true';
        const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 10000);
        if (status) status.textContent = ' · 载入中…';
        try {
          const response = await fetch(`/api/v1/photos?offset=${offset}&limit=24`, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal: controller.signal });
          if (response.status === 401) { location.assign('/login'); return; }
          if (!response.ok) throw new Error();
          const data = await response.json();
          const items = Array.isArray(data.items) ? data.items : [];
          const fragment = document.createDocumentFragment();
          for (const item of items) fragment.append(card(item));
          grid.append(fragment); offset += items.length;
          if (moreWrap) moreWrap.hidden = !data.hasMore;
          empty.hidden = Number(data.totalItemCount) > 0;
          if (status) status.textContent = ` · ${Math.max(0, Number(data.totalItemCount) || 0)} 张`;
        } catch { if (status) status.textContent = ' · 载入失败'; if (window.medialibToast) window.medialibToast('照片载入失败，请重试。', { tone: 'error' }); }
        finally { clearTimeout(timer); loading = false; more.disabled = false; delete more.dataset.busy; }
      });
    })();
    """#
}
