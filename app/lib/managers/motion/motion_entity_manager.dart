import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../home_assistant/home_assistant_manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// Motion from a Home Assistant occupancy, motion or presence sensor in
/// the camera's place (issue #973), for a tablet whose camera does not
/// work or a room that already has a sensor. The screensaver takes
/// [ExternalMotionDetected] as motion under Dismiss on motion and
/// Postpone on motion, and the motion manager stops binding the camera
/// for those two while the switch is on.
///
/// The entity reports a state, not ticks, so it is turned into the person
/// sensor's shape: turning on is an arrival, and while it stays on a held
/// repeat every [holdInterval] keeps Postpone on motion holding the idle
/// clock. A held one never dismisses, so a screensaver that starts with
/// the sensor still on is not dismissed by it (the loop of issue #369).
/// The first state after the subscription opens is held too: the sensor
/// was already on, nobody arrived.
///
/// The entity is watched over a subscription of this app's own, open only
/// while the switch is on and an entity is picked, so Home Assistant sends
/// this one entity and nothing else.
class MotionEntityManager extends Manager {
  MotionEntityManager(
    super.bus,
    super.commands,
    super.log,
    this._settings,
    this._ha, {
    this.holdInterval = const Duration(seconds: 2),
  });

  final SettingsManager _settings;
  final HomeAssistantManager _ha;

  /// How often a sensor that stays on repeats as held. Injectable for
  /// tests only.
  final Duration holdInterval;

  @override
  String get name => 'motion-entity';

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  GlanceSubscription? _live;
  String? _liveEntity;
  Timer? _retry;
  Timer? _hold;
  bool _opening = false;

  /// Bumped on every close, so a subscription that finishes connecting
  /// after its owner moved on closes itself instead of taking over.
  int _generation = 0;

  /// The entity's state: true on, false off, null before it reports, while
  /// it reads unavailable or unknown, and while nothing keeps it current.
  bool? _detected;
  bool? get detected => _detected;

  /// Whether the last state the entity sent was neither on nor off, so the
  /// warning is logged once per run of bad states, not on every update.
  bool _warnedState = false;

  /// The entity picked, or empty while the camera is the source.
  String get _entity => _settings.get(defs.motionUseEntity)
      ? _settings.get(defs.motionEntity).trim()
      : '';

  @override
  Future<void> init() async {
    _subscriptions.add(
      bus.on<SettingChanged>().listen((e) {
        // Another server or token: the open socket is the old one's.
        if (e.key == defs.haUrl.key || e.key == defs.haToken.key) _close();
        if (e.key == defs.motionUseEntity.key ||
            e.key == defs.motionEntity.key) {
          final entity = _entity;
          log.info(
            name,
            !_settings.get(defs.motionUseEntity)
                ? 'motion from the camera'
                : 'motion from ${entity.isEmpty ? 'no entity yet' : entity}',
          );
        }
        if (e.key == defs.motionUseEntity.key ||
            e.key == defs.motionEntity.key ||
            e.key == defs.haUrl.key ||
            e.key == defs.haToken.key) {
          unawaited(_sync());
        }
      }),
    );

    commands.register(
      Command(
        name: 'getExternalMotion',
        description:
            'The Home Assistant entity motion comes from in place of the '
            'camera, and whether it reads detected (null before it reports)',
        handler: (_) async => CommandResult.ok({
          'enabled': _settings.get(defs.motionUseEntity),
          'entity': _settings.get(defs.motionEntity),
          'detected': _detected,
        }),
      ),
    );

    // Not awaited: Home Assistant may take a while to answer.
    unawaited(_sync());
  }

  /// Open the entity's subscription when the switch wants it, close it
  /// when not.
  Future<void> _sync() async {
    final entity = _entity;
    if (entity.isEmpty) {
      _close();
      return;
    }
    if (_liveEntity == entity) {
      // Opening already, or open and alive.
      final current = _live;
      if (current == null ? _opening : !current.isClosed) return;
    }
    await _open(entity);
  }

  Future<void> _open(String entity) async {
    _close();
    final generation = _generation;
    _liveEntity = entity;
    _opening = true;
    final live = await _ha.subscribeEntities([entity], _onState);
    if (generation != _generation) {
      // Closed or reopened for another entity while this one connected.
      await live?.close();
      return;
    }
    _opening = false;
    if (live == null) {
      // Home Assistant not set up yet, unreachable or restarting: try
      // again shortly.
      _retryIn(const Duration(seconds: 20));
      return;
    }
    live.onClosed = () {
      if (_live != live) return;
      log.debug(name, 'subscription dropped; reopening');
      _live = null;
      // Nothing keeps the state current now: a sensor left on must not
      // hold the screensaver off until the socket comes back.
      _setDetected(null);
      _retryIn(const Duration(seconds: 5));
    };
    _live = live;
    log.debug(name, 'watching $entity');
  }

  void _retryIn(Duration delay) {
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      _liveEntity = null;
      unawaited(_sync());
    });
  }

  void _close() {
    _generation++;
    _opening = false;
    _retry?.cancel();
    _retry = null;
    final live = _live;
    _live = null;
    _liveEntity = null;
    if (live != null) unawaited(live.close());
    _setDetected(null);
  }

  void _onState(String entityId, Map<String, Object?> state) =>
      applyEntityState(entityId, state['state']);

  /// One state from the subscription: `on` is detected, `off` clear, and
  /// anything else (unavailable, unknown) is no reading.
  @visibleForTesting
  void applyEntityState(String entityId, Object? state) {
    if (entityId != _entity) return;
    final detected = switch ('$state') {
      'on' => true,
      'off' => false,
      _ => null,
    };
    if (detected == null) {
      if (!_warnedState) {
        _warnedState = true;
        log.warn(name, '$entityId reads "$state", not on or off');
      }
    } else {
      _warnedState = false;
    }
    final arrived = detected == true && _detected == false;
    if (!_setDetected(detected)) return;
    if (detected == true) {
      log.debug(name, arrived ? 'motion' : 'motion already on');
      bus.publish(ExternalMotionDetected(held: !arrived));
    }
  }

  /// Record the state, and start or stop the held repeats with it. False
  /// when nothing changed.
  bool _setDetected(bool? detected) {
    if (detected == _detected) return false;
    _detected = detected;
    _hold?.cancel();
    _hold = detected == true
        ? Timer.periodic(holdInterval, (_) {
            if (_detected != true) return;
            bus.publish(const ExternalMotionDetected(held: true));
          })
        : null;
    bus.publish(ExternalMotionChanged(detected: detected));
    return true;
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _retry?.cancel();
    _retry = null;
    _hold?.cancel();
    _hold = null;
    final live = _live;
    _live = null;
    await live?.close();
  }
}
