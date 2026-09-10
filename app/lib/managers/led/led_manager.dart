import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'led_effects.dart';

/// What the panel has for an LED, from the native LedBridge.kt: whether
/// `/dev/ledjni` is actually reachable, and why not when it isn't —
/// mirrors LocationSupport/BleSupport's shape so the Settings page renders
/// this the same way it already renders those (a disabled switch naming
/// the reason).
///
/// Unknown counts as supported: a missing answer (no bridge, as in tests)
/// must never switch the feature off on a panel that has the LED.
class LedSupport {
  const LedSupport({required this.supported, this.hint});

  static const unknown = LedSupport(supported: true);

  final bool supported;

  /// Why [supported] is false, in a sentence fit for a settings row.
  final String? hint;
}

/// The panel's front RGB LED (Rockchip `/dev/ledjni`), via [LedBridge] on
/// the native side.
///
/// The hardware is write-only — there is nothing to poll or observe — so
/// this manager just forwards commands to the bridge and keeps the last
/// value written in memory, which is all `esp_entities.dart` needs to
/// answer a state read (there's no external actor that could change the
/// LED behind this app's back, unlike e.g. screen brightness via quick
/// settings).
///
/// [available] starts false. The hardware half of it flips at most once,
/// briefly after start, when the native side finishes probing which access
/// path this panel supports, or that neither works — see LedBridge.kt's
/// class doc; the [defs.ledEnabled] setting half can flip any number of
/// times, from the Settings page or a remote command. Nothing here assumes
/// a particular panel: hardware absence is the normal case on most kiosks,
/// and the ESPHome entity is simply not published then.
///
/// [effects] mirrors ESPHome's own generic (non-addressable) light effects
/// — Pulse, Strobe, Random, Flicker — so the entity matches a real ESPHome
/// device's dropdown exactly. The hardware is three raw registers with no
/// animation support of its own, so every effect is driven here: a
/// [Timer] repeatedly writes frames straight to the bridge, leaving [_r]/
/// [_g]/[_b] (the base color effects animate around) untouched until the
/// effect is cleared, at which point that base color is restored.
class LedManager extends Manager {
  LedManager(super.bus, super.commands, super.log, this._settings);

  final SettingsManager _settings;

  static const _channel = MethodChannel('kiosk_satellite/led');

  /// The four generic ESPHome effects (esphome.io/components/light,
  /// implemented inline below via [_runPulse] etc.) plus every effect from
  /// the "accent light, non-addressable" reference config (`~/dev/...`,
  /// see [ledEffectRunners] in led_effects.dart) — "None" is never listed,
  /// HA adds that itself as the implicit clear-effect option.
  static final effects = ['Pulse', 'Strobe', 'Random', 'Flicker', ...ledEffectRunners.keys];

  static const _tick = Duration(milliseconds: 100);

  @override
  String get name => 'led';

  /// Hardware-only: whether native detection found a working access path.
  /// Not what callers should gate on — see [available].
  bool _hardwareAvailable = false;

  /// Effective availability: the hardware works *and* the user hasn't
  /// turned the entity off. What every command handler below checks, and
  /// what `esp_entities.dart` asks before publishing the entity at all —
  /// so disabling the setting mid-session both stops new commands and
  /// (via the `led.enabled` catalogKeys entry in BtProxyManager) drops the
  /// entity from Home Assistant on the next reconnect.
  bool get available => _hardwareAvailable && _settings.get(defs.ledEnabled);

  LedSupport? _support;

  /// True once hardware detection has resolved to "unusable" — the
  /// Settings page shows a disabled switch with [ledHint] instead of the
  /// normal toggle while this is true (same convention as
  /// LocationManager.locationKnownUnsupported / BtProxyManager's BLE
  /// equivalent).
  bool get ledKnownUnsupported => _support?.supported == false;

  /// Why [ledKnownUnsupported] is true, in a sentence fit for a settings
  /// row — see LedBridge.kt's `hint` for the exact wording per cause.
  String? get ledHint => _support?.hint;

  /// Detection runs on a background native thread and can take a few
  /// seconds (the rooted-fallback probe's own timeout); completed by the
  /// method-call handler below the first time it hears from native,
  /// whichever way detection landed. [ledSupport] awaits this instead of
  /// racing a still-in-progress probe.
  final _detectionSettled = Completer<void>();

  /// Last value this app itself set, not necessarily what the hardware
  /// currently shows (there's no way to read that back). r/g/b is the
  /// *base* color: what a running effect animates around, and what gets
  /// restored the moment the effect is cleared.
  bool _on = false;
  int _r = 0;
  int _g = 0;
  int _b = 0;
  String _effect = 'None';

  Timer? _effectTimer;

  /// Set only while a [ledEffectRunners] (as opposed to one of the four
  /// simple inline effects) is active — its tick timing.
  Stopwatch? _effectStopwatch;

  Map<String, Object?> get state =>
      {'on': _on, 'r': _r, 'g': _g, 'b': _b, 'effect': _effect};

  @override
  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'available') {
        final was = available;
        _hardwareAvailable = call.arguments == true;
        if (!_detectionSettled.isCompleted) _detectionSettled.complete();
        if (was != available) {
          bus.publish(LedAvailabilityChanged(available: available));
        }
      }
      return null;
    });
    // The bridge may resolve availability before this handler is attached
    // (detection runs on a background thread from the moment the app
    // process starts); ask once so a late-attaching listener isn't stuck
    // believing "unavailable" forever.
    _hardwareAvailable = await _channel.invokeMethod<bool>('available') ?? false;
    if (_hardwareAvailable && !_detectionSettled.isCompleted) {
      _detectionSettled.complete();
    }

    commands.register(
      Command(
        name: 'ledAvailable',
        description: 'Whether the panel has a controllable RGB LED',
        handler: (_) async => CommandResult.ok(available),
      ),
    );
    commands.register(
      Command(
        name: 'getLedSupport',
        description: 'Whether the panel LED works, and why not if it does not',
        handler: (_) async {
          final support = await ledSupport();
          return CommandResult.ok({
            'supported': support.supported,
            if (support.hint != null) 'hint': support.hint,
          });
        },
      ),
    );
    commands.register(
      Command(
        name: 'getLedState',
        description: 'Last colour (and effect) this app itself set',
        handler: (_) async => CommandResult.ok(state),
      ),
    );
    commands.register(
      Command(
        name: 'setLedRgb',
        description: 'Set the panel LED colour',
        params: const {
          'r': 'Red 0..255',
          'g': 'Green 0..255',
          'b': 'Blue 0..255',
        },
        handler: (p) async {
          if (!available) return const CommandResult.fail('LED unavailable');
          final r = ((p['r'] as num?) ?? 0).clamp(0, 255).toInt();
          final g = ((p['g'] as num?) ?? 0).clamp(0, 255).toInt();
          final b = ((p['b'] as num?) ?? 0).clamp(0, 255).toInt();
          // A direct colour pick reads as "stop animating, show exactly
          // this" — the same convention every smart light follows.
          _stopEffect();
          final ok = await _writeRaw(r, g, b);
          if (ok) {
            _on = true;
            _r = r;
            _g = g;
            _b = b;
            bus.publish(const LedStateChanged());
          }
          return ok
              ? const CommandResult.ok()
              : const CommandResult.fail('LED write failed');
        },
      ),
    );
    commands.register(
      Command(
        name: 'ledOff',
        description: 'Turn the panel LED off',
        handler: (_) async {
          if (!available) return const CommandResult.fail('LED unavailable');
          _stopEffect();
          final ok = await _channel.invokeMethod<bool>('off') ?? false;
          if (ok) {
            _on = false;
            bus.publish(const LedStateChanged());
          }
          return ok
              ? const CommandResult.ok()
              : const CommandResult.fail('LED write failed');
        },
      ),
    );
    commands.register(
      Command(
        name: 'setLedEffect',
        description: 'Start (or clear, with "None") a built-in animation',
        params: {'effect': 'One of ${effects.join(', ')}, or "None" to clear'},
        handler: (p) async {
          if (!available) return const CommandResult.fail('LED unavailable');
          final requested = '${p['effect'] ?? 'None'}';
          if (requested == 'None' || !effects.contains(requested)) {
            _stopEffect();
            // Effects run brighter/dimmer than the base color; restore it
            // exactly so clearing the effect doesn't leave a stray frame.
            await _writeRaw(_r, _g, _b);
          } else {
            _startEffect(requested);
          }
          _on = true;
          bus.publish(const LedStateChanged());
          return const CommandResult.ok();
        },
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _effectTimer?.cancel();
  }

  /// The native answer, asked once detection has actually resolved (not a
  /// still-in-progress snapshot — see [_detectionSettled]). A failed or
  /// missing ask is not cached, so a bridge that was not ready gets asked
  /// again. Powers the Settings page's disabled-switch-with-reason row.
  Future<LedSupport> ledSupport() async {
    if (_support case final known?) return known;
    await _detectionSettled.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    if (_hardwareAvailable) return _support = const LedSupport(supported: true);
    try {
      final hint = await _channel.invokeMethod<String>('hint');
      return _support = LedSupport(supported: false, hint: hint);
    } catch (_) {
      return LedSupport.unknown;
    }
  }

  Future<bool> _writeRaw(int r, int g, int b) async {
    return await _channel.invokeMethod<bool>('setRgb', {
          'r': r.clamp(0, 255),
          'g': g.clamp(0, 255),
          'b': b.clamp(0, 255),
        }) ??
        false;
  }

  void _stopEffect() {
    _effectTimer?.cancel();
    _effectTimer = null;
    _effectStopwatch = null;
    _effect = 'None';
  }

  void _startEffect(String effect) {
    _effectTimer?.cancel();
    _effect = effect;
    final makeRunner = ledEffectRunners[effect];
    if (makeRunner != null) {
      final runner = makeRunner();
      _effectStopwatch = Stopwatch()..start();
      _effectTimer = Timer.periodic(runner.updateInterval, (_) {
        final (r, g, b) = runner.tick(_effectStopwatch!.elapsedMilliseconds, (_r, _g, _b));
        unawaited(_writeRaw(r, g, b));
      });
      return;
    }
    switch (effect) {
      case 'Pulse':
        _runPulse();
      case 'Strobe':
        _runStrobe();
      case 'Random':
        _runRandom();
      case 'Flicker':
        _runFlicker();
    }
  }

  /// Brightness ramps 0→max→0 over a 2s cycle (ESPHome's own Pulse default
  /// is a 1s-up/1s-down transition_length) — scales the stored base color
  /// rather than driving a separate dimmer, since the hardware has none.
  void _runPulse() {
    const periodMs = 2000;
    var elapsedMs = 0;
    _effectTimer = Timer.periodic(_tick, (_) {
      elapsedMs = (elapsedMs + _tick.inMilliseconds) % periodMs;
      final phase = elapsedMs / periodMs;
      final level = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
      unawaited(
        _writeRaw((_r * level).round(), (_g * level).round(), (_b * level).round()),
      );
    });
  }

  /// Rapid on/off at the stored base color — ESPHome's own Strobe effect
  /// defaults to exactly this when no explicit color sequence is given.
  void _runStrobe() {
    var on = true;
    _effectTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      on = !on;
      unawaited(_writeRaw(on ? _r : 0, on ? _g : 0, on ? _b : 0));
    });
  }

  /// A fresh random color every few seconds — ESPHome's Random effect
  /// transitions smoothly, but our 0..15 hardware resolution makes a
  /// transition invisible, so this jumps straight to each new color.
  void _runRandom() {
    final rnd = Random();
    void tick() =>
        unawaited(_writeRaw(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)));
    tick();
    _effectTimer = Timer.periodic(const Duration(seconds: 3), (_) => tick());
  }

  /// Jitters each channel of the base color by a small random amount every
  /// tick — a candle-like flicker. ESPHome's own default intensity (1.5%
  /// of 255) rounds to nothing at our 16-level hardware resolution, so
  /// this uses a stronger fraction to stay visible.
  void _runFlicker() {
    final rnd = Random();
    const intensity = 0.2;
    int jitter(int base) {
      final delta = (rnd.nextDouble() * 2 - 1) * 255 * intensity;
      return (base + delta).round().clamp(0, 255);
    }

    _effectTimer = Timer.periodic(
      _tick,
      (_) => unawaited(_writeRaw(jitter(_r), jitter(_g), jitter(_b))),
    );
  }
}
