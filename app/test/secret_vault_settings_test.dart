import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/secret_vault.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Keystore that can be told to misbehave. Wrapping is reversible base64
/// under the real prefix, which is enough for the file to stop containing
/// what was typed and for a test to see that it has.
class _FakeVault implements SecretVault {
  var works = true;
  var unwraps = true;

  /// Calls that fail before unwrapping starts working, for the retry.
  var unwrapFailuresFirst = 0;

  @override
  Future<bool> selfTest() async => works;

  @override
  Future<List<String?>> wrap(List<String> plain) async => [
    for (final value in plain)
      works
          ? '${SecretVault.prefix}${base64.encode(utf8.encode(value))}'
          : null,
  ];

  @override
  Future<List<String?>> unwrap(List<String> stored) async {
    if (unwrapFailuresFirst > 0) {
      unwrapFailuresFirst--;
      return List.filled(stored.length, null);
    }
    return [
      for (final value in stored)
        unwraps
            ? utf8.decode(
                base64.decode(value.substring(SecretVault.prefix.length)),
              )
            : null,
    ];
  }
}

/// What the settings do with a Keystore: use it when it proves itself, and
/// never let it cost a panel a secret it had.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsManager> boot(
    _FakeVault vault, [
    Map<String, Object> prefs = const {},
    bool reset = true,
  ]) async {
    if (reset) SharedPreferences.setMockInitialValues(prefs);
    final log = Logger();
    final settings = SettingsManager(
      EventBus(),
      CommandRegistry(log),
      log,
      vault: vault,
    );
    await settings.init();
    return settings;
  }

  Future<String?> onDisk(String key) async =>
      (await SharedPreferences.getInstance()).getString('ks.$key');

  test(
    'a token kept as typed is moved into the vault and still reads',
    () async {
      final settings = await boot(_FakeVault(), {'ks.ha.token': 'long-lived'});
      expect(settings.get(defs.haToken), 'long-lived');
      expect(await onDisk('ha.token'), startsWith(SecretVault.prefix));
      expect(await onDisk('ha.token'), isNot(contains('long-lived')));
    },
  );

  test('it reads the same after a restart', () async {
    final vault = _FakeVault();
    await boot(vault, {'ks.ha.token': 'long-lived'});
    final again = await boot(vault, const {}, false);
    expect(again.get(defs.haToken), 'long-lived');
  });

  test(
    'a new secret is wrapped as it is set, and an ordinary setting is not',
    () async {
      final settings = await boot(_FakeVault());
      await settings.set(defs.haToken, 'fresh');
      await settings.set(defs.haUrl, 'http://ha.local:8123');
      expect(settings.get(defs.haToken), 'fresh');
      expect(await onDisk('ha.token'), startsWith(SecretVault.prefix));
      expect(await onDisk('ha.url'), 'http://ha.local:8123');
    },
  );

  test(
    'a device whose Keystore fails its round trip is left as it was',
    () async {
      final settings = await boot(_FakeVault()..works = false, {
        'ks.ha.token': 'long-lived',
      });
      expect(settings.get(defs.haToken), 'long-lived');
      expect(await onDisk('ha.token'), 'long-lived');
      await settings.set(defs.haToken, 'changed');
      expect(await onDisk('ha.token'), 'changed');
    },
  );

  test('a Keystore slow to start is asked again', () async {
    final vault = _FakeVault();
    await boot(vault, {'ks.ha.token': 'long-lived'});
    vault.unwrapFailuresFirst = 1;
    final again = await boot(vault, const {}, false);
    expect(again.get(defs.haToken), 'long-lived');
  });

  test(
    'a secret that will not unwrap reads as unset and is not destroyed',
    () async {
      final vault = _FakeVault();
      await boot(vault, {'ks.ha.token': 'long-lived'});
      final sealed = await onDisk('ha.token');

      vault.unwraps = false;
      final bad = await boot(vault, const {}, false);
      expect(bad.get(defs.haToken), '');
      // The only copy. A launch that can read it must still find it.
      expect(await onDisk('ha.token'), sealed);

      vault.unwraps = true;
      final good = await boot(vault, const {}, false);
      expect(good.get(defs.haToken), 'long-lived');
    },
  );

  test(
    'an unreadable signing secret is stood in for, never replaced',
    () async {
      final vault = _FakeVault();
      final first = await boot(vault);
      final secret = await first.secret('remote_auth', () => 'original');
      expect(secret, 'original');
      final sealed = await onDisk('secret.remote_auth');

      vault.unwraps = false;
      final bad = await boot(vault, const {}, false);
      final standIn = await bad.secret('remote_auth', () => 'stand-in');
      expect(standIn, 'stand-in');
      expect(await bad.secret('remote_auth', () => 'another'), 'stand-in');
      expect(await onDisk('secret.remote_auth'), sealed);

      vault.unwraps = true;
      final good = await boot(vault, const {}, false);
      expect(await good.secret('remote_auth', () => 'never'), 'original');
    },
  );

  test(
    'somebody typing a new value is how an unreadable one is replaced',
    () async {
      final vault = _FakeVault();
      await boot(vault, {'ks.ha.token': 'lost'});
      vault.unwraps = false;
      final settings = await boot(vault, const {}, false);
      vault.unwraps = true;
      await settings.set(defs.haToken, 'typed-again');
      expect(settings.get(defs.haToken), 'typed-again');
      expect(
        (await boot(vault, const {}, false)).get(defs.haToken),
        'typed-again',
      );
    },
  );

  test('a backup carries secrets as typed, so it restores anywhere', () async {
    final settings = await boot(_FakeVault(), {'ks.ha.token': 'long-lived'});
    expect(settings.export(withSecrets: true)['ha.token'], 'long-lived');
    expect(settings.export().containsKey('ha.token'), isFalse);
  });

  test('the admin password is hashed first and wrapped second', () async {
    final settings = await boot(_FakeVault(), {'ks.remote.password': 'secret'});
    final kept = settings.get(defs.remotePassword);
    expect(kept, startsWith(r'pbkdf2-sha256$'));
    expect(await onDisk('remote.password'), startsWith(SecretVault.prefix));
  });

  test('with no vault at all, nothing changes', () async {
    SharedPreferences.setMockInitialValues({'ks.ha.token': 'long-lived'});
    final log = Logger();
    final settings = SettingsManager(EventBus(), CommandRegistry(log), log);
    await settings.init();
    expect(settings.get(defs.haToken), 'long-lived');
    expect(await onDisk('ha.token'), 'long-lived');
  });
}
