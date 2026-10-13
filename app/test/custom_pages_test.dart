import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/btproxy/dashboard_views.dart';
import 'package:kiosk_satellite/managers/home_assistant/custom_pages.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/ui/dashboard_view_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Custom pages: the person's own HTML under /local/, listed by the
/// dashboard commands as one more dashboard and navigated by a full load,
/// or by a fragment change within the same file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('paths', () {
    test('a path is taken however it is typed', () {
      for (final input in [
        '/local/kitchen.html',
        'local/kitchen.html',
        'kitchen.html',
        '  /local/kitchen.html ',
        'https://ha.test:8123/local/kitchen.html',
      ]) {
        expect(normalizeCustomPagePath(input), '/local/kitchen.html');
      }
    });

    test('folders, a query and a fragment are kept', () {
      expect(
        normalizeCustomPagePath('/local/wall/index.html?room=den#lights'),
        '/local/wall/index.html?room=den#lights',
      );
      expect(
        normalizeCustomPagePath('http://ha.test/local/a.html#b'),
        '/local/a.html#b',
      );
    });

    test('anything that names no file under /local/ is refused', () {
      for (final input in [
        '',
        '/local/',
        '/config/configuration.yaml',
        'https://ha.test/api/states',
        '/local/wall/',
        '/local/../secrets.yaml',
        '/local/a//b.html',
        '/local/my page.html',
        r'/local/a\b.html',
      ]) {
        expect(normalizeCustomPagePath(input), isNull, reason: input);
      }
    });

    test('the stored list skips malformed and doubled pages', () {
      final pages = parseCustomPages(
        jsonEncode([
          {'name': 'Kitchen', 'path': '/local/kitchen.html'},
          {'name': '', 'path': '/local/x.html'},
          {'name': 'Bad', 'path': '/local/'},
          {'name': 'Again', 'path': 'kitchen.html'},
          'not a page',
          {'name': 'Den', 'path': '/local/den.html#tv'},
        ]),
      );
      expect(pages.map((p) => p.name), ['Kitchen', 'Den']);
      expect(pages.last.navPath, 'local/den.html#tv');
      expect(pages.last.route, 'den.html#tv');
      expect(parseCustomPages('not json'), isEmpty);
    });

    test('a custom page keeps its query and fragment as a navigation path', () {
      expect(
        navPathOfUri(Uri.parse('http://ha.test/local/a.html?x=1#b')),
        'local/a.html?x=1#b',
      );
      expect(
        navPathOfUri(Uri.parse('http://ha.test/lovelace/home?edit=1#x')),
        'lovelace/home',
      );
      expect(
        dashboardPathOfUrl('http://ha.test/local/a.html#b', 'http://ha.test'),
        'local/a.html#b',
      );
      expect(
        dashboardPathOfUrl('http://ha.test/lovelace/home#x', 'http://ha.test'),
        'lovelace/home',
      );
    });

    test('the ESPHome select tells layouts of one page apart', () {
      const options = ['lovelace/home', 'local/a.html#one', 'local/a.html#two'];
      expect(
        matchDashboardView('http://ha.test/local/a.html#two', options),
        'local/a.html#two',
      );
      expect(matchDashboardView('http://ha.test/local/a.html', options), null);
    });
  });

  group('manager', () {
    late SettingsManager settings;
    late HomeAssistantManager ha;
    late CommandRegistry commands;
    late List<String> loads;
    late String location;

    Future<void> build(List<Map<String, String>> pages) async {
      SharedPreferences.setMockInitialValues({
        'ks.ha.url': 'http://ha.test:8123',
        'ks.ha.token': 'token',
        'ks.browser.start_url': 'http://ha.test:8123/lovelace/home',
        'ks.ha.custom_pages': jsonEncode(pages),
      });
      final bus = EventBus();
      final log = Logger();
      commands = CommandRegistry(log);
      settings = SettingsManager(bus, commands, log);
      await settings.init();
      loads = [];
      location = 'http://ha.test:8123/lovelace/home';
      commands
        ..register(
          Command(
            name: 'evalJs',
            description: 'stub',
            handler: (p) async {
              final code = '${p['code']}';
              final here = Uri.parse(location);
              // The page's dashboard registry.
              if (code.contains('hass.panels')) {
                return CommandResult.ok(
                  jsonEncode([
                    {'url_path': 'lovelace', 'title': 'Overview'},
                  ]),
                );
              }
              // The custom page hop.
              if (code.contains("var target = '/' +")) {
                final target = RegExp(
                  r"var target = '/' \+ \x22([^\x22]*)\x22",
                ).firstMatch(code)!.group(1)!;
                final cut = target.indexOf('#');
                final file = cut < 0 ? target : target.substring(0, cut);
                final hash = cut < 0 ? '' : target.substring(cut + 1);
                final current =
                    here.path.substring(1) +
                    (here.hasQuery ? '?${here.query}' : '');
                if (current != file) return const CommandResult.ok('load');
                if (here.fragment == hash) {
                  return const CommandResult.ok('already');
                }
                location = here.replace(fragment: hash).toString();
                return const CommandResult.ok('navigated');
              }
              // The view soft navigation.
              if (code.contains('pushState')) {
                if (here.path.startsWith('/local/')) {
                  return const CommandResult.ok('load');
                }
                final path = RegExp(
                  r"var path = '/' \+ \x22([^\x22]*)\x22",
                ).firstMatch(code)!.group(1)!;
                location = 'http://ha.test:8123/$path';
                return const CommandResult.ok('navigated');
              }
              return const CommandResult.ok('false');
            },
          ),
        )
        ..register(
          Command(
            name: 'loadUrl',
            description: 'stub',
            handler: (p) async {
              loads.add('${p['url']}');
              location = '${p['url']}';
              return const CommandResult.ok();
            },
          ),
        )
        ..register(
          Command(
            name: 'hideOverlayPage',
            description: 'stub',
            handler: (_) async => const CommandResult.ok(),
          ),
        );
      ha = HomeAssistantManager(bus, commands, log, settings);
      await ha.init();
    }

    test('the pages are listed as one more dashboard, last', () async {
      await build([
        {'name': 'Kitchen', 'path': '/local/kitchen.html'},
        {'name': 'Den', 'path': '/local/den.html#tv'},
      ]);
      final dashboards = await ha.listDashboards();
      expect(dashboards!.last, {
        'url_path': 'local',
        'title': 'Custom Pages',
        'icon': customPagesIcon,
        'custom': true,
      });
      expect(await ha.listDashboardViews('local'), [
        {'title': 'Kitchen', 'route': 'kitchen.html', 'icon': customPageIcon},
        {'title': 'Den', 'route': 'den.html#tv', 'icon': customPageIcon},
      ]);
    });

    test('no pages, no entry', () async {
      await build([]);
      final dashboards = await ha.listDashboards();
      expect(dashboards!.map((d) => d['url_path']), ['lovelace']);
    });

    test('a page is a full load and so is the way back to a view', () async {
      await build([]);
      expect(await ha.navigateToViewPath('local/kitchen.html'), 'navigated');
      expect(loads, ['http://ha.test:8123/local/kitchen.html']);
      expect(await ha.navigateToViewPath('lovelace/home'), 'navigated');
      expect(loads.last, 'http://ha.test:8123/lovelace/home');
    });

    test('another layout of the same page only changes the fragment', () async {
      await build([]);
      await ha.navigateToViewPath('local/wall.html#kitchen');
      expect(loads, hasLength(1));
      expect(await ha.navigateToViewPath('local/wall.html#den'), 'navigated');
      expect(await ha.navigateToViewPath('local/wall.html#den'), 'already');
      expect(loads, hasLength(1));
      expect(location, 'http://ha.test:8123/local/wall.html#den');
    });

    test('the home view of a custom start page keeps its fragment', () async {
      await build([]);
      await settings.set(
        defs.startUrl,
        'http://ha.test:8123/local/wall.html#den',
      );
      expect(ha.homeViewPath(), 'local/wall.html#den');
    });

    test('Save & Validate saves only a page Home Assistant serves', () async {
      await build([]);
      final requested = <String>[];
      Future<String?> save(String path, {int status = 200, String? original}) =>
          http.runWithClient(
            () =>
                ha.saveCustomPage(name: 'Wall', path: path, original: original),
            () => MockClient((request) async {
              requested.add('${request.url}');
              expect(request.headers['authorization'], isNull);
              return http.Response('', status);
            }),
          );

      expect(await save('/local/missing.html', status: 404), 'not_found');
      expect(await save('/local/secret.html', status: 403), 'status:403');
      expect(await save('/config/x'), 'path');
      expect(ha.customPages, isEmpty);

      expect(await save('wall.html#den'), isNull);
      expect(requested.last, 'http://ha.test:8123/local/wall.html');
      expect(ha.customPages.single.path, '/local/wall.html#den');

      expect(await save('/local/wall.html#den'), 'duplicate');
      // Changing the page in place keeps its own path free to reuse.
      expect(
        await save('/local/wall2.html', original: '/local/wall.html#den'),
        isNull,
      );
      expect(ha.customPages.single.path, '/local/wall2.html');
    });

    test('a page is removed by its path', () async {
      await build([
        {'name': 'Kitchen', 'path': '/local/kitchen.html'},
        {'name': 'Den', 'path': '/local/den.html'},
      ]);
      final removed = await commands.execute('haRemoveCustomPage', {
        'path': '/local/kitchen.html',
      });
      expect(removed.ok, isTrue);
      expect(ha.customPages.map((p) => p.name), ['Den']);
    });
  });
}
