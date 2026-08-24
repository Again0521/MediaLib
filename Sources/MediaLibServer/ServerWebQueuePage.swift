import Foundation
import MediaLibServerProtocol

/// 持久化的逐用户网页播放队列。页面只接受服务端已经授权的队列 DTO；浏览器
/// 通过同源 JSON 端点修改顺序和播放设置，令牌仍只存在于受保护的 HTML meta 中。
enum ServerWebQueuePage {
    static func render(serverName: String, queue: ServerQueueResponse, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras) -> String {
        let items = queue.items.enumerated().map { index, item in
            itemMarkup(item, index: index, current: index == queue.currentPosition, total: queue.items.count)
        }.joined()
        let sidebar = ServerWebNavigation.render(active: .queue, showAdministration: showAdministration, note: .playback, categories: categories, extras: sidebarExtras)
        let shuffleEnabled = queue.shuffleEnabled ? "true" : "false"
        let shuffleLabel = queue.shuffleEnabled ? "关闭随机" : "开启随机"
        let repeatSelected = { (value: String) in queue.repeatMode == value ? " selected" : "" }
        let emptyState = queue.items.isEmpty ? "队列为空，请从资料库加入媒体。" : "已同步"
        let disabled = queue.items.isEmpty

        let content = """
        \(ServerWebPageHeader.render(
            icon: .queue,
            eyebrow: "Playback",
            title: "播放队列",
            subtitle: "接下来要看的内容。换台设备登录，队列还在。",
            countID: "queue-count",
            initialCount: queue.items.count,
            actions: ServerWebUI.button("清空队列", variant: .destructive, icon: .trash, id: "clear-queue", disabled: disabled)
        ))
        \(ServerWebUI.controlBar(
            label: "队列设置",
            chipsLabel: "队列设置",
            chips: [],
            mobileDisclosureLabel: "高级筛选",
            // 同步状态不是计数，所以它留在条内而不是随计数搬进页头。
            trailing: #"""
            <span id="queue-status" class="t-footnote t-tertiary" role="status" aria-live="polite">\#(ServerWebHTML.escape(emptyState))</span>
            <label class="queue-select">
              <span class="t-footnote t-tertiary">循环</span>
              <select class="ui-select" id="repeat-mode">
                <option value="sequential"\#(repeatSelected("sequential"))>顺序播放</option>
                <option value="repeatOne"\#(repeatSelected("repeatOne"))>单曲循环</option>
                <option value="repeatAll"\#(repeatSelected("repeatAll"))>列表循环</option>
              </select>
            </label>
            \#(ServerWebUI.button(shuffleLabel, variant: .secondary, icon: .sort, id: "shuffle-toggle", attributes: #" aria-pressed="\#(shuffleEnabled)""#))
            """#,
            trailingID: "queue-advanced-filters",
            extraClass: "queue-toolbar"
        ))
        <ol id="queue-list" class="queue-list" aria-live="polite">\(items)</ol>
        \(ServerWebUI.emptyState(
            icon: .queue,
            title: "队列为空",
            message: "在任意影片上选择「加入队列」，就能把接下来要看的排在这里。",
            action: "浏览资料库",
            actionHref: "/category/\(ServerWebLibraryPage.Scope.videoGroupID)",
            id: "queue-empty",
            hidden: !queue.items.isEmpty
        ))
        """

        return ServerWebDocument.render(
            title: "播放队列",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/queue.css"],
            pageScripts: ["/assets/overlays.js", "/assets/queue.js"],
            bodyAttributes: #" data-page-route="/queue" data-playback-filter="inProgress" data-repeat-mode="\#(ServerWebHTML.escape(queue.repeatMode))" data-shuffle-enabled="\#(shuffleEnabled)" data-current-position="\#(queue.currentPosition)""#,
            tint: .music
        )
    }

    private static func itemMarkup(_ item: ServerQueueItem, index: Int, current: Bool, total: Int) -> String {
        guard let id = ServerWebURL.pathSegment(item.id) else { return "" }
        let destination = item.isSeries ? "/series/\(id)/play" : "/item/\(id)"
        let artwork = item.artworkAvailable
            ? #"<img src="/api/v1/images/\#(id)/poster?size=160" alt="" loading="lazy" decoding="async">"#
            : #"<span class="queue-art-fallback" aria-hidden="true">\#(ServerWebHTML.escape(String(item.type.prefix(1)).uppercased()))</span>"#
        let sourceBadge = item.isRemoteSource ? #"<span class="queue-source">Mlink</span>"# : ""
        let title = ServerWebHTML.escape(item.title)
        let meta = "\(ServerWebHTML.escape(item.type))\(item.year.map { " · \($0)" } ?? "")\(current ? " · 正在播放" : "")"
        return """
        <li class="queue-item\(current ? " current" : "")" data-item-id="\(ServerWebHTML.escape(item.id))" data-index="\(index)">
          <span class="queue-position" aria-label="第 \(index + 1) 项">\(index + 1)</span>
          <a class="queue-link" href="\(destination)">
            <span class="queue-art">\(artwork)\(sourceBadge)</span>
            <span class="queue-copy"><strong>\(title)</strong><small>\(meta)</small></span>
          </a>
          <span class="queue-actions">
            \(ServerWebUI.iconButton(.arrowUp, label: "上移 \(item.title)", size: .small, disabled: index == 0, attributes: #" data-action="up""#))
            \(ServerWebUI.iconButton(.arrowDown, label: "下移 \(item.title)", size: .small, disabled: index >= total - 1, attributes: #" data-action="down""#))
            \(ServerWebUI.iconButton(.close, label: "移除 \(item.title)", size: .small, attributes: #" data-action="remove""#))
          </span>
        </li>
        """
    }

    static let style = #"""
    .queue-toolbar { margin-bottom: var(--space-6); }
    .queue-select { display: flex; align-items: center; gap: var(--space-2); }

    .queue-list { display: grid; gap: var(--space-2); }
    .queue-item {
      display: grid;
      grid-template-columns: 32px minmax(0, 1fr) auto;
      align-items: center;
      gap: var(--space-3);
      padding: var(--space-2);
      border: var(--hairline) solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
      transition: border-color var(--duration-fast) var(--ease-out), background-color var(--duration-fast) var(--ease-out);
    }
    .queue-item:hover { border-color: var(--border-strong); }
    /* The playing row is marked by a tinted plate and an accent rail, not by
       colour alone. */
    .queue-item.current {
      border-color: transparent;
      background: var(--surface-selected);
      box-shadow: inset 3px 0 0 var(--accent);
    }
    .queue-position {
      color: var(--text-tertiary);
      font-size: var(--type-footnote-size);
      font-variant-numeric: tabular-nums;
      text-align: center;
    }
    .queue-link { display: flex; min-width: 0; align-items: center; gap: var(--space-3); color: inherit; }
    .queue-art {
      position: relative;
      display: grid;
      width: 44px;
      height: 62px;
      flex: none;
      place-items: center;
      overflow: hidden;
      border-radius: var(--radius-xs);
      background: var(--surface-sunken);
    }
    .queue-art img { width: 100%; height: 100%; object-fit: cover; }
    .queue-art-fallback { color: var(--text-tertiary); font-weight: var(--weight-bold); }
    .queue-source {
      position: absolute;
      top: 3px;
      left: 3px;
      padding: 1px 4px;
      border-radius: 4px;
      color: var(--text-on-media);
      background: var(--overlay-on-media-strong);
      font-size: 9px;
      font-weight: var(--weight-semibold);
    }
    .queue-copy { min-width: 0; }
    .queue-copy strong {
      display: block;
      overflow: hidden;
      font-size: var(--type-callout-size);
      font-weight: var(--weight-medium);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .queue-copy small { display: block; margin-top: 2px; color: var(--text-tertiary); font-size: var(--type-footnote-size); }
    .queue-actions { display: flex; align-items: center; gap: var(--space-1); }

    @media (max-width: 719px) {
      .queue-item { grid-template-columns: 26px minmax(0, 1fr); }
      .queue-actions { grid-column: 2; justify-content: flex-end; }
      .queue-select { flex: 1 1 auto; justify-content: space-between; }
    }
    """#

    static let script = #"""
    (() => { 'use strict';
      const list = document.getElementById('queue-list'); const empty = document.getElementById('queue-empty'); const count = document.getElementById('queue-count'); const status = document.getElementById('queue-status'); const repeat = document.getElementById('repeat-mode'); const shuffle = document.getElementById('shuffle-toggle'); const clear = document.getElementById('clear-queue'); const csrf = document.querySelector('meta[name="medialib-csrf-token"]')?.content || ''; let state = null; let busy = false;
      const text = value => String(value ?? '').slice(0, 512);
      const notify = (message, tone) => { if (window.medialibToast) window.medialibToast(message, { tone: tone }); };
      const SVG_NS = 'http://www.w3.org/2000/svg';
      const ICONS = { up: 'M12 4v15.5M5.5 10.5 12 4l6.5 6.5', down: 'M12 4v15.5M5.5 13.5 12 20l6.5-6.5', remove: 'm6.5 6.5 11 11M17.5 6.5l-11 11' };
      const iconButton = (label, action, disabled) => {
        const node = document.createElement('button'); node.type = 'button';
        node.className = 'ui-btn ui-btn-icon ui-btn-ghost ui-btn-sm';
        node.dataset.action = action; node.disabled = disabled === true;
        node.setAttribute('aria-label', label); node.title = label;
        const svg = document.createElementNS(SVG_NS, 'svg');
        svg.setAttribute('class', 'icon icon-md'); svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '1.8'); svg.setAttribute('stroke-linecap', 'round');
        svg.setAttribute('stroke-linejoin', 'round'); svg.setAttribute('aria-hidden', 'true');
        const path = document.createElementNS(SVG_NS, 'path'); path.setAttribute('d', ICONS[action]);
        svg.appendChild(path); node.appendChild(svg);
        return node;
      };
      const fetchQueue = async signal => { const response = await fetch('/api/v1/queue', { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal }); if (response.status === 401) { window.location.assign('/login'); return null; } if (!response.ok) throw new Error(); return response.json(); };
      const mutate = async payload => { if (busy) return; busy = true; status.textContent = '正在同步队列…'; const controller = new AbortController(); const timer = window.setTimeout(() => controller.abort(), 10000); try { const response = await fetch('/api/v1/queue', { method: 'POST', credentials: 'same-origin', headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrf }, body: JSON.stringify(payload), signal: controller.signal }); if (response.status === 401) { window.location.assign('/login'); return; } if (!response.ok) throw new Error(); state = await response.json(); render(); } catch { status.textContent = '队列同步失败，请重试。'; notify('队列同步失败，请重试。', 'error'); } finally { window.clearTimeout(timer); busy = false; } };
      const render = () => { if (!state || !Array.isArray(state.items)) return; list.replaceChildren(); state.items.forEach((item, index) => { const row = document.createElement('li'); row.className = 'queue-item' + (index === Number(state.currentPosition) ? ' current' : ''); row.dataset.itemId = text(item.id); row.dataset.index = String(index); const position = document.createElement('span'); position.className = 'queue-position'; position.textContent = String(index + 1); position.setAttribute('aria-label', `第 ${index + 1} 项`); const link = document.createElement('a'); link.className = 'queue-link'; link.href = item.isSeries === true ? `/series/${encodeURIComponent(text(item.id))}/play` : `/item/${encodeURIComponent(text(item.id))}`; link.setAttribute('aria-label', `${item.isSeries === true ? '直接播放剧集' : '查看并播放'} ${text(item.title)}`); const art = document.createElement('span'); art.className = 'queue-art'; if (item.artworkAvailable === true) { const image = document.createElement('img'); image.alt = ''; image.loading = 'lazy'; image.decoding = 'async'; image.src = `/api/v1/images/${encodeURIComponent(text(item.id))}/poster?size=160`; art.append(image); } else { const fallback = document.createElement('span'); fallback.className = 'queue-art-fallback'; fallback.textContent = text(item.type).slice(0, 1).toUpperCase(); art.append(fallback); } const sourceLabel = ({emby:'Emby',jellyfin:'Jellyfin',plex:'Plex',mlink:'Mlink'})[item.remoteSourceKind]; if (sourceLabel) { const mark = document.createElement('span'); mark.className = 'queue-source'; mark.textContent = sourceLabel; art.append(mark); } const copy = document.createElement('span'); copy.className = 'queue-copy'; const title = document.createElement('strong'); title.textContent = text(item.title) || '未命名媒体'; const meta = document.createElement('small'); meta.textContent = `${text(item.type)}${Number.isInteger(item.year) ? ` · ${item.year}` : ''}${index === Number(state.currentPosition) ? ' · 正在播放' : ''}`; copy.append(title, meta); link.append(art, copy); const actions = document.createElement('span'); actions.className = 'queue-actions'; actions.append(iconButton('上移', 'up', index === 0), iconButton('下移', 'down', index === state.items.length - 1), iconButton('移除', 'remove')); row.append(position, link, actions); list.append(row); }); const total = state.items.length; if (count) count.textContent = ` · ${total} 项`; status.textContent = total ? '已同步' : '队列为空，请从资料库加入媒体。'; empty.hidden = total > 0; clear.disabled = total === 0; repeat.value = ['sequential', 'repeatOne', 'repeatAll'].includes(state.repeatMode) ? state.repeatMode : 'sequential'; const shuffleLabel = shuffle.querySelector('span'); if (shuffleLabel) shuffleLabel.textContent = state.shuffleEnabled === true ? '关闭随机' : '开启随机'; shuffle.setAttribute('aria-pressed', state.shuffleEnabled === true ? 'true' : 'false'); };
      list.addEventListener('click', event => { const target = event.target.closest('button[data-action]'); if (!target) return; const row = target.closest('.queue-item'); const index = Number(row?.dataset.index); if (!Number.isInteger(index) || !state) return; if (target.dataset.action === 'remove') mutate({ action: 'remove', mediaID: row.dataset.itemId }); else if (target.dataset.action === 'up' && index > 0) mutate({ action: 'move', fromIndex: index, toIndex: index - 1 }); else if (target.dataset.action === 'down' && index < state.items.length - 1) mutate({ action: 'move', fromIndex: index, toIndex: index + 1 }); });
      repeat.addEventListener('change', () => mutate({ action: 'settings', repeatMode: repeat.value })); shuffle.addEventListener('click', () => mutate({ action: 'settings', shuffleEnabled: !(state?.shuffleEnabled === true) })); clear.addEventListener('click', () => { if (state?.items?.length && window.confirm('清空当前播放队列？')) mutate({ action: 'clear' }); });
      (async () => { const controller = new AbortController(); const timer = window.setTimeout(() => controller.abort(), 10000); try { state = await fetchQueue(controller.signal); render(); } catch { status.textContent = '队列载入失败，请刷新重试。'; } finally { window.clearTimeout(timer); } })();
    })();
    """#
}
