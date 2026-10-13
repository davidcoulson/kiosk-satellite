import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/browser/browser_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Custom pages load fresh: Home Assistant serves /local/ to be cached for
/// a month, so the dashboard WebView skips the HTTP cache while a custom
/// page is the target and uses it again for everything else. The native
/// switch is a platform channel call, recorded here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kiosk_satellite/webview_freeze');

  late BrowserManager browser;
  late CommandRegistry commands;
  late List<Map<Object?, Object?>> calls;
  late int matched;

  Future<void> build([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    final bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    browser = BrowserManager(bus, commands, log, settings);
    await browser.init();
    calls = [];
    matched = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'setCacheMode') return 1;
          calls.add(call.arguments as Map<Object?, Object?>);
          return matched;
        });
    browser.onUrlChanged('https://ha.test/lovelace/0');
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a custom page skips the cache and a dashboard uses it again', () async {
    await build();
    await browser.prepareLoad('https://ha.test/local/wall.html#den');
    expect(calls, [
      {'noCache': true, 'urlPrefix': 'https://ha.test'},
    ]);
    // Another page or the same one again: already fresh.
    await browser.prepareLoad('https://ha.test/local/other.html');
    expect(calls, hasLength(1));
    await browser.prepareLoad('https://ha.test/lovelace/1');
    expect(calls.last, {'noCache': false, 'urlPrefix': 'https://ha.test'});
    await browser.prepareLoad('https://ha.test/home');
    expect(calls, hasLength(2));
  });

  test('a switch that found no WebView is tried again', () async {
    await build();
    matched = 0;
    await browser.prepareLoad('https://ha.test/local/wall.html');
    matched = 1;
    await browser.prepareLoad('https://ha.test/local/wall.html');
    expect(calls, hasLength(2));
    expect(calls.last['noCache'], isTrue);
  });

  test('with Disable cache on, nothing ever uses the cache again', () async {
    await build({'ks.browser.disable_cache': true});
    await browser.prepareLoad('https://ha.test/local/wall.html');
    await browser.prepareLoad('https://ha.test/lovelace/0');
    expect(calls.map((c) => c['noCache']), everyElement(isTrue));
  });

  test(
    'the service worker\'s copies go before a page loads and is left',
    () async {
      await build();
      final purges = <String>[];
      browser.evalOverride = (source) async {
        if (source.contains("caches.open('file-cache')")) purges.add(source);
        return null;
      };
      // Entering from a dashboard drops the target's own copy.
      await browser.prepareLoad('https://ha.test/local/wall.html#den');
      expect(purges.single, contains('const target = "/local/wall.html";'));
      expect(purges.single, contains("target.lastIndexOf('/')"));
      // Dashboard to dashboard touches nothing.
      browser.onUrlChanged('https://ha.test/lovelace/0');
      await browser.prepareLoad('https://ha.test/lovelace/1');
      expect(purges, hasLength(1));
      // Leaving a custom page drops what it loaded, named in the page.
      browser.onUrlChanged('https://ha.test/local/wall.html');
      await browser.prepareLoad('https://ha.test/lovelace/0');
      expect(purges.last, contains('const target = null;'));
      // So does a reload of it.
      await commands.execute('reload', const {});
      expect(purges, hasLength(3));
    },
  );

  test('only paths under /local/ count as custom pages', () {
    expect(
      BrowserManager.isCustomPageUrl('https://ha.test/local/a.html'),
      isTrue,
    );
    expect(
      BrowserManager.isCustomPageUrl('https://ha.test/lovelace/local'),
      isFalse,
    );
    expect(
      BrowserManager.isCustomPageUrl('https://ha.test/localx/a.html'),
      isFalse,
    );
    expect(BrowserManager.isCustomPageUrl('not a url'), isFalse);
  });
}
