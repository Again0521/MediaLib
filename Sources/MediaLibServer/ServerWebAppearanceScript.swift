import Foundation

/// The appearance (light / dark / auto) controller.
///
/// It is deliberately a separate, render-blocking asset loaded before any
/// stylesheet: the stored choice must be stamped onto `<html>` before the first
/// paint, or a visitor who picked dark gets a white flash on every navigation.
/// The page CSP forbids inline scripts, so this cannot be folded into the
/// document.
///
/// **Storage policy.** This is the only place in the browser bundle that touches
/// `localStorage`, and it reads and writes exactly one key holding one of three
/// literal words.  No token, session, identifier, library, path or any other user
/// data is stored client-side — `app-shell.js` and every page script remain
/// storage-free, and the tests assert that.
enum ServerWebAppearanceScript {
    static let script = #"""
    (function () {
      'use strict';

      var STORAGE_KEY = 'medialib-appearance';
      var MODES = ['auto', 'light', 'dark'];
      var root = document.documentElement;

      // Storage can be unavailable outright (private browsing, blocked cookies,
      // a sandboxed frame).  Appearance is an enhancement, so every access is
      // guarded and failure silently falls back to the system preference.
      function readStoredMode() {
        try {
          var value = window.localStorage.getItem(STORAGE_KEY);
          return MODES.indexOf(value) === -1 ? 'auto' : value;
        } catch (error) {
          return 'auto';
        }
      }

      function persistMode(mode) {
        try {
          if (mode === 'auto') window.localStorage.removeItem(STORAGE_KEY);
          else window.localStorage.setItem(STORAGE_KEY, mode);
        } catch (error) {
          /* Non-fatal: the choice simply will not survive this navigation. */
        }
      }

      function paint(mode) {
        if (mode === 'light' || mode === 'dark') root.setAttribute('data-theme', mode);
        else root.removeAttribute('data-theme');
      }

      var currentMode = readStoredMode();
      paint(currentMode);

      function apply(mode) {
        if (MODES.indexOf(mode) === -1) mode = 'auto';
        currentMode = mode;
        persistMode(mode);
        paint(mode);
        try {
          document.dispatchEvent(new CustomEvent('medialib:appearancechange', { detail: { mode: mode } }));
        } catch (error) {
          /* CustomEvent is universally available; the guard costs nothing. */
        }
      }

      window.__medialibAppearance = {
        get: function () { return currentMode; },
        set: apply,
        modes: MODES.slice()
      };
    })();
    """#
}
