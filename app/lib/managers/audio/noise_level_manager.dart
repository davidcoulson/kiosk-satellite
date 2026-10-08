import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import 'mic_hub.dart';
import 'mic_level_monitor.dart';

/// How loud the room is, as one number (issue #910): the Ambient noise
/// sensor in Home Assistant and getNoiseLevel / audio.noise for plugins, so
/// the kiosk can answer quietly at night and louder over the TV.
///
/// It is a level and nothing more. The figure is the mean power of the
/// capture over [window], rounded to whole dBFS. It moves only by [step]
/// or more. It comes off the capture the wake word engine already holds
/// ([MicHub.tap]), so measuring never opens the microphone. With wake word
/// detection off or muted there is nothing to report.
///
/// It holds its last value while a voice turn or another interaction runs
/// (speech must not show up in it) and while the kiosk plays its own sound,
/// which it would otherwise measure. A window the kiosk played into is
/// thrown away, its echo tail included.
class NoiseLevelManager extends Manager {
  NoiseLevelManager(
    super.bus,
    super.commands,
    super.log, {
    @visibleForTesting Stream<Uint8List> Function()? tap,
    @visibleForTesting Future<bool> Function(Duration within)? playedWithin,
    @visibleForTesting DateTime Function()? now,
  }) : _tap = tap ?? (() => MicHub.instance.tap()),
       _playedWithin = playedWithin ?? _nativePlayedWithin,
       _now = now ?? DateTime.now;

  final Stream<Uint8List> Function() _tap;
  final Future<bool> Function(Duration within) _playedWithin;
  final DateTime Function() _now;

  @override
  String get name => 'noise_level';

  /// How long each reading averages over.
  static const window = Duration(seconds: 5);

  /// The smallest move the sensor and plugins hear about.
  static const step = 2;

  /// What a silent capture reads: the bottom of 16-bit audio.
  static const floorDbfs = -96;

  /// How long a sound still echoes after the kiosk stops playing it, the
  /// capture watchdog's playback tail.
  static const _echoTail = Duration(seconds: 2);

  static const _channel = MethodChannel('kiosk_satellite/audio_routing');

  static Future<bool> _nativePlayedWithin(Duration within) async {
    try {
      return await _channel.invokeMethod<bool>('playedWithin', {
            'ms': within.inMilliseconds,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  final _subs = <StreamSubscription<Object?>>[];

  bool _wakeActive = true;
  bool _wakeListening = false;

  /// The interactions running now, by reason: voice turns, announcements,
  /// timers, alarms, media and intercom calls all hold the level.
  final _interactions = <String>{};

  DateTime? _windowStart;
  double _power = 0;
  int _chunks = 0;

  /// Bumped whenever the window is thrown away, so a reading still waiting
  /// on the playback check is dropped too.
  int _generation = 0;

  int? _dbfs;
  bool _held = false;
  DateTime? _updated;
  (bool, int?, bool)? _sent;

  /// Detection paused for a voice turn or another interaction running.
  bool get _busy => !_wakeActive || _interactions.isNotEmpty;

  bool get _sampling => _wakeListening && !_busy;

  /// A level is listening now or held through an interaction.
  bool get available => _wakeListening || (!_wakeActive && _dbfs != null);

  bool get held => available && (_busy || _held);

  int? get dbfs => available ? _dbfs : null;

  Map<String, Object?> describe() => {
    'available': available,
    'dbfs': dbfs,
    'held': held,
    'updated': available ? _updated?.toUtc().toIso8601String() : null,
  };

  @override
  Future<void> init() async {
    final wake = await commands.execute('getWakeWordState', const {});
    if (wake.ok && wake.data is Map) {
      final state = wake.data as Map;
      _wakeActive = state['active'] != false;
      _wakeListening = state['listening'] == true;
    }
    _subs
      ..add(
        bus.on<WakeWordStateChanged>().listen((e) {
          _wakeActive = e.active;
          _wakeListening = e.listening;
          _sync();
        }),
      )
      ..add(
        bus.on<VoiceInteractionChanged>().listen((e) {
          if (e.active) {
            _interactions.add(e.reason);
          } else {
            _interactions.remove(e.reason);
          }
          _sync();
        }),
      )
      ..add(_tap().listen(_onChunk, onError: (Object _) {}));
    commands.register(
      Command(
        name: 'getNoiseLevel',
        description:
            'How loud the room is: whole dBFS averaged over 5 seconds, '
            'held through voice turns and the kiosk\'s own sounds. '
            'Unavailable while wake word detection is not listening.',
        handler: (_) async => CommandResult.ok(describe()),
      ),
    );
    _sync();
  }

  void _sync() {
    if (!_sampling) _discard();
    // Still held once the interaction ends, until a clean window replaces
    // the value: the first one after an answer usually carries its echo.
    if (_busy) _held = true;
    if (!available) {
      _dbfs = null;
      _held = false;
      _updated = null;
    }
    _publish();
  }

  void _discard() {
    _generation++;
    _windowStart = null;
    _power = 0;
    _chunks = 0;
  }

  void _onChunk(Uint8List chunk) {
    if (!_sampling) return;
    final now = _now();
    final start = _windowStart ??= now;
    final rms = MicLevelMonitor.rmsOf(chunk);
    _power += rms * rms;
    _chunks++;
    final span = now.difference(start);
    if (span < window) return;
    final power = _power / _chunks;
    final generation = _generation;
    _windowStart = null;
    _power = 0;
    _chunks = 0;
    unawaited(_close(power, span, generation));
  }

  Future<void> _close(double power, Duration span, int generation) async {
    final played = await _playedWithin(span + _echoTail);
    if (generation != _generation || !_sampling) return;
    if (played) {
      _held = true;
    } else {
      _held = false;
      _dbfs = dbfsOf(power);
      _updated = _now();
    }
    _publish();
  }

  /// Mean power (RMS squared, full scale 1) as whole dBFS.
  static int dbfsOf(double power) {
    if (power <= 0) return floorDbfs;
    final db = (10 * math.log(power) / math.ln10).round();
    return db.clamp(floorDbfs, 0);
  }

  void _publish() {
    final next = (available, dbfs, held);
    final sent = _sent;
    if (sent != null && sent.$1 == next.$1 && sent.$3 == next.$3) {
      final was = sent.$2;
      final now = next.$2;
      if (was == now) return;
      if (was != null && now != null && (was - now).abs() < step) return;
    }
    _sent = next;
    bus.publish(
      NoiseLevelChanged(available: next.$1, dbfs: next.$2, held: next.$3),
    );
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
