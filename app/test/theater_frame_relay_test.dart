import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/browser/navigation.dart';
import 'package:kiosk_satellite/managers/js_api/js_api_manager.dart';
import 'package:kiosk_satellite/managers/js_api/user_script.dart';

/// Theater mode from a page in a frame: the theater panel's web app on a
/// Home Assistant Webpage dashboard, so Voice Satellite keeps running in the
/// dashboard around it. The bridge stays main-frame only; the dashboard
/// relays theater calls from the one allowed origin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JsApiManager api;
  late List<(String, Map<String, Object?>)> calls;

  final ha = Uri.parse('http://ha.local:8123');
  const allowed = 'https://ht-kiosk.coulson.io';

  Future<void> build({bool frameRule = true}) async {
    final log = Logger();
    final commands = CommandRegistry(log);
    api = JsApiManager(EventBus(), commands, log, '1.0.0');
    await api.init();
    calls = [];
    for (final name in [
      'setTheaterMode',
      'getTheaterMode',
      'theaterPeek',
      'startAudioStream',
    ]) {
      commands.register(
        Command(
          name: name,
          description: 'test stub',
          handler: (p) async {
            calls.add((name, Map.of(p)));
            if (name == 'getTheaterMode') {
              return const CommandResult.ok({'active': false, 'phase': 'off'});
            }
            return const CommandResult.ok(true);
          },
        ),
      );
    }
    api.isTrustedOrigin = (o) => o.host == 'ha.local';
    if (frameRule) {
      api.isTheaterFrameOrigin = (o) => isSameWebOrigin(allowed, o);
    }
  }

  Future<Object?> relay(
    String method,
    Map<String, Object?> params, {
    String frameOrigin = allowed,
    Uri? dashboard,
    bool mainFrame = true,
  }) => api.handleCall(
    [
      'theaterRelay',
      {'frameOrigin': frameOrigin, 'method': method, 'params': params},
    ],
    origin: dashboard ?? ha,
    mainFrame: mainFrame,
  );

  test('the allowed frame turns theater mode on, as the page', () async {
    await build();
    final r = await relay('setTheaterMode', {
      'active': true,
      'overlayOpacity': 0.6,
      'source': 'ha',
    });
    expect(r, {'accepted': true, 'result': true});
    expect(calls.single.$1, 'setTheaterMode');
    expect(calls.single.$2['source'], 'page', reason: 'not what it claimed');
    expect(calls.single.$2['overlayOpacity'], 0.6);
    expect(await relay('getTheaterMode', {}), {
      'accepted': true,
      'result': {'active': false, 'phase': 'off'},
    });
  });

  test('another frame origin is refused', () async {
    await build();
    for (final other in [
      'https://evil.example',
      'http://ht-kiosk.coulson.io', // http, not https
      'https://ht-kiosk.coulson.io:8443',
      'https://x.ht-kiosk.coulson.io',
      'null', // a sandboxed frame
      '',
    ]) {
      expect(
        await relay('setTheaterMode', {'active': true}, frameOrigin: other),
        {'accepted': false},
        reason: other,
      );
    }
    expect(calls, isEmpty);
  });

  test('only theater methods go through the relay', () async {
    await build();
    expect(await relay('startAudioStream', {}), {'accepted': false});
    expect(await relay('setBrightness', {'level': 1}), {'accepted': false});
    expect(calls, isEmpty);
  });

  test('no frame is allowed until one is configured', () async {
    await build(frameRule: false);
    expect(await relay('setTheaterMode', {'active': true}), {
      'accepted': false,
    });
    expect(calls, isEmpty);
  });

  test('the dashboard doing the relaying must itself be trusted and the main '
      'frame', () async {
    await build();
    expect(
      await relay('setTheaterMode', {
        'active': true,
      }, dashboard: Uri.parse('https://evil.example')),
      isNull,
    );
    expect(
      await relay('setTheaterMode', {'active': true}, mainFrame: false),
      isNull,
    );
    expect(calls, isEmpty);
  });

  test('isSameWebOrigin matches scheme, host and port only', () {
    expect(
      isSameWebOrigin(allowed, Uri.parse('https://ht-kiosk.coulson.io')),
      isTrue,
    );
    expect(
      isSameWebOrigin(
        'https://HT-Kiosk.coulson.io/#/showtime',
        Uri.parse('https://ht-kiosk.coulson.io:443'),
      ),
      isTrue,
    );
    expect(
      isSameWebOrigin(
        'http://10.2.3.20:8787',
        Uri.parse('http://10.2.3.20:8787'),
      ),
      isTrue,
    );
    expect(
      isSameWebOrigin('http://10.2.3.20:8787', Uri.parse('http://10.2.3.20')),
      isFalse,
    );
    expect(
      isSameWebOrigin('', Uri.parse('https://ht-kiosk.coulson.io')),
      isFalse,
    );
    expect(isSameWebOrigin('file:///x', Uri.parse('file:///x')), isFalse);
  });

  test('the injected relay passes only direct-child requests, and sends '
      'events only to frames the app accepted', () async {
    final which = await Process.run('which', ['node']);
    if (which.exitCode != 0) {
      markTestSkipped('node is not installed');
      return;
    }
    final script = buildKioskSatelliteScript(version: '1', os: 'android');
    final dir = await Directory.systemTemp.createTemp('ks-relay');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/run.js');
    await file.writeAsString(
      [
        'const target = new EventTarget();',
        'globalThis.window = globalThis;',
        'window.addEventListener = target.addEventListener.bind(target);',
        'window.dispatchEvent = target.dispatchEvent.bind(target);',
        'const calls = [];',
        'window.flutter_inappwebview = { callHandler: (h, m, p) => {',
        '  calls.push([m, p]);',
        "  if (m !== 'theaterRelay') return Promise.resolve(true);",
        "  const ok = p.frameOrigin === 'https://good.example';",
        '  return Promise.resolve(ok ? { accepted: true, result: true } '
            ': { accepted: false });',
        '} };',
        "globalThis.document = { addEventListener() {}, readyState: 'complete' };",
        'globalThis.navigator = {};',
        script,
        'function frame(parent) {',
        '  const f = { parent, got: [], closed: false };',
        '  f.postMessage = (m, o) => f.got.push([m, o]);',
        '  return f;',
        '}',
        'function send(source, origin, data) {',
        "  const e = new Event('message');",
        '  e.data = data; e.origin = origin; e.source = source;',
        '  window.dispatchEvent(e);',
        '}',
        'const tick = () => new Promise((r) => setTimeout(r, 5));',
        '(async () => {',
        '  const good = frame(window), bad = frame(window);',
        '  const nested = frame(good);',
        "  send(good, 'https://good.example', { ksTheater: 1, id: 'a', "
            "method: 'setTheaterMode', params: { active: true } });",
        "  send(bad, 'https://bad.example', { ksTheater: 1, id: 'b', "
            "method: 'setTheaterMode', params: { active: true } });",
        "  send(nested, 'https://good.example', { ksTheater: 1, id: 'c', "
            "method: 'getTheaterMode' });",
        "  send(good, 'https://good.example', { ksTheater: 1, id: 'd', "
            "method: 'startAudioStream' });",
        '  await tick();',
        "  const ev = new Event('kiosksatellite:theatermode');",
        "  ev.detail = { active: true, phase: 'dim', source: 'page' };",
        '  window.dispatchEvent(ev);',
        '  console.log(JSON.stringify({',
        "    relayed: calls.filter(([m]) => m === 'theaterRelay').map(([, p]) => [p.frameOrigin, p.method]),",
        '    good: good.got, bad: bad.got, nested: nested.got,',
        '  }));',
        '})();',
      ].join('\n'),
    );
    final run = await Process.run('node', [file.path]);
    expect(run.exitCode, 0, reason: run.stderr.toString());
    final out =
        jsonDecode(run.stdout.toString().trim().split('\n').last) as Map;
    expect(out['relayed'], [
      ['https://good.example', 'setTheaterMode'],
      ['https://bad.example', 'setTheaterMode'],
    ], reason: 'not the nested frame, not a non-theater method');
    // A refused method is answered at once; an app answer takes a turn.
    expect(out['good'], [
      [
        {'ksTheater': 1, 'id': 'd', 'result': null},
        'https://good.example',
      ],
      [
        {'ksTheater': 1, 'id': 'a', 'result': true},
        'https://good.example',
      ],
      [
        {
          'ksTheater': 1,
          'event': 'theatermode',
          'detail': {'active': true, 'phase': 'dim', 'source': 'page'},
        },
        'https://good.example',
      ],
    ]);
    expect(out['bad'], [
      [
        {'ksTheater': 1, 'id': 'b', 'result': null},
        'https://bad.example',
      ],
    ], reason: 'refused, and no event');
    expect(out['nested'], isEmpty);
  });
}
