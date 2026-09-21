import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screen/screen_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Theater mode's brightness hold: a session layer above everything the
/// settings describe. While it holds, the knob and adaptive brightness keep
/// computing and storing, nothing else reaches the panel, and none of it is
/// persisted -- a crash mid-movie must come back at the stored brightness.
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kiosk_satellite/brightness');

  /// The fake panel and the fake light sensor.
  late double panel;
  late List<double> writes;
  late List<BrightnessChanged> published;
  late bool present;
  late double? lux;
  late EventBus bus;
  late SettingsManager settings;
  late CommandRegistry commands;
  late ScreenManager screen;

  /// Let a write's platform round trip and the bus delivery after it run.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> build(
    Map<String, Object> initial, {
    bool sensor = true,
    double? startLux = 5,
    double startPanel = 0.5,
    Duration gap = Duration.zero,
  }) async {
    panel = startPanel;
    writes = [];
    published = [];
    present = sensor;
    lux = startLux;
    wakelockPlusPlatformInstance = _NoopWakelock();
    SharedPreferences.setMockInitialValues(initial);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'get':
              return panel;
            case 'set':
              final level = (call.arguments as Map)['level'] as double;
              panel = level;
              writes.add(level);
              return true;
            default:
              return null;
          }
        });
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    // The device manager's probe, as the screen manager sees it.
    commands.register(
      Command(
        name: 'getLightLevel',
        description: 'fake',
        handler: (_) async =>
            CommandResult.ok({'present': present, 'lux': lux}),
      ),
    );
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    bus.on<BrightnessChanged>().listen(published.add);
    screen = ScreenManager(bus, commands, log, settings, adaptiveWriteGap: gap);
    await screen.init();
    // The bus delivers on a microtask: let init's publishes land.
    await settle();
  }

  /// The native observer reporting a system value that moved the panel.
  Future<void> observe(double level) async {
    panel = level;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('brightnessChanged', level),
          ),
          (_) {},
        );
    await settle();
  }

  Future<double?> ceiling() async =>
      (await commands.execute('getBrightness', const {'ceiling': true})).data
          as double?;
  Future<double?> panelLevel() async =>
      (await commands.execute('getBrightness', const {'panel': true})).data
          as double?;
  Future<double?> knob() async =>
      (await commands.execute('getBrightness', const {})).data as double?;

  /// Adaptive on with Minimum 20% and Maximum 80%: a floor of 0.25.
  const on = {
    'ks.screen.adaptive_brightness': true,
    'ks.screen.adaptive_min_brightness': 0.2,
    'ks.screen.adaptive_max_brightness': 0.8,
    'ks.screen.adaptive_dark_lux': 5,
    'ks.screen.adaptive_bright_lux': 500,
  };

  tearDown(() => screen.dispose());

  Future<Map<String, Object?>> stored() async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final k in prefs.getKeys()) k: prefs.get(k)};
  }

  test('a hold puts the level on the panel and stores nothing', () async {
    await build({'ks.screen.default_brightness': 0.5});
    final before = await stored();
    await commands.execute('holdBrightness', const {'level': 0.02});
    await settle();
    expect(panel, closeTo(0.02, 0.0001));
    await commands.execute('holdBrightness', const {'level': 0.3});
    await settle();
    expect(panel, closeTo(0.3, 0.0001));
    await commands.execute('releaseBrightness', const {});
    await settle();
    expect(await stored(), before, reason: 'not one setting written');
  });

  test('release puts back exactly what the panel showed before', () async {
    await build({}, startPanel: 0.63, sensor: false);
    await commands.execute('holdBrightness', const {'level': 0});
    await settle();
    await commands.execute('releaseBrightness', const {});
    await settle();
    expect(panel, closeTo(0.63, 0.0001));
  });

  test(
    'a knob turned mid-hold is stored, held back, and lands on release',
    () async {
      await build({'ks.screen.default_brightness': 0.5}, sensor: false);
      await commands.execute('holdBrightness', const {'level': 0.02});
      await settle();
      await commands.execute('setBrightness', const {'level': 0.7});
      await settle();
      expect(settings.get(defs.defaultBrightness), 0.7, reason: 'stored');
      expect(panel, closeTo(0.02, 0.0001), reason: 'not shown yet');
      // The Screen light reports what the panel really shows.
      expect(published.last.panel, closeTo(0.02, 0.0001));
      await commands.execute('releaseBrightness', const {});
      await settle();
      expect(panel, closeTo(0.7, 0.0001));
    },
  );

  test('the room moving under a hold changes nothing until release, then '
      'adaptive brightness applies for the room as it is', () async {
    await build(on);
    await commands.execute('holdBrightness', const {'level': 0.02});
    await settle();
    final writesDuringHold = writes.length;
    bus.publish(const LightLevelChanged(lux: 500));
    await settle();
    expect(writes.length, writesDuringHold, reason: 'no write for the room');
    expect(panel, closeTo(0.02, 0.0001));
    await commands.execute('releaseBrightness', const {});
    await settle();
    // Bright room: the factor is 1, so Maximum brightness itself.
    expect(panel, closeTo(0.8, 0.001));
  });

  test('the screensaver cannot take the panel while it is held', () async {
    await build({'ks.screen.default_brightness': 0.5}, sensor: false);
    await commands.execute('holdBrightness', const {'level': 0.02});
    await settle();
    await commands.execute('setBrightness', const {
      'level': 0.9,
      'ceiling': true,
    });
    await settle();
    expect(panel, closeTo(0.02, 0.0001));
  });

  test('releasing with nothing held does nothing', () async {
    await build({}, startPanel: 0.4, sensor: false);
    final before = writes.length;
    await commands.execute('releaseBrightness', const {});
    await settle();
    expect(writes.length, before);
    expect(panel, 0.4);
  });

  test('an out-of-range hold is refused', () async {
    await build({}, sensor: false);
    final r = await commands.execute('holdBrightness', const {'level': 1.5});
    expect(r.ok, isFalse);
  });
}
