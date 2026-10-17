import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/btproxy/bt_proxy_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/managers/voice/voice_manager.dart';
import 'package:kiosk_satellite/managers/wake_word/wake_word_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// setWakeWordMuted (issue #991): the mute Home Assistant's Mute switch
/// controls, set without a round trip through Home Assistant on the
/// native runtime.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late CommandRegistry commands;
  late SettingsManager settings;
  late VoiceManager voice;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('ks_voice_mute');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
    SharedPreferences.setMockInitialValues({});
    final bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    voice = VoiceManager(
      bus,
      commands,
      log,
      settings,
      BtProxyManager(bus, commands, log, settings),
      WakeWordManager(bus, commands, log, settings),
    );
    await voice.init();
  });

  tearDown(() async {
    await voice.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await support.delete(recursive: true);
  });

  test('the native runtime sets the Mute switch itself', () async {
    await settings.set(defs.voiceEnabled, true);
    var result = await commands.execute('setWakeWordMuted', {'muted': true});
    expect(result.ok, true);
    expect(result.data, true);
    expect(settings.get(defs.voiceMute), true);
    result = await commands.execute('setWakeWordMuted', {'muted': false});
    expect(result.data, false);
    expect(settings.get(defs.voiceMute), false);
  });

  test('refuses while Voice Satellite is off or muted is not a bool', () async {
    expect(
      (await commands.execute('setWakeWordMuted', {'muted': true})).ok,
      false,
    );
    expect(settings.get(defs.voiceMute), false);
    await settings.set(defs.voiceEnabled, true);
    expect(
      (await commands.execute('setWakeWordMuted', {'muted': 'true'})).ok,
      false,
    );
  });

  test('the dashboard runtime turns the integration switch', () async {
    await settings.set(defs.voiceRuntime, 'dashboard');
    final calls = <Map<String, Object?>>[];
    commands
      ..register(
        Command(
          name: 'vsControls',
          description: 'test',
          handler: (_) async => const CommandResult.ok({
            'entities': {
              'mute': {'entity_id': 'switch.kitchen_mute', 'state': 'off'},
            },
          }),
        ),
      )
      ..register(
        Command(
          name: 'haCallService',
          description: 'test',
          handler: (p) async {
            calls.add(p);
            return const CommandResult.ok();
          },
        ),
      );
    final result = await commands.execute('setWakeWordMuted', {'muted': true});
    expect(result.data, true);
    expect(calls, [
      {
        'domain': 'switch',
        'service': 'turn_on',
        'entity_id': 'switch.kitchen_mute',
      },
    ]);
    expect(settings.get(defs.voiceMute), false);
  });
}
