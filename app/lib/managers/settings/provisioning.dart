import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/logging.dart';
import 'definitions.dart' as defs;
import 'settings_manager.dart';

/// Provisioning via Android launch-intent extras — configure a device from
/// adb or an MDM without touching the UI:
///
///   adb shell am start -n me.jxl.kiosk_satellite/.MainActivity \
///     --es ks.provision '{"remote.enabled":true,"remote.password":"..."}'
///
/// Keys/values are the same JSON the remote API's settings import accepts.
///
/// Any app on the device can send an intent, and that payload includes the
/// admin password, so this is gated rather than open: a kiosk with no Start
/// page yet is being set up and has nothing to take over, and after that it
/// takes the explicit Allow provisioning intents switch. An MDM that
/// re-provisions in place turns that on; a panel on a wall does not, and a
/// refused payload is logged rather than swallowed.
class ProvisioningChannel {
  ProvisioningChannel(this._settings, this._log);

  static const _channel = MethodChannel('kiosk_satellite/provision');

  final SettingsManager _settings;
  final Logger _log;

  Future<void> init() async {
    // Push path: app already running when a provisioning intent arrives.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'provision' && call.arguments is String) {
        await _apply(call.arguments as String);
      }
    });

    // Pull path: provisioning extra on the launch intent.
    try {
      final json = await _channel.invokeMethod<String>('getProvisionJson');
      if (json != null) await _apply(json);
    } on MissingPluginException {
      // Not on Android, or the host activity doesn't expose the channel.
    }
  }

  /// Whether a payload may be applied at all. First run is open because
  /// provisioning is how an unconfigured kiosk gets its Start page in the
  /// first place - tool/onboard-panel.sh does exactly this - and a kiosk
  /// with nothing configured has nothing worth taking.
  bool get _accepting =>
      _settings.get(defs.startUrl).isEmpty ||
      _settings.get(defs.provisioningAllow);

  Future<void> _apply(String json) async {
    if (!_accepting) {
      _log.warn(
        'provision',
        'refused a provisioning intent: this kiosk is already set up and '
        'Allow provisioning intents is off',
      );
      return;
    }
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return;
      final applied = await _settings.import(decoded.cast<String, Object?>());
      _log.info('provision', 'applied $applied setting(s) from intent');
    } catch (e) {
      _log.warn('provision', 'bad provisioning payload: $e');
    }
  }
}
