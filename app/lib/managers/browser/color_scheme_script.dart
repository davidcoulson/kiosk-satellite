/// Makes a page's `prefers-color-scheme` answer with the dashboard's light
/// or dark state instead of Android's (issue #907).
///
/// Music Assistant's Auto theme (its default) resolves light or dark through
/// `window.matchMedia('(prefers-color-scheme: dark)')`, for both its Vuetify
/// theme and its Tailwind `dark` class, and listens on that query for
/// changes. The WebView answers from the app's own night mode, which knows
/// nothing about a theme scheduled or pinned for the dashboard. So at
/// document start, color-scheme queries get a stand-in list that matches
/// [dark], and every other query goes to the real `matchMedia`.
///
/// [colorSchemeSetJs] flips the state live: each stand-in list whose answer
/// changed fires `change`, which is how the page's own listeners pick up an
/// OS switch at sunset.
///
/// CSS `@media (prefers-color-scheme)` rules are out of reach, which only
/// touches Music Assistant's login page. A theme set to Light or Dark inside
/// Music Assistant never asks, so it keeps its own choice.
String colorSchemeJs({required bool dark}) {
  return '''
    (function () {
      if (window.__ksSetDark || typeof window.matchMedia !== 'function') {
        return;
      }
      var dark = $dark;
      var native = window.matchMedia.bind(window);
      var lists = [];
      var scheme = /prefers-color-scheme\\s*:\\s*(dark|light)/i;
      window.matchMedia = function (query) {
        var m = scheme.exec(String(query));
        if (!m) return native(query);
        var want = m[1].toLowerCase() === 'dark';
        var list = new EventTarget();
        Object.defineProperty(list, 'media', { value: String(query) });
        Object.defineProperty(list, 'matches', {
          get: function () { return dark === want; },
        });
        list.onchange = null;
        list.addListener = function (fn) {
          list.addEventListener('change', fn);
        };
        list.removeListener = function (fn) {
          list.removeEventListener('change', fn);
        };
        lists.push(list);
        return list;
      };
      window.__ksSetDark = function (next) {
        if (next === dark) return;
        dark = next;
        lists.forEach(function (list) {
          var ev = new Event('change');
          ev.matches = list.matches;
          ev.media = list.media;
          list.dispatchEvent(ev);
          if (typeof list.onchange === 'function') list.onchange(ev);
        });
      };
    })();
  ''';
}

/// Flips the state [colorSchemeJs] installed. A no-op on a page without it.
String colorSchemeSetJs({required bool dark}) =>
    'window.__ksSetDark && window.__ksSetDark($dark);';
