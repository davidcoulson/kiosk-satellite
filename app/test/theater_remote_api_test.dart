import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/remote/remote_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/managers/theater/theater_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Theater mode and navigate over the remote API (T-70): the same commands
/// every other surface uses, behind the same bearer token as every other
/// command.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  late SettingsManager settings;
  late RemoteManager remote;
  late TheaterManager theater;
  late int port;
  late List<Map<String, Object?>> navigations;

  setUp(() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    SharedPreferences.setMockInitialValues({
      'ks.browser.start_url': 'http://panel.local:8787/',
      'ks.remote.enabled': true,
      'ks.remote.password': 'secret',
      'ks.remote.port': port,
    });
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    navigations = [];
    for (final name in ['holdBrightness', 'releaseBrightness']) {
      commands.register(
        Command(
          name: name,
          description: 'fake',
          handler: (_) async => const CommandResult.ok(),
        ),
      );
    }
    commands.register(
      Command(
        name: 'navigate',
        description: 'fake',
        handler: (p) async {
          navigations.add(Map.of(p));
          return const CommandResult.ok();
        },
      ),
    );
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    theater = TheaterManager(bus, commands, log, settings);
    await theater.init();
    remote = RemoteManager(bus, commands, log, settings);
    await remote.init();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  });

  tearDown(() async {
    await settings.set(defs.remoteEnabled, false);
    await remote.dispose();
    await theater.dispose();
  });

  Future<String> login() async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/login'),
      );
      req.write(jsonEncode({'password': 'secret'}));
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      return body['token'] as String;
    } finally {
      client.close(force: true);
    }
  }

  Future<(int, Object?)> command(
    String name,
    Map<String, Object?> body, {
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/commands/$name'),
      );
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
    } finally {
      client.close(force: true);
    }
  }

  test('the four commands answer with a token', () async {
    final token = await login();
    final (on, _) = await command('setTheaterMode', {
      'active': true,
    }, token: token);
    expect(on, 200);
    expect(theater.phase, TheaterPhase.dim);

    final (_, state) = await command('getTheaterMode', {}, token: token);
    expect(((state as Map)['data'] as Map)['phase'], 'dim');
    expect((state['data'] as Map)['source'], 'remote');

    final (peek, peeked) = await command('theaterPeek', {
      'seconds': 10,
    }, token: token);
    expect(peek, 200);
    expect((peeked as Map)['data'], isTrue);
    expect(theater.phase, TheaterPhase.peek);

    final (nav, _) = await command('navigate', {
      'url': '#/showtime',
    }, token: token);
    expect(nav, 200);
    expect(navigations.single['url'], '#/showtime');

    await command('setTheaterMode', {'active': false}, token: token);
    expect(theater.active, isFalse);
  });

  test('none of them answers without a token', () async {
    for (final name in [
      'setTheaterMode',
      'getTheaterMode',
      'theaterPeek',
      'navigate',
    ]) {
      final (status, _) = await command(name, {'active': true, 'url': '#/x'});
      expect(status, 401, reason: name);
    }
    expect(theater.active, isFalse);
    expect(navigations, isEmpty);
  });

  Future<(int, Map<String, Object?>)> http(
    String method,
    String path, {
    Map<String, Object?>? body,
    required String token,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      req.headers.set('authorization', 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final decoded = text.isEmpty ? null : jsonDecode(text);
      return (
        res.statusCode,
        decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{},
      );
    } finally {
      client.close(force: true);
    }
  }

  test('T-71 the remote admin is handed the Theater mode group, every key '
      'with its range, and a change saves', () async {
    final token = await login();
    final (_, payload) = await http('GET', '/api/settings', token: token);
    final rows = (payload['settings'] as List).cast<Map>();
    final group = {
      for (final r in rows)
        if (r['section'] == 'Theater mode') r['key']: r,
    };
    expect(group.keys.toSet(), {
      'theater.backlight',
      'theater.overlay_opacity',
      'theater.peek_brightness',
      'theater.peek_seconds',
      'theater.black_after_minutes',
      'theater.first_touch_wakes',
      'theater.ignore_ambient_wake',
      'theater.peek_on_alerts',
      'theater.mute_wake_word',
      'theater.max_hours',
    });
    for (final r in group.values) {
      expect(r['category'], 'Screen & Audio', reason: '${r['key']}');
      if (r['type'] == 'number') {
        expect(r['min'], isNotNull, reason: '${r['key']}');
        expect(r['max'], isNotNull, reason: '${r['key']}');
      }
    }
    expect(group['theater.overlay_opacity']!['max'], 0.95);
    expect(group['theater.peek_seconds']!['min'], 3);

    final (saved, _) = await http(
      'PATCH',
      '/api/settings',
      body: {'theater.overlay_opacity': 0.4},
      token: token,
    );
    expect(saved, 200);
    expect(settings.get(defs.theaterOverlayOpacity), 0.4);
  });

  test('T-71 the device refuses a custom start page that is not a web page, '
      'whatever sent it', () async {
    final token = await login();
    final (_, refused) = await http(
      'PATCH',
      '/api/settings',
      body: {'browser.custom_start_url': 'ftp://10.2.3.20/'},
      token: token,
    );
    expect(refused['rejected'], contains('browser.custom_start_url'));
    expect(settings.get(defs.customStartUrl), isEmpty);
    await http(
      'PATCH',
      '/api/settings',
      body: {'browser.custom_start_url': 'http://10.2.3.20:8787'},
      token: token,
    );
    expect(settings.get(defs.customStartUrl), 'http://10.2.3.20:8787');
  });
}
