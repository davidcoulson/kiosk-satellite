import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/browser/browser_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The wake path makes sure the dashboard's Home Assistant socket is live
/// before a turn starts. A page with no Home Assistant frontend (a custom
/// page, the login form) has no socket to wait for, and waiting for one
/// held every wake word on a custom page for six seconds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BrowserManager browser;

  /// [state] is what the page answers the classification probe with,
  /// [connected] what the socket check answers.
  Future<void> build({required String state, bool connected = false}) async {
    SharedPreferences.setMockInitialValues({});
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    browser = BrowserManager(bus, commands, log, settings);
    browser.evalOverride = (source) async {
      if (source.contains('chrome-error')) return state;
      if (source.contains('c.socket.readyState === 1')) return connected;
      return null;
    };
  }

  test('a page without Home Assistant answers at once', () async {
    await build(state: 'other');
    final watch = Stopwatch()..start();
    expect(await browser.ensureHaConnected(), isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test("Chromium's error page fails at once", () async {
    await build(state: 'error-page');
    final watch = Stopwatch()..start();
    expect(await browser.ensureHaConnected(), isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('a connected dashboard passes straight through', () async {
    await build(state: 'connected', connected: true);
    expect(await browser.ensureHaConnected(), isTrue);
  });

  test('a dashboard still booting is waited for', () async {
    await build(state: 'shell');
    final watch = Stopwatch()..start();
    final ok = await browser.ensureHaConnected(
      timeout: const Duration(milliseconds: 600),
    );
    expect(ok, isFalse);
    expect(
      watch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 600)),
    );
  });
}
