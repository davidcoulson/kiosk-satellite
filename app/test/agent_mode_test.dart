import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/core/frame_watchdog.dart';
import 'package:kiosk_satellite/managers/js_api/js_api_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:shared_preferences/shared_preferences.dart';

/// Agent mode is the answer to "this Android box is not a wall panel": a
/// projector or a media box still earns its place in Home Assistant and in
/// the fleet, and none of the dashboard, voice or camera machinery has any
/// work to do there. The list below is the contract - what never starts, and
/// what must keep starting or the device stops being manageable at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppContainer> build({bool agent = false}) async {
    SharedPreferences.setMockInitialValues(
      agent ? {'flutter.ks.device.agent_mode': true} : const {},
    );
    final c = AppContainer();
    await c.settings.init();
    return c;
  }

  test('a kiosk starts everything', () async {
    final c = await build();
    expect(c.agentMode, isFalse);
    expect(c.managersForTest, contains(c.browser));
    expect(c.managersForTest, contains(c.wakeWord));
    expect(c.managersForTest, contains(c.screensaver));
  });

  test('an agent starts no dashboard, voice, camera or media', () async {
    final c = await build(agent: true);
    expect(c.agentMode, isTrue);
    // Not c.jsApi: in agent mode it is never constructed at all, so reading
    // the field would throw rather than answer. Its absence is the assertion
    // below, by type.
    expect(c.managersForTest.whereType<JsApiManager>(), isEmpty);
    for (final skipped in [
      c.browser,
      c.kiosk,
      c.screensaver,
      c.theater,
      c.deviceCamera,
      c.motion,
      c.wakeWord,
      c.pipeline,
      c.audio,
      c.sendspin,
      c.dlna,
      c.intercom,
    ]) {
      expect(c.managersForTest, isNot(contains(skipped)));
    }
  });

  test('an agent is still a Home Assistant device it can manage', () async {
    final c = await build(agent: true);
    // btProxy owns the ESPHome entity surface: drop it and the device stops
    // existing in Home Assistant, which is the whole point of the mode.
    for (final kept in [
      c.settings,
      c.device,
      c.screen,
      c.service,
      c.btProxy,
      c.remote,
      c.update,
      c.shizuku,
      c.plugins,
      c.fleet,
      c.fleetSync,
      c.files,
    ]) {
      expect(c.managersForTest, contains(kept));
    }
  });

  test('settings and device stay first, so init can skip them', () async {
    final c = await build(agent: true);
    expect(c.managersForTest.take(2), [c.settings, c.device]);
  });

  test('the switch is off by default and never rides fleet sync', () {
    expect(defs.agentMode.defaultValue, isFalse);
    expect(defs.agentMode.perDevice, isTrue);
  });

  test('the renderer watchdog never arms an agent', () async {
    // It reads "foregrounded with no WebView" as a wedged renderer, which is
    // an agent's normal state: armed, it restarted a healthy agent every 30
    // seconds. Caught on the office test panel, not in this file - hence the
    // test.
    final kiosk = FrameWatchdog(await build())..start();
    addTearDown(kiosk.stop);
    expect(kiosk.running, isTrue);

    final agent = FrameWatchdog(await build(agent: true))..start();
    addTearDown(agent.stop);
    expect(agent.running, isFalse);
  });
}
