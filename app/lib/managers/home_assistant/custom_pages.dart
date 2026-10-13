import 'dart:convert';

// Custom pages: a person's own HTML files in Home Assistant's `www`
// folder, which Home Assistant serves at `/local/` on its own origin.
//
// Being on the dashboard's origin is what makes them simple to host here.
// The page shares the dashboard's localStorage, so the session auto-login
// seeds (`hassTokens`) signs a `home-assistant-js-websocket` page in with
// no token in its code. Every origin rule the kiosk applies to the
// dashboard (links, the secure context proxy, a base URL change) covers
// the page too.
//
// A page is stored by its path ("/local/kitchen.html", optionally with a
// query and a fragment) and navigated to by that path without its leading
// slash, the same shape as a dashboard view path. The dashboard lists show
// the pages as one more dashboard on [customPagesDashboardPath], so every
// dashboard picker, the rotation and the ESPHome selects offer them.

/// The url_path the pages are listed under. Home Assistant requires a
/// hyphen in the url_path of a dashboard someone adds and none of its own
/// panels is named this, so no real dashboard can take it.
const customPagesDashboardPath = 'local';

/// The icon every page wears in the pickers: a window with code in it.
const customPageIcon = 'mdi:application-brackets-outline';

/// The icon of the Custom Pages entry in the dashboard list and of its
/// settings page, the same window.
const customPagesIcon = 'mdi:application-brackets-outline';

/// One page the person added.
class CustomPage {
  const CustomPage({required this.name, required this.path});

  final String name;

  /// "/local/kitchen.html#lights": always under /local/.
  final String path;

  /// The navigation path, "local/kitchen.html#lights".
  String get navPath => path.substring(1);

  /// What follows "/local/", the page's route inside the Custom Pages
  /// dashboard.
  String get route => path.substring('/local/'.length);

  Map<String, Object?> toJson() => {'name': name, 'path': path};
}

/// The pages stored in the `ha.custom_pages` setting, in their order.
/// Anything malformed is skipped rather than failing the whole list.
List<CustomPage> parseCustomPages(String raw) {
  try {
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    final pages = <CustomPage>[];
    for (final e in list) {
      if (e is! Map) continue;
      final name = '${e['name'] ?? ''}'.trim();
      final path = normalizeCustomPagePath('${e['path'] ?? ''}');
      if (name.isEmpty || path == null) continue;
      if (pages.any((p) => p.path == path)) continue;
      pages.add(CustomPage(name: name, path: path));
    }
    return pages;
  } catch (_) {
    return const [];
  }
}

String encodeCustomPages(List<CustomPage> pages) =>
    jsonEncode([for (final p in pages) p.toJson()]);

/// [input] as a stored page path ("/local/kitchen.html") or null when it
/// names nothing under /local/. Takes the path as typed ("/local/a.html",
/// "local/a.html" or a bare "a.html") or a whole URL pasted from a
/// browser, whose origin is dropped: the page is always loaded from the
/// Home Assistant base URL.
String? normalizeCustomPagePath(String input) {
  var text = input.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s|\\'))) return null;
  if (text.contains('://')) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority) return null;
    text =
        uri.path +
        (uri.hasQuery ? '?${uri.query}' : '') +
        (uri.hasFragment ? '#${uri.fragment}' : '');
  }
  // An absolute path names its folder, which has to be /local/. A bare
  // file name is taken as one in it.
  final absolute = text.startsWith('/');
  text = text.replaceFirst(RegExp(r'^/+'), '');
  if (text.startsWith('local/')) {
    text = text.substring('local/'.length);
  } else if (absolute) {
    return null;
  }
  final cut = text.indexOf(RegExp('[?#]'));
  final file = cut < 0 ? text : text.substring(0, cut);
  if (file.isEmpty || file.startsWith('/') || file.endsWith('/')) return null;
  if (file.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    return null;
  }
  return '/local/$text';
}

/// Whether a navigation path ("local/kitchen.html") names a custom page
/// rather than a dashboard view.
bool isCustomPagePath(String navPath) =>
    navPath.startsWith('$customPagesDashboardPath/');

/// The navigation path a URL's path names: the path without its slashes,
/// plus the query and the fragment for a custom page, where they pick a
/// layout of the person's own page. A dashboard view keeps the path alone,
/// since Home Assistant navigates by it.
String navPathOfUri(Uri uri) {
  final path = uri.path.replaceAll(RegExp(r'^/+|/+$'), '');
  if (!isCustomPagePath(path)) return path;
  return path +
      (uri.hasQuery ? '?${uri.query}' : '') +
      (uri.hasFragment && uri.fragment.isNotEmpty ? '#${uri.fragment}' : '');
}

/// The page's file, its path without the fragment: what Home Assistant
/// serves and the validation asks for.
String customPageFile(String path) {
  final cut = path.indexOf('#');
  return cut < 0 ? path : path.substring(0, cut);
}
