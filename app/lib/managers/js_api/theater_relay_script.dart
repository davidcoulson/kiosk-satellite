/// Relays theater mode calls from a page in a frame, for a dashboard that
/// frames the theater panel's web app (a Home Assistant Webpage dashboard):
/// Voice Satellite has to run in Home Assistant's own page, so the theater
/// page sits inside it rather than replacing it.
///
/// The bridge stays main-frame only (kiosk_screen.dart), because a frame
/// with the bridge could open the microphone. Instead this main-frame script
/// takes `postMessage` requests from a direct child frame and asks the app,
/// through `theaterRelay`, naming the frame's origin as the browser reported
/// it. The app answers only for theater methods and only for the origin in
/// the "Page allowed from a frame" setting; everything else is refused
/// there, not here. A frame the app accepted is then sent
/// `kiosksatellite:theatermode` events, again only at its own origin.
///
/// The framed page's side of it:
///   request  {ksTheater: 1, id, method, params}   to window.parent
///   reply    {ksTheater: 1, id, result}           null when refused
///   event    {ksTheater: 1, event: 'theatermode', detail}
/// with params in the bridge's form: setTheaterMode {active, ...options},
/// theaterPeek {seconds}. See docs/theater.md.
///
/// Spliced into the kioskSatellite script, where `call` is in scope.
const theaterRelayScript = r'''
  (function () {
    // Never let the relay take the rest of the facade down with it.
    if (typeof window.addEventListener !== 'function') return;
    var methods = { setTheaterMode: 1, getTheaterMode: 1, theaterPeek: 1 };
    var accepted = [];
    function reply(source, origin, message) {
      try { source.postMessage(message, origin); } catch (e) {}
    }
    window.addEventListener('message', function (e) {
      var d = e.data;
      if (!d || typeof d !== 'object' || d.ksTheater !== 1 || d.event) return;
      var source = e.source;
      if (!source || source === window) return;
      // A direct child only: not a frame that frame embeds.
      try { if (source.parent !== window) return; } catch (err) { return; }
      if (!Object.prototype.hasOwnProperty.call(methods, d.method)) {
        reply(source, e.origin, { ksTheater: 1, id: d.id, result: null });
        return;
      }
      var params = d.params && typeof d.params === 'object' ? d.params : {};
      call('theaterRelay', {
        frameOrigin: e.origin,
        method: d.method,
        params: params,
      }).then(function (r) {
        var ok = !!(r && typeof r === 'object' && r.accepted === true);
        if (ok) {
          var known = false;
          for (var i = 0; i < accepted.length; i++) {
            if (accepted[i].source === source) known = true;
          }
          if (!known) accepted.push({ source: source, origin: e.origin });
        }
        reply(source, e.origin, {
          ksTheater: 1,
          id: d.id,
          result: ok ? r.result : null,
        });
      });
    });
    window.addEventListener('kiosksatellite:theatermode', function (ev) {
      accepted = accepted.filter(function (f) {
        try { return !f.source.closed && f.source.parent === window; }
        catch (err) { return false; }
      });
      for (var i = 0; i < accepted.length; i++) {
        reply(accepted[i].source, accepted[i].origin, {
          ksTheater: 1,
          event: 'theatermode',
          detail: ev.detail,
        });
      }
    });
  })();
''';
