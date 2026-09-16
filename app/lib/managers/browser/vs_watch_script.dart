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
/// Three guards keep it from reloading a panel that is working as intended:
///
///  - the engine has to be loaded. A panel whose bundle is deliberately
///    trimmed away (no rule forwarding `voice-satellite-card`) never defines
///    the element, its satellite is unavailable forever by design, and a
///    watcher without this guard would reload it every cooldown until
///    someone noticed;
///  - the satellite has to have been alive once on this page. A session that
///    never started is not a session that died, and is not repaired by a
///    reload;
///  - Home Assistant has to be connected. A dead socket is the socket
///    watchdog's job, and reloading underneath it would race its repair.
const voiceSatelliteWatchScript = '''
(function () {
  if (window.__ksVsWatch) return;
  var CHECK_MS = 15000;
  var DOWN_MS = 60000;
  var S = { seenAlive: false, downSince: 0, reported: false, entity: null };
  window.__ksVsWatch = S;

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
        S.seenAlive = true;
        S.downSince = 0;
        S.reported = false;
        return;
      }
      // Unavailable from the first sample is a session that never started.
      if (!S.seenAlive || S.reported) return;
      var now = Date.now();
      if (!S.downSince) { S.downSince = now; return; }
      if (now - S.downSince < DOWN_MS) return;
      S.reported = true;
      try {
        window.flutter_inappwebview.callHandler(
            'ksVoiceSatelliteDown', id, Math.round((now - S.downSince) / 1000));
      } catch (e) {}
    } catch (e) {}
  }

  setInterval(check, CHECK_MS);
})();
''';
