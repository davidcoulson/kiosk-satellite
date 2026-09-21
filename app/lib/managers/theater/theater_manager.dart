import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// Where theater mode is: off, or on in one of three phases.
enum TheaterPhase { off, dim, peek, black }

/// What the overlay layer draws for the current phase. Kept apart from the
/// manager's state so the widget rebuilds on exactly what it paints.
@immutable
class TheaterView {
  const TheaterView({
    required this.phase,
    required this.opacity,
    required this.absorbTouches,
  });

  static const off = TheaterView(
    phase: TheaterPhase.off,
    opacity: 0,
    absorbTouches: false,
  );

  final TheaterPhase phase;

  /// How dark the black layer over the page is, 0..1.
  final double opacity;

  /// Whether a touch landing now is kept from the page. True while dimmed
  /// (when the first touch should only wake) and while black.
  final bool absorbTouches;

  bool get active => phase != TheaterPhase.off;

  @override
  bool operator ==(Object other) =>
      other is TheaterView &&
      other.phase == phase &&
      other.opacity == opacity &&
      other.absorbTouches == absorbTouches;

  @override
  int get hashCode => Object.hash(phase, opacity, absorbTouches);
}

/// Theater mode: a panel darker than its backlight can go, that people moving
/// in a dark room do not light up, that one touch brings up to readable, and
/// that puts everything back as it was afterwards.
///
/// It is runtime state and never a setting. Nothing here is stored, so a
/// crash, a force stop or a reboot always comes back with it off and the
/// panel at its stored brightness; whatever turned it on (Home Assistant, the
/// page) can turn it on again. Brightness goes through the screen manager's
/// hold, which stores nothing either.
///
/// The phases are one brightness hold at three levels plus an overlay:
///
/// * dim   -- the theater backlight, a black layer at the dimming setting,
///            and (by default) a first touch that only wakes;
/// * peek  -- the peek brightness, no layer, touches reach the page; it
///            lasts a few seconds after the last touch, or for as long as an
///            alert is showing;
/// * black -- the panel minimum under an opaque layer, after a long spell
///            with no touch. The screen stays on and the page keeps
///            rendering, so the next peek shows a current page.
class TheaterManager extends Manager {
  TheaterManager(super.bus, super.commands, super.log, this._settings);

  final SettingsManager _settings;

  @override
  String get name => 'theater';

  /// Whether a main-view page at [origin] is one theater mode may stay on
  /// for: the start page, Home Assistant, or the loopback proxy serving
  /// either. Set by the container, which knows those; null keeps it on for
  /// any page, which is what a test with no browser behind it wants.
  bool Function(Uri origin)? isTrustedOrigin;

  /// What the overlay draws.
  final view = ValueNotifier<TheaterView>(TheaterView.off);

  TheaterPhase _phase = TheaterPhase.off;
  String _source = '';
  DateTime? _since;

  /// Options the caller set for this activation, over the settings.
  Map<String, Object?> _overrides = const {};

  /// Where a peek goes back to: dim after a touch, or whatever an alert
  /// interrupted.
  TheaterPhase _returnPhase = TheaterPhase.dim;

  /// Alerts showing now (a voice turn, a notification card, a camera view,
  /// the intercom, an overlay page). A peek lasts while any is.
  final _alerts = <String>{};

  Timer? _peekTimer;
  Timer? _blackTimer;
  Timer? _capTimer;
  final _subs = <StreamSubscription<Object?>>[];

  TheaterPhase get phase => _phase;
  bool get active => _phase != TheaterPhase.off;

  // ── Options ─────────────────────────────────────────────────────────

  double _num(String key, defs.SettingDef<num> def, double lo, double hi) {
    final raw = _overrides[key];
    final v = raw is num ? raw.toDouble() : _settings.get(def).toDouble();
    return v.clamp(lo, hi).toDouble();
  }

  double get _backlight => _num('backlight', defs.theaterBacklight, 0, 1);
  double get _overlayOpacity =>
      _num('overlayOpacity', defs.theaterOverlayOpacity, 0, 0.95);
  double get _peekBrightness =>
      _num('peekBrightness', defs.theaterPeekBrightness, 0, 1);
  double get _peekSeconds =>
      _num('peekSeconds', defs.theaterPeekSeconds, 3, 60);
  double get _blackAfterMinutes =>
      _num('blackAfterMinutes', defs.theaterBlackAfterMinutes, 0, 240);
  bool get _firstTouchWakes {
    final raw = _overrides['firstTouchWakes'];
    return raw is bool ? raw : _settings.get(defs.theaterFirstTouchWakes);
  }

  /// The per-activation options a caller may pass, with anything else
  /// dropped: an unknown key is ignored rather than refused, so a page built
  /// against a later version still turns theater mode on.
  static Map<String, Object?> _pickOptions(Map<String, Object?> p) => {
    for (final key in const [
      'backlight',
      'overlayOpacity',
      'peekBrightness',
      'peekSeconds',
      'blackAfterMinutes',
    ])
      if (p[key] is num) key: p[key],
    if (p['firstTouchWakes'] is bool) 'firstTouchWakes': p['firstTouchWakes'],
  };

  // ── Lifecycle ───────────────────────────────────────────────────────

  @override
  Future<void> init() async {
    commands
      ..register(
        Command(
          name: 'setTheaterMode',
          description:
              'Turn theater mode on or off. Options apply to this '
              'activation only: backlight, overlayOpacity, peekBrightness, '
              'peekSeconds, blackAfterMinutes, firstTouchWakes.',
          params: const {
            'active': 'true to turn it on, false to turn it off',
            'backlight': 'optional 0..1: backlight while dimmed',
            'overlayOpacity': 'optional 0..0.95: how dark the dimming layer',
            'peekBrightness': 'optional 0..1: backlight while peeking',
            'peekSeconds': 'optional 3..60: how long a peek lasts',
            'blackAfterMinutes': 'optional 0..240: go black after; 0 never',
            'firstTouchWakes': 'optional: the first touch only wakes',
            'source': "optional: who is asking ('page', 'ha', 'link')",
          },
          handler: (p) async {
            final on = p['active'];
            if (on is! bool) {
              return const CommandResult.fail('active must be true or false');
            }
            final source = p['source'] is String
                ? p['source'] as String
                : 'remote';
            if (on) {
              await activate(_pickOptions(p), source: source);
            } else {
              await deactivate(source: source);
            }
            return const CommandResult.ok(true);
          },
        ),
      )
      ..register(
        Command(
          name: 'getTheaterMode',
          description: 'Theater mode state: active, phase, source, since.',
          handler: (_) async => CommandResult.ok(state),
        ),
      )
      ..register(
        Command(
          name: 'theaterPeek',
          description:
              'Brighten a dimmed or black panel for a while. False when '
              'theater mode is off.',
          params: const {'seconds': 'optional: how long, 3..600'},
          handler: (p) async {
            final seconds = (p['seconds'] as num?)?.toDouble();
            return CommandResult.ok(
              await peek(
                seconds: seconds,
                source: p['source'] is String
                    ? p['source'] as String
                    : 'remote',
              ),
            );
          },
        ),
      );

    _subs
      // People moving in a dark room: nothing, unless the owner wants them
      // to light the panel (IX-5). They still reach Home Assistant, which
      // listens on the bus for itself.
      ..add(bus.on<MotionDetected>().listen((_) => _ambient()))
      ..add(bus.on<FaceDetected>().listen((_) => _ambient()))
      ..add(bus.on<ProximityDetected>().listen((_) => _ambient()))
      ..add(bus.on<PersonDetected>().listen((_) => _ambient()))
      // Alerts peek while they show (IX-6). A media interaction is the
      // opposite of an alert: music bracketed for its whole length would
      // hold the panel bright for the film.
      ..add(
        bus.on<VoiceInteractionChanged>().listen((e) {
          if (e.reason == 'media') return;
          final key = 'voice:${e.reason}';
          e.active ? _alertOn(key) : _alertOff(key);
        }),
      )
      ..add(
        bus.on<NotificationsChanged>().listen(
          (e) => e.showing
              ? _alertOn('notifications')
              : _alertOff('notifications'),
        ),
      )
      ..add(
        bus.on<CameraViewStateChanged>().listen(
          (e) => e.active ? _alertOn('camera') : _alertOff('camera'),
        ),
      )
      ..add(
        bus.on<IntercomStateChanged>().listen((e) {
          final state = e.status['state'];
          final busy = state is String && state != 'idle' && state.isNotEmpty;
          busy ? _alertOn('intercom') : _alertOff('intercom');
        }),
      )
      // A screen woken while theater mode is on comes back dimmed, not at
      // the stored brightness (IX-4).
      ..add(
        bus.on<ScreenStateChanged>().listen((e) {
          if (e.on && active && _phase != TheaterPhase.dim) {
            unawaited(_enter(TheaterPhase.dim, source: _source));
          }
        }),
      )
      ..add(bus.on<PageChanged>().listen((e) => _onPageLoaded(e.url)));
  }

  @override
  Future<void> dispose() async {
    _peekTimer?.cancel();
    _blackTimer?.cancel();
    _capTimer?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    view.dispose();
  }

  /// The state getTheaterMode answers with.
  Map<String, Object?> get state => {
    'active': active,
    'phase': _phase.name,
    'source': _source,
    'backlight': _backlight,
    'overlayOpacity': _overlayOpacity,
    'peekSeconds': _peekSeconds,
    'since': _since?.toIso8601String(),
  };

  // ── Transitions ─────────────────────────────────────────────────────

  /// Turn theater mode on with [options] for this activation. Already on,
  /// the options apply in place, with no leaving and re-entering (TM-9).
  Future<void> activate(
    Map<String, Object?> options, {
    required String source,
  }) async {
    if (active) {
      _overrides = {..._overrides, ...options};
      // Re-apply the current phase with the new levels; no transition.
      await _apply(_phase);
      _restartBlackTimer();
      return;
    }
    _overrides = Map.of(options);
    _alerts.clear();
    _since = DateTime.now();
    _capTimer?.cancel();
    final hours = _settings
        .get(defs.theaterMaxHours)
        .toDouble()
        .clamp(0.05, 24.0);
    _capTimer = Timer(
      Duration(milliseconds: (hours * 3600 * 1000).round()),
      () => unawaited(deactivate(source: 'timeout')),
    );
    await _enter(TheaterPhase.dim, source: source);
  }

  /// Turn theater mode off and put the panel back. Idempotent.
  Future<void> deactivate({required String source}) async {
    if (!active) return;
    _peekTimer?.cancel();
    _blackTimer?.cancel();
    _capTimer?.cancel();
    _alerts.clear();
    _overrides = const {};
    _phase = TheaterPhase.off;
    _source = source;
    _since = DateTime.now();
    view.value = TheaterView.off;
    await commands.execute('releaseBrightness', const {});
    log.info(name, 'off ($source)');
    _publish();
  }

  /// Brighten the panel for [seconds], or the peek setting. False when
  /// theater mode is off.
  Future<bool> peek({double? seconds, String source = 'remote'}) async {
    if (!active) return false;
    if (_phase != TheaterPhase.peek) _returnPhase = TheaterPhase.dim;
    final wait = (seconds ?? _peekSeconds).clamp(3.0, 600.0);
    if (_phase != TheaterPhase.peek) {
      await _enter(TheaterPhase.peek, source: source);
    }
    _schedulePeekEnd(Duration(milliseconds: (wait * 1000).round()));
    return true;
  }

  /// A finger landed on the panel. The overlay calls this for every touch,
  /// absorbed or passed through; it is what keeps a peek going.
  void touch() {
    if (!active) return;
    _returnPhase = TheaterPhase.dim;
    if (_phase == TheaterPhase.peek) {
      // A touch mid-alert keeps the peek open for as long as the alert is.
      if (_alerts.isEmpty) _schedulePeekEnd(_peekDuration);
      return;
    }
    unawaited(peek(source: _source));
  }

  Duration get _peekDuration =>
      Duration(milliseconds: (_peekSeconds * 1000).round());

  void _schedulePeekEnd(Duration after) {
    _peekTimer?.cancel();
    _peekTimer = Timer(after, () {
      if (_phase != TheaterPhase.peek || _alerts.isNotEmpty) return;
      unawaited(_enter(_returnPhase, source: _source));
    });
  }

  void _restartBlackTimer() {
    _blackTimer?.cancel();
    if (_phase != TheaterPhase.dim) return;
    final minutes = _blackAfterMinutes;
    if (minutes <= 0) return;
    _blackTimer = Timer(
      Duration(milliseconds: (minutes * 60 * 1000).round()),
      () {
        if (_phase == TheaterPhase.dim) {
          unawaited(_enter(TheaterPhase.black, source: _source));
        }
      },
    );
  }

  Future<void> _enter(TheaterPhase next, {required String source}) async {
    final was = _phase;
    _phase = next;
    _source = source;
    if (next != TheaterPhase.peek) _peekTimer?.cancel();
    await _apply(next);
    _restartBlackTimer();
    if (was != next) {
      log.info(name, '${next.name} ($source)');
      _publish();
    }
  }

  /// Put [phase] on the panel: the brightness hold and the overlay.
  Future<void> _apply(TheaterPhase phase) async {
    switch (phase) {
      case TheaterPhase.off:
        return;
      case TheaterPhase.dim:
        view.value = TheaterView(
          phase: phase,
          opacity: _overlayOpacity,
          absorbTouches: _firstTouchWakes,
        );
        await _hold(_backlight);
      case TheaterPhase.peek:
        view.value = TheaterView(
          phase: phase,
          opacity: 0,
          absorbTouches: false,
        );
        await _hold(_peekBrightness);
      case TheaterPhase.black:
        view.value = const TheaterView(
          phase: TheaterPhase.black,
          opacity: 1,
          absorbTouches: true,
        );
        await _hold(0);
    }
  }

  Future<void> _hold(double level) =>
      commands.execute('holdBrightness', {'level': level});

  void _publish() => bus.publish(
    TheaterModeChanged(active: active, phase: _phase.name, source: _source),
  );

  // ── Inputs ──────────────────────────────────────────────────────────

  void _ambient() {
    if (!active || _settings.get(defs.theaterIgnoreAmbientWake)) return;
    unawaited(peek(source: _source));
  }

  void _alertOn(String key) {
    if (!active || !_settings.get(defs.theaterPeekOnAlerts)) return;
    if (!_alerts.add(key)) return;
    _peekTimer?.cancel();
    if (_phase == TheaterPhase.peek) return;
    _returnPhase = _phase;
    unawaited(_enter(TheaterPhase.peek, source: _source));
  }

  void _alertOff(String key) {
    if (!_alerts.remove(key)) return;
    if (_alerts.isEmpty && _phase == TheaterPhase.peek) {
      _schedulePeekEnd(_peekDuration);
    }
  }

  /// A full document load in the main view. Another site ends theater mode
  /// (TM-10): the dimming exists for the pages the owner pointed the kiosk
  /// at, and an unknown page under it would be unreadable with no obvious
  /// way out. Either way the page is told the current state once, so a
  /// Showtime screen reloading mid-film catches up (TM-12).
  void _onPageLoaded(String url) {
    final uri = Uri.tryParse(url);
    final trusted = isTrustedOrigin;
    if (active &&
        uri != null &&
        uri.hasScheme &&
        trusted != null &&
        !trusted(uri)) {
      unawaited(deactivate(source: 'navigation'));
      return;
    }
    _publish();
  }
}
