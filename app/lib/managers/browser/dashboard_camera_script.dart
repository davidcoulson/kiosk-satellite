/// Releases supported Home Assistant dashboard camera players while covered.
/// Rendering an empty Lit template disconnects the players through their own
/// lifecycle, closing WebRTC and HLS connections. Restoring the template creates
/// fresh players. The page's visibility, microphone and other media stay live.
///
/// An emptied player collapses to nothing, which reads as a broken card rather
/// than a paused one. So a released camera keeps the card's shape and shows its
/// last still, blurred and dimmed: recognisably that camera, plainly not live.
/// The still is a single snapshot fetched once, not a stream, so the decode
/// budget the pause exists to protect is not spent again.
const dashboardCameraScript = r'''
(function () {
  if (window.__ksDashboardCameras || !window.customElements) return;
  var paused = false;
  var ready = false;
  var watched = new WeakSet();
  var patched = new WeakSet();
  var STILL_ID = 'ks-camera-still';

  function refresh(root) {
    root.querySelectorAll('*').forEach(function (el) {
      if (el.localName === 'ha-camera-stream' &&
          typeof el.requestUpdate === 'function') el.requestUpdate();
      if (el.shadowRoot) refresh(el.shadowRoot);
    });
  }

  window.__ksDashboardCameras = {
    setPaused: function (value) {
      watchRegistry();
      value = !!value;
      if (paused === value) return;
      paused = value;
      if (ready) refresh(document);
    },
    get paused() { return paused; },
    get supported() { return ready; }
  };

  // The snapshot Home Assistant already serves for this camera: one JPEG,
  // fetched once and then held, rather than a stream that keeps decoding.
  function stillUrl(el) {
    try {
      var attrs = el.stateObj && el.stateObj.attributes;
      var url = attrs && attrs.entity_picture;
      return typeof url === 'string' && url ? url : null;
    } catch (e) { return null; }
  }

  // Keep the shape the live player had, so releasing a stream does not
  // collapse the card and reflow every card around it.
  function aspectRatio(el) {
    try {
      var attrs = el.stateObj && el.stateObj.attributes;
      var w = Number(attrs && attrs.width);
      var h = Number(attrs && attrs.height);
      if (w > 0 && h > 0) return w + ' / ' + h;
    } catch (e) {}
    return '16 / 9';
  }

  function paintStill(el) {
    try {
      var root = el.shadowRoot;
      if (!root || typeof root.appendChild !== 'function') return;
      if (typeof document.createElement !== 'function') return;
      if (root.getElementById && root.getElementById(STILL_ID)) return;
      var still = document.createElement('div');
      still.id = STILL_ID;
      still.setAttribute('aria-hidden', 'true');
      // The scale pushes the blur's soft edge outside the clipped host, so
      // the still reaches the card's borders instead of fading out before
      // them. Blur and dim together are what say "held", not "broken".
      still.style.cssText =
          'position:absolute;inset:0;pointer-events:none;' +
          'background:#0d0f12 center/cover no-repeat;' +
          'transform:scale(1.12);' +
          'filter:blur(7px) saturate(0.55) brightness(0.62);';
      var url = stillUrl(el);
      if (url) still.style.backgroundImage = 'url("' + url + '")';
      root.appendChild(still);
    } catch (e) {}
  }

  function showStill(el) {
    try {
      if (el.style) {
        el.style.display = 'block';
        el.style.position = 'relative';
        el.style.overflow = 'hidden';
        el.style.aspectRatio = aspectRatio(el);
      }
      // Lit clears the shadow root as it renders the empty template, so the
      // still goes in once that has finished rather than before it.
      var rendered = el.updateComplete;
      if (rendered && typeof rendered.then === 'function') {
        rendered.then(function () { paintStill(el); });
      } else {
        paintStill(el);
      }
    } catch (e) {}
  }

  function clearStill(el) {
    try {
      if (el.style) {
        el.style.display = '';
        el.style.position = '';
        el.style.overflow = '';
        el.style.aspectRatio = '';
      }
      var root = el.shadowRoot;
      var still = root && root.getElementById && root.getElementById(STILL_ID);
      if (still && typeof still.remove === 'function') still.remove();
    } catch (e) {}
  }

  function install(ctor) {
    var proto = ctor && ctor.prototype;
    if (!proto || patched.has(proto)) return;
    var render = proto.render;
    if (typeof render !== 'function') return;
    patched.add(proto);
    proto.render = function () {
      // Keep intentional camera audio playing. Only HA's camera component
      // in this dashboard document is affected, including newly added streams.
      if (paused && this.muted === true && this.isConnected &&
          document.querySelector('home-assistant')) {
        // Removing an MJPEG image alone can leave its HTTP request running.
        if (this.shadowRoot) {
          this.shadowRoot.querySelectorAll('img').forEach(function (img) {
            img.removeAttribute('src');
          });
        }
        showStill(this);
        return null;
      }
      clearStill(this);
      return render.apply(this, arguments);
    };
    ready = true;
    if (paused) refresh(document);
  }

  function watchRegistry() {
    var registry = window.customElements;
    if (!registry || watched.has(registry)) return;
    watched.add(registry);
    registry.whenDefined('ha-camera-stream').then(function (ctor) {
      install(ctor || registry.get('ha-camera-stream'));
    });
  }

  // HA can replace the native registry with its scoped registry polyfill
  // after document-start injection. Its definitions never resolve promises
  // on the old registry, so subscribe again once the frontend has loaded.
  watchRegistry();
  document.addEventListener('DOMContentLoaded', watchRegistry, { once: true });
  window.addEventListener('load', watchRegistry, { once: true });
})();
''';

String pauseDashboardCamerasJs(bool paused) =>
    'window.__ksDashboardCameras && '
    'window.__ksDashboardCameras.setPaused($paused);';
