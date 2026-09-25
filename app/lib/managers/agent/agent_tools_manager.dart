import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// Headless management: what a box whose screen belongs to another app -
/// a projector, a media box - needs from Kiosk Satellite. Mostly for agent
/// mode, where it runs in place of everything on-screen, but nothing here
/// assumes it: each part is off until its own setting turns it on.
///
///  - Now playing: another app's media session (Plezy, Kodi, YouTube),
///    from MediaSessions.kt, with play, pause and skip back to it.
///  - The home app: opened at boot, and brought back after the remote has
///    sat idle with nothing playing - the vendor launcher or a crashed
///    player left in front gets replaced by the app this box is for.
///  - The daily restart, where the device can be restarted at all.
///  - On an agent, the restart commands the kiosk manager otherwise owns.
class AgentToolsManager extends Manager {
  AgentToolsManager(
    super.bus,
    super.commands,
    super.log,
    this._settings, {
    MethodChannel? mediaChannel,
    DateTime Function()? clock,
  }) : _media =
           mediaChannel ??
           const MethodChannel('kiosk_satellite/media_sessions'),
       _clock = clock ?? DateTime.now;

  final SettingsManager _settings;
  final MethodChannel _media;
  final DateTime Function() _clock;

  static const _background = MethodChannel('kiosk_satellite/background');

  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _tick;

  Map<String, Object?> _nowPlaying = const {'state': 'idle'};
  /// The last remote key press, or startup: set in [init], not lazily,
  /// so the idle clock runs from when the app started.
  DateTime _lastKey = DateTime.fromMillisecondsSinceEpoch(0);
  String _rebootDoneFor = '';

  Map<String, Object?> get nowPlaying => _nowPlaying;

  @override
  String get name => 'agentTools';

  @override
  Future<void> init() async {
    _lastKey = _clock();
    _media.setMethodCallHandler((call) async {
      if (call.method == 'changed' && call.arguments is Map) {
        _nowPlaying = (call.arguments as Map).cast<String, Object?>();
        bus.publish(NowPlayingChanged(_nowPlaying));
      }
      return null;
    });
    _subs.add(bus.on<RemoteKeyReported>().listen((_) => _lastKey = _clock()));

    commands.register(
      Command(
        name: 'nowPlayingStatus',
        description:
            'What plays on the device in another app: {access, state, '
            'package, app, title, artist, album, durationMs}.',
        quiet: true,
        handler: (_) async {
          try {
            final status = await _media.invokeMapMethod<String, Object?>(
              'status',
            );
            return CommandResult.ok(status ?? _nowPlaying);
          } on MissingPluginException {
            return CommandResult.ok(_nowPlaying);
          }
        },
      ),
    );
    commands.register(
      Command(
        name: 'mediaControl',
        description:
            'Control whatever plays on the device: play, pause, play_pause, '
            'next, previous or stop.',
        params: const {'action': 'play_pause, next, ...'},
        handler: (p) async {
          try {
            final answer = await _media.invokeMapMethod<String, Object?>(
              'control',
              {'action': '${p['action'] ?? ''}'},
            );
            return answer?['ok'] == true
                ? const CommandResult.ok()
                : CommandResult.fail('${answer?['error'] ?? 'refused'}');
          } on MissingPluginException {
            return const CommandResult.fail('media control is Android-only');
          }
        },
      ),
    );
    commands.register(
      Command(
        name: 'listInstalledApps',
        description:
            'Every launchable app: package, label, version, versionCode, '
            'installed and updated (epoch ms), system, enabled.',
        quiet: true,
        handler: (_) async {
          try {
            final apps = await _background.invokeListMethod<Object?>(
              'listAppsDetailed',
            );
            return CommandResult.ok(apps ?? const []);
          } on MissingPluginException {
            return const CommandResult.ok([]);
          }
        },
      ),
    );
    commands.register(
      Command(
        name: 'uninstallApp',
        description:
            "Open Android's uninstall confirmation for a package on the "
            'device; the person there confirms.',
        params: const {'package': 'Android package'},
        handler: (p) async {
          final pkg = '${p['package'] ?? ''}'.trim();
          if (pkg.isEmpty) return const CommandResult.fail('package required');
          try {
            final ok =
                await _background.invokeMethod<bool>('uninstallApp', {
                  'package': pkg,
                }) ??
                false;
            return ok
                ? const CommandResult.ok()
                : CommandResult.fail('could not open the uninstall for $pkg');
          } on MissingPluginException {
            return const CommandResult.fail('uninstalling is Android-only');
          }
        },
      ),
    );
    if (_settings.get(defs.agentMode)) _registerAgentReboot();

    unawaited(_openAtBoot());
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _check());
  }

  @override
  Future<void> dispose() async {
    _tick?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _media.setMethodCallHandler(null);
  }

  String get _homeApp => _settings.get(defs.homeApp).trim();

  /// After a boot, not after an app restart: the device's uptime says
  /// which. Delayed a little so the launcher's own start does not land on
  /// top of it.
  Future<void> _openAtBoot() async {
    if (_homeApp.isEmpty || !_settings.get(defs.homeAppAtBoot)) return;
    final uptime = await commands.execute('getUptime', const {});
    final device = uptime.ok && uptime.data is Map
        ? ((uptime.data as Map)['device'] as num?)
        : null;
    if (device == null || device > 300) return;
    await Future<void>.delayed(const Duration(seconds: 10));
    log.info(name, 'opening the home app after boot: $_homeApp');
    await _launchHome();
  }

  Future<void> _launchHome() async {
    final result = await commands.execute('launchApp', {'package': _homeApp});
    if (!result.ok) log.warn(name, 'could not open $_homeApp: ${result.error}');
  }

  @visibleForTesting
  Future<void> checkForTest() => _check();

  Future<void> _check() async {
    await _returnHomeIfIdle();
    await _rebootIfDue();
  }

  /// Brings the home app back once the remote has been idle long enough,
  /// nothing is playing, and something else is in front.
  Future<void> _returnHomeIfIdle() async {
    final minutes = _settings.get(defs.homeAppIdleMinutes);
    if (_homeApp.isEmpty || minutes <= 0) return;
    if (_clock().difference(_lastKey) < Duration(minutes: minutes.toInt())) {
      return;
    }
    if (_nowPlaying['state'] == 'playing') return;
    final front = await commands.execute('foregroundApp', const {});
    final pkg = front.ok && front.data is Map
        ? (front.data as Map)['package'] as String?
        : null;
    // Unknown: nothing says the home app is not already there.
    if (pkg == null || pkg == _homeApp) return;
    log.info(name, 'idle with $pkg in front: bringing back $_homeApp');
    _lastKey = _clock();
    await _launchHome();
  }

  /// The daily restart, once per day at its minute, and never within ten
  /// minutes of a boot (a clock that jumps at boot must not loop it).
  Future<void> _rebootIfDue() async {
    final at = RegExp(
      r'^([01]?\d|2[0-3]):([0-5]\d)$',
    ).firstMatch(_settings.get(defs.rebootTime).trim());
    if (at == null) return;
    final now = _clock();
    final today = '${now.year}-${now.month}-${now.day}';
    if (_rebootDoneFor == today) return;
    if (now.hour != int.parse(at.group(1)!) ||
        now.minute != int.parse(at.group(2)!)) {
      return;
    }
    _rebootDoneFor = today;
    final uptime = await commands.execute('getUptime', const {});
    final device = uptime.ok && uptime.data is Map
        ? ((uptime.data as Map)['device'] as num?)
        : null;
    if (device != null && device < 600) return;
    log.info(name, 'daily restart');
    final result = await commands.execute('rebootDevice', const {});
    if (!result.ok) log.warn(name, 'daily restart refused: ${result.error}');
  }

  /// The kiosk manager owns these on a kiosk; an agent does not run it, so
  /// the Restart device button and the daily restart would have nothing to
  /// call. Same rule: device owner, or a granted Shizuku connection.
  void _registerAgentReboot() {
    Future<Map<String, Object?>> support() async {
      var owner = false;
      try {
        owner = await _background.invokeMethod<bool>('isDeviceOwner') ?? false;
      } on PlatformException catch (_) {
      } on MissingPluginException catch (_) {}
      if (owner) return const {'supported': true, 'route': 'device_owner'};
      final shizuku = await commands.execute('getShizukuState', const {});
      final granted =
          shizuku.ok &&
          shizuku.data is Map &&
          (shizuku.data as Map)['granted'] == true;
      return granted
          ? const {'supported': true, 'route': 'shizuku'}
          : const {
              'supported': false,
              'route': null,
              'reason':
                  'Restarting the device needs Kiosk Satellite provisioned '
                  'as the device owner or a granted Shizuku connection.',
            };
    }

    commands.register(
      Command(
        name: 'getDeviceRebootSupport',
        description: 'Whether the whole device can be restarted from here.',
        quiet: true,
        handler: (_) async => CommandResult.ok(await support()),
      ),
    );
    commands.register(
      Command(
        name: 'rebootDevice',
        description: 'Restart the whole device (device owner or Shizuku).',
        handler: (_) async {
          final s = await support();
          if (s['supported'] != true) {
            return CommandResult.fail('${s['reason']}');
          }
          if (s['route'] == 'device_owner') {
            try {
              final answer = await _background.invokeMapMethod<String, Object?>(
                'rebootDevice',
              );
              return answer?['ok'] == true
                  ? const CommandResult.ok()
                  : CommandResult.fail(
                      '${answer?['error'] ?? 'Android refused the restart'}',
                    );
            } on PlatformException catch (e) {
              return CommandResult.fail('restart failed: $e');
            } on MissingPluginException {
              return const CommandResult.fail('restart is Android-only');
            }
          }
          final result = await commands.execute('runShizukuAction', {
            'action': 'reboot',
          });
          return result.ok
              ? const CommandResult.ok()
              : CommandResult.fail(
                  result.error ?? 'Shizuku refused the restart',
                );
        },
      ),
    );
  }
}
