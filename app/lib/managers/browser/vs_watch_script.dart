/// Document-start script that reports a Voice Satellite session that died
/// and did not come back.
///
/// [reconnectHaSocket] repairs everything riding the Home Assistant socket
/// without a reload, and the socket watchdog hears a close the instant it
/// happens. Neither helps here: after Home Assistant restarts, the page's own
/// socket reconnects fine — `hass.connected` goes true, entity state flows —
/// while the Voice Satellite engine's separate subscription does not
/// re-register. The satellite entity sits `unavailable` with a perfectly
/// healthy page around it, so nothing the app already watches can see it. On
/// 16 Sept a restart left one panel dead for 35 minutes until it was reloaded
/// by hand, and another took 29 minutes to recover on its own.
///
/// Only a reload re-runs the engine, so this reports and [BrowserManager]
/// decides, under the same auto-reload setting and rate limit as every other
/// self-initiated reload.
///
/// A session that failed to start counts, not just one that died after
/// running. The engine starts against `hass.states` before the frontend has
/// filled it in and throws — "Native wake handoff failed: Cannot read
/// properties of null" — and then never registers, which is how .145 sat
/// unavailable inside a page whose socket was fine. Requiring the satellite
/// to have been seen alive first would disarm this watcher for exactly the
/// case it exists to repair: a page that loaded into a failed start has
/// never seen it alive, and a reload is what fixes it.
///
/// Three guards keep it from reloading a panel that is working as intended:
///
///  - the engine has to be loaded. A panel whose bundle is deliberately
///    trimmed away (no rule forwarding `voice-satellite-card`) never defines
///    the element, its satellite is unavailable forever by design, and a
///    watcher without this guard would reload it every cooldown until
///    someone noticed;
///  - reloads are capped per tab. Since a never-started session now counts,
///    the attempt count rides in `sessionStorage` so it survives the reloads
///    it is counting. A panel a reload cannot fix gives up instead of
///    cycling forever, and the count resets the moment the satellite is
///    seen alive;
///  - Home Assistant has to be connected. A dead socket is the socket
///    watchdog's job, and reloading underneath it would race its repair.
const voiceSatelliteWatchScript = '''
(function () {
  if (window.__ksVsWatch) return;
  var CHECK_MS = 15000;
  var DOWN_MS = 60000;
  var MAX_RELOADS = 3;
  var COUNT_KEY = 'ks-vs-reloads';
  var S = { downSince: 0, reported: false, entity: null };
  window.__ksVsWatch = S;

  // Per tab, not per page: the count has to outlive the reloads it counts.
  function attempts() {
    try {
      return parseInt(window.sessionStorage.getItem(COUNT_KEY), 10) || 0;
    } catch (e) { return 0; }
  }

  function setAttempts(n) {
    try {
      if (n) window.sessionStorage.setItem(COUNT_KEY, '' + n);
      else window.sessionStorage.removeItem(COUNT_KEY);
    } catch (e) {}
  }

  function satelliteEntity() {
    if (S.entity) return S.entity;
    try {
      var raw = window.localStorage.getItem('vs-panel-config');
      if (!raw) return null;
      var id = JSON.parse(raw).satellite_entity;
      if (typeof id === 'string' && id) S.entity = id;
    } catch (e) {}
    return S.entity;
  }

  function engineLoaded() {
    try {
      return !!(window.customElements &&
                window.customElements.get('voice-satellite-card'));
    } catch (e) { return false; }
  }

  function check() {
    try {
      if (!engineLoaded()) return;
      var id = satelliteEntity();
      if (!id) return;
      var ha = document.querySelector('home-assistant');
      var hass = ha && ha.hass;
      if (!hass || !hass.states) return;
      // A dead socket belongs to the socket watchdog, not here.
      if (hass.connected === false) { S.downSince = 0; return; }
      var entry = hass.states[id];
      var state = entry && entry.state;
      if (!state) return;

      if (state !== 'unavailable') {
        // A working session clears the budget for the next outage.
        S.downSince = 0;
        S.reported = false;
        setAttempts(0);
        return;
      }
      if (S.reported) return;
      // A panel a reload cannot repair stops asking rather than cycling.
      var tries = attempts();
      if (tries >= MAX_RELOADS) return;
      var now = Date.now();
      if (!S.downSince) { S.downSince = now; return; }
      if (now - S.downSince < DOWN_MS) return;
      S.reported = true;
      setAttempts(tries + 1);
      try {
        window.flutter_inappwebview.callHandler(
            'ksVoiceSatelliteDown', id, Math.round((now - S.downSince) / 1000));
      } catch (e) {}
    } catch (e) {}
  }

  setInterval(check, CHECK_MS);
})();
''';
