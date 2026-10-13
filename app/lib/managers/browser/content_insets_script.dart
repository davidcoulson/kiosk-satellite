/// The space plugins asked the dashboard to keep clear, handed to the page
/// as CSS, in CSS pixels.
///
/// Home Assistant pads its views, dialogs, toasts and sidebar by its
/// `--safe-area-inset-*` variables, which read `--app-safe-area-inset-*`
/// first, the hook its own apps use (src/resources/theme/main.globals.ts).
/// Setting those reserves the space in the page itself: the view background
/// runs under a translucent bar, the last cards scroll clear of it, and the
/// WebView never resizes. `max()` keeps a punch-hole camera's own inset on
/// the cutout modes that avoid it. Other pages, custom pages among them,
/// read `--ks-content-inset-*`.
///
/// A style element rather than the root's style attribute, so nothing the
/// page writes there can clear it. Before the head exists it goes on the
/// root, where it applies just the same, and before the root exists the
/// script waits for it.
String contentInsetsJs({
  required double left,
  required double top,
  required double right,
  required double bottom,
}) {
  // Tenths of a pixel, and never negative or not a number.
  String px(double value) => value.isFinite && value > 0
      ? ((value * 10).round() / 10).toString()
      : '0';
  return '''
(function apply(insets) {
  var root = document.documentElement;
  // At document start the root element may not exist yet.
  if (!root) {
    var wait = new MutationObserver(function () {
      if (!document.documentElement) return;
      wait.disconnect();
      apply(insets);
    });
    wait.observe(document, {childList: true});
    return;
  }
  var style = document.getElementById('ks-content-insets');
  var rules = [];
  ['left', 'top', 'right', 'bottom'].forEach(function (side, i) {
    var value = insets[i];
    rules.push('--ks-content-inset-' + side + ':' + value + 'px');
    if (value > 0) {
      rules.push('--app-safe-area-inset-' + side +
        ':max(env(safe-area-inset-' + side + ', 0px), ' + value + 'px)');
    }
  });
  var css = ':root{' + rules.join(';') + '}';
  if (!style) {
    if (css === ':root{--ks-content-inset-left:0px;--ks-content-inset-top:0px;--ks-content-inset-right:0px;--ks-content-inset-bottom:0px}') return;
    style = document.createElement('style');
    style.id = 'ks-content-insets';
    root.appendChild(style);
  }
  if (style.textContent !== css) style.textContent = css;
})([${px(left)}, ${px(top)}, ${px(right)}, ${px(bottom)}]);
''';
}
