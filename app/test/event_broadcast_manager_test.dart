import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/broadcasts/event_broadcast_manager.dart';

/// What the Android broadcasts of issue #964 say, from the bus events the
/// voice, intercom, alarm and screensaver managers already publish.
void main() {
  late EventBus bus;
  late EventBroadcastManager manager;
  late List<(String, Map<String, Object?>)> sent;

  setUp(() async {
    bus = EventBus();
    final log = Logger();
    sent = [];
    manager = EventBroadcastManager(
      bus,
      CommandRegistry(log),
      log,
      send: (name, extras) async => sent.add((name, extras)),
    );
    await manager.init();
  });

  tearDown(() async {
    await manager.dispose();
    await bus.dispose();
  });

  Future<List<String>> publish(List<AppEvent> events) async {
    events.forEach(bus.publish);
    await pumpEventQueue();
    return [for (final (name, _) in sent) name];
  }

  VoiceInteractionChanged hold(
    bool active,
    String reason, {
    InteractionSource source = InteractionSource.native,
  }) => VoiceInteractionChanged(active: active, reason: reason, source: source);

  test(
    'a turn starts, moves through its states and ends with the overlay',
    () async {
      final names = await publish([
        hold(true, 'voice'),
        const AssistOverlayVisibility(true),
        const VoiceSatelliteStateChanged('listening'),
        const VoiceSatelliteStateChanged('processing'),
        const VoiceSatelliteStateChanged('responding'),
        const VoiceSatelliteStateChanged('idle'),
        hold(false, 'voice'),
      ]);
      expect(names, [
        'VS_STARTED',
        'VS_LISTENING',
        'VS_THINKING',
        'VS_SPEAKING',
      ]);
      expect(sent.first.$2, {'reason': 'voice'});

      // The answer lingers on screen: the turn is not over until it goes.
      expect(
        (await publish([const AssistOverlayVisibility(false)])).last,
        'VS_ENDED',
      );
    },
  );

  test('a turn hidden at once ends when its hold drops', () async {
    final names = await publish([
      hold(true, 'voice'),
      const AssistOverlayVisibility(true),
      const AssistOverlayVisibility(false),
      hold(false, 'voice'),
    ]);
    expect(names, ['VS_STARTED', 'VS_ENDED']);
  });

  test('a follow-up after an announcement stays one interaction', () async {
    final names = await publish([
      hold(true, 'announcement'),
      const AssistOverlayVisibility(true),
      const VoiceSatelliteStateChanged('responding', announcement: true),
      hold(true, 'voice'),
      const VoiceSatelliteStateChanged('listening'),
      const VoiceSatelliteStateChanged('processing'),
      const VoiceSatelliteStateChanged('responding'),
      const VoiceSatelliteStateChanged('idle'),
      const VoiceInteractionChanged(
        active: false,
        source: InteractionSource.native,
      ),
      const AssistOverlayVisibility(false),
    ]);
    expect(names, [
      'VS_STARTED',
      'VS_ANNOUNCEMENT',
      'VS_LISTENING',
      'VS_THINKING',
      'VS_SPEAKING',
      'VS_ENDED',
    ]);
    expect(sent.first.$2, {'reason': 'announcement'});
  });

  test(
    'holds that are not the built-in Voice Satellite send nothing',
    () async {
      final names = await publish([
        hold(true, 'alarm'),
        hold(true, 'voice', source: InteractionSource.page),
        hold(true, 'media', source: InteractionSource.sendspin),
        hold(true, 'intercom', source: InteractionSource.command),
        hold(false, 'alarm'),
      ]);
      expect(names, isEmpty);
    },
  );

  test('timer and alarm events go out with their fields as extras', () async {
    final names = await publish([
      const HaEventRequested('kiosk_satellite_timer', {
        'event_type': 'finished',
        'timer_id': 't1',
        'name': 'pasta',
        'total_seconds': 600,
        'seconds_left': 0,
        'is_active': false,
      }),
      const HaEventRequested('kiosk_satellite_alarm', {
        'event_type': 'ringing',
        'alarm_id': 'a1',
        'label': 'Work',
        'time': '07:00',
        'days': ['mon', 'tue'],
        'enabled': true,
      }),
      const HaEventRequested('something_else', {'event_type': 'x'}),
    ]);
    expect(names, ['VS_TIMER_FINISHED', 'ALARM_RINGING']);
    expect(sent[0].$2, {
      'timer_id': 't1',
      'name': 'pasta',
      'total_seconds': 600,
      'seconds_left': 0,
      'is_active': false,
    });
    expect(sent[1].$2['days'], ['mon', 'tue']);
    expect(sent[1].$2.containsKey('event_type'), isFalse);
  });

  Map<String, Object?> intercom(String state, [String peer = '']) => {
    'state': state,
    if (peer.isNotEmpty)
      'call': {
        'peer': {'name': peer},
      },
    'kiosks': const [],
  };

  test(
    'a call rings, connects and ends once, naming the other kiosk',
    () async {
      final names = await publish([
        IntercomStateChanged(intercom('ringing', 'Kitchen')),
        IntercomStateChanged(intercom('ringing', 'Kitchen')),
        IntercomStateChanged(intercom('in_call', 'Kitchen')),
        IntercomStateChanged(intercom('ended', 'Kitchen')),
        IntercomStateChanged(intercom('idle')),
      ]);
      expect(names, ['INTERCOM_RINGING', 'INTERCOM_IN_CALL', 'INTERCOM_ENDED']);
      for (final (_, extras) in sent) {
        expect(extras, {'kiosk': 'Kitchen'});
      }
    },
  );

  test('a missed call says so and still ends', () async {
    final names = await publish([
      IntercomStateChanged(intercom('ringing', 'Office')),
      IntercomStateChanged(intercom('missed', 'Office')),
      IntercomStateChanged(intercom('idle')),
    ]);
    expect(names, ['INTERCOM_RINGING', 'INTERCOM_MISSED', 'INTERCOM_ENDED']);
  });

  test('the peer from the last call does not leak into the next', () async {
    await publish([
      IntercomStateChanged(intercom('in_call', 'Kitchen')),
      IntercomStateChanged(intercom('idle')),
      IntercomStateChanged(intercom('broadcasting')),
    ]);
    expect(sent.last.$1, 'INTERCOM_BROADCASTING');
    expect(sent.last.$2, {'kiosk': ''});
  });

  test('the screensaver reports only real changes', () async {
    final names = await publish([
      const ScreensaverStateChanged(active: false),
      const ScreensaverStateChanged(active: true),
      const ScreensaverStateChanged(active: true),
      const ScreensaverStateChanged(active: false),
    ]);
    expect(names, ['SCREENSAVER_STARTED', 'SCREENSAVER_STOPPED']);
  });
}
