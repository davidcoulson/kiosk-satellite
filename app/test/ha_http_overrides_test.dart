import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/ha_http_overrides.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Issue #216: with "Ignore SSL errors" enabled, dart:io requests (wake-word
/// model downloads, the sound relay) still failed certificate verification
/// whenever the URL named a host other than the configured HA host, e.g. the
/// old IP the dashboard still loads from after the HA URL moved to a domain.
/// The dart-side policy must agree with the WebView, which proceeds on any
/// SSL error under that setting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HaHttpOverrides> build(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    return HaHttpOverrides(settings);
  }

  setUp(() => HaHttpOverrides.sawSelfSigned = false);

  test('configured HA host is exempt and flags sawSelfSigned', () async {
    final overrides = await build({'ks.ha.url': 'https://ha.example.com:8123'});
    expect(
      overrides.allowBadCertificate('ha.example.com', fingerprint: 'aa'),
      isTrue,
    );
    expect(HaHttpOverrides.sawSelfSigned, isTrue);
  });

  test('other hosts still verify by default', () async {
    final overrides = await build({'ks.ha.url': 'https://ha.example.com:8123'});
    expect(
      overrides.allowBadCertificate('192.168.1.50', fingerprint: 'aa'),
      isFalse,
    );
    expect(HaHttpOverrides.sawSelfSigned, isFalse);
  });

  test('Ignore SSL errors accepts any host, like the WebView', () async {
    final overrides = await build({
      'ks.ha.url': 'https://ha.example.com:8123',
      'ks.browser.ignore_ssl_errors': true,
    });
    expect(
      overrides.allowBadCertificate('192.168.1.50', fingerprint: 'aa'),
      isTrue,
    );
    // The blanket opt-in is not the same as having seen a self-signed
    // certificate on the configured HA host.
    expect(HaHttpOverrides.sawSelfSigned, isFalse);
  });

  test('Immich host is exempt without the blanket opt-in', () async {
    final overrides = await build({
      'ks.ha.url': 'https://ha.example.com:8123',
      'ks.screensaver.immich_url': 'https://immich.local:2283',
    });
    expect(
      overrides.allowBadCertificate('immich.local', fingerprint: 'aa'),
      isTrue,
    );
  });

  group('the exemption is for one certificate, not for the host', () {
    const url = {'ks.ha.url': 'https://ha.example.com:8123'};

    test(
      'the first certificate is remembered and another is refused',
      () async {
        final overrides = await build(url);
        final refused = <String>[];
        overrides.onRefused = (host, fingerprint) => refused.add(fingerprint);

        expect(
          overrides.allowBadCertificate('ha.example.com', fingerprint: 'aa'),
          isTrue,
        );
        expect(
          overrides.allowBadCertificate('ha.example.com', fingerprint: 'aa'),
          isTrue,
        );
        // Somebody else answering under the same name.
        expect(
          overrides.allowBadCertificate('ha.example.com', fingerprint: 'bb'),
          isFalse,
        );
        expect(
          overrides.allowBadCertificate('ha.example.com', fingerprint: 'bb'),
          isFalse,
        );
        // Said once, however often the client retries.
        expect(refused, ['bb']);
        // And the real server is still welcome.
        expect(
          overrides.allowBadCertificate('ha.example.com', fingerprint: 'aa'),
          isTrue,
        );
      },
    );

    test('it survives a restart', () async {
      final first = await build(url);
      first.allowBadCertificate('ha.example.com', fingerprint: 'aa');
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      final again = await build({
        ...url,
        for (final k in prefs.getKeys().where((k) => k.contains('certpin')))
          k: prefs.getString(k)!,
      });
      expect(
        again.allowBadCertificate('ha.example.com', fingerprint: 'bb'),
        isFalse,
      );
    });

    test('Ignore SSL errors adopts a renewed certificate', () async {
      // The way back from a renewed self-signed certificate, from the
      // device's own settings screen: on, reconnect, off.
      final overrides = await build({
        ...url,
        'ks.browser.ignore_ssl_errors': true,
      });
      overrides.allowBadCertificate('ha.example.com', fingerprint: 'aa');
      expect(
        overrides.allowBadCertificate('ha.example.com', fingerprint: 'renewed'),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ks.certpin.ha.example.com'), 'renewed');
    });

    test(
      'Immich is pinned on its own, and forgetting lets a new one in',
      () async {
        SharedPreferences.setMockInitialValues({
          ...url,
          'ks.screensaver.immich_url': 'https://immich.local:2283',
        });
        final log = Logger();
        final settings = SettingsManager(EventBus(), CommandRegistry(log), log);
        await settings.init();
        final overrides = HaHttpOverrides(settings);
        expect(
          overrides.allowBadCertificate('immich.local', fingerprint: 'im'),
          isTrue,
        );
        expect(
          overrides.allowBadCertificate('ha.example.com', fingerprint: 'ha'),
          isTrue,
        );
        expect(
          overrides.allowBadCertificate('immich.local', fingerprint: 'other'),
          isFalse,
        );

        expect(await settings.forgetCertificates(), 2);
        expect(
          overrides.allowBadCertificate('immich.local', fingerprint: 'other'),
          isTrue,
        );
      },
    );

    test('pointing the app at another server forgets the old one', () async {
      SharedPreferences.setMockInitialValues(url);
      final log = Logger();
      final settings = SettingsManager(EventBus(), CommandRegistry(log), log);
      await settings.init();
      final overrides = HaHttpOverrides(settings);
      overrides.allowBadCertificate('ha.example.com', fingerprint: 'aa');
      await Future<void>.delayed(Duration.zero);
      expect(settings.pinnedCertificate('ha.example.com'), 'aa');

      await settings.set(defs.haUrl, 'https://other.example.com:8123');
      expect(settings.pinnedCertificate('ha.example.com'), isNull);
      expect(
        overrides.allowBadCertificate('other.example.com', fingerprint: 'cc'),
        isTrue,
      );
    });
  });
}
