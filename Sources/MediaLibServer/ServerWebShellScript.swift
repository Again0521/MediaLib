import Foundation

/// Shared progressive navigation for the authenticated Web shell.
///
/// Pages remain server-rendered and deep-linkable, but same-origin GET links can
/// reuse one fetched document without rebuilding the whole browser window. The
/// swap deliberately uses DOMParser/importNode/replaceChildren instead of HTML
/// string sinks; page-specific external scripts are recreated after the swap.
enum ServerWebShellScript {
    static let script = #"""
    (() => {
      'use strict';
      const nativeFetch = typeof window.fetch === 'function' ? window.fetch.bind(window) : null;
      if (nativeFetch && window.__medialibFetchInstalled !== true) {
        var refreshPromise = null;
        const refreshCSRF = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
        const requestURL = request => {
          try { return new URL(request.url, window.location.href); } catch (_) { return null; }
        };
        const isRefreshableRequest = request => {
          const url = requestURL(request);
          if (!url || url.origin !== window.location.origin) return false;
          if (!['GET', 'HEAD', 'OPTIONS'].includes(request.method)) return false;
          if (url.pathname === '/login' || url.pathname.startsWith('/assets/')) return false;
          if (url.pathname.startsWith('/api/v1/auth/')) return false;
          return true;
        };
        const isLoginRedirect = (response, request) => {
          if (!response.redirected) return false;
          const requestURLValue = requestURL(request);
          let responseURL;
          try { responseURL = new URL(response.url, window.location.href); } catch (_) { return false; }
          return requestURLValue?.origin === window.location.origin
            && responseURL.origin === window.location.origin
            && responseURL.pathname === '/login';
        };
        const invalidatesLibraryBrowseCache = request => {
          const url = requestURL(request);
          if (!url || ['GET', 'HEAD', 'OPTIONS'].includes(request.method)) return false;
          return url.pathname === '/api/v1/queue'
            || url.pathname.startsWith('/api/v1/user-media/');
        };
        const refreshSession = () => {
          if (refreshPromise) return refreshPromise;
          if (!refreshCSRF) return Promise.resolve(false);
          const controller = typeof window.AbortController === 'function' ? new AbortController() : null;
          const options = {
            method: 'POST',
            credentials: 'same-origin',
            cache: 'no-store',
            headers: { Accept: 'application/json', 'X-MediaLIB-CSRF': refreshCSRF }
          };
          if (controller) options.signal = controller.signal;
          const timeout = controller ? window.setTimeout(() => controller.abort(), 8_000) : null;
          refreshPromise = nativeFetch('/api/v1/auth/refresh', options)
            .then(response => response.ok)
            .catch(() => false)
            .finally(() => {
              if (timeout !== null) window.clearTimeout(timeout);
              refreshPromise = null;
            });
          return refreshPromise;
        };
        // Keep the refresh cookie scoped to the authentication API. Progressive
        // navigation can explicitly renew a spent browser session, without
        // widening that high-value cookie to every media and document request.
        window.__medialibRefreshSession = refreshSession;
        // 一次网络抖动或者一次 503，从前就等于那一栏永远空着：页面控制器取数据
        // 只发一次请求，失败就把空态画出来，读者除了刷新没有别的办法。读取请求
        // 因此统一退避重试三次。只有读取——写入重试可能会重复下单、重复入队。
        const retryableRead = request => {
          const url = requestURL(request);
          if (!url || url.origin !== window.location.origin) return false;
          if (!['GET', 'HEAD'].includes(request.method)) return false;
          // 会话续期自己就有重入保护，再叠一层重试只会让过期的会话多等几秒。
          return !url.pathname.startsWith('/api/v1/auth/');
        };
        const readRetryDelays = [400, 1_200, 2_600];
        const retryableStatus = status => status >= 500 || status === 408 || status === 429;
        const delay = milliseconds => new Promise(resolve => window.setTimeout(resolve, milliseconds));
        const fetchWithRetry = async request => {
          if (!retryableRead(request)) return nativeFetch(request);
          var attempt = 0;
          for (;;) {
            try {
              const response = await nativeFetch(attempt === 0 ? request : request.clone());
              if (attempt >= readRetryDelays.length || !retryableStatus(response.status)) return response;
              // 丢掉的响应体要主动关掉，否则连接一直挂着。
              try { await response.body?.cancel?.(); } catch (_) { /* ignore */ }
            } catch (error) {
              // 中止是调用方自己的决定，不是失败。
              if (attempt >= readRetryDelays.length
                || error?.name === 'AbortError'
                || request.signal?.aborted === true) throw error;
            }
            await delay(readRetryDelays[attempt]);
            attempt += 1;
          }
        };
        window.fetch = async (input, init) => {
          let request;
          try {
            request = typeof window.Request === 'function' && input instanceof window.Request && init === undefined
              ? input
              : new window.Request(input, init);
          } catch (_) {
            return nativeFetch(input, init);
          }
          const response = await fetchWithRetry(request);
          if (response.ok && invalidatesLibraryBrowseCache(request)) {
            // This cache only spans progressive document swaps in one
            // authenticated page. Clear it as soon as a queue/preference/
            // playback mutation succeeds, so a quick return never shows a
            // stale personal collection or progress card.
            window.__medialibLibraryBrowseCache?.clear?.();
            // Documents are also retained only for fast same-session sidebar
            // returns. Discard them on every successful personal mutation so
            // queue, progress, favorite and rating pages always refetch their
            // server-rendered state on the next visit.
            window.__medialibPageCache?.clear?.();
          }
          if (response.status !== 401 && !isLoginRedirect(response, request)) return response;
          if (!isRefreshableRequest(request)) return response;
          if (!await refreshSession()) return response;
          try { return await fetchWithRetry(request.clone()); } catch (_) { return response; }
        };
        window.__medialibFetchInstalled = true;
      }
      // The audio dock is an enhancement, never a prerequisite for navigation.
      // Some embedded / accessibility browsers intentionally omit `Audio`; in
      // that case do not let construction of `new Audio()` abort the shared
      // shell before its click and keyboard navigation handlers are installed.
      if (typeof window.Audio !== 'function') {
        window.__medialibAudioDockInstalled = true;
        window.__medialibEnsureAudioDock = () => null;
      }
      if (window.__medialibAudioDockInstalled !== true) {
        window.__medialibAudioDockInstalled = true;
        const csrfToken = () => document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
        const formatClock = seconds => {
          if (!Number.isFinite(seconds) || seconds < 0) return '--:--';
          const total = Math.floor(seconds);
          return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
        };
        const makeElement = (name, className, label) => {
          const node = document.createElement(name);
          if (className) node.className = className;
          if (label !== undefined) node.textContent = label;
          return node;
        };
        // 图标由 Swift 从 `ServerWebIcon` 插值下来，脚本这一侧不再自带路径数据。
        // 此前这里手写着十条实心 Material 风格的路径，`'play'` 画的三角和
        // 页面上 `.play` 那颗圆角三角根本不是同一个形状——底栏于是成了产品里
        // 唯一一处外来图标。
        \#(ServerWebIcon.scriptHelper(for: [
            .play, .pause, .skipBack, .skipForward, .shuffle, .repeatAll, .repeatOne,
            .volumeOn, .volumeOff, .queue, .music, .close
        ]))
        const transportGlyph = name => medialibIcon(name, 'icon icon-md');
        // Shared placeholder glyph for the dock cover.  Built as SVG rather than a
        // text note character so it takes a colour and one fixed size.
        const musicGlyph = () => medialibIcon('music', 'icon icon-md');
        // A bottom bar that offers 上一首/下一首 has to actually change tracks.
        // The previous version wired both to `currentTime ± 10`, so the labels,
        // the icons and the screen-reader names all described something the
        // controls did not do.  The queue is the list the reader started from:
        // every `[data-music-play]` in the document, in document order.
        const state = {
          audio: new Audio(), dock: null, cover: null, title: null, subtitle: null,
          play: null, previous: null, next: null, timeline: null, elapsed: null, total: null,
          volume: null, mute: null, shuffle: null, repeat: null,
          activeID: '', queue: [], index: -1, shuffleOn: false, repeatMode: 'off', lastVolume: 1, dockFrame: null,
          ambient: null, titleTrack: null
        };
        state.audio.preload = 'metadata';
        const makeTransport = (className, glyph, label) => {
          const button = makeElement('button', className, undefined);
          button.type = 'button';
          button.append(transportGlyph(glyph));
          button.setAttribute('aria-label', label);
          button.title = label;
          return button;
        };
        const closeDock = () => {
          if (!state.dock) return;
          state.audio.pause();
          state.audio.removeAttribute('src');
          state.audio.load();
          state.activeID = ''; state.queue = []; state.index = -1;
          state.dock.hidden = true;
          document.body.classList.remove('medialib-audio-dock-visible');
        };
        const ensureDock = () => {
          if (!state.dock) {
            const dock = makeElement('section', '', undefined);
            dock.id = 'medialib-audio-dock';
            dock.hidden = true;
            dock.setAttribute('aria-label', '音乐播放控制');

            // 玻璃底下一层由当前封面取色染出来的极淡光。底栏是浮在内容之上的
            // 前景外壳，材质在这里是允许的；取色走 `data-artwork-palette` 类令牌
            // 而不是内联样式，因为 CSP 会静默丢弃 `style=""`。
            const ambient = makeElement('div', 'ml-audio-ambient', undefined);
            ambient.setAttribute('aria-hidden', 'true');

            const content = makeElement('div', 'ml-audio-content', undefined);

            // Left: what is playing.
            const lead = makeElement('div', 'ml-audio-lead', undefined);
            const cover = makeElement('div', 'ml-audio-cover');
            cover.append(musicGlyph());
            const copy = makeElement('div', 'ml-audio-copy', undefined);
            // 标题只在**溢出时**、且只在指针停留或键盘聚焦时跑一趟，跑完就停。
            // 常驻循环的跑马灯是注意力税（设计文档 §2 禁止常驻动画），但一个被
            // 截断的曲名读者根本没有别的办法看全。
            const titleTrack = makeElement('span', 'ml-audio-title-track', undefined);
            const title = makeElement('strong', '', '还没开始播放');
            titleTrack.append(title);
            const subtitle = makeElement('span', '', 'MediaLIB 音乐');
            copy.append(titleTrack, subtitle);
            lead.append(cover, copy);

            // Centre: transport over the scrubber, the arrangement every music
            // service uses, so the primary control sits on the page's centre line.
            const centre = makeElement('div', 'ml-audio-centre', undefined);
            const controls = makeElement('div', 'ml-audio-controls', undefined);
            const shuffle = makeTransport('ml-audio-shuffle', 'shuffle', '随机播放');
            shuffle.setAttribute('aria-pressed', 'false');
            const previous = makeTransport('ml-audio-prev', 'skipBack', '上一首');
            const play = makeTransport('ml-audio-play', 'play', '播放');
            const next = makeTransport('ml-audio-next', 'skipForward', '下一首');
            const repeat = makeTransport('ml-audio-repeat', 'repeatAll', '循环播放：关闭');
            repeat.setAttribute('aria-pressed', 'false');
            controls.append(shuffle, previous, play, next, repeat);

            const scrubber = makeElement('div', 'ml-audio-scrubber', undefined);
            const elapsed = makeElement('span', 'ml-audio-time', '0:00');
            const timeline = document.createElement('input');
            // `ui-range` 带来槽/把手/填充，`ui-range-scrub` 让它在指针下变粗。
            timeline.className = 'ui-range ui-range-scrub ml-audio-progress-bar';
            timeline.type = 'range'; timeline.min = '0'; timeline.max = '0'; timeline.step = '0.1'; timeline.value = '0';
            timeline.setAttribute('aria-label', '播放进度');
            const total = makeElement('span', 'ml-audio-time', '--:--');
            scrubber.append(elapsed, timeline, total);
            centre.append(controls, scrubber);

            // Right: output and dismissal.
            const trail = makeElement('div', 'ml-audio-trail', undefined);
            const mute = makeTransport('ml-audio-mute', 'volumeOn', '静音');
            mute.setAttribute('aria-pressed', 'false');
            const volume = document.createElement('input');
            volume.className = 'ui-range ml-audio-volume'; volume.type = 'range'; volume.min = '0'; volume.max = '1'; volume.step = '0.05'; volume.value = '1'; volume.setAttribute('aria-label', '音量');
            const queueLink = document.createElement('a');
            queueLink.className = 'ml-audio-queue';
            queueLink.href = '/queue';
            queueLink.setAttribute('aria-label', '播放队列');
            queueLink.title = '播放队列';
            queueLink.append(transportGlyph('queue'));
            const close = makeTransport('ml-audio-close', 'close', '关闭音乐播放器');
            trail.append(mute, volume, queueLink, close);

            content.append(lead, centre, trail);
            dock.append(ambient, content);
            state.ambient = ambient;
            state.titleTrack = titleTrack;

            play.addEventListener('click', () => {
              if (state.audio.paused) void state.audio.play().catch(() => {}); else state.audio.pause();
            });
            previous.addEventListener('click', () => {
              // Matching every music player: within the first few seconds the
              // control goes to the previous track, later it restarts this one.
              if ((state.audio.currentTime || 0) > 3 || state.queue.length < 2) { state.audio.currentTime = 0; return; }
              playQueueOffset(-1);
            });
            next.addEventListener('click', () => playQueueOffset(1));
            shuffle.addEventListener('click', () => {
              state.shuffleOn = !state.shuffleOn;
              shuffle.setAttribute('aria-pressed', String(state.shuffleOn));
              shuffle.classList.toggle('is-active', state.shuffleOn);
              const label = state.shuffleOn ? '随机播放：开启' : '随机播放：关闭';
              shuffle.setAttribute('aria-label', label); shuffle.title = label;
            });
            repeat.addEventListener('click', () => {
              state.repeatMode = state.repeatMode === 'off' ? 'all' : (state.repeatMode === 'all' ? 'one' : 'off');
              repeat.replaceChildren(transportGlyph(state.repeatMode === 'one' ? 'repeatOne' : 'repeatAll'));
              repeat.setAttribute('aria-pressed', String(state.repeatMode !== 'off'));
              repeat.classList.toggle('is-active', state.repeatMode !== 'off');
              const label = state.repeatMode === 'off' ? '循环播放：关闭' : (state.repeatMode === 'all' ? '循环播放：全部' : '循环播放：单曲');
              repeat.setAttribute('aria-label', label); repeat.title = label;
            });
            mute.addEventListener('click', () => {
              if (state.audio.muted || state.audio.volume === 0) {
                state.audio.muted = false;
                state.audio.volume = state.lastVolume > 0 ? state.lastVolume : 1;
              } else {
                state.lastVolume = state.audio.volume;
                state.audio.muted = true;
              }
              paintVolume();
            });

            timeline.addEventListener('input', () => {
              const target = Number(timeline.value);
              if (Number.isFinite(target)) state.audio.currentTime = target;
              paintTimeline();
            });
            volume.addEventListener('input', () => {
              state.audio.muted = false;
              state.audio.volume = Number(volume.value);
              state.lastVolume = state.audio.volume;
              paintVolume();
            });
            close.addEventListener('click', () => {
              state.audio.pause(); state.audio.removeAttribute('src'); state.audio.load();
              closeDock();
            });
            state.dock = dock; state.cover = cover; state.title = title; state.subtitle = subtitle;
            state.play = play; state.previous = previous; state.next = next;
            state.timeline = timeline; state.elapsed = elapsed; state.total = total;
            state.volume = volume; state.mute = mute; state.shuffle = shuffle; state.repeat = repeat;
          }
          if (!state.dock.isConnected) document.body.append(state.dock);
          // body 是整个换掉的，类名不会跟着元素回来；不补上，`.app-main` 就少了
          // 给底栏预留的那一段下边距，页尾内容会被压在底栏底下。
          if (!state.dock.hidden) document.body.classList.add('medialib-audio-dock-visible');
          // 视频播放页自己要出声，音乐底栏在这里让位——这是唯一会自动关掉它的地方。
          if (document.body.dataset.mediaKind === 'video') closeDock();
          return state.dock;
        };
        const paintTimeline = () => {
          if (!state.timeline) return;
          const max = Number(state.timeline.max);
          const percent = max > 0 ? (Number(state.timeline.value) / max) * 100 : 0;
          state.timeline.style.setProperty('--progress', `${Math.min(Math.max(percent, 0), 100)}%`);
        };
        const paintVolume = () => {
          if (!state.volume || !state.mute) return;
          const silent = state.audio.muted || state.audio.volume === 0;
          state.volume.value = String(silent ? 0 : state.audio.volume);
          state.volume.style.setProperty('--progress', `${(silent ? 0 : state.audio.volume) * 100}%`);
          state.mute.replaceChildren(transportGlyph(silent ? 'volumeOff' : 'volumeOn'));
          state.mute.setAttribute('aria-pressed', String(silent));
          const label = silent ? '取消静音' : '静音';
          state.mute.setAttribute('aria-label', label); state.mute.title = label;
        };
        /// The queue is whatever list the reader is looking at, in document order.
        // 取色由 Swift 从 `ServerWebArtworkPalette` 插值下来：底栏那层光必须和
        // 它上面那张封面卡片落到同一个桶，否则同一首歌会有两种颜色。
        \#(ServerWebArtworkPalette.scriptHelper)
        const collectQueue = (activeID) => {
          const seen = new Set();
          const items = [];
          for (const node of document.querySelectorAll('[data-music-play]')) {
            const id = node.dataset.musicPlay || '';
            if (!id || seen.has(id)) continue;
            seen.add(id);
            items.push({ id, title: node.dataset.musicTitle || '', subtitle: node.dataset.musicSubtitle || 'MediaLIB 音乐' });
          }
          state.queue = items;
          state.index = items.findIndex(entry => entry.id === activeID);
        };
        const playQueueOffset = (offset) => {
          if (state.queue.length === 0) return;
          let target;
          if (state.shuffleOn && state.queue.length > 1) {
            do { target = Math.floor(Math.random() * state.queue.length); } while (target === state.index);
          } else {
            target = state.index + offset;
            if (target < 0) target = state.repeatMode === 'all' ? state.queue.length - 1 : 0;
            if (target >= state.queue.length) {
              if (state.repeatMode !== 'all') return;
              target = 0;
            }
          }
          const entry = state.queue[target];
          if (entry) startMusic(entry.id, entry.title, entry.subtitle, { keepQueue: true, index: target });
        };
        const syncTransportAvailability = () => {
          if (!state.previous || !state.next) return;
          const many = state.queue.length > 1;
          state.previous.disabled = !many && (state.audio.currentTime || 0) <= 0;
          state.next.disabled = !many && state.repeatMode !== 'one';
        };
        const updateDock = () => {
          if (!state.timeline || !state.elapsed || !state.play) return;
          const duration = Number.isFinite(state.audio.duration) ? state.audio.duration : 0;
          state.timeline.max = String(duration);
          state.timeline.value = String(Math.min(state.audio.currentTime || 0, duration));
          paintTimeline();
          state.elapsed.textContent = formatClock(state.audio.currentTime);
          state.total.textContent = duration > 0 ? formatClock(duration) : '--:--';
          state.play.replaceChildren(transportGlyph(state.audio.paused ? 'play' : 'pause'));
          const label = state.audio.paused ? '播放' : '暂停';
          state.play.setAttribute('aria-label', label);
          state.play.title = label;
          syncTransportAvailability();
        };
        const scheduleDock = () => {
          if (state.dockFrame !== null) return;
          state.dockFrame = window.requestAnimationFrame(() => {
            state.dockFrame = null;
            updateDock();
          });
        };
        const report = event => {
          if (!state.activeID || !csrfToken()) return;
          void fetch(`/api/v1/playback/state/${encodeURIComponent(state.activeID)}`, {
            method: 'POST', credentials: 'same-origin', keepalive: event !== 'progress',
            headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': csrfToken() },
            body: JSON.stringify({ event, positionSeconds: Number.isFinite(state.audio.currentTime) ? state.audio.currentTime : 0, durationSeconds: Number.isFinite(state.audio.duration) ? state.audio.duration : null })
          }).catch(() => {});
        };
        state.audio.addEventListener('loadedmetadata', updateDock);
        state.audio.addEventListener('timeupdate', scheduleDock);
        state.audio.addEventListener('play', () => { updateDock(); report('started'); });
        state.audio.addEventListener('pause', () => { updateDock(); if (!state.audio.ended) report('stopped'); });
        state.audio.addEventListener('ended', () => {
          updateDock();
          report('completed');
          if (state.repeatMode === 'one') { state.audio.currentTime = 0; void state.audio.play().catch(() => {}); return; }
          playQueueOffset(1);
        });
        state.audio.addEventListener('volumechange', paintVolume);
        state.audio.addEventListener('error', () => { if (state.subtitle) state.subtitle.textContent = '这个浏览器播不了这首歌'; });
        const startMusic = (id, title, subtitle, options) => {
          if (!id) return;
          const dock = ensureDock();
          state.activeID = id;
          if (options && options.keepQueue === true) state.index = options.index;
          else collectQueue(id);
          state.title.textContent = title || '未命名音乐';
          state.subtitle.textContent = subtitle || 'MediaLIB 音乐';
          // 跑马灯只在真的放不下时才有意义。测量放在这里而不是 CSS 里，是因为
          // "溢出了多少"决定位移距离，而 CSS 拿不到这个数。
          if (state.titleTrack) {
            const overflow = Math.max(0, state.title.scrollWidth - state.titleTrack.clientWidth);
            state.titleTrack.dataset.overflowing = overflow > 4 ? 'true' : 'false';
            state.titleTrack.style.setProperty('--marquee-shift', `-${overflow}px`);
          }
          // 底栏那层环境光跟着当前曲目的取色走。同一个 FNV-1a 哈希，和服务端
          // `ServerWebArtworkPalette` 给这条曲目算出来的是同一个桶。
          if (state.ambient) state.ambient.dataset.artworkPalette = medialibArtworkPalette(id, 'music');
          state.cover.replaceChildren();
          const image = document.createElement('img');
          image.src = `/api/v1/images/${encodeURIComponent(id)}/poster?size=160`; image.alt = '';
          image.style.opacity = '0';
          image.addEventListener('load', () => { image.style.opacity = '1'; }, { once: true });
          image.addEventListener('error', () => { state.cover.replaceChildren(musicGlyph()); }, { once: true });
          state.cover.append(image);
          dock.hidden = false; document.body.classList.add('medialib-audio-dock-visible');
          state.audio.pause(); state.audio.src = `/api/v1/stream/${encodeURIComponent(id)}`; state.audio.load();
          paintVolume();
          syncTransportAvailability();
          void state.audio.play().catch(() => { state.subtitle.textContent = '请按播放按钮继续'; updateDock(); });
        };
        document.addEventListener('click', event => {
          if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
          const control = event.target?.closest?.('[data-music-play]');
          if (!(control instanceof HTMLElement)) return;
          const id = control.dataset.musicPlay || '';
          if (!id) return;
          event.preventDefault(); event.stopImmediatePropagation();
          startMusic(id, control.dataset.musicTitle || control.getAttribute('aria-label') || '', control.dataset.musicSubtitle || 'MediaLIB 音乐');
        }, true);
        window.__medialibEnsureAudioDock = ensureDock;
        window.__medialibAudioIsActive = () => Boolean(state.activeID);
      }
      if (window.__medialibNavigationInstalled === true) return;
      window.__medialibNavigationInstalled = true;

      // ---- 共用移动端高级筛选 ----------------------------------------------
      // 控制条由服务端页面逐次替换，因此这里使用事件委托，只安装一次就能覆盖资料库、
      // 音乐、队列以及之后接入同一组件的页面。展开状态只属于当前页；回到桌面断点时
      // 立即复位，让 aria 状态与视觉状态始终一致。
      const closeControlBarDisclosures = () => {
        for (const bar of document.querySelectorAll('.ui-control-bar.is-mobile-disclosable')) {
          bar.classList.remove('is-advanced-open');
          bar.querySelector('.ui-control-bar-disclosure')?.setAttribute('aria-expanded', 'false');
        }
      };
      document.addEventListener('click', event => {
        const trigger = event.target?.closest?.('.ui-control-bar-disclosure');
        if (!trigger) return;
        const bar = trigger.closest('.ui-control-bar.is-mobile-disclosable');
        const targetID = trigger.getAttribute('aria-controls') || '';
        const panel = targetID ? document.getElementById(targetID) : null;
        if (!bar || !panel || panel.parentElement !== bar) return;
        const expanded = bar.classList.toggle('is-advanced-open');
        trigger.setAttribute('aria-expanded', expanded ? 'true' : 'false');
      });
      const narrowControlBars = window.matchMedia?.('(max-width: 719px)');
      narrowControlBars?.addEventListener?.('change', event => { if (!event.matches) closeControlBarDisclosures(); });
      window.addEventListener('medialib:pagedidload', () => {
        if (narrowControlBars?.matches === false) closeControlBarDisclosures();
      });
      document.documentElement.classList.add('app-shell-ready');

      // ---- 同源资源的重试与统一兜底 ------------------------------------------
      // `<img>` 没有重试语义。缩略图恰好在生成、NAS 刚被唤醒、网络抖了一下——
      // 这些都是暂时的，可页面上留下的是一个永久的空格子，不刷新就再也不会回来。
      // 样式表和页面控制器同理：少载入一个 `library.js`，那一页就再也不出内容。
      //
      // 每个同源资源因此有三次退避重试。序号必须挂进 URL：浏览器对同一个地址
      // 不会再发第二次请求，改 `src` 成同样的值等于什么都没做（服务端认识
      // `_retry` 这个键，然后忽略它）。三次用完才落到统一的兜底封面上——那是
      // 「取不到图」的一致外观，而不是每个页面各画一种空白。
      const resourceRetryDelays = [600, 1_800, 4_000];
      const artworkFallbackSelector = ':scope > .ui-poster-fallback, :scope > .artwork-fallback,'
        + ' :scope > .ui-artwork-fallback, :scope > .photo-placeholder';
      const retryURL = (raw, attempt) => {
        let url;
        try { url = new URL(raw, window.location.href); } catch (_) { return null; }
        if (url.origin !== window.location.origin) return null;
        url.searchParams.set('_retry', String(attempt));
        return url.pathname + url.search;
      };
      // 兜底封面上写的是这张图代表的东西。海报底下本来就压着一层写了标题的
      // 兜底块，这里只服务那些没有的地方（音乐封面、详情页剧照、照片舞台）。
      const artworkLabel = image => {
        const card = image.closest('.ui-media-card, .ui-track-row, figure, a');
        const title = card?.querySelector('.ui-media-title, .ui-poster-fallback, strong')?.textContent;
        return String(image.getAttribute('alt') || title || '').trim().slice(0, 24);
      };
      const markArtworkReady = image => {
        image.dataset.artworkState = 'ready';
        image.dataset.ready = 'true';
        const host = image.parentElement;
        if (!(host instanceof Element)) return;
        host.removeAttribute('data-artwork-failed');
        host.querySelector(':scope > .ui-artwork-fallback')?.remove();
      };
      const markArtworkFailed = image => {
        image.dataset.artworkState = 'failed';
        // 服务端渲染的封面自带 `data-ready="true"`，取不到图时必须收回它，否则
        // 读者看到的是浏览器画的碎图标，而不是兜底封面。
        delete image.dataset.ready;
        const host = image.parentElement;
        if (!(host instanceof Element)) return;
        if (host.querySelector(artworkFallbackSelector)) return;
        const fallback = document.createElement('span');
        fallback.className = 'ui-artwork-fallback';
        fallback.setAttribute('aria-hidden', 'true');
        fallback.textContent = artworkLabel(image);
        host.setAttribute('data-artwork-failed', 'true');
        host.prepend(fallback);
      };
      const retryResource = (element, attribute) => {
        if (!element.dataset.retrySource) {
          element.dataset.retrySource = element.getAttribute(attribute) || '';
        }
        const source = element.dataset.retrySource;
        if (!source || /^(data|blob):/i.test(source)) return false;
        const attempt = Number(element.dataset.retryAttempts || '0') + 1;
        if (!(attempt >= 1) || attempt > resourceRetryDelays.length) return false;
        const next = retryURL(source, attempt);
        if (!next) return false;
        element.dataset.retryAttempts = String(attempt);
        window.setTimeout(() => {
          if (!element.isConnected) return;
          if (element.tagName.toLowerCase() === 'img') { element.setAttribute(attribute, next); return; }
          // 样式表和脚本换个属性是不会重来的：失败过的节点不再加载。必须换一个
          // 新节点，并把已经用掉的重试次数一起带过去。
          const replacement = document.createElement(element.tagName);
          for (const attributeNode of [...element.attributes]) {
            replacement.setAttribute(attributeNode.name, attributeNode.value);
          }
          replacement.setAttribute(attribute, next);
          element.replaceWith(replacement);
        }, resourceRetryDelays[attempt - 1]);
        return true;
      };
      const handleResourceFailure = element => {
        if (!(element instanceof Element)) return;
        const tag = element.tagName.toLowerCase();
        if (tag === 'img') {
          if (!retryResource(element, 'src')) markArtworkFailed(element);
          return;
        }
        if (tag === 'script') { retryResource(element, 'src'); return; }
        if (tag === 'link' && (element.getAttribute('rel') || '').includes('stylesheet')) {
          retryResource(element, 'href');
        }
      };
      // `error` 和 `load` 在图片上都不冒泡，但捕获阶段照样经过 document。
      document.addEventListener('error', event => handleResourceFailure(event.target), true);
      document.addEventListener('load', event => {
        const target = event.target;
        if (!(target instanceof Element) || target.tagName.toLowerCase() !== 'img') return;
        target.dataset.retryAttempts = '0';
        markArtworkReady(target);
      }, true);
      // 页面控制器是先建好 <img>、设好 src，再把整张卡片插进文档的。图在插进来
      // 之前就失败的话，那一次 `error` 没有祖先可以捕获，上面的监听收不到。
      const adoptArtwork = root => {
        if (!(root instanceof Element)) return;
        const images = root.tagName.toLowerCase() === 'img' ? [root] : [...root.querySelectorAll('img')];
        for (const image of images) {
          if (image.dataset.artworkState === 'failed') continue;
          if (!image.complete || !image.getAttribute('src')) continue;
          if (image.naturalWidth > 0) { markArtworkReady(image); continue; }
          if (!retryResource(image, 'src')) markArtworkFailed(image);
        }
      };
      if (typeof window.MutationObserver === 'function') {
        new window.MutationObserver(records => {
          for (const record of records) {
            for (const node of record.addedNodes) adoptArtwork(node);
          }
        }).observe(document.documentElement, { childList: true, subtree: true });
      }
      // 网络回来时，把三次都用完的那些再给一次机会：这是最常见的一整批失败。
      window.addEventListener('online', () => {
        for (const image of document.querySelectorAll('img[data-artwork-state="failed"]')) {
          image.dataset.retryAttempts = '0';
          retryResource(image, 'src');
        }
      });
      adoptArtwork(document.documentElement);

      // ---- 常驻侧栏的状态 ----------------------------------------------------
      // 侧栏是常驻导航，不该跟着内容刷新。就地换页已经原样保留它，但详情页和
      // 播放页走的是整页加载：文档被浏览器整个换掉，展开的分组收了回去、滚动
      // 位置回到顶端——读者每看一部片子，就要把「视频」重新展开一次。
      //
      // 状态因此存进 sessionStorage（只属于这一个标签页，关掉即消失），在每次
      // 文档载入和每次就地换页之后原样放回去。
      const sidebarStateKey = 'medialib:sidebar-state';
      const sidebarElement = () => document.querySelector('.app-sidebar');
      const drawerBreakpoint = window.matchMedia?.('(max-width: 1023px)');
      const drawerStateElement = () => document.getElementById('app-drawer-state');
      const drawerToggleElement = () => document.querySelector('.app-drawer-toggle');
      const synchronizeDrawerAccessibility = () => {
        const sidebar = sidebarElement();
        const state = drawerStateElement();
        const toggle = drawerToggleElement();
        if (!sidebar || !state) return;
        const isDrawer = drawerBreakpoint?.matches === true;
        const isOpen = !isDrawer || state.checked;
        // A translated drawer is still in the tab order. Keep its accessibility
        // state aligned with the visible spatial model so keyboard readers never
        // land on controls outside the viewport. Desktop retains the same live
        // sidebar rather than inheriting stale mobile state after a resize.
        sidebar.inert = !isOpen;
        sidebar.toggleAttribute('inert', !isOpen);
        if (isOpen) sidebar.removeAttribute('aria-hidden');
        else sidebar.setAttribute('aria-hidden', 'true');
        if (toggle) {
          toggle.setAttribute('aria-expanded', state.checked ? 'true' : 'false');
          toggle.setAttribute('aria-label', state.checked ? '关闭导航' : '打开导航');
        }
      };
      const disclosureKey = details => details.querySelector('summary')?.textContent?.trim() ?? '';
      const captureSidebarState = sidebar => {
        if (!sidebar) return null;
        const opened = [];
        const closed = [];
        for (const details of sidebar.querySelectorAll('details.nav-disclosure')) {
          const key = disclosureKey(details);
          if (!key) continue;
          (details.open ? opened : closed).push(key);
        }
        return { opened, closed, scrollTop: Math.round(sidebar.scrollTop) };
      };
      const applySidebarState = (sidebar, state) => {
        if (!sidebar || !state) return;
        for (const details of sidebar.querySelectorAll('details.nav-disclosure')) {
          const key = disclosureKey(details);
          if (!key) continue;
          // 服务端已经把「当前所在的那个分组」标成展开。读者在别处收起过同名
          // 分组，不该把这个定位一起撤销掉。
          if (details.querySelector('[aria-current]')) { details.open = true; continue; }
          if (state.opened?.includes(key)) details.open = true;
          else if (state.closed?.includes(key)) details.open = false;
        }
        if (typeof state.scrollTop === 'number') sidebar.scrollTop = state.scrollTop;
      };
      const readStoredJSON = key => {
        try { return JSON.parse(window.sessionStorage?.getItem(key) || 'null'); } catch (_) { return null; }
      };
      const writeStoredJSON = (key, value) => {
        // 无痕模式下 sessionStorage 会直接抛错。状态保留是锦上添花，不能因此
        // 让导航整个失效。
        try { window.sessionStorage?.setItem(key, JSON.stringify(value)); } catch (_) { /* ignore */ }
      };
      const persistSidebarState = () => {
        const state = captureSidebarState(sidebarElement());
        if (state) writeStoredJSON(sidebarStateKey, state);
      };
      const restoreSidebarState = () => applySidebarState(sidebarElement(), readStoredJSON(sidebarStateKey));
      document.addEventListener('toggle', event => {
        if (event.target?.classList?.contains?.('nav-disclosure')) persistSidebarState();
      }, true);
      var sidebarScrollTimer = null;
      document.addEventListener('scroll', event => {
        if (!(event.target instanceof Element) || !event.target.classList.contains('app-sidebar')) return;
        if (sidebarScrollTimer !== null) return;
        sidebarScrollTimer = window.setTimeout(() => {
          sidebarScrollTimer = null;
          persistSidebarState();
        }, 250);
      }, true);
      window.addEventListener('pagehide', persistSidebarState);
      restoreSidebarState();
      synchronizeDrawerAccessibility();
      drawerBreakpoint?.addEventListener?.('change', synchronizeDrawerAccessibility);
      document.addEventListener('change', event => {
        if (event.target?.id !== 'app-drawer-state') return;
        synchronizeDrawerAccessibility();
        if (!event.target.checked && sidebarElement()?.contains(document.activeElement)) {
          drawerToggleElement()?.focus();
        }
      });
      document.addEventListener('keydown', event => {
        const toggle = event.target?.closest?.('.app-drawer-toggle');
        if (toggle && (event.key === 'Enter' || event.key === ' ')) {
          event.preventDefault();
          const state = drawerStateElement();
          if (!state) return;
          state.checked = !state.checked;
          state.dispatchEvent(new Event('change', { bubbles: true }));
          if (state.checked) sidebarElement()?.querySelector('a[href], button, summary, select, input')?.focus();
          return;
        }
        if (event.key !== 'Escape' || drawerBreakpoint?.matches !== true) return;
        const state = drawerStateElement();
        if (!state?.checked) return;
        state.checked = false;
        state.dispatchEvent(new Event('change', { bubbles: true }));
      });

      // ---- 「返回」指向真正的来处 --------------------------------------------
      // 服务端已经按 `Referer` 把返回目标算好了（详情页、人物、合集、照片、歌单
      // 都是），这里补的是它做不到的两件事：
      //
      //  * 就地换页没有新的 HTTP 请求，服务端那次推导发生在读者还在上一页的时候。
      //    所以来处要跟着**这一条历史记录**走，存进 history.state——存成全局变量
      //    的话，按一下后退键它就是错的。
      //  * 用后退键回去，比重新走一遍链接多带一样东西：读者原来的滚动位置。
      const sameOriginReferrer = () => {
        const raw = document.referrer || '';
        if (!raw) return null;
        let url;
        try { url = new URL(raw); } catch (_) { return null; }
        if (url.origin !== window.location.origin) return null;
        if (url.href === window.location.href) return null;
        return url;
      };
      const currentPageLabel = () => {
        if (window.location.pathname === '/search'
          && new URLSearchParams(window.location.search).get('q')) return '搜索结果';
        const heading = document.querySelector('.app-page-head h1');
        const raw = String(heading?.textContent || document.title.split('·')[0] || '').trim();
        return raw.length > 12 ? `${raw.slice(0, 12)}…` : raw;
      };
      const currentOrigin = () => ({ href: window.location.href, label: currentPageLabel(), canPop: true });
      const renderBackControl = () => {
        const from = window.history.state?.medialibFrom;
        const control = document.querySelector('.app-back');
        if (!control || !from?.href) return;
        let url;
        try { url = new URL(from.href, window.location.href); } catch (_) { return; }
        if (url.origin !== window.location.origin || url.href === window.location.href) return;
        const target = url.pathname + url.search;
        if (control.dataset.serverHref === undefined) {
          control.dataset.serverHref = control.getAttribute('href') || '';
        }
        control.href = target;
        const text = control.querySelector('span');
        const label = String(from.label || '').trim();
        if (text) {
          if (label) text.textContent = `返回${label}`;
          // 名字是上一页自己的标题，只有就地换页时才拿得到。整页加载时服务端已经
          // 按同一个来处把名字画对了——除非它落在服务端不认识的路由上，那时说
          // 「上一页」也比指着首页却写着别的名字诚实。
          else if (control.dataset.serverHref !== target) text.textContent = '返回上一页';
        }
        control.dataset.backOrigin = from.canPop === true ? 'history' : 'link';
      };
      const adoptOriginState = () => {
        if (!window.history.state?.medialibFrom) {
          const referrer = sameOriginReferrer();
          if (referrer) {
            try {
              window.history.replaceState({
                ...(window.history.state || {}),
                medialibFrom: { href: referrer.href, label: '', canPop: true }
              }, '');
            } catch (_) { /* ignore */ }
          }
        }
        renderBackControl();
      };
      // 后退键回到来处，比重新走一遍链接多一样东西：读者原来的滚动位置。地址
      // 仍然是真链接，中键、复制、深链一律照旧。
      //
      // ★ 必须是捕获阶段，而且要在下面那个统一的链接拦截器之前注册。同一个
      // document 上，捕获永远先于冒泡：注册成冒泡监听的话，链接拦截器早就把这
      // 一次点击 `preventDefault()` 掉并当成一次普通前进导航压进历史了——「返回」
      // 会多压一条记录，读者的滚动位置也就丢了。这里先 `preventDefault()`，
      // 那个拦截器自己的 `event.defaultPrevented` 判断随后会让它让开。
      document.addEventListener('click', event => {
        if (!isPrimaryUnmodifiedClick(event) || event.defaultPrevented) return;
        const control = event.target?.closest?.('.app-back');
        if (!(control instanceof Element) || control.dataset.backOrigin !== 'history') return;
        const target = control.getAttribute('href') || '';
        if (!target.startsWith('/')) return;
        event.preventDefault();
        const before = window.location.href;
        window.history.back();
        // 后退没有落地（这一条历史记录已经不在了）时，链接本身仍然要生效。
        window.setTimeout(() => {
          if (window.location.href === before) assignNativeLocation(target);
        }, 600);
      }, { capture: true });
      window.addEventListener('medialib:pagedidload', renderBackControl);

      const pageCache = new Map();
      window.__medialibPageCache = pageCache;
      const maxPageCacheEntries = 24;
      const pageCacheLifetime = 60_000;
      // A page swap preserves this JavaScript realm while recreating the
      // page-specific library controller. Keep a tiny, short-lived cache of
      // already-authorized browse JSON in that realm so a sidebar pointerdown
      // can fetch the document and its first 24 cards in parallel. It is never
      // written to browser storage and is cleared after personal mutations.
      const libraryBrowseCache = (() => {
        const existing = window.__medialibLibraryBrowseCache;
        if (existing && typeof existing.get === 'function' && typeof existing.set === 'function' && typeof existing.clear === 'function') return existing;
        const created = new Map();
        window.__medialibLibraryBrowseCache = created;
        return created;
      })();
      const libraryBrowseCacheLifetime = 30_000;
      const maximumLibraryBrowseCacheEntries = 24;
      // 旧的 800ms 截止会在资料库查询稍慢时中止已经成功的渐进请求，再启动
      // 一次完整文档导航，结果既慢又像侧栏没有响应。保留明确的兜底，但给
      // 受限服务器检索和 DOM 替换足够时间；页面顶部进度条会立即反馈点击。
      const navigationFallbackDelay = 4_000;
      var navigationSerial = 0;
      var activeNavigationRequest = null;
      var navigationFallbackTimer = null;
      var navigationWarmTimer = null;
      var navigationWarmURL = '';
      // Touch browsers should keep a full-document location transition as the
      // source of truth. It is the most reliable path for swipe-back, captive
      // portals, sleeping tabs, and slow reverse proxies; progressive swaps are
      // an optimization for precise pointer/keyboard desktop navigation only.
      const prefersNativeNavigation = () => {
        try {
          return window.navigator?.maxTouchPoints > 0 || window.matchMedia('(pointer: coarse)').matches;
        } catch (_) {
          return false;
        }
      };
      const supportsProgressiveNavigation = () => {
        try {
          return typeof window.fetch === 'function'
            && typeof window.DOMParser === 'function'
            && typeof window.AbortController === 'function'
            && typeof window.history?.pushState === 'function'
            && typeof document.importNode === 'function'
            && typeof document.body?.replaceWith === 'function'
            && typeof document.documentElement?.classList?.add === 'function';
        } catch (_) {
          return false;
        }
      };
      // Each source declares whether it has a controller that can safely be
      // rebound after a document swap.  The previous attribute-only split
      // became stale as pages evolved: music routes were sometimes fetched as
      // a shell document but their controller never ran, leaving a blank main
      // area.  Keep the fast progressive path only for the known-safe catalog
      // surfaces; all other routes receive an immediate browser navigation.
      // `/category/{id}` is the library route — `/library` has not existed since
      // browsing became always-scoped, so listing it warmed and swapped a 404.
      // The category pages run the same `library.js` controller as `/search`
      // and friends, so they are safe on the same grounds.
      const catalogRoute = pathname => /^\/category\/[^/?#]+$/.test(pathname);
      // 远程来源分组下的每一行（「全部」与各资料库）走的也是 `library.js`，
      // 作用域 ID 是十六进制摘要。它此前完全不在名单里，于是侧栏里唯一能到达
      // 远程内容的那些链接每点一次都整页重载。智能集合与智能歌单同理：它们也是
      // 侧栏条目，也各自跑一个已知的页面控制器。
      const scopedCatalogRoute = pathname => /^\/remote\/[0-9a-f]{1,64}$/.test(pathname)
        || /^\/smart-collections\/[^/?#]+$/.test(pathname)
        || /^\/music\/playlists\/[^/?#]+$/.test(pathname);
      // 侧栏能到达的每一个目的地都必须在这里。
      //
      // 漏掉一个的后果不是"慢一点"：那条链接会退回整页加载，于是整个文档重建，
      // 侧栏展开的分组收回去、滚动位置回到顶端，正在放的音乐也断了。保险库、相册
      // 和音乐各页此前都不在名单里——点「保险库」侧栏就会刷新一次，正是这个原因。
      const progressiveRoutes = new Set([
        '/', '/index.html', '/search', '/watching', '/history',
        '/favorites', '/watchlist', '/ratings', '/watched', '/unwatched',
        '/people', '/collections', '/photos', '/albums', '/queue',
        '/account', '/vault', '/admin', '/admin/users', '/admin/sessions',
        '/admin/libraries', '/admin/playback', '/admin/network', '/admin/tasks',
        '/admin/storage', '/admin/security', '/admin/logs',
        '/music/songs', '/music/albums', '/music/artists', '/music/playlists', '/music/recent'
      ]);
      const supportsProgressiveRoute = pathname => catalogRoute(pathname)
        || scopedCatalogRoute(pathname) || progressiveRoutes.has(pathname);
      const knownNavigationRoutes = progressiveRoutes;
      const navigationRoutes = { has: pathname => catalogRoute(pathname)
        || scopedCatalogRoute(pathname) || knownNavigationRoutes.has(pathname) };
      // Detail and playback documents can include a large, media-specific
      // controller.  A browser-owned location change is both faster to start
      // and more reliable here: if the current document is under load, an
      // intercepted async swap used to wait for its four-second fallback,
      // making an episode card appear unresponsive.  Keep progressive swaps
      // for the lightweight shell/library routes, but never delay a play or
      // detail link behind that optimization.
      const nativeDetailRoute = pathname => /^\/(item|people|collections|photo)\/[^/]+$/.test(pathname)
        || /^\/series\/[^/]+(?:\/play)?$/.test(pathname);

      const isAnchorElement = node => {
        // Avoid instanceof here: embedded WebViews can expose DOM nodes from a
        // different realm, making an otherwise valid <a> fail the check.
        return node != null
          && typeof node.tagName === 'string'
          && node.tagName.toLowerCase() === 'a'
          && typeof node.href === 'string';
      };
      const eventAnchor = event => {
        const path = typeof event?.composedPath === 'function' ? event.composedPath() : [];
        const pathAnchor = path.find(isAnchorElement);
        if (pathAnchor) return pathAnchor;
        const target = event?.target;
        if (isAnchorElement(target)) return target;
        const closest = target?.closest?.('a[href]');
        return isAnchorElement(closest) ? closest : null;
      };
      const isPrimaryUnmodifiedClick = event => {
        return event != null
          && (event.button === undefined || event.button === 0)
          && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey;
      };

      const assignNativeLocation = href => {
        document.documentElement.classList.add('app-shell-navigating');
        try { window.location.assign(href); } catch (_) { window.location.href = href; }
      };

      const routeIsNavigable = (anchor, event) => {
        if (!isAnchorElement(anchor) || event?.defaultPrevented) return false;
        if (event && ((event.button !== undefined && event.button !== 0) || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) return false;
        if (anchor.target && anchor.target !== '_self') return false;
        if (anchor.hasAttribute('download')) return false;
        let url;
        try { url = new URL(anchor.href, window.location.href); } catch (_) { return false; }
        if (url.origin !== window.location.origin || url.hash) return false;
        if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/assets/')) return false;
        if (url.pathname === '/health' || url.pathname === '/.well-known/mlink') return false;
        // Playback/detail cards must retain their own browser document.  They
        // are not in the shell's progressive-route table, but still need to
        // pass through the single capture handler so a carousel's drag guard
        // cannot swallow a normal poster click.
        if (nativeDetailRoute(url.pathname)) return true;
        return navigationRoutes.has(url.pathname) && supportsProgressiveRoute(url.pathname);
      };

      // Some shell destinations deliberately require a browser-owned document
      // lifecycle: their controller binds long-lived media/image state after
      // `defer`, and an imported document leaves that controller inert in
      // embedded browsers.  The sidebar and music tabs mark those links
      // explicitly.  They must never enter the progressive-swap/four-second
      // fallback path; location assignment starts the real navigation now.
      const requiresNativeDocumentNavigation = anchor => {
        if (!anchor) return false;
        try {
          const url = new URL(anchor.href, window.location.href);
          // 详情与播放页始终整页加载：它们带着一个重的媒体控制器，浏览器自己发起
          // 的导航更快、也更可靠，而那里正是音乐该让位给视频的地方。
          if (nativeDetailRoute(url.pathname)) return true;
          // 其余在渐进白名单里的路由一律就地换文档，`data-native-navigation` 不再
          // 能把它们拉回整页加载。
          //
          // 那个属性原本是为了个别嵌入式浏览器里控制器绑定不牢而加的，但代价是每
          // 翻一页都重建整个文档：正在放的音乐会断，侧栏展开的分组会收回去、滚动
          // 位置回到顶端。常驻导航和正在播放的音频都不该跟着内容刷新，这两件事比
          // 那个边缘情况更要紧；渐进路径本来也会重新创建页面脚本。
          if (supportsProgressiveRoute(url.pathname)) return false;
          return anchor.hasAttribute?.('data-native-navigation') === true
            || navigationRoutes.has(url.pathname);
        } catch (_) { return anchor.hasAttribute?.('data-native-navigation') === true; }
      };

      const parsePage = async (url, signal, mayRefresh = true) => {
        const response = await fetch(url.href, {
          credentials: 'same-origin',
          cache: 'no-store',
          headers: { 'Accept': 'text/html' },
          signal
        });
        const contentType = response.headers.get('content-type') || '';
        if (!response.ok || !contentType.includes('text/html')) {
          if (mayRefresh && await window.__medialibRefreshSession?.()) return parsePage(url, signal, false);
          throw new Error('page-unavailable');
        }
        const contentLength = Number(response.headers.get('content-length'));
        if (Number.isFinite(contentLength) && contentLength > 2_000_000) throw new Error('page-too-large');
        const markup = await response.text();
        if (markup.length > 2_000_000) throw new Error('page-too-large');
        const documentFragment = new DOMParser().parseFromString(markup, 'text/html');
        if (!documentFragment.querySelector('.shell') || !documentFragment.querySelector('main')) {
          // An expired access cookie follows the normal 303 to the login document.
          // Renew via the narrowly scoped authentication API, then retry once.
          if (mayRefresh && await window.__medialibRefreshSession?.()) return parsePage(url, signal, false);
          throw new Error('not-authenticated-page');
        }
        if ([...documentFragment.scripts].some(script => !script.src && script.textContent.trim())) throw new Error('inline-script');
        if (documentFragment.querySelector('base')) throw new Error('base-element');
        const networkNodes = documentFragment.querySelectorAll('script[src],link[href],img[src],video[src],audio[src],source[src],track[src]');
        if ([...networkNodes].some(node => {
          const raw = node.getAttribute('src') || node.getAttribute('href') || '';
          try { return new URL(raw, url.href).origin !== window.location.origin; } catch (_) { return true; }
        })) throw new Error('cross-origin-asset');
        if ([...documentFragment.querySelectorAll('*')].some(element => [...element.attributes].some(attribute => {
          return attribute.name.toLowerCase().startsWith('on') || /^\s*javascript:/i.test(attribute.value);
        }))) throw new Error('inline-handler');
        return documentFragment;
      };

      const loadPage = (url) => {
        const key = url.href;
        const cached = pageCache.get(key);
        if (cached && cached.expiresAt > Date.now()) {
          // Promote a hot prefetched page to the newest cache entry so repeated
          // sidebar/detail hops do not evict the page the user is actually using.
          pageCache.delete(key);
          pageCache.set(key, cached);
          return cached.promise;
        }
        if (cached) {
          cached.controller.abort();
          pageCache.delete(key);
        }
        const controller = new AbortController();
        const entry = { promise: null, controller, expiresAt: Date.now() + pageCacheLifetime };
        const pending = parsePage(url, controller.signal).catch(() => {
          if (pageCache.get(key) === entry) pageCache.delete(key);
          return null;
        });
        entry.promise = pending;
        pageCache.set(key, entry);
        while (pageCache.size > maxPageCacheEntries) {
          const oldest = pageCache.keys().next().value;
          if (oldest === key || oldest === undefined) break;
          const oldestEntry = pageCache.get(oldest);
          oldestEntry?.controller.abort();
          pageCache.delete(oldest);
        }
        return pending;
      };

      // 这里拼出的 URL 必须与 library.js 首次请求的 URL **逐字**相同，否则预取
      // 只是白白发一次请求：命中与否没有任何可见迹象。两处的默认值一起改。
      const primeLibraryBrowse = url => {
        const allowedTypes = new Set(['movie', 'tvShow', 'anime', 'documentary', 'variety', 'homeVideo', 'music', 'other', 'episode', 'photo']);
        const scopedCategory = /^\/category\/([^/?#]+)$/.exec(url.pathname);
        // 远程来源分组下的行同样跑 `library.js`，作用域在路径里而不是查询串里。
        const scopedRemote = /^\/remote\/([0-9a-f]{1,64})$/.exec(url.pathname);
        if (!scopedCategory && !scopedRemote && !['/search', '/watching', '/history', '/favorites', '/watchlist', '/ratings', '/watched', '/unwatched'].includes(url.pathname)) return;
        var requestedType = url.searchParams.get('type') || '';
        var requestedGroup = url.searchParams.get('group') || '';
        if (scopedRemote) { requestedType = ''; requestedGroup = ''; }
        if (scopedCategory) {
          // 分类页的作用域在路径里。`/category/video` 是"全部视频"这个保留组。
          const identifier = decodeURIComponent(scopedCategory[1]);
          if (identifier === 'video') { requestedGroup = 'video'; requestedType = ''; }
          else { requestedType = identifier; requestedGroup = ''; }
        }
        if ((requestedType && !allowedTypes.has(requestedType)) || (requestedGroup && requestedGroup !== 'video') || (requestedType && requestedGroup)) return;
        const params = new URLSearchParams({ offset: '0', limit: '24', sort: url.pathname === '/history' ? 'lastPlayed' : 'recentlyUpdated' });
        if (requestedType) params.set('type', requestedType);
        if (requestedGroup) params.set('group', requestedGroup);
        // 顺序与 library.js 一致：type / group 之后、state / preference 之前。
        if (scopedRemote) params.set('remoteScope', scopedRemote[1]);
        if (url.pathname === '/watching') params.set('state', 'inProgress');
        if (url.pathname === '/history') params.set('state', 'history');
        if (url.pathname === '/watched') params.set('state', 'watched');
        if (url.pathname === '/unwatched') params.set('state', 'unwatched');
        if (url.pathname === '/favorites') params.set('preference', 'favorite');
        if (url.pathname === '/watchlist') params.set('preference', 'watchlist');
        if (url.pathname === '/ratings') params.set('preference', 'rated');
        const key = `/api/v1/library/browse?${params.toString()}`;
        const now = Date.now();
        const cached = libraryBrowseCache.get(key);
        if (cached && cached.expiresAt > now) return;
        libraryBrowseCache.delete(key);
        const controller = new AbortController();
        const timeout = window.setTimeout(() => controller.abort(), 8_000);
        const promise = fetch(key, {
          credentials: 'same-origin', cache: 'no-store',
          headers: { Accept: 'application/json' }, signal: controller.signal
        }).then(response => {
          const contentType = response.headers.get('content-type') || '';
          if (!response.ok || !contentType.includes('application/json')) throw new Error('browse-unavailable');
          return response.json();
        }).finally(() => window.clearTimeout(timeout));
        const entry = { expiresAt: now + libraryBrowseCacheLifetime, promise };
        libraryBrowseCache.set(key, entry);
        promise.catch(() => {
          if (libraryBrowseCache.get(key) === entry) libraryBrowseCache.delete(key);
        });
        while (libraryBrowseCache.size > maximumLibraryBrowseCacheEntries) {
          const oldest = libraryBrowseCache.keys().next().value;
          if (oldest === undefined) break;
          libraryBrowseCache.delete(oldest);
        }
      };

      const headResourceKey = node => {
        if (!(node instanceof Element)) return null;
        if (node.matches('link[rel~="stylesheet"][href]')) {
          try {
            const resourceURL = new URL(node.getAttribute('href'), window.location.href);
            return resourceURL.origin === window.location.origin ? `link:${resourceURL.href}` : null;
          } catch (_) { return null; }
        }
        if (node.matches('script[src]')) {
          try {
            const resourceURL = new URL(node.getAttribute('src'), window.location.href);
            return resourceURL.origin === window.location.origin ? `script:${resourceURL.href}` : null;
          } catch (_) { return null; }
        }
        return null;
      };

      // 换页的可见反馈此前只有顶部那条 2px 进度条：文档在一帧之内被整个换掉，
      // 读者看到的是一次硬切。View Transitions 让浏览器自己在旧帧与新帧之间做
      // 交叉淡入，代价是一个 `await`，且**只在浏览器支持时**发生——不支持的
      // 浏览器直接走原来的同步路径，行为一个字节都没变。
      //
      // `prefers-reduced-motion` 下跳过：这条策略是"替换"而不是"关掉"（见
      // base.css），但页面级的交叉淡入没有可替换的静态形态，它本身就是纯装饰。
      const withViewTransition = (swap) => {
        const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches === true;
        if (reduced || typeof document.startViewTransition !== 'function') return swap();
        return document.startViewTransition(swap).updateCallbackDone;
      };

      const replaceDocument = (nextDocument, url, scrollTarget = 0) => {
        document.dispatchEvent(new Event('medialib:pagewillunload'));
        const existingHeadResources = new Map(
          [...document.head.childNodes]
            .map(node => [headResourceKey(node), node])
            .filter(([key]) => key !== null)
        );
        const nextHead = [...nextDocument.head.childNodes].map(node => {
          const imported = document.importNode(node, true);
          const key = headResourceKey(imported);
          if (!key || !existingHeadResources.has(key)) return imported;
          const preserved = existingHeadResources.get(key);
          existingHeadResources.delete(key);
          return preserved;
        });
        const nextBody = document.importNode(nextDocument.body, true);
        // 侧栏不跟着页面重建。
        //
        // 整个 <body> 被换掉时，侧栏也会被换成新文档里那一份——于是展开的分组会
        // collapse 回去、滚动位置回到顶端，读者每翻一页就要重新把「视频」展开、
        // 重新滚到刚才那个分类。它是常驻导航，本来就不该跟着内容刷新。
        //
        // 做法是把**活着的那个节点**搬进新 body，再从新文档里只取两样会变的东西：
        // 当前页标记，和分类计数。其余（展开状态、滚动位置、焦点）原样保留。
        //
        // ★ 但只在两份侧栏的**结构相同**时这样做。
        //
        // 这个补丁循环遍历的是活着那份的链接，只更新两份里都有的 href；新文档里
        // 新增的条目（远程来源分组、智能集合、智能歌单）被整个丢掉，随后
        // `incomingSidebar.replaceWith(liveSidebar)` 又把新 markup 扔了。于是一份
        // 在落地页画错/画少的侧栏，在整个会话里再也修不回来——正文换了、侧栏没换，
        // 看起来就是"刷新之后本地数据正常，Emby 目录还是不出现"。
        //
        // 结构不同时改为采用新侧栏，再把状态搬回去：分组展开状态按 summary 文本
        // 对应（href 在 <summary> 上没有，分组标题才是它的身份），滚动位置照旧。
        const liveSidebar = document.querySelector('.app-sidebar');
        const incomingSidebar = nextBody.querySelector('.app-sidebar');
        // 展开状态与滚动位置只在这一处取一次，两条分支和整页加载共用同一份状态
        // 描述——它同时也是写进 sessionStorage、供下一次整页加载认领的那一份。
        const sidebarState = captureSidebarState(liveSidebar);
        var keptLiveSidebar = false;
        if (liveSidebar && incomingSidebar) {
          const sidebarSignature = sidebar => [...sidebar.querySelectorAll('a[href]')]
            .map(link => link.getAttribute('href')).join('\n');
          if (sidebarSignature(liveSidebar) === sidebarSignature(incomingSidebar)) {
            const incomingLinks = new Map();
            incomingSidebar.querySelectorAll('a[href]').forEach(link => {
              incomingLinks.set(link.getAttribute('href'), {
                current: link.hasAttribute('aria-current'),
                count: link.querySelector('.nav-count')?.textContent ?? null
              });
            });
            liveSidebar.querySelectorAll('a[href]').forEach(link => {
              const next = incomingLinks.get(link.getAttribute('href'));
              if (!next) return;
              if (next.current) link.setAttribute('aria-current', 'page');
              else link.removeAttribute('aria-current');
              const badge = link.querySelector('.nav-count');
              if (badge && next.count !== null) badge.textContent = next.count;
            });
            incomingSidebar.replaceWith(liveSidebar);
            keptLiveSidebar = true;
          } else {
            // 结构不同（远程来源分组、智能集合、智能歌单增减了条目）时采用新
            // markup，再把读者的展开状态搬回去；服务端标成当前的那一组照旧展开。
            applySidebarState(incomingSidebar, sidebarState);
          }
        }
        document.head.replaceChildren(...nextHead);
        document.body.replaceWith(nextBody);
        // 搬动节点会把滚动位置清零，等它真正落到新 body 里之后再放回去。
        const settledSidebar = keptLiveSidebar ? liveSidebar : document.querySelector('.app-sidebar');
        if (settledSidebar && sidebarState) settledSidebar.scrollTop = sidebarState.scrollTop;
        if (sidebarState) writeStoredJSON(sidebarStateKey, sidebarState);
        synchronizeDrawerAccessibility();
        document.title = nextDocument.title;
        window.__medialibEnsureAudioDock?.();

        // Imported script nodes are inert. Recreate only same-origin external
        // scripts so each page's controller can bind to its new DOM.
        [...document.querySelectorAll('script[src]')].forEach(source => {
          let scriptURL;
          try { scriptURL = new URL(source.src, window.location.href); } catch (_) { source.remove(); return; }
          if (scriptURL.origin !== window.location.origin) { source.remove(); return; }
          if (window.__medialibNavigationInstalled === true && scriptURL.pathname === '/assets/app-shell.js') return;
          const executable = document.createElement('script');
          executable.src = scriptURL.href;
          executable.async = false;
          executable.defer = false;
          source.replaceWith(executable);
        });

        document.documentElement.classList.remove('app-shell-navigating');
        // 前进是一页新内容，从顶部开始；后退是回到读者刚才那一页，位置也该跟着
        // 回来。浏览器自己的滚动恢复对就地换页无能为力——它在内容到达之前就跑完了。
        window.scrollTo({ top: scrollTarget, left: 0, behavior: 'auto' });
        const main = document.querySelector('#main');
        if (main instanceof HTMLElement) main.focus({ preventScroll: true });
        adoptArtwork(document.body);
        // The swap replaced `<main>`, so anything watching its children — the
        // section entrance observer among them — has to be told to look again.
        window.dispatchEvent(new Event('medialib:pagedidload'));
        void url;
      };

      const navigate = (url, replace = false) => {
        const requestSerial = ++navigationSerial;
        // 来处要在地址变掉之前记下来。后退（replace）时地址早已是目标页，那一次
        // 的来处存在被恢复的 history.state 里，不该由这里覆写。
        const origin = replace ? null : currentOrigin();
        // 兜底的整页加载不需要额外交接：浏览器会把当前地址作为 `Referer` 发出去，
        // 服务端和新文档都从那里读到同一个来处。
        const escapeToNativeNavigation = () => window.location.assign(url.href);
        document.documentElement.classList.add('app-shell-navigating');
        activeNavigationRequest?.abort();
        const pendingPage = loadPage(url);
        activeNavigationRequest = pageCache.get(url.href)?.controller ?? null;
        if (navigationFallbackTimer !== null) window.clearTimeout(navigationFallbackTimer);
        navigationFallbackTimer = window.setTimeout(() => {
          if (requestSerial !== navigationSerial) return;
          activeNavigationRequest?.abort();
          escapeToNativeNavigation();
        }, navigationFallbackDelay);
        pendingPage.then(nextDocument => {
          if (requestSerial !== navigationSerial) return;
          if (!nextDocument) {
            document.documentElement.classList.remove('app-shell-navigating');
            escapeToNativeNavigation();
            return;
          }
          var scrollTarget = 0;
          if (replace) {
            scrollTarget = Number(window.history.state?.medialibScroll) || 0;
            window.history.replaceState(window.history.state ?? {}, '', url.href);
          } else {
            // 离开之前把这一页的滚动位置钉在它自己那条历史记录上，按下后退键
            // 时才能连位置一起回来。
            try {
              window.history.replaceState(
                { ...(window.history.state || {}), medialibScroll: Math.round(window.scrollY) }, ''
              );
            } catch (_) { /* ignore */ }
            window.history.pushState({ medialibFrom: origin }, '', url.href);
          }
          try {
            withViewTransition(() => {
              replaceDocument(nextDocument, url, scrollTarget);
              renderBackControl();
            });
          } catch (_) {
            // A browser that cannot import/replace the parsed document must
            // still navigate; never leave a pressed link with a frozen shell.
            document.documentElement.classList.remove('app-shell-navigating');
            escapeToNativeNavigation();
          }
        }).finally(() => {
          if (requestSerial === navigationSerial) {
            if (navigationFallbackTimer !== null) window.clearTimeout(navigationFallbackTimer);
            navigationFallbackTimer = null;
            activeNavigationRequest = null;
          }
        });
      };

      // 不在鼠标掠过时预取完整认证页面：长侧栏会产生一串资料库查询，反而让
      // 用户真正点击的页面排队。按下时仍立即启动目标请求，保留点击前的抢跑收益。
      document.addEventListener('pointerdown', event => {
        if (event.button !== 0) return;
        if (prefersNativeNavigation() || !supportsProgressiveNavigation()) return;
        const anchor = eventAnchor(event);
        // 详情页与播放页交给浏览器自己导航，预取的那一份文档没有任何人会用到
        // ——纯粹让服务器把最重的一类页面渲染两遍。
        if (!routeIsNavigable(anchor) || requiresNativeDocumentNavigation(anchor)) return;
        try {
          const url = new URL(anchor.href, window.location.href);
          void loadPage(url);
          primeLibraryBrowse(url);
        } catch (_) { /* ignore */ }
      }, { passive: true, capture: true });

      // Pointer-down has the smallest possible overhead, but a deliberate
      // desktop sidebar hover can hide nearly all document latency.  Warm only
      // after a short intent delay, never on touch or a data-saving/slow
      // connection, and reuse the bounded cache used by click navigation.
      // This keeps the old "do not prefetch every fly-over" guarantee while
      // making the common pause-then-click navigation path feel immediate.
      const canWarmNavigation = event => {
        if (event?.pointerType && event.pointerType !== 'mouse') return false;
        if (prefersNativeNavigation() || !supportsProgressiveNavigation()) return false;
        const connection = window.navigator?.connection;
        return connection?.saveData !== true && !['slow-2g', '2g'].includes(connection?.effectiveType || '');
      };
      const cancelNavigationWarm = () => {
        if (navigationWarmTimer !== null) window.clearTimeout(navigationWarmTimer);
        navigationWarmTimer = null;
        navigationWarmURL = '';
      };
      const scheduleNavigationWarm = (anchor, event) => {
        if (!canWarmNavigation(event) || !routeIsNavigable(anchor)) return;
        if (requiresNativeDocumentNavigation(anchor)) return;
        let url;
        try { url = new URL(anchor.href, window.location.href); } catch (_) { return; }
        if (url.href === navigationWarmURL) return;
        cancelNavigationWarm();
        navigationWarmURL = url.href;
        navigationWarmTimer = window.setTimeout(() => {
          navigationWarmTimer = null;
          if (navigationWarmURL !== url.href) return;
          void loadPage(url);
          primeLibraryBrowse(url);
        }, 140);
      };
      document.addEventListener('pointerover', event => {
        const anchor = eventAnchor(event);
        const previous = event.relatedTarget?.closest?.('a[href]');
        if (anchor && anchor === previous) return;
        scheduleNavigationWarm(anchor, event);
      }, { passive: true, capture: true });
      document.addEventListener('pointerout', event => {
        const anchor = eventAnchor(event);
        if (!anchor || event.relatedTarget?.closest?.('a[href]') === anchor) return;
        cancelNavigationWarm();
      }, { passive: true, capture: true });
      document.addEventListener('focusin', event => {
        const anchor = eventAnchor(event);
        if (!anchor) return;
        scheduleNavigationWarm(anchor, { pointerType: 'mouse' });
      }, { capture: true });

      // Capture before page-specific controllers so a nested button/card handler
      // cannot swallow a sidebar item, content card, or breadcrumb link. Desktop
      // precision pointers use one progressive path for every app route. The
      // 4s native-location deadline remains the escape hatch: if a WebView
      // cannot fetch/parse/replace a page, its genuine href still wins quickly.
      // Touch/coarse pointers and incomplete WebViews keep browser-owned
      // navigation to preserve swipe-back and avoid preventDefault-with-no-result.
      document.addEventListener('click', event => {
        const anchor = eventAnchor(event);
        if (!routeIsNavigable(anchor, event)) return;
        if (requiresNativeDocumentNavigation(anchor)) {
          event.preventDefault();
          assignNativeLocation(anchor.href);
          return;
        }
        // On touch/coarse pointers, use an explicit full-document navigation.
        // Relying on a synthesized click's default action is unreliable in
        // embedded WebViews and some mobile Safari versions (the link can show
        // press feedback yet leave the page unchanged). A normal location
        // assignment preserves the browser's history/back behavior while
        // guaranteeing that every proxied content link has a visible route
        // transition.
        if (prefersNativeNavigation() || !supportsProgressiveNavigation()) {
          event.preventDefault();
          assignNativeLocation(anchor.href);
          return;
        }
        event.preventDefault();
        try { navigate(new URL(anchor.href, window.location.href)); } catch (_) { window.location.assign(anchor.href); }
      }, { capture: true });

      window.addEventListener('popstate', () => {
        try { navigate(new URL(window.location.href), true); } catch (_) { window.location.reload(); }
      });

      // 落地时认领来处：整页加载的那些页面走的是这条路。
      adoptOriginState();

      // ---- Section entrance --------------------------------------------------
      // Sections arrive as they come into view rather than all at once on load.
      // Deliberately once-only and short: a block that re-animates every time it
      // scrolls past is a distraction, not a flourish. Only `transform` and
      // `opacity` move, and the whole thing is skipped outright under reduced
      // motion — where the substitution is simply "already in place".
      const revealSections = () => {
        if (window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches) return;
        if (typeof window.IntersectionObserver !== 'function') return;
        const main = document.getElementById('main');
        if (!main) return;
        // Only blocks the server rendered whole.  A container the page fills
        // asynchronously (the media grid) is zero-height when the observer
        // starts, never reaches a positive intersection ratio, and would sit at
        // opacity 0 forever — an empty page where the content had in fact
        // arrived.
        const blocks = Array.from(main.querySelectorAll('.ui-section, .home-stats, .ui-control-bar'))
          .filter(block => !block.dataset.revealed);
        if (blocks.length === 0) return;
        const reveal = (block, rank) => {
          if (block.dataset.revealed === 'true') return;
          block.dataset.revealed = 'true';
          // Cap the stagger: with a tall viewport a dozen blocks can enter in
          // one callback, and half a second of queued delay reads as lag.
          block.style.setProperty('--reveal-delay', `${Math.min(rank, 4) * 40}ms`);
          block.classList.add('is-revealed');
        };
        const observer = new window.IntersectionObserver((entries, self) => {
          let rank = 0;
          for (const entry of entries) {
            if (!entry.isIntersecting) continue;
            self.unobserve(entry.target);
            reveal(entry.target, rank);
            rank += 1;
          }
        }, { rootMargin: '0px 0px -8% 0px', threshold: 0 });
        for (const block of blocks) {
          block.dataset.revealed = '';
          block.classList.add('will-reveal');
          observer.observe(block);
        }
        // Failsafe. An entrance effect must never be able to leave content
        // permanently invisible, whatever the observer does or does not report.
        window.setTimeout(() => {
          observer.disconnect();
          for (const block of blocks) reveal(block, 0);
        }, 1_200);
      };
      revealSections();
      // Progressive navigation swaps `<main>`, so the new document's blocks need
      // observing too.
      window.addEventListener('medialib:pagedidload', revealSections);
    })();
    """#
}
