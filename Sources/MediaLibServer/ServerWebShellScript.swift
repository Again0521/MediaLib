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
        let refreshPromise = null;
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
        window.fetch = async (input, init) => {
          let request;
          try {
            request = typeof window.Request === 'function' && input instanceof window.Request && init === undefined
              ? input
              : new window.Request(input, init);
          } catch (_) {
            return nativeFetch(input, init);
          }
          const response = await nativeFetch(request);
          if (response.status !== 401 && !isLoginRedirect(response, request)) return response;
          if (!isRefreshableRequest(request)) return response;
          if (!await refreshSession()) return response;
          try { return await nativeFetch(request.clone()); } catch (_) { return response; }
        };
        window.__medialibFetchInstalled = true;
      }
      if (window.__medialibNavigationInstalled === true) return;
      window.__medialibNavigationInstalled = true;
      document.documentElement.classList.add('app-shell-ready');

      const pageCache = new Map();
      const maxPageCacheEntries = 32;
      const prefetchTimers = new WeakMap();
      let navigationSerial = 0;
      let activeNavigationRequest = null;
      let navigationFallbackTimer = null;
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
      const navigationRoutes = new Set([
        '/', '/index.html', '/library', '/search', '/watching', '/history',
        '/favorites', '/watchlist', '/ratings', '/watched', '/unwatched',
        '/people', '/collections', '/photos', '/queue', '/status', '/account',
        '/admin', '/sources'
      ]);

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
      const isSidebarNavigation = anchor => {
        return isAnchorElement(anchor) && anchor.hasAttribute('data-native-navigation');
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
        // Sidebar links are handled by the explicit capture-phase location
        // assignment below. They must not enter the progressive fetch/history
        // path, because a partial WebView implementation can otherwise leave
        // the shell visually pressed while the route stays unchanged.
        if (isSidebarNavigation(anchor)) return false;
        if (event && ((event.button !== undefined && event.button !== 0) || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) return false;
        if (anchor.target && anchor.target !== '_self') return false;
        if (anchor.hasAttribute('download')) return false;
        let url;
        try { url = new URL(anchor.href, window.location.href); } catch (_) { return false; }
        if (url.origin !== window.location.origin || url.hash) return false;
        if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/assets/')) return false;
        if (url.pathname === '/health' || url.pathname === '/.well-known/mlink') return false;
        if (navigationRoutes.has(url.pathname)) return true;
        return /^\/(item|series|people|collections|photo)\/[^/]+$/.test(url.pathname);
      };

      const parsePage = async (url, signal) => {
        const response = await fetch(url.href, {
          credentials: 'same-origin',
          cache: 'no-store',
          headers: { 'Accept': 'text/html' },
          signal
        });
        const contentType = response.headers.get('content-type') || '';
        if (!response.ok || !contentType.includes('text/html')) throw new Error('page-unavailable');
        const contentLength = Number(response.headers.get('content-length'));
        if (Number.isFinite(contentLength) && contentLength > 2_000_000) throw new Error('page-too-large');
        const markup = await response.text();
        if (markup.length > 2_000_000) throw new Error('page-too-large');
        const documentFragment = new DOMParser().parseFromString(markup, 'text/html');
        if (!documentFragment.querySelector('.shell') || !documentFragment.querySelector('main')) throw new Error('not-authenticated-page');
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
        if (cached) {
          // Promote a hot prefetched page to the newest cache entry so repeated
          // sidebar/detail hops do not evict the page the user is actually using.
          pageCache.delete(key);
          pageCache.set(key, cached);
          return cached.promise;
        }
        const controller = new AbortController();
        const pending = parsePage(url, controller.signal).catch(() => {
          pageCache.delete(key);
          return null;
        });
        pageCache.set(key, { promise: pending, controller });
        while (pageCache.size > maxPageCacheEntries) {
          const oldest = pageCache.keys().next().value;
          if (oldest === key || oldest === undefined) break;
          const oldestEntry = pageCache.get(oldest);
          oldestEntry?.controller.abort();
          pageCache.delete(oldest);
        }
        return pending;
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

      const replaceDocument = (nextDocument, url) => {
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
        document.head.replaceChildren(...nextHead);
        document.body.replaceWith(nextBody);
        document.title = nextDocument.title;

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
        window.scrollTo({ top: 0, left: 0, behavior: 'auto' });
        const main = document.querySelector('#main');
        if (main instanceof HTMLElement) main.focus({ preventScroll: true });
        void url;
      };

      const navigate = (url, replace = false) => {
        const requestSerial = ++navigationSerial;
        document.documentElement.classList.add('app-shell-navigating');
        activeNavigationRequest?.abort();
        const pendingPage = loadPage(url);
        activeNavigationRequest = pageCache.get(url.href)?.controller ?? null;
        if (navigationFallbackTimer !== null) window.clearTimeout(navigationFallbackTimer);
        navigationFallbackTimer = window.setTimeout(() => {
          if (requestSerial !== navigationSerial) return;
          activeNavigationRequest?.abort();
          window.location.assign(url.href);
        }, 1800);
        pendingPage.then(nextDocument => {
          if (requestSerial !== navigationSerial) return;
          if (!nextDocument) {
            document.documentElement.classList.remove('app-shell-navigating');
            window.location.assign(url.href);
            return;
          }
          if (replace) window.history.replaceState({}, '', url.href);
          else window.history.pushState({}, '', url.href);
          try {
            replaceDocument(nextDocument, url);
          } catch (_) {
            // A browser that cannot import/replace the parsed document must
            // still navigate; never leave a pressed link with a frozen shell.
            document.documentElement.classList.remove('app-shell-navigating');
            window.location.assign(url.href);
          }
        }).finally(() => {
          if (requestSerial === navigationSerial) {
            if (navigationFallbackTimer !== null) window.clearTimeout(navigationFallbackTimer);
            navigationFallbackTimer = null;
            activeNavigationRequest = null;
          }
        });
      };

      document.addEventListener('pointerover', event => {
        const anchor = eventAnchor(event);
        if (!routeIsNavigable(anchor)) return;
        if (prefetchTimers.has(anchor)) window.clearTimeout(prefetchTimers.get(anchor));
        const timer = window.setTimeout(() => {
          try { void loadPage(new URL(anchor.href, window.location.href)); } catch (_) { /* ignore */ }
        }, 80);
        prefetchTimers.set(anchor, timer);
      }, { passive: true });

      document.addEventListener('pointerdown', event => {
        if (event.button !== 0) return;
        const anchor = eventAnchor(event);
        if (!routeIsNavigable(anchor)) return;
        try { void loadPage(new URL(anchor.href, window.location.href)); } catch (_) { /* ignore */ }
      }, { passive: true, capture: true });

      document.addEventListener('touchstart', event => {
        const anchor = eventAnchor(event);
        if (!routeIsNavigable(anchor)) return;
        try { void loadPage(new URL(anchor.href, window.location.href)); } catch (_) { /* ignore */ }
      }, { passive: true });

      // Capture before page-specific controllers so a nested button/card handler
      // cannot swallow a content card or breadcrumb link. Sidebar anchors are
      // handled here with an explicit same-origin location assignment. This
      // keeps sidebar switching reliable in WebViews that expose anchors but
      // swallow their default navigation after a script-driven page swap.
      document.addEventListener('click', event => {
        const anchor = eventAnchor(event);
        if (isSidebarNavigation(anchor)) {
          if (!isPrimaryUnmodifiedClick(event)) return;
          event.preventDefault();
          assignNativeLocation(anchor.href);
          return;
        }
        if (!routeIsNavigable(anchor, event)) return;
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
    })();
    """#
}
