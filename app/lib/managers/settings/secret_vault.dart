import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// The Dart end of SecretVault.kt: wraps and unwraps strings under a key the
/// Android Keystore holds. Knows nothing about settings.
///
/// Every failure is an answer rather than an exception -- no channel (a test,
/// another platform), a Keystore that throws, a value that will not unwrap --
/// because the caller's job is deciding what a secret it cannot read means,
/// and it has to make that decision at startup with nobody watching.
class SecretVault {
  const SecretVault();

  static const _channel = MethodChannel('kiosk_satellite/secret_vault');

  /// Marks a stored value as wrapped. Versioned, so a later scheme can tell
  /// its own values from these.
  static const prefix = 'ksv1:';

  static bool isWrapped(String stored) => stored.startsWith(prefix);

  /// Only Android has SecretVault.kt. Anywhere else the channel has no
  /// handler, and under a widget test's fake clock a call to a channel with
  /// no handler never resolves -- it hung every test that booted the
  /// settings, rather than failing any of them.
  static bool get _available => Platform.isAndroid;

  /// Whether this device's Keystore round-trips a value, asked before
  /// anything is entrusted to it.
  Future<bool> selfTest() async {
    if (!_available) return false;
    try {
      return await _channel.invokeMethod<bool>('selfTest', const {
            'values': <String>[],
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Each of [plain] wrapped and prefixed, or null where that failed.
  Future<List<String?>> wrap(List<String> plain) async {
    final out = await _batch('wrap', plain);
    return [for (final value in out) value == null ? null : '$prefix$value'];
  }

  /// Each of [stored] unwrapped, or null where that failed. Every entry must
  /// be [isWrapped].
  Future<List<String?>> unwrap(List<String> stored) => _batch('unwrap', [
    for (final value in stored) value.substring(prefix.length),
  ]);

  Future<List<String?>> _batch(String method, List<String> values) async {
    if (values.isEmpty) return const [];
    if (!_available) return List<String?>.filled(values.length, null);
    try {
      final out = await _channel.invokeListMethod<String?>(method, {
        'values': values,
      });
      if (out != null && out.length == values.length) return out;
    } on MissingPluginException {
      // Fall through.
    } on PlatformException {
      // Fall through.
    }
    return List<String?>.filled(values.length, null);
  }
}
