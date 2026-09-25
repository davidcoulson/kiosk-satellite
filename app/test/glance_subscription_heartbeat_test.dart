import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A subscription whose connection dies without closing must still report
/// the loss, or its owner keeps stale states forever. Weather Mood once
/// showed last night's sun and weather at noon on a Portal Go.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GlanceSubscription.heartbeat = const Duration(milliseconds: 50);
    GlanceSubscription.pongTimeout = const Duration(milliseconds: 50);
  });
  tearDown(() {
    GlanceSubscription.heartbeat = const Duration(seconds: 30);
    GlanceSubscription.pongTimeout = const Duration(seconds: 10);
  });

  /// A Home Assistant stand-in that accepts the subscription and answers
  /// pings while [answering] says so.
  Future<(HttpServer, HomeAssistantManager, List<String>)> start(
    bool Function() answering,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pings = <String>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode({'type': 'auth_required'}));
      socket.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        switch (msg['type']) {
          case 'auth':
            socket.add(jsonEncode({'type': 'auth_ok'}));
          case 'subscribe_entities':
            socket.add(
              jsonEncode({'id': msg['id'], 'type': 'result', 'success': true}),
            );
            socket.add(
              jsonEncode({
                'id': msg['id'],
                'type': 'event',
                'event': {
                  'a': {
                    'sun.sun': {'s': 'above_horizon', 'a': {}},
                  },
                },
              }),
            );
          case 'ping':
            pings.add('${msg['id']}');
            if (answering()) {
              socket.add(jsonEncode({'id': msg['id'], 'type': 'pong'}));
            }
        }
      });
    });
    SharedPreferences.setMockInitialValues({
      'ks.ha.url': 'http://127.0.0.1:${server.port}',
      'ks.ha.token': 'token',
    });
    final bus = EventBus();
    final log = Logger();
    final settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
    return (
      server,
      HomeAssistantManager(bus, CommandRegistry(log), log, settings),
      pings,
    );
  }

  test('a subscription that answers pings stays open', () async {
    final (server, ha, pings) = await start(() => true);
    addTearDown(() => server.close(force: true));
    final states = <String>[];
    final live = await ha.subscribeEntities([
      'sun.sun',
    ], (id, state) => states.add('${state['state']}'));
    var closed = false;
    live!.onClosed = () => closed = true;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(states, ['above_horizon']);
    expect(pings.length, greaterThan(2));
    expect(closed, false);
    expect(live.isClosed, false);
    await live.close();
  });

  test('a silent connection counts as closed', () async {
    var answering = true;
    final (server, ha, pings) = await start(() => answering);
    addTearDown(() => server.close(force: true));
    final live = await ha.subscribeEntities(['sun.sun'], (_, _) {});
    final closed = Completer<void>();
    live!.onClosed = closed.complete;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(live.isClosed, false);
    // The server keeps the socket open but stops answering.
    answering = false;
    await closed.future.timeout(const Duration(seconds: 2));
    expect(live.isClosed, true);
  });
}
