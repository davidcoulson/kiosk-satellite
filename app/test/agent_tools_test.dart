import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/agent/agent_tools_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Headless management: the home app coming back when the remote sits idle,
/// and the daily restart. The media and key plumbing is native; this is the
/// part that decides.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const media = MethodChannel('kiosk_satellite/media_sessions');
  late EventBus bus;
  late SettingsManager settings;
  late CommandRegistry commands;
  late AgentToolsManager tools;
  late DateTime now;
  late List<String> launched;
  late int reboots;
  late String front;
  late int uptime;

  Future<void> build(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues({
      for (final e in prefs.entries) 'ks.${e.key}': e.value,
    });
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    launched = [];
    reboots = 0;
    front = 'com.mediatek.wwtv.tvcenter';
    uptime = 86400;
    now = DateTime(2026, 9, 25, 20, 0);
    void stub(
      String name,
      Future<CommandResult> Function(Map<String, Object?>) h,
    ) => commands.register(Command(name: name, description: name, handler: h));
    stub('foregroundApp', (_) async => CommandResult.ok({'package': front}));
    stub('launchApp', (p) async {
      launched.add('${p['package']}');
      return const CommandResult.ok();
    });
    stub('getUptime', (_) async => CommandResult.ok({'device': uptime}));
    stub('rebootDevice', (_) async {
      reboots++;
      return const CommandResult.ok();
    });
    tools = AgentToolsManager(bus, commands, log, settings, clock: () => now);
    await tools.init();
  }

  tearDown(() => tools.dispose());

  Future<void> playing(String state) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall('changed', {'state': state, 'app': 'Plezy'}),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(media.name, data, (_) {});
  }

  group('return to the home app', () {
    const home = {
      'device.home_app': 'com.spocky.projengmenu',
      'device.home_app_idle_minutes': 10,
    };

    test('after the idle time, with another app in front', () async {
      await build(home);
      now = now.add(const Duration(minutes: 9));
      await tools.checkForTest();
      expect(launched, isEmpty);
      now = now.add(const Duration(minutes: 2));
      await tools.checkForTest();
      expect(launched, ['com.spocky.projengmenu']);
    });

    test('never while something is playing', () async {
      await build(home);
      await playing('playing');
      now = now.add(const Duration(minutes: 30));
      await tools.checkForTest();
      expect(launched, isEmpty);
      await playing('paused');
      await tools.checkForTest();
      expect(launched, ['com.spocky.projengmenu']);
    });

    test('a remote key press restarts the idle clock', () async {
      await build(home);
      now = now.add(const Duration(minutes: 8));
      bus.publish(const RemoteKeyReported(keyCode: 20, type: 'dpad_down'));
      await pumpEventQueue();
      now = now.add(const Duration(minutes: 8));
      await tools.checkForTest();
      expect(launched, isEmpty);
    });

    test('not when the home app is already in front, or when off', () async {
      await build(home);
      front = 'com.spocky.projengmenu';
      now = now.add(const Duration(minutes: 30));
      await tools.checkForTest();
      expect(launched, isEmpty);

      await build({'device.home_app': 'com.spocky.projengmenu'});
      now = now.add(const Duration(minutes: 300));
      await tools.checkForTest();
      expect(launched, isEmpty);
    });
  });

  group('daily restart', () {
    test('once, at its minute', () async {
      await build({'device.reboot_time': '03:30'});
      now = DateTime(2026, 9, 26, 3, 29);
      await tools.checkForTest();
      expect(reboots, 0);
      now = DateTime(2026, 9, 26, 3, 30);
      await tools.checkForTest();
      await tools.checkForTest();
      expect(reboots, 1);
      now = DateTime(2026, 9, 27, 3, 30);
      await tools.checkForTest();
      expect(reboots, 2);
    });

    test('not within ten minutes of a boot, and never on a bad time', () async {
      await build({'device.reboot_time': '03:30'});
      uptime = 120;
      now = DateTime(2026, 9, 26, 3, 30);
      await tools.checkForTest();
      expect(reboots, 0);

      await build({'device.reboot_time': '25:99'});
      now = DateTime(2026, 9, 26, 3, 30);
      await tools.checkForTest();
      expect(reboots, 0);
    });
  });

  test('every headless switch is off, and per device', () {
    for (final def in [
      defs.remoteKeysReport,
      defs.nowPlaying,
      defs.homeAppAtBoot,
    ]) {
      expect(def.defaultValue, isFalse, reason: def.key);
      expect(def.perDevice, isTrue, reason: def.key);
    }
    expect(defs.homeApp.defaultValue, '');
    expect(defs.homeAppIdleMinutes.defaultValue, 0);
    expect(defs.rebootTime.defaultValue, '');
  });
}
