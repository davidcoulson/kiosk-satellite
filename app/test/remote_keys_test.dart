import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/gestures/remote_keys_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remote key mappings, the Dart half: the table the service is given, what
/// happens to a key it hands back, and capture for the editors. The native
/// half (which keys are swallowed, long presses) is RemoteKeysTest.kt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('kiosk_satellite/remote_keys');
  const home = '[{"id":"k1","trigger":{"type":"remote_key","keyCode":3,'
      '"keyName":"Home"},"action":{"type":"launch_app",'
      '"package":"com.spocky.projengmenu"}},'
      '{"id":"k2","trigger":{"type":"remote_key","keyCode":82,'
      '"keyName":"Menu"},"action":{"type":"plugin_action",'
      '"pluginId":"nexigo-aurora","command":"settings"}}]';

  late EventBus bus;
  late SettingsManager settings;
  late RemoteKeysManager keys;
  late List<MethodCall> calls;
  late bool serviceRunning;

  Future<void> build({String mappings = home}) async {
    SharedPreferences.setMockInitialValues({
      'ks.${defs.gestureMappings.key}': mappings,
    });
    bus = EventBus();
    final log = Logger();
    settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
    calls = [];
    serviceRunning = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'capture' => serviceRunning,
            'status' => {'serviceRunning': serviceRunning},
            _ => null,
          };
        });
    keys = RemoteKeysManager(bus, CommandRegistry(log), log, settings);
    await keys.init();
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// A call from the service, as the platform side would send it.
  Future<void> fromNative(String method, Map<String, Object?> args) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, data, (_) {});
  }

  test('the service gets the mappings and the switch at start', () async {
    await build();
    final configure = calls.singleWhere((c) => c.method == 'configure');
    expect(configure.arguments, {'mappings': home, 'enabled': true});
  });

  test('editing the mappings or the switch pushes the table again', () async {
    await build();
    calls.clear();
    await settings.set(defs.gestureRemoteKeysEnabled, false);
    await settings.setFromJson(defs.gestureMappings.key, '[]');
    await pumpEventQueue();
    final pushed = calls.where((c) => c.method == 'configure').toList();
    expect(pushed, hasLength(2));
    expect(pushed.last.arguments, {'mappings': '[]', 'enabled': false});
  });

  test('a key the service could not run natively becomes a gesture', () async {
    await build();
    final seen = <String>[];
    bus.on<GestureDetected>().listen((e) => seen.add(e.id));
    await fromNative('pressed', {'id': 'k2', 'ran': null});
    await pumpEventQueue();
    expect(seen, ['k2']);
  });

  test('a key the service already ran is only logged', () async {
    await build();
    final seen = <String>[];
    bus.on<GestureDetected>().listen((e) => seen.add(e.id));
    await fromNative('pressed', {'id': 'k1', 'ran': true});
    await fromNative('pressed', {'id': 'k1', 'ran': false});
    await pumpEventQueue();
    expect(seen, isEmpty);
  });

  test('capture reports the next key pressed', () async {
    await build();
    final pending = keys.capture(seconds: 5);
    await pumpEventQueue();
    expect(calls.last.method, 'capture');
    expect(calls.last.arguments, {'seconds': 5});
    await fromNative('captured', {'keyCode': 134, 'name': 'F4'});
    expect(await pending, {'keyCode': 134, 'keyName': 'F4'});
  });

  test('capture refuses at once when the service is off', () async {
    await build();
    serviceRunning = false;
    expect(await keys.capture(seconds: 5), isNull);
    expect(calls.last.method, 'cancelCapture');
  });

  test('the capture command explains a missing service', () async {
    SharedPreferences.setMockInitialValues({});
    bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'capture' ? false : null;
        });
    await RemoteKeysManager(bus, commands, log, settings).init();
    final result = await commands.execute('captureRemoteKey', {'seconds': 1});
    expect(result.ok, isFalse);
    expect(result.error, contains('accessibility service'));
  });

  test('remote keys are on by default and ride fleet sync', () {
    expect(defs.gestureRemoteKeysEnabled.defaultValue, isTrue);
    expect(defs.gestureRemoteKeysEnabled.perDevice, isFalse);
  });
}
