import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/js_api/js_api_manager.dart';
import 'package:kiosk_satellite/managers/js_api/page_ha_socket.dart';

/// The managed Home Assistant connection for custom pages: the app signs
/// in with the kiosk's token and passes frames through, per document.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late List<WebSocket> served;
  late List<String> received;
  late Completer<void> firstFrame;
  late String acceptToken;
  late PageHaSockets sockets;
  late List<String> delivered;
  late bool allowed;
  late String token;

  setUp(() async {
    served = [];
    received = [];
    firstFrame = Completer<void>();
    acceptToken = 'kiosk-token';
    // A Home Assistant that signs in one token and answers every command.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      served.add(ws);
      ws.add(jsonEncode({'type': 'auth_required', 'ha_version': '2026.10.1'}));
      ws.listen((raw) {
        // Home Assistant also takes several commands in one frame.
        final decoded = jsonDecode(raw as String);
        final msg = (decoded is List ? decoded.first : decoded) as Map;
        if (msg['type'] == 'auth') {
          ws.add(
            jsonEncode(
              msg['access_token'] == acceptToken
                  ? {'type': 'auth_ok', 'ha_version': '2026.10.1'}
                  : {'type': 'auth_invalid', 'message': 'Invalid access'},
            ),
          );
          return;
        }
        received.add(raw);
        if (!firstFrame.isCompleted) firstFrame.complete();
        // Three frames at once, as a busy subscription sends them.
        for (var i = 0; i < 3; i++) {
          ws.add(jsonEncode({'id': msg['id'], 'type': 'event', 'n': i}));
        }
      });
    });
    allowed = true;
    token = 'kiosk-token';
    delivered = [];
    sockets = PageHaSockets(
      baseUrl: () => 'http://127.0.0.1:${server.port}',
      token: () => token,
      allowed: () async => allowed,
      log: Logger(),
    )..run = delivered.add;
  });

  tearDown(() async {
    sockets.dispose();
    await server.close(force: true);
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  test('a page socket signs in with the kiosk token and passes frames '
      'through, batched', () async {
    final open = await sockets.open('doc1', 's1');
    expect(open, {'ok': true, 'haVersion': '2026.10.1'});
    expect(sockets.send('doc1', 's1', '{"id":2,"type":"get_states"}'), isTrue);
    await firstFrame.future;
    await settle();
    // The page's frame reached Home Assistant untouched, auth never did.
    expect(received, ['{"id":2,"type":"get_states"}']);
    // The three answers arrived in one delivery.
    expect(delivered, hasLength(1));
    final batch = RegExp(
      r'receive\("doc1", (.*)\);$',
    ).firstMatch(delivered.single)!;
    final frames = (jsonDecode(batch.group(1)!) as Map)['s1'] as List;
    expect(frames, hasLength(3));
    expect(jsonDecode(frames.last as String), {
      'id': 2,
      'type': 'event',
      'n': 2,
    });
  });

  test(
    'credential commands never reach Home Assistant, the page hears no',
    () async {
      await sockets.open('doc1', 's1');
      expect(
        sockets.send(
          'doc1',
          's1',
          '{"id":2,"type":"auth/long_lived_access_token",'
              '"client_name":"x","lifespan":3650}',
        ),
        isTrue,
      );
      // Spelled with an escape, in a list beside an allowed command.
      sockets.send(
        'doc1',
        's1',
        r'[{"id":3,"type":"\u0061uth/delete_refresh_token"},'
            '{"id":4,"type":"auth/current_user"}]',
      );
      sockets.send('doc1', 's1', '{"id":5,"type":"config/auth/create"}');
      await firstFrame.future;
      await settle();
      expect(received, ['[{"id":4,"type":"auth/current_user"}]']);
      final refused = [
        for (final call in delivered)
          for (final frame
              in (jsonDecode(
                        RegExp(
                          r'receive\("doc1", (.*)\);$',
                        ).firstMatch(call)!.group(1)!,
                      )
                      as Map)['s1']
                  as List)
            jsonDecode(frame as String) as Map,
      ].where((f) => f['type'] == 'result').toList();
      expect(refused.map((f) => f['id']), [2, 3, 5]);
      expect(refused.every((f) => f['success'] == false), isTrue);
      expect((refused.first['error'] as Map)['code'], 'not_allowed');
    },
  );

  test('a wrong token, no token or the setting off open nothing', () async {
    acceptToken = 'other';
    expect(await sockets.open('doc1', 's1'), {
      'ok': false,
      'error': 'auth_invalid',
    });
    token = '';
    expect(await sockets.open('doc1', 's2'), {
      'ok': false,
      'error': 'not_configured',
    });
    allowed = false;
    final before = served.length;
    expect(await sockets.open('doc1', 's3'), {
      'ok': false,
      'error': 'not_allowed',
    });
    expect(served.length, before);
    expect(sockets.openCount, 0);
  });

  test('a new document takes over and the old one is cut off', () async {
    await sockets.open('doc1', 's1');
    expect(served, hasLength(1));
    final gone = served.first.done;
    await sockets.open('doc2', 's1');
    await gone.timeout(const Duration(seconds: 2));
    expect(sockets.send('doc1', 's1', '{}'), isFalse);
    expect(sockets.send('doc2', 's1', '{"id":2}'), isTrue);
    expect(sockets.openCount, 1);
  });

  test('a navigation closes every socket and tells the page', () async {
    await sockets.open('doc1', 's1');
    await sockets.open('doc1', 's2');
    sockets.closeAll('navigation', notify: true);
    expect(sockets.openCount, 0);
    expect(delivered, [
      'window.__ksHaSocket && window.__ksHaSocket.closed("doc1", "s1", '
          '"navigation");',
      'window.__ksHaSocket && window.__ksHaSocket.closed("doc1", "s2", '
          '"navigation");',
    ]);
  });

  test(
    'a dropped connection hands over its last frames, then closes',
    () async {
      await sockets.open('doc1', 's1');
      sockets.send('doc1', 's1', '{"id":2}');
      await firstFrame.future;
      await served.single.close();
      await settle();
      expect(delivered.first, contains('receive("doc1"'));
      expect(
        delivered.last,
        contains('closed("doc1", "s1", "connection_lost")'),
      );
      expect(sockets.openCount, 0);
    },
  );

  test('one document holds a few sockets at most', () async {
    for (var i = 0; i < PageHaSockets.maxPerPage; i++) {
      expect((await sockets.open('doc1', 's$i'))['ok'], isTrue);
    }
    expect(await sockets.open('doc1', 'extra'), {
      'ok': false,
      'error': 'too_many',
    });
    expect(await sockets.open('doc1', 's0'), {'ok': false, 'error': 'in_use'});
  });

  test('the bridge checks its arguments', () async {
    final log = Logger();
    final api = JsApiManager(EventBus(), CommandRegistry(log), log, '1.0.0');
    expect(await api.handleHaSocket(['open', 'doc1', 's1']), {
      'ok': false,
      'error': 'not_allowed',
    });
    api.haSockets = sockets;
    expect(await api.handleHaSocket(['open', 1, 's1']), isNull);
    expect(await api.handleHaSocket(['open', '', 's1']), isNull);
    expect(await api.handleHaSocket(['open', 'doc1', 'x' * 65]), isNull);
    expect(await api.handleHaSocket(['dance', 'doc1', 's1']), isNull);
    expect(
      (await api.handleHaSocket(['open', 'doc1', 's1']) as Map)['ok'],
      true,
    );
    expect(await api.handleHaSocket(['send', 'doc1', 's1', 42]), isFalse);
    expect(
      await api.handleHaSocket(['send', 'doc1', 's1', '{"id":2}']),
      isTrue,
    );
    expect(await api.handleHaSocket(['close', 'doc1', 's1']), isTrue);
    expect(sockets.openCount, 0);
  });
}
