import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/remote/remote_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the remote server refuses before anyone has proved anything: a body
/// too large to be a password, and a browser page on another origin reaching
/// the endpoints that answer without a token.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  late SettingsManager settings;
  late RemoteManager remote;
  late int port;
  late List<String> executed;

  Future<void> boot(Map<String, Object> prefs) async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    SharedPreferences.setMockInitialValues({
      'ks.remote.enabled': true,
      'ks.remote.port': port,
      ...prefs,
    });
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    executed = [];
    for (final name in ['fleetInviteReceived', 'getDeviceInfo']) {
      commands.register(
        Command(
          name: name,
          description: 'stub',
          handler: (p) async {
            executed.add(name);
            return CommandResult.ok({'from': name});
          },
        ),
      );
    }
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    remote = RemoteManager(bus, commands, log, settings);
    await remote.init();
    // The server starts off the settings listener.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  tearDown(() async {
    await settings.set(defs.remoteEnabled, false);
    await remote.dispose();
  });

  Future<(int, Map<String, Object?>, HttpHeaders)> post(
    String path,
    String body, {
    String? origin,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (origin != null) req.headers.set('origin', origin);
      req.write(body);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {}
      return (
        res.statusCode,
        decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{},
        res.headers,
      );
    } finally {
      client.close(force: true);
    }
  }

  const configured = {
    'ks.browser.start_url': 'http://ha.local:8123/lovelace/0',
    'ks.remote.password': 'secret',
  };

  test('a login body too large to be a password is never buffered', () async {
    await boot(configured);
    // Valid JSON and the right password, so the only thing that can refuse
    // it is the size: under the old reader this logged in.
    final padded = jsonEncode({'password': 'secret', 'pad': 'x' * 200000});
    final (status, _, _) = await post('/api/login', padded);
    expect(status, 401);

    final (ok, body, _) = await post(
      '/api/login',
      jsonEncode({'password': 'secret'}),
    );
    expect(ok, 200);
    expect(body['token'], isA<String>());
  });

  test('a page on another origin cannot send an invitation', () async {
    await boot(configured);
    final invite = jsonEncode({'id': 'leader', 'name': 'L', 'nonce': 'n'});

    final (hostile, error, _) = await post(
      '/api/fleet/invite',
      invite,
      origin: 'http://evil.example',
    );
    expect(hostile, 403);
    expect(error['error'], 'cross-origin');
    expect(executed, isNot(contains('fleetInviteReceived')));

    // Another kiosk is not a browser and names no origin at all.
    final (kiosk, _, _) = await post('/api/fleet/invite', invite);
    expect(kiosk, 200);
    expect(executed, contains('fleetInviteReceived'));
  });

  test("the admin's own page is the same origin, whatever its port", () async {
    await boot(configured);
    // Spaced past the invitation throttle.
    final (status, _, _) = await post(
      '/api/fleet/invite',
      jsonEncode({'id': 'leader', 'name': 'L', 'nonce': 'n'}),
      origin: 'http://127.0.0.1:$port',
    );
    expect(status, 200);

    await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 100));
    final (otherPort, _, _) = await post(
      '/api/fleet/invite',
      jsonEncode({'id': 'leader', 'name': 'L', 'nonce': 'n'}),
      origin: 'http://127.0.0.1:1',
    );
    expect(otherPort, 403);
  });

  test(
    'a page elsewhere cannot choose an unconfigured panel\'s password',
    () async {
      // No start URL and no password: the window in which setting one is
      // public, which is exactly when a hostile page would try.
      await boot(const {});
      final (hostile, _, _) = await post(
        '/api/setup/password',
        jsonEncode({'password': 'chosen-by-attacker'}),
        origin: 'http://evil.example',
      );
      expect(hostile, 403);
      expect(settings.get(defs.remotePassword), isEmpty);

      // The wizard itself, served from this origin, still can.
      final (wizard, body, _) = await post(
        '/api/setup/password',
        jsonEncode({'password': 'chosen-by-owner'}),
        origin: 'http://127.0.0.1:$port',
      );
      expect(wizard, 200);
      expect(body['token'], isA<String>());
    },
  );

  test('every response tells the browser not to guess its type', () async {
    await boot(configured);
    final (_, _, headers) = await post('/api/login', '{}');
    expect(headers.value('x-content-type-options'), 'nosniff');
    expect(headers.value('referrer-policy'), 'no-referrer');
  });
}
