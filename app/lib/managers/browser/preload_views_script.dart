/// Builds every view of the current dashboard once, at idle, so the first
/// switch to each is as fast as the second.
///
/// hui-root caches the view elements it has built (`_viewCache`, the same
/// cache the carousel mounts its neighbor previews from), so a revisit is
/// a swap of an element that already exists. The cost is entirely in the
/// FIRST visit to each view in a page's life, and it is not small on a
/// wall panel: measured on a px30 panel over a three-view dashboard, the
/// first switch took 1060ms and 232ms while every later one took 9ms.
///
/// So this walks the unbuilt views once and comes back. Nothing here
/// makes a switch faster than HA already makes it -- it moves the cost off
/// the moment someone is watching and into the seconds after a load, when
/// nobody is.
///
/// <h2>Why it navigates rather than building elements directly</h2>
///
/// Building a `hui-view` without navigating means constructing the element
/// and populating `_viewCache` the way `_selectView` does, against HA
/// internals that are not ours. Navigating uses HA's own path, so a
/// frontend release that changes how views are built changes this with
/// it. The cost of that choice is that the views really do appear on
/// screen while the walk runs, which is what the cover is for.
///
/// <h2>The cover</h2>
///
/// A fixed overlay painted in the theme's own background color sits over
/// the page for the duration, so the walk reads as part of the load rather
/// than as the dashboard flickering by itself. It is removed on the way
/// out, and by a watchdog regardless -- a cover that outlived a thrown
/// accessor would leave the panel showing a blank rectangle, which is far
/// worse than a slow first switch.
///
/// <h2>What it skips</h2>
///
/// Views whose config carries a camera card: building one starts its
/// stream, and a preload that quietly opens every camera on the panel
/// would spend bandwidth and battery on views nobody asked to see.
/// Already-cached views are skipped too -- on a rotation kiosk most of
/// them are warm within a cycle anyway.
library;

const preloadViewsScript = '''
(function () {
  if (window.__ksPreloadRan) return;

  var START_DELAY_MS = 4000;   // after the dashboard exists: let it settle
  var READY_MS = 60000;        // how long to wait for a dashboard at all
  var PER_VIEW_MS = 6000;      // give up on one view
  var TOTAL_MS = 25000;        // watchdog: cover never outlives this
  var SETTLE_MS = 250;         // between views, so each build stands alone

  function huiRoot() {
    try {
      var ha = document.querySelector('home-assistant');
      var main = ha && ha.shadowRoot &&
        ha.shadowRoot.querySelector('home-assistant-main');
      var panel = main && main.shadowRoot &&
        main.shadowRoot.querySelector('ha-panel-lovelace');
      return (panel && panel.shadowRoot &&
        panel.shadowRoot.querySelector('hui-root')) || null;
    } catch (e) { return null; }
  }

  // A camera anywhere in a view's cards, including nested inside the
  // stack and grid cards people actually build dashboards out of.
  function hasCamera(node) {
    try {
      if (!node || typeof node !== 'object') return false;
      var t = node.type;
      if (typeof t === 'string' && t.indexOf('camera') !== -1) return true;
      var lists = [node.cards, node.sections, node.badges, node.elements];
      for (var i = 0; i < lists.length; i++) {
        var l = lists[i];
        if (!l || !l.length) continue;
        for (var j = 0; j < l.length; j++) if (hasCamera(l[j])) return true;
      }
      return false;
    } catch (e) { return true; }  // unreadable: treat as camera, skip it
  }

  function cover() {
    var el = document.createElement('div');
    var bg = '';
    try {
      bg = getComputedStyle(document.body).backgroundColor;
    } catch (e) {}
    if (!bg || bg === 'transparent' || bg.indexOf('rgba(0, 0, 0, 0)') === 0) {
      bg = '#000';
    }
    el.style.cssText =
      'position:fixed;inset:0;z-index:2147483646;background:' + bg + ';' +
      'pointer-events:none;';
    (document.body || document.documentElement).appendChild(el);
    return el;
  }

  function run() {
    if (window.__ksPreloadRan) return;
    var hr = huiRoot();
    if (!hr) return;                      // not a lovelace page
    var views;
    try { views = hr.lovelace.config.views || []; } catch (e) { return; }
    if (!views.length || views.length < 2) return;

    var base = (location.pathname.split('/')[1] || '');
    if (!base) return;
    var home = location.pathname;

    function cached(i) {
      try { return !!(hr._viewCache && hr._viewCache[i]); } catch (e) { return false; }
    }

    var todo = [];
    for (var i = 0; i < views.length; i++) {
      if (cached(i)) continue;
      if (hasCamera(views[i])) continue;
      todo.push({ i: i, path: views[i].path == null ? String(i) : views[i].path });
    }
    if (!todo.length) return;

    window.__ksPreloadRan = true;
    var shade = cover();
    var done = false;
    function finish() {
      if (done) return;
      done = true;
      try {
        if (location.pathname !== home) {
          history.pushState(null, '', home);
          window.dispatchEvent(new CustomEvent('location-changed'));
        }
      } catch (e) {}
      // One frame on the original view before revealing it, so the
      // uncover never shows the last preloaded view instead.
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          if (shade && shade.parentNode) shade.parentNode.removeChild(shade);
        });
      });
    }
    setTimeout(finish, TOTAL_MS);

    function walk(n) {
      if (done) return;
      if (n >= todo.length) return finish();
      var v = todo[n];
      var t0 = Date.now();
      try {
        history.pushState(null, '', '/' + base + '/' + v.path);
        window.dispatchEvent(new CustomEvent('location-changed'));
      } catch (e) { return finish(); }
      (function poll() {
        if (done) return;
        if (cached(v.i) || Date.now() - t0 > PER_VIEW_MS) {
          return setTimeout(function () { walk(n + 1); }, SETTLE_MS);
        }
        requestAnimationFrame(poll);
      })();
    }
    walk(0);
  }

  // hui-root does not exist at load: the frontend authenticates, opens its
  // websocket and builds the panel first, and on a low-end panel that is
  // seconds after the load event -- checking once and giving up is why the
  // first cut of this never ran. Poll for the dashboard, then wait out the
  // settle delay so the first view is done before anything else is built.
  function schedule() {
    if (!window.__ksPreloadViews) return;   // flag-gated, like the carousel
    var giveUp = Date.now() + READY_MS;
    (function waitForDashboard() {
      var hr = huiRoot();
      var ready = false;
      try { ready = !!(hr && hr.lovelace && hr.lovelace.config); } catch (e) {}
      if (ready) return setTimeout(run, START_DELAY_MS);
      if (Date.now() > giveUp) return;      // never a lovelace page
      setTimeout(waitForDashboard, 500);
    })();
  }

  if (document.readyState === 'complete') schedule();
  else window.addEventListener('load', schedule);
})();
''';
