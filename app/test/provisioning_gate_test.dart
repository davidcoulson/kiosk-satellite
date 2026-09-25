import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/provisioning.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Any app on the device can send an intent, and the payload it carries is
/// the same JSON the settings import takes - the admin password included. So
/// provisioning is open exactly while a kiosk has nothing to take over, and
/// after that only when someone has said so.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('kiosk_satellite/provision');
  late SettingsManager settings;

  /// Stands the manager up with [initial] prefs and hands the provisioning
  /// channel [payload] the way a launch intent would.
  Future<void> provision(
    Map<String, Object> initial,
    Map<String, Object?> payload,
  ) async {
    SharedPreferences.setMockInitialValues(initial);
    final bus = EventBus();
    final log = Logger();
    settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'getProvisionJson' ? jsonEncode(payload) : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await ProvisioningChannel(settings, log).init();
  }

  test('a kiosk with no Start page yet takes the intent', () async {
    // How tool/onboard-panel.sh configures a panel out of the box.
    await provision(const {}, {'remote.enabled': true, 'device.name': 'Hall'});
    expect(settings.get(defs.remoteEnabled), isTrue);
    expect(settings.get(defs.deviceName), 'Hall');
  });

  test('a configured kiosk refuses it', () async {
    await provision(
      const {
        'flutter.ks.browser.start_url': 'https://home.example/lovelace/0',
        'flutter.ks.device.name': 'Hall',
      },
      {'remote.enabled': true, 'device.name': 'Taken over'},
    );
    expect(settings.get(defs.remoteEnabled), isFalse);
    expect(settings.get(defs.deviceName), 'Hall');
  });

  test('a configured kiosk takes it once provisioning is allowed', () async {
    // The MDM case: re-provisioning in place, switched on deliberately.
    await provision(
      const {
        'flutter.ks.browser.start_url': 'https://home.example/lovelace/0',
        'flutter.ks.provisioning.allow': true,
      },
      {'device.name': 'Re-provisioned'},
    );
    expect(settings.get(defs.deviceName), 'Re-provisioned');
  });

  test('the switch is off by default and kept per device', () {
    expect(defs.provisioningAllow.defaultValue, isFalse);
    expect(defs.provisioningAllow.perDevice, isTrue);
  });
}
