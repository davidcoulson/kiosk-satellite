import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'gesture_mappings.dart';

/// Remote key mappings: the Dart half.
///
/// A `remote_key` gesture maps a hardware key on the device's remote to a
/// gesture action. The keys are caught natively, by the System UI guard's
/// accessibility service (RemoteKeys.kt), because only an accessibility
/// service sees keys while another app is in front. This manager keeps
/// that table in step with gestures.mappings, runs what the service hands
/// back, and captures a key for the editors.
///
/// The service runs launch_app, open_uri and android_settings itself and
/// reports them here only for the log; every other action arrives as a
/// [GestureDetected], so the gestures manager runs it exactly as it runs a
/// touch or clap gesture.
///
/// Kept in agent mode, with the gestures manager: a projector's remote is
/// the one input an agent has.
class RemoteKeysManager extends Manager {
  RemoteKeysManager(
    super.bus,
    super.commands,
    super.log,
    this._settings, {
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('kiosk_satellite/remote_keys');

  final SettingsManager _settings;
  final MethodChannel _channel;

  StreamSubscription<SettingChanged>? _settingsSub;
  Completer<Map<String, Object?>>? _capture;

  @override
  String get name => 'remoteKeys';

  @override
  Future<void> init() async {
    _channel.setMethodCallHandler(_onNative);
    _settingsSub = bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.gestureMappings.key ||
          e.key == defs.gestureRemoteKeysEnabled.key) {
        _push();
      }
    });
    await _push();

    commands.register(
      Command(
        name: 'captureRemoteKey',
        description:
            'Wait for the next key pressed on the device remote and report '
            'it, for mapping it to an action. The key does nothing else.',
        params: const {'seconds': 'How long to wait (default 20)'},
        handler: (p) async {
          final seconds = ((p['seconds'] as num?) ?? 20).clamp(1, 120).toInt();
          final key = await capture(seconds: seconds);
          if (key == null) {
            return CommandResult.fail(
              _lastCaptureRefused
                  ? 'Remote keys need the Kiosk Satellite accessibility '
                        'service: enable it in Android Accessibility settings.'
                  : 'No key was pressed.',
            );
          }
          return CommandResult.ok(key);
        },
      ),
    );
    commands.register(
      Command(
        name: 'remoteKeysStatus',
        description:
            'Whether the accessibility service remote keys need is running.',
        quiet: true,
        handler: (_) async => CommandResult.ok(await status()),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _settingsSub?.cancel();
    _capture?.complete(const {});
    _channel.setMethodCallHandler(null);
  }

  Future<void> _push() async {
    try {
      await _channel.invokeMethod('configure', {
        'mappings': _settings.get(defs.gestureMappings),
        'enabled': _settings.get(defs.gestureRemoteKeysEnabled),
      });
    } on MissingPluginException {
      // Not Android: there is no remote to map.
    } on PlatformException catch (e) {
      log.warn(name, 'could not update the remote key table: $e');
    }
  }

  Future<Object?> _onNative(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'pressed':
        final id = '${args['id'] ?? ''}';
        final ran = args['ran'];
        if (ran is bool) {
          final mapping = _mapping(id);
          final what = mapping == null
              ? 'remote key'
              : '${describeGestureTrigger(mapping.trigger)}: '
                    '${describeGestureAction(mapping.action)}';
          if (ran) {
            log.info(name, what);
          } else {
            log.warn(name, '$what failed');
          }
        } else {
          bus.publish(GestureDetected(id: id));
        }
      case 'captured':
        final pending = _capture;
        _capture = null;
        pending?.complete({
          'keyCode': (args['keyCode'] as num?)?.toInt() ?? 0,
          'keyName': '${args['name'] ?? ''}',
        });
    }
    return null;
  }

  GestureMapping? _mapping(String id) {
    for (final m in decodeGestureMappings(
      _settings.get(defs.gestureMappings),
    )) {
      if (m.id == id) return m;
    }
    return null;
  }

  bool _lastCaptureRefused = false;

  /// The next key pressed on the remote, as {keyCode, keyName}, or null
  /// when none came within [seconds] or the service is not running. The
  /// key is swallowed: pressing Home to map it must not also go home.
  Future<Map<String, Object?>?> capture({int seconds = 20}) async {
    _lastCaptureRefused = false;
    _capture?.complete(const {});
    final pending = Completer<Map<String, Object?>>();
    _capture = pending;
    bool running;
    try {
      running =
          await _channel.invokeMethod<bool>('capture', {'seconds': seconds}) ??
          false;
    } on MissingPluginException {
      running = false;
    }
    if (!running) {
      _lastCaptureRefused = true;
      if (identical(_capture, pending)) _capture = null;
      await _cancelNative();
      return null;
    }
    final key = await pending.future.timeout(
      Duration(seconds: seconds),
      onTimeout: () => const {},
    );
    if (identical(_capture, pending)) _capture = null;
    if (key.isEmpty) {
      await _cancelNative();
      return null;
    }
    return key;
  }

  /// Stop waiting for a key (the editor closed).
  Future<void> cancelCapture() async {
    final pending = _capture;
    _capture = null;
    pending?.complete(const {});
    await _cancelNative();
  }

  Future<void> _cancelNative() async {
    try {
      await _channel.invokeMethod('cancelCapture');
    } on MissingPluginException {
      // Not Android.
    }
  }

  /// {serviceRunning, filtering, mappings}: the editors warn when the
  /// service is off, since no remote key works without it.
  Future<Map<String, Object?>> status() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('status');
      return result ?? const {'serviceRunning': false};
    } on MissingPluginException {
      return const {'serviceRunning': false};
    }
  }
}
