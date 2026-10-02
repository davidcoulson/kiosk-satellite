import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/browser/browser_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EventBus bus;
  late BrowserManager browser;
  late SettingsManager settings;
  late CommandRegistry commands;
  const channel = MethodChannel('kiosk_satellite/webview_freeze');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (_) async => 1);
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    browser = BrowserManager(bus, commands, log, settings);
    await browser.init();
  });

  Future<void> publish(AppEvent event) async {
    bus.publish(event);
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() async {
    await browser.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'defaults on and follows coverage independently of rendering pause',
    () async {
      expect(settings.get(defs.pauseDashboardCameras), isTrue);
      await settings.set(defs.freezeOnScreensaver, false);
      await publish(const ScreensaverStateChanged(active: true));
      expect(browser.dashboardCameraStreamsPaused, isFalse);
      await publish(const ScreensaverViewChanged(view: 'clock'));
      expect(browser.dashboardCameraStreamsPaused, isTrue);
      await publish(const ScreensaverStateChanged(active: false));
      expect(browser.dashboardCameraStreamsPaused, isFalse);
    },
  );

  test('an outside hold pauses the streams with no screensaver involved', () async {
    // The case this exists for: a wall panel that never runs a screensaver,
    // decoding every camera on its dashboard for an empty room. Presence is
    // Home Assistant's to judge, so the hold arrives as a command.
    expect(browser.dashboardCameraStreamsPaused, isFalse);
    expect(browser.dashboardCamerasHeldPaused, isFalse);

    final events = <bool>[];
    final sub = bus.on<DashboardCamerasHoldChanged>().listen(
      (e) => events.add(e.held),
    );
    addTearDown(sub.cancel);

    final off = await commands.execute('setDashboardCameras', {
      'playing': false,
    });
    expect(off.ok, isTrue);
    expect(
      browser.dashboardCameraStreamsPaused,
      isTrue,
      reason: 'held paused without any screensaver',
    );

    final on = await commands.execute('setDashboardCameras', {'playing': true});
    expect(on.ok, isTrue);
    expect(browser.dashboardCameraStreamsPaused, isFalse);

    await Future<void>.delayed(Duration.zero);
    expect(events, [true, false], reason: 'each change announced once');
  });

  test('the hold does not depend on the screensaver setting', () async {
    await settings.setFromJson(defs.pauseDashboardCameras.key, false);
    await commands.execute('setDashboardCameras', {'playing': false});
    expect(browser.dashboardCameraStreamsPaused, isTrue);
    await commands.execute('setDashboardCameras', {'playing': true});
    expect(browser.dashboardCameraStreamsPaused, isFalse);
  });

  test('the command refuses anything that is not a bool', () async {
    final bad = await commands.execute('setDashboardCameras', {
      'playing': 'false',
    });
    expect(bad.ok, isFalse, reason: 'a string "false" must not read as false');
    expect(browser.dashboardCamerasHeldPaused, isFalse);
  });


  test(
    'live toggles and screensaver mode changes restore camera streams',
    () async {
      await publish(const ScreensaverViewChanged(view: 'clock'));
      await publish(const ScreensaverStateChanged(active: true));
      await settings.set(defs.pauseDashboardCameras, false);
      expect(browser.dashboardCameraStreamsPaused, isFalse);
      await settings.set(defs.pauseDashboardCameras, true);
      expect(browser.dashboardCameraStreamsPaused, isTrue);
      await publish(const ScreensaverViewChanged(view: null));
      expect(browser.dashboardCameraStreamsPaused, isFalse);
      await publish(const ScreenStateChanged(on: false));
      expect(browser.dashboardCameraStreamsPaused, isTrue);
      await publish(const ScreenStateChanged(on: true));
      expect(browser.dashboardCameraStreamsPaused, isFalse);
    },
  );

  test(
    'a website screensaver on HA origin can pause only the dashboard cameras',
    () async {
      await settings.set(defs.haUrl, 'http://ha.local:8123');
      await settings.set(
        defs.screensaverWebsiteUrl,
        'http://ha.local:8123/clock',
      );
      await publish(const ScreensaverViewChanged(view: 'website'));
      await publish(const ScreensaverStateChanged(active: true));
      expect(browser.dashboardCameraStreamsPaused, isTrue);
    },
  );

  test(
    'settings and camera feature overlays alone do not suspend dashboard streams',
    () {
      browser.setCovered('camera view', covered: true);
      expect(browser.dashboardCameraStreamsPaused, isFalse);
      browser.setCovered('settings', covered: true);
      expect(browser.dashboardCameraStreamsPaused, isFalse);
    },
  );
}
