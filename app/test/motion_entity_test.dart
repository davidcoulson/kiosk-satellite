import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/home_assistant/entity_list.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';
import 'package:kiosk_satellite/managers/motion/motion_entity_manager.dart';
import 'package:kiosk_satellite/managers/motion/motion_manager.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Motion from a Home Assistant entity in the camera's place (issue #973).
/// Home Assistant is left unconfigured, so no socket opens; the entity's
/// states are fed in as the subscription would deliver them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Where a test leaves camera motion wanted, the motion manager asks for
  // the camera permission: answer "denied" so the camera path stops there.
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'),
          (call) async => switch (call.method) {
            'checkPermissionStatus' => 0,
            'requestPermissions' => <dynamic, dynamic>{},
            'shouldShowRequestPermissionRationale' => true,
            _ => null,
          },
        );
  });

  const entity = 'binary_sensor.hallway_occupancy';
  const on = <String, Object>{
    'ks.motion.use_entity': true,
    'ks.motion.entity': entity,
  };

  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late Logger log;

  Future<void> build(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    bus = EventBus();
    log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
  }

  MotionEntityManager manager() => MotionEntityManager(
    bus,
    commands,
    log,
    settings,
    HomeAssistantManager(bus, commands, log, settings),
  );

  group('the entity manager', () {
    late MotionEntityManager motion;
    late List<ExternalMotionDetected> detected;
    late List<ExternalMotionChanged> changed;

    Future<void> start(Map<String, Object> prefs) async {
      await build(prefs);
      detected = [];
      changed = [];
      bus.on<ExternalMotionDetected>().listen(detected.add);
      bus.on<ExternalMotionChanged>().listen(changed.add);
      motion = manager();
      await motion.init();
      await pumpEventQueue();
    }

    tearDown(() => motion.dispose());

    test('reports nothing with the switch off', () async {
      await start({});
      expect((await commands.execute('getExternalMotion', const {})).data, {
        'enabled': false,
        'entity': '',
        'detected': null,
      });
      motion.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(detected, isEmpty);
      expect(motion.detected, isNull);
    });

    test(
      'a sensor already on is held, turning on again is an arrival',
      () async {
        await start(on);
        motion.applyEntityState(entity, 'on');
        await pumpEventQueue();
        expect(detected.map((e) => e.held), [true]);
        expect(motion.detected, isTrue);

        motion.applyEntityState(entity, 'off');
        await pumpEventQueue();
        expect(detected, hasLength(1));
        expect(motion.detected, isFalse);

        motion.applyEntityState(entity, 'on');
        await pumpEventQueue();
        expect(detected.map((e) => e.held), [true, false]);
        expect(changed.map((e) => e.detected), [true, false, true]);
        expect((await commands.execute('getExternalMotion', const {})).data, {
          'enabled': true,
          'entity': entity,
          'detected': true,
        });
      },
    );

    test(
      'unavailable is no reading, and coming back on from it is held',
      () async {
        await start(on);
        motion.applyEntityState(entity, 'off');
        motion.applyEntityState(entity, 'unavailable');
        await pumpEventQueue();
        expect(motion.detected, isNull);
        motion.applyEntityState(entity, 'on');
        await pumpEventQueue();
        expect(detected.map((e) => e.held), [true]);
      },
    );

    test('another entity is ignored', () async {
      await start(on);
      motion.applyEntityState('binary_sensor.kitchen_motion', 'on');
      await pumpEventQueue();
      expect(detected, isEmpty);
      expect(motion.detected, isNull);
    });

    test('turning the switch off forgets the state', () async {
      await start(on);
      motion.applyEntityState(entity, 'on');
      await pumpEventQueue();
      await settings.setFromJson(defs.motionUseEntity.key, false);
      await pumpEventQueue();
      expect(motion.detected, isNull);
      expect(changed.last.detected, isNull);
    });
  });

  test('a sensor that stays on repeats as held until it clears', () {
    fakeAsync((async) {
      build(on);
      async.flushMicrotasks();
      final detected = <ExternalMotionDetected>[];
      bus.on<ExternalMotionDetected>().listen(detected.add);
      final motion = manager();
      motion.init();
      async.flushMicrotasks();

      motion.applyEntityState(entity, 'off');
      motion.applyEntityState(entity, 'on');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 7));
      expect(detected.map((e) => e.held), [false, true, true, true]);

      motion.applyEntityState(entity, 'off');
      async.elapse(const Duration(seconds: 10));
      expect(detected, hasLength(4));
      motion.dispose();
      async.flushMicrotasks();
    });
  });

  group('the screensaver', () {
    late ScreensaverManager saver;

    Future<void> buildSaver(Map<String, Object> prefs) async {
      await build(prefs);
      saver = ScreensaverManager(bus, commands, log, settings);
      await saver.init();
    }

    test('an arrival dismisses, a held sensor does not', () async {
      await buildSaver({
        ...on,
        'ks.screensaver.enabled': true,
        'ks.screensaver.dismiss_on_motion': true,
      });
      addTearDown(saver.dispose);
      await saver.start();
      await pumpEventQueue();
      expect(saver.isActive, isTrue);

      bus.publish(const ExternalMotionDetected(held: true));
      await pumpEventQueue();
      expect(saver.isActive, isTrue);

      bus.publish(const ExternalMotionDetected());
      await pumpEventQueue();
      expect(saver.isActive, isFalse);
    });

    test('camera motion is ignored while the entity stands in', () async {
      await buildSaver({
        ...on,
        'ks.screensaver.enabled': true,
        'ks.screensaver.dismiss_on_motion': true,
      });
      addTearDown(saver.dispose);
      await saver.start();
      await pumpEventQueue();
      bus.publish(const MotionDetected());
      await pumpEventQueue();
      expect(saver.isActive, isTrue);
    });

    test('the entity is ignored with the switch off', () async {
      await buildSaver({
        'ks.screensaver.enabled': true,
        'ks.screensaver.dismiss_on_motion': true,
      });
      addTearDown(saver.dispose);
      await saver.start();
      await pumpEventQueue();
      bus.publish(const ExternalMotionDetected());
      await pumpEventQueue();
      expect(saver.isActive, isTrue);
    });

    test('Postpone on motion: a held sensor keeps the screensaver off', () {
      fakeAsync((async) {
        buildSaver({
          ...on,
          'ks.screensaver.enabled': true,
          'ks.screensaver.timeout_seconds': 10,
          'ks.screensaver.dismiss_on_motion': true,
          'ks.screensaver.postpone_on_motion': true,
        });
        async.flushMicrotasks();
        bus.publish(const ActivityDetected(source: 'touch'));
        async.flushMicrotasks();
        for (var i = 0; i < 15; i++) {
          async.elapse(const Duration(seconds: 2));
          bus.publish(const ExternalMotionDetected(held: true));
          async.flushMicrotasks();
        }
        expect(saver.isActive, isFalse);

        // The sensor cleared: the clock runs out.
        async.elapse(const Duration(seconds: 11));
        expect(saver.isActive, isTrue);
        saver.dispose();
        async.flushMicrotasks();
      });
    });
  });

  test('the camera stops watching for screensaver motion, and faces stay '
      'behind Dismiss on motion', () async {
    await build({
      'ks.camera.enabled': true,
      'ks.screensaver.dismiss_on_motion': true,
    });
    final camera = MotionManager(bus, commands, log, settings);
    await camera.init();
    addTearDown(camera.dispose);
    expect(camera.enabled, isTrue);

    await settings.setFromJson(defs.motionUseEntity.key, true);
    await pumpEventQueue();
    expect(camera.enabled, isFalse);
    expect(camera.faceEnabled, isFalse);
  });

  test('the occupancy filter keeps occupancy, motion and presence binary '
      'sensors', () {
    const entities = <Map<String, Object?>>[
      {
        'entity_id': 'binary_sensor.hallway_occupancy',
        'domain': 'binary_sensor',
        'device_class': 'occupancy',
      },
      {
        'entity_id': 'binary_sensor.porch_motion',
        'domain': 'binary_sensor',
        'device_class': 'motion',
      },
      {
        'entity_id': 'binary_sensor.office_presence',
        'domain': 'binary_sensor',
        'device_class': 'presence',
      },
      {
        'entity_id': 'binary_sensor.front_door',
        'domain': 'binary_sensor',
        'device_class': 'door',
      },
      {
        'entity_id': 'sensor.hallway_motion_count',
        'domain': 'sensor',
        'device_class': 'motion',
      },
    ];
    expect(
      [
        for (final e in filterEntities(entities, deviceClass: 'occupancy'))
          e['entity_id'],
      ],
      [
        'binary_sensor.hallway_occupancy',
        'binary_sensor.porch_motion',
        'binary_sensor.office_presence',
      ],
    );
  });
}
