import Foundation

/// Shared overlay and feedback behaviour: toasts, menus, dialogs and the
/// appearance control.
///
/// It is loaded on every authenticated page alongside `app-shell.js`.  All DOM is
/// built with `createElement`/`textContent`; nothing here parses HTML, reads
/// storage, or touches cookies.
enum ServerWebOverlayScript {
    static let script = #"""
    (function () {
      'use strict';
      if (window.__medialibOverlaysInstalled) return;
      window.__medialibOverlaysInstalled = true;

      var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)');

      /* ------------------------------------------------------------------ *
       * Toasts
       *
       * The region is a polite live region that never takes focus: stealing it
       * mid-task is more disruptive than the message is useful.  Errors stay on
       * screen longer than confirmations because they usually need a decision.
       * ------------------------------------------------------------------ */

      var TONE_ICONS = {
        success: 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17Zm-3.8 8.7 2.7 2.7 5-5.4',
        error: 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17ZM9.2 9.2l5.6 5.6M14.8 9.2l-5.6 5.6',
        info: 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17Zm0 7.5v5.5m0-8.7h.01'
      };

      function toneIcon(tone) {
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '2');
        svg.setAttribute('stroke-linecap', 'round');
        svg.setAttribute('stroke-linejoin', 'round');
        svg.setAttribute('aria-hidden', 'true');
        var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('d', TONE_ICONS[tone] || TONE_ICONS.info);
        svg.appendChild(path);
        return svg;
      }

      function toastRegion() {
        var region = document.getElementById('ui-toast-region');
        if (region) return region;
        region = document.createElement('div');
        region.id = 'ui-toast-region';
        region.className = 'ui-toast-region';
        region.setAttribute('role', 'status');
        region.setAttribute('aria-live', 'polite');
        document.body.appendChild(region);
        return region;
      }

      function dismiss(toast) {
        if (!toast || toast.dataset.leaving === 'true') return;
        toast.dataset.leaving = 'true';
        var remove = function () { if (toast.parentNode) toast.remove(); };
        if (reduceMotion && reduceMotion.matches) remove();
        else window.setTimeout(remove, 200);
      }

      function showToast(message, options) {
        if (!message) return null;
        var settings = options || {};
        var tone = settings.tone === 'success' || settings.tone === 'error' ? settings.tone : 'info';
        var region = toastRegion();

        var toast = document.createElement('div');
        toast.className = 'ui-toast ui-toast-' + (tone === 'success' ? 'ok' : tone);
        toast.appendChild(toneIcon(tone));

        var body = document.createElement('div');
        body.className = 'ui-toast-body';
        body.textContent = message;
        toast.appendChild(body);

        var close = document.createElement('button');
        close.type = 'button';
        close.className = 'ui-btn ui-btn-ghost ui-btn-icon ui-btn-sm';
        close.setAttribute('aria-label', '关闭');
        close.textContent = '×';
        close.addEventListener('click', function () { dismiss(toast); });
        toast.appendChild(close);

        region.appendChild(toast);
        // Three concurrent messages is the point where they stop being read.
        while (region.children.length > 3) dismiss(region.firstElementChild);

        var life = typeof settings.duration === 'number' ? settings.duration : (tone === 'error' ? 6000 : 3800);
        if (life > 0) window.setTimeout(function () { dismiss(toast); }, life);
        return toast;
      }

      window.medialibToast = showToast;

      /* ------------------------------------------------------------------ *
       * Menus and popovers
       *
       * A menu is anchored to its trigger and scales out of the corner nearest
       * it, so the spatial relationship between the button pressed and the panel
       * that appeared is never ambiguous.
       * ------------------------------------------------------------------ */

      var openMenu = null;
      var openTrigger = null;

      function closeMenu() {
        if (!openMenu) return;
        var menu = openMenu;
        var trigger = openTrigger;
        openMenu = null;
        openTrigger = null;
        menu.hidden = true;
        if (trigger) trigger.setAttribute('aria-expanded', 'false');
      }

      function positionMenu(menu, trigger) {
        var bounds = trigger.getBoundingClientRect();
        var alignRight = bounds.left > window.innerWidth / 2;
        menu.style.setProperty('--ui-overlay-origin', alignRight ? 'top right' : 'top left');
        menu.hidden = false;
        var width = menu.offsetWidth;
        var left = alignRight ? bounds.right - width : bounds.left;
        left = Math.max(8, Math.min(left, window.innerWidth - width - 8));
        menu.style.left = Math.round(left + window.scrollX) + 'px';
        menu.style.top = Math.round(bounds.bottom + window.scrollY + 6) + 'px';
      }

      document.addEventListener('click', function (event) {
        var trigger = event.target.closest ? event.target.closest('[data-menu-trigger]') : null;
        if (trigger) {
          var menu = document.getElementById(trigger.getAttribute('data-menu-trigger'));
          if (!menu) return;
          event.preventDefault();
          var wasOpen = openMenu === menu;
          closeMenu();
          if (wasOpen) return;
          openMenu = menu;
          openTrigger = trigger;
          trigger.setAttribute('aria-expanded', 'true');
          positionMenu(menu, trigger);
          var first = menu.querySelector('.ui-menu-item');
          if (first) first.focus();
          return;
        }
        if (openMenu && !openMenu.contains(event.target)) closeMenu();
      });

      /* ------------------------------------------------------------------ *
       * Dialogs
       *
       * Focus is trapped while a dialog is up and restored to whatever opened it
       * on close, and Escape always works — a modal task must always have a way
       * out that does not require finding the button.
       * ------------------------------------------------------------------ */

      var FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';
      var openDialog = null;
      var dialogReturnFocus = null;

      function focusables(container) {
        return Array.prototype.filter.call(
          container.querySelectorAll(FOCUSABLE),
          function (node) { return node.offsetParent !== null || node === document.activeElement; }
        );
      }

      function openDialogElement(dialog) {
        if (!dialog || openDialog === dialog) return;
        closeDialog();
        openDialog = dialog;
        dialogReturnFocus = document.activeElement;
        dialog.hidden = false;
        document.body.dataset.dialogOpen = 'true';
        var candidates = focusables(dialog);
        (candidates[0] || dialog).focus();
      }

      function closeDialog() {
        if (!openDialog) return;
        openDialog.hidden = true;
        openDialog = null;
        delete document.body.dataset.dialogOpen;
        if (dialogReturnFocus && dialogReturnFocus.focus) dialogReturnFocus.focus();
        dialogReturnFocus = null;
      }

      window.medialibDialog = { open: openDialogElement, close: closeDialog };

      document.addEventListener('click', function (event) {
        var opener = event.target.closest ? event.target.closest('[data-dialog-open]') : null;
        if (opener) {
          event.preventDefault();
          openDialogElement(document.getElementById(opener.getAttribute('data-dialog-open')));
          return;
        }
        if (event.target.closest && event.target.closest('[data-dialog-close]')) {
          event.preventDefault();
          closeDialog();
        }
      });

      document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
          if (openMenu) { closeMenu(); if (openTrigger) openTrigger.focus(); return; }
          if (openDialog) { closeDialog(); return; }
        }
        if (event.key === 'Tab' && openDialog) {
          var candidates = focusables(openDialog);
          if (!candidates.length) return;
          var first = candidates[0];
          var last = candidates[candidates.length - 1];
          if (event.shiftKey && document.activeElement === first) {
            event.preventDefault();
            last.focus();
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault();
            first.focus();
          }
        }
      });

      /* ------------------------------------------------------------------ *
       * Appearance control
       * ------------------------------------------------------------------ */

      function syncAppearanceControl() {
        var api = window.__medialibAppearance;
        if (!api) return;
        var mode = api.get();
        var options = document.querySelectorAll('[data-appearance-mode]');
        for (var index = 0; index < options.length; index += 1) {
          var option = options[index];
          var selected = option.getAttribute('data-appearance-mode') === mode;
          option.setAttribute('aria-checked', selected ? 'true' : 'false');
          var input = option.querySelector('input');
          if (input) input.checked = selected;
        }
      }

      document.addEventListener('click', function (event) {
        var option = event.target.closest ? event.target.closest('[data-appearance-mode]') : null;
        if (!option || !window.__medialibAppearance) return;
        window.__medialibAppearance.set(option.getAttribute('data-appearance-mode'));
        syncAppearanceControl();
      });

      /* ------------------------------------------------------------------ *
       * Range inputs
       *
       * WebKit cannot paint a filled track from the value alone, so the filled
       * proportion is mirrored into a custom property the stylesheet reads.
       * ------------------------------------------------------------------ */

      function syncRange(input) {
        if (!input || input.type !== 'range') return;
        var min = Number(input.min || 0);
        var max = Number(input.max || 100);
        var span = max - min;
        var ratio = span > 0 ? ((Number(input.value) - min) / span) * 100 : 0;
        input.style.setProperty('--ui-slider-progress', Math.max(0, Math.min(100, ratio)) + '%');
      }

      document.addEventListener('input', function (event) {
        if (event.target && event.target.classList && event.target.classList.contains('ui-slider')) {
          syncRange(event.target);
        }
      });

      /* ------------------------------------------------------------------ *
       * Horizontal rails
       *
       * 每一条横向列表都该能拖、也该有翻页键。详情页的「艺术照」此前两样都没有：
       * 它是一个 `overflow-x: auto` 的容器，可是触控板横向滚动在这种窄条上很难
       * 触发，鼠标用户则完全没有办法——那一排图有一半是看不到的。
       *
       * 翻页键由脚本补出来，页面只要把轨道渲染出来就行：十几个货架各自去写两个
       * 按钮，迟早会有几个漏掉，样式也会各写各的。
       * ------------------------------------------------------------------ */
      var RAIL_SELECTOR = '.ui-shelf, .client-detail-stills, .client-detail-people, .client-detail-related, .ui-scroll-x';

      function makeRailButton(direction, label) {
        var button = document.createElement('button');
        button.type = 'button';
        button.className = 'ui-rail-step ui-rail-' + direction;
        button.setAttribute('aria-label', label);
        button.title = label;
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        // 瘦长的 viewBox：装在一条贯穿整排卡片的细长按钮里，方格图标看上去还是那个
        // 20px 的小尖角，把按钮加高根本看不出变化。
        svg.setAttribute('class', 'ui-rail-glyph');
        svg.setAttribute('viewBox', '0 0 24 64');
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '2');
        svg.setAttribute('stroke-linecap', 'round');
        svg.setAttribute('stroke-linejoin', 'round');
        svg.setAttribute('aria-hidden', 'true');
        var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('d', direction === 'previous' ? 'M17 6 6 32l11 26' : 'M7 6l11 26L7 58');
        path.setAttribute('vector-effect', 'non-scaling-stroke');
        svg.appendChild(path);
        button.appendChild(svg);
        return button;
      }

      function enhanceRail(track) {
        if (track.__medialibRail) return;
        track.__medialibRail = true;

        var frame = document.createElement('div');
        frame.className = 'ui-rail';
        track.parentNode.insertBefore(frame, track);
        frame.appendChild(track);
        var previous = makeRailButton('previous', '向前翻页');
        var next = makeRailButton('next', '向后翻页');
        frame.appendChild(previous);
        frame.appendChild(next);

        // 一屏一翻，留一点重叠让读者认得出接上的是哪一张。
        //
        // 位移自己用 rAF 补间，不用 `behavior: 'smooth'`：那个选项在部分内嵌浏览器
        // 里是空操作（`'auto'` 正常、`'smooth'` 完全不动），于是翻页键按下去什么也
        // 不发生，而且不报错——这正是最难查的一类"按钮坏了"。
        var tween = null;
        function page(direction) {
          var amount = Math.max(track.clientWidth - 96, 160);
          var from = track.scrollLeft;
          var maximum = track.scrollWidth - track.clientWidth;
          var to = Math.max(0, Math.min(maximum, from + direction * amount));
          if (tween) cancelAnimationFrame(tween);
          if (reduceMotion && reduceMotion.matches) { track.scrollLeft = to; return; }
          var started = 0;
          var duration = 320;
          function step(now) {
            if (!started) started = now;
            var progress = Math.min((now - started) / duration, 1);
            // ease-out cubic：起步快、收尾稳，和产品其它位移一致。
            var eased = 1 - Math.pow(1 - progress, 3);
            track.scrollLeft = from + (to - from) * eased;
            tween = progress < 1 ? requestAnimationFrame(step) : null;
          }
          tween = requestAnimationFrame(step);
        }
        previous.addEventListener('click', function () { page(-1); });
        next.addEventListener('click', function () { page(1); });

        // 到头就不再显示那一侧的按钮：一个按下去没有反应的箭头，比没有更让人
        // 怀疑是不是坏了。
        function sync() {
          var maximum = track.scrollWidth - track.clientWidth;
          var scrollable = maximum > 4;
          frame.classList.toggle('is-scrollable', scrollable);
          previous.hidden = !scrollable || track.scrollLeft <= 2;
          next.hidden = !scrollable || track.scrollLeft >= maximum - 2;
        }
        track.addEventListener('scroll', sync, { passive: true });
        if (window.ResizeObserver) new ResizeObserver(sync).observe(track);
        sync();

        // 指针拖动。10px 的判定阈值之内不算拖，卡片的点击照常生效。
        var drag = null;
        track.addEventListener('pointerdown', function (event) {
          if (event.pointerType === 'touch') return;   // 触摸交给原生滚动
          if (event.button !== 0) return;
          drag = { id: event.pointerId, startX: event.clientX, startScroll: track.scrollLeft, moved: false };
        });
        track.addEventListener('pointermove', function (event) {
          if (!drag || drag.id !== event.pointerId) return;
          var delta = event.clientX - drag.startX;
          if (!drag.moved && Math.abs(delta) < 10) return;
          if (!drag.moved) {
            drag.moved = true;
            track.setPointerCapture(event.pointerId);
            frame.classList.add('is-dragging');
          }
          track.scrollLeft = drag.startScroll - delta;
        });
        function endDrag(event) {
          if (!drag || drag.id !== event.pointerId) return;
          var moved = drag.moved;
          drag = null;
          frame.classList.remove('is-dragging');
          if (moved) {
            // 拖完手指抬起来那一下不该顺便打开一张卡片。
            track.addEventListener('click', function (click) {
              click.preventDefault();
              click.stopPropagation();
            }, { capture: true, once: true });
          }
        }
        track.addEventListener('pointerup', endDrag);
        track.addEventListener('pointercancel', endDrag);
      }

      function initialise() {
        syncAppearanceControl();
        var ranges = document.querySelectorAll('.ui-slider');
        for (var index = 0; index < ranges.length; index += 1) syncRange(ranges[index]);
        var rails = document.querySelectorAll(RAIL_SELECTOR);
        for (var railIndex = 0; railIndex < rails.length; railIndex += 1) enhanceRail(rails[railIndex]);
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initialise);
      } else {
        initialise();
      }
      // The shell swaps documents in place, so re-bind after every navigation.
      document.addEventListener('medialib:pagewillunload', function () { closeMenu(); closeDialog(); });
      window.addEventListener('pageshow', initialise);
    })();
    """#
}
