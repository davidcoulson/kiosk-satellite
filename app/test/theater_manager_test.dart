import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/managers/theater/theater_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Theater mode's state machine. The screen manager's hold is faked here:
/// its own guarantees (nothing stored, exact restore) are tested in
/// screen_theater_hold_test.dart. Every timer runs on a fake clock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late TheaterManager theater;
  late List<double?> holds;
  late int releases;
  late List<TheaterModeChanged> events;

  /// Builds everything inside [async], so settings and the manager share its
  /// clock. [prefs] are the stored settings.
  void build(FakeAsync async, [Map<String, Object> prefs = const {}]) {
    SharedPreferences.setMockInitialValues(prefs);
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    holds = [];
    releases = 0;
    events = [];
    commands
      ..register(
        Command(
          name: 'holdBrightness',
          description: 'fake',
          handler: (p) async {
            holds.add((p['level'] as num).toDouble());
            return const CommandResult.ok();
          },
        ),
      )
      ..register(
        Command(
          name: 'releaseBrightness',
          description: 'fake',
          handler: (_) async {
            releases++;
            return const CommandResult.ok();
          },
        ),
      );
    settings = SettingsManager(bus, commands, log);
    settings.init();
    async.flushMicrotasks();
    theater = TheaterManager(bus, commands, log, settings);
    theater.init();
    async.flushMicrotasks();
    bus.on<TheaterModeChanged>().listen(events.add);
  }

  Future<void> set(bool on, [Map<String, Object?> extra = const {}]) => commands
      .execute('setTheaterMode', {'active': on, 'source': 'page', ...extra});

  test('T-1 turning it on dims through the hold, draws the layer at the '
      'setting and says who asked', () {
    fakeAsync((async) {
      build(async, {'ks.theater.overlay_opacity': 0.7});
      set(true);
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.dim);
      expect(holds, [0.0], reason: 'theater backlight default 0');
      expect(theater.view.value.opacity, 0.7);
      expect(theater.view.value.absorbTouches, isTrue);
      expect(events.single.phase, 'dim');
      expect(events.single.source, 'page');
    });
  });

  test('T-2 turning it off from any phase releases the hold and clears the '
      'layer', () {
    for (final into in ['dim', 'peek', 'black']) {
      fakeAsync((async) {
        build(async, {'ks.theater.black_after_minutes': 5});
        set(true);
        async.flushMicrotasks();
        if (into == 'peek') {
          theater.touch();
        } else if (into == 'black') {
          async.elapse(const Duration(minutes: 5));
        }
        async.flushMicrotasks();
        expect(theater.phase.name, into);
        set(false);
        async.flushMicrotasks();
        expect(theater.phase, TheaterPhase.off, reason: into);
        expect(releases, 1, reason: into);
        expect(theater.view.value, TheaterView.off);
      });
    }
  });

  test('T-3 a whole cycle writes no setting', () {
    fakeAsync((async) {
      build(async, {
        'ks.screen.default_brightness': 0.8,
        'ks.theater.black_after_minutes': 5,
      });
      final prefs = SharedPreferences.getInstance();
      async.flushMicrotasks();
      late Map<String, Object?> before;
      prefs.then((p) => before = {for (final k in p.getKeys()) k: p.get(k)});
      async.flushMicrotasks();
      set(true);
      async.flushMicrotasks();
      theater.touch();
      async.elapse(const Duration(seconds: 10));
      async.elapse(const Duration(minutes: 5));
      expect(theater.phase, TheaterPhase.black);
      set(false);
      async.flushMicrotasks();
      late Map<String, Object?> after;
      prefs.then((p) => after = {for (final k in p.getKeys()) k: p.get(k)});
      async.flushMicrotasks();
      expect(after, before);
    });
  });

  test('T-4 a new instance starts off, whatever the last one was doing', () {
    fakeAsync((async) {
      build(async);
      set(true);
      async.flushMicrotasks();
      expect(theater.active, isTrue);
      final again = TheaterManager(bus, commands, Logger(), settings);
      expect(again.phase, TheaterPhase.off);
    });
  });

  test('T-5 a peek lasts the peek time after the last touch, touches extend '
      'it, and a longer one can be asked for', () {
    fakeAsync((async) {
      build(async, {'ks.theater.peek_seconds': 8});
      set(true);
      async.flushMicrotasks();
      theater.touch();
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.peek);
      async.elapse(const Duration(seconds: 7));
      theater.touch(); // at t-1s
      async.elapse(const Duration(seconds: 7));
      expect(theater.phase, TheaterPhase.peek, reason: 'extended');
      async.elapse(const Duration(seconds: 2));
      expect(theater.phase, TheaterPhase.dim);

      commands.execute('theaterPeek', {'seconds': 30});
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 29));
      expect(theater.phase, TheaterPhase.peek);
      async.elapse(const Duration(seconds: 2));
      expect(theater.phase, TheaterPhase.dim);

      set(false);
      async.flushMicrotasks();
      late Object? off;
      commands.execute('theaterPeek', const {}).then((r) => off = r.data);
      async.flushMicrotasks();
      expect(off, isFalse);
    });
  });

  test('T-6 it goes black after the black time, never with 0, and a touch '
      'in black peeks', () {
    fakeAsync((async) {
      build(async, {'ks.theater.black_after_minutes': 10});
      set(true);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 10));
      expect(theater.phase, TheaterPhase.black);
      expect(theater.view.value.opacity, 1);
      expect(holds.last, 0);
      theater.touch();
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.peek);
    });
    fakeAsync((async) {
      build(async); // 0 by default
      set(true);
      async.flushMicrotasks();
      async.elapse(const Duration(hours: 5));
      expect(theater.phase, TheaterPhase.dim);
    });
  });

  test('T-7 the safety cap turns it off, as a timeout', () {
    fakeAsync((async) {
      build(async, {'ks.theater.max_hours': 0.05});
      set(true);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 3, seconds: 1));
      expect(theater.phase, TheaterPhase.off);
      expect(events.last.source, 'timeout');
      expect(releases, 1);
    });
  });

  test('T-8 turning it on twice is one transition, and new options apply in '
      'place', () {
    fakeAsync((async) {
      build(async);
      set(true);
      async.flushMicrotasks();
      set(true, {'overlayOpacity': 0.3});
      async.flushMicrotasks();
      expect(events, hasLength(1));
      expect(theater.phase, TheaterPhase.dim);
      expect(theater.view.value.opacity, 0.3);
    });
  });

  test('options are clamped, unknown ones ignored, and a non-boolean '
      'active refused', () {
    fakeAsync((async) {
      build(async);
      set(true, {'overlayOpacity': 2, 'backlight': -1, 'sparkle': true});
      async.flushMicrotasks();
      expect(theater.view.value.opacity, 0.95);
      expect(holds.last, 0);
      late bool ok;
      commands
          .execute('setTheaterMode', {'active': 'yes'})
          .then((r) => ok = r.ok);
      async.flushMicrotasks();
      expect(ok, isFalse);
    });
  });

  test('T-9 another site in the main view ends it; the same origin does '
      'not', () {
    fakeAsync((async) {
      build(async);
      theater.isTrustedOrigin = (u) => u.host == 'panel.local';
      set(true);
      async.flushMicrotasks();
      bus.publish(const PageChanged(url: 'http://panel.local:8787/#/showtime'));
      async.flushMicrotasks();
      expect(theater.active, isTrue, reason: 'a reload of the start page');
      bus.publish(const PageChanged(url: 'https://example.com/'));
      async.flushMicrotasks();
      expect(theater.active, isFalse);
      expect(events.last.source, 'navigation');
    });
  });

  test('TM-12 a page load re-announces the current state', () {
    fakeAsync((async) {
      build(async);
      set(true);
      async.flushMicrotasks();
      events.clear();
      bus.publish(const PageChanged(url: 'http://panel.local/'));
      async.flushMicrotasks();
      expect(events.single.phase, 'dim');
    });
  });

  test('T-10 people moving do nothing, unless told to peek', () {
    fakeAsync((async) {
      build(async);
      set(true);
      async.flushMicrotasks();
      for (final e in <AppEvent>[
        const MotionDetected(),
        const FaceDetected(),
        const ProximityDetected(),
        const PersonDetected(),
      ]) {
        bus.publish(e);
      }
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.dim);
      expect(events, hasLength(1));
    });
    fakeAsync((async) {
      build(async, {'ks.theater.ignore_ambient_wake': false});
      set(true);
      async.flushMicrotasks();
      bus.publish(const MotionDetected());
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.peek);
    });
  });

  test('T-11 an alert peeks while it shows and the peek time after, then '
      'goes back to where it was', () {
    fakeAsync((async) {
      build(async, {
        'ks.theater.black_after_minutes': 5,
        'ks.theater.peek_seconds': 8,
      });
      set(true);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      expect(theater.phase, TheaterPhase.black);

      bus.publish(const NotificationsChanged(count: 1));
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.peek);
      async.elapse(const Duration(minutes: 2));
      expect(theater.phase, TheaterPhase.peek, reason: 'still showing');
      bus.publish(const NotificationsChanged(count: 0));
      async.elapse(const Duration(seconds: 7));
      expect(theater.phase, TheaterPhase.peek);
      async.elapse(const Duration(seconds: 2));
      expect(theater.phase, TheaterPhase.black, reason: 'where it was');
    });

    // Each kind of alert peeks.
    for (final open in <AppEvent>[
      const VoiceInteractionChanged(active: true, reason: 'announcement'),
      const CameraViewStateChanged(viewId: 'door', viewName: 'Door'),
      const IntercomStateChanged({'state': 'ringing'}),
    ]) {
      fakeAsync((async) {
        build(async);
        set(true);
        async.flushMicrotasks();
        bus.publish(open);
        async.flushMicrotasks();
        expect(theater.phase, TheaterPhase.peek, reason: '$open');
      });
    }
  });

  test('music is not an alert, and alerts can be switched off', () {
    fakeAsync((async) {
      build(async);
      set(true);
      async.flushMicrotasks();
      bus.publish(const VoiceInteractionChanged(active: true, reason: 'media'));
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.dim);
    });
    fakeAsync((async) {
      build(async, {'ks.theater.peek_on_alerts': false});
      set(true);
      async.flushMicrotasks();
      bus.publish(const NotificationsChanged(count: 1));
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.dim);
    });
  });

  test('T-12 a screen woken while it is on comes back dimmed', () {
    fakeAsync((async) {
      build(async);
      set(true);
      async.flushMicrotasks();
      theater.touch();
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.peek);
      bus.publish(const ScreenStateChanged(on: false));
      async.flushMicrotasks();
      expect(theater.active, isTrue, reason: 'screen off keeps it on');
      bus.publish(const ScreenStateChanged(on: true));
      async.flushMicrotasks();
      expect(theater.phase, TheaterPhase.dim);
      expect(holds.last, 0, reason: 'the theater backlight, not stored');
    });
  });

  test('with first touch passing through, dim does not absorb', () {
    fakeAsync((async) {
      build(async, {'ks.theater.first_touch_wakes': false});
      set(true);
      async.flushMicrotasks();
      expect(theater.view.value.absorbTouches, isFalse);
    });
  });
}
