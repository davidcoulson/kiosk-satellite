import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/browser/browser_manager.dart';
import 'package:kiosk_satellite/managers/browser/navigation.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Moving the main view from Home Assistant (NAV-1), and a start page that is
/// not Home Assistant (URL-2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const showing = 'http://panel.local:8787/#/lobby';

  group('T-60 navigate', () {
    test('a fragment on the page showing changes in place', () {
      final d = decideNavigation('#/showtime', showing);
      expect(d, isA<NavigationHash>());
      expect((d as NavigationHash).fragment, '/showtime');
    });

    test('the same page named in full, differing only by fragment, is also '
        'in place', () {
      final d = decideNavigation('http://panel.local:8787/#/showtime', showing);
      expect(d, isA<NavigationHash>());
    });

    test('an absolute URL elsewhere loads', () {
      final d = decideNavigation('http://ha.local:8123/lovelace/0', showing);
      expect((d as NavigationLoad).url, 'http://ha.local:8123/lovelace/0');
    });

    test('a path resolves against the page showing and loads', () {
      final d = decideNavigation('/music', showing);
      expect((d as NavigationLoad).url, 'http://panel.local:8787/music');
    });

    test('an absolute URL is compared in the proxy\'s form', () {
      // The page showing is the loopback form of ha.local.
      final d = decideNavigation(
        'http://ha.local:8123/lovelace/0#x',
        'http://127.0.0.1:40123/lovelace/0',
        mapUrl: (u) =>
            u.replaceFirst('http://ha.local:8123', 'http://127.0.0.1:40123'),
      );
      expect(d, isA<NavigationHash>());
    });

    test('every other scheme is refused', () {
      for (final bad in [
        'javascript:alert(1)',
        'file:///sdcard/x.html',
        'data:text/html,<b>hi</b>',
        'intent://scan/#Intent;scheme=zxing;end',
        'ftp://example.com/',
        '//evil.example/x',
        'about:blank',
        '',
      ]) {
        expect(
          decideNavigation(bad, showing),
          isA<NavigationRefused>(),
          reason: bad,
        );
      }
    });

    test('a path with nothing loaded has nothing to resolve against', () {
      expect(decideNavigation('#/x', ''), isA<NavigationRefused>());
    });
  });

  group('T-61 a custom start page', () {
    Future<BrowserManager> browser(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues({
        'ks.ha.url': 'http://ha.local:8123',
        'ks.browser.start_url': 'http://panel.local:8787/',
        ...prefs,
      });
      final bus = EventBus();
      final log = Logger();
      final commands = CommandRegistry(log);
      final settings = SettingsManager(bus, commands, log);
      await settings.init();
      return BrowserManager(bus, commands, log, settings);
    }

    final panel = Uri.parse('http://panel.local:8787/#/showtime');
    final ha = Uri.parse('http://ha.local:8123/lovelace/0');

    test('is the dashboard\'s origin but never Home Assistant\'s', () async {
      final b = await browser({'ks.browser.start_page': 'custom'});
      expect(b.isDashboardOrigin(panel), isTrue);
      expect(
        b.isHomeAssistantOrigin(panel),
        isFalse,
        reason: 'it must not be handed the HA session',
      );
      expect(b.isHomeAssistantOrigin(ha), isTrue);
    });

    test('an install that never chose keeps trusting the dashboard as Home '
        'Assistant, as before', () async {
      // Issue #216: the dashboard at an old address while the HA URL moved.
      final b = await browser({
        'ks.browser.start_url': 'http://192.168.1.10:8123/lovelace/0',
      });
      expect(
        b.isHomeAssistantOrigin(Uri.parse('http://192.168.1.10:8123/x')),
        isTrue,
      );
    });
  });

  group('URL-1 the start page choice and the start URL stay in step', () {
    late SettingsManager settings;

    Future<void> start(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues({
        'ks.ha.url': 'http://ha.local:8123',
        'ks.browser.start_url': 'http://ha.local:8123/lovelace/0',
        ...prefs,
      });
      final bus = EventBus();
      final log = Logger();
      final commands = CommandRegistry(log);
      settings = SettingsManager(bus, commands, log);
      await settings.init();
      await BrowserManager(bus, commands, log, settings).init();
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    test('typing a custom URL makes it the start URL', () async {
      await start({'ks.browser.start_page': 'custom'});
      await settings.set(defs.customStartUrl, 'http://10.2.3.20:8787');
      await settle();
      expect(settings.get(defs.startUrl), 'http://10.2.3.20:8787');
    });

    test(
      'a dashboard picked in between does not lose the custom URL',
      () async {
        await start({});
        await settings.set(defs.startPage, 'custom');
        await settings.set(defs.customStartUrl, 'http://10.2.3.20:8787');
        await settle();
        await settings.set(defs.startPage, 'ha');
        await settle();
        expect(
          settings.get(defs.startUrl),
          'http://ha.local:8123',
          reason: 'not left on a page it would trust as Home Assistant',
        );
        await settings.set(defs.startPage, 'custom');
        await settle();
        expect(settings.get(defs.startUrl), 'http://10.2.3.20:8787');
      },
    );

    test('a start URL written directly while custom is remembered', () async {
      await start({'ks.browser.start_page': 'custom'});
      await settings.set(defs.startUrl, 'http://10.2.3.20:8787/#/lobby');
      await settle();
      expect(
        settings.get(defs.customStartUrl),
        'http://10.2.3.20:8787/#/lobby',
      );
    });

    test(
      'choosing Home Assistant leaves a Home Assistant start URL alone',
      () async {
        await start({'ks.browser.start_page': 'custom'});
        await settings.set(defs.startUrl, 'http://ha.local:8123/lovelace/2');
        await settle();
        await settings.set(defs.startPage, 'ha');
        await settle();
        expect(settings.get(defs.startUrl), 'http://ha.local:8123/lovelace/2');
      },
    );

    test('a custom URL must be a web page', () {
      expect(defs.validateCustomStartUrl('ftp://10.2.3.20/'), isNotNull);
      expect(defs.validateCustomStartUrl('file:///sdcard/x'), isNotNull);
      expect(defs.validateCustomStartUrl('javascript:alert(1)'), isNotNull);
      expect(defs.validateCustomStartUrl('10.2.3.20:8787'), isNotNull);
      expect(defs.validateCustomStartUrl('http://10.2.3.20:8787'), isNull);
      expect(defs.validateCustomStartUrl('https://panel.example/'), isNull);
    });
  });
}
