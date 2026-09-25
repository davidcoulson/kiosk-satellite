import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'gesture_mappings.dart';

/// The keys a remote has that are not text, by Android key code, as the
/// event types of Home Assistant's Remote key event. Only these are ever
/// reported: never letters, digits or symbols, so a keyboard typing into an
/// app is never sent anywhere. The event entity declares exactly this list,
/// since Home Assistant refuses an event type it was not told about.
const remoteKeyEventTypes = <int, String>{
  3: 'home',
  4: 'back',
  19: 'dpad_up',
  20: 'dpad_down',
  21: 'dpad_left',
  22: 'dpad_right',
  23: 'dpad_center',
  24: 'volume_up',
  25: 'volume_down',
  66: 'enter',
  82: 'menu',
  84: 'search',
  85: 'media_play_pause',
  86: 'media_stop',
  87: 'media_next',
  88: 'media_previous',
  89: 'media_rewind',
  90: 'media_fast_forward',
  91: 'mute',
  126: 'media_play',
  127: 'media_pause',
  131: 'f1',
  132: 'f2',
  133: 'f3',
  134: 'f4',
  135: 'f5',
  136: 'f6',
  137: 'f7',
  138: 'f8',
  139: 'f9',
  140: 'f10',
  141: 'f11',
  142: 'f12',
  164: 'volume_mute',
  165: 'info',
  166: 'channel_up',
  167: 'channel_down',
  170: 'tv',
  172: 'guide',
  174: 'bookmark',
  175: 'captions',
  176: 'settings',
  178: 'tv_input',
  183: 'red',
  184: 'green',
  185: 'yellow',
  186: 'blue',
  187: 'app_switch',
  219: 'assist',
  222: 'audio_track',
  284: 'all_apps',
};

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
          e.key == defs.gestureRemoteKeysEnabled.key ||
          e.key == defs.remoteKeysReport.key ||
          e.key == defs.homeApp.key ||
          e.key == defs.homeAppIdleMinutes.key) {
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
        name: 'sendKey',
        description:
            'Press a key on the device: back, home, recents, notifications, '
            'the media keys and volume on any Android; the D-pad and OK from '
            'Android 13. No root or ADB needed.',
        params: const {'key': 'e.g. back, home, play_pause, volume_up'},
        handler: (p) async {
          try {
            final answer = await _channel.invokeMapMethod<String, Object?>(
              'sendKey',
              {'key': '${p['key'] ?? ''}'.trim()},
            );
            return answer?['ok'] == true
                ? const CommandResult.ok()
                : CommandResult.fail('${answer?['error'] ?? 'refused'}');
          } on MissingPluginException {
            return const CommandResult.fail('sending keys is Android-only');
          }
        },
      ),
    );
    commands.register(
      Command(
        name: 'selfRepairs',
        description:
            'What the accessibility keeper has put back after firmware took '
            'it away: {count, last (epoch ms), what}.',
        quiet: true,
        handler: (_) async {
          try {
            return CommandResult.ok(
              await _channel.invokeMapMethod<String, Object?>('selfRepairs') ??
                  const {'count': 0},
            );
          } on MissingPluginException {
            return const CommandResult.ok({'count': 0});
          }
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
        if (_reportWanted) 'report': remoteKeyEventTypes.keys.toList(),
      });
    } on MissingPluginException {
      // Not Android: there is no remote to map.
    } on PlatformException catch (e) {
      log.warn(name, 'could not update the remote key table: $e');
    }
  }

  /// Presses are observed for Home Assistant's event, and for the
  /// home-app guard, which reads a press as the remote being in use.
  bool get _reportWanted =>
      _settings.get(defs.remoteKeysReport) ||
      (_settings.get(defs.homeApp).trim().isNotEmpty &&
          _settings.get(defs.homeAppIdleMinutes) > 0);

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
      case 'reported':
        final code = (args['keyCode'] as num?)?.toInt() ?? 0;
        final type = remoteKeyEventTypes[code];
        if (type != null) {
          bus.publish(RemoteKeyReported(keyCode: code, type: type));
        }
      case 'repaired':
        bus.publish(SelfRepaired(args));
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
