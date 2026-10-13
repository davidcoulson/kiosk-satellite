import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Wake to screensaver": a detection under a dark panel powers the screen
/// on and leaves the screensaver up with a fresh screen-off countdown,
/// the way the ESPHome Screen light does. Touch still lands on the
/// dashboard, and a lit panel keeps the normal dismiss rules.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late SettingsManager settings;
  late ScreensaverManager saver;
  late List<String> screenCalls;
  late List<FaceDismissedScreensaver> previews;

  Future<void> build(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.enabled': true,
      'ks.screensaver.mode': 'black',
      ...initial,
    });
    bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    final calls = <String>[];
    screenCalls = calls;
    for (final name in ['screenOn', 'screenOff']) {
      commands.register(
        Command(
          name: name,
          description: 'Record screen power requests',
          handler: (_) async {
            calls.add(name);
            bus.publish(
              ScreenStateChanged(on: name == 'screenOn', source: 'app'),
            );
            return const CommandResult.ok();
          },
        ),
      );
    }
    previews = [];
    bus.on<FaceDismissedScreensaver>().listen(previews.add);
    saver = ScreensaverManager(bus, commands, log, settings);
    await saver.init();
  }

  const wakeKey = 'ks.screensaver.screen_off_wake_to_screensaver';

  for (final (kind, event) in [
    ('motion', const MotionDetected()),
    ('face', const FaceDetected()),
    ('proximity', const ProximityDetected()),
    ('person', const PersonDetected()),
  ]) {
    final dismissKey = 'ks.screensaver.dismiss_on_$kind';

    test('$kind under a dark panel relights the screensaver and re-arms', () {
      fakeAsync((async) {
        build({
          dismissKey: true,
          wakeKey: true,
          'ks.screensaver.timeout_seconds': 60,
          'ks.screensaver.screen_off_minutes': 5,
        });
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));
        expect(saver.isActive, isTrue);
        async.elapse(const Duration(minutes: 5));
        expect(screenCalls, ['screenOff']);
        expect(saver.isActive, isTrue);

        // The detection lights the panel and nothing more.
        bus.publish(event);
        async.flushMicrotasks();
        expect(saver.isActive, isTrue);
        expect(screenCalls, ['screenOff', 'screenOn']);
        expect(previews, isEmpty);

        // A fresh countdown runs from the wake, and the room going quiet
        // powers the panel off again.
        async.elapse(const Duration(minutes: 4));
        expect(screenCalls, ['screenOff', 'screenOn']);
        async.elapse(const Duration(minutes: 1));
        expect(screenCalls, ['screenOff', 'screenOn', 'screenOff']);
        expect(saver.isActive, isTrue);

        // Relit again, then a touch is what opens the dashboard.
        bus.publish(event);
        async.flushMicrotasks();
        expect(saver.isActive, isTrue);
        bus.publish(const ActivityDetected(source: 'touch'));
        async.flushMicrotasks();
        expect(saver.isActive, isFalse);
      });
    });

    test('$kind on a lit screensaver still dismisses with the switch on', () {
      fakeAsync((async) {
        build({
          dismissKey: true,
          wakeKey: true,
          'ks.screensaver.timeout_seconds': 60,
          'ks.screensaver.screen_off_minutes': 5,
        });
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));
        expect(saver.isActive, isTrue);
        bus.publish(event);
        async.flushMicrotasks();
        expect(saver.isActive, isFalse);
        expect(screenCalls, ['screenOn']);
      });
    });

    test('$kind under a dark panel wakes the dashboard by default', () {
      fakeAsync((async) {
        build({
          dismissKey: true,
          'ks.screensaver.timeout_seconds': 60,
          'ks.screensaver.screen_off_minutes': 5,
        });
        async.flushMicrotasks();
        expect(settings.get(defs.screensaverScreenOffWakeToScreensaver), '[]');
        async.elapse(const Duration(minutes: 6));
        expect(screenCalls, ['screenOff']);
        bus.publish(event);
        async.flushMicrotasks();
        expect(saver.isActive, isFalse);
        expect(screenCalls, ['screenOff', 'screenOn']);
      });
    });

    test('$kind under a dark panel still needs its dismiss switch', () {
      fakeAsync((async) {
        build({
          dismissKey: false,
          wakeKey: true,
          'ks.screensaver.timeout_seconds': 60,
          'ks.screensaver.screen_off_minutes': 5,
        });
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 6));
        expect(screenCalls, ['screenOff']);
        bus.publish(event);
        async.flushMicrotasks();
        expect(saver.isActive, isTrue);
        expect(screenCalls, ['screenOff']);
      });
    });

    test('$kind under a dark panel holds under lockdown', () {
      fakeAsync((async) {
        build({
          dismissKey: true,
          wakeKey: true,
          'ks.lockdown.enabled': true,
          'ks.lockdown.allow_screensaver': true,
          'ks.screensaver.timeout_seconds': 60,
          'ks.screensaver.screen_off_minutes': 5,
        });
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 6));
        expect(screenCalls, ['screenOff']);
        bus.publish(event);
        async.flushMicrotasks();
        expect(saver.isActive, isTrue);
        expect(screenCalls, ['screenOff']);
      });
    });
  }

  // A wake the app did not ask for (power button, the Echo Show's mute
  // button, double-tap to wake) follows the switch too (issue #952).
  test('a system wake under a dark panel relights the screensaver', () {
    fakeAsync((async) {
      build({
        wakeKey: true,
        'ks.screensaver.timeout_seconds': 60,
        'ks.screensaver.screen_off_minutes': 5,
      });
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 6));
      expect(screenCalls, ['screenOff']);
      expect(saver.isActive, isTrue);

      bus.publish(const ScreenStateChanged(on: true));
      async.flushMicrotasks();
      expect(saver.isActive, isTrue);
      expect(screenCalls, ['screenOff']);

      // A fresh countdown runs from the wake.
      async.elapse(const Duration(minutes: 4));
      expect(screenCalls, ['screenOff']);
      async.elapse(const Duration(minutes: 1));
      expect(screenCalls, ['screenOff', 'screenOff']);
      expect(saver.isActive, isTrue);

      // Woken again, then a touch is what opens the dashboard.
      bus.publish(const ScreenStateChanged(on: true));
      async.flushMicrotasks();
      expect(saver.isActive, isTrue);
      bus.publish(const ActivityDetected(source: 'touch'));
      async.flushMicrotasks();
      expect(saver.isActive, isFalse);
    });
  });

  test('a system wake under a dark panel opens the dashboard by default', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.timeout_seconds': 60,
        'ks.screensaver.screen_off_minutes': 5,
      });
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 6));
      expect(screenCalls, ['screenOff']);
      bus.publish(const ScreenStateChanged(on: true));
      async.flushMicrotasks();
      expect(saver.isActive, isFalse);
    });
  });

  test('the pick is exposed through the settings schema', () async {
    await build({});
    final def = defs.screensaverScreenOffWakeToScreensaver;
    expect(settings.visible(def), isTrue);
    expect(await settings.setFromJson(def.key, '["touch","motion"]'), isTrue);
    expect(
      settings.describe().firstWhere((row) => row['key'] == def.key),
      containsPair('value', '["motion","touch"]'),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(wakeKey), '["motion","touch"]');
    expect(await settings.setFromJson(def.key, '["sneeze"]'), isFalse);
    expect(await settings.setFromJson(def.key, 'motion'), isFalse);
    await saver.dispose();
  });

  // The setting was a switch before issue #954. On stood for every
  // detection and the power button, never touch.
  for (final (stored, expected) in [
    (true, '["motion","face","proximity","person","power"]'),
    (false, '[]'),
  ]) {
    test('a stored switch $stored migrates to $expected', () async {
      await build({wakeKey: stored});
      expect(
        settings.get(defs.screensaverScreenOffWakeToScreensaver),
        expected,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(wakeKey), expected);
      await saver.dispose();
    });

    test('an imported switch $stored becomes $expected', () async {
      await build({});
      expect(
        await settings.import({
          defs.screensaverScreenOffWakeToScreensaver.key: stored,
        }),
        1,
      );
      expect(
        settings.get(defs.screensaverScreenOffWakeToScreensaver),
        expected,
      );
      await saver.dispose();
    });
  }

  test('a detection that is not picked wakes the dashboard', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.dismiss_on_motion': true,
        'ks.screensaver.dismiss_on_proximity': true,
        wakeKey: '["motion"]',
        'ks.screensaver.timeout_seconds': 60,
        'ks.screensaver.screen_off_minutes': 5,
      });
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 6));
      expect(screenCalls, ['screenOff']);
      bus.publish(const ProximityDetected());
      async.flushMicrotasks();
      expect(saver.isActive, isFalse);
      expect(screenCalls, ['screenOff', 'screenOn']);
    });
  });

  test('a system wake opens the dashboard when Power button is not picked', () {
    fakeAsync((async) {
      build({
        wakeKey: '["motion","face","proximity","person","touch"]',
        'ks.screensaver.timeout_seconds': 60,
        'ks.screensaver.screen_off_minutes': 5,
      });
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 6));
      expect(screenCalls, ['screenOff']);
      bus.publish(const ScreenStateChanged(on: true));
      async.flushMicrotasks();
      expect(saver.isActive, isFalse);
    });
  });
}
