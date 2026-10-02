/// What `navigate` should do with a requested URL (NAV-1).
sealed class NavigationDecision {
  const NavigationDecision();
}

/// Refuse it: a scheme the main view never loads, or nothing usable.
class NavigationRefused extends NavigationDecision {
  const NavigationRefused(this.reason);
  final String reason;
}

/// Only the fragment differs from the page showing: change location.hash in
/// place. No reload, so a page's live connection (theater-panel's event
/// stream, Home Assistant's websocket) survives the move.
class NavigationHash extends NavigationDecision {
  const NavigationHash(this.fragment);

  /// Without the leading '#'.
  final String fragment;
}

/// Load it in the main view.
class NavigationLoad extends NavigationDecision {
  const NavigationLoad(this.url);
  final String url;
}

/// Decides what navigating the main view to [requested] means, given the
/// page showing now at [current].
///
/// [requested] is an absolute http(s) URL, or a path or fragment beginning
/// with '/' or '#', resolved against [current]. Every other scheme --
/// javascript:, file:, data:, intent: and the rest -- is refused: this is an
/// entry point Home Assistant and the remote API can reach, and none of those
/// is a page.
///
/// [mapUrl] is the secure-context proxy's mapping, applied to an absolute
/// URL before comparing, since the page showing may be the proxied loopback
/// form of the very host [requested] names.
NavigationDecision decideNavigation(
  String requested,
  String current, {
  String Function(String url)? mapUrl,
}) {
  final raw = requested.trim();
  if (raw.isEmpty) return const NavigationRefused('no URL');

  final base = Uri.tryParse(current);
  final Uri target;
  if (raw.startsWith('#') || raw.startsWith('/')) {
    if (base == null || !base.hasScheme) {
      return const NavigationRefused('nothing loaded to resolve against');
    }
    // A leading '//' would be a host, not a path.
    if (raw.startsWith('//')) {
      return const NavigationRefused('a path must not begin with //');
    }
    target = base.resolve(raw);
  } else {
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        !(parsed.scheme == 'http' || parsed.scheme == 'https') ||
        parsed.host.isEmpty) {
      return NavigationRefused(
        'only http(s) URLs, paths and fragments are loaded: $raw',
      );
    }
    target = Uri.parse(mapUrl?.call(parsed.toString()) ?? parsed.toString());
  }

  if (base != null &&
      base.hasScheme &&
      target.scheme == base.scheme &&
      target.host == base.host &&
      target.port == base.port &&
      target.path == base.path &&
      target.query == base.query &&
      target.hasFragment) {
    return NavigationHash(target.fragment);
  }
  return NavigationLoad(target.toString());
}

/// Whether [origin] is the web origin of [configured]: the same http(s)
/// scheme, host and port, with default ports filled in. An empty or
/// unparsable setting matches nothing, and so does an opaque origin (a
/// sandboxed frame reports "null").
bool isSameWebOrigin(String configured, Uri origin) {
  final c = Uri.tryParse(configured.trim());
  if (c == null || c.host.isEmpty) return false;
  bool web(Uri u) => u.scheme == 'http' || u.scheme == 'https';
  if (!web(c) || !web(origin) || origin.host.isEmpty) return false;
  return c.scheme == origin.scheme &&
      c.host.toLowerCase() == origin.host.toLowerCase() &&
      c.port == origin.port;
}
