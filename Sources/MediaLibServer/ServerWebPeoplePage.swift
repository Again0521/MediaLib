import Foundation
import MediaLibServerProtocol

/// 人物目录与人物作品页。肖像不直接引用第三方 profile URL，而使用稳定的文字首字母
/// 占位，从而既保留可扫读的视觉节奏，也不把浏览者 IP 暴露给元数据提供方。
enum ServerWebPeoplePage {
    static func directory(
        serverName: String,
        page: ServerPeoplePage,
        csrfToken: String,
        showAdministration: Bool
    ) -> String {
        let cards = page.items.map(personCard).joined(separator: "\n")
        let sidebar = ServerWebNavigation.render(active: .people, showAdministration: showAdministration, note: .library)
        return document(
            title: "人物 · \(serverName)", csrfToken: csrfToken, bodyData: "",
            sidebar: sidebar,
            content: """
            <section class="people-heading" aria-labelledby="page-title"><p class="eyebrow">People</p><h1 id="page-title">人物</h1><p>只显示当前账号可访问作品中的演职人员。</p><form id="people-search" role="search"><label for="people-query">搜索人物</label><input id="people-query" name="q" type="search" maxlength="128" autocomplete="off" placeholder="姓名、演员、导演"><button type="submit">搜索</button></form><p id="people-status" role="status" aria-live="polite">共 \(page.totalItemCount) 位人物</p></section>
            <section id="people-grid" class="people-grid" aria-live="polite">\(cards)</section>
            <button id="people-load-more" class="load-more" type="button"\(page.hasMore ? "" : " hidden")>载入更多</button>
            <p id="people-empty" class="empty"\(page.items.isEmpty ? "" : " hidden")>没有匹配的人物。请调整搜索词，或确认媒体库已完成元数据扫描。</p>
            """
        )
    }

    static func detail(
        serverName: String,
        detail: ServerPersonDetail,
        csrfToken: String,
        showAdministration: Bool
    ) -> String {
        let sidebar = ServerWebNavigation.render(active: .people, showAdministration: showAdministration, note: .playback)
        let facts = [detail.department, detail.birthday.map { "出生 \($0)" }, detail.deathday.map { "逝世 \($0)" }, detail.placeOfBirth].compactMap { $0 }.map { "<li>\(escape($0))</li>" }.joined()
        let credits = detail.credits.items.map(creditCard).joined(separator: "\n")
        return document(
            title: "\(detail.name) · \(serverName)", csrfToken: csrfToken, bodyData: " data-person-id=\"\(escape(detail.id))\"",
            sidebar: sidebar,
            content: """
            <a class="back" href="/people">← 返回人物</a>
            <section class="person-hero" aria-labelledby="person-name"><div class="monogram large" role="img" aria-label="\(escape(detail.name)) 的姓名首字母头像">\(escape(initials(detail.name)))</div><div><p class="eyebrow">Person</p><h1 id="person-name">\(escape(detail.name))</h1><ul class="facts">\(facts.isEmpty ? "<li>资料库人物</li>" : facts)</ul><p class="biography">\(escape(detail.biography ?? "暂无人物简介。"))</p></div></section>
            <section class="credits" aria-labelledby="credits-title"><div class="section-heading"><div><p class="eyebrow">Filmography</p><h2 id="credits-title">作品</h2></div><span id="credits-count">共 \(detail.credits.totalItemCount) 部</span></div><div id="credit-grid" class="credit-grid" aria-live="polite">\(credits)</div><button id="credits-load-more" class="load-more" type="button"\(detail.credits.hasMore ? "" : " hidden")>载入更多作品</button><p id="credits-status" role="status" aria-live="polite"></p></section>
            """
        )
    }

    private static func document(title: String, csrfToken: String, bodyData: String, sidebar: String, content: String) -> String {
        """
        <!doctype html><html lang="zh-Hans"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><meta name="medialib-csrf-token" content="\(escape(csrfToken))"><title>\(escape(title))</title><link rel="stylesheet" href="/assets/people.css"><link rel="stylesheet" href="/assets/app-shell.css"><script src="/assets/people.js" defer></script></head><body\(bodyData)><a class="skip" href="#main">跳到主要内容</a><div class="shell">\(sidebar)<main id="main" tabindex="-1">\(content)</main></div></body></html>
        """
    }

    private static func personCard(_ person: ServerPersonCard) -> String {
        guard let id = ServerWebURL.pathSegment(person.id) else { return "" }
        let department = person.department.map { "<p>\(escape($0))</p>" } ?? "<p>资料库人物</p>"
        return "<a class=\"person-card\" href=\"/people/\(id)\" aria-label=\"查看 \(escape(person.name)) 的作品\"><span class=\"monogram\" aria-hidden=\"true\">\(escape(initials(person.name)))</span><span><strong>\(escape(person.name))</strong>\(department)<small>\(person.mediaCount) 部可见作品</small></span></a>"
    }

    private static func creditCard(_ credit: ServerPersonCredit) -> String {
        guard let id = ServerWebURL.pathSegment(credit.id) else { return "" }
        let path = credit.isSeries ? "/series/\(id)" : "/item/\(id)"
        let role = credit.role.map { "<p>\(escape($0))</p>" } ?? "<p>\(escape(credit.category == "cast" ? "演职人员" : credit.category))</p>"
        let art: String
        if credit.artworkAvailable {
            art = "<img src=\"/api/v1/images/\(id)/poster\" alt=\"\" loading=\"lazy\" decoding=\"async\"><span class=\"mlink\">Mlink</span>"
        } else {
            art = "<span>\(escape(String(credit.type.prefix(1)).uppercased()))</span><span class=\"mlink\">Mlink</span>"
        }
        return "<a class=\"credit-card\" href=\"\(path)\" aria-label=\"查看 \(escape(credit.title))\"><span class=\"credit-art\">\(art)</span><span class=\"credit-copy\"><strong>\(escape(credit.title))</strong><small>\(escape(credit.type))\(credit.year.map { " · \($0)" } ?? "")</small>\(role)</span></a>"
    }

    static let style = """
    :root { --ink:#172033; --muted:#607086; --line:#dce7f2; --canvas:#f4f8fc; --surface:rgba(255,255,255,.88); --primary:#236fb5; --strong:#174d82; --focus:#1570ef; }
    *{box-sizing:border-box} html{min-width:320px} body{margin:0;overflow-x:hidden;color:var(--ink);background:var(--canvas);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-optical-sizing:auto} a,button,input{touch-action:manipulation}:focus-visible{outline:3px solid var(--focus);outline-offset:3px}.skip{position:fixed;z-index:1000;top:8px;left:8px;padding:10px 14px;border-radius:10px;color:#fff;background:var(--strong);transform:translateY(-160%)}.skip:focus{transform:none}main{width:100%;max-width:1440px;min-width:0;padding:clamp(22px,4vw,48px)}h1{margin:0;font-size:clamp(36px,6vw,68px);line-height:1.05;letter-spacing:-.045em;overflow-wrap:anywhere}h2{margin:0;font-size:28px;letter-spacing:-.025em}.eyebrow{margin:0 0 6px;color:var(--primary);font-size:13px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.people-heading>p{max-width:60ch;margin:12px 0;color:var(--muted)}form{display:flex;gap:10px;max-width:680px;margin-top:24px}label{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}input{min-width:0;min-height:46px;flex:1;padding:10px 13px;border:1px solid #b5c9df;border-radius:12px;color:var(--ink);background:#fff;font:inherit}button,.load-more{min-height:44px;padding:9px 16px;border:1px solid #98b8d7;border-radius:11px;color:#fff;background:var(--primary);cursor:pointer;font:inherit;font-weight:750;transition:transform .18s ease,background-color .18s ease}button:hover,.load-more:hover{background:var(--strong)}button:active,.person-card:active,.credit-card:active{transform:scale(.985)}button:disabled{opacity:.5;cursor:not-allowed}.people-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(215px,1fr));gap:12px;margin-top:20px}.person-card{display:flex;min-height:104px;gap:13px;align-items:center;padding:14px;border:1px solid var(--line);border-radius:17px;color:inherit;background:var(--surface);box-shadow:0 10px 28px #2345670a;text-decoration:none;transition:transform .2s ease,border-color .2s ease,box-shadow .2s ease}.person-card:hover{border-color:#9dc5e8;box-shadow:0 15px 30px #23456716;transform:translateY(-2px)}.monogram{display:grid;width:50px;height:50px;flex:none;place-items:center;border:1px solid #b7d4ee;border-radius:50%;color:#0f4a7a;background:linear-gradient(145deg,#f9fcff,#dcefff);font-weight:800;letter-spacing:-.04em}.person-card strong,.credit-copy strong{display:block;overflow-wrap:anywhere}.person-card p,.person-card small,.credit-copy p,.credit-copy small{display:block;margin:3px 0 0;color:var(--muted);font-size:13px}.person-card small{font-variant-numeric:tabular-nums}.load-more{display:block;min-width:140px;margin:22px auto}.empty{margin-top:24px;padding:18px;border:1px dashed #b7cbe0;border-radius:14px;color:var(--muted);background:#fff}.back{display:inline-flex;min-height:44px;align-items:center;margin-bottom:14px;color:var(--strong);font-weight:700;text-decoration:none}.person-hero{display:grid;grid-template-columns:150px minmax(0,1fr);gap:28px;align-items:start}.monogram.large{width:150px;height:150px;font-size:44px}.facts{display:flex;flex-wrap:wrap;gap:8px;margin:18px 0 0;padding:0;list-style:none}.facts li{padding:6px 10px;border:1px solid #c8d9ea;border-radius:999px;color:#43546a;background:#fff;font-size:13px}.biography{max-width:75ch;margin:20px 0 0;color:#3c4d63;white-space:pre-wrap;overflow-wrap:anywhere}.credits{margin-top:38px}.section-heading{display:flex;align-items:end;justify-content:space-between;gap:16px;margin-bottom:15px}.section-heading>span{color:var(--muted);font-variant-numeric:tabular-nums}.credit-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:14px}.credit-card{display:block;overflow:hidden;border:1px solid var(--line);border-radius:15px;color:inherit;background:var(--surface);text-decoration:none;transition:transform .2s ease,border-color .2s ease,box-shadow .2s ease}.credit-card:hover{border-color:#9dc5e8;box-shadow:0 15px 30px #23456718;transform:translateY(-2px)}.credit-art{position:relative;display:grid;overflow:hidden;aspect-ratio:2/3;place-items:center;color:#fff;background:linear-gradient(145deg,#174d82,#4aa2df);font-size:30px;font-weight:800}.credit-art img{width:100%;height:100%;object-fit:cover}.mlink{position:absolute;top:8px;left:8px;padding:3px 6px;border-radius:6px;color:#fff;background:#123b68e8;font-size:10px;font-weight:800}.credit-copy{display:block;padding:11px}.credit-copy p{min-height:20px}.credits>#credits-status{min-height:24px;margin:12px 0;color:var(--muted)}.credits>#credits-status.error{color:#b42318}@media(max-width:700px){main{padding:24px 18px 40px}.person-hero{grid-template-columns:96px minmax(0,1fr);gap:18px}.monogram.large{width:96px;height:96px;font-size:30px}.biography,.facts{grid-column:1/-1}.credit-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:430px){form{flex-wrap:wrap}form button{flex:1 1 100%}.people-grid{grid-template-columns:1fr}.credit-grid{gap:10px}}@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;transition-duration:.01ms!important}}
    """

    static let script = #"""
    (() => { 'use strict';
      const byID = id => document.getElementById(id);
      const create = (tag, className, value) => { const el = document.createElement(tag); if (className) el.className = className; if (value !== undefined) el.textContent = value; return el; };
      const initials = name => String(name || '?').trim().split(/\s+/).slice(0, 2).map(part => part[0] || '').join('').toUpperCase() || '?';
      const pageSize = 24;
      const safeText = value => String(value || '').slice(0, 512);
      const personCard = item => { const link = create('a', 'person-card'); link.href = `/people/${encodeURIComponent(String(item.id || ''))}`; link.setAttribute('aria-label', `查看 ${safeText(item.name)} 的作品`); link.append(create('span', 'monogram', initials(item.name))); const copy = create('span'); copy.append(create('strong', '', safeText(item.name))); copy.append(create('p', '', safeText(item.department) || '资料库人物')); copy.append(create('small', '', `${Math.max(0, Number(item.mediaCount) || 0)} 部可见作品`)); link.append(copy); return link; };
      const creditCard = item => { const link = create('a', 'credit-card'); const id = String(item.id || ''); link.href = `${item.isSeries === true ? '/series/' : '/item/'}${encodeURIComponent(id)}`; link.setAttribute('aria-label', `查看 ${safeText(item.title)}`); const art = create('span', 'credit-art', String(item.type || '?').slice(0, 1).toUpperCase()); if (item.artworkAvailable === true) { const image = document.createElement('img'); image.alt = ''; image.loading = 'lazy'; image.decoding = 'async'; image.src = `/api/v1/images/${encodeURIComponent(id)}/poster`; art.replaceChildren(image); } art.append(create('span', 'mlink', 'Mlink')); const copy = create('span', 'credit-copy'); copy.append(create('strong', '', safeText(item.title))); copy.append(create('small', '', `${safeText(item.type)}${Number.isInteger(item.year) ? ` · ${item.year}` : ''}`)); copy.append(create('p', '', safeText(item.role) || (safeText(item.category) === 'cast' ? '演职人员' : safeText(item.category)))); link.append(art, copy); return link; };
      async function fetchJSON(url, signal) { const response = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal }); if (response.status === 401) { window.location.assign('/login'); return null; } if (!response.ok) throw new Error(`服务暂时不可用（${response.status}）。`); return response.json(); }
      const personID = document.body.dataset.personId || '';
      if (personID) { let offset = document.querySelectorAll('.credit-card').length; let loading = false; const more = byID('credits-load-more'); const grid = byID('credit-grid'); const status = byID('credits-status'); more?.addEventListener('click', async () => { if (loading) return; loading = true; more.disabled = true; status.classList.remove('error'); status.textContent = '正在载入更多作品…'; const controller = new AbortController(); const timeout = window.setTimeout(() => controller.abort(), 10000); try { const data = await fetchJSON(`/api/v1/people/${encodeURIComponent(personID)}/credits?offset=${offset}&limit=${pageSize}`, controller.signal); if (!data) return; const fragment = document.createDocumentFragment(); for (const item of (Array.isArray(data.items) ? data.items : [])) fragment.append(creditCard(item)); grid.append(fragment); offset += Array.isArray(data.items) ? data.items.length : 0; more.hidden = !data.hasMore; status.textContent = ''; } catch (error) { status.classList.add('error'); status.textContent = error?.name === 'AbortError' ? '请求超时，请重试。' : '作品载入失败，请重试。'; } finally { window.clearTimeout(timeout); loading = false; more.disabled = false; } }); return; }
      const form = byID('people-search'); const query = byID('people-query'); const grid = byID('people-grid'); const more = byID('people-load-more'); const status = byID('people-status'); const empty = byID('people-empty'); let offset = grid?.querySelectorAll('.person-card').length || 0; let currentQuery = ''; let loading = false; async function load(reset) { if (loading) return; loading = true; more.disabled = true; const controller = new AbortController(); const timeout = window.setTimeout(() => controller.abort(), 10000); status.textContent = reset ? '正在搜索人物…' : '正在载入更多人物…'; try { const params = new URLSearchParams({ offset: String(reset ? 0 : offset), limit: String(pageSize) }); if (currentQuery) params.set('q', currentQuery); const data = await fetchJSON(`/api/v1/people?${params.toString()}`, controller.signal); if (!data) return; const items = Array.isArray(data.items) ? data.items : []; const fragment = document.createDocumentFragment(); for (const item of items) fragment.append(personCard(item)); if (reset) { grid.replaceChildren(fragment); offset = items.length; } else { grid.append(fragment); offset += items.length; } more.hidden = !data.hasMore; empty.hidden = Number(data.totalItemCount) > 0; status.textContent = `共 ${Math.max(0, Number(data.totalItemCount) || 0)} 位人物`; } catch (error) { status.textContent = error?.name === 'AbortError' ? '请求超时，请重试。' : '人物载入失败，请重试。'; } finally { window.clearTimeout(timeout); loading = false; more.disabled = false; } }
      form?.addEventListener('submit', event => { event.preventDefault(); currentQuery = String(query.value || '').trim().slice(0, 128); void load(true); }); more?.addEventListener('click', () => void load(false));
    })();
    """#

    private static func initials(_ value: String) -> String {
        let parts = value.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let result = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return result.isEmpty ? "?" : String(result.prefix(2))
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
