import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The screensaver stands down for theater mode (T-50, IX-1): it never
/// starts while theater mode is on, one showing when it turns on stops, and
/// when it ends the idle clock starts again from zero rather than firing at
/// once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late ScreensaverManager saver;

  void build(FakeAsync async, Map<String, Object> initial) {
    SharedPreferences.setMockInitialValues(initial);
    bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    settings.init();
    async.flushMicrotasks();
    saver = ScreensaverManager(bus, commands, log, settings);
    saver.clock = () => DateTime(2026, 9, 1, 12);
    saver.init();
    async.flushMicrotasks();
  }

  void theater(FakeAsync async, bool on) {
    bus.publish(
      TheaterModeChanged(active: on, phase: on ? 'dim' : 'off', source: 'page'),
    );
    async.flushMicrotasks();
  }

  const enabled = {
    'ks.screensaver.enabled': true,
    'ks.screensaver.timeout_seconds': 30,
  };

  test('the idle clock never starts it while theater mode is on', () {
    fakeAsync((async) {
      build(async, enabled);
      theater(async, true);
      expect(saver.idleDue, isNull, reason: 'nothing counts down');
      async.elapse(const Duration(hours: 2));
      expect(saver.isActive, isFalse);
    });
  });

  test('one showing when theater mode turns on stops', () {
    fakeAsync((async) {
      build(async, enabled);
      async.elapse(const Duration(seconds: 31));
      expect(saver.isActive, isTrue);
      theater(async, true);
      async.elapse(const Duration(seconds: 1));
      expect(saver.isActive, isFalse);
    });
  });

  test('when theater mode ends the clock starts from zero, not at once', () {
    fakeAsync((async) {
      build(async, enabled);
      theater(async, true);
      async.elapse(const Duration(hours: 1));
      theater(async, false);
      expect(saver.idleDue, isNotNull);
      async.elapse(const Duration(seconds: 29));
      expect(saver.isActive, isFalse, reason: 'a full timeout first');
      async.elapse(const Duration(seconds: 2));
      expect(saver.isActive, isTrue);
    });
  });

  test('an explicit start is refused while theater mode is on', () {
    fakeAsync((async) {
      build(async, enabled);
      theater(async, true);
      saver.start();
      async.flushMicrotasks();
      expect(saver.isActive, isFalse);
    });
  });

  test('hold mode still applies after theater mode ends', () {
    fakeAsync((async) {
      build(async, {...enabled, 'ks.ha.hold_mode': true});
      theater(async, true);
      theater(async, false);
      expect(saver.idleDue, isNull, reason: 'hold mode keeps the clock off');
      async.elapse(const Duration(minutes: 5));
      expect(saver.isActive, isFalse);
    });
  });
}
