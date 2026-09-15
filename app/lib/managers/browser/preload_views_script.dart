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
  // Walks the whole view config rather than the card types and the four
  // lists a built-in layout happens to use.
  //
  // The first version of this matched `type` against "camera" and recursed
  // through cards/sections/badges/elements. It missed the shape that
  // actually costs something: a `picture-entity` card whose *entity* is a
  // `camera.*`, sitting inside a custom layout that keeps its children
  // somewhere other than `cards`. On the basement panel that view was
  // preloaded, two ha-web-rtc-players started, and they kept decoding for a
  // view nobody was looking at -- 181% of four cores, against 6% with them
  // stopped, on the slowest panel in the fleet.
  //
  // So: any key at any depth, and a camera is a `camera.` entity id, a
  // camera_image/camera_view key, or a card type that says camera. Depth
  // limited because a config is data and data can be cyclic.
  function hasCamera(node, depth) {
    try {
      if (!node || typeof node !== 'object') return false;
      if (depth > 24) return true;  // too deep to be sure: skip the view
      var keys = Object.keys(node);
      for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        if (k === 'camera_image' || k === 'camera_view') return true;
        var v = node[k];
        if (typeof v === 'string') {
          if (v.indexOf('camera.') === 0) return true;
          if (k === 'type' && v.indexOf('camera') !== -1) return true;
        } else if (v && typeof v === 'object') {
          if (hasCamera(v, depth + 1)) return true;
        }
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
      if (hasCamera(views[i], 0)) continue;
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
