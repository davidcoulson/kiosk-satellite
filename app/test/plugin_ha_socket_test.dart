import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/home_assistant/plugin_ha_socket.dart';

/// The Home Assistant connection plugins share: the app signs in, numbers
/// every message and owns each plugin's subscriptions.
void main() {
  late HttpServer server;
  late List<WebSocket> served;
  late List<Map> received;
  late HaPluginSocket socket;
  late List<(String, String, Map<String, Object?>)> emitted;

  setUp(() async {
    served = [];
    received = [];
    emitted = [];
    // A Home Assistant that signs in, runs services and accepts
    // subscriptions.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      served.add(ws);
      ws.add(jsonEncode({'type': 'auth_required', 'ha_version': '2026.10.1'}));
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map;
        if (msg['type'] == 'auth') {
          ws.add(jsonEncode({'type': 'auth_ok', 'ha_version': '2026.10.1'}));
          return;
        }
        received.add(msg);
        final id = msg['id'];
        void result(Object? value) => ws.add(
          jsonEncode({
            'id': id,
            'type': 'result',
            'success': true,
            'result': value,
          }),
        );
        switch (msg['type']) {
          case 'call_service' when msg['domain'] == 'missing':
            ws.add(
              jsonEncode({
                'id': id,
                'type': 'result',
                'success': false,
                'error': {
                  'code': 'service_not_found',
                  'message': 'Action missing.x not found',
                },
              }),
            );
          case 'call_service':
            result({
              'context': {'id': 'c1'},
            });
          case 'get_states':
            result([
              for (var i = 0; i < 2000; i++)
                {'entity_id': 'sensor.s$i', 'state': '$i'},
            ]);
          case 'render_template':
            // A streaming command: the answer, then an event.
            result(null);
            ws.add(
              jsonEncode({
                'id': id,
                'type': 'event',
                'event': {'result': 'on'},
              }),
            );
          case 'auth/current_user':
            result({'name': 'Kiosk'});
          case 'subscribe_trigger':
          case 'subscribe_events':
          case 'unsubscribe_events':
            result(null);
          case 'refuse_me':
            ws.add(
              jsonEncode({
                'id': id,
                'type': 'result',
                'success': false,
                'error': {'code': 'unknown_command', 'message': 'Unknown'},
              }),
            );
        }
      });
    });
    socket = HaPluginSocket(
      baseUrl: () => 'http://127.0.0.1:${server.port}',
      token: () => 'kiosk-token',
      log: Logger(),
      idleClose: const Duration(milliseconds: 200),
    )..emit = (owner, key, payload) => emitted.add((owner, key, payload));
  });

  tearDown(() async {
    socket.dispose();
    await server.close(force: true);
  });

  Future<void> settle([int ms = 80]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// Push an event for subscription [id] from the server's side.
  void fire(int id, Map event, {int connection = -1}) {
    final ws = connection < 0 ? served.last : served[connection];
    ws.add(jsonEncode({'id': id, 'type': 'event', 'event': event}));
  }

  int idOf(String type, [int nth = 0]) =>
      received.where((m) => m['type'] == type).elementAt(nth)['id'] as int;

  test('a call returns Home Assistant result, or its error', () async {
    final ok = await socket.call('p:1', {
      'type': 'call_service',
      'domain': 'light',
      'service': 'turn_on',
      'target': {'entity_id': 'light.kitchen'},
    });
    expect(ok, {
      'ok': true,
      'result': {
        'context': {'id': 'c1'},
      },
    });
    // KS numbered it, the plugin never chose an id.
    expect(received.single['id'], isA<int>());
    expect(received.single['target'], {'entity_id': 'light.kitchen'});
    final missing = await socket.call('p:1', {
      'type': 'call_service',
      'domain': 'missing',
      'service': 'x',
    });
    expect(missing, {
      'ok': false,
      'error': {
        'code': 'service_not_found',
        'message': 'Action missing.x not found',
      },
    });
  });

  test(
    'credential, bookkeeping and malformed messages never leave KS',
    () async {
      Future<String> code(Map<String, Object?> message) async =>
          ((await socket.call('p:1', message))['error'] as Map)['code']
              as String;
      expect(
        await code({
          'type': 'auth/long_lived_access_token',
          'client_name': 'x',
        }),
        'not_allowed',
      );
      expect(await code({'type': 'auth/delete_refresh_token'}), 'not_allowed');
      expect(
        await code({'type': 'config/auth_provider/homeassistant/create'}),
        'not_allowed',
      );
      expect(
        await code({'type': 'unsubscribe_events', 'subscription': 1}),
        'not_allowed',
      );
      expect(await code({'type': 'ping'}), 'not_allowed');
      expect(await code({'id': 9, 'type': 'call_service'}), 'invalid_message');
      expect(await code({'domain': 'light'}), 'invalid_message');
      expect(
        await code({'type': 'call_service', 'data': 'x' * 40000}),
        'too_large',
      );
      expect(received, isEmpty);
      // Who the kiosk is signed in as is fine.
      expect(await socket.call('p:1', {'type': 'auth/current_user'}), {
        'ok': true,
        'result': {'name': 'Kiosk'},
      });
      expect(received.single['type'], 'auth/current_user');
    },
  );

  test('a result over 32 KB is refused', () async {
    final result = await socket.call('p:1', {'type': 'get_states'});
    expect((result['error'] as Map)['code'], 'too_large');
  });

  test('a subscription delivers its events to its owner and key', () async {
    final result = await socket.subscribe('p:1', 'door', {
      'type': 'subscribe_trigger',
      'trigger': {'platform': 'state', 'entity_id': 'binary_sensor.door'},
    });
    expect(result, {'ok': true});
    final id = idOf('subscribe_trigger');
    fire(id, {
      'variables': {
        'trigger': {'to_state': 'on'},
      },
    });
    fire(id, {
      'variables': {
        'trigger': {'to_state': 'off'},
      },
    });
    await settle();
    expect(emitted, hasLength(2));
    expect(emitted.first.$1, 'p:1');
    expect(emitted.first.$2, 'door');
    expect(emitted.first.$3['type'], 'event');
    expect(((emitted.last.$3['event'] as Map)['variables'] as Map)['trigger'], {
      'to_state': 'off',
    });
    // The same key twice is refused, a bad key too.
    expect(
      ((await socket.subscribe('p:1', 'door', {
            'type': 'subscribe_events',
            'event_type': 'x',
          }))['error']
          as Map)['code'],
      'in_use',
    );
    expect(
      ((await socket.subscribe('p:1', 'no spaces', {
            'type': 'subscribe_events',
          }))['error']
          as Map)['code'],
      'invalid_key',
    );
    // Unsubscribing tells Home Assistant which one, and nothing follows.
    socket.unsubscribe('p:1', 'door');
    await settle();
    final unsub = received.lastWhere((m) => m['type'] == 'unsubscribe_events');
    expect(unsub['subscription'], id);
    fire(id, {'late': true});
    await settle();
    expect(emitted, hasLength(2));
  });

  test('a rejected subscription is not kept', () async {
    final result = await socket.subscribe('p:1', 'bad', {'type': 'refuse_me'});
    expect((result['error'] as Map)['code'], 'unknown_command');
    expect(socket.subscriptionCount, 0);
  });

  test('a plugin holds at most 16 subscriptions', () async {
    for (var i = 0; i < 16; i++) {
      expect(
        (await socket.subscribe('p:1', 'k$i', {
          'type': 'subscribe_events',
          'event_type': 'e$i',
        }))['ok'],
        isTrue,
      );
    }
    final over = await socket.subscribe('p:1', 'k16', {
      'type': 'subscribe_events',
      'event_type': 'e',
    });
    expect((over['error'] as Map)['code'], 'too_many');
    // Another plugin has its own allowance.
    expect(
      (await socket.subscribe('p:2', 'k0', {
        'type': 'subscribe_events',
        'event_type': 'e',
      }))['ok'],
      isTrue,
    );
  });

  test("a session's end releases only its own subscriptions", () async {
    await socket.subscribe('p:1', 'a', {
      'type': 'subscribe_events',
      'event_type': 'a',
    });
    await socket.subscribe('p:2', 'b', {
      'type': 'subscribe_events',
      'event_type': 'b',
    });
    socket.release('p:1');
    await settle();
    final unsubs = received.where((m) => m['type'] == 'unsubscribe_events');
    expect(unsubs.map((m) => m['subscription']), [idOf('subscribe_events', 0)]);
    fire(idOf('subscribe_events', 1), {'n': 1});
    await settle();
    expect(emitted.map((e) => e.$1), ['p:2']);
  });

  test('a lost connection comes back and subscribes again', () async {
    await socket.subscribe('p:1', 'door', {
      'type': 'subscribe_trigger',
      'trigger': {'platform': 'state'},
    });
    await served.single.close();
    await settle();
    expect(emitted.single.$3['type'], 'disconnected');
    expect(socket.connected, isFalse);
    // The first retry waits a second.
    await settle(1500);
    expect(served, hasLength(2));
    expect(emitted.last.$3['type'], 'resubscribed');
    final again = idOf('subscribe_trigger', 1);
    fire(again, {'n': 1});
    await settle();
    expect(emitted.last.$3, {
      'type': 'event',
      'event': {'n': 1},
    });
  });

  test('events of a call nobody subscribed are stopped', () async {
    final result = await socket.call('p:1', {
      'type': 'render_template',
      'template': '{{ 1 }}',
    });
    expect(result, {'ok': true, 'result': null});
    await settle();
    final id = idOf('render_template');
    expect(
      received.where((m) => m['type'] == 'unsubscribe_events').single,
      containsPair('subscription', id),
    );
    expect(emitted, isEmpty);
  });

  test('the connection closes when idle and opens on the next call', () async {
    await socket.call('p:1', {
      'type': 'call_service',
      'domain': 'a',
      'service': 'b',
    });
    expect(socket.connected, isTrue);
    await settle(400);
    expect(socket.connected, isFalse);
    await socket.call('p:1', {
      'type': 'call_service',
      'domain': 'a',
      'service': 'b',
    });
    expect(served, hasLength(2));
  });

  test('without an address or token nothing connects', () async {
    final unset = HaPluginSocket(
      baseUrl: () => '',
      token: () => '',
      log: Logger(),
    );
    final result = await unset.call('p:1', {'type': 'call_service'});
    expect((result['error'] as Map)['code'], 'not_configured');
    unset.dispose();
  });
}
