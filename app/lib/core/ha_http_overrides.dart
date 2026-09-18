import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

import '../managers/settings/definitions.dart' as defs;
import '../managers/settings/settings_manager.dart';
import 'app_identity.dart';

/// Most Home Assistant installs on a LAN run self-signed certificates, so
/// the app must not fail TLS verification against its own configured
/// server — that would break setup validation, service calls, the
/// websocket, and wake-word model downloads alike.
///
/// Installed as [HttpOverrides.global], which every dart:io HttpClient in
/// the process inherits (package:http and WebSocket.connect included).
/// The exemption is scoped to the configured HA and Immich hosts only —
/// certificates for any other host still verify normally — unless the user
/// enabled the browser's "Ignore SSL errors" setting, which turns
/// verification off for these clients just as it does for the WebView. The
/// WebView has its own trust stack; [sawSelfSigned] lets the connection check
/// align the browser's "Ignore SSL errors" setting when a self-signed
/// certificate was in fact accepted.
///
/// The exemption is for one certificate, not for the host. It used to accept
/// anything presented under the configured name, which excuses a self-signed
/// certificate and equally excuses whoever answers in its place: these
/// clients carry the long-lived access token, so anyone able to intercept
/// the connection could collect it with a certificate of their own making.
/// The first untrusted certificate a host presents is remembered and only
/// that one is accepted afterwards -- what SSH does with a host key.
///
/// A self-signed certificate is eventually renewed, and a panel on a wall
/// must not be stranded by that. The remembered certificate is forgotten
/// when the URL it belongs to changes, when "Ignore SSL errors" is switched
/// on, and by the forgetCertificates command; and while "Ignore SSL errors"
/// is on, whatever is presented becomes the one remembered, so switching it
/// on, reconnecting and switching it off adopts a renewed certificate from
/// the device's own settings screen.
class HaHttpOverrides extends HttpOverrides {
  HaHttpOverrides(this._settings);

  final SettingsManager _settings;

  /// Set when a bad certificate for the HA host was accepted this run.
  static bool sawSelfSigned = false;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // Every client in the process is born here, so this is the one place
    // the app has to name itself. A request that sets its own User-Agent
    // header still wins, which is what keeps the secure-context proxy
    // forwarding the browser's own string.
    client.userAgent = AppIdentity.userAgent;
    client.badCertificateCallback = (cert, host, port) =>
        allowBadCertificate(host, fingerprint: fingerprintOf(cert));
    return client;
  }

  /// SHA-256 of the certificate as presented, in hex.
  static String fingerprintOf(X509Certificate cert) =>
      sha256.convert(cert.der).toString();

  /// Refusals already logged, so a client reconnecting every few seconds
  /// says it once per certificate rather than once per attempt.
  final _refused = <String>{};

  /// Called with each refusal worth telling someone about.
  void Function(String host, String fingerprint)? onRefused;

  /// The policy behind badCertificateCallback, separate so tests can
  /// exercise it without staging a TLS handshake.
  bool allowBadCertificate(String host, {required String fingerprint}) {
    // "Ignore SSL errors" is the browser's blanket opt-in, and these
    // clients must agree with the WebView about what connects. Wake-word
    // manifest URLs come from the dashboard page's own origin, which can
    // name a host neither setting below knows about, e.g. an old IP the
    // dashboard still loads from while the HA URL moved to a domain
    // (issue #216).
    final ignoring = _settings.get(defs.ignoreSslErrors);
    final ha = Uri.tryParse(_settings.get(defs.haUrl).trim())?.host;
    // The Immich screensaver server gets the same standing as HA: a LAN
    // service the user pointed the app at, likely behind a self-signed
    // certificate. Still host-scoped; everything else verifies normally.
    final immich = Uri.tryParse(
      _settings.get(defs.screensaverImmichUrl).trim(),
    )?.host;
    final isHa = ha != null && ha.isNotEmpty && host == ha;
    final isImmich = immich != null && immich.isNotEmpty && host == immich;
    if (!isHa && !isImmich) return ignoring;

    final pinned = _settings.pinnedCertificate(host);
    if (pinned == null || ignoring) {
      // First sight, or the owner has said to trust what is there now.
      if (pinned != fingerprint) _settings.pinCertificate(host, fingerprint);
    } else if (pinned != fingerprint) {
      if (_refused.add('$host $fingerprint')) {
        onRefused?.call(host, fingerprint);
      }
      return false;
    }
    if (isHa) sawSelfSigned = true;
    return true;
  }
}
