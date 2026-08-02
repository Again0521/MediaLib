import Foundation
import MediaLibServerProtocol

/// 经授权的手动合集网页。它不显示桌面端的编辑入口：服务器网页只读展示，
/// 所有卡片和分页都由同源 API 重新按当前账户授权过滤。
enum ServerWebCollectionsPage {
    static func directory(serverName: String, page: ServerCollectionsPage, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = []) -> String {
        let cards = page.items.map(collectionCard).joined(separator: "\n")
        let pageHeader = ServerWebPageHeader.render(icon: .collections, eyebrow: "合集", title: "合集", subtitle: "由本机资料库整理的手动合集；只展示当前账号可访问的媒体。")
        return document(
            title: "合集 · \(serverName)", csrfToken: csrfToken, bodyData: "",
            sidebar: ServerWebNavigation.render(active: .collections, showAdministration: showAdministration, note: .library, categories: categories),
            content: """
            \(pageHeader)<p id="collection-status" class="status" role="status" aria-live="polite">共 \(page.totalItemCount) 个合集</p>
            <section id="collection-grid" class="collection-grid" aria-live="polite">\(cards)</section>
            <button id="collections-load-more" class="load-more" type="button"\(page.hasMore ? "" : " hidden")>载入更多合集</button>
            <p id="collections-empty" class="empty"\(page.items.isEmpty ? "" : " hidden")>尚无可访问的手动合集。请在桌面端创建合集并加入已授权的媒体。</p>
            """
        )
    }

    static func detail(serverName: String, detail: ServerCollectionDetail, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = []) -> String {
        let cards = detail.items.items.map(mediaCard).joined(separator: "\n")
        let pageHeader = ServerWebPageHeader.render(icon: .collections, eyebrow: "合集", title: detail.name, subtitle: "共 \(detail.items.totalItemCount) 部当前账号可访问媒体。")
        return document(
            title: "\(detail.name) · \(serverName)", csrfToken: csrfToken,
            bodyData: " data-collection-id=\"\(escape(detail.id))\"",
            sidebar: ServerWebNavigation.render(active: .collections, showAdministration: showAdministration, note: .playback, categories: categories),
            content: """
            <a class="back" href="/collections">← 返回合集</a>
            \(pageHeader)<p id="collection-count" class="status" role="status" aria-live="polite">共 \(detail.items.totalItemCount) 部可访问媒体</p>
            <section id="collection-media-grid" class="media-grid" aria-live="polite">\(cards)</section>
            <button id="collection-items-load-more" class="load-more" type="button"\(detail.items.hasMore ? "" : " hidden")>载入更多媒体</button>
            <p id="collection-items-status" class="status" role="status" aria-live="polite"></p>
            """
        )
    }

    private static func document(title: String, csrfToken: String, bodyData: String, sidebar: String, content: String) -> String {
        """
        <!doctype html><html lang="zh-Hans"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><meta name="medialib-csrf-token" content="\(escape(csrfToken))"><title>\(escape(title))</title><link rel="stylesheet" href="/assets/collections.css"><link rel="stylesheet" href="/assets/app-shell.css?v=68"><script src="/assets/app-shell.js?v=68" defer></script><script src="/assets/collections.js" defer></script></head><body\(bodyData)><a class="skip" href="#main">跳到主要内容</a><div class="shell">\(sidebar)<main id="main" tabindex="-1">\(content)</main></div></body></html>
        """
    }

    private static func collectionCard(_ collection: ServerCollectionCard) -> String {
        guard let id = ServerWebURL.pathSegment(collection.id) else { return "" }
        return "<a class=\"collection-card\" href=\"/collections/\(id)\" aria-label=\"查看合集 \(escape(collection.name))\"><span class=\"collection-symbol\" aria-hidden=\"true\">▦</span><span><strong>\(escape(collection.name))</strong><small>\(collection.mediaCount) 部可访问媒体</small></span><span class=\"arrow\" aria-hidden=\"true\">→</span></a>"
    }

    private static func mediaCard(_ media: ServerCollectionMedia) -> String {
        guard let id = ServerWebURL.pathSegment(media.id) else { return "" }
        let path = media.isSeries ? "/series/\(id)" : "/item/\(id)"
        let artwork: String
        if media.artworkAvailable {
            artwork = "<img src=\"/api/v1/images/\(id)/poster\" alt=\"\" loading=\"lazy\" decoding=\"async\"><span class=\"mlink\">Mlink</span>"
        } else {
            artwork = "<span>\(escape(String(media.type.prefix(1)).uppercased()))</span><span class=\"mlink\">Mlink</span>"
        }
        return "<a class=\"media-card\" href=\"\(path)\" aria-label=\"查看 \(escape(media.title))\"><span class=\"art\">\(artwork)</span><span class=\"media-copy\"><strong>\(escape(media.title))</strong><small>\(escape(media.type))\(media.year.map { " · \($0)" } ?? "")</small></span></a>"
    }

    static let style = """
    :root{--ink:#172033;--muted:#607086;--line:#dce7f2;--canvas:#f4f8fc;--surface:rgba(255,255,255,.88);--primary:#236fb5;--strong:#174d82;--focus:#1570ef}*{box-sizing:border-box}html{min-width:320px}body{margin:0;overflow-x:hidden;color:var(--ink);background:var(--canvas);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-optical-sizing:auto}a,button{touch-action:manipulation}:focus-visible{outline:3px solid var(--focus);outline-offset:3px}.skip{position:fixed;z-index:1000;top:8px;left:8px;padding:10px 14px;border-radius:10px;color:#fff;background:var(--strong);transform:translateY(-160%)}.skip:focus{transform:none}main{width:100%;max-width:1440px;min-width:0;padding:clamp(22px,4vw,48px)}h1{margin:0;font-size:clamp(36px,6vw,68px);line-height:1.05;letter-spacing:-.045em;overflow-wrap:anywhere}.eyebrow{margin:0 0 6px;color:var(--primary);font-size:13px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.heading>p{max-width:65ch;margin:12px 0;color:var(--muted)}.collection-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:13px;margin-top:24px}.collection-card{display:grid;grid-template-columns:52px minmax(0,1fr) auto;min-height:108px;gap:13px;align-items:center;padding:16px;border:1px solid var(--line);border-radius:18px;color:inherit;background:var(--surface);box-shadow:0 10px 28px #2345670a;text-decoration:none;transition:transform .2s ease,border-color .2s ease,box-shadow .2s ease}.collection-card:hover,.media-card:hover{border-color:#9dc5e8;box-shadow:0 15px 30px #23456718;transform:translateY(-2px)}.collection-card:active,.media-card:active,button:active{transform:scale(.985)}.collection-symbol{display:grid;width:52px;height:52px;place-items:center;border:1px solid #b7d4ee;border-radius:15px;color:#0f4a7a;background:linear-gradient(145deg,#f9fcff,#dcefff);font-size:26px;font-weight:800}.collection-card strong,.media-copy strong{display:block;overflow-wrap:anywhere}.collection-card small,.media-copy small{display:block;margin-top:4px;color:var(--muted);font-size:13px}.arrow{color:var(--primary);font-size:20px}.load-more{display:block;min-width:150px;min-height:44px;margin:22px auto;padding:9px 16px;border:1px solid #98b8d7;border-radius:11px;color:#fff;background:var(--primary);cursor:pointer;font:inherit;font-weight:750;transition:transform .18s ease,background-color .18s ease}.load-more:hover{background:var(--strong)}.load-more:disabled{opacity:.5;cursor:not-allowed}.empty{margin-top:24px;padding:18px;border:1px dashed #b7cbe0;border-radius:14px;color:var(--muted);background:#fff}.back{display:inline-flex;min-height:44px;align-items:center;margin-bottom:14px;color:var(--strong);font-weight:700;text-decoration:none}.media-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:14px;margin-top:24px}.media-card{display:block;overflow:hidden;border:1px solid var(--line);border-radius:15px;color:inherit;background:var(--surface);text-decoration:none;transition:transform .2s ease,border-color .2s ease,box-shadow .2s ease}.art{position:relative;display:grid;overflow:hidden;aspect-ratio:2/3;place-items:center;color:#fff;background:linear-gradient(145deg,#174d82,#4aa2df);font-size:30px;font-weight:800}.art img{width:100%;height:100%;object-fit:cover}.mlink{position:absolute;top:8px;left:8px;padding:3px 6px;border-radius:6px;color:#fff;background:#123b68e8;font-size:10px;font-weight:800}.media-copy{display:block;padding:11px}.status{min-height:24px;margin:12px 0;color:var(--muted)}.status.error{color:#b42318}@media(max-width:700px){main{padding:24px 18px 40px}.media-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:430px){.collection-grid{grid-template-columns:1fr}.media-grid{gap:10px}}@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;transition-duration:.01ms!important}}
    """

    static let script = #"""
    (() => { 'use strict';
      const byID = id => document.getElementById(id);
      const create = (tag, className, value) => { const el = document.createElement(tag); if (className) el.className = className; if (value !== undefined) el.textContent = value; return el; };
      const safeText = value => String(value || '').slice(0, 512); const pageSize = 24;
      async function fetchJSON(url, signal) { const response = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal }); if (response.status === 401) { window.location.assign('/login'); return null; } if (!response.ok) throw new Error(`服务暂时不可用（${response.status}）。`); return response.json(); }
      const collectionCard = item => { const link = create('a', 'collection-card'); const id = String(item.id || ''); link.href = `/collections/${encodeURIComponent(id)}`; link.setAttribute('aria-label', `查看合集 ${safeText(item.name)}`); link.append(create('span', 'collection-symbol', '▦')); const copy = create('span'); copy.append(create('strong', '', safeText(item.name))); copy.append(create('small', '', `${Math.max(0, Number(item.mediaCount) || 0)} 部可访问媒体`)); link.append(copy, create('span', 'arrow', '→')); return link; };
      const mediaCard = item => { const link = create('a', 'media-card'); const id = String(item.id || ''); link.href = `${item.isSeries === true ? '/series/' : '/item/'}${encodeURIComponent(id)}`; link.setAttribute('aria-label', `查看 ${safeText(item.title)}`); const art = create('span', 'art', safeText(item.type).slice(0, 1).toUpperCase()); if (item.artworkAvailable === true) { const image = document.createElement('img'); image.alt = ''; image.loading = 'lazy'; image.decoding = 'async'; image.src = `/api/v1/images/${encodeURIComponent(id)}/poster`; art.replaceChildren(image); } art.append(create('span', 'mlink', 'Mlink')); const copy = create('span', 'media-copy'); copy.append(create('strong', '', safeText(item.title))); copy.append(create('small', '', `${safeText(item.type)}${Number.isInteger(item.year) ? ` · ${item.year}` : ''}`)); link.append(art, copy); return link; };
      const collectionID = document.body.dataset.collectionId || '';
      const grid = byID(collectionID ? 'collection-media-grid' : 'collection-grid'); const more = byID(collectionID ? 'collection-items-load-more' : 'collections-load-more'); const status = byID(collectionID ? 'collection-items-status' : 'collection-status'); const empty = byID('collections-empty'); let offset = grid?.children.length || 0; let loading = false;
      more?.addEventListener('click', async () => { if (loading) return; loading = true; more.disabled = true; const controller = new AbortController(); const timeout = window.setTimeout(() => controller.abort(), 10000); status.classList.remove('error'); status.textContent = collectionID ? '正在载入更多媒体…' : '正在载入更多合集…'; try { const url = collectionID ? `/api/v1/collections/${encodeURIComponent(collectionID)}/items?offset=${offset}&limit=${pageSize}` : `/api/v1/collections?offset=${offset}&limit=${pageSize}`; const data = await fetchJSON(url, controller.signal); if (!data) return; const items = Array.isArray(data.items) ? data.items : []; const fragment = document.createDocumentFragment(); for (const item of items) fragment.append(collectionID ? mediaCard(item) : collectionCard(item)); grid.append(fragment); offset += items.length; more.hidden = !data.hasMore; if (empty) empty.hidden = Number(data.totalItemCount) > 0; status.textContent = collectionID ? `共 ${Math.max(0, Number(data.totalItemCount) || 0)} 部可访问媒体` : `共 ${Math.max(0, Number(data.totalItemCount) || 0)} 个合集`; } catch (error) { status.classList.add('error'); status.textContent = error?.name === 'AbortError' ? '请求超时，请重试。' : '载入失败，请重试。'; } finally { window.clearTimeout(timeout); loading = false; more.disabled = false; } });
    })();
    """#

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
